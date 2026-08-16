import Foundation

//===----------------------------------------------------------------------===//
//  DatabaseTools.swift
//  Tessera Studio
//
//  The agent's access to `DatabaseConnector` (P2-D item 2.16): db_attach,
//  db_schema, db_query, db_import_range, db_detach. Tier mapping (per the
//  wave brief, using this codebase's own shipped ApprovalLevel<->TesseraTier
//  convention - `SheetGoalSeekTool`/`SheetSolverRunTool`, Tools/
//  SheetTools.swift - tier0 = .auto, tier1 = .notify):
//
//    db_attach       tier1 (.notify) - registers a session-scoped read-only
//                    connection to a local file the user picked.
//    db_schema       tier0 (.auto)   - table/column introspection, a read.
//    db_query        tier0 (.auto)   - SELECT-only, enforced by the
//                    engine's own read-only connection mode (see
//                    DatabaseConnector.swift's header) - never emits a
//                    receipt ("no receipt without a mutation").
//    db_import_range tier1 (.notify) - materializes a query result into a
//                    sheet range via SheetStore.importFromDatabase; ONE
//                    receipt with full audit provenance.
//    db_detach       tier1 (.notify) - closes a session-scoped connection.
//
//  db_attach/db_detach are session-scoped, not document-scoped: there is
//  no Doc/Sheet/Drawing entity to hang a `GraphReceipt` off of, and this
//  wave's pre-landed reservations added no new *ReceiptType case for
//  either (per the wave brief: "doesn't need a NEW *ReceiptType case
//  since attach/detach are session-scoped, not document-scoped
//  mutations - your call, document it either way"). This file's choice:
//  do NOT force a synthetic entityID through a data-layer receipt sink
//  DatabaseToolContext otherwise has no reason to depend on - the
//  existing agent-loop audit trail (`ActionAuditLogStore`, AGENTS.md
//  "Inline stop + audit log side panel") already records every tool call
//  + outcome + tier + timestamp regardless of a domain receipt, and each
//  tool's own `ToolResult.data` carries the session-scoped audit facts
//  (handle, kind, source path/hash for attach; handle for detach). See
//  this track's findings file for the full reasoning, flagged for
//  architect ratification.
//===----------------------------------------------------------------------===//

// MARK: - DatabaseToolContext

/// Where the database tools find the connector (and, for
/// `db_import_range`, the `SheetStore`) to act on. Same shape as
/// `MailMergeToolContext`/`SheetToolContext` (Tools/MailMergeTools.swift,
/// Tools/SheetTools.swift): nil by default, so a build with nothing wired
/// reports that cleanly rather than inventing a connector. The app
/// installs the live connector (and sheet store) once its
/// `TesseraDataLayer`/database surface starts, and clears them when the
/// surface tears down.
public final class DatabaseToolContext: @unchecked Sendable {
    public static let shared = DatabaseToolContext()

    private let lock = NSLock()
    private var _connector: DatabaseConnector?
    private var _sheetStore: SheetStore?

    public init() {}

    /// The connector every `db_*` tool acts on, or nil when none is
    /// installed.
    public var connector: DatabaseConnector? {
        get { lock.lock(); defer { lock.unlock() }; return _connector }
        set { lock.lock(); defer { lock.unlock() }; _connector = newValue }
    }

    /// The receipted persistence seam `db_import_range` materializes
    /// into. Nil when no Sheets surface is wired, in which case
    /// `db_import_range` fails closed exactly like `db_attach`/
    /// `db_schema`/`db_query`/`db_detach` do with no connector installed.
    public var sheetStore: SheetStore? {
        get { lock.lock(); defer { lock.unlock() }; return _sheetStore }
        set { lock.lock(); defer { lock.unlock() }; _sheetStore = newValue }
    }

    /// Install (or, with nils, clear) the live connector and sheet store.
    /// `sheetStore` is optional so a caller that only needs
    /// attach/schema/query/detach (no materialization) can install just
    /// the connector.
    public func install(_ connector: DatabaseConnector?, sheetStore: SheetStore? = nil) {
        self.connector = connector
        self.sheetStore = sheetStore
    }
}

enum DatabaseToolError: LocalizedError, Equatable {
    case noConnector
    case noSheetStore
    case invalidHandle
    case invalidAnchor(String)

    var errorDescription: String? {
        switch self {
        case .noConnector:
            return "No local database is attached. Call db_attach first."
        case .noSheetStore:
            return "No Sheets surface is available to materialize into. Open a Sheets surface first."
        case .invalidHandle:
            return "handle must be the UUID string returned by db_attach."
        case .invalidAnchor(let raw):
            return "anchor must be an A1-style cell reference (e.g. \"A1\") - got \"\(raw)\"."
        }
    }
}

/// Shared argument/rendering helpers for the database tools.
enum DatabaseToolSupport {
    static func connector() throws -> DatabaseConnector {
        guard let connector = DatabaseToolContext.shared.connector else {
            throw DatabaseToolError.noConnector
        }
        return connector
    }

    static func handle(from arguments: [String: JSONValue]) throws -> DatabaseConnector.Handle {
        guard let raw = arguments["handle"]?.stringValue, let id = UUID(uuidString: raw) else {
            throw DatabaseToolError.invalidHandle
        }
        return DatabaseConnector.Handle(id: id)
    }

    /// Renders a query result as compact TSV for the tool's human-
    /// readable `output` text - unambiguous column boundaries, cheap for
    /// a model to read, capped so one giant result does not blow out the
    /// response. `data` (see each tool below) always carries the FULL
    /// result; only this preview text is capped.
    static func renderPreview(columns: [String], rows: [[String]], previewRowLimit: Int = 20) -> String {
        var lines = [columns.joined(separator: "\t")]
        lines.append(contentsOf: rows.prefix(previewRowLimit).map { $0.joined(separator: "\t") })
        if rows.count > previewRowLimit {
            lines.append("... (\(rows.count - previewRowLimit) more row(s))")
        }
        return lines.joined(separator: "\n")
    }

    static func schemaData(_ schema: DatabaseConnector.Schema) -> JSONValue {
        .array(schema.tables.map { table in
            .object([
                "name": .string(table.name),
                "columns": .array(table.columns.map { column in
                    .object(["name": .string(column.name), "type": .string(column.type)])
                }),
            ])
        })
    }
}

// MARK: - db_attach

/// Agent tool: attach a local database/data file read-only. **Tier1**
/// (`.notify`) - a session-scoped connection, reversible by `db_detach`,
/// but worth surfacing since it names a filesystem path the agent is
/// about to read from.
public struct DatabaseAttachTool: TesseraTool {
    public let name = "db_attach"
    public let description = """
        Attach a local database or data file, read-only, for db_schema/db_query/db_import_range to \
        act on. Local file engines only, no network: .sqlite/.db (via SQLite, genuinely read-only at \
        the connection level) and .csv/.tsv/.parquet/.json/.jsonl (via DuckDB, read directly - no \
        import step). Returns a handle - pass it to the other db_* tools. A material already open as \
        a Sheet (e.g. an imported .xlsx) is NOT attached here; use sheet_read/sheet_describe for that.
        """
    public let defaultApprovalLevel = ApprovalLevel.notify

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "path": SchemaProperty(
                type: "string",
                description: "Absolute path to a local .sqlite, .db, .csv, .tsv, .parquet, .json, or .jsonl file."
            ),
        ],
        required: ["path"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let path = arguments["path"]?.stringValue, !path.isEmpty else {
            return .fail("path is required")
        }
        do {
            let connector = try DatabaseToolSupport.connector()
            let handle = try await connector.attach(path: URL(fileURLWithPath: path))
            let info = try await connector.sourceInfo(handle: handle)
            return .ok(
                "Attached \(path) - handle \(handle.id.uuidString).",
                data: [
                    "handle": .string(handle.id.uuidString),
                    "source_path": .string(info.path.path),
                    "source_hash": .string(info.hash),
                ]
            )
        } catch let error as DatabaseToolError {
            return .fail(error.errorDescription ?? "attach failed")
        } catch let error as DatabaseConnectorError {
            return .fail(error.errorDescription ?? "attach failed")
        } catch {
            return .fail(error.localizedDescription)
        }
    }
}

// MARK: - db_schema

/// Agent tool: introspect an attached source's tables/columns. **Tier0**
/// (`.auto`) - a read.
public struct DatabaseSchemaTool: TesseraTool {
    public let name = "db_schema"
    public let description = "List the tables and columns of an attached local database (db_attach's handle)."
    public let defaultApprovalLevel = ApprovalLevel.auto

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "handle": SchemaProperty(type: "string", description: "The handle returned by db_attach."),
        ],
        required: ["handle"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        do {
            let handle = try DatabaseToolSupport.handle(from: arguments)
            let connector = try DatabaseToolSupport.connector()
            let schema = try await connector.schema(handle: handle)
            let tableCount = schema.tables.count
            let columnCount = schema.tables.reduce(0) { $0 + $1.columns.count }
            return .ok(
                "\(tableCount) table(s), \(columnCount) column(s) total.",
                data: ["tables": DatabaseToolSupport.schemaData(schema)]
            )
        } catch let error as DatabaseToolError {
            return .fail(error.errorDescription ?? "schema failed")
        } catch let error as DatabaseConnectorError {
            return .fail(error.errorDescription ?? "schema failed")
        } catch {
            return .fail(error.localizedDescription)
        }
    }
}

// MARK: - db_query

/// Agent tool: run a SELECT against an attached source. **Tier0**
/// (`.auto`) - a read. SELECT-only is enforced by the engine's own
/// read-only connection mode (`DatabaseConnector.swift`'s header) - this
/// tool does not parse or allowlist `sql`. Never emits a receipt: it is a
/// read, not a mutation.
public struct DatabaseQueryTool: TesseraTool {
    public let name = "db_query"
    public let description = """
        Run a read-only SQL query (SELECT) against an attached local database. Rejected at the \
        engine's own read-only connection level if it is not a read - this tool does not inspect the \
        SQL text. For CSV/Parquet/JSON sources, reference the file directly in the SQL via DuckDB's \
        own read_csv_auto('<path>')/read_parquet('<path>')/read_json_auto('<path>') (db_schema names \
        the path). Never persists anything and never emits a receipt - use db_import_range to \
        materialize a result into a sheet.
        """
    public let defaultApprovalLevel = ApprovalLevel.auto

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "handle": SchemaProperty(type: "string", description: "The handle returned by db_attach."),
            "sql": SchemaProperty(type: "string", description: "A read-only SQL query (SELECT)."),
        ],
        required: ["handle", "sql"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let sql = arguments["sql"]?.stringValue, !sql.isEmpty else {
            return .fail("sql is required")
        }
        do {
            let handle = try DatabaseToolSupport.handle(from: arguments)
            let connector = try DatabaseToolSupport.connector()
            let result = try await connector.query(handle: handle, sql: sql)
            return .ok(
                DatabaseToolSupport.renderPreview(columns: result.columns, rows: result.rows),
                data: [
                    "columns": .array(result.columns.map { .string($0) }),
                    "rows": .array(result.rows.map { row in .array(row.map { .string($0) }) }),
                    "row_count": .number(Double(result.rows.count)),
                ]
            )
        } catch let error as DatabaseToolError {
            return .fail(error.errorDescription ?? "query failed")
        } catch let error as DatabaseConnectorError {
            return .fail(error.errorDescription ?? "query failed")
        } catch {
            return .fail(error.localizedDescription)
        }
    }
}

// MARK: - db_import_range

/// Agent tool: materialize a query result into a sheet range. **Tier1**
/// (`.notify`) - a bounded, single-entity mutation (one sheet, one
/// receipt) in the same spirit as `SheetGoalSeekTool`/`SheetSolverRunTool`.
public struct DatabaseImportRangeTool: TesseraTool {
    public let name = "db_import_range"
    public let description = """
        Run a read-only SQL query against an attached local database and materialize its result into \
        a sheet range: a header row of column names, then one row per result row, anchored at the \
        given cell. Grows the sheet's grid to fit if needed. One receipt carrying full audit \
        provenance - source file path + content hash, the SQL text, and the row count.
        """
    public let defaultApprovalLevel = ApprovalLevel.notify

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "handle": SchemaProperty(type: "string", description: "The handle returned by db_attach."),
            "sql": SchemaProperty(type: "string", description: "A read-only SQL query (SELECT) to materialize."),
            "sheet_id": SchemaProperty(type: "string", description: "UUID of the destination Sheet."),
            "anchor": SchemaProperty(
                type: "string",
                description: "A1-style top-left cell for the imported range, e.g. \"A1\". Default \"A1\".",
                defaultValue: "A1"
            ),
        ],
        required: ["handle", "sql", "sheet_id"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let sql = arguments["sql"]?.stringValue, !sql.isEmpty else {
            return .fail("sql is required")
        }
        guard let sheetIDString = arguments["sheet_id"]?.stringValue, let sheetID = UUID(uuidString: sheetIDString) else {
            return .fail("sheet_id must be a UUID")
        }
        let anchorRaw = arguments["anchor"]?.stringValue ?? "A1"
        guard let anchorRef = try? AddressParser.parseCell(anchorRaw) else {
            return .fail(DatabaseToolError.invalidAnchor(anchorRaw).errorDescription ?? "invalid anchor")
        }
        do {
            let handle = try DatabaseToolSupport.handle(from: arguments)
            let connector = try DatabaseToolSupport.connector()
            guard let sheetStore = DatabaseToolContext.shared.sheetStore else {
                return .fail(DatabaseToolError.noSheetStore.errorDescription ?? "no sheet store")
            }
            let result = try await connector.query(handle: handle, sql: sql)
            let info = try await connector.sourceInfo(handle: handle)
            let updated = try await sheetStore.importFromDatabase(
                columns: result.columns,
                rows: result.rows,
                sourcePath: info.path.path,
                sourceHash: info.hash,
                sql: sql,
                anchor: anchorRef.addr,
                for: sheetID
            )
            return .ok(
                "Imported \(result.rows.count) row(s) x \(result.columns.count) column(s) into \(updated.displayTitle) at \(anchorRef.addr.description).",
                data: [
                    "sheet_id": .string(sheetID.uuidString),
                    "row_count": .number(Double(result.rows.count)),
                    "column_count": .number(Double(result.columns.count)),
                    "source_hash": .string(info.hash),
                ]
            )
        } catch let error as DatabaseToolError {
            return .fail(error.errorDescription ?? "import failed")
        } catch let error as DatabaseConnectorError {
            return .fail(error.errorDescription ?? "import failed")
        } catch {
            return .fail(error.localizedDescription)
        }
    }
}

// MARK: - db_detach

/// Agent tool: close a session-scoped connection. **Tier1** (`.notify`),
/// matching `db_attach`'s own tier.
public struct DatabaseDetachTool: TesseraTool {
    public let name = "db_detach"
    public let description = "Close a database connection opened by db_attach."
    public let defaultApprovalLevel = ApprovalLevel.notify

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "handle": SchemaProperty(type: "string", description: "The handle returned by db_attach."),
        ],
        required: ["handle"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        do {
            let handle = try DatabaseToolSupport.handle(from: arguments)
            let connector = try DatabaseToolSupport.connector()
            await connector.detach(handle: handle)
            return .ok("Detached \(handle.id.uuidString).", data: ["handle": .string(handle.id.uuidString)])
        } catch let error as DatabaseToolError {
            return .fail(error.errorDescription ?? "detach failed")
        } catch {
            return .fail(error.localizedDescription)
        }
    }
}
