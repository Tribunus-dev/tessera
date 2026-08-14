import Foundation

// MARK: - CellValue

/// A cell's typed value - distinct from ``SheetCellFormat`` (how the
/// cell is presented) and from `tableCell.content` (the plain
/// `InlineRun` text every block already carries, kept as the
/// always-present display text). Evolves ``SheetColumnType``'s
/// vocabulary rather than replacing it: `.text`/`.number`/`.date`/
/// `.checkbox` mirror the column's four declared kinds one-for-one,
/// plus `.formula` and `.error`, which apply to a cell regardless of
/// its column's declared type.
///
/// Not the same type as the formula engine's `Value`
/// (`FormulaEngine/TypeSystem.swift`): `Value` is an ephemeral
/// evaluation result and isn't `Codable`. `CellValue` is what's
/// stored - a formula cell's `CellValue` is `.formula("=A1+B1")`, the
/// unevaluated source; evaluating it against a workbook produces a
/// `Value`. Wiring that evaluation path into the product layer is P0
/// item 0.1/0.2, not this type.
public enum CellValue: Sendable, Hashable {
    case empty
    case text(String)
    case number(Double)
    case date(Date)
    case checkbox(Bool)
    /// Raw formula source, e.g. `"=SUM(A1:A3)"`, including the leading `=`.
    case formula(String)
    /// A display string for a cell in an error state, e.g. `"#REF!"`.
    case error(String)

    public var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }
}

// MARK: - Classification

extension CellValue {
    /// Classifies raw cell text (what a user typed, or what
    /// `SheetStore.setCell` was given) into a typed value. The
    /// column's declared type is a hint for otherwise-ambiguous text,
    /// not an enforced schema - Excel disambiguates "01/02" as a date
    /// or a fraction the same way, by column/cell formatting, and
    /// still accepts "hello" typed into a number column as text.
    public static func classify(_ text: String, columnType: SheetColumnType) -> CellValue {
        guard !text.isEmpty else { return .empty }
        if SheetWorkbook.isFormula(text) { return .formula(text) }
        switch columnType {
        case .checkbox:
            if let b = parseBool(text) { return .checkbox(b) }
        case .date:
            if let d = parseDate(text) { return .date(d) }
        case .number:
            if let n = Double(text) { return .number(n) }
        case .text:
            break
        }
        // Fall back to sniffing regardless of the declared column type:
        // the type is a hint, not an enforced schema, so a .text column
        // still holds "42" as a number if that's what was typed.
        if let b = parseBool(text) { return .checkbox(b) }
        if let d = parseDate(text) { return .date(d) }
        if let n = Double(text) { return .number(n) }
        return .text(text)
    }

    private static func parseBool(_ text: String) -> Bool? {
        switch text.uppercased() {
        case "TRUE": return true
        case "FALSE": return false
        default: return nil
        }
    }

    private static func parseDate(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }
}

// MARK: - JSON bridge

extension CellValue {
    /// The attribute key a `.tableCell` block stores this under.
    /// Mirrors ``SheetCellFormat/attributeKey``'s convention.
    public static let attributeKey = "cellValue"

    private enum Kind {
        static let empty = "empty"
        static let text = "text"
        static let number = "number"
        static let date = "date"
        static let checkbox = "checkbox"
        static let formula = "formula"
        static let error = "error"
    }

    public init?(json: JSONValue) {
        guard case .object(let dict) = json, let kind = dict["kind"]?.stringValue else { return nil }
        switch kind {
        case Kind.empty:
            self = .empty
        case Kind.text:
            self = .text(dict["value"]?.stringValue ?? "")
        case Kind.number:
            self = .number(dict["value"]?.numberValue ?? 0)
        case Kind.date:
            guard let iso = dict["value"]?.stringValue,
                  let date = ISO8601DateFormatter().date(from: iso) else { return nil }
            self = .date(date)
        case Kind.checkbox:
            self = .checkbox(dict["value"]?.boolValue ?? false)
        case Kind.formula:
            self = .formula(dict["value"]?.stringValue ?? "")
        case Kind.error:
            self = .error(dict["value"]?.stringValue ?? "")
        default:
            return nil
        }
    }

    public var json: JSONValue {
        switch self {
        case .empty:
            return .object(["kind": .string(Kind.empty)])
        case .text(let s):
            return .object(["kind": .string(Kind.text), "value": .string(s)])
        case .number(let n):
            return .object(["kind": .string(Kind.number), "value": .number(n)])
        case .date(let d):
            return .object(["kind": .string(Kind.date), "value": .string(ISO8601DateFormatter().string(from: d))])
        case .checkbox(let b):
            return .object(["kind": .string(Kind.checkbox), "value": .bool(b)])
        case .formula(let s):
            return .object(["kind": .string(Kind.formula), "value": .string(s)])
        case .error(let s):
            return .object(["kind": .string(Kind.error), "value": .string(s)])
        }
    }
}
