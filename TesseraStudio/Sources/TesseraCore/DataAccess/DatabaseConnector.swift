import Foundation
import CryptoKit
import GRDB
import DuckDB

//===----------------------------------------------------------------------===//
//  DatabaseConnector.swift
//  Tessera Studio
//
//  P2-D item 2.16 (local-file-engines-only; design contract:
//  docs/.scratch/sota-enterprise-report.md "2.16 DatabaseConnector - local-
//  file-engines-only; the doctrine wins"; ratified studio-expansion-plan.md
//  section 8 row 16). A "database" in Tessera is a local file the user
//  explicitly picked, full stop:
//
//    .sqlite / .db  -> GRDB, opened with `Configuration.readonly = true`
//                       (SQLITE_OPEN_READONLY). A genuinely read-only
//                       SQLite connection rejects INSERT/UPDATE/DELETE/
//                       DDL at the engine level.
//    CSV/Parquet/JSON -> DuckDB, read directly via its own table
//                       functions (`read_csv_auto`/`read_parquet`/
//                       `read_json_auto`) - no separate "import" step.
//
//  Enforcement is by CONNECTION MODE, never by parsing or allowlisting the
//  caller's SQL text - `query(handle:sql:)` hands the caller's SQL to the
//  engine unexamined; the engine is what refuses a write.
//
//  No network DSNs, no ODBC/JDBC/SDBC, no credential storage, ever. The
//  no-egress doctrine's escape hatch for live Postgres/Oracle etc. is
//  "export an extract to Parquet/CSV upstream" - outside this app.
//
//  xlsx boundary (ratified, row 16): a file already imported as a
//  `SheetWorkbook` material is queried via `sheet_read`/`sheet_describe`
//  (no dedicated `sheet_query` tool exists yet, per the wave brief) -
//  this connector NEVER opens a material file. xlsx itself is dropped
//  from the v1 db path entirely (CSV/Parquet cover the analyst workflow) -
//  DuckDB's `excel` core extension needs static linking that is awkward on
//  iOS, and the plan's own escape hatch for this item blesses dropping it
//  rather than carrying two xlsx readers. See findings for the record.
//===----------------------------------------------------------------------===//

// MARK: - DatabaseConnector

/// Local-file-engines-only database connector. A public actor: every
/// `attach`/`schema`/`query`/`detach` call is serialized through actor
/// isolation, so two agent tool calls racing on the same handle can never
/// interleave against the same GRDB/DuckDB connection.
public actor DatabaseConnector {

    // MARK: - Handle

    /// Opaque session identifier returned by ``attach(path:)``. Session-
    /// scoped, not document-scoped: it names an open connection, not a
    /// material, and does not survive process restart.
    public struct Handle: Hashable, Sendable, Codable {
        public let id: UUID
        public init(id: UUID = UUID()) { self.id = id }
    }

    /// Which engine a handle's file was routed to.
    public enum Kind: String, Sendable, Equatable, Codable {
        case sqlite
        case csv
        case parquet
        case json
    }

    // MARK: - Schema

    public struct ColumnInfo: Sendable, Equatable {
        public let name: String
        /// The engine's own type name (SQLite's declared type string, or
        /// DuckDB's `DESCRIBE` type string) - not normalized to a shared
        /// vocabulary, so callers see exactly what the engine reports.
        public let type: String
        public init(name: String, type: String) {
            self.name = name
            self.type = type
        }
    }

    public struct TableInfo: Sendable, Equatable {
        public let name: String
        public let columns: [ColumnInfo]
        public init(name: String, columns: [ColumnInfo]) {
            self.name = name
            self.columns = columns
        }
    }

    public struct Schema: Sendable, Equatable {
        public let tables: [TableInfo]
        public init(tables: [TableInfo]) {
            self.tables = tables
        }
    }

    // MARK: - Query result

    /// `rows`/`columns` shape, per the design contract. Every value is
    /// already stringified (see `stringify` below) - `SheetStore.
    /// importFromDatabase` classifies each string the same way any other
    /// typed cell text is classified (`CellValue.classify`), so this type
    /// intentionally does not carry engine-native typed values.
    public struct QueryResult: Sendable, Equatable {
        public let columns: [String]
        public let rows: [[String]]
        public init(columns: [String], rows: [[String]]) {
            self.columns = columns
            self.rows = rows
        }
    }

    // MARK: - Session state

    private enum Engine {
        case sqlite(DatabaseQueue)
        case duckdb(Connection)
    }

    private struct Session {
        let engine: Engine
        let kind: Kind
        let sourcePath: URL
        let sourceHash: String
    }

    private var sessions: [Handle: Session] = [:]

    /// Where the shared DuckDB scratch catalog lives - an on-disk
    /// `.duckdb` file that is NEVER written to (no `CREATE TABLE` ever
    /// runs against it) after the one-time creation in
    /// `ensureScratchCatalogExists`. It exists purely because DuckDB
    /// refuses `access_mode = READ_ONLY` on an in-memory store ("Cannot
    /// launch in-memory database in read-only mode!" -
    /// `duckdb/src/storage/storage_manager.cpp`), so a genuinely
    /// read-only DuckDB connection needs a real file to open. Because the
    /// persisted catalog stays permanently empty, the read-only flag has
    /// nothing of the app's own to protect - table access instead comes
    /// entirely from `read_csv_auto`/`read_parquet`/`read_json_auto`,
    /// DuckDB's own table functions that scan the user's file directly
    /// and are unaffected by the attached database's own catalog access
    /// mode (they are not catalog objects; a `SELECT` through them never
    /// touches the read-only catalog at all).
    private let duckDBScratchCatalogURL: URL
    // `DuckDB.` qualified throughout this file: GRDB ALSO exports a
    // top-level `Database` type (and a `Column` type, qualified below at
    // its own use site), so with both modules imported the bare names
    // are ambiguous.
    private var duckDBScratchDatabase: DuckDB.Database?

    /// `scratchCatalogURL` is injectable so tests can point the scratch
    /// catalog at a throwaway temp directory instead of the real
    /// Application Support folder (matching `DuckDBAnalyticsETL`'s own
    /// Application Support convention for the default).
    public init(scratchCatalogURL: URL? = nil) {
        self.duckDBScratchCatalogURL = scratchCatalogURL ?? Self.defaultScratchCatalogURL()
    }

    private static func defaultScratchCatalogURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("Tessera", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tessera_db_connector_scratch.duckdb")
    }

    // MARK: - attach

    /// Open `path` read-only and return a handle. The extension picks the
    /// engine: `.sqlite`/`.db` -> GRDB; `.csv`/`.tsv`/`.parquet`/`.json`/
    /// `.jsonl` -> DuckDB. Any other extension (including `.xlsx` - see
    /// this file's own header) is rejected before either engine is
    /// touched.
    public func attach(path: URL) throws -> Handle {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw DatabaseConnectorError.fileNotFound(path: path.path)
        }
        let hash = try Self.sourceHash(of: path)
        let ext = path.pathExtension.lowercased()
        let handle = Handle()
        switch ext {
        case "sqlite", "db":
            var config = GRDB.Configuration()
            config.readonly = true
            let queue = try DatabaseQueue(path: path.path, configuration: config)
            sessions[handle] = Session(engine: .sqlite(queue), kind: .sqlite, sourcePath: path, sourceHash: hash)
        case "csv", "tsv":
            let conn = try duckDBReadOnlyConnection()
            sessions[handle] = Session(engine: .duckdb(conn), kind: .csv, sourcePath: path, sourceHash: hash)
        case "parquet":
            let conn = try duckDBReadOnlyConnection()
            sessions[handle] = Session(engine: .duckdb(conn), kind: .parquet, sourcePath: path, sourceHash: hash)
        case "json", "jsonl":
            let conn = try duckDBReadOnlyConnection()
            sessions[handle] = Session(engine: .duckdb(conn), kind: .json, sourcePath: path, sourceHash: hash)
        default:
            throw DatabaseConnectorError.unsupportedFileType(extension: ext)
        }
        return handle
    }

    /// The source file path + content hash a handle was attached from -
    /// what `db_import_range` needs for the materialization receipt's
    /// audit-provenance payload.
    public func sourceInfo(handle: Handle) throws -> (path: URL, hash: String) {
        guard let session = sessions[handle] else {
            throw DatabaseConnectorError.unknownHandle
        }
        return (session.sourcePath, session.sourceHash)
    }

    /// Close the connection a handle names. Idempotent: detaching an
    /// already-detached (or never-attached) handle is a no-op, not an
    /// error - matching `db_detach`'s own "session teardown, not a
    /// document mutation" framing.
    public func detach(handle: Handle) {
        sessions.removeValue(forKey: handle)
    }

    // MARK: - schema

    public func schema(handle: Handle) throws -> Schema {
        guard let session = sessions[handle] else {
            throw DatabaseConnectorError.unknownHandle
        }
        switch session.engine {
        case .sqlite(let queue):
            return try Self.schemaForSQLite(queue)
        case .duckdb(let conn):
            return try Self.schemaForDuckDB(conn, kind: session.kind, path: session.sourcePath)
        }
    }

    // MARK: - query

    /// Run `sql` against the attached source and return its result.
    /// SELECT-only is enforced by the engine's own read-only connection
    /// mode (see this file's header) - `sql` reaches the engine
    /// unexamined. Never emits a receipt: this is a read, and "no receipt
    /// without a mutation" is a standing rule (only `SheetStore.
    /// importFromDatabase`, reached separately by `db_import_range`,
    /// materializes a receipted mutation).
    public func query(handle: Handle, sql: String) throws -> QueryResult {
        guard let session = sessions[handle] else {
            throw DatabaseConnectorError.unknownHandle
        }
        switch session.engine {
        case .sqlite(let queue):
            return try Self.querySQLite(queue, sql: sql)
        case .duckdb(let conn):
            return try Self.queryDuckDB(conn, sql: sql)
        }
    }

    // MARK: - DuckDB connection plumbing

    private func duckDBReadOnlyConnection() throws -> Connection {
        if let db = duckDBScratchDatabase {
            return try db.connect()
        }
        try Self.ensureScratchCatalogExists(at: duckDBScratchCatalogURL)
        let config = DuckDB.Database.Configuration()
        try config.setValue("READ_ONLY", forKey: "access_mode")
        let database = try DuckDB.Database(store: .file(at: duckDBScratchCatalogURL), configuration: config)
        duckDBScratchDatabase = database
        return try database.connect()
    }

    /// Create the scratch catalog file once, in the (default) read-write
    /// mode, so DuckDB actually creates it - DuckDB only auto-creates a
    /// missing file when NOT read-only (`duckdb/src/storage/
    /// storage_manager.cpp`: the create-on-missing branch is guarded
    /// `!read_only && !fs.FileExists(path)`). Every later `attach()` call
    /// reopens this same, now-existing file in READ_ONLY mode. The
    /// temporary `Database` instance is not retained past this function,
    /// so its `deinit` closes the file immediately.
    private static func ensureScratchCatalogExists(at url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        _ = try DuckDB.Database(store: .file(at: url))
    }

    private static func duckDBTableFunctionCall(kind: Kind, path: URL) -> String {
        // Single-quote escaping only (DuckDB SQL string literal syntax) -
        // this is building a TRUSTED, hardcoded query template around a
        // path WE resolved at attach time, not parsing caller-supplied
        // SQL, so it does not run afoul of this file's own "no SQL
        // parsing" rule.
        let escaped = path.path.replacingOccurrences(of: "'", with: "''")
        switch kind {
        case .csv: return "read_csv_auto('\(escaped)')"
        case .parquet: return "read_parquet('\(escaped)')"
        case .json: return "read_json_auto('\(escaped)')"
        case .sqlite:
            preconditionFailure("a .sqlite session never reaches the DuckDB table-function path")
        }
    }

    private static func schemaForDuckDB(_ conn: Connection, kind: Kind, path: URL) throws -> Schema {
        let call = duckDBTableFunctionCall(kind: kind, path: path)
        let result = try conn.query("DESCRIBE SELECT * FROM \(call)")
        let nameColumn = result.column(at: 0).cast(to: String.self)
        let typeColumn = result.column(at: 1).cast(to: String.self)
        var columns: [ColumnInfo] = []
        let rowCount = Int(result.rowCount)
        columns.reserveCapacity(rowCount)
        for i in 0..<rowCount {
            let index = DBInt(i)
            columns.append(ColumnInfo(name: nameColumn[index] ?? "", type: typeColumn[index] ?? ""))
        }
        let tableName = path.deletingPathExtension().lastPathComponent
        return Schema(tables: [TableInfo(name: tableName, columns: columns)])
    }

    private static func queryDuckDB(_ conn: Connection, sql: String) throws -> QueryResult {
        let result = try conn.query(sql)
        let columnCount = Int(result.columnCount)
        let rowCount = Int(result.rowCount)
        var columnNames: [String] = []
        var stringColumns: [[String]] = []
        columnNames.reserveCapacity(columnCount)
        stringColumns.reserveCapacity(columnCount)
        for c in 0..<columnCount {
            let column = result.column(at: DBInt(c))
            columnNames.append(column.name)
            stringColumns.append(try stringify(column, rowCount: rowCount))
        }
        var rows: [[String]] = []
        rows.reserveCapacity(rowCount)
        for r in 0..<rowCount {
            rows.append(stringColumns.map { $0[r] })
        }
        return QueryResult(columns: columnNames, rows: rows)
    }

    /// Render every value of a DuckDB result column as display text, the
    /// same shape `SheetStore.writingCellValue` expects (plain text, re-
    /// classified into a typed `CellValue` on the way into a cell).
    ///
    /// Covers the DuckDB column types real CSV/Parquet/JSON files
    /// realistically carry (boolean, the 8 integer widths, float/double,
    /// varchar, blob, decimal, uuid, date/time/timestamp incl. the TZ and
    /// second-precision variants). Composite/nested types (`list`,
    /// `struct`, `map`, `union`, `enum`) and `hugeint`/`uhugeint`/
    /// `interval` are explicitly NOT stringified in v1 - `db_query`
    /// throws a named error naming the column rather than silently
    /// emitting an empty string, so a query that returns one of these
    /// fails loudly instead of materializing wrong (empty) data. See
    /// findings for the scope note.
    private static func stringify(_ column: DuckDB.Column<Void>, rowCount: Int) throws -> [String] {
        switch column.underlyingDatabaseType {
        case .varchar:
            let c = column.cast(to: String.self)
            return (0..<rowCount).map { c[DBInt($0)] ?? "" }
        case .boolean:
            let c = column.cast(to: Bool.self)
            return (0..<rowCount).map { c[DBInt($0)].map { $0 ? "TRUE" : "FALSE" } ?? "" }
        case .tinyint:
            let c = column.cast(to: Int8.self)
            return (0..<rowCount).map { c[DBInt($0)].map(String.init) ?? "" }
        case .smallint:
            let c = column.cast(to: Int16.self)
            return (0..<rowCount).map { c[DBInt($0)].map(String.init) ?? "" }
        case .integer:
            let c = column.cast(to: Int32.self)
            return (0..<rowCount).map { c[DBInt($0)].map(String.init) ?? "" }
        case .bigint:
            let c = column.cast(to: Int64.self)
            return (0..<rowCount).map { c[DBInt($0)].map(String.init) ?? "" }
        case .utinyint:
            let c = column.cast(to: UInt8.self)
            return (0..<rowCount).map { c[DBInt($0)].map(String.init) ?? "" }
        case .usmallint:
            let c = column.cast(to: UInt16.self)
            return (0..<rowCount).map { c[DBInt($0)].map(String.init) ?? "" }
        case .uinteger:
            let c = column.cast(to: UInt32.self)
            return (0..<rowCount).map { c[DBInt($0)].map(String.init) ?? "" }
        case .ubigint:
            let c = column.cast(to: UInt64.self)
            return (0..<rowCount).map { c[DBInt($0)].map(String.init) ?? "" }
        case .float:
            let c = column.cast(to: Float.self)
            return (0..<rowCount).map { index in c[DBInt(index)].map { (value: Float) -> String in String(value) } ?? "" }
        case .double:
            let c = column.cast(to: Double.self)
            return (0..<rowCount).map { index in c[DBInt(index)].map { (value: Double) -> String in String(value) } ?? "" }
        case .decimal:
            let c = column.cast(to: Decimal.self)
            return (0..<rowCount).map { c[DBInt($0)].map { String(describing: $0) } ?? "" }
        case .uuid:
            let c = column.cast(to: UUID.self)
            return (0..<rowCount).map { c[DBInt($0)]?.uuidString ?? "" }
        case .blob:
            let c = column.cast(to: Data.self)
            return (0..<rowCount).map { c[DBInt($0)]?.base64EncodedString() ?? "" }
        case .date:
            let c = column.cast(to: DuckDB.Date.self)
            return (0..<rowCount).map { index in
                guard let value = c[DBInt(index)] else { return "" }
                let comps = value.components
                return String(format: "%04d-%02d-%02d", comps.year, comps.month, comps.day)
            }
        case .time:
            let c = column.cast(to: Time.self)
            return (0..<rowCount).map { index in
                guard let value = c[DBInt(index)] else { return "" }
                let comps = value.components
                return String(format: "%02d:%02d:%02d", comps.hour, comps.minute, comps.second)
            }
        case .timeTz:
            let c = column.cast(to: TimeTz.self)
            return (0..<rowCount).map { index in
                guard let value = c[DBInt(index)] else { return "" }
                let comps = value.time.components
                return String(format: "%02d:%02d:%02d", comps.hour, comps.minute, comps.second)
            }
        case .timestamp, .timestampTz, .timestampS, .timestampMS, .timestampNS:
            let c = column.cast(to: Timestamp.self)
            return (0..<rowCount).map { index in
                guard let value = c[DBInt(index)] else { return "" }
                let comps = value.components
                return String(
                    format: "%04d-%02d-%02dT%02d:%02d:%02d",
                    comps.date.year, comps.date.month, comps.date.day,
                    comps.time.hour, comps.time.minute, comps.time.second
                )
            }
        default:
            throw DatabaseConnectorError.unsupportedColumnType(
                column: column.name,
                type: column.underlyingDatabaseType.description
            )
        }
    }

    // MARK: - SQLite (GRDB) plumbing

    private static func schemaForSQLite(_ queue: DatabaseQueue) throws -> Schema {
        try queue.read { db in
            let names = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
            )
            let tables = try names.map { name -> TableInfo in
                let columns = try db.columns(in: name)
                return TableInfo(name: name, columns: columns.map { ColumnInfo(name: $0.name, type: $0.type) })
            }
            return Schema(tables: tables)
        }
    }

    private static func querySQLite(_ queue: DatabaseQueue, sql: String) throws -> QueryResult {
        try queue.read { db in
            let statement = try db.makeStatement(sql: sql)
            let columnNames = statement.columnNames
            let rows = try Row.fetchAll(statement)
            let stringRows = rows.map { row in row.map { _, value in stringify(value) } }
            return QueryResult(columns: columnNames, rows: stringRows)
        }
    }

    private static func stringify(_ value: DatabaseValue) -> String {
        switch value.storage {
        case .null: return ""
        case .int64(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return s
        case .blob(let data): return data.base64EncodedString()
        }
    }

    // MARK: - Content hash

    /// `"sha256:<hex>"` over the source file's own bytes - the same
    /// format `MailMergeCoordinator.sourceHash(records:)` uses, so the
    /// receipt chain has one consistent content-addressing shape.
    static func sourceHash(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var hasher = SHA256()
        hasher.update(data: data)
        let digest = hasher.finalize()
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - DatabaseConnectorError

public enum DatabaseConnectorError: Error, Sendable, Equatable, LocalizedError {
    case fileNotFound(path: String)
    case unsupportedFileType(extension: String)
    case unknownHandle
    case unsupportedColumnType(column: String, type: String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "No file exists at \(path)."
        case .unsupportedFileType(let ext):
            return "Unsupported database file type: .\(ext). Supported: sqlite, db, csv, tsv, parquet, json, jsonl."
        case .unknownHandle:
            return "This database handle is not attached (was it already detached?)."
        case .unsupportedColumnType(let column, let type):
            return "Column '\(column)' has a type (\(type)) this connector does not stringify in v1."
        }
    }
}
