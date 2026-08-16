import Foundation
@testable import TesseraCore

// MARK: - RoundTripCorpus
//
// Support types for the P2-0 corpus harness (studio-expansion-plan.md
// section 6f, deliverable 1.0: "a checked-in corpus of real documents ...
// plus a test target that imports each, exports it, and scores survival
// per feature axis"). This file is deliberately soffice-free and holds no
// XCTestCase: doctrine rule 10 restricts SHELLING OUT to the quarantined
// probe file (RoundTripCorpusTests.swift); the scoring math and the
// Codable scoreboard shape live here so they're independently testable
// and reusable if a future wave adds more probe files.
//
// FROM-SCRATCH REWRITE (2026-08-15): the previous RoundTripCorpus.swift +
// RoundTripCorpusTests.swift were deleted 2026-08-15 with the whole
// pre-doctrine suite. This is not a restore - the fixture set, the axis
// vocabulary, and the scoring shape below are new, sized to what
// Tessera's CURRENT bridges (WriterBridgeFilter, CalcBridgeFilter,
// LOBridgeDeckIO, ODGBridgeFilter) can actually round-trip, not to the
// full studio-expansion-plan.md 6f target (20+ DOCX / 10+ ODS-XLSX / 10+
// PPTX-ODP / 5+ ODG-SVG). See docs/.scratch/p2-0-findings-d.md item 4 for
// the corpus-size gap this wave leaves for a future wave to close.

// MARK: - Feature axis vocabulary

/// The shared feature-axis vocabulary the scoreboard scores against.
/// Not every fixture exercises every axis - `RoundTripFixtureResult
/// .axisScores` only carries the axes that particular fixture's material
/// and content make meaningful (doctrine rule 7: an axis a fixture
/// doesn't exercise is simply absent, never scored as a false 100%).
public enum RoundTripAxis: String, Codable, Sendable, CaseIterable {
    case cellValues
    case blocks
    case tables
    case footnotes
    case slideCount
    case slideTitles
    case slideNotes
    case masterBackgrounds
    case shapeKinds
    case layers
    case connectors
}

// MARK: - RoundTripAxisScore

/// One axis's survival count for one fixture: `survived` out of
/// `expected` features from the FIRST import were still present after
/// export + reimport. `expected == 0` means the axis wasn't exercised by
/// this fixture (not a failure - `percentage` reports `nil` rather than
/// a misleading 100%).
public struct RoundTripAxisScore: Codable, Sendable, Equatable {
    public let axis: RoundTripAxis
    public let expected: Int
    public let survived: Int
    public let notes: String?

    public init(axis: RoundTripAxis, expected: Int, survived: Int, notes: String? = nil) {
        self.axis = axis
        self.expected = expected
        self.survived = survived
        self.notes = notes
    }

    /// `nil` when `expected == 0` (axis not exercised); otherwise
    /// `survived / expected` as a percentage, clamped to [0, 100] so a
    /// pathological `survived > expected` (e.g. a bridge that duplicates
    /// content) reports 100, not a claim beyond what was ever present.
    public var percentage: Double? {
        guard expected > 0 else { return nil }
        return min(100, max(0, Double(survived) / Double(expected) * 100))
    }
}

// MARK: - RoundTripFixtureResult

public enum RoundTripFixtureStatus: String, Codable, Sendable {
    /// The full import -> export -> reimport pipeline ran and every
    /// `axisScores` entry reflects a real comparison.
    case scored
    /// The fixture's material needs a tool this environment doesn't
    /// have (soffice absent, or a `TesseraFormatBridge` python library
    /// missing - e.g. python-docx). Not a Tessera code defect; rerun in
    /// an environment with the dependency to get a real score.
    case skipped
    /// The pipeline ran but threw. `detail` carries the error
    /// description; this status is itself a primary-metric signal (an
    /// import/export crash), per studio-expansion-plan.md 6f's "trust =
    /// import failure / crash rate on the corpus" template.
    case failed
}

public struct RoundTripFixtureResult: Codable, Sendable {
    public let fixtureName: String
    public let material: String
    public let status: RoundTripFixtureStatus
    public let detail: String?
    public let axisScores: [RoundTripAxisScore]

    public init(
        fixtureName: String,
        material: String,
        status: RoundTripFixtureStatus,
        detail: String? = nil,
        axisScores: [RoundTripAxisScore] = []
    ) {
        self.fixtureName = fixtureName
        self.material = material
        self.status = status
        self.detail = detail
        self.axisScores = axisScores
    }
}

// MARK: - RoundTripScoreboard

/// The primary-metric artifact studio-expansion-plan.md 6f names: "the
/// harness IS the primary-metric source for every parity claim". A wave
/// gate reads this (or the JSON file `RoundTripCorpusTests` writes
/// alongside it) rather than trusting a narrative claim.
public struct RoundTripScoreboard: Codable, Sendable {
    public let probedAt: Date
    public let sofficeVersionDescription: String
    public let fixtures: [RoundTripFixtureResult]

    public init(probedAt: Date, sofficeVersionDescription: String, fixtures: [RoundTripFixtureResult]) {
        self.probedAt = probedAt
        self.sofficeVersionDescription = sofficeVersionDescription
        self.fixtures = fixtures
    }

    /// Aggregate survival percentage for one axis across every `.scored`
    /// fixture that exercised it (sums `survived`/`expected` across
    /// fixtures rather than averaging per-fixture percentages, so a
    /// fixture with more features of that kind carries proportionally
    /// more weight). `nil` when no scored fixture exercised the axis.
    public func aggregatePercentage(for axis: RoundTripAxis) -> Double? {
        let scores = fixtures
            .filter { $0.status == .scored }
            .flatMap { $0.axisScores }
            .filter { $0.axis == axis && $0.expected > 0 }
        guard !scores.isEmpty else { return nil }
        let totalExpected = scores.reduce(0) { $0 + $1.expected }
        let totalSurvived = scores.reduce(0) { $0 + $1.survived }
        guard totalExpected > 0 else { return nil }
        return min(100, max(0, Double(totalSurvived) / Double(totalExpected) * 100))
    }

    public var scoredCount: Int { fixtures.filter { $0.status == .scored }.count }
    public var skippedCount: Int { fixtures.filter { $0.status == .skipped }.count }
    public var failedCount: Int { fixtures.filter { $0.status == .failed }.count }
}

// MARK: - RoundTripScoring
//
// Pure comparison functions: given the model produced by the FIRST
// import and the model produced by reimporting the exported bytes,
// count how many of the first import's features are still present in
// the second. Kept as static functions (not methods on the model types
// themselves) so the scoring logic stays in one file, matching this
// harness's own single-source-of-truth goal.

public enum RoundTripScoring {

    // MARK: Calc (Sheet)

    /// `cellValues`: for every (row, col) the FIRST import populated
    /// with non-empty text, does the REIMPORTED sheet have the same
    /// text at that coordinate. Counts, never diffs formula source
    /// (CalcBridgeFilter's own doc comment: import always flattens
    /// formulas to their last-computed value, so scoring "formula
    /// survival" against this filter would just re-assert a known,
    /// already-documented limitation, not measure anything new).
    public static func sheetAxisScores(original: Sheet, roundTripped: Sheet) -> [RoundTripAxisScore] {
        var expected = 0
        var survived = 0
        for row in 0..<original.rowCount {
            for col in 0..<original.columnCount {
                let originalText = original.cellText(row: row, col: col)
                guard !originalText.isEmpty else { continue }
                expected += 1
                if row < roundTripped.rowCount, col < roundTripped.columnCount,
                   roundTripped.cellText(row: row, col: col) == originalText {
                    survived += 1
                }
            }
        }
        return [RoundTripAxisScore(axis: .cellValues, expected: expected, survived: survived)]
    }

    // MARK: Impress (SlideDeck)

    /// `slideCount`/`slideTitles`/`slideNotes`/`masterBackgrounds`: the
    /// axes `LOBridgeDeckIO.mapToSlideDeck`/`mapToFlatODFTree` actually
    /// carry (see that type's own doc comment for the exact mapping and
    /// its documented "Default" master-page asymmetry, which this
    /// scorer accounts for by matching on background color, not id).
    public static func slideDeckAxisScores(original: SlideDeck, roundTripped: SlideDeck) -> [RoundTripAxisScore] {
        var scores: [RoundTripAxisScore] = []

        let originalSlideCount = original.body.rootChildren.count
        let roundTrippedSlideCount = roundTripped.body.rootChildren.count
        scores.append(RoundTripAxisScore(
            axis: .slideCount,
            expected: originalSlideCount,
            survived: min(originalSlideCount, roundTrippedSlideCount)
        ))

        let originalTitles = titles(of: original)
        let roundTrippedTitles = titles(of: roundTripped)
        let titleSurvivors = originalTitles.filter { roundTrippedTitles.contains($0) }
        scores.append(RoundTripAxisScore(
            axis: .slideTitles,
            expected: originalTitles.count,
            survived: titleSurvivors.count
        ))

        let originalNotes = original.slideMeta.values.map(\.notes).filter { !$0.isEmpty }
        let roundTrippedNotes = Set(roundTripped.slideMeta.values.map(\.notes).filter { !$0.isEmpty })
        let noteSurvivors = originalNotes.filter { roundTrippedNotes.contains($0) }
        scores.append(RoundTripAxisScore(
            axis: .slideNotes,
            expected: originalNotes.count,
            survived: noteSurvivors.count
        ))

        // Match master pages by background color hex (not id - export
        // always mints fresh UUIDs, and LOBridgeDeckIO's own doc
        // comment names the extra unconditional "Default" master as a
        // harmless, by-design asymmetry on re-import).
        let originalBackgrounds = Set(original.effectiveMasterPages.values.compactMap { master -> String? in
            guard case .literal(let hex)? = master.backgroundColorHex else { return nil }
            return hex
        })
        let roundTrippedBackgrounds = Set(roundTripped.effectiveMasterPages.values.compactMap { master -> String? in
            guard case .literal(let hex)? = master.backgroundColorHex else { return nil }
            return hex
        })
        let backgroundSurvivors = originalBackgrounds.filter { roundTrippedBackgrounds.contains($0) }
        scores.append(RoundTripAxisScore(
            axis: .masterBackgrounds,
            expected: originalBackgrounds.count,
            survived: backgroundSurvivors.count
        ))

        return scores
    }

    private static func titles(of deck: SlideDeck) -> [String] {
        // firstHeadingText already covers "the root block itself is the
        // heading" (its own first check, before it recurses into
        // children), so a bare-heading slide and a `.toggle`-grouped
        // slide (heading + body paragraphs) both resolve through the
        // same call - no separate case needed here.
        deck.body.rootChildren.compactMap { id in
            firstHeadingText(blockID: id, ast: deck.body)
        }
    }

    private static func firstHeadingText(blockID: UUID, ast: DocumentAST) -> String? {
        guard let block = ast.blocks[blockID] else { return nil }
        if block.type == .heading {
            let text = block.content.map(\.text).joined()
            return text.isEmpty ? nil : text
        }
        for child in block.children {
            if let found = firstHeadingText(blockID: child, ast: ast) { return found }
        }
        return nil
    }

    // MARK: Draw (Drawing)

    /// `shapeKinds`/`layers`/`connectors`: exactly ODGBridgeFilter's own
    /// documented scope ("only ShapeKind cases + ShapeGeometry ... the
    /// layer-set and connector clauses" - fill/stroke/rotation are
    /// explicitly out of scope there, so this scorer doesn't claim them
    /// either).
    public static func drawingAxisScores(original: Drawing, roundTripped: Drawing) -> [RoundTripAxisScore] {
        var scores: [RoundTripAxisScore] = []

        let originalKinds = original.shapes.map(\.kind)
        var remainingRoundTripped = roundTripped.shapes.map(\.kind)
        var kindSurvivors = 0
        for kind in originalKinds {
            if let index = remainingRoundTripped.firstIndex(of: kind) {
                kindSurvivors += 1
                remainingRoundTripped.remove(at: index)
            }
        }
        scores.append(RoundTripAxisScore(axis: .shapeKinds, expected: originalKinds.count, survived: kindSurvivors))

        let originalLayerNames = Set(original.layers.map(\.name))
        let roundTrippedLayerNames = Set(roundTripped.layers.map(\.name))
        let layerSurvivors = originalLayerNames.filter { roundTrippedLayerNames.contains($0) }
        scores.append(RoundTripAxisScore(axis: .layers, expected: originalLayerNames.count, survived: layerSurvivors.count))

        let originalConnectorStyles = original.shapes.compactMap { $0.connector?.style }
        var remainingConnectorStyles = roundTripped.shapes.compactMap { $0.connector?.style }
        var connectorSurvivors = 0
        for style in originalConnectorStyles {
            if let index = remainingConnectorStyles.firstIndex(of: style) {
                connectorSurvivors += 1
                remainingConnectorStyles.remove(at: index)
            }
        }
        scores.append(RoundTripAxisScore(axis: .connectors, expected: originalConnectorStyles.count, survived: connectorSurvivors))

        return scores
    }

    // MARK: Writer (DocumentAST)

    /// `blocks`/`tables`/`footnotes`: generic `DocumentAST` block-type
    /// census, usable regardless of which importer produced the AST
    /// (WriterBridgeFilter today; a future native ODT/DOCX reader
    /// tomorrow - the scorer doesn't care which bridge, only the model
    /// shape both sides of doctrine rule 11's seam already share).
    public static func documentASTAxisScores(original: DocumentAST, roundTripped: DocumentAST) -> [RoundTripAxisScore] {
        var scores: [RoundTripAxisScore] = []

        let originalBlockCount = original.blocks.count
        scores.append(RoundTripAxisScore(
            axis: .blocks,
            expected: originalBlockCount,
            survived: min(originalBlockCount, roundTripped.blocks.count)
        ))

        let originalTableCount = original.blocks.values.filter { $0.type == .table }.count
        let roundTrippedTableCount = roundTripped.blocks.values.filter { $0.type == .table }.count
        scores.append(RoundTripAxisScore(
            axis: .tables,
            expected: originalTableCount,
            survived: min(originalTableCount, roundTrippedTableCount)
        ))

        let originalFootnoteCount = original.blocks.values.filter { $0.type == .footnote || $0.type == .endnote }.count
        let roundTrippedFootnoteCount = roundTripped.blocks.values.filter { $0.type == .footnote || $0.type == .endnote }.count
        scores.append(RoundTripAxisScore(
            axis: .footnotes,
            expected: originalFootnoteCount,
            survived: min(originalFootnoteCount, roundTrippedFootnoteCount)
        ))

        return scores
    }
}

// MARK: - Scoreboard JSON persistence

public enum RoundTripScoreboardWriter {
    /// Writes `scoreboard` as pretty, sorted-key JSON to `url` - the
    /// "checked-in-adjacent scratch file" studio-expansion-plan.md 6f
    /// allows as the primary-metric artifact a wave gate reads. Sorted
    /// keys + ISO-8601 dates keep the diff small across probe reruns
    /// (rule 2's "byte-identical re-encode" spirit, applied to a report
    /// artifact rather than a domain value type).
    public static func write(_ scoreboard: RoundTripScoreboard, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(scoreboard)
        try data.write(to: url, options: .atomic)
    }
}
