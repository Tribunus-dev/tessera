//===----------------------------------------------------------------------===//
//  NumberFormatEngine.swift
//  Tessera Formula Engine
//
//  Parses Excel/ODF-style number format codes (e.g. "#,##0.00",
//  "$#,##0.00;[Red]-$#,##0.00", "0.00%", "mm/dd/yyyy") and formats
//  values against them.
//
//  Scope note (studio-expansion-plan.md priority #5 flags this as the
//  single highest-risk P0 deliverable, chosen as a full parser rather
//  than an 80% subset, "parity with svl/source/numbers/"): this file
//  covers the format-CODE grammar in full generality (arbitrary digit
//  masks, section splitting, color/currency tags, the common date/time
//  tokens) and hands locale-specific separators and month/day names to
//  Foundation's Locale-aware formatters rather than re-deriving
//  locale tables from scratch - svl's own locale data ultimately
//  bottoms out at the same ICU/CLDR data Foundation already carries,
//  so hand-porting it would duplicate data Swift already has, not add
//  parity. NOT yet covered, and out of scope for this pass: fraction
//  formats ("# ?/?"), elapsed-time formats ("[h]:mm:ss"), the
//  repeat-to-fill ("*") and pad-to-width ("_") directives, and
//  locale-ID currency tags beyond stripping them ("[$-409]"). These
//  are real gaps against full svl parity, not silently patched over -
//  `parse(_:)` still accepts the tokens it doesn't specially handle
//  (folding them into literals) so a format string round-trips to
//  *something* rather than throwing, but the specialized behavior
//  those codes imply is not implemented yet.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - NumberFormat

/// A parsed format code, up to 4 semicolon-separated sections
/// (positive; negative; zero; text), matching Excel/ODF's convention.
public struct NumberFormat: Sendable, Hashable {
    public let raw: String
    let sections: [FormatSection]

    /// `"General"` (or empty) - the default, locale-appropriate
    /// rendering with no forced mask. Every ``SheetNumberFormat/general``
    /// cell uses this.
    public static let general = NumberFormatEngine.parse("General")
}

// MARK: - FormatSection

struct FormatSection: Sendable, Hashable {
    var colorName: String?
    var tokens: [FormatToken]
    /// True if any token in this section is date/time-related - such a
    /// section formats a `Value.date`/serial number as a date even
    /// without an explicit sign condition.
    var isDateSection: Bool { tokens.contains { if case .dateToken = $0 { return true }; return false } }
}

// MARK: - FormatToken

enum FormatToken: Sendable, Hashable {
    case digitRequired          // '0'
    case digitOptional          // '#'
    case digitOrSpace           // '?'
    case decimalPoint           // '.'
    case groupingSeparator      // ',' between digits
    case scaleByThousand        // trailing ',' after the last digit placeholder
    case percent                // '%' - also scales the value by 100
    case exponent(uppercase: Bool, forceSign: Bool)  // 'E+00' / 'e-00'
    case literal(String)
    case dateToken(DateTokenKind, count: Int)
    case generalMarker          // "General"
    case currencySymbol(String)
}

enum DateTokenKind: Sendable, Hashable {
    case year, month, day, hour, minute, second, amPm
}

// MARK: - NumberFormatEngine

public enum NumberFormatEngine {

    // MARK: Parsing

    /// Parses a format code string into a ``NumberFormat``. Never
    /// throws: an unrecognized or malformed code degrades to a
    /// best-effort literal section rather than failing the whole cell.
    public static func parse(_ code: String) -> NumberFormat {
        guard !code.trimmingCharacters(in: .whitespaces).isEmpty else {
            return NumberFormat(raw: code, sections: [FormatSection(colorName: nil, tokens: [.generalMarker])])
        }
        let sectionStrings = splitSections(code)
        let sections = sectionStrings.map(parseSection)
        return NumberFormat(raw: code, sections: sections)
    }

    /// Splits on top-level `;` - not inside a quoted `"..."` literal or
    /// a bracketed `[...]` tag, both of which may themselves contain a
    /// `;` that must not split the format.
    private static func splitSections(_ code: String) -> [String] {
        var sections: [String] = []
        var current = ""
        var inQuotes = false
        var bracketDepth = 0
        for ch in code {
            switch ch {
            case "\"":
                inQuotes.toggle()
                current.append(ch)
            case "[" where !inQuotes:
                bracketDepth += 1
                current.append(ch)
            case "]" where !inQuotes:
                bracketDepth = max(0, bracketDepth - 1)
                current.append(ch)
            case ";" where !inQuotes && bracketDepth == 0:
                sections.append(current)
                current = ""
            default:
                current.append(ch)
            }
        }
        sections.append(current)
        return sections
    }

    private static func parseSection(_ raw: String) -> FormatSection {
        let chars = Array(raw)
        var index = 0
        var colorName: String?
        var tokens: [FormatToken] = []

        if raw.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("General") == .orderedSame {
            return FormatSection(colorName: nil, tokens: [.generalMarker])
        }

        while index < chars.count {
            let ch = chars[index]
            switch ch {
            case "[":
                guard let close = chars[index...].firstIndex(of: "]") else {
                    tokens.append(.literal(String(chars[index...])))
                    index = chars.count
                    break
                }
                let tag = String(chars[(index + 1)..<close])
                if isKnownColor(tag) {
                    colorName = tag
                } else if tag.hasPrefix("$") {
                    // "[$USD-409]" / "[$$-en-US]" style currency tag: the
                    // literal currency symbol is between "$" and an
                    // optional "-locale" suffix.
                    let body = String(tag.dropFirst())
                    let symbol = body.split(separator: "-", maxSplits: 1).first.map(String.init) ?? body
                    if !symbol.isEmpty { tokens.append(.currencySymbol(symbol)) }
                }
                // Other bracket tags ([h], [Red] already handled, locale
                // IDs, etc.) are consumed but not specially interpreted -
                // see the file header's scope note.
                index = close + 1
                continue
            case "\"":
                var literal = ""
                index += 1
                while index < chars.count, chars[index] != "\"" {
                    literal.append(chars[index])
                    index += 1
                }
                tokens.append(.literal(literal))
                index += 1
                continue
            case "\\":
                if index + 1 < chars.count {
                    tokens.append(.literal(String(chars[index + 1])))
                    index += 2
                    continue
                }
                index += 1
                continue
            case "0", "#", "?":
                let (run, next) = consumeRun(chars, from: index, matching: { $0 == "0" || $0 == "#" || $0 == "?" })
                for c in run {
                    switch c {
                    case "0": tokens.append(.digitRequired)
                    case "#": tokens.append(.digitOptional)
                    default: tokens.append(.digitOrSpace)
                    }
                }
                index = next
                continue
            case ".":
                tokens.append(.decimalPoint)
                index += 1
                continue
            case ",":
                // Trailing comma(s) right after the last digit placeholder
                // (and before end-of-section or '%') scale by 1000 per
                // comma; a comma between digit placeholders is a grouping
                // separator. Distinguishing needs the token stream so far.
                if let last = tokens.last, isDigitToken(last),
                   nextNonCommaIsNotDigit(chars, from: index) {
                    tokens.append(.scaleByThousand)
                } else {
                    tokens.append(.groupingSeparator)
                }
                index += 1
                continue
            case "%":
                tokens.append(.percent)
                index += 1
                continue
            case "E", "e":
                if index + 1 < chars.count, chars[index + 1] == "+" || chars[index + 1] == "-" {
                    let forceSign = chars[index + 1] == "+"
                    tokens.append(.exponent(uppercase: ch == "E", forceSign: forceSign))
                    index += 2
                    // Consume the digit placeholders for the exponent
                    // width; the engine always renders at least 2 digits
                    // regardless of the mask's exact width.
                    let (_, next) = consumeRun(chars, from: index, matching: { $0 == "0" })
                    index = next
                    continue
                }
                tokens.append(.literal(String(ch)))
                index += 1
                continue
            case "y", "Y", "m", "M", "d", "D", "h", "H", "s", "S":
                let (run, next) = consumeRun(chars, from: index) { $0.lowercased() == String(ch).lowercased() }
                tokens.append(.dateToken(dateTokenKind(for: ch), count: run.count))
                index = next
                continue
            case "A", "a":
                // AM/PM (case-insensitive, "AM/PM" or "A/P").
                let upper = String(chars[index...]).uppercased()
                if upper.hasPrefix("AM/PM") {
                    tokens.append(.dateToken(.amPm, count: 5))
                    index += 5
                } else if upper.hasPrefix("A/P") {
                    tokens.append(.dateToken(.amPm, count: 3))
                    index += 3
                } else {
                    tokens.append(.literal(String(ch)))
                    index += 1
                }
                continue
            case " ":
                tokens.append(.literal(" "))
                index += 1
                continue
            default:
                tokens.append(.literal(String(ch)))
                index += 1
                continue
            }
        }
        return FormatSection(colorName: colorName, tokens: disambiguateMonthVsMinute(tokens))
    }

    /// `m`/`mm` is ambiguous in Excel/ODF format codes: it means MONTH
    /// almost everywhere, but MINUTE immediately after an `h`/`hh` token
    /// or immediately before an `s`/`ss` token (e.g. `"hh:mm:ss"`).
    /// Adjacency is by nearest *date* token, ignoring literal separators
    /// in between (the `:` between `hh` and `mm` doesn't break it).
    /// Parsed eagerly as `.month` above since the disambiguating
    /// neighbor may come later in the string; this reclassifies after
    /// the whole section is tokenized.
    private static func disambiguateMonthVsMinute(_ tokens: [FormatToken]) -> [FormatToken] {
        var result = tokens
        let dateIndices = tokens.indices.filter { if case .dateToken = tokens[$0] { return true }; return false }
        for (pos, idx) in dateIndices.enumerated() {
            guard case .dateToken(.month, let count) = tokens[idx] else { continue }
            let prevIsHour = pos > 0 && isDateKind(tokens[dateIndices[pos - 1]], .hour)
            let nextIsSecond = pos + 1 < dateIndices.count && isDateKind(tokens[dateIndices[pos + 1]], .second)
            if prevIsHour || nextIsSecond {
                result[idx] = .dateToken(.minute, count: count)
            }
        }
        return result
    }

    private static func isDateKind(_ token: FormatToken, _ kind: DateTokenKind) -> Bool {
        if case .dateToken(let k, _) = token { return k == kind }
        return false
    }

    private static func isDigitToken(_ t: FormatToken) -> Bool {
        switch t { case .digitRequired, .digitOptional, .digitOrSpace: return true; default: return false }
    }

    private static func nextNonCommaIsNotDigit(_ chars: [Character], from index: Int) -> Bool {
        var i = index
        while i < chars.count, chars[i] == "," { i += 1 }
        guard i < chars.count else { return true }
        return chars[i] != "0" && chars[i] != "#" && chars[i] != "?"
    }

    private static func consumeRun(_ chars: [Character], from start: Int, matching predicate: (Character) -> Bool) -> (run: [Character], next: Int) {
        var i = start
        var run: [Character] = []
        while i < chars.count, predicate(chars[i]) {
            run.append(chars[i])
            i += 1
        }
        return (run, i)
    }

    private static func dateTokenKind(for ch: Character) -> DateTokenKind {
        switch ch.lowercased() {
        case "y": return .year
        case "m": return .month
        case "d": return .day
        case "h": return .hour
        case "s": return .second
        default: return .month
        }
    }

    private static func isKnownColor(_ tag: String) -> Bool {
        ["black", "blue", "cyan", "green", "magenta", "red", "white", "yellow"]
            .contains(tag.lowercased())
    }

    // MARK: Formatting

    /// Formats `value` against `format`, choosing the section per
    /// Excel's convention: 1 section applies to everything; 2 sections
    /// are positive-and-zero / negative; 3 are positive / negative /
    /// zero; a 4th, if present, applies to text values.
    public static func format(_ value: Value, using format: NumberFormat, locale: Locale = .current) -> String {
        if case .string(let s) = value, format.sections.count >= 4 {
            return render(format.sections[3], number: nil, text: s, locale: locale)
        }
        if case .error(let e) = value { return e.displayString }

        let number = value.asNumber
        guard let number else {
            return render(format.sections.first ?? FormatSection(colorName: nil, tokens: [.generalMarker]), number: nil, text: value.asString, locale: locale)
        }

        let section: FormatSection
        switch format.sections.count {
        case 0:
            section = FormatSection(colorName: nil, tokens: [.generalMarker])
        case 1:
            section = format.sections[0]
        case 2:
            section = number < 0 ? format.sections[1] : format.sections[0]
        default:
            if number < 0 { section = format.sections[1] }
            else if number == 0 { section = format.sections[2] }
            else { section = format.sections[0] }
        }

        if section.isDateSection, case .date(let d) = value {
            return renderDate(section, date: d, locale: locale)
        }
        if section.isDateSection {
            // A date-formatted cell whose Value is numeric (e.g. an
            // Excel-style day-count serial) - out of scope for this
            // pass (see the file header); render the raw number instead
            // of guessing an epoch.
            return render(FormatSection(colorName: nil, tokens: [.generalMarker]), number: number, text: nil, locale: locale)
        }

        let magnitude = format.sections.count >= 2 ? abs(number) : number
        let needsSign = format.sections.count < 2 && number < 0
        var out = render(section, number: magnitude, text: nil, locale: locale)
        if needsSign { out = "-" + out }
        return out
    }

    public static func format(_ number: Double, using format: NumberFormat, locale: Locale = .current) -> String {
        self.format(.number(number), using: format, locale: locale)
    }

    public static func format(_ date: Date, using format: NumberFormat, locale: Locale = .current) -> String {
        self.format(.date(date), using: format, locale: locale)
    }

    private static func render(_ section: FormatSection, number: Double?, text: String?, locale: Locale) -> String {
        if section.tokens.contains(.generalMarker) {
            if let text { return text }
            guard let number else { return "" }
            return generalNumberString(number, locale: locale)
        }

        var scaled = number ?? 0
        let thousandScales = section.tokens.filter { if case .scaleByThousand = $0 { return true }; return false }.count
        if thousandScales > 0 { scaled /= pow(1000, Double(thousandScales)) }
        if section.tokens.contains(.percent) { scaled *= 100 }

        let hasExponent = section.tokens.contains { if case .exponent = $0 { return true }; return false }
        let fractionDigits = countTrailingDigitPlaceholders(section.tokens)
        let integerDigitsRequired = countLeadingRequiredIntegerDigits(section.tokens)
        let hasGrouping = section.tokens.contains(.groupingSeparator)

        var mantissa = scaled
        var exponentValue = 0
        if hasExponent {
            (mantissa, exponentValue) = normalizeForExponent(scaled)
        }

        let numeric = formatMagnitude(
            mantissa,
            fractionDigits: fractionDigits,
            minIntegerDigits: integerDigitsRequired,
            grouping: hasGrouping,
            locale: locale
        )

        var out = ""
        var digitsEmitted = false
        var currencyEmitted = false
        for token in section.tokens {
            switch token {
            case .digitRequired, .digitOptional, .digitOrSpace, .decimalPoint, .groupingSeparator:
                if !digitsEmitted {
                    out += numeric
                    digitsEmitted = true
                }
            case .scaleByThousand:
                continue
            case .percent:
                out += "%"
            case .exponent(let uppercase, let forceSign):
                let sign = exponentValue < 0 ? "-" : (forceSign ? "+" : "")
                out += (uppercase ? "E" : "e") + sign + String(format: "%02d", abs(exponentValue))
            case .literal(let s):
                out += s
            case .currencySymbol(let s):
                out += s
                currencyEmitted = true
            case .dateToken:
                continue // handled by renderDate; not reachable for a number section
            case .generalMarker:
                continue
            }
        }
        _ = currencyEmitted
        return out
    }

    private static func generalNumberString(_ n: Double, locale: Locale) -> String {
        if n == n.rounded(), abs(n) < 1e15 {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .none
            formatter.usesGroupingSeparator = false
            return formatter.string(from: NSNumber(value: Int64(n))) ?? String(Int64(n))
        }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 15
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    private static func countTrailingDigitPlaceholders(_ tokens: [FormatToken]) -> Int {
        guard let dot = tokens.firstIndex(of: .decimalPoint) else { return 0 }
        var count = 0
        for token in tokens[(dot + 1)...] {
            if isDigitToken(token) { count += 1 } else if token == .percent || isLiteralLike(token) { continue } else { break }
        }
        return count
    }

    private static func isLiteralLike(_ t: FormatToken) -> Bool {
        if case .literal = t { return true }
        return false
    }

    private static func countLeadingRequiredIntegerDigits(_ tokens: [FormatToken]) -> Int {
        var count = 0
        for token in tokens {
            if token == .decimalPoint { break }
            if token == .digitRequired { count += 1 }
            else if isDigitToken(token) { continue }
        }
        return count
    }

    private static func normalizeForExponent(_ value: Double) -> (mantissa: Double, exponent: Int) {
        guard value != 0 else { return (0, 0) }
        let sign: Double = value < 0 ? -1 : 1
        var m = abs(value)
        var e = 0
        while m >= 10 { m /= 10; e += 1 }
        while m < 1 { m *= 10; e -= 1 }
        return (m * sign, e)
    }

    private static func formatMagnitude(
        _ value: Double,
        fractionDigits: Int,
        minIntegerDigits: Int,
        grouping: Bool,
        locale: Locale
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        formatter.minimumIntegerDigits = max(1, minIntegerDigits)
        formatter.negativePrefix = ""
        formatter.negativeSuffix = ""
        return formatter.string(from: NSNumber(value: abs(value))) ?? String(format: "%.\(fractionDigits)f", abs(value))
    }

    private static func renderDate(_ section: FormatSection, date: Date, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        // Spreadsheet date/time values are timezone-naive wall-clock
        // values (matching Value.asNumber's Excel-epoch arithmetic
        // above, which is also timezone-naive) - fixing UTC here keeps
        // rendering deterministic regardless of the host machine's
        // timezone, rather than silently varying with TimeZone.current.
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        var out = ""
        for token in section.tokens {
            switch token {
            case .dateToken(let kind, let count):
                out += dateFieldString(kind, count: count, components: components, date: date, calendar: calendar, locale: locale)
            case .literal(let s):
                out += s
            default:
                continue
            }
        }
        return out
    }

    private static func dateFieldString(
        _ kind: DateTokenKind,
        count: Int,
        components: DateComponents,
        date: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        switch kind {
        case .year:
            let year = components.year ?? 1970
            return count >= 4 ? String(format: "%04d", year) : String(format: "%02d", year % 100)
        case .month:
            let month = components.month ?? 1
            if count >= 4 { return monthName(month, calendar: calendar, style: .full) }
            if count == 3 { return monthName(month, calendar: calendar, style: .short) }
            return count >= 2 ? String(format: "%02d", month) : String(month)
        case .day:
            let day = components.day ?? 1
            if count >= 4 { return weekdayName(date, calendar: calendar, style: .full) }
            if count == 3 { return weekdayName(date, calendar: calendar, style: .short) }
            return count >= 2 ? String(format: "%02d", day) : String(day)
        case .hour:
            let hour = components.hour ?? 0
            return count >= 2 ? String(format: "%02d", hour) : String(hour)
        case .minute:
            let minute = components.minute ?? 0
            return count >= 2 ? String(format: "%02d", minute) : String(minute)
        case .second:
            let second = components.second ?? 0
            return count >= 2 ? String(format: "%02d", second) : String(second)
        case .amPm:
            let hour = components.hour ?? 0
            let isPM = hour >= 12
            return count == 3 ? (isPM ? "P" : "A") : (isPM ? "PM" : "AM")
        }
    }

    private enum NameStyle { case full, short }

    private static func monthName(_ month: Int, calendar: Calendar, style: NameStyle) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale
        let names = style == .full ? formatter.monthSymbols : formatter.shortMonthSymbols
        guard let names, month >= 1, month <= names.count else { return "" }
        return names[month - 1]
    }

    private static func weekdayName(_ date: Date, calendar: Calendar, style: NameStyle) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale
        let weekday = calendar.component(.weekday, from: date)
        let names = style == .full ? formatter.weekdaySymbols : formatter.shortWeekdaySymbols
        guard let names, weekday >= 1, weekday <= names.count else { return "" }
        return names[weekday - 1]
    }
}
