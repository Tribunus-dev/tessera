//===----------------------------------------------------------------------===//
//  FormulaReferenceAdjuster.swift
//  Tessera Formula Engine
//
//  Rewrites the references inside a formula when rows or columns are
//  inserted or deleted.
//
//  Without this, inserting a row above `=SUM(A1:A5)` leaves it summing
//  the wrong five cells - silently, with a plausible number. Structural
//  edits already rewrote the grid; this makes the formulas follow.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Structural edits

/// A row/column insertion or deletion, in 0-based grid coordinates - or a
/// sheet rename, which touches the sheet-qualifier prefix instead of the
/// row/column part of a reference.
public enum StructuralEdit: Sendable, Equatable {
    case insertRows(at: Int, count: Int)
    case deleteRows(at: Int, count: Int)
    case insertColumns(at: Int, count: Int)
    case deleteColumns(at: Int, count: Int)
    /// `from`/`to` are the UNESCAPED sheet names (no quotes, no `!`) -
    /// the same form `AddressParser.unescapeSheetName` produces and
    /// `escapeSheetName` consumes.
    case renameSheet(from: String, to: String)
    /// `name` is the UNESCAPED sheet name being removed. Any reference
    /// that qualifies with it becomes `#REF!`, the same way a reference
    /// into a deleted row or column does.
    case deleteSheet(name: String)
}

// MARK: - Adjuster

/// Rewrites A1-style references for a structural edit.
///
/// **Why textual and not AST-based.** Re-printing an AST would reformat
/// the user's formula - `1` becomes `1.0`, spacing and parentheses move.
/// A formula is text the user wrote and expects back; only the reference
/// tokens change, and everything between them is copied verbatim.
///
/// **The rules** (observable in any spreadsheet, and the reason each
/// exists):
///
/// * `$` marks a reference absolute for COPYING, not for structural
///   edits. Inserting a row above `$A$5` still makes it `$A$6` - the
///   cell moved, so the reference must move with it.
/// * A reference before the edit point is untouched.
/// * A range that SPANS the insertion point grows: insert at row 3 and
///   `A1:A5` becomes `A1:A6`, because the new row is inside the span.
/// * Deleting the cells a reference points at yields `#REF!`, and it
///   stays `#REF!`. Silently narrowing the range instead would leave a
///   formula that still computes, just over the wrong data.
public enum FormulaReferenceAdjuster {

    /// Excel's grid limits. Used to reject identifiers that merely look
    /// like references: `Sales2024` is a name, not column `SALES` row
    /// 2024, and 5 letters exceed the widest real column (`XFD`).
    static let maxColumnLetters = 3
    static let maxRow = 1_048_576

    /// Rewrite every reference in `source` for `edit`.
    public static func adjust(_ source: String, for edit: StructuralEdit) -> String {
        let chars = Array(source)
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

            if let match = matchReference(chars, from: i) {
                // A range must be adjusted as a UNIT. Treating the two
                // endpoints independently gets deletion wrong: removing
                // rows 1-2 from `A1:A5` would yield `#REF!:A3` instead
                // of clamping to the surviving `A1:A3`.
                if match.end < chars.count, chars[match.end] == ":",
                   let second = matchReference(chars, from: match.end + 1, allowMidIdentifier: true) {
                    out.append(adjustedRange(match, second, for: edit))
                    i = second.end
                    continue
                }
                out.append(adjusted(match, for: edit))
                i = match.end
                continue
            }

            out.append(ch)
            i += 1
        }
        return out
    }

    // MARK: Matching

    /// One A1-style reference found in the source text.
    struct ReferenceMatch {
        var sheetPrefix: String   // "Sheet1!" or "" - copied through
        var colAbsolute: Bool
        var column: Int           // 0-based
        var rowAbsolute: Bool
        var row: Int              // 0-based
        var end: Int              // index just past the match
    }

    /// Match `[Sheet!]$?COL$?ROW` starting at `start`, or nil.
    ///
    /// `allowMidIdentifier` is set for the right-hand side of a range,
    /// where the preceding character is the `:` we just consumed.
    static func matchReference(
        _ chars: [Character],
        from start: Int,
        allowMidIdentifier: Bool = false
    ) -> ReferenceMatch? {
        // A reference cannot begin mid-identifier: `B` in `TAB1` is not a
        // column.
        if start > 0, !allowMidIdentifier {
            let prev = chars[start - 1]
            if prev.isLetter || prev.isNumber || prev == "_" || prev == "$" || prev == "!" {
                return nil
            }
        }

        var i = start
        var sheetPrefix = ""

        // Optional sheet qualifier, quoted or bare, ending in "!".
        if let (prefix, next) = matchSheetPrefix(chars, from: i) {
            sheetPrefix = prefix
            i = next
        }

        var colAbsolute = false
        if i < chars.count, chars[i] == "$" {
            colAbsolute = true
            i += 1
        }

        var letters = ""
        while i < chars.count, chars[i].isLetter {
            letters.append(chars[i])
            i += 1
        }
        guard !letters.isEmpty, letters.count <= maxColumnLetters else { return nil }

        var rowAbsolute = false
        if i < chars.count, chars[i] == "$" {
            rowAbsolute = true
            i += 1
        }

        var digits = ""
        while i < chars.count, chars[i].isNumber {
            digits.append(chars[i])
            i += 1
        }
        guard !digits.isEmpty, let rowNumber = Int(digits), rowNumber >= 1, rowNumber <= maxRow else {
            return nil
        }

        // A trailing identifier char means this was a name, not a
        // reference. A trailing "(" means it was a function: `LOG10(`
        // scans as column LOG row 10 right up until the paren.
        if i < chars.count {
            let next = chars[i]
            if next.isLetter || next.isNumber || next == "_" || next == "(" { return nil }
        }

        guard let column = CellAddr.colNumber(for: letters.uppercased()) else { return nil }

        return ReferenceMatch(
            sheetPrefix: sheetPrefix,
            colAbsolute: colAbsolute,
            column: column,
            rowAbsolute: rowAbsolute,
            row: rowNumber - 1,
            end: i
        )
    }

    /// Match `Name!` or `'Some Name'!`, returning the text and the index
    /// after it.
    static func matchSheetPrefix(_ chars: [Character], from start: Int) -> (String, Int)? {
        var i = start
        var text = ""

        if i < chars.count, chars[i] == "'" {
            text.append(chars[i])
            i += 1
            while i < chars.count, chars[i] != "'" {
                text.append(chars[i])
                i += 1
            }
            guard i < chars.count else { return nil }
            text.append(chars[i]) // closing quote
            i += 1
        } else {
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                text.append(chars[i])
                i += 1
            }
            guard !text.isEmpty else { return nil }
        }

        guard i < chars.count, chars[i] == "!" else { return nil }
        text.append("!")
        return (text, i + 1)
    }

    // MARK: Adjusting

    /// The replacement text for one matched reference.
    static func adjusted(_ match: ReferenceMatch, for edit: StructuralEdit) -> String {
        switch edit {
        case .insertRows(let at, let count):
            guard match.row >= at else { return render(match) }
            return render(match, row: match.row + count)

        case .insertColumns(let at, let count):
            guard match.column >= at else { return render(match) }
            return render(match, column: match.column + count)

        case .deleteRows(let at, let count):
            if match.row < at { return render(match) }
            // The referenced row itself was removed.
            if match.row < at + count { return "#REF!" }
            return render(match, row: match.row - count)

        case .deleteColumns(let at, let count):
            if match.column < at { return render(match) }
            if match.column < at + count { return "#REF!" }
            return render(match, column: match.column - count)

        case .renameSheet(let from, let to):
            var renamed = match
            renamed.sheetPrefix = renamedPrefix(match.sheetPrefix, from: from, to: to)
            return render(renamed)

        case .deleteSheet(let name):
            return referencesDeletedSheet(match.sheetPrefix, name) ? "#REF!" : render(match)
        }
    }

    /// Whether a captured `sheetPrefix` names the sheet being deleted.
    /// An empty prefix (unqualified - "same sheet as this formula")
    /// never does: deleting some OTHER sheet must never turn a
    /// same-sheet reference into an error.
    static func referencesDeletedSheet(_ prefix: String, _ name: String) -> Bool {
        !prefix.isEmpty && unescapeSheetPrefix(prefix) == name
    }

    /// Rewrite a captured `sheetPrefix` ("" | `Name!` | `'Some Name'!`)
    /// when it names `from`, to the equivalent prefix naming `to`.
    ///
    /// An EMPTY prefix (an unqualified reference) is left empty: renaming
    /// some other sheet must never turn "same sheet as this formula"
    /// into a reference that now points somewhere else because it
    /// happened to share a sheet name with the one just renamed.
    static func renamedPrefix(_ prefix: String, from: String, to: String) -> String {
        guard !prefix.isEmpty else { return prefix }
        let name = unescapeSheetPrefix(prefix)
        guard name == from else { return prefix }
        // ALWAYS quoted, not AddressParser.escapeSheetName's
        // only-when-it-contains-a-special-character rule: this engine's
        // own Lexer (scanIdentifier) never looks ahead for "!" after a
        // bare identifier, so an unquoted sheet-qualified reference does
        // not parse at all - "=Sheet1!A1*2" silently becomes a named-
        // range lookup that drops "!A1*2" outright, and the same
        // reference inside a function call throws. escapeSheetName's
        // narrower rule is correct for whatever it was written for, but
        // wrong here: every renamed reference this produces gets fed
        // back into setFormulaUnlocked, which needs it to actually
        // reparse.
        let escaped = to.replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'!"
    }

    /// Strip the trailing `!` and any wrapping quotes a matched sheet
    /// prefix carries, mirroring `AddressParser.unescapeSheetName` (that
    /// one operates on the parsed `CellRef`, not this scanner's raw
    /// capture, so the two can't share code directly).
    static func unescapeSheetPrefix(_ prefix: String) -> String {
        var s = prefix
        guard s.hasSuffix("!") else { return s }
        s.removeLast()
        if s.hasPrefix("'") && s.hasSuffix("'") && s.count >= 2 {
            s = String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return s
    }

    /// The replacement text for a `start:end` range.
    ///
    /// A range survives a deletion that only partially covers it: the
    /// surviving rows/columns clamp down. It becomes `#REF!` only when
    /// the deletion removes the range entirely - a formula over "what's
    /// left of" a range the user deleted is worse than an error, because
    /// it keeps computing.
    static func adjustedRange(
        _ start: ReferenceMatch,
        _ end: ReferenceMatch,
        for edit: StructuralEdit
    ) -> String {
        switch edit {
        case .insertRows(let at, let count):
            let (top, bottom) = (Swift.min(start.row, end.row), Swift.max(start.row, end.row))
            if bottom < at { return "\(render(start)):\(render(end))" }
            if top >= at {
                return "\(render(start, row: start.row + count)):\(render(end, row: end.row + count))"
            }
            // The insertion lands inside the span, so the range grows.
            return "\(render(start)):\(render(end, row: end.row + count))"

        case .insertColumns(let at, let count):
            let (left, right) = (Swift.min(start.column, end.column), Swift.max(start.column, end.column))
            if right < at { return "\(render(start)):\(render(end))" }
            if left >= at {
                return "\(render(start, column: start.column + count)):\(render(end, column: end.column + count))"
            }
            return "\(render(start)):\(render(end, column: end.column + count))"

        case .deleteRows(let at, let count):
            guard let (newTop, newBottom) = clamp(
                low: Swift.min(start.row, end.row),
                high: Swift.max(start.row, end.row),
                deletedAt: at, count: count
            ) else { return "#REF!" }
            return "\(render(start, row: newTop)):\(render(end, row: newBottom))"

        case .deleteColumns(let at, let count):
            guard let (newLeft, newRight) = clamp(
                low: Swift.min(start.column, end.column),
                high: Swift.max(start.column, end.column),
                deletedAt: at, count: count
            ) else { return "#REF!" }
            return "\(render(start, column: newLeft)):\(render(end, column: newRight))"

        case .renameSheet(let from, let to):
            // Only `start` normally carries a sheet prefix ("Sheet2!A1:B5"
            // has no prefix on B5), but rewrite both sides independently
            // in case a formula wrote one out explicitly.
            var newStart = start
            newStart.sheetPrefix = renamedPrefix(start.sheetPrefix, from: from, to: to)
            var newEnd = end
            newEnd.sheetPrefix = renamedPrefix(end.sheetPrefix, from: from, to: to)
            return "\(render(newStart)):\(render(newEnd))"

        case .deleteSheet(let name):
            // Same asymmetry as renameSheet above: check both sides
            // independently even though only `start` normally carries
            // the prefix in practice.
            if referencesDeletedSheet(start.sheetPrefix, name) || referencesDeletedSheet(end.sheetPrefix, name) {
                return "#REF!"
            }
            return "\(render(start)):\(render(end))"
        }
    }

    /// New bounds for a span after a deletion, or nil when the deletion
    /// swallowed it whole.
    static func clamp(low: Int, high: Int, deletedAt at: Int, count: Int) -> (Int, Int)? {
        let last = at + count - 1
        if high < at { return (low, high) }              // entirely before
        if low > last { return (low - count, high - count) } // entirely after
        if low >= at && high <= last { return nil }      // entirely removed

        let overlap = Swift.min(high, last) - Swift.max(low, at) + 1
        let newLow = low < at ? low : at
        let newHigh = high - overlap
        return newHigh < newLow ? nil : (newLow, newHigh)
    }

    /// Re-emit a reference, preserving its `$` markers and sheet prefix.
    static func render(_ match: ReferenceMatch, column: Int? = nil, row: Int? = nil) -> String {
        let col = column ?? match.column
        let rw = row ?? match.row
        var out = match.sheetPrefix
        if match.colAbsolute { out += "$" }
        out += CellAddr.colLetter(for: col)
        if match.rowAbsolute { out += "$" }
        out += String(rw + 1)
        return out
    }
}
