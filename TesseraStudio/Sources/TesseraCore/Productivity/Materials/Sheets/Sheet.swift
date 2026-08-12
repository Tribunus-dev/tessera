import Foundation

// MARK: - SheetColumnType

/// The declared type of a sheet column. The grid cells are
/// polymorphic (inline runs); the column type is the *hint*
/// the editor uses for per-column behaviour (numeric keyboard,
/// date picker, checkbox).
public enum SheetColumnType: String, Codable, Sendable, Hashable, CaseIterable {
    case text
    case number
    case date
    case checkbox
}

// MARK: - SheetColumn

/// One column in the sheet's logical grid. The grid itself is
/// the ``DocumentAST`` (table blocks); the columns array carries
/// the spreadsheet-level semantics (headers, widths, types) that
/// the block AST's `table` attributes don't know about.
public struct SheetColumn: Codable, Sendable, Hashable {
    public var label: String
    public var width: Double?
    public var type: SheetColumnType

    public init(
        label: String = "",
        width: Double? = nil,
        type: SheetColumnType = .text
    ) {
        self.label = label
        self.width = width
        self.type = type
    }
}

// MARK: - Sheet

/// A first-class Material in the Tessera productivity surface — an
/// Excel/openpyxl-style spreadsheet whose grid is the Block AST's
/// `table` / `tableCell` blocks (spec §4.1). Sheets are stored as
/// `graph_entity` rows with `entity_type = 'document'` and
/// `subtype = 'sheet'`, matching the universal "one row per thing"
/// pattern (see `docs/tessera-data-layer-design.md` §3). The `body`
/// column carries the serialized `Sheet` JSON (whose `body` field is
/// the `DocumentAST` table tree); `label` is the display title.
///
/// Sheets ride the same constitutional-receipt backbone as every
/// other material: every mutation produces a signed receipt. The
/// ``SheetStore`` is the seam that enforces that invariant for the
/// sheet-specific mutation vocabulary (cell, row, column, archive,
/// trash, favorite, tag, link, import).
///
/// The struct is self-contained: no data-layer imports, no
/// framework imports beyond `Foundation`.
public struct Sheet: Codable, Sendable, Identifiable, Hashable {

    public let id: UUID
    public var title: String
    public var body: DocumentAST
    public var columns: [SheetColumn]
    public var isArchived: Bool
    public var isTrashed: Bool
    public var isFavorite: Bool
    public var tags: [String]
    public var linkedEntityIDs: [UUID]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "",
        body: DocumentAST = .empty,
        columns: [SheetColumn] = [],
        isArchived: Bool = false,
        isTrashed: Bool = false,
        isFavorite: Bool = false,
        tags: [String] = [],
        linkedEntityIDs: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.columns = columns
        self.isArchived = isArchived
        self.isTrashed = isTrashed
        self.isFavorite = isFavorite
        self.tags = Self.normalizeTags(tags)
        self.linkedEntityIDs = linkedEntityIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Constants

    public static let entityType = "document"
    public static let subtype = "sheet"

    public var subtypeString: String { Self.subtype }

    // MARK: - Display

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let first = Sheet.firstHeadingText(in: body), !first.isEmpty {
            return first
        }
        return "Untitled"
    }

    public func snippet(maxLength: Int = 200) -> String {
        Sheet.plainTextSnippet(from: body, maxLength: maxLength)
    }

    public var wordCount: Int {
        Sheet.wordCount(of: body)
    }

    // MARK: - Grid geometry

    /// Number of logical rows in the primary table. Derived from
    /// the largest table block's `attributes["rows"]` (or 0 when
    /// the body has no tables).
    public var rowCount: Int {
        gridDimensions().rows
    }

    /// Number of logical columns in the primary table. Prefers the
    /// explicit `columns` array when non-empty (spreadsheet intent);
    /// otherwise falls back to the table block's `attributes["cols"]`.
    public var columnCount: Int {
        gridDimensions().cols
    }

    /// Total cell count of the primary table (rows * cols, or 0).
    public var cellCount: Int {
        let dims = gridDimensions()
        return dims.rows * dims.cols
    }

    private func gridDimensions() -> (rows: Int, cols: Int) {
        if !columns.isEmpty, body.blocks.isEmpty == false {
            if let tableDims = tableBlockDimensions() {
                return (rows: tableDims.rows, cols: max(tableDims.cols, columns.count))
            }
            return (rows: 0, cols: columns.count)
        }
        if let dims = tableBlockDimensions() { return dims }
        return (rows: 0, cols: columns.isEmpty ? 0 : columns.count)
    }

    private func tableBlockDimensions() -> (rows: Int, cols: Int)? {
        for id in body.rootChildren {
            guard let block = body.blocks[id], block.type == .table else { continue }
            let rows = block.attributes["rows"]?.numberValue ?? 0
            let cols = block.attributes["cols"]?.numberValue ?? 0
            return (rows: Int(rows), cols: Int(cols))
        }
        return nil
    }

    // MARK: - Cell access helpers

    /// The ordered list of cell block IDs for the primary table.
    /// The table's `children` array is the cell list; its `attributes["rows"]`
    /// / `attributes["cols"]` encode the dimensions. Cells are row-major.
    public var tableCellIDs: [UUID] {
        for id in body.rootChildren {
            guard let block = body.blocks[id], block.type == .table else { continue }
            return block.children
        }
        return []
    }

    /// Plain text of the cell at (row, col) in the primary table,
    /// or "" when the cell is absent. Rows and cols are 0-indexed.
    public func cellText(row: Int, col: Int) -> String {
        guard let blockID = cellID(row: row, col: col),
              let block = body.blocks[blockID] else { return "" }
        return block.content.map { $0.text }.joined()
    }

    private func cellID(row: Int, col: Int) -> UUID? {
        guard let dims = tableBlockDimensions() else { return nil }
        guard row >= 0, row < dims.rows, col >= 0, col < dims.cols else { return nil }
        let index = row * dims.cols + col
        let ids = tableCellIDs
        guard index >= 0, index < ids.count else { return nil }
        return ids[index]
    }

    // MARK: - Tag normalization

    public static func normalizeTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in tags {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                out.append(trimmed)
            }
        }
        return out
    }

    // MARK: - Table factory

    /// Create a Sheet with a blank table of the given dimensions.
    /// Every cell is an empty `tableCell` block; the `table` block
    /// carries `rows`/`cols` attributes. The `columns` array is
    /// initialized with empty labels and `.text` type.
    public static func makeBlank(title: String, rows: Int, cols: Int) -> Sheet {
        let cellIDs: [UUID] = (0..<(rows * cols)).map { _ in UUID() }
        var blocks: [UUID: Block] = [:]
        for id in cellIDs {
            blocks[id] = Block(type: .tableCell, content: [])
        }
        let tableID = UUID()
        blocks[tableID] = Block(
            id: tableID,
            type: .table,
            attributes: [
                "rows": .number(Double(rows)),
                "cols": .number(Double(cols)),
            ],
            children: cellIDs
        )
        let ast = DocumentAST(blocks: blocks, rootChildren: [tableID])
        let columnDefs = (0..<cols).map { i in
            SheetColumn(label: columnLabel(index: i), type: .text)
        }
        return Sheet(title: title, body: ast, columns: columnDefs)
    }

    private static func columnLabel(index: Int) -> String {
        // A, B, ..., Z, AA, AB, ...
        var label = ""
        var n = index
        repeat {
            label = String(UnicodeScalar(65 + n % 26)!) + label
            n = n / 26 - 1
        } while n >= 0
        return label
    }

    // MARK: - Plain text + heading extraction

    public static func firstHeadingText(in ast: DocumentAST) -> String? {
        for id in ast.rootChildren {
            guard let block = ast.blocks[id] else { continue }
            if block.type == .heading {
                let text = block.content.map { $0.text }.joined()
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    public static func plainText(of ast: DocumentAST) -> String {
        var out: [String] = []
        for id in ast.rootChildren {
            appendPlainText(blockID: id, ast: ast, into: &out)
        }
        return out.joined(separator: "\n")
    }

    private static func appendPlainText(
        blockID: UUID,
        ast: DocumentAST,
        into out: inout [String]
    ) {
        guard let block = ast.blocks[blockID] else { return }
        switch block.type {
        case .paragraph, .heading, .quote, .listItem, .tableCell:
            let text = block.content.map { $0.text }.joined()
            if !text.isEmpty { out.append(text) }
        case .codeBlock:
            let text = block.content.map { $0.text }.joined()
            if !text.isEmpty { out.append(text) }
        case .callout:
            var line = ""
            if let emoji = block.attributes["emoji"]?.stringValue, !emoji.isEmpty {
                line += emoji + " "
            }
            line += block.content.map { $0.text }.joined()
            if !line.isEmpty { out.append(line) }
        case .list:
            for child in block.children {
                appendPlainText(blockID: child, ast: ast, into: &out)
            }
        case .table:
            for child in block.children {
                appendPlainText(blockID: child, ast: ast, into: &out)
            }
        case .toggle, .image, .divider, .equation, .comment, .trackInsertion, .trackDeletion:
            break
        }
        for child in block.children where block.type != .list && block.type != .table {
            appendPlainText(blockID: child, ast: ast, into: &out)
        }
    }

    public static func plainTextSnippet(from ast: DocumentAST, maxLength: Int = 200) -> String {
        let raw = plainText(of: ast)
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= maxLength { return collapsed }
        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: maxLength)
        return String(collapsed[..<endIndex]) + "…"
    }

    public static func wordCount(of ast: DocumentAST) -> Int {
        let text = plainText(of: ast)
        guard !text.isEmpty else { return 0 }
        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
    }
}

// MARK: - JSON helpers

extension Sheet {

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func from(jsonData: Data) throws -> Sheet {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Sheet.self, from: jsonData)
    }

    public func jsonDataString() throws -> String {
        let data = try jsonData()
        guard let s = String(data: data, encoding: .utf8) else {
            throw SheetStoreError.invalidBody(reason: "encoded JSON is not UTF-8")
        }
        return s
    }

    public static func from(jsonDataString: String) throws -> Sheet {
        guard let data = jsonDataString.data(using: .utf8) else {
            throw SheetStoreError.invalidBody(reason: "body is not valid UTF-8")
        }
        return try from(jsonData: data)
    }
}

// JSONValue helpers are provided by TesseraTool.swift (public
// stringValue / numberValue / boolValue); no local extension.
