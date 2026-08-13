//===----------------------------------------------------------------------===//
//  SheetWorkbook.swift
//  Tessera Studio
//
//  The calculation layer between the Sheets surface and the formula
//  engine. Until this existed the two had no connection: the grid was a
//  document-backed table of literal text, and `SheetEngine` - the
//  dependency graph, recalculation and function library - was reachable
//  only from its own tests.
//===----------------------------------------------------------------------===//

import Foundation

/// Calculation state for one open sheet.
///
/// **What is stored versus what is shown.** The `Sheet` document keeps
/// each cell's SOURCE text - `=SUM(B1:B4)`, not `10`. That leaves the
/// storage format, the receipt chain and the recovery files exactly as
/// they were, and it is the only representation that survives a round
/// trip: a saved computed value would silently become a literal.
/// Displayed values are computed here and never persisted.
///
/// Recalculation therefore changes what the grid shows without changing
/// what is on disk, which is why an edit persists one cell but can
/// refresh many.
@MainActor
public final class SheetWorkbook: ObservableObject {

    /// The live engine. Replaced wholesale on `hydrate`, since loading a
    /// different sheet means a different workbook.
    public private(set) var engine: SheetEngine

    /// Bumped whenever displayed values may have changed, so a SwiftUI
    /// grid observing this object redraws. Recalculation can touch cells
    /// far from the edit, so the grid cannot key off the edited cell.
    @Published public private(set) var revision: Int = 0

    /// The sheet currently loaded, if any.
    public private(set) var sheetID: UUID?

    public init(engine: SheetEngine = SheetEngine()) {
        self.engine = engine
    }

    // MARK: - Loading

    /// Rebuild calculation state from a sheet's stored text.
    ///
    /// Two passes on purpose: every literal is placed before any formula
    /// runs, so a formula that references a cell below or to the right of
    /// it still sees a value. A single pass would evaluate such a formula
    /// against blanks and cache the wrong result until something forced a
    /// recalculation.
    public func hydrate(from sheet: Sheet) {
        let fresh = SheetEngine()
        var formulas: [(CellAddr, String)] = []

        for row in 0..<sheet.rowCount {
            for col in 0..<sheet.columnCount {
                let text = sheet.cellText(row: row, col: col)
                guard !text.isEmpty else { continue }
                let addr = CellAddr(col: col, row: row)
                if Self.isFormula(text) {
                    formulas.append((addr, text))
                } else {
                    fresh.setValue(sheet: nil, addr: addr, value: Self.literal(text))
                }
            }
        }

        for (addr, source) in formulas {
            do {
                _ = try fresh.setFormula(sheet: nil, addr: addr, source: source)
            } catch {
                // A stored formula that no longer parses (or is circular)
                // shows as #REF! rather than vanishing - a blank cell
                // would look like data loss.
                fresh.setValue(sheet: nil, addr: addr, value: .error(.referenceInvalid))
            }
        }

        engine = fresh
        sheetID = sheet.id
        revision &+= 1
    }

    /// Drop calculation state. Called when the surface closes so the
    /// agent's sheet tools stop reporting a workbook that is not open.
    public func unload() {
        engine = SheetEngine()
        sheetID = nil
        revision &+= 1
    }

    // MARK: - Editing

    /// Apply a user edit. Returns false when a formula was rejected
    /// (a parse failure or a circular reference), in which case the cell
    /// shows `#REF!`.
    ///
    /// The caller still persists the SOURCE text either way: a formula
    /// the engine rejects is the user's text and must not be silently
    /// discarded from the document.
    @discardableResult
    public func apply(text: String, row: Int, col: Int) -> Bool {
        let addr = CellAddr(col: col, row: row)
        defer { revision &+= 1 }

        guard Self.isFormula(text) else {
            engine.setValue(sheet: nil, addr: addr, value: Self.literal(text))
            return true
        }
        do {
            _ = try engine.setFormula(sheet: nil, addr: addr, source: text)
            return true
        } catch {
            engine.setValue(sheet: nil, addr: addr, value: .error(.referenceInvalid))
            return false
        }
    }

    // MARK: - Reading

    /// What the grid shows: the computed value.
    public func displayText(row: Int, col: Int) -> String {
        engine.getValue(sheet: nil, addr: CellAddr(col: col, row: row)).asString
    }

    /// The computed value itself, for callers that need the type.
    public func value(row: Int, col: Int) -> Value {
        engine.getValue(sheet: nil, addr: CellAddr(col: col, row: row))
    }

    /// True when the cell holds a formula rather than a literal.
    public func hasFormula(row: Int, col: Int) -> Bool {
        engine.hasFormula(sheet: nil, addr: CellAddr(col: col, row: row))
    }

    // MARK: - Text conversion

    /// A leading `=` marks a formula, as in every spreadsheet. A bare
    /// `=` is just text.
    public nonisolated static func isFormula(_ text: String) -> Bool {
        text.count > 1 && text.hasPrefix("=")
    }

    /// Type a literal the way a spreadsheet does, so a typed "42"
    /// aggregates instead of sitting in the grid as a string.
    public nonisolated static func literal(_ raw: String) -> Value {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .null }
        if let n = Double(trimmed) { return .number(n) }
        switch trimmed.uppercased() {
        case "TRUE": return .bool(true)
        case "FALSE": return .bool(false)
        default: return .string(raw)
        }
    }
}
