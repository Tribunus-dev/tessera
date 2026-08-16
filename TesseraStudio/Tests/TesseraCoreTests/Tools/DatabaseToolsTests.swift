import XCTest
@testable import TesseraCore

// MARK: - DatabaseToolsTests
//
// Contract source: this track's brief (P2-D item 2.16) + testing-doctrine.md's
// Agent tool coverage shape ("schema round-trip + tier assertion + receipt
// behavior + denial path") + `TesseraTool`'s protocol doc comments
// (Sources/TesseraCore/Agent/TesseraTool.swift) + `MailMergeToolsTests.swift`/
// `SheetSolverToolsTests.swift` for the exact shape a store-backed tool's
// tests follow, including reusing the shared-context install/teardown
// pattern.
//
// GATING: db_attach/db_schema/db_query/db_detach need only a
// `DatabaseConnector` (no `TesseraDataLayer` dependency at all - see
// `DatabaseConnector.swift`'s own header), so their full functional
// behavior is tested fully ungated against the real CSV fixture.
// `db_import_range`'s denial paths (no connector, no sheet store, bad
// arguments) are likewise ungated. Only `db_import_range`'s SUCCESS path
// needs a real `SheetStore`/`TesseraDataLayer` and is gated on
// `TESSERA_DB_INTEGRATION=1`, matching `MailMergeToolsTests.swift`'s own
// gating for the same reason.
final class DatabaseToolsTests: DoctrineTestCase {

    override func tearDown() {
        DatabaseToolContext.shared.install(nil, sheetStore: nil)
        super.tearDown()
    }

    // MARK: - Fixture helpers

    private func fixturesRoot() -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        // Tests/TesseraCoreTests/Tools/DatabaseToolsTests.swift ->
        // Tests/TesseraCoreTests/Fixtures/Database
        return thisFile
            .deletingLastPathComponent() // Tools/
            .deletingLastPathComponent() // TesseraCoreTests/
            .appendingPathComponent("Fixtures/Database")
    }

    private var employeesCSV: URL { fixturesRoot().appendingPathComponent("employees.csv") }

    private func makeScratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("db-tools-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Installs a fresh connector (own scratch catalog dir) and returns it
    /// alongside the scratch dir so the caller can clean up.
    private func installConnector() throws -> (connector: DatabaseConnector, scratchDir: URL) {
        let dir = try makeScratchDirectory()
        let connector = DatabaseConnector(scratchCatalogURL: dir.appendingPathComponent("scratch.duckdb"))
        DatabaseToolContext.shared.install(connector)
        return (connector, dir)
    }

    // MARK: - schema round-trip (doctrine rule 2 applied to Agent tool coverage)

    func testDbAttachToolSchemaRoundTripsThroughJSON() throws {
        let tool = DatabaseAttachTool()
        let data = try JSONEncoder().encode(tool.parameters)
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, tool.parameters)
        XCTAssertEqual(tool.name, "db_attach")
        XCTAssertEqual(tool.parameters.required, ["path"])
    }

    func testDbSchemaToolSchemaRoundTripsThroughJSON() throws {
        let tool = DatabaseSchemaTool()
        let data = try JSONEncoder().encode(tool.parameters)
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, tool.parameters)
        XCTAssertEqual(tool.name, "db_schema")
        XCTAssertEqual(tool.parameters.required, ["handle"])
    }

    func testDbQueryToolSchemaRoundTripsThroughJSON() throws {
        let tool = DatabaseQueryTool()
        let data = try JSONEncoder().encode(tool.parameters)
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, tool.parameters)
        XCTAssertEqual(tool.name, "db_query")
        XCTAssertEqual(Set(tool.parameters.required ?? []), ["handle", "sql"])
    }

    func testDbImportRangeToolSchemaRoundTripsThroughJSON() throws {
        let tool = DatabaseImportRangeTool()
        let data = try JSONEncoder().encode(tool.parameters)
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, tool.parameters)
        XCTAssertEqual(tool.name, "db_import_range")
        XCTAssertEqual(Set(tool.parameters.required ?? []), ["handle", "sql", "sheet_id"])
        XCTAssertNotNil(tool.parameters.properties?["anchor"])
    }

    func testDbDetachToolSchemaRoundTripsThroughJSON() throws {
        let tool = DatabaseDetachTool()
        let data = try JSONEncoder().encode(tool.parameters)
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, tool.parameters)
        XCTAssertEqual(tool.name, "db_detach")
        XCTAssertEqual(tool.parameters.required, ["handle"])
    }

    // MARK: - tier assertion

    func testDbAttachToolDefaultApprovalLevelIsNotify() {
        XCTAssertEqual(DatabaseAttachTool().defaultApprovalLevel, .notify)
        XCTAssertEqual(TesseraTier.tier1.displayName, "Tier 1 (notify)")
    }

    func testDbSchemaToolDefaultApprovalLevelIsAuto() {
        XCTAssertEqual(DatabaseSchemaTool().defaultApprovalLevel, .auto)
        XCTAssertEqual(TesseraTier.tier0.displayName, "Tier 0 (auto)")
    }

    func testDbQueryToolDefaultApprovalLevelIsAuto() {
        XCTAssertEqual(DatabaseQueryTool().defaultApprovalLevel, .auto)
    }

    func testDbImportRangeToolDefaultApprovalLevelIsNotify() {
        XCTAssertEqual(DatabaseImportRangeTool().defaultApprovalLevel, .notify)
    }

    func testDbDetachToolDefaultApprovalLevelIsNotify() {
        XCTAssertEqual(DatabaseDetachTool().defaultApprovalLevel, .notify)
    }

    // MARK: - denial path: no connector installed

    func testDbAttachToolFailsCleanlyWithNoConnectorInstalled() async throws {
        DatabaseToolContext.shared.install(nil)
        let result = try await DatabaseAttachTool().execute(arguments: ["path": .string(employeesCSV.path)])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, DatabaseToolError.noConnector.errorDescription)
    }

    func testDbSchemaToolFailsCleanlyWithNoConnectorInstalled() async throws {
        DatabaseToolContext.shared.install(nil)
        let result = try await DatabaseSchemaTool().execute(arguments: ["handle": .string(UUID().uuidString)])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, DatabaseToolError.noConnector.errorDescription)
    }

    func testDbQueryToolFailsCleanlyWithNoConnectorInstalled() async throws {
        DatabaseToolContext.shared.install(nil)
        let result = try await DatabaseQueryTool().execute(arguments: [
            "handle": .string(UUID().uuidString),
            "sql": .string("SELECT 1"),
        ])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, DatabaseToolError.noConnector.errorDescription)
    }

    func testDbDetachToolFailsCleanlyWithNoConnectorInstalled() async throws {
        DatabaseToolContext.shared.install(nil)
        let result = try await DatabaseDetachTool().execute(arguments: ["handle": .string(UUID().uuidString)])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, DatabaseToolError.noConnector.errorDescription)
    }

    func testDbImportRangeToolFailsCleanlyWithNoConnectorInstalled() async throws {
        DatabaseToolContext.shared.install(nil)
        let result = try await DatabaseImportRangeTool().execute(arguments: [
            "handle": .string(UUID().uuidString),
            "sql": .string("SELECT 1"),
            "sheet_id": .string(UUID().uuidString),
        ])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, DatabaseToolError.noConnector.errorDescription)
    }

    // MARK: - denial path: malformed arguments (fail before touching the connector)

    func testDbAttachToolFailsCleanlyWithEmptyPath() async throws {
        let result = try await DatabaseAttachTool().execute(arguments: ["path": .string("")])
        XCTAssertFalse(result.success)
    }

    func testDbSchemaToolFailsCleanlyWithNonUUIDHandle() async throws {
        _ = try installConnector()
        let result = try await DatabaseSchemaTool().execute(arguments: ["handle": .string("not-a-uuid")])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, DatabaseToolError.invalidHandle.errorDescription)
    }

    func testDbQueryToolFailsCleanlyWithEmptySql() async throws {
        _ = try installConnector()
        let result = try await DatabaseQueryTool().execute(arguments: [
            "handle": .string(UUID().uuidString),
            "sql": .string(""),
        ])
        XCTAssertFalse(result.success)
    }

    func testDbImportRangeToolFailsCleanlyWithNonUUIDSheetID() async throws {
        _ = try installConnector()
        let result = try await DatabaseImportRangeTool().execute(arguments: [
            "handle": .string(UUID().uuidString),
            "sql": .string("SELECT 1"),
            "sheet_id": .string("not-a-uuid"),
        ])
        XCTAssertFalse(result.success)
    }

    func testDbImportRangeToolFailsCleanlyWithInvalidAnchor() async throws {
        _ = try installConnector()
        let result = try await DatabaseImportRangeTool().execute(arguments: [
            "handle": .string(UUID().uuidString),
            "sql": .string("SELECT 1"),
            "sheet_id": .string(UUID().uuidString),
            "anchor": .string("not-a-cell-ref"),
        ])
        XCTAssertFalse(result.success)
    }

    // MARK: - denial path: db_import_range with a connector but no sheet store

    func testDbImportRangeToolFailsCleanlyWithNoSheetStoreInstalled() async throws {
        let (connector, dir) = try installConnector()
        defer { try? FileManager.default.removeItem(at: dir) }
        let handle = try await connector.attach(path: employeesCSV)

        let result = try await DatabaseImportRangeTool().execute(arguments: [
            "handle": .string(handle.id.uuidString),
            "sql": .string("SELECT * FROM read_csv_auto('\(employeesCSV.path)')"),
            "sheet_id": .string(UUID().uuidString),
        ])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, DatabaseToolError.noSheetStore.errorDescription)
    }

    // MARK: - db_attach / db_schema / db_query / db_detach: real functional round trip (ungated)

    func testDbAttachToolAttachesAndReportsHandleAndSourceHash() async throws {
        let (_, dir) = try installConnector()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try await DatabaseAttachTool().execute(arguments: ["path": .string(employeesCSV.path)])
        XCTAssertTrue(result.success)
        XCTAssertNotNil(result.data?["handle"]?.stringValue)
        XCTAssertEqual(result.data?["source_path"]?.stringValue, employeesCSV.path)
        XCTAssertTrue(result.data?["source_hash"]?.stringValue?.hasPrefix("sha256:") ?? false)
    }

    func testDbSchemaToolReportsTablesAndColumns() async throws {
        let (connector, dir) = try installConnector()
        defer { try? FileManager.default.removeItem(at: dir) }
        let handle = try await connector.attach(path: employeesCSV)

        let result = try await DatabaseSchemaTool().execute(arguments: ["handle": .string(handle.id.uuidString)])
        XCTAssertTrue(result.success)
        guard case .array(let tables)? = result.data?["tables"] else {
            XCTFail("expected tables array")
            return
        }
        XCTAssertEqual(tables.count, 1)
        guard case .object(let table)? = tables.first else {
            XCTFail("expected table object")
            return
        }
        XCTAssertEqual(table["name"]?.stringValue, "employees")
        guard case .array(let columns)? = table["columns"] else {
            XCTFail("expected columns array")
            return
        }
        XCTAssertEqual(columns.count, 5)
    }

    func testDbQueryToolReturnsRealRows() async throws {
        let (connector, dir) = try installConnector()
        defer { try? FileManager.default.removeItem(at: dir) }
        let handle = try await connector.attach(path: employeesCSV)

        let result = try await DatabaseQueryTool().execute(arguments: [
            "handle": .string(handle.id.uuidString),
            "sql": .string("SELECT id, name FROM read_csv_auto('\(employeesCSV.path)') ORDER BY id"),
        ])
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?["row_count"]?.numberValue, 3)
        guard case .array(let columns)? = result.data?["columns"] else {
            XCTFail("expected columns array")
            return
        }
        XCTAssertEqual(columns.map { $0.stringValue }, ["id", "name"])
    }

    func testDbQueryToolRejectsAWriteAtTheEngineLevel() async throws {
        let (connector, dir) = try installConnector()
        defer { try? FileManager.default.removeItem(at: dir) }
        let handle = try await connector.attach(path: employeesCSV)

        let result = try await DatabaseQueryTool().execute(arguments: [
            "handle": .string(handle.id.uuidString),
            "sql": .string("CREATE TABLE evil (x INTEGER)"),
        ])
        XCTAssertFalse(result.success, "a write attempt must fail - the engine's own read-only mode rejects it")
    }

    /// "db_query never emits a receipt" (explicit assertion, per this
    /// track's item 5). This is a STRUCTURAL guarantee, not merely a
    /// behavioral one: `DatabaseConnector` (see its own header) holds no
    /// reference to `TesseraDataLayer`, `SheetStore`, `DocStore`, or
    /// `ReceiptsCoordinator` at all - there is no call path from
    /// `db_query`'s `execute` through `DatabaseQueryTool` -> `DatabaseTool
    /// Support.connector()` -> `DatabaseConnector.query(handle:sql:)` that
    /// could reach a receipt sink even if this test somehow missed a
    /// regression. The behavioral half: running a real query against the
    /// real fixture succeeds and returns data with no receipt-shaped
    /// fields in its payload.
    func testDbQueryToolNeverEmitsAReceipt() async throws {
        let (connector, dir) = try installConnector()
        defer { try? FileManager.default.removeItem(at: dir) }
        let handle = try await connector.attach(path: employeesCSV)

        let result = try await DatabaseQueryTool().execute(arguments: [
            "handle": .string(handle.id.uuidString),
            "sql": .string("SELECT * FROM read_csv_auto('\(employeesCSV.path)')"),
        ])
        XCTAssertTrue(result.success)
        XCTAssertNil(result.data?["receipt_id"], "db_query must never surface a receipt id - it is a read")
        XCTAssertNil(result.data?["receipt_type"])
    }

    func testDbDetachToolDetachesSoASubsequentSchemaCallFails() async throws {
        let (connector, dir) = try installConnector()
        defer { try? FileManager.default.removeItem(at: dir) }
        let handle = try await connector.attach(path: employeesCSV)

        let detachResult = try await DatabaseDetachTool().execute(arguments: ["handle": .string(handle.id.uuidString)])
        XCTAssertTrue(detachResult.success)

        let schemaResult = try await DatabaseSchemaTool().execute(arguments: ["handle": .string(handle.id.uuidString)])
        XCTAssertFalse(schemaResult.success, "a detached handle must no longer resolve")
    }

    // MARK: - db_import_range: success path (gated: live SheetStore, real materialization)

    func testDbImportRangeToolMaterializesRealQueryResultIntoASheetWithFullProvenance() async throws {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip(
                "TESSERA_DB_INTEGRATION not set - skipping the live-SheetStore db_import_range path " +
                "(doctrine rule 11: denial paths above are the ungated shadow of this same tool's contract)."
            )
        }
        let (connector, dir) = try installConnector()
        defer { try? FileManager.default.removeItem(at: dir) }
        let handle = try await connector.attach(path: employeesCSV)

        let dataLayer = TesseraDataLayer()
        let outcome = await dataLayer.start()
        guard case .ready = outcome else {
            throw XCTSkip("Postgres/Valkey not reachable in this environment (\(outcome)) - skipping.")
        }
        let sheetStore = SheetStore(dataLayer: dataLayer)
        DatabaseToolContext.shared.install(connector, sheetStore: sheetStore)
        let sheet = try await sheetStore.upsert(Sheet.makeBlank(title: "db-import-range-tool-test", rows: 1, cols: 1))

        let sql = "SELECT id, name FROM read_csv_auto('\(employeesCSV.path)') ORDER BY id"
        let result = try await DatabaseImportRangeTool().execute(arguments: [
            "handle": .string(handle.id.uuidString),
            "sql": .string(sql),
            "sheet_id": .string(sheet.id.uuidString),
            "anchor": .string("A1"),
        ])

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?["row_count"]?.numberValue, 3)
        XCTAssertEqual(result.data?["column_count"]?.numberValue, 2)
        XCTAssertTrue(result.data?["source_hash"]?.stringValue?.hasPrefix("sha256:") ?? false)

        let updated = try await sheetStore.get(id: sheet.id)
        XCTAssertEqual(updated?.cellText(row: 0, col: 0), "id")
        XCTAssertEqual(updated?.cellText(row: 1, col: 0), "1")

        let receipts = try await sheetStore.receipts(forSheet: sheet.id)
        let importReceipts = receipts.filter { $0.receiptType == SheetReceiptType.importFromDatabase.rawValue }
        XCTAssertEqual(importReceipts.count, 1)
        XCTAssertEqual(importReceipts.first?.payload["sql"], .string(sql))
        XCTAssertEqual(importReceipts.first?.payload["rowCount"], .number(3))
    }
}
