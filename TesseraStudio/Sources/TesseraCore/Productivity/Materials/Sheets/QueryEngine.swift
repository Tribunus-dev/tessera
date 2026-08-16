import Foundation

// MARK: - SheetFilterKind

/// The autoFilter criteria kind a ``SheetFilterCriteria`` carries.
/// OOXML's filterColumn has EXACTLY ONE criteria child per column -
/// mirrored here the way ``SheetValidationKind``/``SheetConditionalFormatKind``
/// mirror their own single-child-per-rule XML shapes: one flat struct,
/// a `kind` discriminator, and the fields for every kind coexisting as
/// optionals that only the matching `kind` populates.
public enum SheetFilterKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// A literal OR-set of display-text values (the checkbox dropdown).
    case valueSet
    /// Up to two predicates, AND/OR joined.
    case custom
    /// Top/bottom N items or N percent.
    case top
    /// A dated bucket (today, this month, Q1, ...).
    case dynamic
    /// Fill or font color match.
    case color
}

// MARK: - SheetFilterCustomOperator

/// The comparator vocabulary for a `.custom` criterion's predicates -
/// OOXML's customFilter `operator` attribute. `.equal`/`.notEqual` are
/// where wildcard matching lives (see ``SheetFilterCriteria``'s doc
/// comment); the other four never glob-match.
public enum SheetFilterCustomOperator: String, Codable, Sendable, Hashable, CaseIterable {
    case equal
    case notEqual
    case greaterThan
    case greaterThanOrEqual
    case lessThan
    case lessThanOrEqual
}

// MARK: - SheetFilterCustomJoin

public enum SheetFilterCustomJoin: String, Codable, Sendable, Hashable, CaseIterable {
    case and
    case or
}

// MARK: - SheetFilterTopDirection

public enum SheetFilterTopDirection: String, Codable, Sendable, Hashable, CaseIterable {
    case top
    case bottom
}

// MARK: - SheetFilterDynamicPeriod

/// The dated buckets a `.dynamic` criterion can select, matching
/// OOXML's ST_DynamicFilterType date-related members (`today`,
/// `thisWeek`, `M1`..`M12`, ...). `aboveAverage`/`belowAverage` - the
/// two non-dated members of that same OOXML enumeration - are
/// deliberately out of scope: they need a cross-row mean rather than a
/// date bucket, which is a different mechanism from what this
/// component's contract asks for ("dynamic (dated buckets)").
public enum SheetFilterDynamicPeriod: String, Codable, Sendable, Hashable, CaseIterable {
    case today, yesterday, tomorrow
    case thisWeek, lastWeek, nextWeek
    case thisMonth, lastMonth, nextMonth
    case thisQuarter, lastQuarter, nextQuarter
    case thisYear, lastYear, nextYear
    case yearToDate
    case month1, month2, month3, month4, month5, month6
    case month7, month8, month9, month10, month11, month12
    case quarter1, quarter2, quarter3, quarter4
}

extension SheetFilterDynamicPeriod {
    /// `month1`..`month12`/`quarter1`..`quarter4` recur every year -
    /// they match a calendar component's VALUE, not an absolute date
    /// range, so `interval(relativeTo:calendar:)` returns nil for them.
    enum RecurringComponent {
        case month(Int)
        case quarter(Int)
    }

    var recurringComponent: RecurringComponent? {
        switch self {
        case .month1: return .month(1)
        case .month2: return .month(2)
        case .month3: return .month(3)
        case .month4: return .month(4)
        case .month5: return .month(5)
        case .month6: return .month(6)
        case .month7: return .month(7)
        case .month8: return .month(8)
        case .month9: return .month(9)
        case .month10: return .month(10)
        case .month11: return .month(11)
        case .month12: return .month(12)
        case .quarter1: return .quarter(1)
        case .quarter2: return .quarter(2)
        case .quarter3: return .quarter(3)
        case .quarter4: return .quarter(4)
        default: return nil
        }
    }

    /// Half-open `[start, end)` for every period relative to
    /// `referenceDate`, or nil for the recurring month/quarter buckets
    /// (see ``RecurringComponent``). Criteria are evaluated once, at
    /// apply time, against whatever `referenceDate` the caller passes -
    /// the resulting hidden-row set is then the persisted truth and is
    /// never recomputed against "today" again on a later load.
    func interval(relativeTo referenceDate: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        let today = calendar.startOfDay(for: referenceDate)
        func adding(_ component: Calendar.Component, _ value: Int, to date: Date) -> Date? {
            calendar.date(byAdding: component, value: value, to: date)
        }

        switch self {
        case .today:
            guard let end = adding(.day, 1, to: today) else { return nil }
            return (today, end)
        case .yesterday:
            guard let start = adding(.day, -1, to: today) else { return nil }
            return (start, today)
        case .tomorrow:
            guard let start = adding(.day, 1, to: today), let end = adding(.day, 2, to: today) else { return nil }
            return (start, end)

        case .thisWeek, .lastWeek, .nextWeek:
            guard let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)) else { return nil }
            switch self {
            case .thisWeek:
                guard let end = adding(.day, 7, to: weekStart) else { return nil }
                return (weekStart, end)
            case .lastWeek:
                guard let start = adding(.day, -7, to: weekStart) else { return nil }
                return (start, weekStart)
            case .nextWeek:
                guard let start = adding(.day, 7, to: weekStart), let end = adding(.day, 14, to: weekStart) else { return nil }
                return (start, end)
            default: return nil
            }

        case .thisMonth, .lastMonth, .nextMonth:
            guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) else { return nil }
            switch self {
            case .thisMonth:
                guard let end = adding(.month, 1, to: monthStart) else { return nil }
                return (monthStart, end)
            case .lastMonth:
                guard let start = adding(.month, -1, to: monthStart) else { return nil }
                return (start, monthStart)
            case .nextMonth:
                guard let start = adding(.month, 1, to: monthStart), let end = adding(.month, 2, to: monthStart) else { return nil }
                return (start, end)
            default: return nil
            }

        case .thisQuarter, .lastQuarter, .nextQuarter:
            let comps = calendar.dateComponents([.year, .month], from: today)
            guard let year = comps.year, let month = comps.month else { return nil }
            let quarterStartMonth = ((month - 1) / 3) * 3 + 1
            var startComps = DateComponents()
            startComps.year = year
            startComps.month = quarterStartMonth
            startComps.day = 1
            guard let quarterStart = calendar.date(from: startComps) else { return nil }
            switch self {
            case .thisQuarter:
                guard let end = adding(.month, 3, to: quarterStart) else { return nil }
                return (quarterStart, end)
            case .lastQuarter:
                guard let start = adding(.month, -3, to: quarterStart) else { return nil }
                return (start, quarterStart)
            case .nextQuarter:
                guard let start = adding(.month, 3, to: quarterStart), let end = adding(.month, 6, to: quarterStart) else { return nil }
                return (start, end)
            default: return nil
            }

        case .thisYear, .lastYear, .nextYear, .yearToDate:
            guard let yearStart = calendar.date(from: calendar.dateComponents([.year], from: today)) else { return nil }
            switch self {
            case .thisYear:
                guard let end = adding(.year, 1, to: yearStart) else { return nil }
                return (yearStart, end)
            case .lastYear:
                guard let start = adding(.year, -1, to: yearStart) else { return nil }
                return (start, yearStart)
            case .nextYear:
                guard let start = adding(.year, 1, to: yearStart), let end = adding(.year, 2, to: yearStart) else { return nil }
                return (start, end)
            case .yearToDate:
                guard let end = adding(.day, 1, to: today) else { return nil }
                return (yearStart, end)
            default: return nil
            }

        case .month1, .month2, .month3, .month4, .month5, .month6,
             .month7, .month8, .month9, .month10, .month11, .month12,
             .quarter1, .quarter2, .quarter3, .quarter4:
            return nil
        }
    }
}

// MARK: - SheetFilterCriteria

/// One column's autoFilter criteria - the OOXML filterColumn model:
/// exactly one kind selected via ``SheetFilterKind``, every other
/// kind's fields left nil. Bound to a column index by
/// ``SheetFilterColumn``, not carried here (a criterion has no opinion
/// about which column it's attached to).
///
/// Wildcards are NOT a separate criteria kind: `*`/`?` glob matching is
/// a variant behaviour of the `.custom` kind's `.equal`/`.notEqual`
/// operators specifically (see ``rowsFailing(in:referenceDate:)``'s
/// private predicate matcher). Every other operator, and every other
/// kind, compares literally.
public struct SheetFilterCriteria: Codable, Sendable, Hashable {
    public var kind: SheetFilterKind

    // .valueSet - the literal OR-set of display-text values (the
    // checkbox dropdown's checked members). `includeBlanks` is a
    // separate flag rather than a member of `values`, matching OOXML's
    // `filters` element treating "(Blanks)" as its own `blank="1"`
    // attribute, not a listed `<filter val="...">` child.
    public var values: Set<String>?
    public var includeBlanks: Bool

    // .custom - up to two predicates (OOXML customFilters' 2-child cap).
    // `secondOperator`/`secondValue`/`join` all nil means a single-
    // predicate custom filter (OOXML allows a customFilters element
    // with just one child).
    public var firstOperator: SheetFilterCustomOperator?
    public var firstValue: String?
    public var join: SheetFilterCustomJoin?
    public var secondOperator: SheetFilterCustomOperator?
    public var secondValue: String?

    // .top
    public var topDirection: SheetFilterTopDirection?
    public var topIsPercent: Bool
    /// N items, or N percent when `topIsPercent`.
    public var topCount: Double?

    // .dynamic
    public var dynamicPeriod: SheetFilterDynamicPeriod?

    // .color
    /// `#RRGGBB`, matching `SheetCellFormat.fillHex`'s convention.
    public var colorHex: String?
    /// True filters by fill color; false filters by font color -
    /// mirrors OOXML colorFilter's `cellColor` flag.
    public var colorIsFill: Bool

    public init(
        kind: SheetFilterKind,
        values: Set<String>? = nil,
        includeBlanks: Bool = false,
        firstOperator: SheetFilterCustomOperator? = nil,
        firstValue: String? = nil,
        join: SheetFilterCustomJoin? = nil,
        secondOperator: SheetFilterCustomOperator? = nil,
        secondValue: String? = nil,
        topDirection: SheetFilterTopDirection? = nil,
        topIsPercent: Bool = false,
        topCount: Double? = nil,
        dynamicPeriod: SheetFilterDynamicPeriod? = nil,
        colorHex: String? = nil,
        colorIsFill: Bool = true
    ) {
        self.kind = kind
        self.values = values
        self.includeBlanks = includeBlanks
        self.firstOperator = firstOperator
        self.firstValue = firstValue
        self.join = join
        self.secondOperator = secondOperator
        self.secondValue = secondValue
        self.topDirection = topDirection
        self.topIsPercent = topIsPercent
        self.topCount = topCount
        self.dynamicPeriod = dynamicPeriod
        self.colorHex = colorHex
        self.colorIsFill = colorIsFill
    }

    /// Rows this criterion would hide when applied to `rows`, which
    /// must be the FULL column's data (every row, 0-indexed). `.top`
    /// needs the whole distribution to find its cutoff; `.dynamic`
    /// needs `referenceDate` to resolve a relative bucket into an
    /// absolute range - neither is a genuinely per-cell predicate the
    /// way `.valueSet`/`.custom`/`.color` are, unlike e.g.
    /// `SheetValidationRule.isSatisfied(by:)`. ``QueryEngine/applyFilter``
    /// unions this across every active column into the sheet's hidden-
    /// row set.
    public func rowsFailing(in rows: [SheetFilterRowInput], referenceDate: Date = Date()) -> Set<Int> {
        switch kind {
        case .valueSet:
            return Set(rows.filter { !matchesValueSet($0) }.map { $0.row })
        case .custom:
            return Set(rows.filter { !matchesCustom($0) }.map { $0.row })
        case .top:
            return rowsFailingTop(in: rows)
        case .dynamic:
            return rowsFailingDynamic(in: rows, referenceDate: referenceDate)
        case .color:
            return Set(rows.filter { !matchesColor($0) }.map { $0.row })
        }
    }

    // MARK: .valueSet

    private func matchesValueSet(_ row: SheetFilterRowInput) -> Bool {
        if row.value.isEmpty { return includeBlanks }
        return values?.contains(row.displayText) ?? false
    }

    // MARK: .custom

    private func matchesCustom(_ row: SheetFilterRowInput) -> Bool {
        guard let firstOperator, let firstValue else { return true }
        let firstResult = Self.matchesPredicate(op: firstOperator, target: firstValue, value: row.value, displayText: row.displayText)
        guard let join, let secondOperator, let secondValue else { return firstResult }
        let secondResult = Self.matchesPredicate(op: secondOperator, target: secondValue, value: row.value, displayText: row.displayText)
        switch join {
        case .and: return firstResult && secondResult
        case .or: return firstResult || secondResult
        }
    }

    private static func matchesPredicate(
        op: SheetFilterCustomOperator,
        target: String,
        value: CellValue,
        displayText: String
    ) -> Bool {
        switch op {
        case .equal:
            return wildcardMatches(pattern: target, text: displayText)
        case .notEqual:
            return !wildcardMatches(pattern: target, text: displayText)
        case .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual:
            if let a = numericValue(value), let b = Double(target) {
                switch op {
                case .greaterThan: return a > b
                case .greaterThanOrEqual: return a >= b
                case .lessThan: return a < b
                case .lessThanOrEqual: return a <= b
                default: return false
                }
            }
            let cmp = displayText.caseInsensitiveCompare(target)
            switch op {
            case .greaterThan: return cmp == .orderedDescending
            case .greaterThanOrEqual: return cmp != .orderedAscending
            case .lessThan: return cmp == .orderedAscending
            case .lessThanOrEqual: return cmp != .orderedDescending
            default: return false
            }
        }
    }

    private static func numericValue(_ value: CellValue) -> Double? {
        switch value {
        case .number(let n): return n
        case .date(let d): return d.timeIntervalSince1970
        default: return nil
        }
    }

    /// `*` matches any run of characters, `?` matches exactly one -
    /// Excel/LO's customFilter glob convention. Case-insensitive,
    /// matching AutoFilter's default text comparison.
    private static func wildcardMatches(pattern: String, text: String) -> Bool {
        guard pattern.contains("*") || pattern.contains("?") else {
            return text.caseInsensitiveCompare(pattern) == .orderedSame
        }
        var regexPattern = "^"
        for ch in pattern {
            switch ch {
            case "*": regexPattern += ".*"
            case "?": regexPattern += "."
            default: regexPattern += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        regexPattern += "$"
        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: [.caseInsensitive]) else {
            return text.caseInsensitiveCompare(pattern) == .orderedSame
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    // MARK: .top

    /// Cutoff-based, not rank-based: a "Top 3" over `[10, 10, 10, 5]`
    /// passes all three 10s, matching Excel (a fixed-size head would
    /// arbitrarily drop tied values instead). Non-numeric cells always
    /// fail - Top N/percent only ever applies to a numeric column.
    private func rowsFailingTop(in rows: [SheetFilterRowInput]) -> Set<Int> {
        let allRows = Set(rows.map { $0.row })
        let numeric: [(row: Int, n: Double)] = rows.compactMap { r in
            switch r.value {
            case .number(let n): return (r.row, n)
            case .date(let d): return (r.row, d.timeIntervalSince1970)
            default: return nil
            }
        }
        guard !numeric.isEmpty, let direction = topDirection else { return allRows }

        let count: Int
        if topIsPercent {
            let pct = max(0, min(topCount ?? 0, 100))
            count = max(1, Int((Double(numeric.count) * pct / 100).rounded(.up)))
        } else {
            count = max(1, min(Int(topCount ?? 0), numeric.count))
        }

        let sortedValues = numeric.map { $0.n }.sorted { direction == .top ? $0 > $1 : $0 < $1 }
        let cutoff = sortedValues[count - 1]
        let passingRows = Set(numeric.compactMap { entry -> Int? in
            switch direction {
            case .top: return entry.n >= cutoff ? entry.row : nil
            case .bottom: return entry.n <= cutoff ? entry.row : nil
            }
        })
        return allRows.subtracting(passingRows)
    }

    // MARK: .dynamic

    private func rowsFailingDynamic(in rows: [SheetFilterRowInput], referenceDate: Date) -> Set<Int> {
        let allRows = Set(rows.map { $0.row })
        guard let period = dynamicPeriod else { return allRows }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        let passing: Set<Int>
        if let component = period.recurringComponent {
            passing = Set(rows.compactMap { r -> Int? in
                guard case .date(let d) = r.value else { return nil }
                switch component {
                case .month(let m):
                    return calendar.component(.month, from: d) == m ? r.row : nil
                case .quarter(let q):
                    let month = calendar.component(.month, from: d)
                    return ((month - 1) / 3 + 1) == q ? r.row : nil
                }
            })
        } else if let interval = period.interval(relativeTo: referenceDate, calendar: calendar) {
            passing = Set(rows.compactMap { r -> Int? in
                guard case .date(let d) = r.value else { return nil }
                return (d >= interval.start && d < interval.end) ? r.row : nil
            })
        } else {
            passing = []
        }
        return allRows.subtracting(passing)
    }

    // MARK: .color

    private func matchesColor(_ row: SheetFilterRowInput) -> Bool {
        guard let colorHex else { return false }
        let hex = colorIsFill ? row.format.fillHex : row.format.textHex
        guard let hex else { return false }
        return hex.caseInsensitiveCompare(colorHex) == .orderedSame
    }
}

// MARK: - SheetFilterRowInput

/// One row's filterable state for a single column: its typed value,
/// its display text (what `.valueSet`/`.custom` compare against - the
/// same string the autofilter dropdown would list), and its
/// presentation (for `.color`). Not `Codable` - this is an ephemeral
/// evaluation input built fresh from the live grid, never persisted.
public struct SheetFilterRowInput: Sendable {
    public var row: Int
    public var value: CellValue
    public var displayText: String
    public var format: SheetCellFormat

    public init(row: Int, value: CellValue, displayText: String, format: SheetCellFormat = .standard) {
        self.row = row
        self.value = value
        self.displayText = displayText
        self.format = format
    }
}

// MARK: - SheetFilterColumn

/// One filterColumn: which column index the criteria is bound to.
/// OOXML keys filterColumn by `colId`, a 0-based offset from the
/// autoFilter range's own left edge; this targets the sheet's absolute
/// column index instead, since P1 QueryEngine works at the worksheet
/// level rather than against a `SheetTable`-scoped region (see the
/// design contract's evidence note on Tables/ListObject being the
/// eventual, not current, home for filter state).
public struct SheetFilterColumn: Codable, Sendable, Hashable {
    public var columnIndex: Int
    public var criteria: SheetFilterCriteria

    public init(columnIndex: Int, criteria: SheetFilterCriteria) {
        self.columnIndex = columnIndex
        self.criteria = criteria
    }
}

// MARK: - SheetFilterState

/// The sheet's autofilter state, as two independently persisted
/// pieces: `criteria` (what the UI shows as active per column) and
/// `hiddenRows` (which rows are actually hidden right now). This is
/// the law from the design contract's evidence, not an implementation
/// shortcut: OOXML stores criteria declaratively in `filterColumn` and
/// applied visibility as a plain `row@hidden="1"` on each row, written
/// by whatever last touched the file - the two can legitimately
/// disagree (an import from another app, a criteria edit that hasn't
/// been re-applied yet), and this type's plain synthesized `Codable`
/// deliberately does nothing on decode except fill in both fields
/// as-is. Nothing in this file ever derives one from the other except
/// the explicit mutation entry points on ``QueryEngine``
/// (`applyFilter`/`clearFilter`), which is the ONLY place criteria are
/// allowed to change what's hidden.
public struct SheetFilterState: Codable, Sendable, Hashable {
    public var criteria: [SheetFilterColumn]
    public var hiddenRows: Set<Int>

    public init(criteria: [SheetFilterColumn] = [], hiddenRows: Set<Int> = []) {
        self.criteria = criteria
        self.hiddenRows = hiddenRows
    }

    public static let empty = SheetFilterState()
}

// MARK: - Sheet.effectiveFilterState

/// This file owns ``SheetFilterState``, so - matching
/// `SheetConditionalFormat.swift`'s `effectiveConditionalFormats`/
/// `SheetNamedRange.swift`'s `effectiveNamedRanges` convention of the
/// concept's owning file extending ``Sheet`` - it also owns the
/// "nil means none active" read-through for `Sheet.filterState`.
public extension Sheet {
    var effectiveFilterState: SheetFilterState {
        filterState ?? .empty
    }
}

// MARK: - SheetSortCondition

/// One key of a multi-key sort - OOXML's sortCondition, applied in
/// list order (the first condition is the primary key). See
/// ``QueryEngine/sortedRowOrder(rowCount:conditions:cellValue:)`` for
/// the actual comparison semantics.
public struct SheetSortCondition: Codable, Sendable, Hashable {
    public var columnIndex: Int
    public var ascending: Bool

    public init(columnIndex: Int, ascending: Bool = true) {
        self.columnIndex = columnIndex
        self.ascending = ascending
    }
}

// MARK: - QueryEngineOutcome

/// The result of a ``QueryEngine`` mutation method, shaped for a
/// future ``SheetStore`` integration to turn directly into a receipt.
/// `receiptType` is the raw string a `SheetReceiptType` case will use
/// once one exists (`sheet_sorted` / `sheet_filter_applied` /
/// `sheet_filter_cleared` - see ``QueryEngine/ReceiptType``);
/// `payload` is the structural summary, in the same
/// `[String: JSONValue]` shape `SheetStore.appendReceipt` already
/// takes. This type does not append anything itself - see the
/// `QueryEngine` doc comment for why that boundary stops here.
public struct QueryEngineOutcome: Sendable, Equatable {
    public var receiptType: String
    public var payload: [String: JSONValue]

    public init(receiptType: String, payload: [String: JSONValue]) {
        self.receiptType = receiptType
        self.payload = payload
    }
}

// MARK: - QueryEngine

/// Sort and autofilter for the Sheets material - peer of
/// ``SheetsViewModel``, the same relationship ``SheetValueRenderer``
/// has to ``SheetCellFormat``: a plain, mostly-pure namespace of
/// static functions next to the data types it operates on, owning no
/// state of its own.
///
/// **Receipt-emission boundary.** Every other Sheets mutation
/// (`SheetStore.setCell`, `.insertRow`, ...) appends its own receipt
/// via `dataLayer.appendReceipt`. QueryEngine's mutation methods
/// (`sort`/`applyFilter`/`clearFilter`) do NOT: they return a
/// ``QueryEngineOutcome`` instead of writing one, so a future
/// `SheetStore` integration can call into `QueryEngine`, get back the
/// computed result AND the receipt-shaped outcome, and append the
/// receipt itself at the one call site that already owns
/// `dataLayer`. `QueryEngine` has no `dataLayer` dependency and never
/// will - it is testable with zero setup, matching the file's "plain,
/// mostly-pure type" contract.
public enum QueryEngine {

    /// The three receipt-type strings this component's mutations
    /// produce. Not `SheetReceiptType` cases yet (that enum's file is
    /// out of this item's scope - see the type header); a future
    /// integration adds matching cases there and can use these
    /// constants to keep the two in sync at the call site.
    public enum ReceiptType {
        public static let sorted = "sheet_sorted"
        public static let filterApplied = "sheet_filter_applied"
        public static let filterCleared = "sheet_filter_cleared"
    }

    // MARK: - Sort

    /// Computes the new row order for `conditions`: a stable multi-key
    /// sort. Mixed-type order per key: numbers < text < logical <
    /// error < blanks - blanks sort last REGARDLESS of that key's own
    /// ascending/descending direction (only non-blank values flip with
    /// direction; LO and Excel agree on this). Ties across every key
    /// fall back to the ORIGINAL row index (LO's explicit tie-break),
    /// so sorting an already-sorted range, or sorting with an empty
    /// `conditions` list, is a no-op.
    ///
    /// `cellValue` must return the RESOLVED value for a formula cell
    /// (its computed result), not the raw `.formula(...)` source -
    /// this pure type has no workbook to evaluate a formula with. A
    /// `.formula` value that reaches this function anyway sorts in the
    /// text bucket, by its source string, as a defensive fallback
    /// rather than a crash or a silently-wrong numeric bucket.
    public static func sortedRowOrder(
        rowCount: Int,
        conditions: [SheetSortCondition],
        cellValue: (_ row: Int, _ col: Int) -> CellValue
    ) -> [Int] {
        guard rowCount > 0 else { return [] }
        guard !conditions.isEmpty else { return Array(0..<rowCount) }
        return (0..<rowCount).sorted { a, b in
            for condition in conditions {
                let cmp = compareForSort(
                    cellValue(a, condition.columnIndex),
                    cellValue(b, condition.columnIndex),
                    ascending: condition.ascending
                )
                if cmp != 0 { return cmp < 0 }
            }
            return a < b
        }
    }

    /// The mutation entry point: computes the sorted row order AND the
    /// `sheet_sorted` receipt-shaped outcome. See the type header for
    /// why this returns the outcome instead of appending a receipt.
    public static func sort(
        rowCount: Int,
        conditions: [SheetSortCondition],
        cellValue: (_ row: Int, _ col: Int) -> CellValue
    ) -> (order: [Int], outcome: QueryEngineOutcome) {
        let order = sortedRowOrder(rowCount: rowCount, conditions: conditions, cellValue: cellValue)
        let outcome = QueryEngineOutcome(
            receiptType: ReceiptType.sorted,
            payload: [
                "rowCount": .number(Double(rowCount)),
                "keyCount": .number(Double(conditions.count)),
                "keys": .array(conditions.map {
                    .object([
                        "columnIndex": .number(Double($0.columnIndex)),
                        "ascending": .bool($0.ascending),
                    ])
                }),
            ]
        )
        return (order, outcome)
    }

    /// Bucket rank for the mixed-type order table: numbers < text <
    /// logical < error < blanks. `.date` rides with `.number` (a
    /// spreadsheet date IS a number); `.formula` rides with `.text` -
    /// see `sortedRowOrder`'s doc comment for why.
    private static func sortRank(_ value: CellValue) -> Int {
        switch value {
        case .number, .date: return 0
        case .text, .formula: return 1
        case .checkbox: return 2
        case .error: return 3
        case .empty: return 4
        }
    }

    /// -1/0/1 for `a` vs `b`, honoring `ascending` for every bucket
    /// EXCEPT blanks, which always compare as "after" a non-blank
    /// value regardless of direction - flipping the whole comparison
    /// for a descending key would otherwise put blanks first.
    private static func compareForSort(_ a: CellValue, _ b: CellValue, ascending: Bool) -> Int {
        if a.isEmpty && b.isEmpty { return 0 }
        if a.isEmpty { return 1 }
        if b.isEmpty { return -1 }

        let base = compareNonBlank(a, b)
        return ascending ? base : -base
    }

    private static func compareNonBlank(_ a: CellValue, _ b: CellValue) -> Int {
        let rankA = sortRank(a)
        let rankB = sortRank(b)
        if rankA != rankB { return rankA < rankB ? -1 : 1 }
        switch rankA {
        case 0:
            return compareDouble(numericSortKey(a), numericSortKey(b))
        case 1:
            let sa = textSortKey(a), sb = textSortKey(b)
            if sa == sb { return 0 }
            return sa < sb ? -1 : 1
        case 2:
            guard case .checkbox(let ba) = a, case .checkbox(let bb) = b else { return 0 }
            if ba == bb { return 0 }
            return ba ? 1 : -1 // FALSE < TRUE
        case 3:
            guard case .error(let ea) = a, case .error(let eb) = b else { return 0 }
            if ea == eb { return 0 }
            return ea < eb ? -1 : 1
        default:
            return 0
        }
    }

    /// Numeric key for the `.number`/`.date` bucket. Dates use
    /// `timeIntervalSince1970` as a stand-in for the spreadsheet serial
    /// they'd otherwise be - `CellValue` carries no shared numeric
    /// representation between the two, and this component has no
    /// dependency on `SheetValueRenderer`'s serial/epoch math. Only
    /// matters for a column mixing literal numbers with dates; a
    /// column of one kind sorts correctly regardless.
    private static func numericSortKey(_ value: CellValue) -> Double {
        switch value {
        case .number(let n): return n
        case .date(let d): return d.timeIntervalSince1970
        default: return 0
        }
    }

    private static func textSortKey(_ value: CellValue) -> String {
        switch value {
        case .text(let s): return s
        case .formula(let s): return s
        default: return ""
        }
    }

    private static func compareDouble(_ x: Double, _ y: Double) -> Int {
        if x < y { return -1 }
        if x > y { return 1 }
        return 0
    }

    // MARK: - Filter

    /// Evaluates every column in `criteria` against the live grid and
    /// returns the resulting ``SheetFilterState`` (criteria + the newly
    /// computed `hiddenRows`) plus the `sheet_filter_applied` outcome.
    /// A row is hidden when it fails ANY active column's criterion
    /// (autofilter columns AND together), matching Excel/LO.
    ///
    /// `value`/`displayText`/`format` are per-cell accessors rather
    /// than a pre-built grid: this keeps QueryEngine decoupled from
    /// however the caller stores its rows, the same shape
    /// `sortedRowOrder`'s `cellValue` closure uses.
    public static func applyFilter(
        rowCount: Int,
        criteria: [SheetFilterColumn],
        referenceDate: Date = Date(),
        value: (_ row: Int, _ col: Int) -> CellValue,
        displayText: (_ row: Int, _ col: Int) -> String,
        format: (_ row: Int, _ col: Int) -> SheetCellFormat = { _, _ in .standard }
    ) -> (state: SheetFilterState, outcome: QueryEngineOutcome) {
        var hidden: Set<Int> = []
        for column in criteria {
            let rows = (0..<rowCount).map { row in
                SheetFilterRowInput(
                    row: row,
                    value: value(row, column.columnIndex),
                    displayText: displayText(row, column.columnIndex),
                    format: format(row, column.columnIndex)
                )
            }
            hidden.formUnion(column.criteria.rowsFailing(in: rows, referenceDate: referenceDate))
        }
        let state = SheetFilterState(criteria: criteria, hiddenRows: hidden)
        let outcome = QueryEngineOutcome(
            receiptType: ReceiptType.filterApplied,
            payload: [
                "rowCount": .number(Double(rowCount)),
                "columnCount": .number(Double(criteria.count)),
                "hiddenRowCount": .number(Double(hidden.count)),
            ]
        )
        return (state, outcome)
    }

    /// Drops every active criterion and unhides every row. Takes the
    /// PREVIOUS state only to size the `sheet_filter_cleared` outcome's
    /// payload - the returned state is always ``SheetFilterState/empty``.
    public static func clearFilter(previousState: SheetFilterState) -> (state: SheetFilterState, outcome: QueryEngineOutcome) {
        let outcome = QueryEngineOutcome(
            receiptType: ReceiptType.filterCleared,
            payload: [
                "clearedColumnCount": .number(Double(previousState.criteria.count)),
                "unhiddenRowCount": .number(Double(previousState.hiddenRows.count)),
            ]
        )
        return (.empty, outcome)
    }
}

// MARK: - SubtotalAggregationFunction

/// The 11 SUBTOTAL aggregation kinds - Excel/LO's `function_num` 1-11
/// (the FormulaEngine-layer `SubtotalAggregator`, Functions/
/// SubtotalFunctions.swift, separately accepts the 101-111 band a
/// hand-typed formula can opt into for "also exclude manually-hidden
/// rows" - see that type's doc comment for the full law). `rawValue`
/// IS the function_num, so a descriptor's chosen function writes
/// straight into a generated `=SUBTOTAL(n,...)` formula string with no
/// translation table.
///
/// Deliberately its OWN vocabulary, not a reuse of
/// `SheetPivotAggregation` (SheetPivotDefinition.swift, a different
/// P2-A track's file this wave): SUBTOTAL's law needs all 11 Excel
/// functions (countA, stdDevP, varianceP included) and the pivot
/// engine's simplified 9-case set is missing exactly those three.
/// Reaching into a parallel track's file to add them would cross this
/// wave's file-ownership lane (see this file's header for the
/// no-collision constraint every P2-A track works under).
public enum SubtotalAggregationFunction: Int, Codable, Sendable, Hashable, CaseIterable {
    case average = 1
    case count = 2
    /// COUNTA - counts non-empty cells, not just numeric ones (`.count`
    /// above is the numeric-only COUNT).
    case countA = 3
    case max = 4
    case min = 5
    case product = 6
    /// Sample standard deviation (divides by n-1).
    case stdDev = 7
    /// Population standard deviation (divides by n).
    case stdDevP = 8
    case sum = 9
    /// Sample variance (divides by n-1).
    case variance = 10
    /// Population variance (divides by n).
    case varianceP = 11

    /// The function_num this case writes into a generated formula
    /// string. Always the 1-11 band (includes manually-hidden rows) -
    /// matching what Excel/LO's own Subtotal dialog generates;
    /// `SubtotalAggregator` separately understands the 101-111 band for
    /// a hand-typed formula, but this engine never generates that band
    /// itself (`SubtotalDescriptor` has no field for it - see that
    /// type's doc comment).
    public var functionNum: Int { rawValue }
}

// MARK: - SubtotalColumnFunction

/// One `SubtotalDescriptor.perColumnFunctions` entry: which column gets
/// a `=SUBTOTAL(...)` formula in every group's summary row, and which
/// of the 11 functions it uses. A struct rather than a bare tuple -
/// tuples are neither `Codable` nor `Hashable`-as-a-collection-element -
/// matching `SheetFilterColumn`'s own columnIndex+criteria wrapper
/// earlier in this file.
public struct SubtotalColumnFunction: Codable, Sendable, Hashable {
    public var columnIndex: Int
    public var function: SubtotalAggregationFunction

    public init(columnIndex: Int, function: SubtotalAggregationFunction) {
        self.columnIndex = columnIndex
        self.function = function
    }
}

// MARK: - SubtotalDescriptor

/// The user-facing intent behind one "Data > Subtotal" application:
/// group `groupByColumn`'s rows by display-text equality (the grid
/// must already be sorted on this column for the resulting groups to
/// be contiguous runs - matching Excel/LO, which both require the same
/// pre-sort and do not do it for you), and insert a
/// `=SUBTOTAL(fn, range)` summary row per group for every entry in
/// `perColumnFunctions`.
///
/// Pure intent only - `SubtotalEngine.plan(for:descriptor:)`
/// (SubtotalEngine.swift) is what turns this into actual row
/// insertions and outline levels; this type does no computation and
/// has no engine dependency, matching every other intent/model type in
/// this file (`SheetFilterColumn`, `SheetSortCondition`).
public struct SubtotalDescriptor: Codable, Sendable, Hashable {
    public var groupByColumn: Int
    public var perColumnFunctions: [SubtotalColumnFunction]
    /// True removes any subtotal structure already on the sheet before
    /// this one applies (the Subtotal dialog's "Replace current
    /// subtotals" checkbox); false layers a NEW nesting level on top of
    /// whatever subtotal rows already exist. `SubtotalEngine.plan`
    /// itself does not read this field - it always plans against
    /// whatever `Sheet` it is given, so replace-vs-layer is entirely a
    /// wiring-layer decision (call `removeSubtotals` first, or don't)
    /// made before `plan` is ever called.
    public var replaceExisting: Bool
    /// True places each group's summary row AFTER its detail rows
    /// (Excel/LO's default); false places it BEFORE.
    public var summaryBelow: Bool

    public init(
        groupByColumn: Int,
        perColumnFunctions: [SubtotalColumnFunction],
        replaceExisting: Bool = true,
        summaryBelow: Bool = true
    ) {
        self.groupByColumn = groupByColumn
        self.perColumnFunctions = perColumnFunctions
        self.replaceExisting = replaceExisting
        self.summaryBelow = summaryBelow
    }
}
