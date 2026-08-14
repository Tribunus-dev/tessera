//===----------------------------------------------------------------------===//
//  DependencyGraph.swift
//  Tessera Formula Engine
//
//  Bidirectional dependency graph for incremental recalculation.
//  Forward edges: cell → its precedents (what it depends on)
//  Reverse edges: cell → its dependents (what depends on it)
//===----------------------------------------------------------------------===//

import Foundation

public struct CycleError: Error, CustomStringConvertible {
    public let cycle: [SheetCellAddr]

    public var description: String {
        let path = cycle.map { $0.description }.joined(separator: " -> ")
        return "Circular reference detected: \(path)"
    }
}

// MARK: - SheetCellAddr

/// A cell address qualified by sheet - the graph's real node identity.
///
/// `CellAddr` alone (col, row) is not unique across a workbook: Sheet1!A1
/// and Sheet2!A1 are the same `CellAddr`. Every graph node, edge, and
/// query is keyed on the pair, not the bare address, so cells on
/// different sheets never collide and a cross-sheet formula's precedent
/// edge lands on the sheet it actually reads.
public struct SheetCellAddr: Hashable, Sendable, CustomStringConvertible {
    public let sheet: String
    public let addr: CellAddr

    public init(sheet: String, addr: CellAddr) {
        self.sheet = sheet
        self.addr = addr
    }

    public var description: String { "\(sheet)!\(addr.description)" }
}

// MARK: - RecalcState

/// A formula cell's freshness relative to its own precedents.
///
/// Formalizes what recalculation already tracked implicitly (a cell
/// was "dirty" exactly when it appeared in a `dirtySubgraph` BFS
/// result, "clean" by simply being absent) as an explicit, queryable
/// per-cell state - the recalculation ALGORITHM (dirty-cone BFS +
/// Kahn's-algorithm topological evaluation order, in
/// `SheetEngine.recalculateInternal`) is unchanged; this only exposes
/// its state so a caller can ask "is this cell stale right now"
/// without re-running a BFS.
///
/// Not tracked for plain-value cells: a literal's value is
/// definitionally always current the instant it's written, so "needs
/// recalculating" has no meaning for it - only a formula can be stale
/// relative to its precedents. `DependencyGraph.recalcState(for:)`
/// reports `.clean` for any untracked cell, which is correct for both
/// "no formula" and "formula, never touched by a recalculation" -
/// `SheetEngine.setFormulaUnlocked` always evaluates a new formula
/// synchronously before returning, so a cell is never observably dirty
/// from outside the lock.
public enum RecalcState: Sendable, Equatable {
    case clean
    case dirty
}

/// Bidirectional dependency graph.
/// Manages cell-to-precedent and cell-to-dependent edges for incremental recalculation.
public final class DependencyGraph: @unchecked Sendable {
    /// Set of qualified cell addresses — factored out to avoid nested-`>` generic syntax.
    private typealias AddrSet = Set<SheetCellAddr>

    /// Forward edges: cell → cells it depends on (precedents)
    private var precedents: [SheetCellAddr: AddrSet] = [:]
    /// Reverse edges: cell → cells that depend on it (dependents)
    private var dependents: [SheetCellAddr: AddrSet] = [:]
    /// Formula ASTs for each cell
    private var formulaASTs: [SheetCellAddr: FormulaAST] = [:]
    /// Cells that contain volatile functions (NOW, RAND, etc.)
    private var volatileCells: Set<SheetCellAddr> = []
    /// Explicit dirty/clean state for formula cells - see `RecalcState`.
    private var recalcStates: [SheetCellAddr: RecalcState] = [:]

    public init() {}

    // MARK: - Mutation

    /// Set or update a formula for a cell. Updates edges and detects cycles.
    ///
    /// A `CellRef`/`RangeRef` inside the AST with `sheet == nil` means
    /// "same sheet as the formula's own cell" - `key.sheet` resolves it,
    /// so `=A1` in a formula living on Sheet2 records a precedent edge on
    /// Sheet2!A1, and `=Sheet1!A1` records one on Sheet1!A1 regardless of
    /// where the formula itself lives.
    ///
    /// - Throws: CycleError if the new formula creates a dependency cycle.
    public func setFormula(_ key: SheetCellAddr, ast: FormulaAST) throws {
        // Only this cell's own precedents; the cells reading it keep
        // depending on it.
        removePrecedentEdges(for: key)

        // Store the AST
        formulaASTs[key] = ast

        // Collect new precedents, resolved against this cell's own sheet.
        let newPrecedents = collectPrecedents(from: ast, currentSheet: key.sheet)

        // Check for cycles
        if wouldCreateCycle(from: key, newPrecedents: newPrecedents) {
            formulaASTs.removeValue(forKey: key)
            throw CycleError(cycle: buildCycle(from: key, newPrecedents: newPrecedents))
        }

        // Add forward edges
        precedents[key] = newPrecedents

        // Add reverse edges (dependents)
        for precedent in newPrecedents {
            if dependents[precedent] == nil { dependents[precedent] = Set() }
            dependents[precedent]!.insert(key)
        }

        // Track volatile functions
        if ast.containsVolatileFunction {
            volatileCells.insert(key)
        } else {
            volatileCells.remove(key)
        }
    }

    /// Drop `key`'s formula and the edges to the cells it read, while
    /// keeping the cells that read IT - the address still exists and now
    /// holds a plain value.
    ///
    /// Typing a value over a formula must go through this. Without it the
    /// AST stayed in the graph, the next recalculation re-evaluated the
    /// old formula, and the typed value was silently thrown away.
    public func clearFormula(_ key: SheetCellAddr) {
        removePrecedentEdges(for: key)
        formulaASTs.removeValue(forKey: key)
        volatileCells.remove(key)
        recalcStates.removeValue(forKey: key)
    }

    /// Remove a cell and all its edges.
    public func removeCell(_ key: SheetCellAddr) {
        removeEdges(for: key)
        formulaASTs.removeValue(forKey: key)
        volatileCells.remove(key)
        recalcStates.removeValue(forKey: key)
    }

    /// Remove every node belonging to one sheet (deleting a sheet) without
    /// disturbing any other sheet's graph state.
    public func removeSheet(_ sheet: String) {
        // allCells (== precedents.keys) misses a plain-value cell that
        // is never a formula OWNER but is still a formula TARGET
        // elsewhere - it exists only as a value inside some other
        // cell's precedent set and as a key in `dependents`, never as a
        // key in `precedents`. Skipping it left a permanent dangling
        // edge toward a sheet that no longer exists, which years later
        // could throw a false-positive CycleError if a sheet by the
        // same name was ever recreated (hasPath walks the stale edge
        // and "finds" a cycle that was never really there).
        var toRemove = Set<SheetCellAddr>()
        for key in precedents.keys where key.sheet == sheet { toRemove.insert(key) }
        for key in dependents.keys where key.sheet == sheet { toRemove.insert(key) }
        for key in toRemove {
            removeEdges(for: key)
            formulaASTs.removeValue(forKey: key)
            volatileCells.remove(key)
            recalcStates.removeValue(forKey: key)
        }
    }

    /// Rewrite every node/edge on `old` to live under `new` (renaming a
    /// sheet). Cross-sheet edges pointing AT the renamed sheet from
    /// elsewhere are rewritten too, so a formula on another sheet that
    /// reads the renamed one keeps its edge instead of dangling.
    /// The caller (SheetEngine.renameSheet) already guards that `new`
    /// names no existing sheet, so this never collides through that
    /// path today. This method is public with no guard of its own,
    /// though, so `uniquingKeysWith:` - keep the later value, arbitrary
    /// but deterministic - stands in for `uniqueKeysWithValues:`, which
    /// traps the process outright if a future caller ever renames onto
    /// an existing sheet name.
    public func renameSheet(from old: String, to new: String) {
        func rekey(_ key: SheetCellAddr) -> SheetCellAddr {
            key.sheet == old ? SheetCellAddr(sheet: new, addr: key.addr) : key
        }
        precedents = Dictionary(precedents.map { (rekey($0.key), Set($0.value.map(rekey))) },
                                 uniquingKeysWith: { $1 })
        dependents = Dictionary(dependents.map { (rekey($0.key), Set($0.value.map(rekey))) },
                                 uniquingKeysWith: { $1 })
        formulaASTs = Dictionary(formulaASTs.map { (rekey($0.key), $0.value) },
                                  uniquingKeysWith: { $1 })
        volatileCells = Set(volatileCells.map(rekey))
        recalcStates = Dictionary(recalcStates.map { (rekey($0.key), $0.value) },
                                   uniquingKeysWith: { $1 })
    }

    /// Clear the entire graph (every sheet).
    public func clear() {
        precedents.removeAll()
        dependents.removeAll()
        formulaASTs.removeAll()
        volatileCells.removeAll()
        recalcStates.removeAll()
    }

    /// Drop only the OUTGOING edges: the cells `key` reads.
    ///
    /// Re-setting a cell's formula replaces what it reads, not who reads
    /// it. Incoming edges must survive - dropping them meant that the
    /// moment a referenced cell's formula was re-set, every cell reading
    /// it silently stopped depending on it, which disabled both cycle
    /// detection and incremental recalculation.
    private func removePrecedentEdges(for key: SheetCellAddr) {
        if let preds = precedents[key] {
            for pred in preds {
                dependents[pred]?.remove(key)
                if dependents[pred]?.isEmpty == true { dependents.removeValue(forKey: pred) }
            }
        }
        precedents.removeValue(forKey: key)
    }

    /// Drop every edge touching `key`, incoming and outgoing. Only for
    /// removing the cell itself; see `removePrecedentEdges` for the
    /// re-set-a-formula path.
    private func removeEdges(for key: SheetCellAddr) {
        removePrecedentEdges(for: key)

        // Remove from precedents' dependent lists
        if let deps = dependents[key] {
            for dep in deps {
                precedents[dep]?.remove(key)
                if precedents[dep]?.isEmpty == true { precedents.removeValue(forKey: dep) }
            }
        }
        dependents.removeValue(forKey: key)
    }

    private func collectPrecedents(from ast: FormulaAST, currentSheet: String) -> Set<SheetCellAddr> {
        var result = Set<SheetCellAddr>()
        for cell in ast.collectCells() {
            result.insert(SheetCellAddr(sheet: cell.sheet ?? currentSheet, addr: cell.addr))
        }
        for range in ast.collectRanges() {
            let sheet = range.sheet ?? currentSheet
            for addr in range.cells() { result.insert(SheetCellAddr(sheet: sheet, addr: addr)) }
        }
        return result
    }

    private func wouldCreateCycle(from key: SheetCellAddr, newPrecedents: Set<SheetCellAddr>) -> Bool {
        // If any of the new precedents transitively depend on key, it's a cycle
        return hasPath(from: key, to: key, via: newPrecedents)
    }

    private func hasPath(from source: SheetCellAddr, to target: SheetCellAddr, via directPrecedents: Set<SheetCellAddr>) -> Bool {
        // DFS from each new precedent to see if we can reach `source`
        var visited = Set<SheetCellAddr>()
        var stack = Array(directPrecedents)

        while !stack.isEmpty {
            let current = stack.removeLast()
            if current == target { return true }
            if visited.contains(current) { continue }
            visited.insert(current)
            if let preds = precedents[current] {
                stack.append(contentsOf: preds)
            }
        }
        return false
    }

    private func buildCycle(from key: SheetCellAddr, newPrecedents: Set<SheetCellAddr>) -> [SheetCellAddr] {
        // Build the cycle path: key ← ... ← precedent ← key
        var current = key
        _ = current
        var visited = Set<SheetCellAddr>([key])

        // Find a precedent that leads back to key
        var queue = Array(newPrecedents)
        var parent: [SheetCellAddr: SheetCellAddr] = [:]

        while !queue.isEmpty {
            let node = queue.removeFirst()
            if node == key {
                // Reconstruct
                var path = [key]
                var cur: SheetCellAddr? = node
                while let c = cur {
                    cur = parent[c]
                    if let cc = cur { path.append(cc) }
                }
                return path.reversed()
            }
            if visited.contains(node) { continue }
            visited.insert(node)
            if let preds = precedents[node] {
                for pred in preds {
                    parent[pred] = node
                    queue.append(pred)
                }
            }
        }

        return [key]
    }

    // MARK: - Queries

    /// Topological sort of all cells, or of a specified set of roots.
    /// - Throws: CycleError if a cycle exists in the subgraph.
    public func evaluationOrder(from roots: [SheetCellAddr]? = nil) throws -> [SheetCellAddr] {
        // Kahn's algorithm
        var inDegree: [SheetCellAddr: Int] = [:]
        var allNodes: Set<SheetCellAddr> = []

        if let roots = roots {
            allNodes = Set(roots)
            for root in roots { collectAllDependents(of: root, into: &allNodes) }
        } else {
            allNodes = Set(precedents.keys)
        }

        // Initialize in-degrees
        for node in allNodes {
            let directPrecedents = precedents[node]?.filter { allNodes.contains($0) } ?? []
            inDegree[node] = directPrecedents.count
        }

        var queue: [SheetCellAddr] = allNodes.filter { inDegree[$0] == 0 }
        var result: [SheetCellAddr] = []

        while !queue.isEmpty {
            let node = queue.removeFirst()
            result.append(node)

            // Find all dependents
            let deps = dependents[node]?.filter { allNodes.contains($0) } ?? []
            for dep in deps {
                inDegree[dep]! -= 1
                if inDegree[dep] == 0 {
                    queue.append(dep)
                }
            }
        }

        if result.count != allNodes.count {
            // Cycle detected — find it
            let remaining = allNodes.subtracting(Set(result))
            let cycleStart = remaining.first!
            let cycle = buildFullCycle(starting: cycleStart)
            throw CycleError(cycle: cycle)
        }

        return result
    }

    private func collectAllDependents(of key: SheetCellAddr, into set: inout Set<SheetCellAddr>) {
        guard let deps = dependents[key] else { return }
        for dep in deps {
            if !set.contains(dep) {
                set.insert(dep)
                collectAllDependents(of: dep, into: &set)
            }
        }
    }

    private func buildFullCycle(starting from: SheetCellAddr) -> [SheetCellAddr] {
        var visited = Set<SheetCellAddr>()
        var path: [SheetCellAddr] = []
        var current: SheetCellAddr? = from

        while let c = current {
            if visited.contains(c) {
                // Found cycle start
                if let idx = path.firstIndex(of: c) {
                    return Array(path[idx...])
                }
                return path
            }
            visited.insert(c)
            path.append(c)
            // Follow reverse edge (any dependent that also has this as precedent)
            current = dependents[c]?.first { precedents[$0]?.contains(c) == true }
        }

        return path
    }

    /// BFS propagation from dirty cells to all downstream dependents.
    /// Returns the complete dirty subgraph.
    public func dirtySubgraph(from dirty: Set<SheetCellAddr>) -> Set<SheetCellAddr> {
        var result = Set<SheetCellAddr>()
        var queue = Array(dirty)

        while !queue.isEmpty {
            let cell = queue.removeFirst()
            if result.contains(cell) { continue }
            result.insert(cell)

            // Propagate to dependents
            if let deps = dependents[cell] {
                queue.append(contentsOf: deps)
            }
        }

        return result
    }

    /// Get all cells that depend (directly or transitively) on a cell.
    public func allDependents(of key: SheetCellAddr) -> Set<SheetCellAddr> {
        dirtySubgraph(from: [key])
    }

    /// Get all cells that a cell depends on (direct precedents).
    public func directPrecedents(of key: SheetCellAddr) -> Set<SheetCellAddr> {
        precedents[key] ?? []
    }

    /// Get all cells that depend on a cell (direct dependents).
    public func directDependents(of key: SheetCellAddr) -> Set<SheetCellAddr> {
        dependents[key] ?? []
    }

    /// Get the formula AST for a cell.
    public func formulaAST(for key: SheetCellAddr) -> FormulaAST? {
        formulaASTs[key]
    }

    /// Get all cells with formulas.
    public var formulaCells: [SheetCellAddr] {
        Array(formulaASTs.keys)
    }

    /// All tracked cells (with formulas), across every sheet.
    public var allCells: Set<SheetCellAddr> {
        Set(precedents.keys)
    }

    /// Cells containing volatile functions.
    public var volatile: Set<SheetCellAddr> { volatileCells }

    /// Check if a cell is volatile.
    public func isVolatile(_ key: SheetCellAddr) -> Bool {
        volatileCells.contains(key)
    }

    /// Full dirty propagation when any volatile function is triggered.
    /// Marks ALL volatile cells as dirty (they can change without their inputs changing).
    public func markAllVolatileDirty(_ dirty: inout Set<SheetCellAddr>) {
        dirty.formUnion(volatileCells)
    }

    // MARK: - RecalcState queries

    /// A formula cell's current freshness. `.clean` for anything not
    /// tracked - see `RecalcState`.
    public func recalcState(for key: SheetCellAddr) -> RecalcState {
        recalcStates[key] ?? .clean
    }

    /// Mark every FORMULA cell in `keys` dirty, ahead of a
    /// recalculation pass over them. Plain-value cells (no formula) are
    /// silently skipped - see `RecalcState`.
    public func markCellsDirty<S: Sequence>(_ keys: S) where S.Element == SheetCellAddr {
        for key in keys where formulaASTs[key] != nil {
            recalcStates[key] = .dirty
        }
    }

    /// Mark one formula cell clean - called once it has been freshly
    /// evaluated against its current precedents.
    public func markCellClean(_ key: SheetCellAddr) {
        recalcStates[key] = .clean
    }

    // MARK: - Serialization (for debugging / MCP)

    public struct SerializedGraph: Codable, Sendable {
        public struct Node: Codable, Sendable {
            public let addr: String
            public let hasFormula: Bool
            public let isVolatile: Bool
        }
        public struct Edge: Codable, Sendable {
            public let from: String
            public let to: String
        }
        public let nodes: [Node]
        public let edges: [Edge]
    }

    public func serialized(root: SheetCellAddr? = nil, depth: Int = 1) -> SerializedGraph {
        var nodesToInclude = Set<SheetCellAddr>()
        var nodesSet = Set<SheetCellAddr>()

        if let root = root {
            // BFS from root to depth
            var queue: [(SheetCellAddr, Int)] = [(root, 0)]
            while !queue.isEmpty {
                let (key, d) = queue.removeFirst()
                if d > depth { continue }
                nodesToInclude.insert(key)
                if let deps = dependents[key] {
                    for dep in deps { queue.append((dep, d + 1)) }
                }
                if let preds = precedents[key] {
                    for pred in preds { queue.append((pred, d + 1)) }
                }
            }
            nodesSet = nodesToInclude
        } else {
            nodesSet = Set(formulaASTs.keys)
        }

        let nodes = nodesSet.map { key in
            SerializedGraph.Node(
                addr: key.description,
                hasFormula: formulaASTs[key] != nil,
                isVolatile: volatileCells.contains(key)
            )
        }

        var edges: [SerializedGraph.Edge] = []
        for (from, preds) in precedents where nodesSet.contains(from) {
            for pred in preds where nodesSet.contains(pred) {
                edges.append(SerializedGraph.Edge(from: pred.description, to: from.description))
            }
        }

        return SerializedGraph(nodes: nodes, edges: edges)
    }
}
