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
/// total row/column, all in one array of rows. `SheetStore`'s pivot-
/// writing methods (`definePivot`/`refreshPivot`) do not need to
/// interpret row/column-field structure themselves; they only need to
/// paste `rows` and know which of the leading rows/columns are headers
/// via `headerRowCount`/`headerColumnCount`.
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
    /// label columns versus the aggregated body. 1 when the outermost
    /// row field's layout mode is `.compact` (every row-field level
    /// collapsed into one column - see `PivotTableStore`'s doc
    /// comment); otherwise the row-field count.
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

/// The Pivot Tables compute engine - peer of `QueryEngine`: a plain,
/// stateless namespace with no `dataLayer` dependency, pure end to end.
/// Takes a `Sheet` + `SheetPivotDefinition`, returns a `PivotResultGrid`
/// (or throws); never writes into a `Sheet` and never calls any
/// `SheetStore` method. `SheetStore` is the only writer of the returned
/// grid into a sheet's output range.
///
/// **Pipeline** (design contract `sota-p2-core-report.md` #2.2): source
/// range -> column vectors -> page filtering -> group-key derivation
/// (per-field grouping via `PivotGroupSpec`, autoShow top-N cutoff,
/// member sort - see `groupedCombos`) -> row x column lattice -> per-
/// data-field aggregation (all 12 `SheetPivotAggregation` cases,
/// optionally transformed by a `.data` field's `reference` mode) ->
/// per-field subtotal rows (P2b) -> grand total row/column ->
/// `PivotResultGrid`.
///
/// **P2b scope calls** (recorded for architect ratification - see this
/// track's findings file for the full reasoning on each):
///   - Subtotal rows and the `.compact`/`.outline` layout distinction
///     are a ROW-AXIS-ONLY feature; column fields never grow subtotal
///     COLUMNS. Most real-world pivots group by rows; a symmetric
///     column-subtotal pass is deferred.
///   - `.compact` is read off `rowFields.first`'s own `layout.mode` as
///     a TABLE-WIDE effective mode (mixing a collapsed single column
///     with per-level columns within one grid has no coherent
///     rendering) - not evaluated per level.
///   - `.outline`/`.compact` do NOT reproduce Excel's "the outer
///     group's label gets its own dedicated (dataless) row" nuance;
///     each row-field combo still produces exactly one data row, same
///     as `.tabular` - only the label's PLACEMENT (its own column vs.
///     collapsed) and the presence of subtotal rows differ.
///   - `SheetPivotReferenceMode` ships 4 of LO/Excel's many "show
///     values as" modes - the ones needing no caller-chosen base
///     field/base item (see that enum's own doc comment).
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

        // MARK: Group-key derivation (P2b: grouping + autoShow + sort,
        // see `groupedCombos`).
        let rowCombos = groupedCombos(fields: rowFields, cols: rowCols, rows: sourceRows, sheet: sheet, dataFields: dataFields, dataCols: dataCols)
        let columnCombos = groupedCombos(fields: columnFields, cols: columnCols, rows: sourceRows, sheet: sheet, dataFields: dataFields, dataCols: dataCols)

        // MARK: Row/column matching against GROUPED values (a combo
        // entry may be a synthetic group label, not necessarily a raw
        // cell value - see `groupedValue`).
        func matchesPrefix(_ row: Int, prefix: [CellValue], cols: [Int], fields: [SheetPivotField]) -> Bool {
            for i in 0..<prefix.count {
                if groupedValue(row: row, col: cols[i], field: fields[i], sheet: sheet) != prefix[i] { return false }
            }
            return true
        }

        func rowsMatching(rowCombo: [CellValue], columnCombo: [CellValue]) -> [Int] {
            sourceRows.filter {
                matchesPrefix($0, prefix: rowCombo, cols: rowCols, fields: rowFields)
                    && matchesPrefix($0, prefix: columnCombo, cols: columnCols, fields: columnFields)
            }
        }
        func rowsMatchingRowPrefix(_ prefix: [CellValue]) -> [Int] {
            sourceRows.filter { matchesPrefix($0, prefix: prefix, cols: rowCols, fields: rowFields) }
        }
        func rowsMatchingColumnOnly(_ columnCombo: [CellValue]) -> [Int] {
            sourceRows.filter { matchesPrefix($0, prefix: columnCombo, cols: columnCols, fields: columnFields) }
        }

        // MARK: Per-data-field aggregation, with an optional `reference`
        // ("show values as") transform. `rowTotalRows`/`columnTotalRows`
        // are the underlying-row sets a `.percentOfRowTotal`/
        // `.percentOfColumnTotal` transform divides by; nil reuses
        // `matches` itself (the P2a behavior every existing caller that
        // never sets `reference` is unaffected by, since the fast path
        // below returns `raw` immediately whenever `reference` is nil
        // or `.normal`).
        func aggregatedCells(
            for matches: [Int],
            rowTotalRows: [Int]? = nil,
            columnTotalRows: [Int]? = nil
        ) -> [CellValue] {
            zip(dataFields, dataCols).map { field, col in
                let raw = aggregate(field.function ?? .sum, values: matches.map { sheet.cellValue(row: $0, col: col) })
                guard let mode = field.reference, mode != .normal else { return raw }
                guard let rawNumber = numeric(raw) else { return raw }
                let denominatorRows: [Int]
                switch mode {
                case .normal: denominatorRows = matches // unreachable, guarded above
                case .percentOfGrandTotal: denominatorRows = sourceRows
                case .percentOfRowTotal: denominatorRows = rowTotalRows ?? matches
                case .percentOfColumnTotal: denominatorRows = columnTotalRows ?? matches
                }
                let denomAgg = aggregate(field.function ?? .sum, values: denominatorRows.map { sheet.cellValue(row: $0, col: col) })
                guard let denom = numeric(denomAgg), denom != 0 else { return .error("#DIV/0!") }
                return .number(rawNumber / denom)
            }
        }

        let columnFieldLevels = columnFields.count
        let rowFieldLevels = rowFields.count

        // MARK: Header rows (columnFieldLevels value-label rows + one
        // data-field-name row). Built in EXPANDED form (one column per
        // row-field level); collapsed to `.compact`'s single column, if
        // applicable, right before returning.
        let effectiveRowLayoutMode: SheetPivotFieldLayoutMode = rowFields.first?.layout?.mode ?? .tabular
        let isCompactRows = effectiveRowLayoutMode == .compact

        var headerRows: [[CellValue]] = (0...columnFieldLevels).map { level in
            var leading = Array(repeating: CellValue.empty, count: rowFieldLevels)
            if level == columnFieldLevels, rowFieldLevels > 0 {
                if isCompactRows {
                    leading[0] = .text("Row Labels")
                } else {
                    for i in 0..<rowFieldLevels { leading[i] = .text(rowFields[i].fieldName) }
                }
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

        // MARK: Data rows - one per row combo, in EXPANDED (per-level
        // column) form, exactly P2a's algorithm (blanking via
        // `repeatItemLabels`, unaffected by `.outline`/`.compact` -
        // those only change label PLACEMENT, not which levels blank).
        var dataRows: [[CellValue]] = []
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
                let matches = rowsMatching(rowCombo: rowCombo, columnCombo: columnCombo)
                cells.append(contentsOf: aggregatedCells(
                    for: matches,
                    rowTotalRows: rowsMatchingRowPrefix(rowCombo),
                    columnTotalRows: rowsMatchingColumnOnly(columnCombo)
                ))
            }
            if definition.columnGrand {
                let matches = rowsMatchingRowPrefix(rowCombo)
                cells.append(contentsOf: aggregatedCells(for: matches, rowTotalRows: matches, columnTotalRows: sourceRows))
            }
            dataRows.append(cells)
        }

        // MARK: Per-field subtotal rows (P2b, row axis only) - a
        // recursive group-and-splice pass over `rowCombos`/`dataRows`,
        // gated per level on that level's field having a non-`.tabular`
        // layout mode (see the type header's scope note).
        func subtotalRow(level: Int, groupRange: Range<Int>) -> [[CellValue]] {
            let field = rowFields[level]
            let prefix = Array(rowCombos[groupRange.lowerBound][0...level])
            let groupRows = rowsMatchingRowPrefix(prefix)
            let functions: [SheetPivotAggregation?] = field.subtotals.isEmpty
                ? [nil] // "auto": each data field's own configured function
                : field.subtotals.map { $0 }

            return functions.map { override -> [CellValue] in
                var leading = Array(repeating: CellValue.empty, count: rowFieldLevels)
                let suffix = override.map { displayName(for: $0) } ?? "Total"
                leading[level] = .text("\(displayText(prefix[level])) \(suffix)")

                var cells = leading
                for columnCombo in columnCombos {
                    // `prefix` is shorter than a full row combo when
                    // `level < rowFieldLevels - 1`; `rowsMatching`'s
                    // prefix match (`matchesPrefix`) only compares
                    // `prefix.count` levels, so this already IS the
                    // group's rows intersected with this column combo -
                    // equivalent to `rowsMatchingRowPrefix(prefix)`
                    // filtered to `columnCombo`, just without building
                    // the intermediate set.
                    let matches = rowsMatching(rowCombo: prefix, columnCombo: columnCombo)
                    cells.append(contentsOf: overriddenAggregatedCells(
                        override: override, for: matches, rowTotalRows: groupRows, columnTotalRows: rowsMatchingColumnOnly(columnCombo), dataFields: dataFields, dataCols: dataCols, sheet: sheet, sourceRows: sourceRows
                    ))
                }
                if definition.columnGrand {
                    cells.append(contentsOf: overriddenAggregatedCells(
                        override: override, for: groupRows, rowTotalRows: groupRows, columnTotalRows: sourceRows, dataFields: dataFields, dataCols: dataCols, sheet: sheet, sourceRows: sourceRows
                    ))
                }
                return cells
            }
        }

        func withSubtotals(range: Range<Int>, level: Int) -> [[CellValue]] {
            guard level < rowFieldLevels else {
                return range.map { dataRows[$0] }
            }
            var result: [[CellValue]] = []
            var i = range.lowerBound
            while i < range.upperBound {
                var j = i + 1
                while j < range.upperBound, rowCombos[j][level] == rowCombos[i][level] { j += 1 }
                let childRows = withSubtotals(range: i..<j, level: level + 1)

                let field = rowFields[level]
                let mode = field.layout?.mode ?? .tabular
                let wantsSubtotal = mode != .tabular && (field.subtotalAuto || !field.subtotals.isEmpty)
                if wantsSubtotal {
                    let subtotals = subtotalRow(level: level, groupRange: i..<j)
                    let atTop = field.layout?.subtotalsAtTop ?? true
                    result.append(contentsOf: atTop ? subtotals + childRows : childRows + subtotals)
                } else {
                    result.append(contentsOf: childRows)
                }
                i = j
            }
            return result
        }

        var bodyRows = rowFieldLevels > 0 ? withSubtotals(range: 0..<rowCombos.count, level: 0) : dataRows

        // MARK: Grand total row
        if definition.rowGrand {
            var cells: [CellValue] = Array(repeating: .empty, count: rowFieldLevels)
            if rowFieldLevels > 0 {
                cells[0] = .text(definition.grandTotalName ?? "Grand Total")
            }
            for columnCombo in columnCombos {
                let matches = rowsMatchingColumnOnly(columnCombo)
                cells.append(contentsOf: aggregatedCells(for: matches, rowTotalRows: sourceRows, columnTotalRows: matches))
            }
            if definition.columnGrand {
                cells.append(contentsOf: aggregatedCells(for: sourceRows, rowTotalRows: sourceRows, columnTotalRows: sourceRows))
            }
            bodyRows.append(cells)
        }

        // MARK: `.compact` collapse - the row-header LEADING columns of
        // every header/body row collapse from `rowFieldLevels` columns
        // to 1, indented per the shallowest non-blank level (see
        // `collapseLeadingToCompact`). Data columns are untouched.
        let finalHeaderRows: [[CellValue]]
        let finalBodyRows: [[CellValue]]
        let headerColumnCount: Int
        if isCompactRows, rowFieldLevels > 0 {
            finalHeaderRows = headerRows.map { row in
                [collapseLeadingToCompact(Array(row.prefix(rowFieldLevels)))] + row.suffix(from: rowFieldLevels)
            }
            finalBodyRows = bodyRows.map { row in
                [collapseLeadingToCompact(Array(row.prefix(rowFieldLevels)))] + row.suffix(from: rowFieldLevels)
            }
            headerColumnCount = 1
        } else {
            finalHeaderRows = headerRows
            finalBodyRows = bodyRows
            headerColumnCount = rowFieldLevels
        }

        return PivotResultGrid(
            rows: finalHeaderRows + finalBodyRows,
            headerRowCount: columnFieldLevels + 1,
            headerColumnCount: headerColumnCount
        )
    }

    /// `aggregatedCells`'s function-override variant used by subtotal
    /// rows: `override` (a specific `subtotals` entry) replaces the
    /// data field's own `function` for this one row when non-nil;
    /// `nil` means "auto" - the data field's own configured function,
    /// same math as the main body. A free function (not a nested
    /// closure inside `build`) since `subtotalRow` needs it with an
    /// explicit `override` per call, unlike `aggregatedCells`'s fixed
    /// per-data-field function.
    private static func overriddenAggregatedCells(
        override: SheetPivotAggregation?,
        for matches: [Int],
        rowTotalRows: [Int],
        columnTotalRows: [Int],
        dataFields: [SheetPivotField],
        dataCols: [Int],
        sheet: Sheet,
        sourceRows: [Int]
    ) -> [CellValue] {
        zip(dataFields, dataCols).map { field, col in
            let function = override ?? field.function ?? .sum
            let raw = aggregate(function, values: matches.map { sheet.cellValue(row: $0, col: col) })
            guard let mode = field.reference, mode != .normal else { return raw }
            guard let rawNumber = numeric(raw) else { return raw }
            let denominatorRows: [Int]
            switch mode {
            case .normal: denominatorRows = matches
            case .percentOfGrandTotal: denominatorRows = sourceRows
            case .percentOfRowTotal: denominatorRows = rowTotalRows
            case .percentOfColumnTotal: denominatorRows = columnTotalRows
            }
            let denomAgg = aggregate(function, values: denominatorRows.map { sheet.cellValue(row: $0, col: col) })
            guard let denom = numeric(denomAgg), denom != 0 else { return .error("#DIV/0!") }
            return .number(rawNumber / denom)
        }
    }

    /// Collapses a row's `rowFieldLevels`-wide leading (row-header)
    /// cells into one `.compact`-form cell: every already-blanked entry
    /// (P2a's `repeatItemLabels` convention: a blank leading cell means
    /// "same as the row above at this level", or - for a subtotal row -
    /// "not this row's own level") is dropped, the survivors are joined
    /// with a space, and the result is indented two spaces per
    /// shallowest-shown level - matching Excel Compact Form's visual
    /// convention (see the type header's scope note for exactly what
    /// this does and does not reproduce of the real feature).
    private static func collapseLeadingToCompact(_ leading: [CellValue]) -> CellValue {
        guard let firstShown = leading.firstIndex(where: { !$0.isEmpty }) else { return .empty }
        let shown = leading[firstShown...].filter { !$0.isEmpty }
        let indent = String(repeating: "  ", count: firstShown)
        return .text(indent + shown.map { displayText($0) }.joined(separator: " "))
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

    // MARK: - Page-field / group display text

    /// A page field's `SheetPivotFieldMember.name` is compared against
    /// this, not `CellValue` structural equality - mirrors
    /// `QueryEngine`'s own `SheetFilterRowInput.displayText` convention
    /// (see `QueryEngine.applyFilter`'s `displayText` parameter) so a
    /// numeric field's member name ("2024") matches a `.number(2024)`
    /// cell. Also used (P2b) as `.members` grouping's own match key and
    /// to render any group/subtotal label text.
    static func displayText(_ value: CellValue) -> String {
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

    // MARK: - Grouping (P2b design contract step 4: PivotGroupSpec)

    /// The group KEY a row contributes at one field - the raw cell
    /// value when `field.group` is nil (P2a behavior, unchanged), else
    /// the synthetic bucket/label `PivotGroupSpec` produces. A value
    /// `PivotGroupSpec` cannot bucket (a non-numeric cell under
    /// `.numeric`, a non-date cell under `.date`) passes through
    /// UNGROUPED at its own raw value, the same "ungrouped items
    /// coexist" convention `.members` documents on itself.
    static func groupedValue(row: Int, col: Int, field: SheetPivotField, sheet: Sheet) -> CellValue {
        let raw = sheet.cellValue(row: row, col: col)
        guard let group = field.group else { return raw }
        switch group {
        case .numeric(let start, let end, let step):
            guard let n = numeric(raw), step > 0 else { return raw }
            return .text(numericGroupLabel(value: n, start: start, end: end, step: step))
        case .date(let by):
            guard case .date(let d) = raw, !by.isEmpty else { return raw }
            return .text(dateGroupLabel(for: d, by: by))
        case .members(let groups):
            let text = displayText(raw)
            if let match = groups.first(where: { $0.members.contains(text) }) {
                return .text(match.name)
            }
            return raw
        }
    }

    /// `[start + k*step, start + (k+1)*step)` bucket label, e.g.
    /// `numericGroupLabel(value: 24, start: 0, end: 100, step: 10)` ==
    /// `"20-30"`. A value below `start` labels as `"< start"`; a value
    /// >= `end` labels as `"end+"` - Excel's own numeric-grouping
    /// convention for out-of-range values (the first/last bucket
    /// absorbs everything beyond the declared span rather than
    /// producing an unbounded number of buckets).
    static func numericGroupLabel(value: Double, start: Double, end: Double, step: Double) -> String {
        if value < start { return "< \(formatBound(start))" }
        if value >= end { return "\(formatBound(end))+" }
        let bucketIndex = ((value - start) / step).rounded(.down)
        let bucketStart = start + bucketIndex * step
        let bucketEnd = min(bucketStart + step, end)
        return "\(formatBound(bucketStart))-\(formatBound(bucketEnd))"
    }

    private static func formatBound(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    /// Combines every selected `PivotDateGroupInterval` into one label,
    /// coarsest to finest (matching how Excel/LO's own multi-select
    /// date grouping reads: "2026 Qtr3", "2026 Aug", "14 09:30"). Each
    /// component uses a fixed (non-locale) format so the label is
    /// deterministic and directly comparable/sortable as text.
    static func dateGroupLabel(for date: Date, by: Set<PivotDateGroupInterval>) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        var parts: [String] = []
        if by.contains(.years), let year = comps.year { parts.append(String(year)) }
        if by.contains(.quarters), let month = comps.month { parts.append("Qtr\((month - 1) / 3 + 1)") }
        if by.contains(.months), let month = comps.month {
            let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            parts.append(names[max(0, min(11, month - 1))])
        }
        if by.contains(.days), let day = comps.day { parts.append(String(format: "%02d", day)) }
        if by.contains(.hours), let hour = comps.hour { parts.append(String(format: "%02dh", hour)) }
        if by.contains(.minutes), let minute = comps.minute { parts.append(String(format: "%02dm", minute)) }
        if by.contains(.seconds), let second = comps.second { parts.append(String(format: "%02ds", second)) }
        return parts.isEmpty ? displayText(.date(date)) : parts.joined(separator: " ")
    }

    // MARK: - Group-key derivation (P2b: grouping + autoShow + sort)

    /// Builds one axis's (row or column fields') ordered group-key
    /// combos. Recurses per field level so grouping, autoShow, and sort
    /// all compose under nesting the same way a real pivot table does:
    /// at each level, source rows are bucketed by `groupedValue`, the
    /// resulting distinct values are autoShow-filtered then sorted (see
    /// `sortedValues`), and each survivor recurses into the next level
    /// using only the rows that produced it. `cols.isEmpty` (no fields
    /// on this axis) returns a single empty tuple: "no grouping" still
    /// produces exactly one row/column, matching a pivot with zero row
    /// (or column) fields laying out one aggregate line rather than
    /// none - identical to P2a's `distinctSortedCombos`.
    static func groupedCombos(
        fields: [SheetPivotField],
        cols: [Int],
        rows: [Int],
        sheet: Sheet,
        dataFields: [SheetPivotField],
        dataCols: [Int]
    ) -> [[CellValue]] {
        guard !fields.isEmpty else { return [[]] }
        return combosForLevel(level: 0, fields: fields, cols: cols, candidateRows: rows, sheet: sheet, dataFields: dataFields, dataCols: dataCols)
    }

    private static func combosForLevel(
        level: Int,
        fields: [SheetPivotField],
        cols: [Int],
        candidateRows: [Int],
        sheet: Sheet,
        dataFields: [SheetPivotField],
        dataCols: [Int]
    ) -> [[CellValue]] {
        let field = fields[level]
        let col = cols[level]

        var valueToRows: [CellValue: [Int]] = [:]
        var order: [CellValue] = []
        for row in candidateRows {
            let v = groupedValue(row: row, col: col, field: field, sheet: sheet)
            if valueToRows[v] == nil { order.append(v) }
            valueToRows[v, default: []].append(row)
        }

        if let autoShow = field.autoShow, autoShow.enabled, order.count > 1,
           let dataFieldIdx = dataFields.firstIndex(where: { $0.fieldName == autoShow.dataFieldName }) {
            let dataField = dataFields[dataFieldIdx]
            let dataCol = dataCols[dataFieldIdx]
            let rowInputs = order.enumerated().map { idx, v -> SheetFilterRowInput in
                let agg = aggregate(dataField.function ?? .sum, values: (valueToRows[v] ?? []).map { sheet.cellValue(row: $0, col: dataCol) })
                return SheetFilterRowInput(row: idx, value: agg, displayText: displayText(agg))
            }
            let criteria = SheetFilterCriteria(
                kind: .top,
                topDirection: autoShow.direction == .top ? .top : .bottom,
                topIsPercent: false,
                topCount: Double(autoShow.itemCount)
            )
            let failing = criteria.rowsFailing(in: rowInputs)
            order = order.enumerated().filter { !failing.contains($0.offset) }.map { $0.element }
        }

        order = sortedValues(order, valueToRows: valueToRows, field: field, dataFields: dataFields, dataCols: dataCols, sheet: sheet)

        guard level + 1 < fields.count else {
            return order.map { [$0] }
        }
        var result: [[CellValue]] = []
        for v in order {
            let childRows = valueToRows[v] ?? []
            let childCombos = combosForLevel(level: level + 1, fields: fields, cols: cols, candidateRows: childRows, sheet: sheet, dataFields: dataFields, dataCols: dataCols)
            for child in childCombos {
                result.append([v] + child)
            }
        }
        return result
    }

    /// Orders one level's distinct group values per `field.sort`
    /// (P2a/nil default: `QueryEngine`'s mixed-type order, ascending -
    /// see `QueryEngine.sortedRowOrder`, reused rather than
    /// reimplemented). `.data` mode ranks by a SINGLE data field's
    /// aggregate over each value's own rows (not a full multi-level
    /// joint aggregate - see `SheetPivotFieldSort`'s doc comment for
    /// this scope call); an unresolvable `dataFieldName` falls back to
    /// name order rather than silently dropping every row. `.manual`
    /// orders by `field.members`' declared order, undeclared values
    /// falling back to name order after every declared one.
    private static func sortedValues(
        _ values: [CellValue],
        valueToRows: [CellValue: [Int]],
        field: SheetPivotField,
        dataFields: [SheetPivotField],
        dataCols: [Int],
        sheet: Sheet
    ) -> [CellValue] {
        guard values.count > 1 else { return values }
        let spec = field.sort ?? SheetPivotFieldSort()

        func nameSorted(_ values: [CellValue], ascending: Bool) -> [CellValue] {
            let order = QueryEngine.sortedRowOrder(
                rowCount: values.count,
                conditions: [SheetSortCondition(columnIndex: 0, ascending: ascending)],
                cellValue: { row, _ in values[row] }
            )
            return order.map { values[$0] }
        }

        switch spec.mode {
        case .name:
            return nameSorted(values, ascending: spec.ascending)
        case .data:
            guard let dataFieldIdx = dataFields.firstIndex(where: { $0.fieldName == spec.dataFieldName }) else {
                return nameSorted(values, ascending: spec.ascending)
            }
            let dataField = dataFields[dataFieldIdx]
            let dataCol = dataCols[dataFieldIdx]
            let keyed: [(CellValue, Double)] = values.map { v in
                let agg = aggregate(dataField.function ?? .sum, values: (valueToRows[v] ?? []).map { sheet.cellValue(row: $0, col: dataCol) })
                return (v, numeric(agg) ?? -Double.greatestFiniteMagnitude)
            }
            let sorted = keyed.enumerated().sorted { a, b in
                if a.element.1 != b.element.1 { return spec.ascending ? a.element.1 < b.element.1 : a.element.1 > b.element.1 }
                return a.offset < b.offset // stable tie-break
            }
            return sorted.map { $0.element.0 }
        case .manual:
            let declaredOrder = field.members.map { $0.name }
            func rank(_ v: CellValue) -> Int {
                declaredOrder.firstIndex(of: displayText(v)) ?? Int.max
            }
            return values.enumerated().sorted { a, b in
                let ra = rank(a.element), rb = rank(b.element)
                if ra != rb { return ra < rb }
                return a.offset < b.offset // undeclared members: stable discovery order
            }.map { $0.element }
        }
    }
}
