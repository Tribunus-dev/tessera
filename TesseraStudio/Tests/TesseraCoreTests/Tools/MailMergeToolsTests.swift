import XCTest
@testable import TesseraCore

// MARK: - MailMergeToolsTests
//
// Contract: this track's brief (P2-C item 2.4/2.21) + testing-doctrine.md's
// Agent tool coverage shape ("schema round-trip + tier assertion + receipt
// behavior + denial path") + `TesseraTool`'s protocol doc comments
// (Sources/TesseraCore/Agent/TesseraTool.swift) + `SheetGoalSeekTool`/
// `SheetSolverRunTool` (Tests/.../Tools/SheetSolverToolsTests.swift) for
// the exact shape a store-backed tool's tests follow, including reusing
// the shared-context install/teardown pattern.
//
// GATING: the schema round-trip, tier assertion, and denial-path (no
// coordinator installed) tests are fully ungated - none of them touches
// a store. The one full "receipt behavior" test that actually runs a
// merge is gated on `TESSERA_DB_INTEGRATION=1`, same reasoning as
// `MailMergeCoordinatorTests.swift`'s `MailMergeCoordinatorRunTests`
// (live DocStore/SheetStore + a real `/usr/bin/textutil` shell-out via
// DocumentExporter.export).

final class MailMergeToolsTests: DoctrineTestCase {
    // The gated success-path test below shells out to /usr/bin/textutil
    // (via DocumentExporter.export through the coordinator); raising the
    // whole class's watchdog to the probe allowance costs the fast
    // ungated tests nothing (an upper bound, not a forced wait).
    override var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.probe }

    override func tearDown() {
        MailMergeToolContext.shared.install(nil)
        super.tearDown()
    }

    // MARK: - schema round-trip (doctrine rule 2 applied to Agent tool coverage)

    func testMergeRunToolSchemaRoundTripsThroughJSON() throws {
        let tool = MailMergeRunTool()
        let data = try JSONEncoder().encode(tool.parameters)
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, tool.parameters)
        XCTAssertEqual(tool.name, "merge_run")
        XCTAssertFalse(tool.description.isEmpty)
        XCTAssertEqual(Set(tool.parameters.required ?? []), ["template_doc_id", "source_entity_id"])
        XCTAssertNotNil(tool.parameters.properties?["output_format"])
        XCTAssertNotNil(tool.parameters.properties?["destination_directory"])
    }

    // MARK: - tier assertion

    /// Tier2 per the design contract's own "fan-out blast radius"
    /// reasoning (studio-expansion-design-refinement-2026-08-14.md 5);
    /// `TesseraTier.tier2.displayName` is "Tier 2 (approval)"
    /// (Agent/TesseraTier.swift), which this tool's `defaultApprovalLevel`
    /// matches directly (`.prompt`) - same pattern
    /// `SheetSolverToolsTests.testGoalSeekToolDefaultApprovalLevelIsNotify`
    /// uses for tier1/`.notify`.
    func testMergeRunToolDefaultApprovalLevelIsPrompt() {
        XCTAssertEqual(MailMergeRunTool().defaultApprovalLevel, .prompt)
        XCTAssertEqual(TesseraTier.tier2.displayName, "Tier 2 (approval)")
    }

    // MARK: - denial path: no coordinator installed

    func testMergeRunToolFailsCleanlyWithNoCoordinatorInstalled() async throws {
        MailMergeToolContext.shared.install(nil)
        let result = try await MailMergeRunTool().execute(arguments: [
            "template_doc_id": .string(UUID().uuidString),
            "source_entity_id": .string(UUID().uuidString),
        ])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, MailMergeToolError.noCoordinator.errorDescription)
    }

    // MARK: - denial path: malformed arguments (fails before touching the coordinator)

    func testMergeRunToolFailsCleanlyWithNonUUIDTemplateID() async throws {
        let result = try await MailMergeRunTool().execute(arguments: [
            "template_doc_id": .string("not-a-uuid"),
            "source_entity_id": .string(UUID().uuidString),
        ])
        XCTAssertFalse(result.success)
    }

    func testMergeRunToolFailsCleanlyWithNonUUIDSourceID() async throws {
        let result = try await MailMergeRunTool().execute(arguments: [
            "template_doc_id": .string(UUID().uuidString),
            "source_entity_id": .string("not-a-uuid"),
        ])
        XCTAssertFalse(result.success)
    }

    func testMergeRunToolFailsCleanlyWithUnrecognizedOutputFormat() async throws {
        let result = try await MailMergeRunTool().execute(arguments: [
            "template_doc_id": .string(UUID().uuidString),
            "source_entity_id": .string(UUID().uuidString),
            "output_format": .string("txt"),
        ])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("docx") ?? false, "the failure must name the allowed formats")
    }

    func testMergeRunToolDefaultsOutputFormatToPdf() async throws {
        // No coordinator installed, so this still fails - but it must
        // fail on `noCoordinator`, proving `output_format` defaulted to
        // "pdf" and parsed successfully rather than failing argument
        // validation first.
        let result = try await MailMergeRunTool().execute(arguments: [
            "template_doc_id": .string(UUID().uuidString),
            "source_entity_id": .string(UUID().uuidString),
        ])
        XCTAssertEqual(result.error, MailMergeToolError.noCoordinator.errorDescription)
    }

    // MARK: - receipt behavior (gated: live coordinator, real merge)

    func testMergeRunToolReportsRecordCountAndOutputDocIDsOnSuccess() async throws {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip("gated: set TESSERA_DB_INTEGRATION=1 - see MailMergeCoordinatorTests.swift's MailMergeCoordinatorRunTests for the full rationale (live DB + real textutil shell-out).")
        }
        let dataLayer = TesseraDataLayer()
        _ = await dataLayer.start()
        let docStore = DocStore(dataLayer: dataLayer)
        let sheetStore = SheetStore(dataLayer: dataLayer)
        MailMergeToolContext.shared.install(MailMergeCoordinator(docStore: docStore, sheetStore: sheetStore))

        var ast = DocumentAST()
        let fieldID = UUID()
        var field = Block(id: fieldID, type: .field)
        field.field = FieldSpec(kind: .mergeField(name: "FirstName"))
        ast.blocks[fieldID] = field
        ast.rootChildren = [fieldID]
        let template = try await docStore.upsert(Doc(title: "Template", body: ast))

        var sheet = Sheet.makeBlank(title: "Contacts", rows: 2, cols: 1)
        sheet.columns = [SheetColumn(label: "FirstName")]
        sheet = sheet.settingCellText(row: 0, col: 0, "Ada")
        sheet = sheet.settingCellText(row: 1, col: 0, "Alan")
        let storedSheet = try await sheetStore.upsert(sheet)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mail-merge-tool-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = try await MailMergeRunTool().execute(arguments: [
            "template_doc_id": .string(template.id.uuidString),
            "source_entity_id": .string(storedSheet.id.uuidString),
            "output_format": .string("pdf"),
            "destination_directory": .string(tempDir.path),
        ])

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?["record_count"]?.numberValue, 2)
        if case .array(let ids)? = result.data?["output_doc_ids"] {
            XCTAssertEqual(ids.count, 2)
        } else {
            XCTFail("expected output_doc_ids to be present")
        }
        XCTAssertNotNil(result.data?["source_hash"]?.stringValue)
    }
}
