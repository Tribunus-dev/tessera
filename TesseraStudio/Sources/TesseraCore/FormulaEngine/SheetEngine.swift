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

    init(value: Value = .null, formula: Formula? = nil) {
        self.rawValue = value
        self.formula = formula
    }
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
            // Remove all graph edges for this sheet's cells
            let cellsToRemove = graph.allCells.filter { cell in
                // Cells on this sheet
                true // filter by sheet once we add sheet tracking
            }
            graph.clear()
            // Rebuild from remaining sheets
            rebuildGraphFromCells()
        }
    }

    /// Rename a sheet.
    public func renameSheet(from old: String, to new: String) -> Bool {
        withLock {
            guard _sheets[old] != nil, _sheets[new] == nil else { return false }
            var sheet = _sheets.removeValue(forKey: old)!
            sheet = WorkbookSheet(name: new)
            _sheets[new] = sheet
            if let idx = _sheetOrder.firstIndex(of: old) {
                _sheetOrder[idx] = new
            }
            if _activeSheet == old { _activeSheet = new }
            return true
        }
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
            _sheets[effectiveSheet]?.cells[addr] = CellData(value: value)

            // Mark dependents dirty and recalculate
            let dirty = markDirty(sheet: effectiveSheet, addr: addr)
            recalculateInternal(dirty: dirty, sheet: effectiveSheet)
            return dirty
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
            guard _sheets[effectiveSheet] != nil else { return [] }

            // Parse
            let parser = try FormulaParser(source: source)
            let result = try parser.parse()

            switch result {
            case .value(let constant):
                // No dependency tracking needed — store as a plain value
                _sheets[effectiveSheet]?.cells[addr] = CellData(value: constant)
                let dirty = markDirty(sheet: effectiveSheet, addr: addr)
                recalculateInternal(dirty: dirty, sheet: effectiveSheet)
                return dirty

            case .formula(let formula):
                // Cycle-safe graph insertion
                try graph.setFormula(addr, ast: formula.ast)

                // Evaluate and cache
                let evaluated = try evaluator.evaluate(formula.ast, at: addr, engine: self)
                _sheets[effectiveSheet]?.cells[addr] = CellData(value: evaluated, formula: formula)

                // Push undo step
                let edit = Edit(change: .setFormula(
                    addr: addr, sheet: effectiveSheet,
                    old: _sheets[effectiveSheet]?.cells[addr]?.formula,
                    new: formula
                ))
                undoStack.push(edit)

                // Recalculate downstream
                let dirty = markDirty(sheet: effectiveSheet, addr: addr)
                recalculateInternal(dirty: dirty, sheet: effectiveSheet)
                return dirty
            }
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
            _sheets[effectiveSheet]?.cells.removeValue(forKey: addr)
            graph.removeCell(addr)
        }
    }

    // MARK: - Range API

    /// Get all values in a range as a flat array (row-major).
    public func getRangeValues(sheet: String?, range: RangeRef) -> [Value] {
        let effectiveSheet = sheet ?? _activeSheet
        return withLock {
            guard let sheetData = _sheets[effectiveSheet] else { return [] }
            var result: [Value] = []
            for addr in range.cells() {
                result.append(sheetData.cells[addr]?.rawValue ?? .null)
            }
            return result
        }
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

    /// All defined names in the workbook.
    public var namedRanges: [String: NamedRange] {
        withLock { _namedRanges }
    }

    /// Define a name bound to a range. Fails if the name already exists.
    public func defineName(_ name: String, range: RangeRef, sheet: String? = nil) -> Bool {
        withLock {
            guard _namedRanges[name] == nil else { return false }
            _namedRanges[name] = NamedRange(name: name, range: range, sheet: sheet)
            return true
        }
    }

    /// Remove a named range.
    public func undefineName(_ name: String) {
        withLock {
            _namedRanges.removeValue(forKey: name)
        }
    }

    /// Resolve a named range to its value (called by the evaluator).
    private func namedRangeResolver(_ name: String, at context: CellAddr) throws -> Value {
        withLock {
            guard let nr = _namedRanges[name] else { return .error(.nameInvalid) }
            let effectiveSheet = nr.sheet ?? _activeSheet
            guard let sheetData = _sheets[effectiveSheet] else { return .error(.referenceInvalid) }
            let vals = nr.range.cells().map { sheetData.cells[$0]?.rawValue ?? .null }
            if vals.count == 1 { return vals[0] }
            return .array(rows: nr.range.height, cols: nr.range.width, flat: vals)
        }
    }

    // MARK: - Recalculation

    /// Full recalculation of all formula cells.
    public func recalculate() {
        withLock {
            recalculateInternal(dirty: graph.allCells, sheet: nil)
        }
    }

    /// Incremental recalculation from a dirty root.
    public func recalculateIncremental(from addr: CellAddr) {
        withLock {
            let dirty = graph.dirtySubgraph(from: [addr])
            recalculateInternal(dirty: dirty, sheet: nil)
        }
    }

    /// Force-mark a cell as dirty (e.g. a volatile function was triggered).
    public func markDirty(addr: CellAddr) -> Set<CellAddr> {
        withLock {
            var dirty = Set<CellAddr>([addr])
            graph.markAllVolatileDirty(&dirty)
            return graph.dirtySubgraph(from: dirty)
        }
    }

    /// Evaluate all formula cells and return a map of addr → result.
    /// Use this for export / checkpointing.
    public func evaluateAll() -> [CellAddr: Value] {
        withLock {
            var results: [CellAddr: Value] = [:]
            for addr in graph.formulaCells {
                if let data = currentCellData(addr) {
                    results[addr] = data.rawValue
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
            applyEdit(edit, isUndo: true)
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
        let effectiveSheet = sheet ?? _activeSheet
        return withLock {
            _sheets[effectiveSheet]?.cells[addr]?.rawValue ?? .null
        }
    }

    public func getRangeValues(_ range: RangeRef) throws -> [Value] {
        getRangeValues(sheet: nil, range: range)
    }

    public func resolveNamedRange(_ name: String, at context: CellAddr) throws -> Value {
        try namedRangeResolver(name, at: context)
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
            let nrMap = Dictionary(
                uniqueKeysWithValues: _namedRanges.map { (name, nr) -> (String, [String: Any]) in
                    (name, [
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

    /// Mark a cell and its dependents as dirty, returning the dirty set.
    private func markDirty(sheet: String, addr: CellAddr) -> Set<CellAddr> {
        let dirty = Set<CellAddr>([addr])
        return graph.dirtySubgraph(from: dirty)
    }

    /// Internal recalculation over a pre-computed dirty set.
    /// Must be called while holding lock.
    private func recalculateInternal(dirty: Set<CellAddr>, sheet: String?) {
        guard !dirty.isEmpty else { return }

        // Mark volatile cells as dirty too (NOW, RAND, etc. can change any time)
        var mutableDirty = dirty
        graph.markAllVolatileDirty(&mutableDirty)
        let subgraph = graph.dirtySubgraph(from: mutableDirty)

        guard !subgraph.isEmpty else { return }

        do {
            let order = try graph.evaluationOrder(from: Array(subgraph))
            for addr in order {
                evaluateCell(addr)
            }
        } catch {
            // Cycle error — leave cells in their previous state, mark the
            // root cell with an error value
            for addr in dirty {
                var mutableSelf = self
                _sheets[sheet ?? _activeSheet]?.cells[addr]?.rawValue = .error(.referenceInvalid)
            }
        }
    }

    /// Evaluate a single formula cell and cache the result.
    /// Must be called while holding lock.
    private func evaluateCell(_ addr: CellAddr) {
        guard let ast = graph.formulaAST(for: addr) else { return }
        guard let cell = _sheets[_activeSheet]?.cells[addr] else { return }

        do {
            let result = try evaluator.evaluate(ast, at: addr, engine: self)
            _sheets[_activeSheet]?.cells[addr] = CellData(value: result, formula: cell.formula)
        } catch {
            _sheets[_activeSheet]?.cells[addr] = CellData(value: .error(.referenceInvalid), formula: cell.formula)
        }
    }

    private func currentCellData(_ addr: CellAddr) -> CellData? {
        _sheets[_activeSheet]?.cells[addr]
    }

    /// Apply an undo/redo edit to the engine state.
    private func applyEdit(_ edit: Edit, isUndo: Bool) {
        switch edit.change {
        case .setValue(let addr, let sheet, let old, let new):
            let s = sheet ?? _activeSheet
            _sheets[s]?.cells[addr] = CellData(value: isUndo ? old : new)
            let dirty = markDirty(sheet: s, addr: addr)
            recalculateInternal(dirty: dirty, sheet: s)

        case .setFormula(let addr, let sheet, let old, let new):
            let s = sheet ?? _activeSheet
            let formula = isUndo ? old : new
            if let f = formula {
                _ = try? graph.setFormula(addr, ast: f.ast)
                _sheets[s]?.cells[addr] = CellData(value: .null, formula: f)
                evaluateCell(addr)
            } else {
                graph.removeCell(addr)
                _sheets[s]?.cells.removeValue(forKey: addr)
            }
            let dirty = markDirty(sheet: s, addr: addr)
            recalculateInternal(dirty: dirty, sheet: s)

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

    /// Rebuild the dependency graph from all stored formulas.
    /// Called after structural edits that clear the graph.
    private func rebuildGraphFromCells() {
        for (_, sheet) in _sheets {
            for (addr, data) in sheet.cells {
                if let formula = data.formula {
                    try? graph.setFormula(addr, ast: formula.ast)
                }
            }
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
            case .null, .date, .array: break
            }
        }
        return ColumnSlice(numbers: numbers, strings: strings, bools: bools, errors: errors)
    }
}

// MARK: - SheetEngineCore wrapper for evaluation isolation

/// Adapts SheetEngine to `inout SheetEngineCore` for safe evaluator access.
/// The evaluator requires `inout` access; this wrapper locks on each access.
private final class EvaluatorBridge: SheetEngineCore {
    private let engine: SheetEngine

    init(engine: SheetEngine) {
        self.engine = engine
    }

    func getCellValue(_ addr: CellAddr, sheet: String?) throws -> Value {
        try engine.getCellValue(addr, sheet: sheet)
    }

    func getRangeValues(_ range: RangeRef) throws -> [Value] {
        try engine.getRangeValues(sheet: nil, range: range)
    }

    func resolveNamedRange(_ name: String, at context: CellAddr) throws -> Value {
        try engine.resolveNamedRange(name, at: context)
    }
}
