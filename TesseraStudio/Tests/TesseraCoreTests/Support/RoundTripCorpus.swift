import Foundation

// MARK: - CorpusFormat

/// The four flat-ODF formats the round-trip corpus spans: fods=Calc,
/// fodt=Writer, fodp=Impress, fodg=Draw. Flat ODF (single-file XML, not
/// the zipped package form) is what `LibreOfficeConverter` reads and
/// writes on this platform - see docs/.scratch/sota-bridge-report.md.
enum CorpusFormat: String, CaseIterable, Hashable, Sendable {
    case fods
    case fodt
    case fodp
    case fodg
}

// MARK: - CorpusEntry

/// One fixture in the round-trip corpus. `featureTags` names what the
/// fixture is meant to exercise (e.g. ["formula", "multi-cell"]) so a
/// later round-trip test can report survival per feature axis, not just
/// pass/fail per file.
struct CorpusEntry: Sendable {
    let name: String
    let format: CorpusFormat
    let url: URL
    let featureTags: [String]
}

// MARK: - RoundTripCorpus

/// Enumerates and loads the round-trip fixture corpus bundled under
/// `Fixtures/RoundTrip` (studio-expansion-plan.md 6b row 1.0). This is
/// the primary-metric source every later P1/P2 round-trip test reads
/// fixtures from; it only enumerates and loads - parsing and scoring
/// survival per feature axis is FlatODFReader's and the bridge filters'
/// job in later items.
enum RoundTripCorpus {

    enum LoadError: Error, LocalizedError, Sendable, Equatable {
        case resourceNotFound(fileName: String)

        var errorDescription: String? {
            switch self {
            case .resourceNotFound(let fileName):
                return "RoundTripCorpus: fixture not found in bundle: \(fileName)"
            }
        }
    }

    /// name + format + feature tags for every fixture; the file itself
    /// lives at Fixtures/RoundTrip/<name>.<format>. Kept as one literal
    /// list (rather than a directory scan) so a missing or misnamed
    /// file fails loudly at `load()` instead of silently vanishing from
    /// the corpus.
    private static let manifest: [(name: String, format: CorpusFormat, featureTags: [String])] = [
        ("basic-cells", .fods, ["cell-values", "multi-cell"]),
        ("sum-formula", .fods, ["formula", "multi-cell"]),
        ("paragraph-heading", .fodt, ["paragraph", "heading"]),
        ("bold-run", .fodt, ["paragraph", "character-style"]),
        ("title-slide", .fodp, ["placeholder", "title"]),
        ("rectangle-shape", .fodg, ["shape", "fill", "stroke"]),
    ]

    /// Resolves every entry in `manifest` against the test bundle's
    /// copied `Fixtures/RoundTrip` tree. Mirrors the manual URL
    /// composition `TesseraSkillLoaderTests` uses for `Fixtures/Skills`,
    /// since Package.swift's `.copy("Fixtures")` resource rule preserves
    /// that nesting verbatim under `Bundle.module.resourceURL`.
    static func load(bundle: Bundle = Bundle.module) throws -> [CorpusEntry] {
        let root = bundle.resourceURL!
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("RoundTrip", isDirectory: true)

        return try manifest.map { item in
            let fileName = "\(item.name).\(item.format.rawValue)"
            let url = root.appendingPathComponent(fileName, isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LoadError.resourceNotFound(fileName: fileName)
            }
            return CorpusEntry(name: item.name, format: item.format, url: url, featureTags: item.featureTags)
        }
    }
}
