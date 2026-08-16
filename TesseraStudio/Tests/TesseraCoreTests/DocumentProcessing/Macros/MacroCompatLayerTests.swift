import XCTest
@testable import TesseraCore

// MARK: - MacroCompatLayerTests
//
// Contract: this track's brief (P2-D item 2.13) - the four-step pipeline
// (preserve -> decompress -> outline -> translate) plus the item's own
// hard line: "MacroCompatLayer NEVER executes a macro. There is no
// `macro_run` tool at any tier, ever." Item 5 explicitly requires an
// assertion that macro_translate never executes anything be a CONCRETE
// side-effect check, not just absence-of-crash - `testTranslate...Never
// ActuallyRunsTheShellCommandInSource` below plants a canary file path
// inside a module's own source text and asserts it was never created.

final class MacroCompatLayerTests: DoctrineTestCase {

    // MARK: - Step (a): preservedVBAProjectBytes

    func testPreservedVBAProjectBytesThrowsWhenNoPreservedPartsAtAll() {
        XCTAssertThrowsError(try MacroCompatLayer.preservedVBAProjectBytes(in: nil, hostKind: .word)) { error in
            XCTAssertEqual(error as? MacroCompatLayerError, .noPreservedVBAProject(key: "word/vbaProject.bin"))
        }
    }

    func testPreservedVBAProjectBytesThrowsWhenKeyAbsent() {
        let parts = PreservedParts(parts: ["xl/vbaProject.bin": Data([0x01])])
        XCTAssertThrowsError(try MacroCompatLayer.preservedVBAProjectBytes(in: parts, hostKind: .word)) { error in
            XCTAssertEqual(error as? MacroCompatLayerError, .noPreservedVBAProject(key: "word/vbaProject.bin"))
        }
    }

    func testPreservedVBAProjectBytesReturnsStoredBytesUnmodified() throws {
        let payload = Data([0x01, 0x02, 0x03])
        let parts = PreservedParts(parts: ["word/vbaProject.bin": payload])
        let bytes = try MacroCompatLayer.preservedVBAProjectBytes(in: parts, hostKind: .word)
        XCTAssertEqual(bytes, payload)
    }

    func testHostKindPreservedPartKeysMatchRealOOXMLPackagePaths() {
        XCTAssertEqual(MacroHostKind.word.preservedPartKey, "word/vbaProject.bin")
        XCTAssertEqual(MacroHostKind.excel.preservedPartKey, "xl/vbaProject.bin")
        XCTAssertEqual(MacroHostKind.powerpoint.preservedPartKey, "ppt/vbaProject.bin")
    }

    // MARK: - Steps (a)-(c): full pipeline over a CFBF fixture

    private let module1Source = """
        Attribute VB_Name = "Module1"
        ' Does a thing.
        Public Sub Foo(x As Integer)
            Shell "cmd.exe"
        End Sub
        """

    private let module2Source = """
        Attribute VB_Name = "ThisDocument"
        Sub AutoOpen()
            CreateObject "Word.Application"
        End Sub
        """

    func testModuleOutlinesExtractsEveryModuleFromACFBFFixture() throws {
        let bin = makeMinimalVBAProjectBin(modules: [
            MacroFixtureModule(streamName: "Module1", sourceText: module1Source),
            MacroFixtureModule(streamName: "ThisDocument", sourceText: module2Source),
        ])
        let outlines = try MacroCompatLayer.moduleOutlines(fromVBAProjectBin: bin)
        XCTAssertEqual(Set(outlines.map(\.moduleName)), ["Module1", "ThisDocument"])
        let module1 = try XCTUnwrap(outlines.first { $0.moduleName == "Module1" })
        XCTAssertEqual(module1.subroutines.count, 1)
        XCTAssertEqual(module1.calledAPIs, ["Shell"])
    }

    func testModuleOutlinesHandlesASingleModuleFixture() throws {
        let bin = makeMinimalVBAProjectBin(modules: [
            MacroFixtureModule(streamName: "Module1", sourceText: module1Source),
        ])
        let outlines = try MacroCompatLayer.moduleOutlines(fromVBAProjectBin: bin)
        XCTAssertEqual(outlines.count, 1)
    }

    func testModuleOutlinesHandlesAThreeModuleFixtureSpanningTwoDirectorySectors() throws {
        // 2 (Root+VBA) + 3 modules = 5 directory entries, > 4 entries per
        // 512-byte directory sector - exercises directory CHAIN traversal
        // in CFBFReader, not just a single sector.
        let bin = makeMinimalVBAProjectBin(modules: [
            MacroFixtureModule(streamName: "Module1", sourceText: module1Source),
            MacroFixtureModule(streamName: "ThisDocument", sourceText: module2Source),
            MacroFixtureModule(streamName: "Sheet1", sourceText: "Attribute VB_Name = \"Sheet1\"\nSub S1()\nEnd Sub\n"),
        ])
        let outlines = try MacroCompatLayer.moduleOutlines(fromVBAProjectBin: bin)
        XCTAssertEqual(Set(outlines.map(\.moduleName)), ["Module1", "ThisDocument", "Sheet1"])
    }

    func testModuleOutlinesHandlesAModuleLargerThanTheMiniStreamCutoff() throws {
        // Forces CFBFReader's REGULAR FAT stream path (streamSize >=
        // 4096), not the mini-stream/mini-FAT path every other fixture
        // in this file exercises.
        let manyRoutines = (1...80).map { "Sub Routine\($0)()\nEnd Sub\n" }.joined()
        let bigSource = "Attribute VB_Name = \"BigModule\"\n" + manyRoutines
        let bin = makeMinimalVBAProjectBin(modules: [
            MacroFixtureModule(streamName: "BigModule", sourceText: bigSource, prefixGarbage: Data(repeating: 0xAB, count: 4200)),
        ])
        let outlines = try MacroCompatLayer.moduleOutlines(fromVBAProjectBin: bin)
        XCTAssertEqual(outlines.count, 1)
        XCTAssertEqual(outlines.first?.subroutines.count, 80)
    }

    func testModuleOutlinesThrowsWhenOnlyNonModuleStreamsArePresent() throws {
        // A stream literally named "dir" is excluded by `isModuleStream`
        // - simulating a VBA storage with no actual code modules.
        let bin = makeMinimalVBAProjectBin(modules: [
            MacroFixtureModule(streamName: "dir", sourceText: "Attribute VB_Name = \"dir\"\n"),
        ])
        XCTAssertThrowsError(try MacroCompatLayer.moduleOutlines(fromVBAProjectBin: bin)) { error in
            XCTAssertEqual(error as? MacroCompatLayerError, .noExtractableModules)
        }
    }

    func testModuleOutlinesThrowsCFBFErrorForNonCompoundFileInput() {
        XCTAssertThrowsError(try MacroCompatLayer.moduleOutlines(fromVBAProjectBin: Data([0x00, 0x01, 0x02, 0x03]))) { error in
            XCTAssertEqual(error as? MacroCompatLayerError, .cfbf(.notACompoundFile))
        }
    }

    func testIsModuleStreamExcludesKnownNonModuleStreamNames() {
        XCTAssertFalse(MacroCompatLayer.isModuleStream(named: "dir"))
        XCTAssertFalse(MacroCompatLayer.isModuleStream(named: "_VBA_PROJECT"))
        XCTAssertFalse(MacroCompatLayer.isModuleStream(named: "__SRP_0"))
        XCTAssertTrue(MacroCompatLayer.isModuleStream(named: "Module1"))
        XCTAssertTrue(MacroCompatLayer.isModuleStream(named: "ThisDocument"))
    }

    func testDecompressedSourceTextSkipsOverPrefixGarbageToFindTheRealSignature() {
        let compressed = makeLiteralOnlyOVBAContainer(Data("Sub X()\nEnd Sub\n".utf8))
        let streamBytes = Data([0xDE, 0xAD, 0xBE, 0xEF]) + compressed
        let text = MacroCompatLayer.decompressedSourceText(fromModuleStream: streamBytes)
        XCTAssertEqual(text, "Sub X()\nEnd Sub\n")
    }

    func testDecompressedSourceTextReturnsNilWhenNoValidContainerExists() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        XCTAssertNil(MacroCompatLayer.decompressedSourceText(fromModuleStream: garbage))
    }

    // MARK: - Step (d): translate

    func testTranslateProducesAHumanSummaryNamingTheModuleAndItsRoutines() {
        let outline = VBAOutlineParser.parse(source: module1Source, fallbackModuleName: "x")
        let playbook = MacroCompatLayer.translate(outline)
        XCTAssertEqual(playbook.sourceModuleName, "Module1")
        XCTAssertTrue(playbook.humanSummary.contains("Foo"))
        XCTAssertTrue(playbook.humanSummary.contains("never executed"))
        XCTAssertEqual(playbook.calledAPIs, ["Shell"])
    }

    func testTranslateArrayOverloadMapsEachOutlineToItsOwnPlaybookInOrder() {
        let outlines = [
            VBAOutlineParser.parse(source: module1Source, fallbackModuleName: "x"),
            VBAOutlineParser.parse(source: module2Source, fallbackModuleName: "y"),
        ]
        let playbooks = MacroCompatLayer.translate(outlines)
        XCTAssertEqual(playbooks.map(\.sourceModuleName), ["Module1", "ThisDocument"])
    }

    func testTranslateIsDeterministicForTheSameOutline() {
        let outline = VBAOutlineParser.parse(source: module1Source, fallbackModuleName: "x")
        let first = MacroCompatLayer.translate(outline)
        let second = MacroCompatLayer.translate(outline)
        XCTAssertEqual(first, second)
    }

    func testTranslateMapsShellToAManualReviewSuggestionNotATesseraToolCall() {
        let outline = VBAOutlineParser.parse(source: module1Source, fallbackModuleName: "x")
        let playbook = MacroCompatLayer.translate(outline)
        XCTAssertTrue(playbook.suggestedToolCalls.contains { $0.lowercased().contains("review manually") })
    }

    func testTranslateFallsBackToAGenericSuggestionWhenNoAPIsAreCalled() {
        let outline = VBAOutlineParser.parse(source: "Sub Quiet()\n    Dim x As Integer\nEnd Sub\n", fallbackModuleName: "x")
        let playbook = MacroCompatLayer.translate(outline)
        XCTAssertEqual(playbook.suggestedToolCalls.count, 1)
        XCTAssertTrue(playbook.suggestedToolCalls[0].contains("no recognized automation APIs"))
    }

    // MARK: - Hard line: never executes anything (explicit side-effect assertion)

    func testTranslateNeverActuallyRunsAShellCommandNamedInModuleSource() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("macro-never-execute-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let canaryPath = tempDir.appendingPathComponent("canary.txt").path

        let maliciousSource = """
            Attribute VB_Name = "Evil"
            Sub AutoOpen()
                Shell "/bin/sh -c 'touch \(canaryPath)'"
            End Sub
            """
        let outline = VBAOutlineParser.parse(source: maliciousSource, fallbackModuleName: "Evil")
        XCTAssertEqual(outline.calledAPIs, ["Shell"])

        let playbook = MacroCompatLayer.translate(outline)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: canaryPath),
            "translate() must never actually invoke Shell - the canary file the source text names must not exist"
        )
        XCTAssertTrue(playbook.humanSummary.contains("never executed"))
    }

    func testFullPipelineFromCFBFFixtureThroughTranslateNeverExecutesAnything() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("macro-never-execute-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let canaryPath = tempDir.appendingPathComponent("canary.txt").path

        let maliciousSource = """
            Attribute VB_Name = "Evil"
            Sub AutoOpen()
                Shell "/bin/sh -c 'touch \(canaryPath)'"
                Kill "\(canaryPath)"
            End Sub
            """
        let bin = makeMinimalVBAProjectBin(modules: [
            MacroFixtureModule(streamName: "Evil", sourceText: maliciousSource),
        ])

        let outlines = try MacroCompatLayer.moduleOutlines(fromVBAProjectBin: bin)
        let playbooks = MacroCompatLayer.translate(outlines)

        XCTAssertFalse(FileManager.default.fileExists(atPath: canaryPath), "the full parse+preserve+translate pipeline must never execute Shell/Kill")
        XCTAssertEqual(Set(outlines.first?.calledAPIs ?? []), ["Shell", "Kill"])
        XCTAssertEqual(playbooks.count, 1)
    }
}
