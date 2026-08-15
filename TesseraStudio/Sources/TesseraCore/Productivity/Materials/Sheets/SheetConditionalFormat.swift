import Foundation

// MARK: - SheetConditionalFormatKind

/// The condition a conditional-formatting rule checks against a range.
/// Adopts cfRule's own vocabulary and evaluation model (OOXML Part 4
/// SpreadsheetML): `.cellValue`/`.formula`/`.text`/`.blanks`/`.errors`/
/// `.top10`/`.aboveAverage`/`.uniqueValues`/`.duplicateValues` are
/// pass/fail conditions that apply `style` to a cell when true;
/// `.colorScale`/`.dataBar`/`.iconSet` are continuous visualizations
/// applied to every cell in range rather than a condition to test -
/// see ``SheetConditionalFormat/matches(_:aggregate:)``. `timePeriod`
/// is P2 (not staged here).
public enum SheetConditionalFormatKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// A numeric comparison against `minValue`/`maxValue`, using the
    /// same comparator vocabulary as ``SheetValidationRule`` - Excel/LO
    /// share this exact set between "Highlight Cells Rules" and data
    /// validation, so reusing ``SheetValidationComparator`` here is
    /// matching an existing shared concept, not introducing a new one.
    /// cfRule calls this type "cellIs".
    case cellValue
    /// A formula that must evaluate truthy. Needs a live formula
    /// engine to check - see `matches(_:aggregate:)`'s doc comment.
    /// Anchors to the range's top-left cell with relative-shift
    /// semantics - see ``SheetConditionalFormat/anchoredFormula(row:col:)``.
    /// cfRule calls this type "expression".
    case formula
    /// Contains / does not contain / begins with / ends with, tested
    /// via `textOperator` against `textValue`. cfRule models these as
    /// four separate rule types (containsText, notContainsText,
    /// beginsWith, endsWith); this follows `SheetValidationRule`'s
    /// convention of one shape with an operator field instead of a
    /// case per operator.
    case text
    /// Cell is/isn't blank, via `negate` (false = containsBlanks,
    /// true = notContainsBlanks).
    case blanks
    /// Cell is/isn't an error, via `negate` (false = containsErrors,
    /// true = notContainsErrors).
    case errors
    /// Top/bottom N or N%, via `top10Count`/`top10IsPercent`/
    /// `top10IsBottom`.
    case top10
    /// Above/below (optionally inclusive of, or N standard deviations
    /// from) the range's average, via the `aboveAverage*` fields.
    case aboveAverage
    case uniqueValues
    case duplicateValues
    case colorScale
    case dataBar
    case iconSet
}

// MARK: - SheetConditionalTextOperator

/// How a `.text` rule tests a cell's string value against `textValue`.
public enum SheetConditionalTextOperator: String, Codable, Sendable, Hashable, CaseIterable {
    case contains
    case notContains
    case beginsWith
    case endsWith
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
/// this ships the rule model and its evaluation, ready for the grid
/// renderer to call ``Sheet/conditionalFormatOverlay(row:col:cache:)``
/// on redraw.
///
/// Adopts cfRule semantics: `priority` (sheet-global, 1 = highest) and
/// `stopIfTrue` resolve which rule(s) win when several rules cover the
/// same cell - see `Array.winningOverlay(for:aggregates:)`. CF stays
/// OUT of the dependency graph (Excel/LO both evaluate it at repaint,
/// not on every recalc) - this type has no formula-engine dependency
/// and no recalc hook; a caller evaluates it lazily per visible cell.
public struct SheetConditionalFormat: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var kind: SheetConditionalFormatKind

    /// Sheet-global rank, 1 = highest priority - cfRule's own
    /// vocabulary. Ties break on array order (`sorted` is stable) in
    /// `Array.winningOverlay(for:aggregates:)`; renumbering existing
    /// rules when a new one is inserted "above" them (Excel's UI
    /// behavior) is store/UI policy, not this model's job.
    public var priority: Int
    /// When this rule matches a cell, lower-priority rules covering
    /// that same cell are not evaluated at all - not merely outranked.
    /// Mirrors cfRule's own `stopIfTrue` exactly.
    public var stopIfTrue: Bool

    // .cellValue
    public var comparator: SheetValidationComparator?
    /// Stored as text and parsed as a number, matching
    /// `SheetValidationRule.minValue`/`maxValue`'s convention.
    public var minValue: String?
    public var maxValue: String?

    // .formula
    /// The check itself, for `.formula` - e.g. `"=A1>B1"`, written as
    /// if for the range's top-left cell.
    public var formula: String?

    // .text
    public var textOperator: SheetConditionalTextOperator?
    public var textValue: String?

    // .blanks / .errors
    /// Inverts the presence test for both `.blanks` and `.errors`
    /// (see their case doc comments) - shared by both kinds rather
    /// than four cases, matching `SheetValidationRule`'s
    /// one-shape-many-kinds convention.
    public var negate: Bool

    // .top10
    /// Stored as text and parsed as a number, matching `minValue`'s
    /// convention above.
    public var top10Count: String?
    public var top10IsPercent: Bool
    public var top10IsBottom: Bool

    // .aboveAverage
    public var aboveAverageIsBelow: Bool
    public var aboveAverageIncludesEqual: Bool
    /// 1...3 standard deviations from the mean instead of the mean
    /// itself - Excel's "N standard deviations above/below average"
    /// variant. `nil` means the plain average.
    public var aboveAverageStdDevCount: Int?

    /// The dxf-style partial override applied to a matching cell, for
    /// every kind above except the continuous-visualization three
    /// (`.colorScale`/`.dataBar`/`.iconSet`, which paint from their own
    /// dedicated fields below, not this one). Reuses
    /// `SheetCellFormatOverlay` (OOXML's dxf shape) rather than a new
    /// style type: a matching rule must be able to set "font red, fill
    /// yellow" without resetting the borders or alignment the cell
    /// already has, which only a partial override can do.
    public var style: SheetCellFormatOverlay?

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
        priority: Int = 1,
        stopIfTrue: Bool = false,
        comparator: SheetValidationComparator? = nil,
        minValue: String? = nil,
        maxValue: String? = nil,
        formula: String? = nil,
        textOperator: SheetConditionalTextOperator? = nil,
        textValue: String? = nil,
        negate: Bool = false,
        top10Count: String? = nil,
        top10IsPercent: Bool = false,
        top10IsBottom: Bool = false,
        aboveAverageIsBelow: Bool = false,
        aboveAverageIncludesEqual: Bool = false,
        aboveAverageStdDevCount: Int? = nil,
        style: SheetCellFormatOverlay? = nil,
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
        self.priority = priority
        self.stopIfTrue = stopIfTrue
        self.comparator = comparator
        self.minValue = minValue
        self.maxValue = maxValue
        self.formula = formula
        self.textOperator = textOperator
        self.textValue = textValue
        self.negate = negate
        self.top10Count = top10Count
        self.top10IsPercent = top10IsPercent
        self.top10IsBottom = top10IsBottom
        self.aboveAverageIsBelow = aboveAverageIsBelow
        self.aboveAverageIncludesEqual = aboveAverageIncludesEqual
        self.aboveAverageStdDevCount = aboveAverageStdDevCount
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
    /// renderer computes their visual directly from `aggregate`
    /// instead of going through this method (see the cfvo math
    /// functions below). `.formula` also always reports true here, for
    /// the same reason `SheetValidationRule.isSatisfied` can't
    /// evaluate `.custom`: no live workbook - a caller wiring
    /// `.formula` rules must evaluate `anchoredFormula(row:col:)`
    /// itself.
    ///
    /// `.top10`/`.aboveAverage`/`.uniqueValues`/`.duplicateValues` need
    /// range-wide context to decide and require `aggregate`; without
    /// one they report false (a missing aggregate falsely NOT
    /// highlighting is the safe default, unlike `.formula`'s "always
    /// true" - there is no live-evaluator equivalent that could ever
    /// make them safe to assume true).
    ///
    /// Unlike `SheetValidationRule.isSatisfied(by:)`, an empty cell
    /// does NOT match `.cellValue` - validation's job is "is this
    /// value allowed" (an unset cell trivially is), while conditional
    /// formatting's job is "does this cell earn a highlight", and an
    /// empty cell never does (except `.blanks`, whose entire job IS
    /// testing emptiness).
    public func matches(_ value: CellValue, aggregate: SheetConditionalFormatRangeAggregate? = nil) -> Bool {
        switch kind {
        case .cellValue:
            guard case .number(let n) = value else { return false }
            return compareNumeric(n)
        case .formula, .colorScale, .dataBar, .iconSet:
            return true
        case .text:
            return matchesText(value)
        case .blanks:
            return value.isEmpty != negate
        case .errors:
            let isError: Bool
            if case .error = value { isError = true } else { isError = false }
            return isError != negate
        case .top10:
            guard let aggregate else { return false }
            return matchesTop10(value, aggregate: aggregate)
        case .aboveAverage:
            guard let aggregate else { return false }
            return matchesAboveAverage(value, aggregate: aggregate)
        case .uniqueValues:
            guard let aggregate, !value.isEmpty else { return false }
            return aggregate.occurrenceCount(of: value) == 1
        case .duplicateValues:
            guard let aggregate, !value.isEmpty else { return false }
            return aggregate.occurrenceCount(of: value) > 1
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

    /// `.text` rules test `.text` cells only, mirroring `.cellValue`
    /// testing only `.number` cells - a numeric cell's displayed text
    /// is out of scope for P1 (see the refinement doc's Calc cluster
    /// notes).
    private func matchesText(_ value: CellValue) -> Bool {
        guard case .text(let s) = value, let needle = textValue, !needle.isEmpty else { return false }
        switch textOperator ?? .contains {
        case .contains:    return s.localizedCaseInsensitiveContains(needle)
        case .notContains: return !s.localizedCaseInsensitiveContains(needle)
        case .beginsWith:  return s.lowercased().hasPrefix(needle.lowercased())
        case .endsWith:    return s.lowercased().hasSuffix(needle.lowercased())
        }
    }

    private func matchesTop10(_ value: CellValue, aggregate: SheetConditionalFormatRangeAggregate) -> Bool {
        guard case .number(let n) = value else { return false }
        guard let rawCount = top10Count.flatMap(Double.init), rawCount > 0 else { return false }
        guard !aggregate.sortedNumericValues.isEmpty else { return false }
        if top10IsPercent {
            let percentile = top10IsBottom ? rawCount : (100 - rawCount)
            guard let cutoff = aggregate.percentileValue(percentile) else { return false }
            return top10IsBottom ? n <= cutoff : n >= cutoff
        }
        let count = min(Int(rawCount), aggregate.sortedNumericValues.count)
        guard count > 0 else { return false }
        if top10IsBottom {
            return n <= aggregate.sortedNumericValues[count - 1]
        }
        return n >= aggregate.sortedNumericValues[aggregate.sortedNumericValues.count - count]
    }

    private func matchesAboveAverage(_ value: CellValue, aggregate: SheetConditionalFormatRangeAggregate) -> Bool {
        guard case .number(let n) = value, let avg = aggregate.average else { return false }
        let distance = Double(aboveAverageStdDevCount ?? 0) * (aggregate.standardDeviation ?? 0)
        let threshold = aboveAverageIsBelow ? avg - distance : avg + distance
        if aboveAverageIsBelow {
            return aboveAverageIncludesEqual ? n <= threshold : n < threshold
        }
        return aboveAverageIncludesEqual ? n >= threshold : n > threshold
    }
}

// MARK: - Formula anchoring

extension SheetConditionalFormat {

    /// Rewrites every un-anchored (non-`$`) reference in `formula` by
    /// `rowDelta`/`colDelta` - fill-handle semantics, not
    /// structural-edit semantics. Contrast `FormulaReferenceAdjuster`,
    /// which shifts BOTH absolute and relative references because a
    /// structural edit physically moves the referenced cell; here
    /// nothing moved, the same rule is being read as if copied to a
    /// different cell, so `$`-anchored references must stay put.
    /// Reuses `FormulaReferenceAdjuster`'s reference scanner/renderer
    /// rather than re-implementing A1 tokenizing.
    public static func shiftedFormula(_ formula: String, rowDelta: Int, colDelta: Int) -> String {
        guard rowDelta != 0 || colDelta != 0 else { return formula }
        let chars = Array(formula)
        var out = ""
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            // Copy string literals verbatim: "A1" inside quotes is text.
            if ch == "\"" {
                out.append(ch)
                i += 1
                while i < chars.count {
                    out.append(chars[i])
                    if chars[i] == "\"" { i += 1; break }
                    i += 1
                }
                continue
            }
            if let match = FormulaReferenceAdjuster.matchReference(chars, from: i) {
                let newCol = match.colAbsolute ? match.column : max(0, match.column + colDelta)
                let newRow = match.rowAbsolute ? match.row : max(0, match.row + rowDelta)
                out.append(FormulaReferenceAdjuster.render(match, column: newCol, row: newRow))
                i = match.end
                continue
            }
            out.append(ch)
            i += 1
        }
        return out
    }

    /// The formula text to evaluate for the cell at `row`/`col`,
    /// shifted from this rule's range top-left with the relative-shift
    /// semantics documented on `shiftedFormula`. `nil` when this isn't
    /// a `.formula` rule or carries no formula. A caller evaluating
    /// `.formula` rules runs the RETURNED text through a live formula
    /// engine at `row`/`col` - `matches(_:aggregate:)` can't do this
    /// itself, see its doc comment.
    public func anchoredFormula(row: Int, col: Int) -> String? {
        guard kind == .formula, let formula else { return nil }
        return SheetConditionalFormat.shiftedFormula(formula, rowDelta: row - topLeftRow, colDelta: col - topLeftCol)
    }
}

// MARK: - cfvo math (colorScale / dataBar / iconSet)

extension SheetConditionalFormat {

    /// dataBar fill length as a percent of cell width (0...100). The
    /// documented formula: `minLength + (v-min)/(max-min) *
    /// (maxLength-minLength)`. `value` is clamped to `[minValue,
    /// maxValue]` first - a value outside the range paints a full or
    /// empty bar, not an out-of-bounds one. `minValue == maxValue`
    /// returns `minLength` (an empty bar, matching Excel's degenerate
    /// flat-range behavior) rather than dividing by zero.
    public static func dataBarLength(
        value: Double,
        minValue: Double,
        maxValue: Double,
        minLength: Double = 10,
        maxLength: Double = 90
    ) -> Double {
        guard maxValue > minValue else { return minLength }
        let clamped = max(minValue, min(maxValue, value))
        let fraction = (clamped - minValue) / (maxValue - minValue)
        return minLength + fraction * (maxLength - minLength)
    }

    /// This rule's dataBar length for `value`, resolving
    /// `dataBarMinValue`/`dataBarMaxValue` against `aggregate` when
    /// unset (cfvo `min`/`max` auto-derive from the range's own
    /// extremes). `nil` when this isn't a `.dataBar` rule or no bound
    /// resolves.
    public func dataBarLength(
        for value: Double,
        aggregate: SheetConditionalFormatRangeAggregate,
        minLength: Double = 10,
        maxLength: Double = 90
    ) -> Double? {
        guard kind == .dataBar else { return nil }
        guard let lo = dataBarMinValue.flatMap(Double.init) ?? aggregate.minimum,
              let hi = dataBarMaxValue.flatMap(Double.init) ?? aggregate.maximum else { return nil }
        return SheetConditionalFormat.dataBarLength(value: value, minValue: lo, maxValue: hi, minLength: minLength, maxLength: maxLength)
    }

    /// Parses `#RRGGBB` into 0...255 per-channel components. `nil` for
    /// a malformed hex (colorScale interpolation has no color to blend).
    public static func rgbComponents(hex: String) -> (r: Int, g: Int, b: Int)? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return (Int((value >> 16) & 0xFF), Int((value >> 8) & 0xFF), Int(value & 0xFF))
    }

    /// Formats 0...255 channel values as `#RRGGBB`, clamping
    /// out-of-range input rather than trapping.
    public static func hex(r: Int, g: Int, b: Int) -> String {
        func clamp(_ v: Int) -> Int { max(0, min(255, v)) }
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }

    /// Linear per-channel interpolation between two `#RRGGBB` colors at
    /// `fraction` (0...1, clamped) - the primitive
    /// `colorScaleColor(for:aggregate:)` walks stop-to-stop with.
    /// Exposed standalone so the cfvo color math can be fixture-tested
    /// without constructing a range aggregate. `nil` when either hex
    /// is malformed.
    public static func interpolatedColor(from: String, to: String, fraction: Double) -> String? {
        guard let a = rgbComponents(hex: from), let b = rgbComponents(hex: to) else { return nil }
        let f = max(0, min(1, fraction))
        let r = Double(a.r) + f * Double(b.r - a.r)
        let g = Double(a.g) + f * Double(b.g - a.g)
        let bl = Double(a.b) + f * Double(b.b - a.b)
        return hex(r: Int(r.rounded()), g: Int(g.rounded()), b: Int(bl.rounded()))
    }

    /// This rule's interpolated fill color for `value`: resolve every
    /// stop to a numeric threshold via `aggregate` (`.minimum`/
    /// `.maximum` -> the range's own extremes; `.percentile`/`.percent`
    /// -> computed against it; `.number` -> the literal), sort them by
    /// threshold, then linearly interpolate each RGB channel between
    /// the two thresholds bracketing `value` - per-channel linear
    /// interpolation between adjacent stops, matching LO's
    /// colorscale.cxx. A value at or beyond an end stop clamps to that
    /// stop's own color. `nil` when this isn't a `.colorScale` rule,
    /// fewer than 2 stops resolve, or a stop's hex is malformed.
    public func colorScaleColor(for value: Double, aggregate: SheetConditionalFormatRangeAggregate) -> String? {
        guard kind == .colorScale, let stops = colorScaleStops else { return nil }
        let resolved = stops.compactMap { stop -> (threshold: Double, hex: String)? in
            guard let threshold = SheetConditionalFormat.resolvedStopThreshold(stop, aggregate: aggregate) else { return nil }
            return (threshold, stop.colorHex)
        }.sorted { $0.threshold < $1.threshold }
        guard resolved.count >= 2 else { return nil }

        if value <= resolved.first!.threshold { return resolved.first!.hex }
        if value >= resolved.last!.threshold { return resolved.last!.hex }

        for i in 1..<resolved.count {
            let hi = resolved[i]
            guard value <= hi.threshold else { continue }
            let lo = resolved[i - 1]
            let span = hi.threshold - lo.threshold
            let fraction = span == 0 ? 0 : (value - lo.threshold) / span
            return SheetConditionalFormat.interpolatedColor(from: lo.hex, to: hi.hex, fraction: fraction)
        }
        // Unreachable given the clamped bounds above; keeps the
        // function total rather than force-unwrapping.
        return resolved.last!.hex
    }

    private static func resolvedStopThreshold(
        _ stop: SheetColorScaleStop,
        aggregate: SheetConditionalFormatRangeAggregate
    ) -> Double? {
        switch stop.kind {
        case .minimum: return aggregate.minimum
        case .maximum: return aggregate.maximum
        case .number: return stop.value.flatMap(Double.init)
        case .percentile:
            return stop.value.flatMap(Double.init).flatMap(aggregate.percentileValue)
        case .percent:
            guard let pct = stop.value.flatMap(Double.init),
                  let lo = aggregate.minimum, let hi = aggregate.maximum else { return nil }
            return lo + (pct / 100) * (hi - lo)
        }
    }

    /// The icon index (0-based ascending, Excel's "worst" to "best"
    /// convention) for `value` under ascending `thresholds`, using
    /// `gte` (>=) comparison per the documented cfvo math: the count
    /// of thresholds `value` meets or exceeds.
    public static func iconIndex(for value: Double, thresholds: [Double]) -> Int {
        thresholds.reduce(0) { count, threshold in value >= threshold ? count + 1 : count }
    }

    /// This rule's icon index for `value`, parsing `iconSetThresholds`.
    /// `nil` when this isn't an `.iconSet` rule or no thresholds parse.
    public func iconIndex(for value: Double) -> Int? {
        guard kind == .iconSet else { return nil }
        let thresholds = (iconSetThresholds ?? []).compactMap(Double.init)
        guard !thresholds.isEmpty else { return nil }
        return SheetConditionalFormat.iconIndex(for: value, thresholds: thresholds)
    }
}

// MARK: - SheetConditionalFormatRangeAggregate

/// Range-wide statistics one covering rule needs to test a single
/// cell: min/max/average/stdDev/percentile for the numeric-only kinds
/// (`.top10`, `.aboveAverage`, `.colorScale`, `.dataBar`), plus
/// per-value occurrence counts for `.uniqueValues`/`.duplicateValues`.
/// A pure snapshot of one range at one point in time - see
/// ``SheetConditionalFormatAggregateCache`` for how a caller keeps one
/// fresh across edits without recomputing it per cell per redraw.
public struct SheetConditionalFormatRangeAggregate: Sendable, Hashable {
    /// Numeric cells only, in range order. Non-numeric cells (text,
    /// blank, error, checkbox, unevaluated formula) are silently
    /// skipped, matching Excel: a text cell inside a colorScale range
    /// simply doesn't participate in the min/max/percentile math.
    public let numericValues: [Double]
    /// Ascending-sorted copy of `numericValues`, cached once so
    /// percentile/top10 lookups don't re-sort per cell.
    public let sortedNumericValues: [Double]
    public let minimum: Double?
    public let maximum: Double?
    public let average: Double?
    /// Population standard deviation (divide by N, not N-1) - matches
    /// Excel's STDEVP, which is what cfRule's `aboveAverage` `stdDev`
    /// attribute is defined against.
    public let standardDeviation: Double?

    /// Occurrence count of every distinct non-empty value in the
    /// range (any `CellValue` kind, canonicalized so `.number(1)` and
    /// `.text("1")` are distinct) - backs `.uniqueValues`/
    /// `.duplicateValues`.
    private let occurrences: [String: Int]

    public init(values: [CellValue]) {
        var nums: [Double] = []
        var counts: [String: Int] = [:]
        for value in values {
            if case .number(let n) = value { nums.append(n) }
            guard !value.isEmpty else { continue }
            counts[SheetConditionalFormatRangeAggregate.canonicalKey(value), default: 0] += 1
        }
        numericValues = nums
        sortedNumericValues = nums.sorted()
        minimum = nums.min()
        maximum = nums.max()
        if nums.isEmpty {
            average = nil
            standardDeviation = nil
        } else {
            let avg = nums.reduce(0, +) / Double(nums.count)
            average = avg
            let variance = nums.reduce(0) { $0 + ($1 - avg) * ($1 - avg) } / Double(nums.count)
            standardDeviation = variance.squareRoot()
        }
        occurrences = counts
    }

    /// How many cells in the range hold a value equal to `value` -
    /// backs `.uniqueValues`/`.duplicateValues`. `.empty` always
    /// reports 0: blank cells are never "duplicates" of each other.
    public func occurrenceCount(of value: CellValue) -> Int {
        guard !value.isEmpty else { return 0 }
        return occurrences[SheetConditionalFormatRangeAggregate.canonicalKey(value)] ?? 0
    }

    /// The value at `percentile` (0...100) via linear interpolation
    /// between the two bracketing sorted samples (Excel's
    /// PERCENTILE.INC method) - what a `.colorScale` `.percentile`
    /// stop and a `.top10` percent cutoff both need. `nil` when there
    /// are no numeric values.
    public func percentileValue(_ percentile: Double) -> Double? {
        guard !sortedNumericValues.isEmpty else { return nil }
        guard sortedNumericValues.count > 1 else { return sortedNumericValues[0] }
        let clamped = max(0, min(100, percentile))
        let rank = clamped / 100 * Double(sortedNumericValues.count - 1)
        let lowIndex = Int(rank.rounded(.down))
        let highIndex = Int(rank.rounded(.up))
        if lowIndex == highIndex { return sortedNumericValues[lowIndex] }
        let fraction = rank - Double(lowIndex)
        let lo = sortedNumericValues[lowIndex]
        let hi = sortedNumericValues[highIndex]
        return lo + fraction * (hi - lo)
    }

    private static func canonicalKey(_ value: CellValue) -> String {
        switch value {
        case .empty: return "e"
        case .text(let s): return "t:\(s)"
        case .number(let n): return "n:\(n)"
        case .date(let d): return "d:\(d.timeIntervalSince1970)"
        case .checkbox(let b): return "b:\(b)"
        case .formula(let f): return "f:\(f)"
        case .error(let e): return "x:\(e)"
        }
    }
}

// MARK: - SheetConditionalFormatAggregateCache

/// Per-rule ``SheetConditionalFormatRangeAggregate`` memoization for
/// viewport-lazy paint-time evaluation. CF deliberately stays out of
/// the dependency graph - Excel/LO both evaluate it at repaint, not on
/// every recalc (a duplicate-detection rule over 100K+ cells is too
/// slow to run per edit). A caller calls `aggregate(for:in:)` once per
/// visible rule per redraw and `invalidate(_:)` when an edit lands
/// inside that rule's range - explicit invalidation, no dependency
/// tracking. Mirrors `SheetValueRenderer`'s lock-guarded cache one
/// file over.
public final class SheetConditionalFormatAggregateCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: SheetConditionalFormatRangeAggregate] = [:]

    public init() {}

    /// The cached aggregate for `rule`, computing it from `sheet` on a
    /// miss. `nil` when the rule's stored coordinates don't form a
    /// valid range (see `rangeRef`).
    public func aggregate(for rule: SheetConditionalFormat, in sheet: Sheet) -> SheetConditionalFormatRangeAggregate? {
        guard let range = rule.rangeRef else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let hit = storage[rule.id] { return hit }
        let values = range.cells().map { sheet.cellValue(row: $0.row, col: $0.col) }
        let computed = SheetConditionalFormatRangeAggregate(values: values)
        storage[rule.id] = computed
        return computed
    }

    /// Drop the cached aggregate for one rule - call after an edit
    /// lands inside that rule's range.
    public func invalidate(_ ruleID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: ruleID)
    }

    /// Drop every cached aggregate - call after a bulk edit (paste,
    /// sort, structural edit) that's cheaper to blanket-invalidate
    /// than to diff range-by-range.
    public func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}

// MARK: - Priority / stopIfTrue winner resolution

extension SheetCellFormatOverlay {
    /// `self` with every field `self` left unset filled in from
    /// `lower` - used by `Array.winningOverlay(for:aggregates:)` to
    /// accumulate priority-ordered rule overlays, where `self` already
    /// carries the higher-priority rules' fields and must not lose
    /// them to a lower-priority rule's setting of the same field.
    /// Lives here (not in SheetCellFormat.swift) since it's meaningful
    /// only for cfRule priority resolution.
    func merging(filling lower: SheetCellFormatOverlay) -> SheetCellFormatOverlay {
        SheetCellFormatOverlay(
            numberFormat: numberFormat ?? lower.numberFormat,
            decimals: decimals ?? lower.decimals,
            isBold: isBold ?? lower.isBold,
            isItalic: isItalic ?? lower.isItalic,
            fillHex: fillHex ?? lower.fillHex,
            textHex: textHex ?? lower.textHex,
            borders: borders ?? lower.borders,
            alignment: alignment ?? lower.alignment
        )
    }
}

extension Array where Element == SheetConditionalFormat {
    /// The dxf overlay a cell should render, given the rules that
    /// cover it (e.g. `Sheet.conditionalFormats(row:col:)`'s result)
    /// and its value. Implements cfRule's per-property winner: walk
    /// matching rules in ascending `priority` (1 first), each filling
    /// only the overlay fields no higher-priority rule already set; a
    /// match on a `stopIfTrue` rule ends the walk immediately, so
    /// lower-priority rules never run for this cell at all - not
    /// merely lose ties. Equal priorities keep `self`'s original order
    /// (`sorted` is stable) as a deterministic fallback; callers
    /// should keep priorities distinct in practice.
    public func winningOverlay(
        for value: CellValue,
        aggregates: [UUID: SheetConditionalFormatRangeAggregate] = [:]
    ) -> SheetCellFormatOverlay {
        var result = SheetCellFormatOverlay()
        for rule in sorted(by: { $0.priority < $1.priority }) {
            guard rule.matches(value, aggregate: aggregates[rule.id]) else { continue }
            if let style = rule.style {
                result = result.merging(filling: style)
            }
            if rule.stopIfTrue { break }
        }
        return result
    }
}

// MARK: - Sheet storage + evaluation

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
    /// reports what applies, it doesn't pick a winner; use
    /// `conditionalFormatOverlay(row:col:cache:)` for cfRule's actual
    /// priority/stopIfTrue winner).
    public func conditionalFormats(row: Int, col: Int) -> [SheetConditionalFormat] {
        effectiveConditionalFormats.filter { $0.covers(row: row, col: col) }
    }

    /// The dxf overlay that should render over the cell at `row`/`col`,
    /// per cfRule priority + `stopIfTrue` resolution (see
    /// `Array.winningOverlay(for:aggregates:)`). `cache` supplies the
    /// per-rule range aggregates that `.top10`/`.aboveAverage`/
    /// `.uniqueValues`/`.duplicateValues` rules need to decide;
    /// omitting it is safe when none of the covering rules use those
    /// kinds (they simply won't match, per `matches(_:aggregate:)`'s
    /// documented "no aggregate, no match" fallback).
    public func conditionalFormatOverlay(
        row: Int,
        col: Int,
        cache: SheetConditionalFormatAggregateCache? = nil
    ) -> SheetCellFormatOverlay {
        let rules = conditionalFormats(row: row, col: col)
        guard !rules.isEmpty else { return SheetCellFormatOverlay() }
        let value = cellValue(row: row, col: col)
        var aggregates: [UUID: SheetConditionalFormatRangeAggregate] = [:]
        if let cache {
            for rule in rules {
                aggregates[rule.id] = cache.aggregate(for: rule, in: self)
            }
        }
        return rules.winningOverlay(for: value, aggregates: aggregates)
    }
}
