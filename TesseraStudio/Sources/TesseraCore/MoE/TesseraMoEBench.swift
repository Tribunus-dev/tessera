import Foundation

/// MoE A/B bench. Ports the algorithmic shape of
/// `tessera-studio-linux/src/core/moe/MoE.cpp`'s `Bench::run_ab`:
/// APEX quantization tiers x prefetcher strategies x scenarios, with a
/// per-sample hit/miss simulation against an LRU expert cache.
///
/// The router + cache math is real; the ttft/tps values are SYNTHETIC (as the
/// Linux version's comments admit - `r.ttft_ms = 120 + stall*0.5` etc.) and
/// the JSONL marks every row `synthetic: true` so no one mistakes a bench
/// number for a measurement until the real calibration path lands.
public struct TesseraMoEBenchResult: Codable, Sendable, Identifiable {
    public var id: String { "\(scenario)|\(prefetcher)|\(apexTier)|\(tsMs)" }
    public let prefetcher: String
    public let scenario: String
    public let apexTier: String
    public let ttftMs: Double
    public let decodeTps: Double
    public let hitRate: Double
    public let stallMs: Double
    public let vramPeakMB: Int
    public let pplDelta: Double
    public let tsMs: Int64
    public let synthetic: Bool

    enum CodingKeys: String, CodingKey {
        case prefetcher, scenario
        case apexTier = "apex_tier"
        case ttftMs = "ttft_ms"
        case decodeTps = "decode_tps"
        case hitRate = "hit_rate"
        case stallMs = "stall_ms"
        case vramPeakMB = "vram_peak_mb"
        case pplDelta = "ppl_delta"
        case tsMs = "ts_ms"
        case synthetic
    }
}

/// APEX quantization tiers. The `tensorPlan` is a llama.cpp tensor-type
/// shorthand like the Linux version's `ApexPlan::for_tier`. The `pplDelta`
/// is the expected perplexity regression vs Q8 (matches Linux's tier ladder).
public enum TesseraApexTier: String, CaseIterable, Sendable {
    case mini, balanced, quality, maxQuality, lossless

    public var label: String { rawValue }
    public var tensorPlan: String {
        switch self {
        case .mini: "routed:Q3_K shared:Q4_K attn:Q4_K blk.0-4:Q6_K"
        case .balanced: "routed:Q4_K_M shared:Q5_K attn:Q5_K blk.0-4:Q6_K"
        case .quality: "routed:Q6_K shared:Q8_0 attn:Q6_K blk.0-4:Q8_0"
        case .maxQuality: "routed:Q8_0 shared:Q8_0 attn:Q8_0"
        case .lossless: "routed:Q8_0 shared:F16 attn:F16"
        }
    }
    public var pplDelta: Double {
        switch self {
        case .mini: 0.12
        case .balanced: 0.05
        case .quality: 0.01
        case .maxQuality: 0.003
        case .lossless: 0.0
        }
    }
}

public enum TesseraMoEBench {
    public struct Scenario: Sendable {
        public let name: String
        public let vramMB: Int
        public init(name: String, vramMB: Int) { self.name = name; self.vramMB = vramMB }
    }

    public static let defaultScenarios: [Scenario] = [
        .init(name: "24GB (3090Ti)", vramMB: 24000),
        .init(name: "16GB (4060)", vramMB: 16000),
        .init(name: "NVMe offload", vramMB: 8000),
    ]

    public static let prefetchers = ["SpecPrefetch", "SPMoE", "CORM"]

    /// Run an A/B sweep: each scenario x each prefetcher at the given tier.
    /// The cache is a simple LRU keyed by expert id; the hit/miss loop mirrors
    /// the Linux `Bench::run_ab` per-sample structure.
    public static func runAB(tier: TesseraApexTier,
                             scenarios: [Scenario] = defaultScenarios,
                             samples: Int = 64) -> [TesseraMoEBenchResult] {
        var out: [TesseraMoEBenchResult] = []
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for sc in scenarios {
            for pf in prefetchers {
                var hits = 0, total = 0
                var stall: Double = 0
                var cache: [Int] = []
                let cacheCap = 8
                // Deterministic pseudo-random expert ids for reproducibility.
                var seed: UInt64 = 0xDEADBEEF
                for _ in 0..<samples {
                    func rng() -> Int {
                        seed = seed &* 6364136223846793005 &+ 1442695040888963407
                        return Int(seed % 64)
                    }
                    let predicted = (0..<3).map { _ in rng() }
                    let actual = (0..<3).map { _ in rng() }
                    for e in predicted + actual {
                        total += 1
                        if cache.contains(e) {
                            hits += 1
                        } else {
                            stall += 0.8
                            cache.append(e)
                            if cache.count > cacheCap { cache.removeFirst() }
                        }
                    }
                }
                let hitRate = total > 0 ? Double(hits) / Double(total) : 0
                // SYNTHETIC latency formulas - same shape as the Linux version.
                // Marked synthetic in the JSONL so no one mistakes this for a
                // real measurement until the calibration path is wired.
                let ttft = 120 + stall * 0.5
                let decode = 35.0 / (1.0 + stall * 0.02)
                let peak = max(8000, sc.vramMB - Int(stall * 2))
                out.append(TesseraMoEBenchResult(
                    prefetcher: pf, scenario: sc.name, apexTier: tier.label,
                    ttftMs: ttft, decodeTps: decode, hitRate: hitRate, stallMs: stall,
                    vramPeakMB: peak, pplDelta: tier.pplDelta, tsMs: now, synthetic: true
                ))
            }
        }
        return out
    }

    /// Write the bench results as JSONL. Mirrors the Linux path layout under
    /// the user's Application Support directory on macOS.
    @discardableResult
    public static func writeJSONL(_ results: [TesseraMoEBenchResult]) -> URL? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = support.appendingPathComponent("Tessera/bench", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(Int64(Date().timeIntervalSince1970 * 1000)).jsonl")
        let encoder = JSONEncoder()
        var lines: [String] = []
        for r in results {
            if let data = try? encoder.encode(r), let s = String(data: data, encoding: .utf8) {
                lines.append(s)
            }
        }
        do {
            try lines.joined(separator: "\n").data(using: .utf8)?.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
