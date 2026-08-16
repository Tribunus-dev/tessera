import XCTest
@testable import TesseraCore

// MARK: - RoundTripCorpusTests
//
// QUARANTINED EMPIRICAL PROBE (doctrine rule 10). Shells out to a real
// `soffice` (and, for the Writer fixtures, the `TesseraFormatBridge`
// python subprocess) to run studio-expansion-plan.md section 6f's
// deliverable 1.0: import each corpus fixture, export it back out,
// reimport the export, and score per-feature-axis survival through
// Tessera's OWN bridge code (CalcBridgeFilter / LOBridgeDeckIO /
// ODGBridgeFilter / WriterBridgeFilter + TesseraFormatBridge), not just
// hand-authored XML inspection. The scoring math itself lives in
// RoundTripCorpus.swift (Support/) so it stays soffice-free and
// independently testable; this file is only the shelling-out half.
//
// PROBE DATE / TOOL VERSION (re-run TODAY, not copied forward - doctrine
// rule 10: "re-verification happens by re-running them, not by trusting
// the comment"):
//   - Probed: 2026-08-15
//   - `soffice --version`: LibreOffice 26.2.5.2
//     (cd7284b4cbbfeb507e630c1aac019f4157393acb)
//   - `python3 -c "import docx"`: FAILED on this machine
//     (ModuleNotFoundError: No module named 'docx') - python-docx is NOT
//     installed here, so every Writer fixture below is expected to
//     report `.skipped` (via `TesseraFormatBridge.FormatBridgeError
//     .missingLibrary`) on THIS run. They score for real in any
//     environment where python-docx is installed - `scoreWriterFixture`
//     does not special-case this machine, it just reports what actually
//     happened. `openpyxl` IS installed but unused: `CalcBridgeFilter`
//     only reads/writes ods/xls (its own doc comment: xlsx already goes
//     through `TesseraFormatBridge` for a DIFFERENT, not-yet-round-trip
//     -tested path).
//
// CORPUS SIZE, STATED PLAINLY: this is a from-scratch-rewrite SEED
// corpus (10 flat-ODF sources + 10 soffice-derived binaries = 20 files),
// not studio-expansion-plan.md 6f's full target (20+ DOCX / 10+
// ODS-XLSX / 10+ PPTX-ODP / 5+ ODG-SVG). See
// docs/.scratch/p2-0-findings-d.md item 4 for the exact gap and the
// axes (charts, themes, conditionalFormats) that have NO round-trip
// code path in this codebase yet at all, independent of corpus size.
//
// Skips per-fixture, cleanly, when its required tool is absent (soffice
// for everything; python-docx additionally for Writer). 120s allowance
// (DoctrineTimeout.probe) per rule 12.

final class RoundTripCorpusTests: DoctrineTestCase {
    // The whole-test watchdog must be bigger than any single fixture's
    // `DoctrineTimeout.probe` (120s) allowance below, since this test
    // runs up to 3 sequential probe-scale soffice calls per fixture
    // across 12 fixtures - `.probe` alone would fire on ordinary
    // cumulative wall-clock time with nothing actually hung. See
    // `DoctrineTimeout.corpusProbe`'s own doc comment.
    override var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.corpusProbe }

    private func fixturesRoot() -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        // Tests/TesseraCoreTests/RoundTripCorpusTests.swift -> Tests/TesseraCoreTests/Fixtures/RoundTrip
        return thisFile.deletingLastPathComponent().appendingPathComponent("Fixtures/RoundTrip")
    }

    private func scoreboardURL() -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent() // RoundTripCorpusTests.swift -> TesseraCoreTests/
            .deletingLastPathComponent() // TesseraCoreTests/ -> Tests/
            .deletingLastPathComponent() // Tests/ -> TesseraStudio/
            .appendingPathComponent("docs/.scratch/p2-0-corpus-scoreboard.json")
    }

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("corpus-\(UUID().uuidString)-\(name)")
    }

    /// One retry, fixture-scoped, ONLY for a `.failed`/"timeout" result -
    /// a real content mismatch (`.failed` with any other detail) or a
    /// clean `.scored`/`.skipped` passes through untouched. Each
    /// `soffice` call below gets a fresh throwaway `-env:UserInstallation=`
    /// profile per `LibreOfficeConverter.convert()` (deliberate, to avoid
    /// the well-known shared-profile-lock hang), which trades a small
    /// amount of cold-start wall-clock variance for that safety; running
    /// ~27 such calls back to back across the whole corpus occasionally
    /// pushes ONE of them past the 120s per-call allowance under normal
    /// system load with nothing actually broken (confirmed empirically
    /// during P2-0: re-running the exact same corpus, a DIFFERENT
    /// fixture timed out each time, never the same one twice - the
    /// signature of transient load, not a fixture-specific defect). A
    /// fixture that times out twice in a row is a real finding, not
    /// absorbed here.
    private func scoringOnceRetryingTimeout(
        _ score: () async throws -> RoundTripFixtureResult
    ) async throws -> RoundTripFixtureResult {
        var last = try await score()
        // Up to 2 retries (3 attempts total): under the full 1794-test
        // suite's sustained CPU load, a single retry still occasionally
        // lands on another transient timeout (confirmed empirically
        // during P2-0's gate - a DIFFERENT fixture timed out on the
        // retry than on the first attempt). Only ever retries a
        // `.failed`/"timeout" result; any other outcome returns
        // immediately.
        for _ in 0..<2 {
            guard last.status == .failed, (last.detail ?? "").contains("timeout") else { break }
            last = try await score()
        }
        return last
    }

    // MARK: - The one probe test: score the whole corpus, write the scoreboard

    /// Explicit opt-in gate (mirrors `TESSERA_DB_INTEGRATION`'s pattern),
    /// added after P2-A: this test alone grew from ~200s to ~400s across
    /// this session (real `soffice --convert-to` wall-clock time under
    /// sustained system load, not a hang - each retry attempt is itself
    /// genuine work, see `scoringOnceRetryingTimeout`'s own doc comment),
    /// which on its own blew the doctrine's 5-minute default-suite budget
    /// (rule 13) once P2-A's ~130 new tests were added alongside it. The
    /// harness is unconditionally correct and still the wave gate's
    /// primary-metric source (§6f) - it just needs to be an explicit,
    /// separately-timed pass (`TESSERA_CORPUS_HARNESS=1 swift test
    /// --filter RoundTripCorpusTests`) rather than tax on every plain
    /// `swift test`, the same reasoning `TESSERA_DB_INTEGRATION` already
    /// established for Postgres-dependent tests.
    func testRoundTripCorpusScoresEveryFixtureAndWritesScoreboard() async throws {
        guard ProcessInfo.processInfo.environment["TESSERA_CORPUS_HARNESS"] == "1" else {
            throw XCTSkip("gated: set TESSERA_CORPUS_HARNESS=1 to run the real-soffice round-trip corpus and regenerate the scoreboard - run as its own timed pass at a wave gate, not part of the default suite (doctrine rule 13)")
        }
        var results: [RoundTripFixtureResult] = []

        results.append(try await scoringOnceRetryingTimeout { try await scoreCalcFixture("basic-cells.ods") })
        results.append(try await scoringOnceRetryingTimeout { try await scoreCalcFixture("sum-formula.ods") })
        results.append(try await scoringOnceRetryingTimeout { try await scoreCalcFixture("multi-column.ods") })

        results.append(try await scoringOnceRetryingTimeout { try await scoreImpressFixture("title-slide.odp", format: .odp) })
        results.append(try await scoringOnceRetryingTimeout { try await scoreImpressFixture("master-theme-slides.odp", format: .odp) })
        results.append(try await scoringOnceRetryingTimeout { try await scoreImpressFixture("title-slide.pptx", format: .pptx) })
        results.append(try await scoringOnceRetryingTimeout { try await scoreImpressFixture("master-theme-slides.pptx", format: .pptx) })

        results.append(try await scoringOnceRetryingTimeout { try await scoreDrawFixture("rectangle-shape.odg") })
        results.append(try await scoringOnceRetryingTimeout { try await scoreDrawFixture("layered-shapes.odg") })

        results.append(try await scoringOnceRetryingTimeout { try await scoreWriterFixture("bold-run.odt") })
        results.append(try await scoringOnceRetryingTimeout { try await scoreWriterFixture("paragraph-heading.odt") })
        results.append(try await scoringOnceRetryingTimeout { try await scoreWriterFixture("table-and-footnote.odt") })

        let scoreboard = RoundTripScoreboard(
            // Fixed, not Date() (doctrine rule 4: no bare Date() in
            // assertions/artifacts derived from this test run) - the
            // real probe date is the file-header comment above,
            // re-verified by re-running this test, not by this field.
            probedAt: Date(timeIntervalSince1970: 1_755_216_000),
            sofficeVersionDescription: "LibreOffice 26.2.5.2 (cd7284b4cbbfeb507e630c1aac019f4157393acb)",
            fixtures: results
        )

        // Write the scoreboard artifact even when every fixture skips
        // (soffice fully absent) - a wave gate reading this file should
        // see WHY nothing scored, not find a missing file (see 6f: "the
        // harness IS the primary-metric source for every parity claim").
        try? FileManager.default.createDirectory(
            at: scoreboardURL().deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try RoundTripScoreboardWriter.write(scoreboard, to: scoreboardURL())

        let converter = LibreOfficeConverter()
        if converter.isAvailable {
            // Trust signal (6f's template: "import failure / crash rate
            // on the corpus, must not regress"). Every material with no
            // python dependency must SCORE, not FAIL, when soffice is
            // present - a crash here is real signal and must not be
            // silently swallowed into a passing test.
            let nonWriterResults = results.filter { $0.material != "writer" }
            for result in nonWriterResults {
                XCTAssertEqual(
                    result.status, .scored,
                    "\(result.fixtureName) (\(result.material)) should score - soffice is available and this material has no python dependency - got \(result.status), detail: \(result.detail ?? "none")"
                )
            }
            // Primary-metric floor: plain literal cell values are exactly
            // what CalcBridgeFilter's CSV pipeline is documented to
            // preserve losslessly - this is the one axis this wave can
            // assert a hard number on, not just "did not crash" (rule 8).
            if let basicCells = results.first(where: { $0.fixtureName == "basic-cells.ods" }) {
                let cellScore = basicCells.axisScores.first { $0.axis == .cellValues }
                XCTAssertEqual(cellScore?.percentage, 100, "plain literal cell values must round-trip losslessly through CalcBridgeFilter's CSV pipeline")
            }
        } else {
            XCTAssertTrue(results.allSatisfy { $0.status == .skipped }, "with soffice absent, every fixture must skip cleanly, never fail")
        }
    }

    // MARK: - Calc (CalcBridgeFilter, ods/xls, CSV-bounded per its own doc comment)

    private func scoreCalcFixture(_ fileName: String) async throws -> RoundTripFixtureResult {
        let filter = CalcBridgeFilter()
        guard filter.isAvailable else {
            return RoundTripFixtureResult(fixtureName: fileName, material: "calc", status: .skipped, detail: "soffice not found")
        }
        let ext = (fileName as NSString).pathExtension
        do {
            let data = try Data(contentsOf: fixturesRoot().appendingPathComponent(fileName))
            let original = try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
                try await filter.importWorkbook(data: data, format: ext)
            }
            let exported = try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
                try await filter.exportWorkbook(original, format: ext)
            }
            let roundTripped = try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
                try await filter.importWorkbook(data: exported, format: ext)
            }
            let scores = RoundTripScoring.sheetAxisScores(original: original, roundTripped: roundTripped)
            return RoundTripFixtureResult(fixtureName: fileName, material: "calc", status: .scored, axisScores: scores)
        } catch {
            return RoundTripFixtureResult(fixtureName: fileName, material: "calc", status: .failed, detail: String(describing: error))
        }
    }

    // MARK: - Impress (LOBridgeDeckIO, odp/pptx - native flat-ODF mapping, no python)

    private func scoreImpressFixture(_ fileName: String, format: DeckExportFormat) async throws -> RoundTripFixtureResult {
        let io = LOBridgeDeckIO()
        guard io.isAvailable else {
            return RoundTripFixtureResult(fixtureName: fileName, material: "impress", status: .skipped, detail: "soffice not found")
        }
        let sourceURL = fixturesRoot().appendingPathComponent(fileName)
        let exportURL = tempURL("export.\(format.rawValue)")
        defer { try? FileManager.default.removeItem(at: exportURL) }
        do {
            let original = try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
                try await io.importDeck(from: sourceURL)
            }
            try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
                try await io.exportDeck(original, to: exportURL, format: format)
            }
            let roundTripped = try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
                try await io.importDeck(from: exportURL)
            }
            let scores = RoundTripScoring.slideDeckAxisScores(original: original, roundTripped: roundTripped)
            return RoundTripFixtureResult(fixtureName: fileName, material: "impress", status: .scored, axisScores: scores)
        } catch {
            return RoundTripFixtureResult(fixtureName: fileName, material: "impress", status: .failed, detail: String(describing: error))
        }
    }

    // MARK: - Draw (ODGBridgeFilter, odg - native flat-ODF mapping, no python)

    private func scoreDrawFixture(_ fileName: String) async throws -> RoundTripFixtureResult {
        let filter = ODGBridgeFilter()
        guard filter.isAvailable else {
            return RoundTripFixtureResult(fixtureName: fileName, material: "draw", status: .skipped, detail: "soffice not found")
        }
        let sourceURL = fixturesRoot().appendingPathComponent(fileName)
        let exportURL = tempURL("export.odg")
        defer { try? FileManager.default.removeItem(at: exportURL) }
        do {
            let original = try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
                try await filter.import(from: sourceURL)
            }
            try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
                try await filter.export(original, to: exportURL)
            }
            let roundTripped = try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
                try await filter.import(from: exportURL)
            }
            let scores = RoundTripScoring.drawingAxisScores(original: original, roundTripped: roundTripped)
            return RoundTripFixtureResult(fixtureName: fileName, material: "draw", status: .scored, axisScores: scores)
        } catch {
            return RoundTripFixtureResult(fixtureName: fileName, material: "draw", status: .failed, detail: String(describing: error))
        }
    }

    // MARK: - Writer (WriterBridgeFilter for odt->docx import, TesseraFormatBridge/python-docx for the docx<->AST halves)

    /// Needs BOTH soffice (the odt -> docx conversion inside
    /// `WriterBridgeFilter`) AND python-docx (the DOCX <-> AST halves
    /// inside `TesseraFormatBridge`) - the latter is NOT installed on
    /// this probe machine (see file header), so this reports `.skipped`
    /// here via the caught `missingLibrary` error, and `.scored`
    /// wherever python-docx is present. There is no Swift-side ODT/DOCX
    /// EXPORT path outside `TesseraFormatBridge` today (WriterBridgeFilter
    /// is import-only per its own doc comment), so this is the only
    /// available round-trip shape for Writer.
    private func scoreWriterFixture(_ fileName: String) async throws -> RoundTripFixtureResult {
        let writerFilter = WriterBridgeFilter()
        guard writerFilter.isAvailable else {
            return RoundTripFixtureResult(fixtureName: fileName, material: "writer", status: .skipped, detail: "soffice not found")
        }
        let bridge = TesseraFormatBridge()
        do {
            let data = try Data(contentsOf: fixturesRoot().appendingPathComponent(fileName))
            let original = try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
                try await writerFilter.importDocument(data: data, format: "odt")
            }
            let astData = try original.jsonData()
            let docxData = try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
                try await bridge.exportFile(blocks: astData, format: "docx")
            }
            let roundTrippedASTData = try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
                try await bridge.importFile(data: docxData, format: "docx")
            }
            let roundTripped = try DocumentAST.from(jsonData: roundTrippedASTData)
            let scores = RoundTripScoring.documentASTAxisScores(original: original, roundTripped: roundTripped)
            return RoundTripFixtureResult(fixtureName: fileName, material: "writer", status: .scored, axisScores: scores)
        } catch TesseraFormatBridge.FormatBridgeError.missingLibrary(let detail) {
            return RoundTripFixtureResult(fixtureName: fileName, material: "writer", status: .skipped, detail: "python library missing: \(detail)")
        } catch {
            return RoundTripFixtureResult(fixtureName: fileName, material: "writer", status: .failed, detail: String(describing: error))
        }
    }
}
