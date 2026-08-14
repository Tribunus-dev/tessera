import Foundation

// MARK: - Block + table cell spans

extension Block {
    /// Rows a `.tableCell` spans downward, via `attributes["rowSpan"]`.
    /// `nil` (the common case - an unmerged cell) means 1, same "absent
    /// means default" convention as every other optional attribute in
    /// this file. Ignored on any other block type.
    public var rowSpan: Int? {
        get { attributes["rowSpan"]?.intValue }
        set {
            guard type == .tableCell else { return }
            guard let newValue, newValue > 1 else {
                attributes.removeValue(forKey: "rowSpan")
                return
            }
            attributes["rowSpan"] = .number(Double(newValue))
        }
    }

    /// Columns a `.tableCell` spans rightward. See ``rowSpan``.
    public var colSpan: Int? {
        get { attributes["colSpan"]?.intValue }
        set {
            guard type == .tableCell else { return }
            guard let newValue, newValue > 1 else {
                attributes.removeValue(forKey: "colSpan")
                return
            }
            attributes["colSpan"] = .number(Double(newValue))
        }
    }

    /// `rowSpan ?? 1`, clamped to at least 1 - what layout math should
    /// read instead of the raw optional.
    public var effectiveRowSpan: Int { max(rowSpan ?? 1, 1) }

    /// `colSpan ?? 1`, clamped to at least 1. See ``effectiveRowSpan``.
    public var effectiveColSpan: Int { max(colSpan ?? 1, 1) }
}

// MARK: - TableCellPlacement

/// One `.tableCell`'s resolved position in its table's grid.
public struct TableCellPlacement: Equatable, Sendable {
    public let cellID: UUID
    public let row: Int
    public let col: Int
    public let rowSpan: Int
    public let colSpan: Int
}

// MARK: - TableLayout

/// Resolves a `.table` block's flat, row-major `children` list into
/// actual grid positions.
///
/// A table's `children` is a flat cell list with no per-cell row/col
/// attribute (see `BlockType.table`'s doc comment) - position is
/// implicit in document order. Without spans that is just
/// `index = row * cols + col`; a spanning cell occupies more than one
/// grid slot, so a later cell in the same row must skip past it. This
/// is the same layout algorithm HTML table rendering itself uses,
/// which keeps a merged cell's later siblings landing in the right
/// column without the document format needing to store row/col
/// explicitly on every cell.
public enum TableLayout {

    /// Every cell's resolved (row, col) origin and span, in document
    /// order. Malformed data (an `attributes["cols"]` of 0 or absent)
    /// falls back to `cols = 1` - one cell per row - rather than
    /// producing an empty layout.
    public static func placements(for table: Block, in ast: DocumentAST) -> [TableCellPlacement] {
        let cols = max(table.attributes["cols"]?.intValue ?? 1, 1)
        var occupied: Set<Int> = []
        var placements: [TableCellPlacement] = []
        var row = 0
        var col = 0

        func advanceToFreeSlot() {
            while occupied.contains(row * cols + col) {
                col += 1
                if col >= cols {
                    col = 0
                    row += 1
                }
            }
        }

        for cellID in table.children {
            guard let cell = ast.blocks[cellID] else { continue }
            advanceToFreeSlot()
            let rowSpan = cell.effectiveRowSpan
            let colSpan = cell.effectiveColSpan
            placements.append(TableCellPlacement(cellID: cellID, row: row, col: col, rowSpan: rowSpan, colSpan: colSpan))
            for r in row..<(row + rowSpan) {
                for c in col..<(col + colSpan) {
                    occupied.insert(r * cols + c)
                }
            }
            col += 1
            if col >= cols {
                col = 0
                row += 1
            }
        }
        return placements
    }

    /// `placements(for:in:)` grouped by row, each row sorted by
    /// column - what a renderer walks to emit one `<tr>` per row
    /// instead of dumping every cell into one, which is what
    /// `DocumentExporter` used to do before this existed.
    public static func rows(for table: Block, in ast: DocumentAST) -> [[TableCellPlacement]] {
        let placements = placements(for: table, in: ast)
        let rowCount = (placements.map(\.row).max() ?? -1) + 1
        var byRow = Array(repeating: [TableCellPlacement](), count: rowCount)
        for p in placements { byRow[p.row].append(p) }
        return byRow.map { $0.sorted { $0.col < $1.col } }
    }
}

// MARK: - DocumentAST + table cell merging

extension DocumentAST {

    public enum TableMergeError: Error, Sendable, Equatable {
        /// `tableID` isn't a block in this document.
        case tableNotFound
        /// `tableID` resolves to a block, but it isn't a `.table`.
        case notATable
        /// The requested rectangle isn't at least 1x1, or runs past
        /// the table's own row/column count.
        case regionOutOfBounds
        /// A cell inside the rectangle extends outside it (e.g. an
        /// existing merge straddles the new rectangle's edge) - merging
        /// would either silently shrink that cell or corrupt the grid,
        /// so this is refused rather than guessed at.
        case regionOverlapsExistingSpan
    }

    /// Merge every cell inside the `rowSpan` x `colSpan` rectangle
    /// whose top-left corner is `(topLeftRow, topLeftCol)` into the one
    /// cell already at that corner: the survivor's `rowSpan`/`colSpan`
    /// are set to cover the rectangle, and every other cell strictly
    /// inside it is deleted from both the table's `children` and the
    /// document's `blocks` (its content is simply dropped - the caller
    /// is responsible for asking the user first if that matters).
    ///
    /// Returns `.failure` without mutating anything on any of the
    /// error conditions - this never leaves a table half-merged.
    public func mergingTableCells(
        tableID: UUID,
        topLeftRow: Int,
        topLeftCol: Int,
        rowSpan: Int,
        colSpan: Int
    ) -> Result<DocumentAST, TableMergeError> {
        guard let table = blocks[tableID] else { return .failure(.tableNotFound) }
        guard table.type == .table else { return .failure(.notATable) }

        let cols = max(table.attributes["cols"]?.intValue ?? 1, 1)
        let rows = max(table.attributes["rows"]?.intValue ?? 1, 1)
        guard topLeftRow >= 0, topLeftCol >= 0, rowSpan >= 1, colSpan >= 1,
              topLeftRow + rowSpan <= rows, topLeftCol + colSpan <= cols
        else {
            return .failure(.regionOutOfBounds)
        }

        let targetRows = topLeftRow..<(topLeftRow + rowSpan)
        let targetCols = topLeftCol..<(topLeftCol + colSpan)

        var survivorID: UUID?
        var toRemove: [UUID] = []
        for placement in TableLayout.placements(for: table, in: self) {
            let placementRows = placement.row..<(placement.row + placement.rowSpan)
            let placementCols = placement.col..<(placement.col + placement.colSpan)
            guard placementRows.overlaps(targetRows) && placementCols.overlaps(targetCols) else { continue }

            let fullyContained = placementRows.lowerBound >= targetRows.lowerBound
                && placementRows.upperBound <= targetRows.upperBound
                && placementCols.lowerBound >= targetCols.lowerBound
                && placementCols.upperBound <= targetCols.upperBound
            guard fullyContained else { return .failure(.regionOverlapsExistingSpan) }

            if placement.row == topLeftRow && placement.col == topLeftCol {
                survivorID = placement.cellID
            } else {
                toRemove.append(placement.cellID)
            }
        }
        guard let survivorID else { return .failure(.regionOutOfBounds) }

        var updated = self
        updated.blocks[survivorID]?.rowSpan = rowSpan
        updated.blocks[survivorID]?.colSpan = colSpan
        for id in toRemove {
            updated.blocks.removeValue(forKey: id)
        }
        updated.blocks[tableID]?.children.removeAll { toRemove.contains($0) }
        return .success(updated)
    }
}
