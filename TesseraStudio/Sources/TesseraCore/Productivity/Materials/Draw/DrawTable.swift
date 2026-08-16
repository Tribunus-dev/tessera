//===----------------------------------------------------------------------===//
//  DrawTable.swift
//  Tessera Studio
//
//  Item 2.12 (Draw advanced, no prior design doc - see this wave's
//  findings file for the ratification write-up): a Draw-native table -
//  a grid of cells living ON a Drawing's canvas, positioned/sized like
//  any other shape, distinct from Calc's `Sheet` grid and Writer's
//  `BlockType.table` (a flowed, row-major `[Block]` list inside a text
//  document's own AST).
//
//  MODELING DECISION: `DrawTable` is a plain value type, hosted via a
//  new `ShapeKind.table` case + `Shape.table: DrawTable?` (the SAME
//  "ShapeKind case + orthogonal payload field" shape `.bezier`/`.path`
//  already established) rather than a second top-level entity living
//  in `Drawing.tables` alongside `shapes`/`layers`. That second option
//  was seriously considered - it would have avoided rippling into
//  ODGBridgeFilter.swift/ShapeCatalog.swift's own exhaustive `ShapeKind`
//  switches (both outside this track's owned file list; see the
//  findings file for the exact follow-up those two files need) - but
//  was rejected: a table needs the SAME positioning, z-order, layer
//  membership, group, snap, and transform behavior every other shape
//  already gets for free through `Drawing`'s `[Shape]`-based machinery
//  (`DrawingStore.setGeometry`/`.setZOrder`/`LayerStore`/`SnapEngine`/
//  `TransformController`/`group`/`ungroup`). Building a parallel
//  top-level entity would mean duplicating every one of those
//  subsystems for `tables` too - exactly the "invasive change that
//  adds a new subsystem" AGENTS.md warns against. Piggybacking on
//  `Shape` costs one enum case and two other files' exhaustive
//  switches (a documented, precisely-scoped follow-up); building a
//  second subsystem would cost far more and duplicate logic that
//  already exists and is already tested.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - DrawTableCell

/// One cell's content. Reuses `ShapeText` (not a bespoke cell-text
/// type) for the same reason `Shape.text` already uses it - a Draw
/// table's cell text should support the exact same inline runs (and,
/// per item 2.12's bullet-list evolution, the exact same bulleted-list
/// mode) any other shape's text does, with no second text stack.
public struct DrawTableCell: Codable, Sendable, Hashable {
    public var text: ShapeText
    /// Per-cell background, painted before `text` - independent of the
    /// table shape's own `Shape.fill` (which, when set, paints the
    /// whole table's outer bounding box before any per-cell fill, so a
    /// cell with `fill == nil` shows the table's own background
    /// through, matching how a spreadsheet cell with no explicit fill
    /// shows the sheet's background).
    public var fill: ShapeFill?

    public init(text: ShapeText = ShapeText(), fill: ShapeFill? = nil) {
        self.text = text
        self.fill = fill
    }
}

// MARK: - DrawTable

/// A Draw-native table's real content (`Shape.table`, `ShapeKind
/// .table`) - a fixed `rowCount` x `columnCount` grid.
///
/// SCOPE DECISION (recorded for architect ratification, per this
/// wave's own instructions): this wave ships table CREATION
/// (`DrawingStore.insertTable`) and per-cell CONTENT editing
/// (`DrawingStore.setTableCell`) - the core "Draw-side table" mutation
/// surface the brief names. Row/column INSERT/DELETE/RESIZE (beyond
/// whole-table resize, which already works for free via the existing
/// `DrawingStore.setGeometry`/`.setGeometries` - resizing `geometry`
/// does not by itself redistribute `columnWidths`/`rowHeights`, a
/// known, documented gap) is DEFERRED: it is real additional surface
/// (grid reflow, cell-merge-adjacent bookkeeping) that does not fit
/// cleanly in this wave's remaining budget alongside the other 3 items
/// + morph. Cell count is fixed at construction; a future wave can add
/// `DrawingStore.insertTableRow`/`.insertTableColumn`/etc. as pure
/// `DrawTable` mutators plus their own `DrawingStore` wrappers,
/// following the exact pattern every method in this file's sibling
/// `DrawingStore.swift` already uses - no new subsystem needed.
public struct DrawTable: Codable, Sendable, Hashable {
    public var rowCount: Int
    public var columnCount: Int
    /// Flat, row-major list of cells - `rowCount * columnCount` entries
    /// (`cell(row:column:)`/`index(row:column:)` resolve
    /// `row * columnCount + column`), matching `BlockType.table`'s own
    /// documented flat-list convention (`Block.swift`'s doc comment:
    /// "`children` is a FLAT, row-major list of `.tableCell` blocks")
    /// rather than a nested `[[DrawTableCell]]` grid - so a Draw
    /// table's cell layout is derived identically to how a Writer
    /// table's already is, not a second convention.
    public var cells: [DrawTableCell]
    /// Column widths, local points, `columnCount` entries.
    public var columnWidths: [Double]
    /// Row heights, local points, `rowCount` entries.
    public var rowHeights: [Double]
    /// The grid-line stroke (row/column dividers) - independent of the
    /// table shape's own `Shape.stroke`, which (when set) strokes only
    /// the table's OUTER bounding box once, via the same generic
    /// mechanism every other shape's stroke already uses
    /// (`ShapeRenderer.render`'s unconditional stroke block). `nil`
    /// draws no internal grid lines (a borderless table).
    public var gridStroke: ShapeStroke?

    /// A blank `rowCount` x `columnCount` table with uniform
    /// `defaultColumnWidth`/`defaultRowHeight` and empty cells. Both
    /// counts are clamped to `>= 1` - a table with zero rows or columns
    /// is not a meaningful grid, matching this codebase's "no negative
    /// (or, here, degenerate-zero) magnitude" convention for structural
    /// counts.
    public init(
        rowCount: Int,
        columnCount: Int,
        defaultColumnWidth: Double = 80,
        defaultRowHeight: Double = 24,
        gridStroke: ShapeStroke? = ShapeStroke(colorHex: "#999999", width: 1)
    ) {
        self.rowCount = max(1, rowCount)
        self.columnCount = max(1, columnCount)
        self.cells = Array(repeating: DrawTableCell(), count: self.rowCount * self.columnCount)
        self.columnWidths = Array(repeating: max(0, defaultColumnWidth), count: self.columnCount)
        self.rowHeights = Array(repeating: max(0, defaultRowHeight), count: self.rowCount)
        self.gridStroke = gridStroke
    }

    /// Full-fidelity init (round-trip / test construction): every
    /// field supplied directly, no defaulting. `cells`/`columnWidths`/
    /// `rowHeights` are NOT validated against `rowCount`/`columnCount`
    /// here - a mismatched count is the same "malformed data degrades,
    /// doesn't crash" contract `cell(row:column:)` below documents,
    /// not a precondition trap.
    public init(rowCount: Int, columnCount: Int, cells: [DrawTableCell], columnWidths: [Double], rowHeights: [Double], gridStroke: ShapeStroke?) {
        self.rowCount = max(1, rowCount)
        self.columnCount = max(1, columnCount)
        self.cells = cells
        self.columnWidths = columnWidths
        self.rowHeights = rowHeights
        self.gridStroke = gridStroke
    }

    /// The flat-list index for `(row, column)`, or `nil` when either is
    /// out of `0..<rowCount`/`0..<columnCount`.
    public func index(row: Int, column: Int) -> Int? {
        guard (0..<rowCount).contains(row), (0..<columnCount).contains(column) else { return nil }
        return row * columnCount + column
    }

    /// The cell at `(row, column)`, or `nil` for an out-of-range
    /// position OR a `cells` array that (via manual construction, or a
    /// legacy/foreign document) is shorter than `rowCount *
    /// columnCount` expects - degrades to `nil` rather than trapping,
    /// matching `ShapePathSegment`/`ConnectorRouter`'s own "malformed
    /// data doesn't crash" convention throughout this directory.
    public func cell(row: Int, column: Int) -> DrawTableCell? {
        guard let idx = index(row: row, column: column), cells.indices.contains(idx) else { return nil }
        return cells[idx]
    }

    /// A copy with the cell at `(row, column)` replaced - a no-op
    /// (returns `self` unchanged) for an out-of-range position, same
    /// degrade-not-crash contract as `cell(row:column:)`.
    public func settingCell(_ cell: DrawTableCell, row: Int, column: Int) -> DrawTable {
        guard let idx = index(row: row, column: column), cells.indices.contains(idx) else { return self }
        var updated = self
        updated.cells[idx] = cell
        return updated
    }

    /// The table's own outer bounding box - `Shape.geometry`'s
    /// width/height is documented as kept in sync with this (see
    /// `ShapeKind.table`'s doc comment); this is that sync operation's
    /// source of truth, mirroring `ShapePath.boundingBox`'s identical
    /// role for `.bezier`.
    public var totalWidth: Double { columnWidths.reduce(0, +) }
    public var totalHeight: Double { rowHeights.reduce(0, +) }
}
