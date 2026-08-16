import Foundation

// MARK: - PivotTableStoreError

/// Errors `PivotTableStore.build(sheet:definition:)` can throw. All are
/// definition/sheet mismatches discoverable before any aggregation runs
/// - there is no "computation failed" case, since the aggregation math
/// itself (see `PivotTableStore.aggregate(_:values:)`) is total over any
/// `[CellValue]` input.
public enum PivotTableStoreError: Error, Equatable, Sendable {
    /// `definition.sourceRangeRef` is nil (a negative coordinate).
    case invalidSourceRange
    /// A field names a column with no matching `Sheet.columns` label.
    case unknownField(String)
    /// A field names a real column, but one outside the definition's
    /// own source range rectangle.
    case fieldOutsideSourceRange(String)
    /// No `orientation == .data` field is configured - nothing to
    /// aggregate, so there is nothing to write into the grid body.
    case noDataFields
}

// MARK: - PivotResultGrid

/// The computed output of one pivot: a plain rectangular grid of
/// `CellValue`, one entry per cell exactly as it would be pasted into
/// the sheet starting at the definition's output top-left - headers,
/// the aggregated body, and (per `columnGrand`/`rowGrand`) the grand
/// total row/column, all in one array of rows. `SheetStore`'s future
/// pivot-writing method (see this track's wiringNotes) does not need to
/// interpret row/column-field structure itself; it only needs to paste
/// `rows` and knows which of the leading rows/columns are headers via
/// `headerRowCount`/`headerColumnCount`.
///
/// `rows` is always rectangular: every entry has the same `.count` as
/// `rows.first` (enforced by construction in `PivotTableStore.build`,
/// not re-validated here - this is a plain value type, not a validator).
public struct PivotResultGrid: Sendable, Equatable {
    public var rows: [[CellValue]]
    /// How many of the leading rows are header rows (column-field
    /// value levels, plus one data-field-name level) versus the
    /// aggregated body.
    public var headerRowCount: Int
    /// How many of the leading columns in every row are row-field
    /// label columns versus the aggregated body.
    public var headerColumnCount: Int

    public init(rows: [[CellValue]], headerRowCount: Int, headerColumnCount: Int) {
        self.rows = rows
        self.headerRowCount = headerRowCount
        self.headerColumnCount = headerColumnCount
    }

    public var rowCount: Int { rows.count }
    public var columnCount: Int { rows.first?.count ?? 0 }
}

// MARK: - PivotTableStore

/// The Pivot Tables compute engine (P2-A 2.2a) - peer of `QueryEngine`:
/// a plain, stateless namespace with no `dataLayer` dependency, pure
/// end to end. Takes a `Sheet` + `SheetPivotDefinition`, returns a
/// `PivotResultGrid` (or throws); never writes into a `Sheet` and never
/// calls any `SheetStore` method. `SheetStore` is the only writer of
/// the returned grid into a sheet's output range (see this track's
/// wiringNotes for the exact method the centralized pass should add).
///
/// **Pipeline** (design contract `sota-p2-core-report.md` #2.2): source
/// range -> column vectors -> page filtering -> group-key derivation
/// (member sort via `QueryEngine.sortedRowOrder`'s mixed-type order,
/// reused rather than reimplemented) -> row x column lattice -> per-
/// data-field aggregation (all 12 `SheetPivotAggregation` cases) ->
/// grand total row/column -> `PivotResultGrid`.
///
/// **P2a scope** (see `SheetPivotField`'s doc comment for the full
/// split): tabular layout + grand totals only. Per-field subtotal rows
/// (`subtotals`/`subtotalAuto`), `sort`/`autoShow`/`reference` modes,
/// declared-member row/column filtering, and date/numeric grouping
/// (`PivotGroupSpec`, design contract step 4) are P2b - this engine
/// computes a correct, ungrouped, unsorted-by-user-key pivot today and
/// grows those behaviors additively later, the same way
/// `SheetPivotAggregation` itself grew from 9 to 12 cases.
public enum PivotTableStore {

    // MARK: - build

    public static func build(sheet: Sheet, definition: SheetPivotDefinition) throws -> PivotResultGrid {
        guard let source = definition.sourceRangeRef,
              source.topLeft.row <= source.bottomRight.row,
              source.topLeft.col <= source.bottomRight.col else {
            throw PivotTableStoreError.invalidSourceRange
        }

        let rowFields = definition.fields.filter { $0.orientation == .row }
        let columnFields = definition.fields.filter { $0.orientation == .column }
        let pageFields = definition.fields.filter { $0.orientation == .page }
        let dataFields = definition.fields.filter { $0.orientation == .data }
        guard !dataFields.isEmpty else { throw PivotTableStoreError.noDataFields }

        func resolvedColumn(for fieldName: String) throws -> Int {
            guard let idx = sheet.columns.firstIndex(where: { $0.label == fieldName }) else {
                throw PivotTableStoreError.unknownField(fieldName)
            }
            guard idx >= source.topLeft.col, idx <= source.bottomRight.col else {
                throw PivotTableStoreError.fieldOutsideSourceRange(fieldName)
            }
            return idx
        }

        let rowCols = try rowFields.map { try resolvedColumn(for: $0.fieldName) }
        let columnCols = try columnFields.map { try resolvedColumn(for: $0.fieldName) }
        let pageCols = try pageFields.map { try resolvedColumn(for: $0.fieldName) }
        let dataCols = try dataFields.map { try resolvedColumn(for: $0.fieldName) }

        // Source rows -> "ignore empty rows" -> page filtering.
        var sourceRows = Array(source.topLeft.row...source.bottomRight.row)

        if definition.ignoreEmptyRows {
            let everyFieldCol = rowCols + columnCols + pageCols + dataCols
            sourceRows = sourceRows.filter { row in
                !everyFieldCol.allSatisfy { sheet.cellValue(row: row, col: $0).isEmpty }
            }
        }

        for (field, col) in zip(pageFields, pageCols) {
            guard !field.members.isEmpty else { continue }
            let selected = Set(field.members.filter { $0.visible }.map { $0.name })
            sourceRows = sourceRows.filter { row in
                selected.contains(displayText(sheet.cellValue(row: row, col: col)))
            }
        }

        // Group-key derivation: the distinct row/column value tuples
        // that actually occur in the filtered data, ordered via
        // QueryEngine's own mixed-type comparison.
        let rowCombos = distinctSortedCombos(rows: sourceRows, cols: rowCols, sheet: sheet)
        let columnCombos = distinctSortedCombos(rows: sourceRows, cols: columnCols, sheet: sheet)

        func rowsMatching(rowCombo: [CellValue], columnCombo: [CellValue]) -> [Int] {
            sourceRows.filter { row in
                zip(rowCols, rowCombo).allSatisfy { sheet.cellValue(row: row, col: $0.0) == $0.1 }
                    && zip(columnCols, columnCombo).allSatisfy { sheet.cellValue(row: row, col: $0.0) == $0.1 }
            }
        }

        func rowsMatchingRowOnly(_ rowCombo: [CellValue]) -> [Int] {
            sourceRows.filter { row in
                zip(rowCols, rowCombo).allSatisfy { sheet.cellValue(row: row, col: $0.0) == $0.1 }
            }
        }

        func rowsMatchingColumnOnly(_ columnCombo: [CellValue]) -> [Int] {
            sourceRows.filter { row in
                zip(columnCols, columnCombo).allSatisfy { sheet.cellValue(row: row, col: $0.0) == $0.1 }
            }
        }

        func aggregatedCells(for matches: [Int]) -> [CellValue] {
            zip(dataFields, dataCols).map { field, col in
                aggregate(field.function ?? .sum, values: matches.map { sheet.cellValue(row: $0, col: col) })
            }
        }

        let columnFieldLevels = columnFields.count
        let rowFieldLevels = rowFields.count

        // MARK: Header rows (columnFieldLevels value-label rows + one
        // data-field-name row).
        var headerRows: [[CellValue]] = (0...columnFieldLevels).map { level in
            var leading = Array(repeating: CellValue.empty, count: rowFieldLevels)
            if level == columnFieldLevels {
                for i in 0..<rowFieldLevels { leading[i] = .text(rowFields[i].fieldName) }
            }
            return leading
        }

        func appendHeaderBlock(columnCombo: [CellValue]?, isGrandTotal: Bool) {
            for level in 0..<columnFieldLevels {
                let value: CellValue
                if isGrandTotal {
                    value = level == 0 ? .text(definition.grandTotalName ?? "Grand Total") : .empty
                } else {
                    value = columnCombo![level]
                }
                headerRows[level].append(contentsOf: Array(repeating: value, count: dataFields.count))
            }
            for field in dataFields {
                headerRows[columnFieldLevels].append(.text(displayName(for: field.function ?? .sum) + " of " + field.fieldName))
            }
        }

        for combo in columnCombos {
            appendHeaderBlock(columnCombo: combo, isGrandTotal: false)
        }
        if definition.columnGrand {
            appendHeaderBlock(columnCombo: nil, isGrandTotal: true)
        }

        // MARK: Body rows

        var bodyRows: [[CellValue]] = []
        var previousCombo: [CellValue]? = nil
        for rowCombo in rowCombos {
            var cells: [CellValue] = []
            var sameGroupAsAbove = true
            for i in 0..<rowFieldLevels {
                let matchesAbove = sameGroupAsAbove && previousCombo != nil && previousCombo![i] == rowCombo[i]
                if matchesAbove {
                    cells.append(rowFields[i].repeatItemLabels ? rowCombo[i] : .empty)
                } else {
                    cells.append(rowCombo[i])
                    sameGroupAsAbove = false
                }
            }
            previousCombo = rowCombo

            for columnCombo in columnCombos {
                cells.append(contentsOf: aggregatedCells(for: rowsMatching(rowCombo: rowCombo, columnCombo: columnCombo)))
            }
            if definition.columnGrand {
                cells.append(contentsOf: aggregatedCells(for: rowsMatchingRowOnly(rowCombo)))
            }
            bodyRows.append(cells)
        }

        // MARK: Grand total row

        if definition.rowGrand {
            var cells: [CellValue] = Array(repeating: .empty, count: rowFieldLevels)
            if rowFieldLevels > 0 {
                cells[0] = .text(definition.grandTotalName ?? "Grand Total")
            }
            for columnCombo in columnCombos {
                cells.append(contentsOf: aggregatedCells(for: rowsMatchingColumnOnly(columnCombo)))
            }
            if definition.columnGrand {
                cells.append(contentsOf: aggregatedCells(for: sourceRows))
            }
            bodyRows.append(cells)
        }

        return PivotResultGrid(
            rows: headerRows + bodyRows,
            headerRowCount: columnFieldLevels + 1,
            headerColumnCount: rowFieldLevels
        )
    }

    // MARK: - Aggregation (all 12 SheetPivotAggregation cases)

    /// Applies one aggregation function to a set of source cells. Total
    /// over any input: an empty numeric set (all-blank, all-text, or a
    /// genuinely empty `values`) returns `.empty` for every function
    /// except `.count`/`.countNumbers` (which correctly answer `0`), and
    /// the sample statistics (`.stdDev`/`.variance`, n-1 denominator)
    /// return `.error("#DIV/0!")` on exactly one numeric value,
    /// matching Excel's STDEV/VAR on a single-cell range - the
    /// population variants (`.stdDevP`/`.varianceP`) have no such
    /// degenerate case since their denominator is N, not N-1.
    public static func aggregate(_ function: SheetPivotAggregation, values: [CellValue]) -> CellValue {
        switch function {
        case .count:
            return .number(Double(values.filter { !$0.isEmpty }.count))
        case .countNumbers:
            return .number(Double(values.compactMap { numeric($0) }.count))
        default:
            let numbers = values.compactMap { numeric($0) }
            guard !numbers.isEmpty else { return .empty }
            switch function {
            case .sum:
                return .number(numbers.reduce(0, +))
            case .average:
                return .number(numbers.reduce(0, +) / Double(numbers.count))
            case .min:
                return .number(numbers.min() ?? 0)
            case .max:
                return .number(numbers.max() ?? 0)
            case .product:
                return .number(numbers.reduce(1, *))
            case .median:
                return .number(median(numbers))
            case .stdDev:
                guard numbers.count > 1 else { return .error("#DIV/0!") }
                return .number(standardDeviation(numbers, sample: true))
            case .variance:
                guard numbers.count > 1 else { return .error("#DIV/0!") }
                return .number(variance(numbers, sample: true))
            case .stdDevP:
                return .number(standardDeviation(numbers, sample: false))
            case .varianceP:
                return .number(variance(numbers, sample: false))
            case .count, .countNumbers:
                return .empty // unreachable: handled in the outer switch
            }
        }
    }

    /// `.number`/`.date` only, matching `QueryEngine.numericSortKey`'s
    /// convention (a date's numeric key is its Unix timestamp).
    /// `.checkbox` is deliberately excluded, also matching that
    /// convention - a pivot data field of booleans counts under
    /// `.count` but contributes nothing to `.sum`/`.average`/etc.
    private static func numeric(_ value: CellValue) -> Double? {
        switch value {
        case .number(let n): return n
        case .date(let d): return d.timeIntervalSince1970
        default: return nil
        }
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    private static func variance(_ values: [Double], sample: Bool) -> Double {
        let m = mean(values)
        let sumOfSquares = values.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        let denominator = sample ? Double(values.count - 1) : Double(values.count)
        return sumOfSquares / denominator
    }

    private static func standardDeviation(_ values: [Double], sample: Bool) -> Double {
        variance(values, sample: sample).squareRoot()
    }

    private static func displayName(for function: SheetPivotAggregation) -> String {
        switch function {
        case .sum: return "Sum"
        case .count: return "Count"
        case .countNumbers: return "Count Numbers"
        case .average: return "Average"
        case .min: return "Min"
        case .max: return "Max"
        case .product: return "Product"
        case .stdDev: return "StdDev"
        case .variance: return "Var"
        case .median: return "Median"
        case .stdDevP: return "StdDevP"
        case .varianceP: return "VarP"
        }
    }

    // MARK: - Page-field display text

    /// A page field's `SheetPivotFieldMember.name` is compared against
    /// this, not `CellValue` structural equality - mirrors
    /// `QueryEngine`'s own `SheetFilterRowInput.displayText` convention
    /// (see `QueryEngine.applyFilter`'s `displayText` parameter) so a
    /// numeric field's member name ("2024") matches a `.number(2024)`
    /// cell.
    private static func displayText(_ value: CellValue) -> String {
        switch value {
        case .empty: return ""
        case .text(let s): return s
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
            return String(n)
        case .date(let d): return ISO8601DateFormatter().string(from: d)
        case .checkbox(let b): return b ? "TRUE" : "FALSE"
        case .formula(let s): return s
        case .error(let s): return s
        }
    }

    // MARK: - Group-key derivation

    /// Distinct value tuples across `cols` for the given `rows`,
    /// ordered by `QueryEngine.sortedRowOrder`'s mixed-type comparison
    /// (numbers < text < logical < error < blanks; see that function's
    /// doc comment) - reused rather than reimplemented, per the design
    /// contract. `cols.isEmpty` (no fields on this axis) returns a
    /// single empty tuple: "no grouping" still produces exactly one
    /// row/column, matching a pivot with zero row (or column) fields
    /// laying out one aggregate line rather than none.
    private static func distinctSortedCombos(rows: [Int], cols: [Int], sheet: Sheet) -> [[CellValue]] {
        guard !cols.isEmpty else { return [[]] }
        var combos: [[CellValue]] = []
        var seen: Set<[CellValue]> = []
        for row in rows {
            let combo = cols.map { sheet.cellValue(row: row, col: $0) }
            if seen.insert(combo).inserted {
                combos.append(combo)
            }
        }
        guard combos.count > 1 else { return combos }
        let conditions = cols.indices.map { SheetSortCondition(columnIndex: $0, ascending: true) }
        let order = QueryEngine.sortedRowOrder(
            rowCount: combos.count,
            conditions: conditions,
            cellValue: { virtualRow, level in combos[virtualRow][level] }
        )
        return order.map { combos[$0] }
    }
}
