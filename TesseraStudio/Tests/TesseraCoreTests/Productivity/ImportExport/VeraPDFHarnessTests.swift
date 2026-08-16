import XCTest
@testable import TesseraCore

// MARK: - VeraPDFHarnessTests
//
// Item 2.20 (5): the veraPDF CI acceptance harness. Exports a small
// fixture corpus with the tagged-PDF option on, then shells out to
// `verapdf --flavour ua1 <file>` and asserts zero machine-checkable
// Matterhorn failures (87 of 136 conditions are machine-decidable per
// this wave's own contract text - the automatable subset; the 47
// human-judgment conditions are NOT this harness's job and get a
// documented manual checklist instead, below).
//
// GATING (doctrine rules 10 + 11): dev-time-only Java dependency, NEVER
// shipped in the app (this wave's own file-list note). Gated behind
// TESSERA_VERAPDF_HARNESS=1, mirroring TESSERA_DB_INTEGRATION=1 /
// TESSERA_CORPUS_HARNESS=1's established opt-in-gate convention - never
// part of the default suite. Degrades gracefully - SKIPS with a clear
// message, never fails the whole suite - when either `verapdf` or
// `soffice` is not found on this machine, checked independently of the
// env-var gate itself (so a CI box with the env var set but no veraPDF
// installed still gets a clean skip, not a hard failure).
//
// HONESTY NOTE (required by this track's own brief - "don't overclaim a
// green run you couldn't actually observe"): `verapdf` was CONFIRMED
// ABSENT on this development machine (checked via `which verapdf` plus
// every common install path this file also checks at runtime - see
// `resolveVeraPDFPath()`) at the time this file was written. This
// harness has therefore NEVER actually executed against real veraPDF
// output in this environment - only `soffice` (present) and the export
// pipeline it drives were exercised directly, in
// PDFAccessibilityFilterOptionsProbeTests.swift. The exact shape of
// veraPDF's CLI stdout is intentionally NOT parsed here beyond its exit
// code (the one behavior documented with confidence at
// docs.verapdf.org/validation - 0 for a compliant file, non-zero
// otherwise); a first real run on a machine with veraPDF installed
// should confirm that convention and is the moment this comment's
// "never actually executed" claim gets to change, per rule 10's own
// "re-verification happens by re-running, not by trusting the comment."
//
// Given PDFAccessibilityFilterOptionsProbeTests.swift's own confirmed
// finding (explicit FilterData currently produces an UNTAGGED pdf on
// this LO install, a LibreOffice CLI defect - see that file's header),
// the compliance assertion below is wrapped in XCTExpectFailure with the
// SAME suspected-bug note: this harness is expected to report
// non-compliance today, for the identical upstream reason, not because
// Tessera's own filter-options plumbing is wrong. Flips to a hard
// assertion the moment that LO defect is fixed and this wrapping is
// removed.

final class VeraPDFHarnessTests: DoctrineTestCase {
    override var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.corpusProbe }

    /// Same resolution strategy as `LibreOfficeConverter
    /// .resolveSofficePath()`: common install locations checked first,
    /// falling back to `which` via a subprocess (covers a `verapdf`
    /// shell script installed via package manager with no fixed path).
    private func resolveVeraPDFPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/verapdf",
            "/usr/local/bin/verapdf",
            "/usr/bin/verapdf",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["verapdf"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        guard (try? which.run()) != nil else { return nil }
        which.waitUntilExit()
        guard which.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    private struct VeraPDFResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func runVeraPDF(_ veraPDFPath: String, flavour: String, file: URL) throws -> VeraPDFResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: veraPDFPath)
        process.arguments = ["--flavour", flavour, file.path]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return VeraPDFResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// The fixture corpus: one small document per material this wave
    /// touches, built directly via each material's own Swift factory
    /// (`Doc`/`Sheet.makeBlank`/`Drawing.makeBlank`/`SlideDeck.makeBlank`)
    /// rather than the raw `Tests/.../Fixtures/RoundTrip/*.fodt` corpus.
    /// Design-judgment call, recorded for architect ratification in this
    /// wave's findings file: those fixtures are hand-authored ODF XML
    /// for FlatODFReader/Writer wire-format pinning (a different test
    /// suite's contract), not `Doc`/`Sheet`/`Drawing`/`SlideDeck` values
    /// this item's own export methods take - routing through them would
    /// need an ODF->Doc import bridge this track does not own or build.
    /// Reusing the exact SAME small shapes this wave's own probe test
    /// (PDFAccessibilityFilterOptionsProbeTests.swift) already
    /// constructs keeps exactly one fixture definition, not two.
    private func writerFixturePDF(destination: URL) async throws -> URL {
        var ast = DocumentAST()
        let headingID = UUID()
        let paragraphID = UUID()
        ast.blocks[headingID] = Block(id: headingID, type: .heading, attributes: ["level": .number(1)], content: [InlineRun(text: "veraPDF Fixture")])
        ast.blocks[paragraphID] = Block(id: paragraphID, type: .paragraph, content: [InlineRun(text: "Body text for the accessibility harness fixture.")])
        ast.rootChildren = [headingID, paragraphID]
        let doc = Doc(title: "veraPDF Fixture", body: ast)
        return try await DocumentExporter().export(doc, to: .pdf, destination: destination, accessibility: .pdfUA)
    }

    private func drawFixturePDF(destination: URL) async throws {
        let shape = Shape(kind: .rect, geometry: ShapeGeometry(x: 10, y: 10, width: 100, height: 60))
        let drawing = Drawing.makeBlank(title: "veraPDF Draw Fixture").insertingShape(shape)
        try await PDFExportBridge().export(drawing, to: destination, accessibility: .pdfUA)
    }

    private func impressFixturePDF(destination: URL) async throws {
        let deck = SlideDeck.makeBlank(title: "veraPDF Impress Fixture")
        try await LOBridgeDeckIO().exportDeck(deck, to: destination, format: .pdf, accessibility: .pdfUA)
    }

    private func calcFixturePDF() async throws -> Data {
        var sheet = Sheet.makeBlank(title: "veraPDF Calc Fixture", rows: 2, cols: 2)
        sheet = sheet.settingCellText(row: 0, col: 0, "Header")
        sheet = sheet.settingCellText(row: 1, col: 0, "Value")
        return try await CalcBridgeFilter().exportPDF(sheet, accessibility: .pdfUA)
    }

    /// The manual checklist for the 47 human-judgment Matterhorn
    /// conditions this harness cannot automate (reading order that
    /// "makes sense", alt text that is actually DESCRIPTIVE rather than
    /// merely present, color contrast intent, etc.) - see this file's
    /// own header. Not executable; a documentation anchor so a reviewer
    /// knows where the automatable/manual line was drawn and why.
    static let manualMatterhornChecklistNote = """
        veraPDF --flavour ua1 covers the 87 machine-decidable Matterhorn \
        1.1 checkpoints. The remaining 47 need human judgment and are NOT \
        covered by this harness: reading-order sensibility, alt-text \
        descriptiveness (vs. merely present), table header/data cell \
        association correctness beyond structural tagging, link purpose \
        clarity from context, and color-alone-conveys-meaning review. A \
        human reviewer should walk this list against any document bound \
        for procurement/compliance sign-off; the harness's PASS is \
        necessary, not sufficient.
        """

    func testFixtureCorpusPassesVeraPDFUA1Validation() async throws {
        guard ProcessInfo.processInfo.environment["TESSERA_VERAPDF_HARNESS"] == "1" else {
            throw XCTSkip("gated: set TESSERA_VERAPDF_HARNESS=1 to run the veraPDF PDF/UA-1 acceptance harness - a dev-time-only Java dependency, never part of the default suite (mirrors TESSERA_DB_INTEGRATION=1/TESSERA_CORPUS_HARNESS=1).")
        }
        guard let veraPDFPath = resolveVeraPDFPath() else {
            throw XCTSkip("veraPDF not installed, skipping (checked common install paths and `which verapdf` - see resolveVeraPDFPath()).")
        }
        guard LibreOfficeConverter().isAvailable else {
            throw XCTSkip("soffice not found on this machine - the harness needs it to produce the fixture corpus's PDFs.")
        }

        let corpusDir = FileManager.default.temporaryDirectory.appendingPathComponent("tessera-verapdf-corpus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: corpusDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: corpusDir) }

        let writerPDF = try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
            try await self.writerFixturePDF(destination: corpusDir.appendingPathComponent("writer-fixture.pdf"))
        }
        let drawPDF = corpusDir.appendingPathComponent("draw-fixture.pdf")
        try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
            try await self.drawFixturePDF(destination: drawPDF)
        }
        let impressPDF = corpusDir.appendingPathComponent("impress-fixture.pdf")
        try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
            try await self.impressFixturePDF(destination: impressPDF)
        }
        let calcData = try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
            try await self.calcFixturePDF()
        }
        let calcPDF = corpusDir.appendingPathComponent("calc-fixture.pdf")
        try calcData.write(to: calcPDF)

        let corpus = [
            ("writer", writerPDF),
            ("draw", drawPDF),
            ("impress", impressPDF),
            ("calc", calcPDF),
        ]

        var results: [(name: String, result: VeraPDFResult)] = []
        for (name, file) in corpus {
            results.append((name, try runVeraPDF(veraPDFPath, flavour: "ua1", file: file)))
        }

        for (name, result) in results {
            XCTExpectFailure("SUSPECTED LIBREOFFICE CLI BUG (not Tessera code): the \(name) fixture is exported with accessibility: .pdfUA, but its *_pdf_Export filter currently ignores that FilterData on LO 26.2.5.2 and produces an untagged PDF (confirmed in PDFAccessibilityFilterOptionsProbeTests.swift) - veraPDF is expected to report non-compliance until that upstream defect is fixed.") {
                XCTAssertEqual(result.exitCode, 0, "veraPDF --flavour ua1 reported non-compliance or an error for the \(name) fixture.\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)")
            }
        }
    }
}
