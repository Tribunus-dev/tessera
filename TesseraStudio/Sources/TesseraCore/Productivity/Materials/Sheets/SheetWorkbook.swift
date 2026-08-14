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

/// Calculation state for a workbook - one or more open sheets sharing a
/// single `SheetEngine`, so cross-sheet formulas ("Budget!A1") work.
///
/// **What is stored versus what is shown.** Each `Sheet` document keeps
/// its cells' SOURCE text - `=SUM(B1:B4)`, not `10`. That leaves the
/// storage format, the receipt chain and the recovery files exactly as
/// they were, and it is the only representation that survives a round
/// trip: a saved computed value would silently become a literal.
/// Displayed values are computed here and never persisted.
///
/// Recalculation therefore changes what the grid shows without changing
/// what is on disk, which is why an edit persists one cell but can
/// refresh many.
///
/// **One engine, many sheets.** `SheetEngine` addresses a sheet by its
/// STRING name (matching formula syntax - a reference reads `Budget!A1`,
/// not a UUID), while the product layer addresses a `Sheet` by its
/// stable `UUID`. `engineSheetName` bridges the two: it is the only
/// place that name is chosen, so a sheet keeps its calculation state
/// (cells, formulas, dependents elsewhere that reference it) across a
/// `hydrate(from:)` refresh, and so loading a SECOND sheet no longer
/// discards the first one's state - `hydrate` used to rebuild the whole
/// engine from scratch on every call, which meant a workbook could never
/// hold more than one sheet's calculation state at a time.
///
/// **Single-sheet callers keep working unchanged.** `apply`/
/// `displayText`/`value`/`hasFormula` with no sheet argument target
/// whichever sheet was hydrated most recently (via `SheetEngine`'s own
/// `activeSheet`), exactly like before `hydrate` became additive -
/// today's editor UI only ever has one sheet open, so nothing about its
/// call sites needs to change. The `in sheetID:` overloads exist for a
/// caller that has more than one sheet loaded at once (tabs UI - not yet
/// built; see studio-expansion-plan.md 0.1).
@MainActor
public final class SheetWorkbook: ObservableObject {

    /// The live engine, shared across every loaded sheet.
    public private(set) var engine: SheetEngine

    /// Bumped whenever displayed values may have changed, so a SwiftUI
    /// grid observing this object redraws. Recalculation can touch cells
    /// far from the edit, so the grid cannot key off the edited cell.
    @Published public private(set) var revision: Int = 0

    /// The sheet most recently loaded - the target for the no-sheetID
    /// convenience API. `nil` when nothing has been hydrated (or after
    /// `unload()`).
    public private(set) var sheetID: UUID?

    /// Every sheet currently loaded into this workbook, keyed by its
    /// product-layer identity.
    public private(set) var sheets: [UUID: Sheet] = [:]

    /// `Sheet.id` -> the `SheetEngine` sheet name it was loaded under.
    /// Chosen once at first load from `Sheet.title` (uniquified on
    /// collision) and reused on every later `hydrate` for the same
    /// sheet, even if the title changes afterward - tracking a title
    /// rename is part of the deferred tabs-UI work (0.1b-e), not this
    /// plumbing layer.
    private var engineSheetName: [UUID: String] = [:]

    /// `Sheet.id` -> the uppercased named-range names that sheet's own
    /// `effectiveNamedRanges` last registered into the engine. Tracked
    /// so a refresh (re-`hydrate` of an already-loaded sheet) can
    /// precisely undefine just THIS sheet's previous names before
    /// redefining its current ones - `engine.defineName` fails outright
    /// on a name that's already registered, and named ranges are
    /// workbook-wide in the engine (not sheet-scoped storage), so a
    /// blind "redefine everything" would collide with itself on every
    /// refresh.
    private var namedRangeNamesBySheetID: [UUID: Set<String>] = [:]

    public init(engine: SheetEngine = SheetEngine()) {
        self.engine = engine
    }

    // MARK: - Loading

    /// Load (or refresh) one sheet's calculation state into this
    /// workbook, alongside whatever else is already loaded.
    ///
    /// Two passes on purpose: every literal is placed before any formula
    /// runs, so a formula that references a cell below or to the right of
    /// it still sees a value. A single pass would evaluate such a formula
    /// against blanks and cache the wrong result until something forced a
    /// recalculation.
    public func hydrate(from sheet: Sheet) {
        let name: String
        if let existing = engineSheetName[sheet.id] {
            name = existing
            clearCells(sheetName: name)
        } else {
            name = uniqueEngineName(base: sheet.title.isEmpty ? "Sheet" : sheet.title)
            engine.createSheet(name: name)
            engineSheetName[sheet.id] = name
        }

        var formulas: [(CellAddr, String)] = []
        for row in 0..<sheet.rowCount {
            for col in 0..<sheet.columnCount {
                let text = sheet.cellText(row: row, col: col)
                guard !text.isEmpty else { continue }
                let addr = CellAddr(col: col, row: row)
                if Self.isFormula(text) {
                    formulas.append((addr, text))
                } else {
                    engine.setValue(sheet: name, addr: addr, value: Self.literal(text))
                }
            }
        }

        for (addr, source) in formulas {
            do {
                _ = try engine.setFormula(sheet: name, addr: addr, source: source)
            } catch {
                // A stored formula that no longer parses (or is circular)
                // shows as #REF! rather than vanishing - a blank cell
                // would look like data loss.
                engine.setValue(sheet: name, addr: addr, value: .error(.referenceInvalid))
            }
        }

        // Undefine this sheet's own previously-registered names (a
        // refresh's stale set - a no-op on first load, when the set is
        // empty), then register its current ones fresh.
        for oldName in namedRangeNamesBySheetID[sheet.id] ?? [] {
            engine.undefineName(oldName)
        }
        var registeredNames: Set<String> = []
        for (key, namedRange) in sheet.effectiveNamedRanges {
            guard let range = namedRange.rangeRef else { continue }
            if engine.defineName(namedRange.name, range: range, sheet: namedRange.sheet) {
                registeredNames.insert(key)
            }
            // A definition that fails here (name collides with one
            // from a DIFFERENT loaded sheet) is silently skipped - see
            // SheetStore.defineNamedRange's doc comment on scoping;
            // resolving cross-sheet name collisions is deferred tabs-UI
            // work (0.1b-e), not this hydrate path's problem to solve.
        }
        namedRangeNamesBySheetID[sheet.id] = registeredNames

        sheets[sheet.id] = sheet
        sheetID = sheet.id
        engine.setActiveSheet(name)
        revision &+= 1
    }

    /// Drop ALL calculation state - every loaded sheet, not just one.
    /// Called when the surface closes so the agent's sheet tools stop
    /// reporting a workbook that is not open.
    public func unload() {
        engine = SheetEngine()
        sheets = [:]
        engineSheetName = [:]
        namedRangeNamesBySheetID = [:]
        sheetID = nil
        revision &+= 1
    }

    /// Drop ONE sheet's calculation state, leaving the rest of the
    /// workbook untouched. A no-op if `sheetID` isn't loaded. If it is
    /// the only sheet loaded, this is equivalent to `unload()` -
    /// `SheetEngine` refuses to delete its last remaining sheet.
    public func unload(_ sheetID: UUID) {
        guard let name = engineSheetName[sheetID] else { return }
        guard sheets.count > 1 else {
            unload()
            return
        }
        engine.deleteSheet(name)
        engineSheetName.removeValue(forKey: sheetID)
        sheets.removeValue(forKey: sheetID)
        for oldName in namedRangeNamesBySheetID.removeValue(forKey: sheetID) ?? [] {
            engine.undefineName(oldName)
        }
        if self.sheetID == sheetID {
            self.sheetID = sheets.keys.first
            if let newActive = self.sheetID, let newName = engineSheetName[newActive] {
                engine.setActiveSheet(newName)
            }
        }
        revision &+= 1
    }

    private func clearCells(sheetName: String) {
        guard let extent = engine.usedExtent(sheet: sheetName) else { return }
        for row in extent.topLeft.row...extent.bottomRight.row {
            for col in extent.topLeft.col...extent.bottomRight.col {
                engine.clearCell(sheet: sheetName, addr: CellAddr(col: col, row: row))
            }
        }
    }

    /// `base`, or `"base (2)"`, `"base (3)"`, ... if `base` is already
    /// taken by another loaded sheet. Only reachable once a second
    /// sheet with a colliding title is loaded into the SAME workbook -
    /// today's single-sheet-per-editor callers never hit this path.
    private func uniqueEngineName(base: String) -> String {
        guard engine.hasSheet(base) else { return base }
        var suffix = 2
        while engine.hasSheet("\(base) (\(suffix))") {
            suffix += 1
        }
        return "\(base) (\(suffix))"
    }

    // MARK: - Editing

    /// Apply a user edit to the most-recently-loaded sheet. Returns
    /// false when a formula was rejected (a parse failure or a circular
    /// reference), in which case the cell shows `#REF!`.
    ///
    /// The caller still persists the SOURCE text either way: a formula
    /// the engine rejects is the user's text and must not be silently
    /// discarded from the document.
    @discardableResult
    public func apply(text: String, row: Int, col: Int) -> Bool {
        applyUnchecked(text: text, row: row, col: col, sheetName: nil)
    }

    /// Apply a user edit to a specific loaded sheet. Returns false (and
    /// makes no change) if `sheetID` isn't loaded.
    @discardableResult
    public func apply(text: String, row: Int, col: Int, in sheetID: UUID) -> Bool {
        guard let name = engineSheetName[sheetID] else { return false }
        return applyUnchecked(text: text, row: row, col: col, sheetName: name)
    }

    private func applyUnchecked(text: String, row: Int, col: Int, sheetName: String?) -> Bool {
        let addr = CellAddr(col: col, row: row)
        defer { revision &+= 1 }

        guard Self.isFormula(text) else {
            engine.setValue(sheet: sheetName, addr: addr, value: Self.literal(text))
            return true
        }
        do {
            _ = try engine.setFormula(sheet: sheetName, addr: addr, source: text)
            return true
        } catch {
            engine.setValue(sheet: sheetName, addr: addr, value: .error(.referenceInvalid))
            return false
        }
    }

    // MARK: - Reading

    /// What the grid shows for the most-recently-loaded sheet: the
    /// computed value.
    public func displayText(row: Int, col: Int) -> String {
        engine.getValue(sheet: nil, addr: CellAddr(col: col, row: row)).asString
    }

    /// What the grid shows for a specific loaded sheet.
    public func displayText(row: Int, col: Int, in sheetID: UUID) -> String {
        guard let name = engineSheetName[sheetID] else { return "" }
        return engine.getValue(sheet: name, addr: CellAddr(col: col, row: row)).asString
    }

    /// The computed value itself, for callers that need the type.
    public func value(row: Int, col: Int) -> Value {
        engine.getValue(sheet: nil, addr: CellAddr(col: col, row: row))
    }

    /// The computed value for a specific loaded sheet.
    public func value(row: Int, col: Int, in sheetID: UUID) -> Value {
        guard let name = engineSheetName[sheetID] else { return .null }
        return engine.getValue(sheet: name, addr: CellAddr(col: col, row: row))
    }

    /// True when the cell holds a formula rather than a literal.
    public func hasFormula(row: Int, col: Int) -> Bool {
        engine.hasFormula(sheet: nil, addr: CellAddr(col: col, row: row))
    }

    /// True when the cell on a specific loaded sheet holds a formula.
    public func hasFormula(row: Int, col: Int, in sheetID: UUID) -> Bool {
        guard let name = engineSheetName[sheetID] else { return false }
        return engine.hasFormula(sheet: name, addr: CellAddr(col: col, row: row))
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
