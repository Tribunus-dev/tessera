import SwiftUI
import TesseraCore

/// The single home for all AI configuration and machinery, organized into four
/// cohesive themes by the pipeline shape the app already encodes
/// (Calibrate -> Evolve -> Evaluate -> Deploy). Friendly to non-technical users
/// by default (the `standard` interface level hides the ML-researcher knobs);
/// switching to `advanced` reveals the deep controls via ``AdvancedSection``.
///
/// Each theme is a lazily-loaded tab so the heavy sub-views only instantiate
/// when opened. Reuses the existing surfaces (Library, Capacity, Learning,
/// Runs, Providers) rather than re-deriving their contents.
struct IntelligenceView: View {
    @AppStorage("interfaceLevel") private var interfaceLevelRaw = InterfaceLevel.standard.rawValue
    @State private var theme: IntelligenceTheme = .modelsAndHardware

    private var interfaceLevel: InterfaceLevel {
        InterfaceLevel(rawValue: interfaceLevelRaw) ?? .standard
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch theme {
            case .modelsAndHardware:  ModelsAndHardwareTheme()
            case .optimization:       OptimizationTheme()
            case .performanceQuality: PerformanceQualityTheme()
            case .agentAutonomy:      AgentAutonomyTheme()
            }
        }
        .navigationTitle("Intelligence")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $theme) {
                ForEach(IntelligenceTheme.allCases) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Intelligence theme")

            Picker("Level", selection: $interfaceLevelRaw) {
                ForEach(InterfaceLevel.allCases) { level in
                    Text(level.displayName).tag(level.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .help("Standard hides the ML-researcher controls; Advanced reveals them.")
            .accessibilityLabel("Interface level: \(interfaceLevel.displayName)")
            .frame(width: 180)
        }
        .padding(12)
    }
}

enum IntelligenceTheme: String, CaseIterable, Identifiable {
    case modelsAndHardware = "Models & Hardware"
    case optimization = "Optimization"
    case performanceQuality = "Performance & Quality"
    case agentAutonomy = "Agent & Autonomy"

    var id: String { rawValue }
    var title: String { rawValue }
}

// MARK: - Theme: Models & Hardware

/// "What can I run?" — model catalog, will-it-fit badges, cloud providers.
private struct ModelsAndHardwareTheme: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Models") { LibraryView() }
                section("Hardware fit") { CapacityView() }
                AdvancedSection("Provider catalog") {
                    ProvidersSettingsView()
                }
            }
            .padding()
        }
    }
}

// MARK: - Theme: Optimization

/// "Make it smaller, faster, just-as-good" — the Calibrate -> Evolve ->
/// Quantize -> Convert pipeline. The standard face summarizes the latest
/// receipt + verdict; advanced reveals per-tensor/GA/MoE detail via the
/// Runs + Analytics surfaces.
private struct OptimizationTheme: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Run history") { RunsView() }
                AdvancedSection("Quantization receipts & analytics") {
                    Text("Open a run for the per-tensor stats, GA archive grid, and MoE A/B bench (latency values are synthetic).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }
}

// MARK: - Theme: Performance & Quality

/// "Is it still good?" — capability eval + adaptation. The standard face is
/// the 5-axis score; advanced surfaces the raw metrics.
private struct PerformanceQualityTheme: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Capability & adaptation") { LearningDashboardView() }
            }
            .padding()
        }
    }
}

// MARK: - Theme: Agent & Autonomy

/// "What is Tessera allowed to do?" — personas, approval levels, the approver
/// network, learned permissions. The standard face is the persona/approval
/// legend; advanced surfaces per-tool overrides and the escalation tiers.
private struct AgentAutonomyTheme: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                personasCard
                approvalLegend
                AdvancedSection("Approver network") {
                    Text("A small local network trained on your approval receipts. It predicts; it never grants. Fails closed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }

    private var personasCard: some View {
        card("Personas") {
            HStack(spacing: 16) {
                personaRow(.tessy)
                personaRow(.sky)
            }
        }
    }

    private func personaRow(_ persona: AgentPersona) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(persona.displayName, systemImage: persona.symbolName)
                .foregroundStyle(persona.tint)
                .font(.headline)
            Text(persona.roleHint).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var approvalLegend: some View {
        card("Approval levels") {
            VStack(alignment: .leading, spacing: 6) {
                legendRow("Auto", "Tessy runs the action without asking (sandboxed, low risk only).")
                legendRow("Notify", "Runs, then tells you what it did.")
                legendRow("Prompt", "Asks before running.")
                legendRow("Denied", "Never runs.")
            }
            .font(.callout)
        }
    }

    private func legendRow(_ name: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).font(.callout.bold()).frame(width: 64, alignment: .leading)
            Text(detail).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func card<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Shared section helper

@ViewBuilder
private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.headline)
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}
