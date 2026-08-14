//===----------------------------------------------------------------------===//
//  SheetEngine.swift
//  Tessera Formula Engine
//
//  Top-level engine — wires dependency graph, evaluator, undo/redo,
//  named ranges, and sheet management into one coherent workbook engine.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - CellData

/// The data stored for each cell — computed value plus optional formula.
struct CellData: Sendable {
    var rawValue: Value
    var formula: Formula?
    var numberFormat: String?

    /// Non-nil when this cell holds part of ANOTHER cell's spilled array.
    /// The value is the anchor - the cell whose formula produced it. A
    /// spilled cell has no formula of its own and cannot be edited
    /// directly; the anchor owns the whole block.
    var spillOrigin: CellAddr?

    /// Set on the ANCHOR: the extent its array result currently occupies,
    /// so the previous spill can be cleared before the next one is
    /// written. Nil for an ordinary single-value cell.
    var spillSize: SpillSize?

    init(value: Value = .null, formula: Formula? = nil) {
        self.rawValue = value
        self.formula = formula
    }
}

/// Dimensions of a spilled array result.
struct SpillSize: Sendable, Equatable {
    let rows: Int
    let cols: Int
}

// MARK: - Sheet

/// One sheet within a workbook.
struct WorkbookSheet: Sendable {
    let name: String
    /// Cell addr (zero-based) → cell data
    var cells: [CellAddr: CellData] = [:]

    init(name: String) {
        self.name = name
    }
}

// MARK: - NamedRange

/// A named range — a label bound to a sheet-qualified range.
public struct NamedRange: Equatable, Sendable {
    public let name: String
    public let range: RangeRef
    public let sheet: String?

    public init(name: String, range: RangeRef, sheet: String? = nil) {
        self.name = name
        self.range = range
        self.sheet = sheet
    }
}

// MARK: - SheetEngine

/// Thread-safe workbook engine — all sheets, all formulas, all recalculation.
///
/// Conforms to `SheetEngineCore` so the evaluator can query cell values
/// without access to the full engine.
public final class SheetEngine: @unchecked Sendable, SheetEngineCore {
    // MARK: - Subsystems

    public let graph: DependencyGraph
    public let functions: FunctionRegistry
    public let undoStack: UndoRedoStack
    public let evaluator: Evaluator

    /// Named ranges (scoped to workbook, not individual sheets)
    private var _namedRanges: [String: NamedRange] = [:]

    /// Configurable clock/RNG seed for reproducible evaluation
    public var deterministicConfig: DeterministicConfig

    // MARK: - Sheet storage

    /// Sheet name → sheet data
    private var _sheets: [String: WorkbookSheet] = [:]
    /// Ordered sheet list (preserves tab order)
    private var _sheetOrder: [String] = []
    /// Active sheet for unqualified references
    private var _activeSheet: String = "Sheet1"

    private let lock = NSLock()

    /// Unlocked view of this engine, handed to the evaluator.
    ///
    /// Evaluation runs with `lock` already held, so it must NOT re-enter
    /// the locked public accessors. Passing `self` here (this engine also
    /// conforms to `SheetEngineCore` for external callers) deadlocks on
    /// any formula that reads a cell.
    private lazy var evaluatorBridge: EvaluatorBridge = EvaluatorBridge(engine: self)

    // MARK: - Init

    public init() {
        self.graph = DependencyGraph()
        self.functions = .shared
        self.undoStack = UndoRedoStack()
        self.deterministicConfig = DeterministicConfig()
        var cfg = Evaluator.Config()
        cfg.deterministicConfig = self.deterministicConfig
        self.evaluator = Evaluator(config: cfg, functions: functions)
        createSheet(name: "Sheet1")
    }

    // MARK: - Thread-safe access helpers

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func mutating<T>(_ body: (inout SheetEngine) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        var mutableSelf = self
        let result = try body(&mutableSelf)
        // NSLock doesn't give us exclusive access across `inout`, so we rely
        // on callers not to capture `self` across threads during mutation.
        // All mutation paths go through the lock here.
        return result
    }

    // MARK: - Sheet management

    /// All sheet names in tab order.
    public var sheetNames: [String] {
        withLock { Array(_sheetOrder) }
    }

    /// True if a sheet exists.
    public func hasSheet(_ name: String) -> Bool {
        withLock { _sheets[name] != nil }
    }

    /// Create a sheet. Fails if the name already exists.
    /// Returns the new sheet name (may be uniquified if it conflicts).
    @discardableResult
    public func createSheet(name: String) -> String? {
        withLock {
            guard _sheets[name] == nil else { return nil }
            let sheet = WorkbookSheet(name: name)
            _sheets[name] = sheet
            _sheetOrder.append(name)
            return name
        }
    }

    /// Delete a sheet and all its cells. Fails if it's the last sheet.
    public func deleteSheet(_ name: String) {
        withLock {
            guard _sheets.count > 1 else { return }
            guard let _ = _sheets.removeValue(forKey: name) else { return }
            _sheetOrder.removeAll { $0 == name }
            if _activeSheet == name {
                _activeSheet = _sheetOrder.first ?? "Sheet1"
            }
            graph.removeSheet(name)
            // After removing the sheet's own storage: a formula ON the
            // deleted sheet no longer exists to rewrite, and iterating
            // the (already-shrunk) _sheets here naturally skips it
            // rather than wasting work rewriting a formula about to be
            // discarded anyway.
            propagateSheetDeletion(of: name)
        }
    }

    /// Rewrite every formula elsewhere in the workbook that references
    /// the just-deleted sheet to `#REF!` - the same treatment a
    /// reference into a deleted row or column already gets.
    ///
    /// Without this, `graph.removeSheet` above cleans up the graph's
    /// own edges, but a formula's stored TEXT still names the sheet
    /// that no longer exists. It does not throw or refuse to load; it
    /// silently evaluates every such reference as null and keeps
    /// computing a plausible-looking wrong answer forever - the same
    /// silent-corruption failure mode `propagateSheetRename` exists to
    /// prevent, just via deletion instead of renaming.
    ///
    /// Must be called with `lock` already held, and after `_sheets[name]`
    /// has already been removed.
    private func propagateSheetDeletion(of name: String) {
        let edit = StructuralEdit.deleteSheet(name: name)
        var rewrites: [(sheet: String, addr: CellAddr, source: String)] = []
        for (sheetName, sheet) in _sheets {
            for (addr, data) in sheet.cells {
                guard let source = data.formula?.source else { continue }
                let rewritten = FormulaReferenceAdjuster.adjust(source, for: edit)
                if rewritten != source {
                    rewrites.append((sheetName, addr, rewritten))
                }
            }
        }
        guard !rewrites.isEmpty else { return }

        undoStack.beginGroup()
        for r in rewrites {
            _ = try? setFormulaUnlocked(sheet: r.sheet, addr: r.addr, source: r.source)
        }
        undoStack.endGroup()
    }

    /// Rename a sheet.
    ///
    /// Reassigns `_sheets[new]` to a copy of the OLD sheet's cells, not a
    /// fresh empty `WorkbookSheet` - a prior version discarded `sheet`
    /// (the just-removed data) on the very next line by overwriting it
    /// with `WorkbookSheet(name: new)`, so every rename silently wiped
    /// the sheet's contents. `graph.renameSheet` keeps the dependency
    /// graph's edges - including any cross-sheet formula elsewhere that
    /// reads this sheet - pointed at the new name.
    public func renameSheet(from old: String, to new: String) -> Bool {
        withLock {
            guard let oldSheet = _sheets[old], _sheets[new] == nil else { return false }
            _sheets.removeValue(forKey: old)
            var renamed = WorkbookSheet(name: new)
            renamed.cells = oldSheet.cells
            _sheets[new] = renamed
            if let idx = _sheetOrder.firstIndex(of: old) {
                _sheetOrder[idx] = new
            }
            if _activeSheet == old { _activeSheet = new }
            // Rewires the graph's OWN edges (precedent/dependent tracking)
            // to the new name - necessary but not sufficient. It does not
            // touch any formula's stored TEXT, so the sweep below is what
            // makes a formula elsewhere that reads "old!A1" keep reading
            // the right cell instead of a sheet that no longer exists.
            graph.renameSheet(from: old, to: new)
            propagateSheetRename(from: old, to: new)
            return true
        }
    }

    /// Rewrite every formula in the workbook - on ANY sheet, including
    /// the renamed one itself (a formula can reference its own sheet by
    /// name) - that qualifies a reference with the OLD sheet name, so it
    /// qualifies with the new one instead.
    ///
    /// Without this, `graph.renameSheet` above still correctly marks a
    /// referencing formula dirty when the renamed sheet's data changes
    /// (the graph edges did follow the rename), but EVALUATING that
    /// formula resolves "old!A1" against a sheet that no longer exists
    /// and silently reads null - a formula that looked like it survived
    /// the rename would quietly start computing wrong.
    ///
    /// Text-based, not AST-based, matching `FormulaReferenceAdjuster`'s
    /// existing row/col rewriting: re-printing an AST would reformat the
    /// user's formula, and only the sheet-qualifier tokens should change.
    /// Must be called with `lock` already held.
    private func propagateSheetRename(from old: String, to new: String) {
        let edit = StructuralEdit.renameSheet(from: old, to: new)
        var rewrites: [(sheet: String, addr: CellAddr, source: String)] = []
        for (sheetName, sheet) in _sheets {
            for (addr, data) in sheet.cells {
                guard let source = data.formula?.source else { continue }
                let rewritten = FormulaReferenceAdjuster.adjust(source, for: edit)
                if rewritten != source {
                    rewrites.append((sheetName, addr, rewritten))
                }
            }
        }
        guard !rewrites.isEmpty else { return }

        // One undo step for the whole cascade, not one per formula.
        //
        // Applied in dictionary-iteration order (unspecified), not
        // dependency order: if A's rewrite runs before a dependent B's,
        // recalculating A dirties B and evaluates it against B's own
        // STILL-STALE text (reading null off the now-missing old
        // sheet name) before B's rewrite lands moments later in this
        // same loop and corrects it. The wrong intermediate never
        // escapes - `lock` is held for this whole method - so this is
        // wasted recalculation, not a correctness bug; sorting the plan
        // into dependency order would remove the waste but isn't free,
        // and every formula here converges on the right value by the
        // time the loop returns either way.
        //
        // A rewrite that fails to re-parse is silently dropped by
        // `try?`: best-effort by design (a rename should not itself
        // fail), but it means a formula that couldn't be migrated is
        // left pointing at a sheet name that no longer exists with no
        // signal to the caller that anything was skipped.
        undoStack.beginGroup()
        for r in rewrites {
            _ = try? setFormulaUnlocked(sheet: r.sheet, addr: r.addr, source: r.source)
        }
        undoStack.endGroup()
    }

    /// Set the active sheet for unqualified references.
    public func setActiveSheet(_ name: String) {
        withLock {
            if _sheets[name] != nil { _activeSheet = name }
        }
    }

    /// Get the active sheet name.
    public var activeSheet: String {
        withLock { _activeSheet }
    }

    // MARK: - Value API

    /// Set a plain value in a cell (no formula). Clears any existing formula.
    /// Returns the affected dirty cells.
    @discardableResult
    public func setValue(sheet: String?, addr: CellAddr, value: Value) -> Set<CellAddr> {
        let effectiveSheet = sheet ?? _activeSheet
        return withLock {
            guard let idx = _sheetOrder.firstIndex(of: effectiveSheet) else { return [] }
            _ = idx // suppress warning

            // You cannot change part of a spilled array. Refuse rather
            // than tear a hole in someone else's result; the anchor is
            // the only cell that owns this block.
            if isSpilledInto(addr, sheet: effectiveSheet) { return [] }

            // Replacing an anchor's own formula with a plain value drops
            // whatever it had spilled, and retires the formula itself so
            // the next recalculation does not resurrect it.
            clearSpill(anchor: addr, sheet: effectiveSheet)
            graph.clearFormula(SheetCellAddr(sheet: effectiveSheet, addr: addr))

            // Snapshot before the write: value edits were not recorded at
            // all, so undo/redo silently did nothing for anything typed
            // straight into a cell.
            let previous = _sheets[effectiveSheet]?.cells[addr]?.rawValue ?? .null
            _sheets[effectiveSheet]?.cells[addr] = CellData(value: value)
            undoStack.push(Edit(change: .setValue(
                addr: addr, sheet: effectiveSheet,
                old: previous, new: value
            )))

            // Mark dependents dirty and recalculate
            let dirtyKeys = markDirtyKeys(sheet: effectiveSheet, addr: addr)
            recalculateInternal(dirty: dirtyKeys)
            return Set(dirtyKeys.map(\.addr))
        }
    }

    /// Set a formula in a cell. Parses, validates cycle-free graph insertion,
    /// caches the computed value, and recalculates all downstream cells.
    ///
    /// - Throws: `Parser.ParseError` on syntax error, `CycleError` on circular reference.
    /// - Returns: the set of cells that were recalculated.
    @discardableResult
    public func setFormula(sheet: String?, addr: CellAddr, source: String) throws -> Set<CellAddr> {
        let effectiveSheet = sheet ?? _activeSheet
        return try withLock {
            try setFormulaUnlocked(sheet: effectiveSheet, addr: addr, source: source)
        }
    }

    /// The body of `setFormula`, factored out so a caller that already
    /// holds `lock` - `renameSheet`'s formula-text-propagation pass, most
    /// notably - can re-set a formula without re-entering the lock.
    /// `NSLock` is non-recursive; calling the public, locking
    /// `setFormula` from inside another locked method deadlocks exactly
    /// the way the evaluator's cell reads once did (see `EvaluatorBridge`).
    /// The caller MUST already hold `lock`.
    @discardableResult
    private func setFormulaUnlocked(sheet effectiveSheet: String, addr: CellAddr, source: String) throws -> Set<CellAddr> {
        guard _sheets[effectiveSheet] != nil else { return [] }

        // Parse
        let parser = try FormulaParser(source: source)
        let result = try parser.parse()

        switch result {
        case .value(let constant):
            // No dependency tracking needed — store as a plain value
            _sheets[effectiveSheet]?.cells[addr] = CellData(value: constant)
            let dirtyKeys = markDirtyKeys(sheet: effectiveSheet, addr: addr)
            recalculateInternal(dirty: dirtyKeys)
            return Set(dirtyKeys.map(\.addr))

        case .formula(let formula):
            // Snapshot the previous formula BEFORE the write below
            // replaces it; reading it afterwards recorded old == new,
            // so every formula undo step was a no-op.
            let previousFormula = _sheets[effectiveSheet]?.cells[addr]?.formula

            // Cycle-safe graph insertion
            try graph.setFormula(SheetCellAddr(sheet: effectiveSheet, addr: addr), ast: formula.ast)

            // Evaluate and cache, spilling an array result into the
            // cells below/right of the anchor.
            let evaluated = try evaluator.evaluate(formula.ast, at: addr, sheet: effectiveSheet, engine: evaluatorBridge)
            let spilled = writeResult(
                anchor: addr, sheet: effectiveSheet,
                result: evaluated, formula: formula
            )

            // Push undo step
            let edit = Edit(change: .setFormula(
                addr: addr, sheet: effectiveSheet,
                old: previousFormula,
                new: formula
            ))
            undoStack.push(edit)

            // Recalculate downstream. Spilled addresses are dirty
            // too: a cell reading one of them must see the new value.
            var dirtyKeys = markDirtyKeys(sheet: effectiveSheet, addr: addr)
            for target in spilled {
                dirtyKeys.formUnion(graph.dirtySubgraph(from: [SheetCellAddr(sheet: effectiveSheet, addr: target)]))
            }
            recalculateInternal(dirty: dirtyKeys)
            return Set(dirtyKeys.map(\.addr))
        }
    }

    /// Get the computed value of a cell. Returns `.null` for empty cells.
    public func getValue(sheet: String?, addr: CellAddr) -> Value {
        let effectiveSheet = sheet ?? _activeSheet
        return withLock {
            _sheets[effectiveSheet]?.cells[addr]?.rawValue ?? .null
        }
    }

    /// Get the formula text for a cell, or nil if the cell has no formula.
    public func getFormula(sheet: String?, addr: CellAddr) -> String? {
        let effectiveSheet = sheet ?? _activeSheet
        return withLock {
            _sheets[effectiveSheet]?.cells[addr]?.formula?.source
        }
    }

    /// Returns true if the cell at addr contains a formula.
    public func hasFormula(sheet: String?, addr: CellAddr) -> Bool {
        let effectiveSheet = sheet ?? _activeSheet
        return withLock {
            _sheets[effectiveSheet]?.cells[addr]?.formula != nil
        }
    }

    /// Clear a cell (set to null). Removes any formula.
    public func clearCell(sheet: String?, addr: CellAddr) {
        setValue(sheet: sheet, addr: addr, value: .null)
    }

    /// Delete a cell and its formula from the graph.
    public func deleteCell(sheet: String?, addr: CellAddr) {
        let effectiveSheet = sheet ?? _activeSheet
        withLock {
            // Deleting an anchor takes its spilled block with it.
            clearSpill(anchor: addr, sheet: effectiveSheet)
            _sheets[effectiveSheet]?.cells.removeValue(forKey: addr)
            graph.removeCell(SheetCellAddr(sheet: effectiveSheet, addr: addr))
        }
    }

    // MARK: - Range API

    /// The bounding box of the non-empty cells on a sheet - the
    /// spreadsheet "used range" - or nil when the sheet is empty.
    /// Lets a caller find where the data is without scanning blindly.
    public func usedExtent(sheet: String?) -> RangeRef? {
        let effectiveSheet = sheet ?? _activeSheet
        return withLock {
            guard let cells = _sheets[effectiveSheet]?.cells else { return nil }
            var minCol = Int.max, minRow = Int.max
            var maxCol = Int.min, maxRow = Int.min
            var found = false
            for (addr, data) in cells {
                // A cell holding only a cleared value is not "used".
                if data.rawValue == .null && data.formula == nil { continue }
                found = true
                minCol = Swift.min(minCol, addr.col)
                maxCol = Swift.max(maxCol, addr.col)
                minRow = Swift.min(minRow, addr.row)
                maxRow = Swift.max(maxRow, addr.row)
            }
            guard found else { return nil }
            return RangeRef(
                sheet: effectiveSheet,
                topLeft: CellAddr(col: minCol, row: minRow),
                bottomRight: CellAddr(col: maxCol, row: maxRow)
            )
        }
    }

    /// Get all values in a range as a flat array (row-major).
    public func getRangeValues(sheet: String?, range: RangeRef) -> [Value] {
        withLock { getRangeValuesUnlocked(sheet: sheet, range: range) }
    }

    /// Range read without taking the lock. The caller MUST already hold
    /// it. See ``getCellValueUnlocked(_:sheet:)`` for why these exist.
    fileprivate func getRangeValuesUnlocked(sheet: String?, range: RangeRef) -> [Value] {
        let effectiveSheet = sheet ?? _activeSheet
        guard let sheetData = _sheets[effectiveSheet] else { return [] }
        var result: [Value] = []
        for addr in range.cells() {
            result.append(sheetData.cells[addr]?.rawValue ?? .null)
        }
        return result
    }

    /// Get a 2D array of values for a range.
    public func getRange(sheet: String?, range: RangeRef) -> [[Value]] {
        let effectiveSheet = sheet ?? _activeSheet
        return withLock {
            guard let sheetData = _sheets[effectiveSheet] else { return [] }
            var rows: [[Value]] = Array(repeating: [], count: range.height)
            for r in 0..<range.height {
                for c in 0..<range.width {
                    let addr = CellAddr(col: range.topLeft.col + c, row: range.topLeft.row + r)
                    rows[r].append(sheetData.cells[addr]?.rawValue ?? .null)
                }
            }
            return rows
        }
    }

    /// Build a ColumnSlice for a range — Arrow-inspired typed columnar access.
    public func getColumnSlice(sheet: String?, range: RangeRef) -> ColumnSlice {
        let values = getRangeValues(sheet: sheet, range: range)
        return ColumnSlice.fromValues(values)
    }

    // MARK: - Named ranges

    /// All defined names in the workbook, keyed by `name.uppercased()`
    /// (case-insensitive lookup, matching how a formula resolves a bare
    /// identifier - see `defineName`). Each value's own `.name` keeps
    /// the caller's original spelling for display.
    public var namedRanges: [String: NamedRange] {
        withLock { _namedRanges }
    }

    /// Define a name bound to a range. Fails if the name already exists
    /// (case-insensitively - `MyCell` and `MYCELL` are the same name).
    ///
    /// Stored under `name.uppercased()`: the lexer uppercases every bare
    /// identifier before a formula ever sees it (`Lexer.scanIdentifier`'s
    /// `.namedRange(upper)`, the same case-folding function names get),
    /// so a name stored under its original mixed-case spelling could
    /// never be found by a formula that references it - every named
    /// range would silently resolve to `#NAME?` unless it happened to
    /// be defined in all caps. `NamedRange.name` still keeps the
    /// caller's original spelling for display.
    public func defineName(_ name: String, range: RangeRef, sheet: String? = nil) -> Bool {
        withLock {
            let key = name.uppercased()
            guard _namedRanges[key] == nil else { return false }
            _namedRanges[key] = NamedRange(name: name, range: range, sheet: sheet)
            return true
        }
    }

    /// Remove a named range (case-insensitively, matching `defineName`).
    public func undefineName(_ name: String) {
        withLock {
            _namedRanges.removeValue(forKey: name.uppercased())
        }
    }

    /// Resolve a named range to its value (called by the evaluator).
    private func namedRangeResolver(_ name: String, at context: CellAddr, fallbackSheet: String) throws -> Value {
        withLock { resolveNamedRangeUnlocked(name, at: context, fallbackSheet: fallbackSheet) }
    }

    /// Named-range read without taking the lock. The caller MUST already
    /// hold it. See ``getCellValueUnlocked(_:sheet:)``.
    ///
    /// `fallbackSheet` - the CALLING FORMULA's own sheet, not
    /// `_activeSheet` - is what a name with no explicit sheet restriction
    /// resolves against. Using `_activeSheet` here was the same bug
    /// class this whole fix exists to close, surviving in the
    /// named-range path: a formula on an inactive sheet reading an
    /// unscoped named range would silently read the active sheet's data.
    fileprivate func resolveNamedRangeUnlocked(_ name: String, at context: CellAddr, fallbackSheet: String) -> Value {
        guard let nr = _namedRanges[name] else { return .error(.nameInvalid) }
        let effectiveSheet = nr.sheet ?? fallbackSheet
        guard let sheetData = _sheets[effectiveSheet] else { return .error(.referenceInvalid) }
        let vals = nr.range.cells().map { sheetData.cells[$0]?.rawValue ?? .null }
        if vals.count == 1 { return vals[0] }
        return .array(rows: nr.range.height, cols: nr.range.width, flat: vals)
    }

    // MARK: - Recalculation

    /// Full recalculation of all formula cells, across every sheet.
    public func recalculate() {
        withLock {
            recalculateInternal(dirty: graph.allCells)
        }
    }

    /// Incremental recalculation from a dirty root on `sheet` (defaults to
    /// the active sheet).
    public func recalculateIncremental(from addr: CellAddr, sheet: String? = nil) {
        withLock {
            let key = SheetCellAddr(sheet: sheet ?? _activeSheet, addr: addr)
            let dirty = graph.dirtySubgraph(from: [key])
            recalculateInternal(dirty: dirty)
        }
    }

    /// Force-mark a cell as dirty (e.g. a volatile function was triggered).
    public func markDirty(addr: CellAddr, sheet: String? = nil) -> Set<CellAddr> {
        withLock {
            let key = SheetCellAddr(sheet: sheet ?? _activeSheet, addr: addr)
            var dirty = Set<SheetCellAddr>([key])
            graph.markAllVolatileDirty(&dirty)
            return Set(graph.dirtySubgraph(from: dirty).map(\.addr))
        }
    }

    /// Evaluate all formula cells on `sheet` (defaults to the active
    /// sheet) and return a map of addr -> result. Use this for export /
    /// checkpointing.
    public func evaluateAll(sheet: String? = nil) -> [CellAddr: Value] {
        withLock {
            let effectiveSheet = sheet ?? _activeSheet
            var results: [CellAddr: Value] = [:]
            for key in graph.formulaCells where key.sheet == effectiveSheet {
                if let data = currentCellData(key) {
                    results[key.addr] = data.rawValue
                }
            }
            return results
        }
    }

    // MARK: - Undo / Redo

    /// Undo the most recent edit group. Returns the edit description or nil.
    public func undo() -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard let edits = undoStack.undo() else { return nil }
        for edit in edits {
            // `undo()` already returns each edit INVERTED, so these are
            // applied forward. Applying them with `isUndo: true` inverted
            // a second time and landed back on the new value, which made
            // undo a no-op for every cell edit.
            applyEdit(edit, isUndo: false)
        }
        return edits.first.map { (_: Edit) -> String? in undoStack.lastEditDescription } ?? nil
    }

    /// Redo the most recently undone edit group. Returns the edit description or nil.
    public func redo() -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard let edits = undoStack.redo() else { return nil }
        for edit in edits {
            applyEdit(edit, isUndo: false)
        }
        return edits.first.map { (_: Edit) -> String? in undoStack.lastEditDescription } ?? nil
    }

    /// Begin an edit group — all edits until `endEditGroup()` become one undo step.
    public func beginEditGroup() {
        undoStack.beginGroup()
    }

    /// End the current edit group.
    public func endEditGroup() {
        undoStack.endGroup()
    }

    // MARK: - SheetEngineCore conformance

    // The evaluator holds a `inout SheetEngineCore` reference.
    // SheetEngine is a class (reference semantics) so we pass `self` as the
    // engine. The evaluator will mutate through `inout`, which requires
    // special handling: we use `withLock` inside each required method so the
    // evaluator's `inout` access is safe across threads.

    public func getCellValue(_ addr: CellAddr, sheet: String?) throws -> Value {
        withLock { getCellValueUnlocked(addr, sheet: sheet) }
    }

    /// Cell read without taking the lock. The caller MUST already hold it.
    ///
    /// `lock` is a plain `NSLock`, so re-entering it deadlocks. Evaluation
    /// runs inside `withLock` (from `setFormula`, `setValue`, and the
    /// `recalculate*` family), and the evaluator reads cells back through
    /// `SheetEngineCore` - so routing that read through the locked public
    /// method self-deadlocked on any formula that referenced a cell.
    /// These unlocked readers are what `EvaluatorBridge` calls instead.
    ///
    /// Same split the editor uses: the computation layer stays pure and
    /// lock-free (`TextEditReducer`), and isolation lives at the boundary.
    fileprivate func getCellValueUnlocked(_ addr: CellAddr, sheet: String?) -> Value {
        let effectiveSheet = sheet ?? _activeSheet
        return _sheets[effectiveSheet]?.cells[addr]?.rawValue ?? .null
    }

    public func getRangeValues(_ range: RangeRef, fallbackSheet: String) throws -> [Value] {
        getRangeValues(sheet: range.sheet ?? fallbackSheet, range: range)
    }

    public func resolveNamedRange(_ name: String, at context: CellAddr, fallbackSheet: String) throws -> Value {
        try namedRangeResolver(name, at: context, fallbackSheet: fallbackSheet)
    }

    // MARK: - Serialization

    /// Snapshot of the entire workbook for MCP checkpointing.
    public struct WorkbookState: Sendable {
        public struct SheetState: Sendable {
            public let name: String
            /// addr string → value JSON
            public let cells: [String: [String: Any]]
        }
        public let sheets: [SheetState]
        public let namedRanges: [String: [String: Any]]
        public let activeSheet: String
        public let graphSerialized: DependencyGraph.SerializedGraph
    }

    /// Serialize the full workbook state.
    public func serialize() -> WorkbookState {
        withLock {
            let sheetStates = _sheetOrder.compactMap { name -> WorkbookState.SheetState? in
                guard let sheet = _sheets[name] else { return nil }
                let cellMap = Dictionary(
                    uniqueKeysWithValues: sheet.cells.map { (addr, cell) -> (String, [String: Any]) in
                        var dict: [String: Any] = ["value": cell.rawValue.serialized()]
                        if let f = cell.formula {
                            dict["formula"] = f.source
                        }
                        return (addr.description, dict)
                    }
                )
                return WorkbookState.SheetState(name: name, cells: cellMap)
            }
            // Keyed by nr.name (the caller's original spelling), not the
            // dictionary's own lookup key (`name`, uppercased for
            // case-insensitive resolution - see defineName) - a
            // serialized snapshot should read back the name as the user
            // typed it, the same way `namedRanges`'s public getter does.
            let nrMap = Dictionary(
                uniqueKeysWithValues: _namedRanges.map { (_, nr) -> (String, [String: Any]) in
                    (nr.name, [
                        "range": nr.range.description,
                        "sheet": nr.sheet as Any
                    ])
                }
            )
            return WorkbookState(
                sheets: sheetStates,
                namedRanges: nrMap,
                activeSheet: _activeSheet,
                graphSerialized: graph.serialized()
            )
        }
    }

    // MARK: - Private helpers

    /// Mark a cell and its dependents as dirty, returning the dirty set as
    /// sheet-qualified keys - a dependent can live on a different sheet
    /// than the cell that changed (`=Sheet1!A1` on Sheet2), and the
    /// recalculation that follows must know each dirty cell's own sheet,
    /// not assume they all share one.
    private func markDirtyKeys(sheet: String, addr: CellAddr) -> Set<SheetCellAddr> {
        graph.dirtySubgraph(from: [SheetCellAddr(sheet: sheet, addr: addr)])
    }

    /// Internal recalculation over a pre-computed dirty set.
    /// Must be called while holding lock.
    private func recalculateInternal(dirty: Set<SheetCellAddr>) {
        guard !dirty.isEmpty else { return }

        // Mark volatile cells as dirty too (NOW, RAND, etc. can change any time)
        var mutableDirty = dirty
        graph.markAllVolatileDirty(&mutableDirty)
        let subgraph = graph.dirtySubgraph(from: mutableDirty)

        guard !subgraph.isEmpty else { return }

        do {
            let order = try graph.evaluationOrder(from: Array(subgraph))
            for key in order {
                evaluateCell(key)
            }
        } catch {
            // Cycle error — leave cells in their previous state, mark the
            // root cell with an error value, on ITS OWN sheet.
            for key in dirty {
                _sheets[key.sheet]?.cells[key.addr]?.rawValue = .error(.referenceInvalid)
            }
        }
    }

    /// Evaluate a single formula cell and cache the result.
    /// Must be called while holding lock.
    ///
    /// `key.sheet` - not `_activeSheet` - is both where the result is
    /// written and the formula's own sheet passed to the evaluator for
    /// resolving unqualified references. Using `_activeSheet` here was
    /// the actual defect: recalculating a dirty cell on an inactive
    /// sheet evaluated it against the active sheet's data and wrote the
    /// result into the active sheet's cell at the same (col, row) -
    /// silently corrupting whichever sheet happened to be open.
    private func evaluateCell(_ key: SheetCellAddr) {
        guard let ast = graph.formulaAST(for: key) else { return }
        guard let cell = _sheets[key.sheet]?.cells[key.addr] else { return }

        do {
            let result = try evaluator.evaluate(ast, at: key.addr, sheet: key.sheet, engine: evaluatorBridge)
            // Re-spill on every recalculation: the array's shape can
            // change when its inputs do (a FILTER matching fewer rows).
            writeResult(anchor: key.addr, sheet: key.sheet, result: result, formula: cell.formula)
        } catch {
            clearSpill(anchor: key.addr, sheet: key.sheet)
            _sheets[key.sheet]?.cells[key.addr] = CellData(value: .error(.referenceInvalid), formula: cell.formula)
        }
    }

    private func currentCellData(_ key: SheetCellAddr) -> CellData? {
        _sheets[key.sheet]?.cells[key.addr]
    }

    // MARK: - Dynamic arrays (spill)

    /// Store a formula's result at `anchor`, spilling an array result
    /// into the cells below/right of it.
    ///
    /// Returns every address written, so the caller can fold them into
    /// the dirty set - a cell reading a spilled address has to recalc
    /// when the anchor's array changes shape or contents.
    ///
    /// Spilling refuses to overwrite occupied cells: the anchor gets
    /// `#SPILL!` and nothing is written, matching Excel. The blocking
    /// cell is left untouched so the user can see what is in the way.
    @discardableResult
    private func writeResult(
        anchor: CellAddr,
        sheet: String,
        result: Value,
        formula: Formula?
    ) -> Set<CellAddr> {
        var touched = clearSpill(anchor: anchor, sheet: sheet)
        touched.insert(anchor)

        // A 1x1 array is a scalar; unwrap so `=SEQUENCE(1)` behaves like
        // any other single value rather than claiming a spill range.
        var value = result
        if case .array(let rows, let cols, let flat) = result, rows <= 1, cols <= 1 {
            value = flat.first ?? .null
        }

        guard case .array(let rows, let cols, let flat) = value, rows * cols > 1 else {
            var data = CellData(value: value, formula: formula)
            data.spillSize = nil
            _sheets[sheet]?.cells[anchor] = data
            return touched
        }

        // Collision check before writing anything.
        for r in 0..<rows {
            for c in 0..<cols {
                let target = CellAddr(col: anchor.col + c, row: anchor.row + r)
                if target == anchor { continue }
                guard let occupant = _sheets[sheet]?.cells[target] else { continue }
                let isOwnedByThisAnchor = occupant.spillOrigin == anchor
                let isBlank = occupant.rawValue == .null && occupant.formula == nil
                if !isOwnedByThisAnchor && !isBlank {
                    var blocked = CellData(value: .error(.spill), formula: formula)
                    blocked.spillSize = nil
                    _sheets[sheet]?.cells[anchor] = blocked
                    return touched
                }
            }
        }

        for r in 0..<rows {
            for c in 0..<cols {
                let target = CellAddr(col: anchor.col + c, row: anchor.row + r)
                let index = r * cols + c
                let element = index < flat.count ? flat[index] : .null
                if target == anchor {
                    var data = CellData(value: element, formula: formula)
                    data.spillSize = SpillSize(rows: rows, cols: cols)
                    _sheets[sheet]?.cells[target] = data
                } else {
                    var data = CellData(value: element)
                    data.spillOrigin = anchor
                    _sheets[sheet]?.cells[target] = data
                }
                touched.insert(target)
            }
        }
        return touched
    }

    /// Remove the cells previously spilled by `anchor`. Returns the
    /// addresses cleared so they can be marked dirty.
    @discardableResult
    private func clearSpill(anchor: CellAddr, sheet: String) -> Set<CellAddr> {
        guard let size = _sheets[sheet]?.cells[anchor]?.spillSize else { return [] }
        var cleared = Set<CellAddr>()
        for r in 0..<size.rows {
            for c in 0..<size.cols {
                let target = CellAddr(col: anchor.col + c, row: anchor.row + r)
                if target == anchor { continue }
                if _sheets[sheet]?.cells[target]?.spillOrigin == anchor {
                    _sheets[sheet]?.cells.removeValue(forKey: target)
                    cleared.insert(target)
                }
            }
        }
        _sheets[sheet]?.cells[anchor]?.spillSize = nil
        return cleared
    }

    /// True when `addr` holds part of another cell's spill. Writing to
    /// one is refused: in Excel you cannot change part of an array.
    private func isSpilledInto(_ addr: CellAddr, sheet: String) -> Bool {
        _sheets[sheet]?.cells[addr]?.spillOrigin != nil
    }

    /// Apply an undo/redo edit to the engine state.
    private func applyEdit(_ edit: Edit, isUndo: Bool) {
        switch edit.change {
        case .setValue(let addr, let sheet, let old, let new):
            let s = sheet ?? _activeSheet
            _sheets[s]?.cells[addr] = CellData(value: isUndo ? old : new)
            let dirtyKeys = markDirtyKeys(sheet: s, addr: addr)
            recalculateInternal(dirty: dirtyKeys)

        case .setFormula(let addr, let sheet, let old, let new):
            let s = sheet ?? _activeSheet
            let key = SheetCellAddr(sheet: s, addr: addr)
            let formula = isUndo ? old : new
            if let f = formula {
                _ = try? graph.setFormula(key, ast: f.ast)
                _sheets[s]?.cells[addr] = CellData(value: .null, formula: f)
                evaluateCell(key)
            } else {
                graph.removeCell(key)
                _sheets[s]?.cells.removeValue(forKey: addr)
            }
            let dirtyKeys = markDirtyKeys(sheet: s, addr: addr)
            recalculateInternal(dirty: dirtyKeys)

        case .clearSheet(let name):
            if isUndo {
                // Can't restore — we lost the content; leave cells empty
            } else {
                _sheets[name]?.cells.removeAll()
                graph.clear()
            }

        case .renameSheet(let old, let new):
            if isUndo {
                renameSheet(from: new, to: old)
            } else {
                renameSheet(from: old, to: new)
            }

        case .insertSheet(let name, let at):
            if isUndo {
                _ = _sheets.removeValue(forKey: name)
                _sheetOrder.removeAll { $0 == name }
            } else {
                _sheets[name] = WorkbookSheet(name: name)
                _sheetOrder.insert(name, at: at)
            }

        case .deleteSheet(let name):
            if isUndo {
                let idx = _sheetOrder.firstIndex { _sheets[$0] != nil } ?? _sheetOrder.count
                _sheets[name] = WorkbookSheet(name: name)
                _sheetOrder.insert(name, at: min(idx, _sheetOrder.count))
            } else {
                _ = _sheets.removeValue(forKey: name)
                _sheetOrder.removeAll { $0 == name }
            }

        case .defineName(let name, _, let new):
            if isUndo {
                _namedRanges.removeValue(forKey: name)
            } else if let nr = new {
                _namedRanges[name] = NamedRange(name: name, range: nr, sheet: nr.sheet)
            }

        case .insertRow, .insertCol, .deleteRow, .deleteCol, .moveRow, .moveCol:
            // Structural edits — trigger full recalc
            recalculate()
        }
    }

}

// MARK: - ColumnSlice extension

extension ColumnSlice {
    /// Build a ColumnSlice from a flat array of Values.
    public static func fromValues(_ values: [Value]) -> ColumnSlice {
        let count = values.count
        var numbers = ContiguousArray<Double?>(repeating: nil, count: count)
        var strings = ContiguousArray<String?>(repeating: nil, count: count)
        var bools = ContiguousArray<Bool?>(repeating: nil, count: count)
        var errors = ContiguousArray<ValueError?>(repeating: nil, count: count)

        for (i, v) in values.enumerated() {
            switch v {
            case .number(let n): numbers[i] = n
            case .string(let s): strings[i] = s
            case .bool(let b): bools[i] = b
            case .error(let e): errors[i] = e
            case .lambda: break  // not a column value
            case .null, .date, .array: break
            }
        }
        return ColumnSlice(numbers: numbers, strings: strings, bools: bools, errors: errors)
    }
}

// MARK: - SheetEngineCore wrapper for evaluation isolation

/// Adapts SheetEngine to `inout SheetEngineCore` for evaluator access.
///
/// Reads go through the engine's UNLOCKED accessors. Evaluation only ever
/// runs with the lock already held (every `evaluator.evaluate` call sits
/// inside a `withLock` body), so taking it again here is both unnecessary
/// and fatal: `lock` is a non-recursive `NSLock`, and the previous version
/// of this wrapper - which called the locked public methods - deadlocked
/// on every formula that read a cell.
private final class EvaluatorBridge: SheetEngineCore {
    // Unowned: the engine owns this bridge for its whole lifetime, so a
    // strong reference back would be a cycle.
    private unowned let engine: SheetEngine

    init(engine: SheetEngine) {
        self.engine = engine
    }

    func getCellValue(_ addr: CellAddr, sheet: String?) throws -> Value {
        engine.getCellValueUnlocked(addr, sheet: sheet)
    }

    func getRangeValues(_ range: RangeRef, fallbackSheet: String) throws -> [Value] {
        // range.sheet wins when the formula qualified it explicitly
        // (`=SUM(Sheet2!A1:B5)`); fallbackSheet - the formula's OWN
        // sheet - only applies to an unqualified range. The prior
        // version hardcoded `sheet: nil` here regardless of range.sheet,
        // so even an explicit qualifier was silently ignored and every
        // range read resolved against the workbook's active sheet.
        engine.getRangeValuesUnlocked(sheet: range.sheet ?? fallbackSheet, range: range)
    }

    func resolveNamedRange(_ name: String, at context: CellAddr, fallbackSheet: String) throws -> Value {
        engine.resolveNamedRangeUnlocked(name, at: context, fallbackSheet: fallbackSheet)
    }
}
