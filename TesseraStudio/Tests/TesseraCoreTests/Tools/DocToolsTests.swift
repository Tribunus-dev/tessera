import XCTest
@testable import TesseraCore

// MARK: - DocToolsTests
//
// Contract: this track's brief (P2-D item 2.15) + testing-doctrine.md's
// Agent tool coverage shape ("schema round-trip + tier assertion +
// receipt behavior + denial path") + `MailMergeToolsTests.swift` for
// the exact shape a store-backed tool's tests follow, including the
// shared-context install/teardown pattern and "argument validation
// before the context check" ordering.
//
// GATING: none of these tests touches a real DocStore (DocStore.swift
// is withheld from this track this wave - see this wave's wiringNotes);
// the "success path" tests below install an in-memory stub loader/
// filler built directly on FormController, standing in for the future
// real DocStore.fillForm(blockID:value:for:) wiring. Nothing here is
// gated - all of it exercises the tool's own request/response shape,
// which does not depend on a live store.

final class DocToolsTests: DoctrineTestCase {

    override func tearDown() {
        DocToolContext.shared.install(loader: nil, filler: nil)
        super.tearDown()
    }

    // MARK: - schema round-trip (doctrine rule 2 applied to Agent tool coverage)

    func testFieldsListToolSchemaRoundTripsThroughJSON() throws {
        let tool = DocFormFieldsListTool()
        let data = try JSONEncoder().encode(tool.parameters)
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, tool.parameters)
        XCTAssertEqual(tool.name, "doc_form_fields_list")
        XCTAssertFalse(tool.description.isEmpty)
        XCTAssertEqual(tool.parameters.required ?? [], ["doc_id"])
    }

    func testFillToolSchemaRoundTripsThroughJSON() throws {
        let tool = DocFormFillTool()
        let data = try JSONEncoder().encode(tool.parameters)
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, tool.parameters)
        XCTAssertEqual(tool.name, "doc_form_fill")
        XCTAssertFalse(tool.description.isEmpty)
        XCTAssertEqual(Set(tool.parameters.required ?? []), ["doc_id", "block_id", "value"])
    }

    // MARK: - tier assertion
    //
    // doc_form_fields_list is tier0 (read) - matches SheetReadTool's own
    // tier0/.auto pairing. doc_form_fill is tier1 (per-entity write) -
    // matches SheetWriteTool's own tier1/.prompt pairing. Per the design
    // contract's own tools/tiers line (sota-enterprise-report.md 2.15).

    func testFieldsListToolDefaultApprovalLevelIsAuto() {
        XCTAssertEqual(DocFormFieldsListTool().defaultApprovalLevel, .auto)
    }

    func testFillToolDefaultApprovalLevelIsPrompt() {
        XCTAssertEqual(DocFormFillTool().defaultApprovalLevel, .prompt)
        XCTAssertEqual(TesseraTier.tier1.displayName, "Tier 1 (notify)")
    }

    // MARK: - denial path: no context installed

    func testFieldsListToolFailsCleanlyWithNoContextInstalled() async throws {
        let result = try await DocFormFieldsListTool().execute(arguments: [
            "doc_id": .string(UUID().uuidString),
        ])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, DocToolError.noContext.errorDescription)
    }

    func testFillToolFailsCleanlyWithNoContextInstalled() async throws {
        let result = try await DocFormFillTool().execute(arguments: [
            "doc_id": .string(UUID().uuidString),
            "block_id": .string(UUID().uuidString),
            "value": .string("Ada"),
        ])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, DocToolError.noContext.errorDescription)
    }

    // MARK: - denial path: malformed arguments (fails before touching the context)

    func testFieldsListToolFailsCleanlyWithNonUUIDDocID() async throws {
        let result = try await DocFormFieldsListTool().execute(arguments: [
            "doc_id": .string("not-a-uuid"),
        ])
        XCTAssertFalse(result.success)
        XCTAssertNotEqual(result.error, DocToolError.noContext.errorDescription, "must fail on argument parsing, not reach the context check")
    }

    func testFillToolFailsCleanlyWithNonUUIDDocID() async throws {
        let result = try await DocFormFillTool().execute(arguments: [
            "doc_id": .string("not-a-uuid"),
            "block_id": .string(UUID().uuidString),
            "value": .string("Ada"),
        ])
        XCTAssertFalse(result.success)
        XCTAssertNotEqual(result.error, DocToolError.noContext.errorDescription)
    }

    func testFillToolFailsCleanlyWithNonUUIDBlockID() async throws {
        let result = try await DocFormFillTool().execute(arguments: [
            "doc_id": .string(UUID().uuidString),
            "block_id": .string("not-a-uuid"),
            "value": .string("Ada"),
        ])
        XCTAssertFalse(result.success)
        XCTAssertNotEqual(result.error, DocToolError.noContext.errorDescription)
    }

    func testFillToolFailsCleanlyWithMissingValue() async throws {
        let result = try await DocFormFillTool().execute(arguments: [
            "doc_id": .string(UUID().uuidString),
            "block_id": .string(UUID().uuidString),
        ])
        XCTAssertFalse(result.success)
        XCTAssertNotEqual(result.error, DocToolError.noContext.errorDescription)
    }

    // MARK: - denial path: doc not found

    func testFieldsListToolFailsCleanlyWhenDocNotFound() async throws {
        DocToolContext.shared.install(loader: { _ in nil }, filler: nil)
        let result = try await DocFormFieldsListTool().execute(arguments: [
            "doc_id": .string(UUID().uuidString),
        ])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, DocToolError.docNotFound.errorDescription)
    }

    // MARK: - success path: in-memory stub context
    //
    // Stands in for the real DocStore.fillForm(blockID:value:for:) this
    // wave's wiringNotes describe - the tool's own request/response
    // shape does not depend on which store backs it.

    private func fixtureDoc() -> (doc: Doc, blockID: UUID) {
        let blockID = UUID()
        var block = Block(id: blockID, type: .paragraph)
        block.contentControl = ContentControl(kind: .plainText, tag: "firstName", title: "First name")
        var ast = DocumentAST()
        ast.blocks[blockID] = block
        ast.rootChildren = [blockID]
        return (Doc(title: "Form", body: ast), blockID)
    }

    func testFieldsListToolReportsEveryControlWithResolvedValues() async throws {
        let (doc, blockID) = fixtureDoc()
        DocToolContext.shared.install(loader: { id in id == doc.id ? doc : nil }, filler: nil)

        let result = try await DocFormFieldsListTool().execute(arguments: ["doc_id": .string(doc.id.uuidString)])

        XCTAssertTrue(result.success)
        guard case .array(let fields)? = result.data?["fields"] else {
            return XCTFail("expected fields array in result.data")
        }
        XCTAssertEqual(fields.count, 1)
        guard case .object(let entry)? = fields.first else {
            return XCTFail("expected an object entry")
        }
        XCTAssertEqual(entry["blockID"]?.stringValue, blockID.uuidString)
        XCTAssertEqual(entry["tag"]?.stringValue, "firstName")
        XCTAssertEqual(entry["kind"]?.stringValue, "plainText")
        XCTAssertEqual(entry["title"]?.stringValue, "First name")
        XCTAssertEqual(entry["value"], .null, "never filled - value must be null, not empty string")
        XCTAssertEqual(entry["bound"]?.boolValue, false)
    }

    func testFieldsListToolFallsBackToBoundValueWhenNothingLocallyFilled() async throws {
        // The control is bound (binding set) but never locally filled
        // (no ContentControl.value, no host-block content) - the tool
        // must fall back to resolving the binding against the doc's own
        // preservedParts (DocFormToolSupport.effectiveValue), the
        // composition FormController.resolvedValue/formData deliberately
        // do not do themselves (see p2-d-findings-2.md item 4).
        let blockID = UUID()
        var block = Block(id: blockID, type: .paragraph)
        block.contentControl = ContentControl(kind: .dropDownList, tag: "status", listItems: ["Draft", "Final"], binding: "/root/status")
        var ast = DocumentAST()
        ast.blocks[blockID] = block
        ast.rootChildren = [blockID]

        var parts = PreservedParts()
        parts["customXml/item1.xml"] = Data("<root><status>Final</status></root>".utf8)
        let doc = Doc(title: "Bound form", body: ast, preservedParts: parts)

        DocToolContext.shared.install(loader: { id in id == doc.id ? doc : nil }, filler: nil)

        let result = try await DocFormFieldsListTool().execute(arguments: ["doc_id": .string(doc.id.uuidString)])

        XCTAssertTrue(result.success)
        guard case .array(let fields)? = result.data?["fields"], case .object(let entry)? = fields.first else {
            return XCTFail("expected one field entry")
        }
        XCTAssertEqual(entry["value"]?.stringValue, "Final", "must resolve the binding when nothing is locally filled")
        XCTAssertEqual(entry["bound"]?.boolValue, true)
    }

    func testFieldsListToolPrefersLocallyFilledValueOverBinding() async throws {
        let blockID = UUID()
        var block = Block(id: blockID, type: .paragraph)
        var control = ContentControl(kind: .dropDownList, tag: "status", listItems: ["Draft", "Final"], binding: "/root/status")
        control.value = "Draft" // locally filled - must win over the binding
        block.contentControl = control
        var ast = DocumentAST()
        ast.blocks[blockID] = block
        ast.rootChildren = [blockID]

        var parts = PreservedParts()
        parts["customXml/item1.xml"] = Data("<root><status>Final</status></root>".utf8)
        let doc = Doc(title: "Bound form", body: ast, preservedParts: parts)

        DocToolContext.shared.install(loader: { id in id == doc.id ? doc : nil }, filler: nil)

        let result = try await DocFormFieldsListTool().execute(arguments: ["doc_id": .string(doc.id.uuidString)])

        guard case .array(let fields)? = result.data?["fields"], case .object(let entry)? = fields.first else {
            return XCTFail("expected one field entry")
        }
        XCTAssertEqual(entry["value"]?.stringValue, "Draft", "a locally filled value must win over the binding")
    }

    func testFieldsListToolReportsNoFieldsMessageForADocumentWithNoControls() async throws {
        let doc = Doc(title: "Plain", body: .empty)
        DocToolContext.shared.install(loader: { _ in doc }, filler: nil)

        let result = try await DocFormFieldsListTool().execute(arguments: ["doc_id": .string(doc.id.uuidString)])

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?["fields"], .array([]))
    }

    func testFillToolFillsThroughStubFillerAndReportsResolvedValue() async throws {
        let (doc, blockID) = fixtureDoc()
        // Stub filler mirrors what DocStore.fillForm will do once wired:
        // run FormController.fill and return the updated Doc.
        DocToolContext.shared.install(loader: nil, filler: { fillBlockID, value, docID in
            guard docID == doc.id, var block = doc.body.blocks[fillBlockID] else {
                throw DocToolError.docNotFound
            }
            var updated = doc
            block = FormController.fill(block, in: doc.body, value: value)
            updated.body.blocks[fillBlockID] = block
            return updated
        })

        let result = try await DocFormFillTool().execute(arguments: [
            "doc_id": .string(doc.id.uuidString),
            "block_id": .string(blockID.uuidString),
            "value": .string("Ada Lovelace"),
        ])

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?["tag"]?.stringValue, "firstName")
        XCTAssertEqual(result.data?["value"]?.stringValue, "Ada Lovelace")
        XCTAssertTrue(result.output.contains("Ada Lovelace"))
    }

    func testFillToolPropagatesFillerErrorAsFailure() async throws {
        DocToolContext.shared.install(loader: nil, filler: { _, _, _ in throw DocToolError.docNotFound })

        let result = try await DocFormFillTool().execute(arguments: [
            "doc_id": .string(UUID().uuidString),
            "block_id": .string(UUID().uuidString),
            "value": .string("x"),
        ])

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, DocToolError.docNotFound.errorDescription)
    }
}
