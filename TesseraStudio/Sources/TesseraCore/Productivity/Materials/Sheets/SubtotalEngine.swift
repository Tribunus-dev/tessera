import Foundation

// MARK: - SubtotalRowInsertion

/// One new row `SubtotalEngine.plan` calls for: a per-group summary row
/// or the trailing grand-total row. Carries everything needed to build
/// it - position, cell content, outline level - but performs no
/// insertion itself; see `SubtotalPlan`'s header for the pure/no-mutate
/// boundary this type lives inside.
public struct SubtotalRowInsertion: Sendable, Equatable {
    /// Insert immediately BEFORE this row index of the ORIGINAL
    /// (pre-insertion) grid the plan was computed against -
    /// `originalRowCount` itself is a legal value meaning "append after
    /// the last original row" (used by `summaryBelow == true` groups
    /// whose last member is the final row, and by the grand-total row
    /// in that same mode).
    ///
    /// `SubtotalPlan.insertions` is sorted ascending by this field. A
    /// caller applying them one at a time against a real grid MUST
    /// apply them in DESCENDING index order: inserting ascending would
    /// shift every later target down by however many rows already went
    /// in above it, since each insertion's index is expressed against
    /// the ORIGINAL grid, not a running post-insertion one.
    public var beforeOriginalRow: Int
    /// column index -> cell text/formula for the new row. The
    /// `groupByColumn` cell carries "<label> Total" (or "Grand Total"
    /// for `isGrandTotal`); every column named in
    /// `SubtotalDescriptor.perColumnFunctions` carries a real
    /// `=SUBTOTAL(function_num, range)` formula string, where `range`
    /// spans the group's ORIGINAL row extent inclusive
    /// (`group.start...group.end`). That range deliberately is NOT
    /// hand-carved to skip any subtotal rows already nested inside it
    /// from an earlier, more granular pass - SUBTOTAL's own nested-call
    /// exclusion (see SubtotalFunctions.swift) is exactly what makes
    /// that carving unnecessary: the outer formula can reference the
    /// group's full span and any inner SUBTOTAL cell inside it is
    /// ignored at evaluation time.
    public var cellTexts: [Int: String]
    /// This row's assigned outline level, 0...7 (0 = not nested inside
    /// any group - the level a `SubtotalDescriptor.replaceExisting ==
    /// true` first pass's grand-total row gets). See `SubtotalPlan`'s
    /// header for the full nesting/level-assignment rule.
    public var outlineLevel: Int
    /// True for the single trailing grand-total row (if any); false for
    /// a per-group summary row.
    public var isGrandTotal: Bool

    public init(beforeOriginalRow: Int, cellTexts: [Int: String], outlineLevel: Int, isGrandTotal: Bool = false) {
        self.beforeOriginalRow = beforeOriginalRow
        self.cellTexts = cellTexts
        self.outlineLevel = outlineLevel
        self.isGrandTotal = isGrandTotal
    }
}

// MARK: - SubtotalPlan

/// The pure output of `SubtotalEngine.plan(for:descriptor:)`: which new
/// rows to insert, and the new outline level for every row that
/// already exists. Nothing in this type mutates a `Sheet` or talks to
/// `SheetStore` - see `SubtotalEngine`'s header for why that boundary
/// stops here (same reasoning as `QueryEngineOutcome` in
/// QueryEngine.swift).
///
/// **Outline-level nesting rule.** Every row already in the sheet
/// bumps its outline level by exactly 1 (capped at 7 - OOXML's row
/// `outlineLevel` ceiling) each time a NEW `plan` call groups it,
/// regardless of whether that row was a detail row or an earlier
/// pass's own summary row - it is, after all, now nested one level
/// deeper inside the new group. Each group's OWN new summary row is
/// assigned the LOWEST pre-bump level found among that group's rows
/// (equivalently `existingRowLevels[group.start]` for a well-formed
/// prior pass, where every row of one contiguous group shares a
/// level; the minimum is taken across the whole group defensively,
/// so a not-perfectly-uniform input still degrades sensibly rather
/// than picking an arbitrary member). A first pass over a sheet with
/// no existing outline therefore produces the simple, well-known
/// shape: detail rows at level 1, summary rows at level 0. A second
/// pass grouping that already-subtotaled range produces the classic
/// 3-tier shape: original detail rows bump to level 2, the first
/// pass's summary rows bump to level 1, and the new pass's own
/// (coarser) summary row sits at level 0 - the grand-total tier.
public struct SubtotalPlan: Sendable, Equatable {
    /// New summary/grand-total rows to insert, sorted ascending by
    /// `beforeOriginalRow` (apply descending - see that field's doc).
    public var insertions: [SubtotalRowInsertion]
    /// The new outline level for every row index 0..<originalRowCount -
    /// i.e. every row that existed BEFORE this plan's insertions,
    /// covering both former detail rows and any earlier pass's summary
    /// rows alike (see this type's header for the bump rule). The
    /// caller re-keys this to final (post-insertion) row indices the
    /// same pass it re-addresses formulas for the insertions
    /// themselves (`Sheet.adjustingFormulas(for:)`'s existing job for
    /// every other structural edit).
    public var existingRowLevels: [Int: Int]
    /// Echoes `SubtotalDescriptor.summaryBelow` - the wiring layer's
    /// `sheet_subtotals_applied` receipt payload wants it without
    /// re-deriving it from `insertions`.
    public var summaryBelow: Bool
    /// Number of groups this plan grouped the sheet into (0 for an
    /// empty/degenerate plan - see `SubtotalEngine.plan`'s guard
    /// clauses).
    public var groupCount: Int

    public init(insertions: [SubtotalRowInsertion], existingRowLevels: [Int: Int], summaryBelow: Bool, groupCount: Int) {
        self.insertions = insertions
        self.existingRowLevels = existingRowLevels
        self.summaryBelow = summaryBelow
        self.groupCount = groupCount
    }

    /// A plan with no insertions and no level changes - what
    /// `SubtotalEngine.plan` returns for a descriptor with nothing to
    /// group (empty sheet, or no `perColumnFunctions`).
    public static let empty = SubtotalPlan(insertions: [], existingRowLevels: [:], summaryBelow: true, groupCount: 0)
}

// MARK: - SubtotalEngine

/// Group-boundary detection, row-insertion planning, and outline-level
/// assignment for the Sheets material's "Data > Subtotal" feature -
/// peer of `QueryEngine`, same relationship to `Sheet`/
/// `SubtotalDescriptor` that `QueryEngine` has to `SheetFilterState`/
/// `SheetSortCondition`.
///
/// **Pure, no persistence.** `plan(for:descriptor:)` takes a `Sheet`
/// and a `SubtotalDescriptor` and returns a `SubtotalPlan` value - it
/// does not mutate the `Sheet`, does not call `SheetStore`, and holds
/// no state of its own. Turning a plan into real row insertions plus
/// exactly one `sheet_subtotals_applied` receipt is `SheetStore`'s job
/// (out of this file's scope this wave - see the wave's wiring notes).
public enum SubtotalEngine {

    /// Group boundaries come from display-text equality on
    /// `descriptor.groupByColumn` - the SAME notion of "display text"
    /// `QueryEngine.applyFilter`'s `.valueSet` criterion compares
    /// against (see that function's `displayText` closure parameter).
    /// `SheetStore.applyFilter`'s own wiring resolves that closure to
    /// `Sheet.cellText(row:col:)` verbatim (stored inline-run text, not
    /// a number-format-rendered string) - this engine, given a `Sheet`
    /// directly rather than a closure, reads the identical source.
    public static func plan(for sheet: Sheet, descriptor: SubtotalDescriptor) -> SubtotalPlan {
        let rowCount = sheet.rowCount
        // `CellAddr` traps on a negative coordinate (its designated
        // init's documented precondition) - guarding here, rather than
        // filtering silently deep inside `summaryRowCellTexts`, keeps
        // every code path below this line able to assume non-negative
        // indices without re-checking.
        guard rowCount > 0, descriptor.groupByColumn >= 0, !descriptor.perColumnFunctions.isEmpty,
              descriptor.perColumnFunctions.allSatisfy({ $0.columnIndex >= 0 }) else { return .empty }

        let existingLevels = sheet.effectiveRowOutlineLevels
        let groups = groupBoundaries(sheet: sheet, groupByColumn: descriptor.groupByColumn, rowCount: rowCount)

        // Every row already in the sheet nests one level deeper under
        // this new grouping, whether it was a detail row or an earlier
        // pass's own summary row - see SubtotalPlan's header.
        var existingRowLevels: [Int: Int] = [:]
        existingRowLevels.reserveCapacity(rowCount)
        for row in 0..<rowCount {
            existingRowLevels[row] = min(7, (existingLevels[row] ?? 0) + 1)
        }

        var insertions: [SubtotalRowInsertion] = []
        insertions.reserveCapacity(groups.count + 1)

        for group in groups {
            let summaryLevel = (group.start...group.end)
                .map { existingLevels[$0] ?? 0 }
                .min() ?? 0
            let cellTexts = summaryRowCellTexts(
                label: "\(group.label) Total",
                startRow: group.start,
                endRow: group.end,
                descriptor: descriptor
            )
            let insertAt = descriptor.summaryBelow ? group.end + 1 : group.start
            insertions.append(SubtotalRowInsertion(
                beforeOriginalRow: insertAt,
                cellTexts: cellTexts,
                outlineLevel: summaryLevel
            ))
        }

        // The grand total always joins the plan (Excel/LO's Subtotal
        // dialog adds one unconditionally, even over a single group,
        // where its range is identical to that lone group's own
        // summary row - a real, if visually redundant, second row).
        // It sits at the shallowest possible level (0): it is, by
        // definition, outside every group this pass created.
        let grandTexts = summaryRowCellTexts(
            label: "Grand Total",
            startRow: 0,
            endRow: rowCount - 1,
            descriptor: descriptor
        )
        let grandInsertAt = descriptor.summaryBelow ? rowCount : 0
        insertions.append(SubtotalRowInsertion(
            beforeOriginalRow: grandInsertAt,
            cellTexts: grandTexts,
            outlineLevel: 0,
            isGrandTotal: true
        ))

        insertions.sort { $0.beforeOriginalRow < $1.beforeOriginalRow }
        return SubtotalPlan(
            insertions: insertions,
            existingRowLevels: existingRowLevels,
            summaryBelow: descriptor.summaryBelow,
            groupCount: groups.count
        )
    }

    // MARK: - Group boundaries

    private struct Group {
        var start: Int
        var end: Int  // inclusive
        var label: String
    }

    /// Contiguous runs of rows sharing the same display text in
    /// `groupByColumn` - the grid is assumed pre-sorted on that column
    /// (matching Excel/LO's own Subtotal precondition), so equal labels
    /// that are NOT contiguous form separate groups rather than being
    /// merged; that is the correct, unsurprising behavior for
    /// unsorted input, not a bug to work around here.
    private static func groupBoundaries(sheet: Sheet, groupByColumn: Int, rowCount: Int) -> [Group] {
        guard rowCount > 0 else { return [] }
        var groups: [Group] = []
        var runStart = 0
        var runLabel = sheet.cellText(row: 0, col: groupByColumn)
        if rowCount > 1 {
            for row in 1..<rowCount {
                let label = sheet.cellText(row: row, col: groupByColumn)
                if label != runLabel {
                    groups.append(Group(start: runStart, end: row - 1, label: runLabel))
                    runStart = row
                    runLabel = label
                }
            }
        }
        groups.append(Group(start: runStart, end: rowCount - 1, label: runLabel))
        return groups
    }

    // MARK: - Summary row content

    private static func summaryRowCellTexts(
        label: String,
        startRow: Int,
        endRow: Int,
        descriptor: SubtotalDescriptor
    ) -> [Int: String] {
        var cellTexts: [Int: String] = [descriptor.groupByColumn: label]
        for entry in descriptor.perColumnFunctions {
            let range = "\(CellAddr(col: entry.columnIndex, row: startRow)):\(CellAddr(col: entry.columnIndex, row: endRow))"
            cellTexts[entry.columnIndex] = "=SUBTOTAL(\(entry.function.functionNum),\(range))"
        }
        return cellTexts
    }
}

// MARK: - Sheet.effectiveRowOutlineLevels / effectiveOutlineSummaryBelow

/// This file owns the outline concept, so - matching
/// `QueryEngine.swift`'s `effectiveFilterState`/
/// `SheetPivotDefinition.swift`'s `effectivePivotDefinitions`
/// convention of the concept's owning file extending `Sheet` - it also
/// owns the "nil means default" read-through for `Sheet.rowOutlineLevels`
/// / `Sheet.outlineSummaryBelow`.
public extension Sheet {
    var effectiveRowOutlineLevels: [Int: Int] {
        rowOutlineLevels ?? [:]
    }

    var effectiveOutlineSummaryBelow: Bool {
        outlineSummaryBelow ?? true
    }
}
