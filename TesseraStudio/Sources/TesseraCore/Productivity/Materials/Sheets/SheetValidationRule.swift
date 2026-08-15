import Foundation

// MARK: - SheetValidationKind

/// The constraint a validation rule checks. Matches Excel/LO's own
/// Data Validation kinds closely enough to round-trip an imported
/// XLSX/ODS's validation rules without losing which kind a cell had.
public enum SheetValidationKind: String, Codable, Sendable, Hashable, CaseIterable {
    case wholeNumber
    case decimal
    /// A dropdown of allowed values - inline literals (`listValues`)
    /// or, at P1, a same-workbook range (`listSourceRange`).
    case list
    case date
    case textLength
    /// A formula that must evaluate truthy. Needs a live formula
    /// engine to check - see `isSatisfied(by:)`'s doc comment.
    case custom
}

// MARK: - SheetValidationComparator

/// How `minValue`/`maxValue` bound the entered value, for every kind
/// except `.list` (membership, not a bound) and `.custom` (the
/// formula itself is the whole check).
public enum SheetValidationComparator: String, Codable, Sendable, Hashable, CaseIterable {
    case between
    case notBetween
    case equalTo
    case notEqualTo
    case greaterThan
    case lessThan
    case greaterThanOrEqual
    case lessThanOrEqual
}

// MARK: - SheetValidationErrorStyle

/// How a rule behaves when a value fails it at interactive entry.
/// Matches SpreadsheetML's `errorStyle` attribute on `<dataValidation>`
/// (`ST_DataValidationErrorStyle`: `stop` | `warning` | `information`)
/// verbatim, so import/export round-trips without translation.
public enum SheetValidationErrorStyle: String, Codable, Sendable, Hashable, CaseIterable {
    /// Rejects the entry outright. The only style
    /// `Sheet.applyingInteractiveEntry(_:row:col:)` actually blocks on.
    case stop
    /// Excel/LO show a "keep or discard" confirm dialog the user can
    /// click through; the write is never actually blocked by this
    /// model, only reported (see `SheetValidationEntryResult`).
    case warning
    /// An FYI dialog with no way to reject the value at all.
    case information
}

// MARK: - SheetValidationRule

/// A data-validation rule bound to a range on a `Sheet`. Persisted on
/// `Sheet.validationRules`. Two write paths enforce this differently:
/// `Sheet.applyingInteractiveEntry(_:row:col:)` blocks on an
/// `errorStyle = .stop` violation, matching Excel's own interactive
/// cell editor; `Sheet.applyingNonInteractiveWrite(_:row:col:)` never
/// blocks - engine results, agent-tool writes, paste/fill - matching
/// Excel's own behavior for those paths too. `Sheet.invalidCells()` is
/// the audit query ("circle invalid data") that finds rule-violating
/// values afterward regardless of which path wrote them.
/// `SheetWorkbook` doesn't call any of these yet - wiring them into
/// the live input layer is a separate piece of work; this file is the
/// complete rule + evaluation model those callers build on.
public struct SheetValidationRule: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var kind: SheetValidationKind
    public var comparator: SheetValidationComparator?
    /// Stored as text and parsed per `kind` (a number for
    /// `.wholeNumber`/`.decimal`, an ISO-8601 string for `.date`, a
    /// character count for `.textLength`) rather than typed fields,
    /// so one rule shape covers every kind without a field explosion.
    public var minValue: String?
    public var maxValue: String?
    /// The dropdown's allowed values, for `.list` - inline literals.
    /// Ignored when `listSourceRange` is set.
    public var listValues: [String]?
    /// A range reference string (e.g. `"A1:B10"`, `"Sheet2!C1:C20"`)
    /// supplying `.list` values from cell text instead of `listValues`
    /// literals - P1's "same-workbook range ref" list source. A `nil`
    /// sheet segment means this rule's own `sheet`. Parsed on demand
    /// via `listSourceRangeRef`; resolving it against actual cell text
    /// is `Sheet.resolvedListValues(for:)`. Cross-sheet round-trip
    /// through OOXML needs the x14 extension list - the workbook
    /// bridge's concern, not this model's.
    public var listSourceRange: String?
    /// True hides the in-cell dropdown arrow for a `.list` rule; false
    /// (the default) shows it. Named for what it DOES, not for
    /// OOXML's own attribute name: SpreadsheetML's `<dataValidation
    /// showDropDown="...">` is documented backwards - despite the
    /// name, setting `showDropDown="1"` HIDES the arrow, and the
    /// omitted/`"0"` default is what shows it. This field's raw value
    /// equals the raw XML attribute value bit-for-bit; only the Swift
    /// name is inverted from the XML attribute's own (misleading)
    /// name, to match what the attribute actually does rather than
    /// what it's called.
    public var hideDropDown: Bool?
    /// The check itself, for `.custom` - e.g. `"=A1>B1"`.
    public var formula: String?
    /// Shown to the user when a value fails this rule. `nil` falls
    /// back to a generic message the input layer supplies.
    public var errorMessage: String?
    /// `nil` = OOXML's own default (`.stop`) - see `effectiveErrorStyle`.
    public var errorStyle: SheetValidationErrorStyle?

    public var sheet: String?
    public var topLeftCol: Int
    public var topLeftRow: Int
    public var bottomRightCol: Int
    public var bottomRightRow: Int

    public init(
        id: UUID = UUID(),
        kind: SheetValidationKind,
        comparator: SheetValidationComparator? = nil,
        minValue: String? = nil,
        maxValue: String? = nil,
        listValues: [String]? = nil,
        listSourceRange: String? = nil,
        hideDropDown: Bool? = nil,
        formula: String? = nil,
        errorMessage: String? = nil,
        errorStyle: SheetValidationErrorStyle? = nil,
        sheet: String? = nil,
        topLeftCol: Int,
        topLeftRow: Int,
        bottomRightCol: Int,
        bottomRightRow: Int
    ) {
        self.id = id
        self.kind = kind
        self.comparator = comparator
        self.minValue = minValue
        self.maxValue = maxValue
        self.listValues = listValues
        self.listSourceRange = listSourceRange
        self.hideDropDown = hideDropDown
        self.formula = formula
        self.errorMessage = errorMessage
        self.errorStyle = errorStyle
        self.sheet = sheet
        self.topLeftCol = topLeftCol
        self.topLeftRow = topLeftRow
        self.bottomRightCol = bottomRightCol
        self.bottomRightRow = bottomRightRow
    }

    /// `nil` if any coordinate is negative - see `SheetNamedRange`'s
    /// doc comment for why this validates rather than constructing
    /// `CellAddr` directly (its initializer's precondition would crash
    /// on corrupt/hand-edited JSON, not fail to decode).
    public var rangeRef: RangeRef? {
        guard topLeftCol >= 0, topLeftRow >= 0, bottomRightCol >= 0, bottomRightRow >= 0 else { return nil }
        return RangeRef(
            sheet: sheet,
            topLeft: CellAddr(col: topLeftCol, row: topLeftRow),
            bottomRight: CellAddr(col: bottomRightCol, row: bottomRightRow)
        )
    }

    /// `listSourceRange` parsed, or nil when unset or unparseable
    /// (e.g. corrupt hand-edited JSON) - fails soft like `rangeRef`
    /// rather than throwing.
    public var listSourceRangeRef: RangeRef? {
        guard let listSourceRange else { return nil }
        return try? AddressParser.parseRange(listSourceRange)
    }

    /// `errorStyle ?? .stop` - OOXML's own default when the attribute
    /// is omitted.
    public var effectiveErrorStyle: SheetValidationErrorStyle {
        errorStyle ?? .stop
    }

    /// `hideDropDown ?? false` - OOXML's own default (dropdown shown)
    /// when `showDropDown` is omitted. See `hideDropDown`'s doc
    /// comment for why the Swift name is inverted from the XML one.
    public var effectiveHideDropDown: Bool {
        hideDropDown ?? false
    }

    /// True if `row`/`col` (0-based, matching `CellAddr`) fall inside
    /// this rule's range.
    public func covers(row: Int, col: Int) -> Bool {
        row >= topLeftRow && row <= bottomRightRow && col >= topLeftCol && col <= bottomRightCol
    }

    /// Whether `value` satisfies this rule. `resolvedListValues`, when
    /// non-nil, REPLACES `listValues` for a `.list` check - the caller
    /// resolves `listSourceRange` (via `Sheet.resolvedListValues(for:)`)
    /// and passes the result in, since this pure model has no sheet to
    /// read cells from itself; omitting it falls back to `listValues`,
    /// matching every existing call site's behavior unchanged.
    ///
    /// `.custom` always returns true here - checking a formula needs a
    /// live workbook to evaluate it against, which this pure model
    /// doesn't have; a caller wiring `.custom` rules is responsible
    /// for evaluating `formula` itself and treating the result the way
    /// this method's Bool is used elsewhere. `.formula`/`.error`/
    /// `.empty` cell values pass every kind except where a rule is
    /// checking against a STORED formula cell's raw text makes no
    /// sense - such cells are simply not checked (the caller should
    /// validate the EVALUATED result of a formula cell, not its stored
    /// `CellValue.formula` case, which this method has no way to
    /// evaluate).
    public func isSatisfied(by value: CellValue, resolvedListValues: [String]? = nil) -> Bool {
        switch kind {
        case .wholeNumber:
            guard case .number(let n) = value, n == n.rounded() else {
                if case .empty = value { return true }
                return false
            }
            return compareNumeric(n)
        case .decimal:
            guard case .number(let n) = value else {
                if case .empty = value { return true }
                return false
            }
            return compareNumeric(n)
        case .list:
            guard case .text(let s) = value else {
                if case .empty = value { return true }
                return false
            }
            if let resolvedListValues {
                return resolvedListValues.contains(s)
            }
            return listValues?.contains(s) ?? true
        case .date:
            guard case .date(let d) = value else {
                if case .empty = value { return true }
                return false
            }
            return compareNumeric(d.timeIntervalSince1970, parse: { Double($0) })
        case .textLength:
            guard case .text(let s) = value else {
                if case .empty = value { return true }
                return false
            }
            return compareNumeric(Double(s.count))
        case .custom:
            return true
        }
    }

    private func compareNumeric(_ actual: Double, parse: (String) -> Double? = Double.init) -> Bool {
        let lo = minValue.flatMap(parse)
        let hi = maxValue.flatMap(parse)
        switch comparator {
        case .between:
            guard let lo, let hi else { return true }
            return actual >= lo && actual <= hi
        case .notBetween:
            guard let lo, let hi else { return true }
            return actual < lo || actual > hi
        case .equalTo:
            guard let lo else { return true }
            return actual == lo
        case .notEqualTo:
            guard let lo else { return true }
            return actual != lo
        case .greaterThan:
            guard let lo else { return true }
            return actual > lo
        case .lessThan:
            guard let lo else { return true }
            return actual < lo
        case .greaterThanOrEqual:
            guard let lo else { return true }
            return actual >= lo
        case .lessThanOrEqual:
            guard let lo else { return true }
            return actual <= lo
        case nil:
            return true
        }
    }
}

// MARK: - SheetValidationEntryResult

/// The result of `Sheet.applyingInteractiveEntry(_:row:col:)`.
public enum SheetValidationEntryResult: Sendable {
    /// Written. `nonBlockingViolations` lists every covering rule
    /// whose `errorStyle` is `.warning`/`.information` (never `.stop` -
    /// a `.stop` violation takes the `.rejected` case below instead)
    /// that the value fails, for a caller that wants to still surface
    /// Excel's confirm/FYI dialog even though nothing blocked the
    /// write. Empty when every covering rule is satisfied.
    case accepted(Sheet, nonBlockingViolations: [SheetValidationRule])
    /// Not written. This case carries no `Sheet` - the caller already
    /// has the one it passed in, unchanged. `rule.errorMessage` is the
    /// message to show, falling back to a generic one the caller
    /// supplies when nil (see `errorMessage`'s own doc comment).
    case rejected(SheetValidationRule)
}

extension Sheet {
    /// `validationRules ?? []`, matching `effectiveProtection`/
    /// `effectiveNamedRanges`'s "nil means none" convention.
    public var effectiveValidationRules: [SheetValidationRule] {
        validationRules ?? []
    }

    /// A copy with `rule` appended.
    public func addingValidationRule(_ rule: SheetValidationRule) -> Sheet {
        var updated = self
        updated.validationRules = effectiveValidationRules + [rule]
        return updated
    }

    /// A copy with the rule matching `id` removed. A no-op if no rule
    /// has that id.
    public func removingValidationRule(_ id: UUID) -> Sheet {
        var updated = self
        updated.validationRules = effectiveValidationRules.filter { $0.id != id }
        return updated
    }

    /// Every rule covering `row`/`col`, in definition order (later
    /// rules can be treated as taking precedence by a caller that
    /// wants "last one wins" for overlapping ranges - this just
    /// reports what applies, it doesn't pick a winner).
    public func validationRules(row: Int, col: Int) -> [SheetValidationRule] {
        effectiveValidationRules.filter { $0.covers(row: row, col: col) }
    }

    // MARK: - List source resolution

    /// The effective membership list for a `.list` rule: `listValues`
    /// when it has no `listSourceRange`, or the TEXT of every cell in
    /// that range when it does. Only resolves a range on THIS sheet
    /// (`listSourceRangeRef.sheet` nil, or equal to the rule's own
    /// `sheet`) - a range naming some OTHER sheet needs the owning
    /// `SheetWorkbook` to hand this sheet its neighbor's cells, which
    /// is beyond a single `Sheet` value's reach; `nil` here is
    /// `isSatisfied(by:resolvedListValues:)`'s "can't check, don't
    /// block" signal, same as `.custom`. Non-`.list` rules return nil
    /// too - there's nothing to resolve.
    public func resolvedListValues(for rule: SheetValidationRule) -> [String]? {
        guard rule.kind == .list else { return nil }
        guard let range = rule.listSourceRangeRef else { return rule.listValues }
        guard range.sheet == nil || range.sheet == rule.sheet else { return nil }
        guard rowCount > 0, columnCount > 0 else { return [] }
        let maxRow = rowCount - 1
        let maxCol = columnCount - 1
        let rowLo = max(0, min(range.topLeft.row, range.bottomRight.row))
        let rowHi = min(maxRow, max(range.topLeft.row, range.bottomRight.row))
        let colLo = max(0, min(range.topLeft.col, range.bottomRight.col))
        let colHi = min(maxCol, max(range.topLeft.col, range.bottomRight.col))
        guard rowLo <= rowHi, colLo <= colHi else { return [] }
        var values: [String] = []
        for row in rowLo...rowHi {
            for col in colLo...colHi {
                values.append(cellText(row: row, col: col))
            }
        }
        return values
    }

    // MARK: - Entry enforcement

    /// Interactive/typed entry - the ONLY write path that blocks. A
    /// value failing a covering `.stop`-style rule is rejected before
    /// it reaches the cell, matching Excel's own interactive-editor
    /// behavior; `.warning`/`.information` rules never block (Excel
    /// shows a dismissable dialog instead) and surface only through
    /// `nonBlockingViolations`. Every OTHER write path - engine
    /// results, agent-tool writes, paste/fill - goes through
    /// `applyingNonInteractiveWrite(_:row:col:)` instead, which never
    /// rejects, matching Excel's own behavior for those paths too.
    public func applyingInteractiveEntry(_ value: CellValue, row: Int, col: Int) -> SheetValidationEntryResult {
        let rules = validationRules(row: row, col: col)
        for rule in rules where rule.effectiveErrorStyle == .stop {
            if !rule.isSatisfied(by: value, resolvedListValues: resolvedListValues(for: rule)) {
                return .rejected(rule)
            }
        }
        let nonBlocking = rules.filter { rule in
            rule.effectiveErrorStyle != .stop
                && !rule.isSatisfied(by: value, resolvedListValues: resolvedListValues(for: rule))
        }
        return .accepted(settingCellValue(row: row, col: col, value), nonBlockingViolations: nonBlocking)
    }

    /// Every write path other than the interactive cell editor -
    /// engine-computed results, agent-tool writes, paste/fill. Excel
    /// itself lets all of these bypass Data Validation entirely, so
    /// this never rejects: the value always lands, whether or not it
    /// satisfies any rule covering (row, col). A rule-violating value
    /// written here isn't flagged inline - `invalidCells()` is how it
    /// surfaces afterward.
    public func applyingNonInteractiveWrite(_ value: CellValue, row: Int, col: Int) -> Sheet {
        settingCellValue(row: row, col: col, value)
    }

    // MARK: - Audit

    /// Every cell currently violating a rule that covers it - the
    /// "circle invalid data" audit query. Implemented by re-evaluating
    /// each rule against the CURRENT value of every cell in its range,
    /// not a separately persisted "flagged invalid" bit:
    /// `applyingNonInteractiveWrite(_:row:col:)` never blocks, so a
    /// rule-violating value it wrote is simply sitting in the cell,
    /// and running `isSatisfied` against it again finds the exact
    /// violation that write never recorded anywhere else. Every
    /// `errorStyle` counts here regardless of whether it would have
    /// blocked at interactive entry - Excel's own "circle invalid
    /// data" doesn't care that a `.warning`/`.information` rule never
    /// blocks typed entry either. Each rule's range is clamped to the
    /// sheet's current grid, so a rule defined over (say) a whole
    /// column doesn't force a scan past the populated cells.
    public func invalidCells() -> [CellAddr] {
        guard rowCount > 0, columnCount > 0 else { return [] }
        var found: Set<CellAddr> = []
        let maxRow = rowCount - 1
        let maxCol = columnCount - 1
        for rule in effectiveValidationRules {
            let rowLo = max(0, min(rule.topLeftRow, rule.bottomRightRow))
            let rowHi = min(maxRow, max(rule.topLeftRow, rule.bottomRightRow))
            let colLo = max(0, min(rule.topLeftCol, rule.bottomRightCol))
            let colHi = min(maxCol, max(rule.topLeftCol, rule.bottomRightCol))
            guard rowLo <= rowHi, colLo <= colHi else { continue }
            let resolvedList = resolvedListValues(for: rule)
            for row in rowLo...rowHi {
                for col in colLo...colHi {
                    let value = cellValue(row: row, col: col)
                    if !rule.isSatisfied(by: value, resolvedListValues: resolvedList) {
                        found.insert(CellAddr(col: col, row: row))
                    }
                }
            }
        }
        return found.sorted { lhs, rhs in
            lhs.row != rhs.row ? lhs.row < rhs.row : lhs.col < rhs.col
        }
    }
}
