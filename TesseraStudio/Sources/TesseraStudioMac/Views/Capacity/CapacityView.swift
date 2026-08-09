import SwiftUI
import TesseraCore

/// Hardware capacity + model-fit + MoE A/B bench surface. The Mac-native
/// equivalent of the Linux capacity surface: CPU/GPU/RAM cards, the community
/// model-fit catalog with green/amber/red badges, and a MoE bench runner that
/// writes JSONL results to Application Support.
struct CapacityView: View {
    @State private var capacity: TesseraLocalCapacity?
    @State private var fits: [TesseraModelFit] = []
    @State private var benchResults: [TesseraMoEBenchResult] = []
    @State private var benchPath: URL?
    @State private var benchTier: TesseraApexTier = .balanced
    @State private var benchRunning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Capacity")
                    .font(.largeTitle.bold())

                if let cap = capacity {
                    hardwareCards(cap)
                    memoryBar(cap)
                } else {
                    ProgressView("Probing hardware...")
                }

                modelFitSection
                moeBenchSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Capacity")
        .task { await refresh() }
    }

    private func refresh() async {
        let cap = TesseraCapacity.gather()
        let computedFits = TesseraCapacity.communityFits(cap)
        await MainActor.run {
            capacity = cap
            fits = computedFits
        }
    }

    // MARK: - Hardware cards

    private func hardwareCards(_ cap: TesseraLocalCapacity) -> some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: 12) {
            card("CPU", systemImage: "cpu") {
                Text(cap.cpuModel.isEmpty ? "Apple Silicon" : cap.cpuModel)
                    .font(.callout)
                Text("\(cap.cpuCores) cores - \(cap.cpuISA)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            card("RAM", systemImage: "memorychip") {
                Text("\(cap.ramTotalMB / 1024) GB total")
                    .font(.callout)
                Text("\(cap.ramAvailMB / 1024) GB free (approx)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let igpu = cap.igpu {
                card("GPU", systemImage: "soc") {
                    Text(igpu.name).font(.callout)
                    Text("\(igpu.api) - \(igpu.vramMB / 1024) GB working set - ~\(Int(cap.bandwidthGBs)) GB/s")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            card("Bandwidth", systemImage: "speedometer") {
                Text(String(format: "%.0f GB/s nominal", cap.bandwidthGBs))
                    .font(.callout)
                Text("Apple Silicon unified-memory estimate")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func card<Content: View>(_ title: String, systemImage: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func memoryBar(_ cap: TesseraLocalCapacity) -> some View {
        let used = cap.ramTotalMB > cap.ramAvailMB ? cap.ramTotalMB - cap.ramAvailMB : 0
        let frac = cap.ramTotalMB > 0 ? Double(used) / Double(cap.ramTotalMB) : 0
        return VStack(alignment: .leading, spacing: 4) {
            Text("Memory: \(used / 1024) GB used of \(cap.ramTotalMB / 1024) GB")
                .font(.caption)
            ProgressView(value: frac).tint(frac > 0.85 ? .red : .accentColor)
        }
    }

    // MARK: - Model fit

    private var modelFitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Community model fit")
                .font(.title2.bold())
            Text("Estimated tok/s from memory bandwidth; badges are RAM-fit then speed.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(fits) { fit in
                HStack {
                    badge(fit.badge)
                    VStack(alignment: .leading) {
                        Text(fit.id).font(.body)
                        Text("\(fit.sizeMB / 1024) GB - \(fit.quant) - ~\(String(format: "%.1f", fit.estTokS)) tok/s")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !fit.fitsRAM {
                        Text("won't fit").font(.caption2).foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func badge(_ kind: String) -> some View {
        let color: Color = switch kind {
        case "green": .green
        case "amber": .orange
        default: .red
        }
        return Circle().fill(color).frame(width: 12, height: 12)
    }

    // MARK: - MoE bench

    private var moeBenchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MoE A/B bench")
                .font(.title2.bold())
            Text("Apex quantization tier x prefetcher x scenario. Latency numbers are synthetic (marked in the JSONL); the router/cache hit math is real.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("APEX tier", selection: $benchTier) {
                ForEach(TesseraApexTier.allCases, id: \.rawValue) { tier in
                    Text(tier.label.capitalized).tag(tier)
                }
            }
            .pickerStyle(.segmented)
            Text(benchTier.tensorPlan)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)

            HStack {
                Button {
                    runBench()
                } label: {
                    if benchRunning { ProgressView().controlSize(.small) } else { Text("Run bench") }
                }
                .disabled(benchRunning)

                if let path = benchPath {
                    Text("Wrote: \(path.lastPathComponent)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if !benchResults.isEmpty {
                Table(benchResults) {
                    TableColumn("Scenario") { Text($0.scenario) }
                    TableColumn("Prefetcher") { Text($0.prefetcher) }
                    TableColumn("Hit %") { Text(String(format: "%.0f%%", $0.hitRate * 100)) }
                    TableColumn("tok/s") { Text(String(format: "%.1f", $0.decodeTps)) }
                    TableColumn("ppl \u{0394}") { Text(String(format: "+%.3f", $0.pplDelta)) }
                }
                .frame(minHeight: 160)
            }
        }
    }

    private func runBench() {
        benchRunning = true
        let tier = benchTier
        Task {
            let results = TesseraMoEBench.runAB(tier: tier)
            let path = TesseraMoEBench.writeJSONL(results)
            await MainActor.run {
                benchResults = results
                benchPath = path
                benchRunning = false
            }
        }
    }
}
