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

// MARK: - Rendering

/// Turns a computed ``Value`` into the string the grid draws.
///
/// Separate from ``SheetCellFormat`` so it can hold the locale and the
/// cached `NumberFormatter`s: building a formatter per cell per redraw
/// is measurably slow on a grid of any size.
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
        case .number:
            return fixed(number, decimals: format.decimals, grouping: false, locale: locale)
        case .comma:
            return accounting(number, decimals: format.decimals, prefix: "", locale: locale)
        case .currency:
            let symbol = locale.currencySymbol ?? "$"
            return accounting(number, decimals: format.decimals, prefix: symbol, locale: locale)
        case .percent:
            let scaled = number * 100
            return fixed(scaled, decimals: format.decimals, grouping: false, locale: locale) + "%"
        case .scientific:
            return scientific(number, decimals: format.decimals)
        case .date:
            return dateString(number, locale: locale)
        }
    }

    /// Only genuine numbers are formatted. A bool is deliberately NOT
    /// coerced: TRUE rendered as "$1.00" hides what the cell holds.
    private static func numeric(_ value: Value) -> Double? {
        if case .number(let n) = value { return n }
        return nil
    }

    private static func fixed(
        _ n: Double,
        decimals: Int,
        grouping: Bool,
        locale: Locale
    ) -> String {
        let formatter = formatter(decimals: decimals, grouping: grouping, locale: locale)
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// Thousands-separated, with negatives in parentheses. The
    /// accounting convention: a minus sign is easy to miss in a column
    /// of numbers, and a misread sign is the expensive kind of error.
    ///
    /// The currency symbol is always a prefix. Correct for en_US and
    /// wrong for the locales that suffix it (fr_FR, de_DE); fixing that
    /// needs the locale's own currency pattern, not a bigger switch.
    private static func accounting(
        _ n: Double,
        decimals: Int,
        prefix: String,
        locale: Locale
    ) -> String {
        let magnitude = fixed(abs(n), decimals: decimals, grouping: true, locale: locale)
        let body = prefix + magnitude
        return n < 0 ? "(" + body + ")" : body
    }

    private static func scientific(_ n: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)E", n)
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
    private static func dateString(_ serial: Double, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var epoch = DateComponents()
        epoch.year = 1899
        epoch.month = 12
        epoch.day = 30
        guard let base = calendar.date(from: epoch) else { return String(serial) }
        let date = base.addingTimeInterval(serial * 86_400)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    // MARK: - Formatter cache

    /// Keyed by the three inputs that change a formatter's output.
    /// `NumberFormatter` is expensive to build and is reused across
    /// every cell that shares a format.
    private struct FormatterKey: Hashable {
        let decimals: Int
        let grouping: Bool
        let localeID: String
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [FormatterKey: NumberFormatter] = [:]

    private static func formatter(
        decimals: Int,
        grouping: Bool,
        locale: Locale
    ) -> NumberFormatter {
        let key = FormatterKey(
            decimals: decimals,
            grouping: grouping,
            localeID: locale.identifier
        )
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[key] { return hit }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        cache[key] = formatter
        return formatter
    }
}
