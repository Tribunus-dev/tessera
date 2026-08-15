//===----------------------------------------------------------------------===//
//  SheetCellFormat.swift
//  Tessera Studio
//
//  Per-cell presentation: number format, emphasis, fill, borders and
//  alignment. Presentation only - the stored source text and the
//  computed value are both untouched by anything in this file.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - SheetNumberFormat

/// How a cell's computed value is rendered.
///
/// The distinction that matters: a format changes only what the grid
/// DRAWS. `1234.5` formatted as currency is still the number 1234.5 to
/// every formula that references it. Storing the formatted string
/// instead would make the cell text, and `SUM` over the column would
/// silently start ignoring it.
public enum SheetNumberFormat: String, Codable, Sendable, Hashable, CaseIterable {
    /// Whatever the value's own description is. The default, and what
    /// every cell written before this type existed decodes to.
    case general
    /// Fixed decimal places, no thousands separator.
    case number
    /// Thousands separators plus fixed decimals; negatives parenthesised,
    /// which is the accounting convention users expect in a model.
    case comma
    /// Currency symbol from the current locale, negatives parenthesised.
    case currency
    /// Value times 100 with a trailing percent sign. A cell holding 0.25
    /// shows 25%, matching Excel: the STORED number is the fraction.
    case percent
    /// Scientific notation, e.g. 1.23E+04.
    case scientific
    /// A serial number rendered as a date. Non-numeric values fall back
    /// to their string form rather than showing an error.
    case date
    /// Force the value to render as plain text even when numeric.
    case text

    public var displayName: String {
        switch self {
        case .general:    return "General"
        case .number:     return "Number"
        case .comma:      return "Comma"
        case .currency:   return "Currency"
        case .percent:    return "Percent"
        case .scientific: return "Scientific"
        case .date:       return "Date"
        case .text:       return "Text"
        }
    }

    /// Decimal places a cell gets when the user first switches to this
    /// format. Currency and percent pick the conventional defaults so a
    /// single click lands on the format the user meant.
    public var defaultDecimals: Int {
        switch self {
        case .general, .text, .date: return 0
        case .number, .comma, .currency: return 2
        case .percent: return 0
        case .scientific: return 2
        }
    }
}

extension SheetNumberFormat {
    /// The Excel/ODF format code this preset expands to - the
    /// "categorical enum becomes a preset table" evolution: every case
    /// bottoms out in a real code that ``NumberFormatEngine`` parses and
    /// formats, rather than a hand-rolled render branch of its own.
    ///
    /// `decimals` is spliced in as a repeated digit mask; `currencySymbol`
    /// (meaningful only for ``currency``) is locale data supplied by the
    /// caller, not baked into the preset. Both are inserted quoted so a
    /// symbol that happens to contain a digit-mask or date-token
    /// character (e.g. an abbreviation using "m" or "d") cannot be
    /// mis-tokenized as a format directive.
    func formatCode(decimals: Int, currencySymbol: String) -> String {
        let frac = decimals > 0 ? "." + String(repeating: "0", count: decimals) : ""
        switch self {
        case .general:
            return "General"
        case .number:
            return "0" + frac
        case .comma:
            return "#,##0\(frac);(#,##0\(frac))"
        case .currency:
            let symbol = "\"\(currencySymbol)\""
            return "\(symbol)#,##0\(frac);(\(symbol)#,##0\(frac))"
        case .percent:
            return "0\(frac)%"
        case .scientific:
            return "0\(frac)E+00"
        case .date:
            // Short month, unpadded day, 4-digit year - the grid's
            // existing "Jan 1, 1970" convention, now produced by the
            // engine instead of a second DateFormatter.
            return "mmm d, yyyy"
        case .text:
            // Never reached on the render path (`SheetValueRenderer`
            // short-circuits `.text` before it needs a code); listed for
            // switch exhaustiveness. "@" is Excel's text-section token.
            return "@"
        }
    }
}

// MARK: - SheetCellBorders

/// Which edges of a cell are stroked. An `OptionSet` because the four
/// edges are independent: "outline" is a combination, not a fifth case.
public struct SheetCellBorders: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let top      = SheetCellBorders(rawValue: 1 << 0)
    public static let bottom   = SheetCellBorders(rawValue: 1 << 1)
    public static let leading  = SheetCellBorders(rawValue: 1 << 2)
    public static let trailing = SheetCellBorders(rawValue: 1 << 3)

    public static let none: SheetCellBorders = []
    public static let all: SheetCellBorders = [.top, .bottom, .leading, .trailing]
    /// The single bottom rule under a total row.
    public static let underline: SheetCellBorders = [.bottom]
}

// MARK: - SheetCellAlignment

public enum SheetCellAlignment: String, Codable, Sendable, Hashable, CaseIterable {
    /// No explicit choice: numbers align right, text left, as in every
    /// spreadsheet. Kept distinct from `.leading` so the grid can tell
    /// "the user chose left" from "nobody chose anything".
    case automatic
    case leading
    case center
    case trailing
}

// MARK: - SheetCellFormat

/// The full presentation state of one cell.
///
/// Persisted inside the cell block's open `attributes` bag rather than
/// as new stored properties, so a sheet written before this type
/// existed still decodes: a missing `format` key is ``standard``.
public struct SheetCellFormat: Codable, Sendable, Hashable {
    public var numberFormat: SheetNumberFormat
    public var decimals: Int
    public var isBold: Bool
    public var isItalic: Bool
    /// Background fill as a `#RRGGBB` string, or nil for no fill.
    public var fillHex: String?
    /// Text colour as a `#RRGGBB` string, or nil for the default.
    public var textHex: String?
    public var borders: SheetCellBorders
    public var alignment: SheetCellAlignment

    public static let standard = SheetCellFormat()

    public init(
        numberFormat: SheetNumberFormat = .general,
        decimals: Int = 0,
        isBold: Bool = false,
        isItalic: Bool = false,
        fillHex: String? = nil,
        textHex: String? = nil,
        borders: SheetCellBorders = .none,
        alignment: SheetCellAlignment = .automatic
    ) {
        self.numberFormat = numberFormat
        self.decimals = max(0, min(decimals, 15))
        self.isBold = isBold
        self.isItalic = isItalic
        self.fillHex = fillHex
        self.textHex = textHex
        self.borders = borders
        self.alignment = alignment
    }

    /// True when the format carries nothing worth storing. The store
    /// drops the attribute entirely in that case, so clearing a format
    /// leaves the block exactly as it was before it was ever set.
    public var isStandard: Bool { self == .standard }

    // MARK: - Mutating helpers

    /// Switch number format, adopting that format's conventional decimal
    /// count. Re-applying the format the cell already has is a no-op, so
    /// a user who set 4 decimals then clicked Currency again does not
    /// lose them.
    public func settingNumberFormat(_ format: SheetNumberFormat) -> SheetCellFormat {
        guard format != numberFormat else { return self }
        var copy = self
        copy.numberFormat = format
        copy.decimals = format.defaultDecimals
        return copy
    }

    /// Step the decimal count, clamped to 0...15. Applying it to a
    /// `.general` cell promotes it to `.number`: "more decimals" is
    /// meaningless without a fixed-decimal format, and doing nothing
    /// would read as a broken button.
    public func steppingDecimals(by delta: Int) -> SheetCellFormat {
        var copy = self
        if copy.numberFormat == .general || copy.numberFormat == .text {
            copy.numberFormat = .number
        }
        copy.decimals = max(0, min(copy.decimals + delta, 15))
        return copy
    }
}

// MARK: - JSON bridging

extension SheetCellFormat {

    /// Keys inside `attributes["format"]`. Only non-default fields are
    /// written, keeping the stored JSON small and diffable.
    private enum Key {
        static let numberFormat = "numberFormat"
        static let decimals = "decimals"
        static let bold = "bold"
        static let italic = "italic"
        static let fill = "fill"
        static let text = "text"
        static let borders = "borders"
        static let alignment = "alignment"
    }

    /// The attribute key the cell block stores this under.
    public static let attributeKey = "format"

    public init?(json: JSONValue) {
        guard case .object(let dict) = json else { return nil }
        var format = SheetCellFormat()
        if let raw = dict[Key.numberFormat]?.stringValue,
           let parsed = SheetNumberFormat(rawValue: raw) {
            format.numberFormat = parsed
        }
        if let d = dict[Key.decimals]?.numberValue {
            format.decimals = max(0, min(Int(d), 15))
        }
        format.isBold = dict[Key.bold]?.boolValue ?? false
        format.isItalic = dict[Key.italic]?.boolValue ?? false
        format.fillHex = dict[Key.fill]?.stringValue
        format.textHex = dict[Key.text]?.stringValue
        if let b = dict[Key.borders]?.numberValue {
            format.borders = SheetCellBorders(rawValue: Int(b))
        }
        if let raw = dict[Key.alignment]?.stringValue,
           let parsed = SheetCellAlignment(rawValue: raw) {
            format.alignment = parsed
        }
        self = format
    }

    public var json: JSONValue {
        var dict: [String: JSONValue] = [:]
        if numberFormat != .general {
            dict[Key.numberFormat] = .string(numberFormat.rawValue)
        }
        if decimals != 0 { dict[Key.decimals] = .number(Double(decimals)) }
        if isBold { dict[Key.bold] = .bool(true) }
        if isItalic { dict[Key.italic] = .bool(true) }
        if let fillHex { dict[Key.fill] = .string(fillHex) }
        if let textHex { dict[Key.text] = .string(textHex) }
        if !borders.isEmpty { dict[Key.borders] = .number(Double(borders.rawValue)) }
        if alignment != .automatic { dict[Key.alignment] = .string(alignment.rawValue) }
        return .object(dict)
    }
}

// MARK: - SheetCellFormatOverlay (dxf subset)

/// A partial override of ``SheetCellFormat``: every field optional,
/// `nil` meaning "this overlay doesn't touch that property" rather than
/// "clear it". This is OOXML's dxf (differential formatting record)
/// concept - the shape a conditional-format rule's style needs, since a
/// rule like "font red, fill yellow" must not reset the borders or
/// alignment the cell already has when it applies.
///
/// `decimals` rides with `numberFormat` the same way it does on
/// ``SheetCellFormat``: a rule that sets `.percent` but leaves `decimals`
/// nil falls through to the base cell's own decimal count, not to
/// `.percent`'s conventional default.
///
/// `fillHex`/`textHex` are a two-state `String?` (present = this color;
/// absent = don't touch), not three-state - an overlay can set a color
/// but cannot use this type to explicitly clear one the cell already
/// has. No current rule kind needs that, and a double-optional for it
/// is not worth the API weight; revisit only if a real rule needs
/// "explicitly no fill" as distinct from "unspecified".
///
/// Introduced for 1.12 (``SheetConditionalFormat``): a matching rule
/// applies its overlay via ``applied(over:)`` at paint time. It never
/// touches the cell's own stored ``SheetCellFormat``.
public struct SheetCellFormatOverlay: Codable, Sendable, Hashable {
    public var numberFormat: SheetNumberFormat?
    public var decimals: Int?
    public var isBold: Bool?
    public var isItalic: Bool?
    public var fillHex: String?
    public var textHex: String?
    public var borders: SheetCellBorders?
    public var alignment: SheetCellAlignment?

    public init(
        numberFormat: SheetNumberFormat? = nil,
        decimals: Int? = nil,
        isBold: Bool? = nil,
        isItalic: Bool? = nil,
        fillHex: String? = nil,
        textHex: String? = nil,
        borders: SheetCellBorders? = nil,
        alignment: SheetCellAlignment? = nil
    ) {
        self.numberFormat = numberFormat
        self.decimals = decimals.map { max(0, min($0, 15)) }
        self.isBold = isBold
        self.isItalic = isItalic
        self.fillHex = fillHex
        self.textHex = textHex
        self.borders = borders
        self.alignment = alignment
    }

    /// True when every field is `nil` - applying this overlay is a no-op.
    public var isEmpty: Bool { self == SheetCellFormatOverlay() }

    /// `base` with every non-nil field of this overlay substituted in.
    /// Fields left `nil` here pass `base`'s value through unchanged.
    public func applied(over base: SheetCellFormat) -> SheetCellFormat {
        var result = base
        if let numberFormat { result.numberFormat = numberFormat }
        if let decimals { result.decimals = max(0, min(decimals, 15)) }
        if let isBold { result.isBold = isBold }
        if let isItalic { result.isItalic = isItalic }
        if let fillHex { result.fillHex = fillHex }
        if let textHex { result.textHex = textHex }
        if let borders { result.borders = borders }
        if let alignment { result.alignment = alignment }
        return result
    }
}

// MARK: - Rendering

/// Turns a computed ``Value`` into the string the grid draws.
///
/// Separate from ``SheetCellFormat`` so it can hold the locale and the
/// cached parsed ``NumberFormat``s: parsing a format code per cell per
/// redraw is measurably slow on a grid of any size.
///
/// No formatting math lives here. Every ``SheetNumberFormat`` case
/// expands to a real Excel/ODF format code
/// (``SheetNumberFormat/formatCode(decimals:currencySymbol:)``) and the
/// actual digit/date rendering runs through ``NumberFormatEngine`` - a
/// second hand-rolled formatter here would silently drift from what a
/// custom (non-preset) format code produces everywhere else in the app.
public enum SheetValueRenderer {

    /// Render `value` under `format`. Errors always render as their
    /// Excel code regardless of format - `#DIV/0!` dressed up as
    /// currency would read as a real number.
    public static func string(
        for value: Value,
        format: SheetCellFormat,
        locale: Locale = .current
    ) -> String {
        if case .error(let err) = value { return err.displayString }
        if format.numberFormat == .text { return value.asString }
        guard let number = numeric(value) else { return value.asString }

        switch format.numberFormat {
        case .general:
            return value.asString
        case .text:
            return value.asString
        case .date:
            guard let date = dateFromSerial(number) else { return String(number) }
            let parsed = parsedFormat(for: .date, decimals: 0, currencySymbol: "")
            return NumberFormatEngine.format(date, using: parsed, locale: locale)
        default:
            let symbol = format.numberFormat == .currency ? (locale.currencySymbol ?? "$") : ""
            let parsed = parsedFormat(for: format.numberFormat, decimals: format.decimals, currencySymbol: symbol)
            return NumberFormatEngine.format(number, using: parsed, locale: locale)
        }
    }

    /// Only genuine numbers are formatted. A bool is deliberately NOT
    /// coerced: TRUE rendered as "$1.00" hides what the cell holds.
    /// `NumberFormatEngine.format` itself WOULD coerce (it accepts any
    /// `Value` and reads `asNumber`, which maps bools/strings/dates to
    /// numbers) - this guard runs before the engine is called at all,
    /// rather than relying on the engine to enforce a rule it has no
    /// way to know about.
    private static func numeric(_ value: Value) -> Double? {
        if case .number(let n) = value { return n }
        return nil
    }

    /// Spreadsheet date serials count days from 1899-12-30, which is
    /// what `DateFunctions` uses (it pins serial 25569 to 1970-01-01).
    /// The two must agree: `=TODAY()` formatted as a date is a serial
    /// the engine produced and this renders.
    ///
    /// The base is a day earlier than "serial 1 is 1900-01-01" would
    /// suggest, and deliberately so: it absorbs Excel's phantom
    /// 1900-02-29, which makes every serial from 1900-03-01 onward
    /// agree with Excel. Serials 1..59 differ, and no real model uses
    /// them.
    private static func dateFromSerial(_ serial: Double) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var epoch = DateComponents()
        epoch.year = 1899
        epoch.month = 12
        epoch.day = 30
        guard let base = calendar.date(from: epoch) else { return nil }
        return base.addingTimeInterval(serial * 86_400)
    }

    // MARK: - Parsed-format cache

    /// Keyed by the three inputs that change the parsed code: the
    /// preset, its decimal count, and (for `.currency`) the locale's
    /// symbol. `NumberFormatEngine.parse` tokenizes the whole code
    /// string and is reused across every cell that shares a format -
    /// the same reasoning the old per-decimals `NumberFormatter` cache
    /// used, one layer up.
    private struct ParsedFormatKey: Hashable {
        let numberFormat: SheetNumberFormat
        let decimals: Int
        let currencySymbol: String
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [ParsedFormatKey: NumberFormat] = [:]

    private static func parsedFormat(
        for numberFormat: SheetNumberFormat,
        decimals: Int,
        currencySymbol: String
    ) -> NumberFormat {
        let key = ParsedFormatKey(numberFormat: numberFormat, decimals: decimals, currencySymbol: currencySymbol)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[key] { return hit }
        let code = numberFormat.formatCode(decimals: decimals, currencySymbol: currencySymbol)
        let parsed = NumberFormatEngine.parse(code)
        cache[key] = parsed
        return parsed
    }
}
