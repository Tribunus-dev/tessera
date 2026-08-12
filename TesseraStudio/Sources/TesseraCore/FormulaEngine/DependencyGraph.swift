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
    public let cycle: [CellAddr]

    public var description: String {
        let path = cycle.map { $0.description }.joined(separator: " -> ")
        return "Circular reference detected: \(path)"
    }
}

/// Bidirectional dependency graph.
/// Manages cell-to-precedent and cell-to-dependent edges for incremental recalculation.
public final class DependencyGraph: @unchecked Sendable {
    /// Set of cell addresses — factored out to avoid nested-`>` generic syntax.
    private typealias AddrSet = Set<CellAddr>

    /// Forward edges: cell → cells it depends on (precedents)
    private var precedents: [CellAddr: AddrSet] = [:]
    /// Reverse edges: cell → cells that depend on it (dependents)
    private var dependents: [CellAddr: AddrSet] = [:]
    /// Formula ASTs for each cell
    private var formulaASTs: [CellAddr: FormulaAST] = [:]
    /// Cells that contain volatile functions (NOW, RAND, etc.)
    private var volatileCells: Set<CellAddr> = []

    public init() {}

    // MARK: - Mutation

    /// Set or update a formula for a cell. Updates edges and detects cycles.
    /// - Throws: CycleError if the new formula creates a dependency cycle.
    public func setFormula(_ addr: CellAddr, ast: FormulaAST) throws {
        // Remove existing edges for this cell
        removeEdges(for: addr)

        // Store the AST
        formulaASTs[addr] = ast

        // Collect new precedents
        let newPrecedents = collectPrecedents(from: ast)

        // Check for cycles
        if wouldCreateCycle(from: addr, newPrecedents: newPrecedents) {
            formulaASTs.removeValue(forKey: addr)
            throw CycleError(cycle: buildCycle(from: addr, newPrecedents: newPrecedents))
        }

        // Add forward edges
        precedents[addr] = newPrecedents

        // Add reverse edges (dependents)
        for precedent in newPrecedents {
            if dependents[precedent] == nil { dependents[precedent] = Set() }
            dependents[precedent]!.insert(addr)
        }

        // Track volatile functions
        if ast.containsVolatileFunction {
            volatileCells.insert(addr)
        } else {
            volatileCells.remove(addr)
        }
    }

    /// Remove a cell and all its edges.
    public func removeCell(_ addr: CellAddr) {
        removeEdges(for: addr)
        formulaASTs.removeValue(forKey: addr)
        volatileCells.remove(addr)
    }

    /// Clear the entire graph.
    public func clear() {
        precedents.removeAll()
        dependents.removeAll()
        formulaASTs.removeAll()
        volatileCells.removeAll()
    }

    private func removeEdges(for addr: CellAddr) {
        // Remove from dependents' precedent lists
        if let preds = precedents[addr] {
            for pred in preds {
                dependents[pred]?.remove(addr)
                if dependents[pred]?.isEmpty == true { dependents.removeValue(forKey: pred) }
            }
        }
        precedents.removeValue(forKey: addr)

        // Remove from precedents' dependent lists
        if let deps = dependents[addr] {
            for dep in deps {
                precedents[dep]?.remove(addr)
                if precedents[dep]?.isEmpty == true { precedents.removeValue(forKey: dep) }
            }
        }
        dependents.removeValue(forKey: addr)
    }

    private func collectPrecedents(from ast: FormulaAST) -> Set<CellAddr> {
        var result = Set<CellAddr>()
        for cell in ast.collectCells() {
            result.insert(cell.addr)
        }
        for range in ast.collectRanges() {
            for addr in range.cells() { result.insert(addr) }
        }
        return result
    }

    private func wouldCreateCycle(from addr: CellAddr, newPrecedents: Set<CellAddr>) -> Bool {
        // If any of the new precedents transitively depend on addr, it's a cycle
        return hasPath(from: addr, to: addr, via: newPrecedents)
    }

    private func hasPath(from source: CellAddr, to target: CellAddr, via directPrecedents: Set<CellAddr>) -> Bool {
        // DFS from each new precedent to see if we can reach `source`
        var visited = Set<CellAddr>()
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

    private func buildCycle(from addr: CellAddr, newPrecedents: Set<CellAddr>) -> [CellAddr] {
        // Build the cycle path: addr ← ... ← precedent ← addr
        var cycle = [addr]
        var current = addr
        var visited = Set<CellAddr>([addr])

        // Find a precedent that leads back to addr
        var queue = Array(newPrecedents)
        var parent: [CellAddr: CellAddr] = [:]

        while !queue.isEmpty {
            let node = queue.removeFirst()
            if node == addr {
                // Reconstruct
                var path = [addr]
                var cur: CellAddr? = node
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

        return [addr]
    }

    // MARK: - Queries

    /// Topological sort of all cells, or of a specified set of roots.
    /// - Throws: CycleError if a cycle exists in the subgraph.
    public func evaluationOrder(from roots: [CellAddr]? = nil) throws -> [CellAddr] {
        // Kahn's algorithm
        var inDegree: [CellAddr: Int] = [:]
        var allNodes: Set<CellAddr> = []

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

        var queue: [CellAddr] = allNodes.filter { inDegree[$0] == 0 }
        var result: [CellAddr] = []

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

    private func collectAllDependents(of addr: CellAddr, into set: inout Set<CellAddr>) {
        guard let deps = dependents[addr] else { return }
        for dep in deps {
            if !set.contains(dep) {
                set.insert(dep)
                collectAllDependents(of: dep, into: &set)
            }
        }
    }

    private func buildFullCycle(starting from: CellAddr) -> [CellAddr] {
        var visited = Set<CellAddr>()
        var path: [CellAddr] = []
        var current: CellAddr? = from

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
    public func dirtySubgraph(from dirty: Set<CellAddr>) -> Set<CellAddr> {
        var result = Set<CellAddr>()
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
    public func allDependents(of addr: CellAddr) -> Set<CellAddr> {
        dirtySubgraph(from: [addr])
    }

    /// Get all cells that a cell depends on (direct precedents).
    public func directPrecedents(of addr: CellAddr) -> Set<CellAddr> {
        precedents[addr] ?? []
    }

    /// Get all cells that depend on a cell (direct dependents).
    public func directDependents(of addr: CellAddr) -> Set<CellAddr> {
        dependents[addr] ?? []
    }

    /// Get the formula AST for a cell.
    public func formulaAST(for addr: CellAddr) -> FormulaAST? {
        formulaASTs[addr]
    }

    /// Get all cells with formulas.
    public var formulaCells: [CellAddr] {
        Array(formulaASTs.keys)
    }

    /// All tracked cells (with formulas).
    public var allCells: Set<CellAddr> {
        Set(precedents.keys)
    }

    /// Cells containing volatile functions.
    public var volatile: Set<CellAddr> { volatileCells }

    /// Check if a cell is volatile.
    public func isVolatile(_ addr: CellAddr) -> Bool {
        volatileCells.contains(addr)
    }

    /// Full dirty propagation when any volatile function is triggered.
    /// Marks ALL volatile cells as dirty (they can change without their inputs changing).
    public func markAllVolatileDirty(_ dirty: inout Set<CellAddr>) {
        dirty.formUnion(volatileCells)
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

    public func serialized(root: CellAddr? = nil, depth: Int = 1) -> SerializedGraph {
        var nodesToInclude = Set<CellAddr>()
        var nodesSet = Set<CellAddr>()

        if let root = root {
            // BFS from root to depth
            var queue: [(CellAddr, Int)] = [(root, 0)]
            while !queue.isEmpty {
                let (addr, d) = queue.removeFirst()
                if d > depth { continue }
                nodesToInclude.insert(addr)
                if let deps = dependents[addr] {
                    for dep in deps { queue.append((dep, d + 1)) }
                }
                if let preds = precedents[addr] {
                    for pred in preds { queue.append((pred, d + 1)) }
                }
            }
            nodesSet = nodesToInclude
        } else {
            nodesSet = Set(formulaASTs.keys)
        }

        let nodes = nodesSet.map { addr in
            SerializedGraph.Node(
                addr: addr.description,
                hasFormula: formulaASTs[addr] != nil,
                isVolatile: volatileCells.contains(addr)
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
