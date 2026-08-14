import Foundation

// MARK: - SheetConditionalFormatKind

/// The condition a conditional-formatting rule checks against a range.
/// `.cellValue`/`.formula` are pass/fail conditions that apply `style`
/// to a cell when true; `.colorScale`/`.dataBar`/`.iconSet` are
/// continuous visualizations applied to every cell in range rather than
/// a condition to test - see ``SheetConditionalFormat/matches(_:)``.
public enum SheetConditionalFormatKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// A numeric comparison against `minValue`/`maxValue`, using the
    /// same comparator vocabulary as ``SheetValidationRule`` - Excel/LO
    /// share this exact set between "Highlight Cells Rules" and data
    /// validation, so reusing ``SheetValidationComparator`` here is
    /// matching an existing shared concept, not introducing a new one.
    case cellValue
    /// A formula that must evaluate truthy. Needs a live formula
    /// engine to check - see `matches(_:)`'s doc comment.
    case formula
    case colorScale
    case dataBar
    case iconSet
}

// MARK: - SheetColorScaleStop

/// One stop in a `.colorScale` rule's gradient.
public struct SheetColorScaleStop: Codable, Sendable, Hashable {
    public enum StopKind: String, Codable, Sendable, Hashable, CaseIterable {
        case minimum
        case maximum
        case percentile
        case number
        case percent
    }

    public var kind: StopKind
    /// The threshold, parsed per `kind`. Unused (nil) for
    /// `.minimum`/`.maximum`, which anchor to the range's own extremes.
    public var value: String?
    /// `#RRGGBB`, matching `SheetCellFormat.fillHex`'s convention.
    public var colorHex: String

    public init(kind: StopKind, value: String? = nil, colorHex: String) {
        self.kind = kind
        self.value = value
        self.colorHex = colorHex
    }
}

// MARK: - SheetConditionalFormat

/// A conditional-formatting rule bound to a range on a `Sheet`.
/// Persisted on `Sheet.conditionalFormats`; `SheetWorkbook` doesn't
/// consult these yet, matching ``SheetValidationRule``'s scope note -
/// this ships the rule model itself, ready for the grid renderer to
/// check against on redraw.
public struct SheetConditionalFormat: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var kind: SheetConditionalFormatKind

    // .cellValue
    public var comparator: SheetValidationComparator?
    /// Stored as text and parsed as a number, matching
    /// `SheetValidationRule.minValue`/`maxValue`'s convention.
    public var minValue: String?
    public var maxValue: String?

    // .formula
    /// The check itself, for `.formula` - e.g. `"=A1>B1"`.
    public var formula: String?

    /// The presentation applied to a matching cell, for `.cellValue`/
    /// `.formula`. Reuses `SheetCellFormat` rather than a new style
    /// type: it already models exactly "bold/italic/fill/text colour",
    /// which is all a highlight rule needs.
    public var style: SheetCellFormat?

    // .colorScale
    public var colorScaleStops: [SheetColorScaleStop]?

    // .dataBar
    public var dataBarColorHex: String?
    public var dataBarMinValue: String?
    public var dataBarMaxValue: String?

    // .iconSet
    /// Identifies which built-in icon family to draw (e.g.
    /// "3TrafficLights") - the renderer owns the actual glyph mapping,
    /// this model just persists which set was chosen.
    public var iconSetID: String?
    /// Ascending thresholds, one fewer than the number of icons in the
    /// set, parsed as numbers.
    public var iconSetThresholds: [String]?

    public var sheet: String?
    public var topLeftCol: Int
    public var topLeftRow: Int
    public var bottomRightCol: Int
    public var bottomRightRow: Int

    public init(
        id: UUID = UUID(),
        kind: SheetConditionalFormatKind,
        comparator: SheetValidationComparator? = nil,
        minValue: String? = nil,
        maxValue: String? = nil,
        formula: String? = nil,
        style: SheetCellFormat? = nil,
        colorScaleStops: [SheetColorScaleStop]? = nil,
        dataBarColorHex: String? = nil,
        dataBarMinValue: String? = nil,
        dataBarMaxValue: String? = nil,
        iconSetID: String? = nil,
        iconSetThresholds: [String]? = nil,
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
        self.formula = formula
        self.style = style
        self.colorScaleStops = colorScaleStops
        self.dataBarColorHex = dataBarColorHex
        self.dataBarMinValue = dataBarMinValue
        self.dataBarMaxValue = dataBarMaxValue
        self.iconSetID = iconSetID
        self.iconSetThresholds = iconSetThresholds
        self.sheet = sheet
        self.topLeftCol = topLeftCol
        self.topLeftRow = topLeftRow
        self.bottomRightCol = bottomRightCol
        self.bottomRightRow = bottomRightRow
    }

    /// `nil` if any coordinate is negative - see `SheetNamedRange`'s
    /// doc comment for why this validates rather than constructing
    /// `CellAddr` directly.
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

    /// Whether `value` matches this rule's condition, i.e. whether
    /// `style` should be applied to the cell holding it.
    ///
    /// `.colorScale`/`.dataBar`/`.iconSet` always report true - they
    /// paint every cell in range on a continuous scale rather than
    /// testing a condition, so "matches" is meaningless for them; the
    /// renderer computes their visual directly from the range's values
    /// instead of going through this method. `.formula` also always
    /// reports true here, for the same reason `SheetValidationRule
    /// .isSatisfied` can't evaluate `.custom`: no live workbook: a
    /// caller wiring `.formula` rules must evaluate `formula` itself.
    ///
    /// Unlike `SheetValidationRule.isSatisfied(by:)`, an empty cell
    /// does NOT match `.cellValue` - validation's job is "is this
    /// value allowed" (an unset cell trivially is), while conditional
    /// formatting's job is "does this cell earn a highlight", and an
    /// empty cell never does.
    public func matches(_ value: CellValue) -> Bool {
        switch kind {
        case .cellValue:
            guard case .number(let n) = value else { return false }
            return compareNumeric(n)
        case .formula, .colorScale, .dataBar, .iconSet:
            return true
        }
    }

    private func compareNumeric(_ actual: Double) -> Bool {
        let lo = minValue.flatMap(Double.init)
        let hi = maxValue.flatMap(Double.init)
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
    /// `conditionalFormats ?? []`, matching `effectiveValidationRules`/
    /// `effectiveNamedRanges`'s "nil means none" convention.
    public var effectiveConditionalFormats: [SheetConditionalFormat] {
        conditionalFormats ?? []
    }

    /// A copy with `rule` appended.
    public func addingConditionalFormat(_ rule: SheetConditionalFormat) -> Sheet {
        var updated = self
        updated.conditionalFormats = effectiveConditionalFormats + [rule]
        return updated
    }

    /// A copy with the rule matching `id` removed. A no-op if no rule
    /// has that id.
    public func removingConditionalFormat(_ id: UUID) -> Sheet {
        var updated = self
        updated.conditionalFormats = effectiveConditionalFormats.filter { $0.id != id }
        return updated
    }

    /// Every rule covering `row`/`col`, in definition order (later
    /// rules can be treated as taking precedence by a caller that
    /// wants "last one wins" for overlapping ranges - this just
    /// reports what applies, it doesn't pick a winner).
    public func conditionalFormats(row: Int, col: Int) -> [SheetConditionalFormat] {
        effectiveConditionalFormats.filter { $0.covers(row: row, col: col) }
    }
}
