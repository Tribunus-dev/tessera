import XCTest
import GRDB
@testable import TesseraCore

// MARK: - DatabaseConnectorTests
//
// Contract source: this track's brief (P2-D item 2.16) + `DatabaseConnector.
// swift`'s own header (design contract: docs/.scratch/sota-enterprise-
// report.md "2.16 DatabaseConnector - local-file-engines-only; the doctrine
// wins") + testing-doctrine.md's Engine/controller coverage shape ("contract
// fixtures + property + trap guards").
//
// Every test here is fully ungated: `DatabaseConnector` depends on neither
// `TesseraDataLayer` nor any app-level wiring - GRDB/DuckDB run entirely
// in-process against real files this test class creates in a scratch temp
// directory (SQLite fixtures) or reads from the checked-in CSV/Parquet
// fixtures. No `TESSERA_DB_INTEGRATION` gate applies.
//
// Fixture provenance (doctrine rule 10's "state the probe date + tool
// version" applied to fixtures, not just empirical probes):
// `Fixtures/Database/employees.csv` is hand-authored plain text (3 rows: id
// bigint, name/department varchar, salary double, is_active boolean - types
// as DuckDB's own CSV auto-detection infers them). `employees.parquet` is
// generated FROM that same CSV via the `duckdb` CLI (v1.5.2), 2026-08-16:
// `duckdb -c "COPY (SELECT * FROM read_csv_auto('employees.csv')) TO
// 'employees.parquet' (FORMAT PARQUET);"` - a real Parquet file, not a
// hand-built one, verified readable under `-readonly` mode with the same
// CLI before being checked in.
final class DatabaseConnectorTests: DoctrineTestCase {

    // MARK: - Fixture helpers

    private func fixturesRoot() -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        // Tests/TesseraCoreTests/DataAccess/DatabaseConnectorTests.swift ->
        // Tests/TesseraCoreTests/Fixtures/Database
        return thisFile
            .deletingLastPathComponent() // DataAccess/
            .deletingLastPathComponent() // TesseraCoreTests/
            .appendingPathComponent("Fixtures/Database")
    }

    private var employeesCSV: URL { fixturesRoot().appendingPathComponent("employees.csv") }
    private var employeesParquet: URL { fixturesRoot().appendingPathComponent("employees.parquet") }

    /// A fresh scratch directory per test, so `DatabaseConnector`'s own
    /// DuckDB scratch catalog and any seeded SQLite fixtures never collide
    /// across tests or leak into the real Application Support folder.
    private func makeScratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("db-connector-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeConnector(in dir: URL) -> DatabaseConnector {
        DatabaseConnector(scratchCatalogURL: dir.appendingPathComponent("connector-scratch.duckdb"))
    }

    /// Seeds a real, on-disk SQLite database (read-write, via plain GRDB -
    /// NOT through `DatabaseConnector`, which never opens anything
    /// read-write) with one table and two rows.
    @discardableResult
    private func seedSQLiteFixture(at url: URL) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, price REAL)")
            try db.execute(sql: "INSERT INTO items (id, name, price) VALUES (1, 'widget', 9.99)")
            try db.execute(sql: "INSERT INTO items (id, name, price) VALUES (2, 'gadget', 19.5)")
        }
        return queue
    }

    // MARK: - GRDB read-only enforcement (engine-level, not "we didn't call a write method")

    func testSQLiteAttachedReadOnlyRejectsInsertAtTheEngineLevel() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("fixture.sqlite")
        try seedSQLiteFixture(at: dbURL)

        let connector = makeConnector(in: dir)
        let handle = try await connector.attach(path: dbURL)

        do {
            _ = try await connector.query(handle: handle, sql: "INSERT INTO items (id, name, price) VALUES (3, 'sprocket', 1.0)")
            XCTFail("a write attempt must be rejected by the read-only SQLite connection")
        } catch {
            XCTAssertFalse(
                error is DatabaseConnectorError,
                "the rejection must come from the ENGINE (a real SQLite readonly error), not from this connector's own plumbing - got \(error)"
            )
        }

        let after = try await connector.query(handle: handle, sql: "SELECT * FROM items ORDER BY id")
        XCTAssertEqual(after.rows.count, 2, "the rejected INSERT must not have landed")
    }

    func testSQLiteAttachedReadOnlyRejectsUpdateAtTheEngineLevel() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("fixture.sqlite")
        try seedSQLiteFixture(at: dbURL)

        let connector = makeConnector(in: dir)
        let handle = try await connector.attach(path: dbURL)

        do {
            _ = try await connector.query(handle: handle, sql: "UPDATE items SET price = 0 WHERE id = 1")
            XCTFail("a write attempt must be rejected by the read-only SQLite connection")
        } catch {
            XCTAssertFalse(error is DatabaseConnectorError, "got \(error)")
        }

        let after = try await connector.query(handle: handle, sql: "SELECT price FROM items WHERE id = 1")
        XCTAssertEqual(after.rows.first?.first, "9.99", "the rejected UPDATE must not have landed")
    }

    func testSQLiteAttachedReadOnlyRejectsDeleteAtTheEngineLevel() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("fixture.sqlite")
        try seedSQLiteFixture(at: dbURL)

        let connector = makeConnector(in: dir)
        let handle = try await connector.attach(path: dbURL)

        do {
            _ = try await connector.query(handle: handle, sql: "DELETE FROM items WHERE id = 1")
            XCTFail("a write attempt must be rejected by the read-only SQLite connection")
        } catch {
            XCTAssertFalse(error is DatabaseConnectorError, "got \(error)")
        }

        let after = try await connector.query(handle: handle, sql: "SELECT * FROM items")
        XCTAssertEqual(after.rows.count, 2, "the rejected DELETE must not have landed")
    }

    func testSQLiteAttachedReadOnlyRejectsDDLAtTheEngineLevel() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("fixture.sqlite")
        try seedSQLiteFixture(at: dbURL)

        let connector = makeConnector(in: dir)
        let handle = try await connector.attach(path: dbURL)

        do {
            _ = try await connector.query(handle: handle, sql: "CREATE TABLE evil (x INTEGER)")
            XCTFail("a CREATE TABLE attempt must be rejected by the read-only SQLite connection")
        } catch {
            XCTAssertFalse(error is DatabaseConnectorError, "got \(error)")
        }
    }

    // MARK: - SQLite reads + schema

    func testSQLiteAttachedQueryReadsRealRows() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("fixture.sqlite")
        try seedSQLiteFixture(at: dbURL)

        let connector = makeConnector(in: dir)
        let handle = try await connector.attach(path: dbURL)
        let result = try await connector.query(handle: handle, sql: "SELECT id, name, price FROM items ORDER BY id")

        XCTAssertEqual(result.columns, ["id", "name", "price"])
        XCTAssertEqual(result.rows, [["1", "widget", "9.99"], ["2", "gadget", "19.5"]])
    }

    func testSQLiteSchemaIntrospectionReturnsTableAndColumnInfo() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("fixture.sqlite")
        try seedSQLiteFixture(at: dbURL)

        let connector = makeConnector(in: dir)
        let handle = try await connector.attach(path: dbURL)
        let schema = try await connector.schema(handle: handle)

        XCTAssertEqual(schema.tables.map(\.name), ["items"])
        let columnNames = schema.tables[0].columns.map(\.name)
        XCTAssertEqual(columnNames, ["id", "name", "price"])
    }

    // MARK: - DuckDB CSV/Parquet reads (real fixture files)

    func testDuckDBReadsRealCSVFixtureCorrectly() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connector = makeConnector(in: dir)
        let handle = try await connector.attach(path: employeesCSV)

        let result = try await connector.query(
            handle: handle,
            sql: "SELECT id, name, department, salary, is_active FROM read_csv_auto('\(employeesCSV.path)') ORDER BY id"
        )

        XCTAssertEqual(result.columns, ["id", "name", "department", "salary", "is_active"])
        XCTAssertEqual(result.rows.count, 3)
        XCTAssertEqual(result.rows[0], ["1", "Ada Lovelace", "Engineering", "95000.5", "TRUE"])
        XCTAssertEqual(result.rows[2], ["3", "Katherine Johnson", "Research", "88000.75", "FALSE"])
    }

    func testDuckDBReadsRealCSVFixtureWithAWhereClause() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connector = makeConnector(in: dir)
        let handle = try await connector.attach(path: employeesCSV)

        let result = try await connector.query(
            handle: handle,
            sql: "SELECT name FROM read_csv_auto('\(employeesCSV.path)') WHERE is_active = true ORDER BY name"
        )

        XCTAssertEqual(result.rows.map { $0[0] }, ["Ada Lovelace", "Grace Hopper"])
    }

    func testDuckDBReadsRealParquetFixtureCorrectly() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connector = makeConnector(in: dir)
        let handle = try await connector.attach(path: employeesParquet)

        let result = try await connector.query(
            handle: handle,
            sql: "SELECT id, name FROM read_parquet('\(employeesParquet.path)') ORDER BY id"
        )

        XCTAssertEqual(result.rows.count, 3)
        XCTAssertEqual(result.rows[0], ["1", "Ada Lovelace"])
    }

    func testDuckDBCSVSchemaIntrospectionMatchesFixtureColumns() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connector = makeConnector(in: dir)
        let handle = try await connector.attach(path: employeesCSV)
        let schema = try await connector.schema(handle: handle)

        XCTAssertEqual(schema.tables.count, 1)
        let table = schema.tables[0]
        XCTAssertEqual(table.name, "employees")
        XCTAssertEqual(table.columns.map(\.name), ["id", "name", "department", "salary", "is_active"])
        // Types as DuckDB's own CSV auto-detection infers them - verified
        // against the checked-in fixture via the duckdb CLI (see this
        // file's header) before being pinned here.
        XCTAssertEqual(table.columns.map { $0.type.uppercased() }, ["BIGINT", "VARCHAR", "VARCHAR", "DOUBLE", "BOOLEAN"])
    }

    func testDuckDBParquetSchemaIntrospectionMatchesFixtureColumns() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connector = makeConnector(in: dir)
        let handle = try await connector.attach(path: employeesParquet)
        let schema = try await connector.schema(handle: handle)

        XCTAssertEqual(schema.tables.count, 1)
        XCTAssertEqual(schema.tables[0].columns.map(\.name), ["id", "name", "department", "salary", "is_active"])
    }

    // MARK: - DuckDB read-only enforcement (parity with the SQLite side)

    func testDuckDBAttachedConnectionRejectsCreateTableAtTheEngineLevel() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connector = makeConnector(in: dir)
        let handle = try await connector.attach(path: employeesCSV)

        do {
            _ = try await connector.query(handle: handle, sql: "CREATE TABLE evil (x INTEGER)")
            XCTFail("a CREATE TABLE attempt must be rejected by the read-only DuckDB catalog")
        } catch {
            XCTAssertFalse(error is DatabaseConnectorError, "got \(error)")
        }
    }

    // MARK: - detach

    func testDetachThenQueryThrowsUnknownHandle() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connector = makeConnector(in: dir)
        let handle = try await connector.attach(path: employeesCSV)
        await connector.detach(handle: handle)

        do {
            _ = try await connector.query(handle: handle, sql: "SELECT 1")
            XCTFail("querying a detached handle must throw")
        } catch let error as DatabaseConnectorError {
            XCTAssertEqual(error, .unknownHandle)
        } catch {
            XCTFail("expected DatabaseConnectorError.unknownHandle, got \(error)")
        }
    }

    func testDetachIsIdempotent() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connector = makeConnector(in: dir)
        let handle = try await connector.attach(path: employeesCSV)
        await connector.detach(handle: handle)
        await connector.detach(handle: handle) // must not throw or crash
    }

    // MARK: - attach error paths

    func testAttachUnsupportedFileTypeThrows() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let xlsxURL = dir.appendingPathComponent("material.xlsx")
        try Data("not a real xlsx".utf8).write(to: xlsxURL)

        let connector = makeConnector(in: dir)
        do {
            _ = try await connector.attach(path: xlsxURL)
            XCTFail("xlsx must be rejected - dropped from the v1 db path per row 16's own escape hatch")
        } catch let error as DatabaseConnectorError {
            XCTAssertEqual(error, .unsupportedFileType(extension: "xlsx"))
        } catch {
            XCTFail("expected DatabaseConnectorError.unsupportedFileType, got \(error)")
        }
    }

    func testAttachMissingFileThrowsFileNotFound() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("does-not-exist.csv")
        let connector = makeConnector(in: dir)

        do {
            _ = try await connector.attach(path: missing)
            XCTFail("attaching a nonexistent file must throw")
        } catch let error as DatabaseConnectorError {
            guard case .fileNotFound = error else {
                XCTFail("expected .fileNotFound, got \(error)")
                return
            }
        } catch {
            XCTFail("expected DatabaseConnectorError.fileNotFound, got \(error)")
        }
    }

    // MARK: - sourceInfo / content hash

    func testSourceInfoReportsPathAndSha256PrefixedHash() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connector = makeConnector(in: dir)
        let handle = try await connector.attach(path: employeesCSV)
        let info = try await connector.sourceInfo(handle: handle)

        XCTAssertEqual(info.path, employeesCSV)
        XCTAssertTrue(info.hash.hasPrefix("sha256:"), "must match MailMergeCoordinator.sourceHash's own \"sha256:<hex>\" format")
        XCTAssertEqual(info.hash.count, "sha256:".count + 64)
    }

    func testSourceHashIsStableForIdenticalBytesAndDiffersForDifferentBytes() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.csv")
        let b = dir.appendingPathComponent("b.csv")
        try Data("x,y\n1,2\n".utf8).write(to: a)
        try Data("x,y\n1,2\n".utf8).write(to: b)
        let c = dir.appendingPathComponent("c.csv")
        try Data("x,y\n9,9\n".utf8).write(to: c)

        let hashA1 = try DatabaseConnector.sourceHash(of: a)
        let hashA2 = try DatabaseConnector.sourceHash(of: a)
        let hashB = try DatabaseConnector.sourceHash(of: b)
        let hashC = try DatabaseConnector.sourceHash(of: c)

        XCTAssertEqual(hashA1, hashA2, "hashing the same file twice must be deterministic")
        XCTAssertEqual(hashA1, hashB, "identical bytes under different paths must hash identically")
        XCTAssertNotEqual(hashA1, hashC, "different bytes must hash differently")
    }
}
