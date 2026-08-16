import XCTest
@testable import TesseraCore

// MARK: - AccessibilityToolsTests
//
// Contract: this track's brief (P2-D item 2.20) item 4/6 + testing-
// doctrine.md's Agent tool coverage shape ("schema round-trip + tier
// assertion + receipt behavior + denial path") + `MailMergeToolsTests
// .swift` for the exact shape a store-backed tool's tests follow
// (shared-context install/teardown, argument validation before the
// store check).
//
// GATING (doctrine rule 11): `doc_accessibility_check` has no receipt
// behavior to test (tier0, read-only, no receipt - see
// AccessibilityTools.swift's own doc comment), so there is no
// "receipt behavior" bucket here. `DocStore` itself has no in-memory
// seam (DocStoreTests.swift's own documented exception - verified by
// grep, no fake/stub data layer exists anywhere in this codebase), so
// the one test that reads a REAL persisted Doc through a REAL DocStore
// is gated on TESSERA_DB_INTEGRATION=1; schema round-trip, tier
// assertion, and both denial paths (malformed doc_id, no store
// installed) are fully ungated - none of them touches a store.

final class AccessibilityToolsTests: DoctrineTestCase {

    override func tearDown() {
        DocAccessibilityToolContext.shared.install(nil)
        super.tearDown()
    }

    // MARK: - schema round-trip (doctrine rule 2 applied to Agent tool coverage)

    func testDocAccessibilityCheckToolSchemaRoundTripsThroughJSON() throws {
        let tool = DocAccessibilityCheckTool()
        let data = try JSONEncoder().encode(tool.parameters)
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, tool.parameters)
        XCTAssertEqual(tool.name, "doc_accessibility_check")
        XCTAssertFalse(tool.description.isEmpty)
        XCTAssertEqual(tool.parameters.required ?? [], ["doc_id"])
        XCTAssertNotNil(tool.parameters.properties?["language"])
    }

    // MARK: - tier assertion

    /// Tier0 (`ApprovalLevel.auto`) per the design contract's own tier
    /// table ("`ApprovalLevel.auto` -> tier0 = all read tools, no
    /// receipts", `docs/.scratch/sota-enterprise-report.md`) - this tool
    /// is read-only and never persists anything.
    func testDocAccessibilityCheckToolDefaultApprovalLevelIsAuto() {
        XCTAssertEqual(DocAccessibilityCheckTool().defaultApprovalLevel, .auto)
        XCTAssertEqual(TesseraTier.tier0.displayName, "Tier 0 (auto)")
    }

    // MARK: - denial path: malformed arguments (fails before touching the store)

    func testFailsCleanlyWithNonUUIDDocID() async throws {
        let result = try await DocAccessibilityCheckTool().execute(arguments: [
            "doc_id": .string("not-a-uuid"),
        ])
        XCTAssertFalse(result.success)
    }

    func testFailsCleanlyWithMissingDocID() async throws {
        let result = try await DocAccessibilityCheckTool().execute(arguments: [:])
        XCTAssertFalse(result.success)
    }

    // MARK: - denial path: no store installed

    func testFailsCleanlyWithNoStoreInstalled() async throws {
        DocAccessibilityToolContext.shared.install(nil)
        let result = try await DocAccessibilityCheckTool().execute(arguments: [
            "doc_id": .string(UUID().uuidString),
        ])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, DocAccessibilityToolError.noStore.errorDescription)
    }

    // MARK: - fixture-based content test (gated: live DocStore, real fetch)

    func testReturnsExpectedIssueKindsForAPersistedFixtureDocument() async throws {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip("gated: set TESSERA_DB_INTEGRATION=1 - DocStore has no in-memory seam, see DocStoreTests.swift's own documented exception.")
        }
        let dataLayer = TesseraDataLayer()
        _ = await dataLayer.start()
        let store = DocStore(dataLayer: dataLayer)
        DocAccessibilityToolContext.shared.install(store)

        // Deliberately NOT well-formed: no title, no first heading (an
        // empty-content paragraph, so Doc.displayTitle falls back to
        // "Untitled"), one image with no alt text, and a heading jump.
        var ast = DocumentAST()
        let h1ID = UUID()
        let h3ID = UUID()
        let imgID = UUID()
        ast.blocks[h1ID] = Block(id: h1ID, type: .heading, attributes: ["level": .number(1)], content: [InlineRun(text: "Start")])
        ast.blocks[h3ID] = Block(id: h3ID, type: .heading, attributes: ["level": .number(3)], content: [InlineRun(text: "Skip")])
        ast.blocks[imgID] = Block(id: imgID, type: .image)
        ast.rootChildren = [h1ID, h3ID, imgID]
        let stored = try await store.upsert(Doc(title: "", body: ast))

        let result = try await DocAccessibilityCheckTool().execute(arguments: [
            "doc_id": .string(stored.id.uuidString),
        ])

        XCTAssertTrue(result.success)
        guard case .array(let issues)? = result.data?["issues"] else {
            return XCTFail("expected an \"issues\" array in the tool result data")
        }
        let kinds = Set(issues.compactMap { issue -> String? in
            guard case .object(let fields) = issue else { return nil }
            return fields["kind"]?.stringValue
        })
        XCTAssertEqual(kinds, [
            AccessibilityIssueKind.headingLevelJump.rawValue,
            AccessibilityIssueKind.missingAltText.rawValue,
            AccessibilityIssueKind.missingLanguage.rawValue,
        ])
        XCTAssertEqual(result.data?["issue_count"]?.numberValue, Double(issues.count))
    }

    func testReturnsEmptyIssuesForAWellFormedPersistedDocumentGivenALanguage() async throws {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip("gated: set TESSERA_DB_INTEGRATION=1 - DocStore has no in-memory seam, see DocStoreTests.swift's own documented exception.")
        }
        let dataLayer = TesseraDataLayer()
        _ = await dataLayer.start()
        let store = DocStore(dataLayer: dataLayer)
        DocAccessibilityToolContext.shared.install(store)

        var ast = DocumentAST()
        let h1ID = UUID()
        ast.blocks[h1ID] = Block(id: h1ID, type: .heading, attributes: ["level": .number(1)], content: [InlineRun(text: "Well Formed")])
        ast.rootChildren = [h1ID]
        let stored = try await store.upsert(Doc(title: "Well Formed Document", body: ast))

        let result = try await DocAccessibilityCheckTool().execute(arguments: [
            "doc_id": .string(stored.id.uuidString),
            "language": .string("en"),
        ])

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?["issue_count"]?.numberValue, 0)
        XCTAssertEqual(result.output, "No accessibility issues found.")
    }

    func testFailsCleanlyWhenDocIDDoesNotExist() async throws {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip("gated: set TESSERA_DB_INTEGRATION=1 - DocStore has no in-memory seam, see DocStoreTests.swift's own documented exception.")
        }
        let dataLayer = TesseraDataLayer()
        _ = await dataLayer.start()
        let store = DocStore(dataLayer: dataLayer)
        DocAccessibilityToolContext.shared.install(store)

        let result = try await DocAccessibilityCheckTool().execute(arguments: [
            "doc_id": .string(UUID().uuidString),
        ])
        XCTAssertFalse(result.success)
    }
}
