//===----------------------------------------------------------------------===//
//  SheetTools.swift
//  Tessera Studio
//
//  The agent's access to the open workbook. Until these existed the
//  agent could quantize a model and search the web but could not read
//  or change a single cell.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Workbook access

/// Where the sheet tools find the workbook to act on.
///
/// Empty by default: with no Sheets surface open the tools report that
/// rather than inventing a workbook. The app installs the live engine
/// when the surface bootstraps and clears it when the surface closes.
/// Same shape as `TesseraApprovalEngine.autonomy`, which defaults to a
/// no-op service until `TesseraLearningServices.installDefaults` runs.
public final class SheetToolContext: @unchecked Sendable {
    public static let shared = SheetToolContext()

    /// Persists one cell edit exactly as the UI does: source text into
    /// the document, plus a receipt.
    ///
    /// Without it a tool write would change only in-memory calculation -
    /// invisible on the next load, and outside the receipt chain, which
    /// is the opposite of what an auditable agent edit has to be.
    public typealias CellWriter = @Sendable (_ row: Int, _ col: Int, _ text: String) async throws -> Void

    private let lock = NSLock()
    private var _workbook: SheetEngine?
    private var _writer: CellWriter?

    public init() {}

    /// The workbook the agent acts on, or nil when none is open.
    public var workbook: SheetEngine? {
        get { lock.lock(); defer { lock.unlock() }; return _workbook }
        set { lock.lock(); defer { lock.unlock() }; _workbook = newValue }
    }

    /// How a tool write reaches the document. Nil when no surface is
    /// wired, in which case writes stay in memory and say so.
    public var writer: CellWriter? {
        get { lock.lock(); defer { lock.unlock() }; return _writer }
        set { lock.lock(); defer { lock.unlock() }; _writer = newValue }
    }

    /// Install the open workbook and its persistence path. Called by the
    /// Sheets surface on selection, and with nils when it closes.
    public func install(_ engine: SheetEngine?, writer: CellWriter? = nil) {
        workbook = engine
        self.writer = writer
    }
}

/// Shared argument handling for the sheet tools.
enum SheetToolSupport {
    static func workbook() throws -> SheetEngine {
        guard let engine = SheetToolContext.shared.workbook else {
            throw SheetToolError.noWorkbook
        }
        return engine
    }

    /// Parse an A1 reference or an A1:B5 range into the addresses it
    /// covers, along with its shape.
    static func addresses(for reference: String) throws -> (cells: [[CellAddr]], isSingle: Bool) {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        if trimmed.contains(":") {
            let range = try AddressParser.parseRange(trimmed)
            var grid: [[CellAddr]] = []
            for row in range.topLeft.row...range.bottomRight.row {
                var line: [CellAddr] = []
                for col in range.topLeft.col...range.bottomRight.col {
                    line.append(CellAddr(col: col, row: row))
                }
                grid.append(line)
            }
            return (grid, false)
        }
        let ref = try AddressParser.parseCell(trimmed)
        return ([[ref.addr]], true)
    }

    /// Render a grid of values as TSV, which is compact for a model to
    /// read and unambiguous about row and column boundaries.
    static func renderTSV(_ grid: [[Value]]) -> String {
        grid.map { row in
            row.map { $0.asString }.joined(separator: "\t")
        }.joined(separator: "\n")
    }
}

enum SheetToolError: LocalizedError {
    case noWorkbook

    var errorDescription: String? {
        switch self {
        case .noWorkbook:
            return "No workbook is open. Open a sheet in the Sheets surface first."
        }
    }
}

// MARK: - sheet_read

/// Read a cell or range. Read-only, so it runs without a prompt.
public struct SheetReadTool: TesseraTool {
    public let name = "sheet_read"
    public let description = """
        Read a cell or range from the open workbook. Returns tab-separated \
        values, one line per row. Use this before writing so an edit is \
        based on what is actually in the sheet.
        """
    public let defaultApprovalLevel = ApprovalLevel.auto

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "reference": SchemaProperty(
                type: "string",
                description: "A cell like B4 or a range like A1:D20."
            ),
            "sheet": SchemaProperty(
                type: "string",
                description: "Sheet name. Defaults to the active sheet."
            ),
        ],
        required: ["reference"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let reference = arguments["reference"]?.stringValue else {
            return .fail("Missing 'reference'.")
        }
        let sheet = arguments["sheet"]?.stringValue
        let engine: SheetEngine
        do { engine = try SheetToolSupport.workbook() } catch { return .fail(error.localizedDescription) }

        let grid: [[CellAddr]]
        do { grid = try SheetToolSupport.addresses(for: reference).cells }
        catch { return .fail("Could not parse reference '\(reference)'.") }

        let values = grid.map { row in
            row.map { engine.getValue(sheet: sheet, addr: $0) }
        }
        return .ok(SheetToolSupport.renderTSV(values), data: [
            "reference": .string(reference),
            "rows": .number(Double(values.count)),
            "cols": .number(Double(values.first?.count ?? 0)),
        ])
    }
}

// MARK: - sheet_write

/// Write a value or a formula into a cell.
///
/// Mutating, so it runs at `.prompt`: the safety spine rates a write as
/// medium risk and asks the user before it lands. A range write is
/// applied cell by cell so a failure part-way leaves the rest intact and
/// the response says exactly how far it got.
public struct SheetWriteTool: TesseraTool {
    public let name = "sheet_write"
    public let description = """
        Write into the open workbook. `value` starting with '=' is stored \
        as a formula, otherwise as a literal. Writing a range repeats the \
        value across it. Read the target first; this overwrites.
        """
    public let defaultApprovalLevel = ApprovalLevel.prompt

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "reference": SchemaProperty(
                type: "string",
                description: "A cell like B4 or a range like A1:A10."
            ),
            "value": SchemaProperty(
                type: "string",
                description: "Literal text/number, or a formula beginning with '='."
            ),
            "sheet": SchemaProperty(
                type: "string",
                description: "Sheet name. Defaults to the active sheet."
            ),
        ],
        required: ["reference", "value"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let reference = arguments["reference"]?.stringValue else {
            return .fail("Missing 'reference'.")
        }
        guard let raw = arguments["value"]?.stringValue else {
            return .fail("Missing 'value'.")
        }
        let sheet = arguments["sheet"]?.stringValue
        let engine: SheetEngine
        do { engine = try SheetToolSupport.workbook() } catch { return .fail(error.localizedDescription) }

        let grid: [[CellAddr]]
        do { grid = try SheetToolSupport.addresses(for: reference).cells }
        catch { return .fail("Could not parse reference '\(reference)'.") }

        let isFormula = SheetWorkbook.isFormula(raw)
        // When the Sheets surface is open, route through its persistence
        // path so the edit lands in the document with a receipt, exactly
        // like a typed one. Otherwise fall back to calculating in memory
        // and say so in the response rather than implying it was saved.
        let writer = SheetToolContext.shared.writer
        var written = 0
        for row in grid {
            for addr in row {
                if let writer {
                    do {
                        try await writer(addr.row, addr.col, raw)
                    } catch {
                        return .fail("Write failed at \(addr.description) after \(written) cell(s): \(error.localizedDescription)")
                    }
                } else if isFormula {
                    do {
                        _ = try engine.setFormula(sheet: sheet, addr: addr, source: raw)
                    } catch {
                        // Report the address that failed rather than a
                        // bare "write failed": a circular reference names
                        // the cell the user has to look at.
                        return .fail("Write failed at \(addr.description) after \(written) cell(s): \(error.localizedDescription)")
                    }
                } else {
                    engine.setValue(sheet: sheet, addr: addr, value: Self.literal(raw))
                }
                written += 1
            }
        }

        // Echo the resulting values so the agent sees what the write
        // actually produced - a formula's computed result, not its text.
        let results = grid.map { row in row.map { engine.getValue(sheet: sheet, addr: $0) } }
        let persisted = writer != nil
        let note = persisted ? "" : " (not saved: no sheet surface is open)"
        return .ok(
            "Wrote \(written) cell(s) to \(reference)\(note).\n\(SheetToolSupport.renderTSV(results))",
            data: [
                "reference": .string(reference),
                "written": .number(Double(written)),
                "isFormula": .bool(isFormula),
                "persisted": .bool(persisted),
            ]
        )
    }

    /// Literal typing is shared with the grid's own edit path, so a
    /// value the agent writes is typed exactly like one the user types.
    static func literal(_ raw: String) -> Value {
        SheetWorkbook.literal(raw)
    }
}

// MARK: - sheet_describe

/// Describe the workbook: sheet names and where the data actually is.
/// Read-only.
public struct SheetDescribeTool: TesseraTool {
    public let name = "sheet_describe"
    public let description = """
        List the sheets in the open workbook and the extent of the data \
        on each. Use this first to find out what is there before reading.
        """
    public let defaultApprovalLevel = ApprovalLevel.auto

    public let parameters = JSONSchema(type: "object", properties: [:], required: [])

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        let engine: SheetEngine
        do { engine = try SheetToolSupport.workbook() } catch { return .fail(error.localizedDescription) }

        let names = engine.sheetNames
        var lines: [String] = ["active: \(engine.activeSheet)"]
        for name in names {
            let extent = engine.usedExtent(sheet: name)
            if let extent {
                lines.append("\(name): \(extent.topLeft.description):\(extent.bottomRight.description)")
            } else {
                lines.append("\(name): empty")
            }
        }
        return .ok(lines.joined(separator: "\n"), data: [
            "sheets": .array(names.map { .string($0) }),
            "active": .string(engine.activeSheet),
        ])
    }
}
