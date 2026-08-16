import XCTest
@testable import TesseraCore

// MARK: - MacroToolsTests
//
// Contract: this track's brief (P2-D item 2.13) + testing-doctrine.md's
// Agent tool coverage shape ("schema round-trip + tier assertion +
// receipt behavior + denial path") + `DocToolsTests.swift` (this same
// wave, same "DocStore withheld" constraint) for the exact shape a
// closure-context tool's tests follow, including the shared-context
// install/teardown pattern and "argument validation before the context
// check" ordering.
//
// GATING: none of these tests touch a real DocStore - `MacroToolContext`
// is closure-based specifically so none of them need to. The "success
// path" tests install an in-memory stub loader/translator standing in
// for the future real `DocStore.translateMacro(for:outlines:)` wiring
// (see this wave's wiringNotes). Nothing here is gated.
//
// Trap test (testing-doctrine.md rule 5): "no macro_run tool at any
// tier, ever" is pinned as an independent hardcoded assertion below
// (`testExactlyThreeMacroToolsExistAndNoneIsMacroRun`), not derived from
// this file's own tool list.

final class MacroToolsTests: DoctrineTestCase {

    override func tearDown() {
        MacroToolContext.shared.install(loader: nil, translator: nil)
        super.tearDown()
    }

    private let module1Source = """
        Attribute VB_Name = "Module1"
        ' Does a thing.
        Public Sub Foo(x As Integer)
            Shell "cmd.exe"
        End Sub
        """

    private func fixtureDoc() -> Doc {
        let bin = makeMinimalVBAProjectBin(modules: [
            MacroFixtureModule(streamName: "Module1", sourceText: module1Source),
        ])
        var parts = PreservedParts()
        parts["word/vbaProject.bin"] = bin
        return Doc(title: "Has Macros", body: .empty, preservedParts: parts)
    }

    // MARK: - schema round-trip (doctrine rule 2 applied to Agent tool coverage)

    func testMacroListToolSchemaRoundTripsThroughJSON() throws {
        let tool = MacroListTool()
        let data = try JSONEncoder().encode(tool.parameters)
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, tool.parameters)
        XCTAssertEqual(tool.name, "macro_list")
        XCTAssertFalse(tool.description.isEmpty)
        XCTAssertEqual(tool.parameters.required ?? [], ["doc_id"])
    }

    func testMacroReadToolSchemaRoundTripsThroughJSON() throws {
        let tool = MacroReadTool()
        let data = try JSONEncoder().encode(tool.parameters)
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, tool.parameters)
        XCTAssertEqual(tool.name, "macro_read")
        XCTAssertFalse(tool.description.isEmpty)
        XCTAssertEqual(Set(tool.parameters.required ?? []), ["doc_id", "module_name"])
    }

    func testMacroTranslateToolSchemaRoundTripsThroughJSON() throws {
        let tool = MacroTranslateTool()
        let data = try JSONEncoder().encode(tool.parameters)
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, tool.parameters)
        XCTAssertEqual(tool.name, "macro_translate")
        XCTAssertFalse(tool.description.isEmpty)
        XCTAssertEqual(tool.parameters.required ?? [], ["doc_id"])
        XCTAssertNotNil(tool.parameters.properties?["module_name"], "module_name must be present but optional")
    }

    // MARK: - trap: no macro_run tool, ever (testing-doctrine.md rule 5)

    func testExactlyThreeMacroToolsExistAndNoneIsMacroRun() {
        let names = Set([MacroListTool().name, MacroReadTool().name, MacroTranslateTool().name])
        XCTAssertEqual(names, ["macro_list", "macro_read", "macro_translate"])
        XCTAssertFalse(names.contains("macro_run"))
    }

    // MARK: - tier assertion

    func testMacroListToolDefaultApprovalLevelIsAuto() {
        XCTAssertEqual(MacroListTool().defaultApprovalLevel, .auto)
        XCTAssertEqual(TesseraTier.tier0.displayName, "Tier 0 (auto)")
    }

    func testMacroReadToolDefaultApprovalLevelIsAuto() {
        XCTAssertEqual(MacroReadTool().defaultApprovalLevel, .auto)
    }

    func testMacroTranslateToolDefaultApprovalLevelIsPrompt() {
        XCTAssertEqual(MacroTranslateTool().defaultApprovalLevel, .prompt)
        XCTAssertEqual(TesseraTier.tier1.displayName, "Tier 1 (notify)")
    }

    // MARK: - denial path: no context installed

    func testMacroListToolFailsCleanlyWithNoContextInstalled() async throws {
        let result = try await MacroListTool().execute(arguments: ["doc_id": .string(UUID().uuidString)])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, MacroToolError.noContext.errorDescription)
    }

    func testMacroReadToolFailsCleanlyWithNoContextInstalled() async throws {
        let result = try await MacroReadTool().execute(arguments: [
            "doc_id": .string(UUID().uuidString),
            "module_name": .string("Module1"),
        ])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, MacroToolError.noContext.errorDescription)
    }

    func testMacroTranslateToolFailsCleanlyWithNoContextInstalled() async throws {
        let result = try await MacroTranslateTool().execute(arguments: ["doc_id": .string(UUID().uuidString)])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, MacroToolError.noContext.errorDescription)
    }

    func testMacroTranslateToolFailsCleanlyWithNoTranslatorInstalledEvenWhenLoaderIs() async throws {
        let doc = fixtureDoc()
        MacroToolContext.shared.install(loader: { id in id == doc.id ? doc : nil }, translator: nil)
        let result = try await MacroTranslateTool().execute(arguments: ["doc_id": .string(doc.id.uuidString)])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, MacroToolError.noTranslator.errorDescription)
    }

    // MARK: - denial path: malformed arguments (fails before touching the context)

    func testMacroListToolFailsCleanlyWithNonUUIDDocID() async throws {
        let result = try await MacroListTool().execute(arguments: ["doc_id": .string("not-a-uuid")])
        XCTAssertFalse(result.success)
        XCTAssertNotEqual(result.error, MacroToolError.noContext.errorDescription, "must fail on argument parsing, not reach the context check")
    }

    func testMacroReadToolFailsCleanlyWithMissingModuleName() async throws {
        let result = try await MacroReadTool().execute(arguments: ["doc_id": .string(UUID().uuidString)])
        XCTAssertFalse(result.success)
        XCTAssertNotEqual(result.error, MacroToolError.noContext.errorDescription)
    }

    func testMacroTranslateToolFailsCleanlyWithNonUUIDDocID() async throws {
        let result = try await MacroTranslateTool().execute(arguments: ["doc_id": .string("not-a-uuid")])
        XCTAssertFalse(result.success)
        XCTAssertNotEqual(result.error, MacroToolError.noContext.errorDescription)
    }

    // MARK: - denial path: doc not found / no preserved macro project

    func testMacroListToolFailsCleanlyWhenDocNotFound() async throws {
        MacroToolContext.shared.install(loader: { _ in nil }, translator: nil)
        let result = try await MacroListTool().execute(arguments: ["doc_id": .string(UUID().uuidString)])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, MacroToolError.docNotFound.errorDescription)
    }

    func testMacroListToolFailsCleanlyWhenDocHasNoPreservedMacroProject() async throws {
        let doc = Doc(title: "No Macros", body: .empty)
        MacroToolContext.shared.install(loader: { id in id == doc.id ? doc : nil }, translator: nil)
        let result = try await MacroListTool().execute(arguments: ["doc_id": .string(doc.id.uuidString)])
        XCTAssertFalse(result.success)
    }

    // MARK: - success path: in-memory stub context

    func testMacroListToolReportsEveryPreservedModuleWithItsSignatures() async throws {
        let doc = fixtureDoc()
        MacroToolContext.shared.install(loader: { id in id == doc.id ? doc : nil }, translator: nil)

        let result = try await MacroListTool().execute(arguments: ["doc_id": .string(doc.id.uuidString)])

        XCTAssertTrue(result.success)
        guard case .array(let modules)? = result.data?["modules"] else {
            return XCTFail("expected modules array")
        }
        XCTAssertEqual(modules.count, 1)
        guard case .object(let entry)? = modules.first else {
            return XCTFail("expected an object entry")
        }
        XCTAssertEqual(entry["moduleName"]?.stringValue, "Module1")
        guard case .array(let subs)? = entry["subroutines"], case .object(let sub)? = subs.first else {
            return XCTFail("expected subroutines array")
        }
        XCTAssertEqual(sub["name"]?.stringValue, "Foo")
        XCTAssertEqual(sub["kind"]?.stringValue, "Sub")
    }

    func testMacroReadToolReturnsOutlineAndDecompressedSourceForOneModule() async throws {
        let doc = fixtureDoc()
        MacroToolContext.shared.install(loader: { id in id == doc.id ? doc : nil }, translator: nil)

        let result = try await MacroReadTool().execute(arguments: [
            "doc_id": .string(doc.id.uuidString),
            "module_name": .string("Module1"),
        ])

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?["moduleName"]?.stringValue, "Module1")
        XCTAssertEqual(result.data?["calledAPIs"], .array([.string("Shell")]))
        XCTAssertEqual(result.data?["sourceText"]?.stringValue, module1Source)
        guard case .array(let subs)? = result.data?["subroutines"], case .object(let sub)? = subs.first else {
            return XCTFail("expected subroutines array")
        }
        XCTAssertEqual(sub["name"]?.stringValue, "Foo")
    }

    func testMacroReadToolFailsCleanlyForAnUnknownModuleName() async throws {
        let doc = fixtureDoc()
        MacroToolContext.shared.install(loader: { id in id == doc.id ? doc : nil }, translator: nil)

        let result = try await MacroReadTool().execute(arguments: [
            "doc_id": .string(doc.id.uuidString),
            "module_name": .string("DoesNotExist"),
        ])

        XCTAssertFalse(result.success)
    }

    func testMacroTranslateToolWritesThroughStubTranslatorAndReportsPlaybooks() async throws {
        let doc = fixtureDoc()
        var translatorCalledWith: [VBAModuleOutline] = []
        MacroToolContext.shared.install(
            loader: { id in id == doc.id ? doc : nil },
            translator: { docID, outlines in
                translatorCalledWith = outlines
                XCTAssertEqual(docID, doc.id)
                return doc // stands in for DocStore.translateMacro's persisted result
            }
        )

        let result = try await MacroTranslateTool().execute(arguments: ["doc_id": .string(doc.id.uuidString)])

        XCTAssertTrue(result.success)
        XCTAssertEqual(translatorCalledWith.map(\.moduleName), ["Module1"])
        XCTAssertEqual(result.data?["moduleNames"], .array([.string("Module1")]))
        guard case .array(let playbooks)? = result.data?["playbooks"], case .object(let entry)? = playbooks.first else {
            return XCTFail("expected playbooks array")
        }
        XCTAssertEqual(entry["sourceModuleName"]?.stringValue, "Module1")
        XCTAssertTrue(result.output.contains("No macro code was executed"))
    }

    func testMacroTranslateToolScopesToASingleNamedModuleWhenGiven() async throws {
        let bin = makeMinimalVBAProjectBin(modules: [
            MacroFixtureModule(streamName: "Module1", sourceText: module1Source),
            MacroFixtureModule(streamName: "ThisDocument", sourceText: "Attribute VB_Name = \"ThisDocument\"\nSub AutoOpen()\nEnd Sub\n"),
        ])
        var parts = PreservedParts()
        parts["word/vbaProject.bin"] = bin
        let doc = Doc(title: "Two Modules", body: .empty, preservedParts: parts)

        var translatorCalledWith: [VBAModuleOutline] = []
        MacroToolContext.shared.install(
            loader: { id in id == doc.id ? doc : nil },
            translator: { _, outlines in translatorCalledWith = outlines; return doc }
        )

        let result = try await MacroTranslateTool().execute(arguments: [
            "doc_id": .string(doc.id.uuidString),
            "module_name": .string("ThisDocument"),
        ])

        XCTAssertTrue(result.success)
        XCTAssertEqual(translatorCalledWith.map(\.moduleName), ["ThisDocument"])
    }

    func testMacroTranslateToolPropagatesTranslatorErrorAsFailure() async throws {
        let doc = fixtureDoc()
        struct StubError: LocalizedError { var errorDescription: String? { "stub translator failure" } }
        MacroToolContext.shared.install(
            loader: { id in id == doc.id ? doc : nil },
            translator: { _, _ in throw StubError() }
        )

        let result = try await MacroTranslateTool().execute(arguments: ["doc_id": .string(doc.id.uuidString)])

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "stub translator failure")
    }

    // MARK: - hard line: macro_translate never executes anything

    func testMacroTranslateToolNeverActuallyRunsTheShellCommandNamedInSource() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("macro-tool-never-execute-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let canaryPath = tempDir.appendingPathComponent("canary.txt").path

        let maliciousSource = """
            Attribute VB_Name = "Evil"
            Sub AutoOpen()
                Shell "/bin/sh -c 'touch \(canaryPath)'"
            End Sub
            """
        let bin = makeMinimalVBAProjectBin(modules: [MacroFixtureModule(streamName: "Evil", sourceText: maliciousSource)])
        var parts = PreservedParts()
        parts["word/vbaProject.bin"] = bin
        let doc = Doc(title: "Evil Doc", body: .empty, preservedParts: parts)

        MacroToolContext.shared.install(
            loader: { id in id == doc.id ? doc : nil },
            translator: { _, _ in doc }
        )

        let result = try await MacroTranslateTool().execute(arguments: ["doc_id": .string(doc.id.uuidString)])

        XCTAssertTrue(result.success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canaryPath), "macro_translate must never actually invoke Shell")
    }
}
