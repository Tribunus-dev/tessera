import Foundation

// MARK: - SheetValidationKind

/// The constraint a validation rule checks. Matches Excel/LO's own
/// Data Validation kinds closely enough to round-trip an imported
/// XLSX/ODS's validation rules without losing which kind a cell had.
public enum SheetValidationKind: String, Codable, Sendable, Hashable, CaseIterable {
    case wholeNumber
    case decimal
    /// A dropdown of allowed values (`listValues`).
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

// MARK: - SheetValidationRule

/// A data-validation rule bound to a range on a `Sheet`. Persisted on
/// `Sheet.validationRules`; `SheetWorkbook` doesn't consult these yet
/// (see the file header's scope note) - this ships the rule model
/// itself, ready for the input layer to check against on cell edit.
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
    /// The dropdown's allowed values, for `.list`.
    public var listValues: [String]?
    /// The check itself, for `.custom` - e.g. `"=A1>B1"`.
    public var formula: String?
    /// Shown to the user when a value fails this rule. `nil` falls
    /// back to a generic message the input layer supplies.
    public var errorMessage: String?

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
        formula: String? = nil,
        errorMessage: String? = nil,
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
        self.formula = formula
        self.errorMessage = errorMessage
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

    /// True if `row`/`col` (0-based, matching `CellAddr`) fall inside
    /// this rule's range.
    public func covers(row: Int, col: Int) -> Bool {
        row >= topLeftRow && row <= bottomRightRow && col >= topLeftCol && col <= bottomRightCol
    }

    /// Whether `value` satisfies this rule. `.custom` always returns
    /// true here - checking a formula needs a live workbook to
    /// evaluate it against, which this pure model doesn't have; a
    /// caller wiring `.custom` rules is responsible for evaluating
    /// `formula` itself and treating the result the way this method's
    /// Bool is used elsewhere. `.formula`/`.error`/`.empty` cell values
    /// pass every kind except where a rule is checking against a
    /// STORED formula cell's raw text makes no sense - such cells are
    /// simply not checked (the caller should validate the EVALUATED
    /// result of a formula cell, not its stored `CellValue.formula`
    /// case, which this method has no way to evaluate).
    public func isSatisfied(by value: CellValue) -> Bool {
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
}
