import Foundation

/// A node function. Async + throwing so a node can drive real work (the agent
/// loop, tool dispatch, LLM streaming) — the Linux `NodeFunc` is synchronous.
/// Semantically equivalent: it reads the current state and returns a partial
/// update.
public typealias StateGraphNodeFn = @Sendable (GraphState) async throws -> StateUpdate

/// One node in the graph. Port of the Linux `GraphNode`
/// (StateGraph.h:24-29). The function lives outside the persistable topology
/// (registered by id via ``StateGraphNodeRegistry``) so a graph's structure
/// can be encoded and resumed after relaunch while the node behaviour stays
/// in code.
public struct StateGraphNode: Sendable {
    public let id: String
    public let displayName: String
    public let fn: StateGraphNodeFn
    public let description: String

    public init(id: String, displayName: String, fn: @escaping StateGraphNodeFn, description: String = "") {
        self.id = id
        self.displayName = displayName
        self.fn = fn
        self.description = description
    }
}

/// A conditional edge. The router inspects the state and returns a key; that
/// key is looked up in `branches` to pick the next node. Falls back to
/// `__default__`, then `__end__`. Port of the Linux `ConditionalEdge`
/// (StateGraph.h:31-35).
public struct ConditionalEdge: Sendable {
    public let from: String
    public let router: @Sendable (GraphState) async -> String
    public let branches: [String: String]

    public init(from: String, router: @escaping @Sendable (GraphState) async -> String, branches: [String: String]) {
        self.from = from
        self.router = router
        self.branches = branches
    }
}

/// Normal edge: a direct `from -> to` pair.
public struct StateGraphEdge: Sendable, Equatable, Codable {
    public let from: String
    public let to: String
    public init(from: String, to: String) { self.from = from; self.to = to }
}

/// Streaming event emitted by the executor. Each event carries a full state
/// snapshot (cheap because GraphState is small), mirroring the Linux
/// `WorkflowEvent` (StateGraph.h:38-45).
public enum StateGraphEventType: Sendable, Equatable {
    case started
    case nodeStarted
    case nodeFinished
    case log
    case interrupted
    case checkpoint
    case finished
}

public struct StateGraphEvent: Sendable {
    public let type: StateGraphEventType
    public let nodeId: String
    public let message: String
    public let success: Bool
    public let stateSnapshot: GraphState

    public init(type: StateGraphEventType, nodeId: String = "", message: String = "", success: Bool = true, stateSnapshot: GraphState = [:]) {
        self.type = type
        self.nodeId = nodeId
        self.message = message
        self.success = success
        self.stateSnapshot = stateSnapshot
    }
}

/// Sentinel node id marking the end of a run.
public let stateGraphEnd = "__end__"

/// Sentinel branch key for the default route when no explicit branch matches.
public let stateGraphDefault = "__default__"

/// The graph topology: nodes, edges, entry/finish, interrupt sets, and
/// per-key reducers. Construction mirrors the Linux `StateGraph` builder API
/// (StateGraph.h:81-91). Execution lives in ``StateGraphExecutor``.
public final class StateGraph: @unchecked Sendable {
    public private(set) var nodes: [StateGraphNode] = []
    public private(set) var edges: [StateGraphEdge] = []
    public private(set) var conditionalEdges: [ConditionalEdge] = []
    public private(set) var interruptBefore: Set<String> = []
    public private(set) var interruptAfter: Set<String> = []
    public private(set) var reducers: [String: StateGraphReducer] = [:]
    public private(set) var entryPoint: String = ""
    public private(set) var finishPoint: String = stateGraphEnd
    public let name: String

    public init(name: String = "workflow") {
        self.name = name
    }

    // MARK: construction

    public func addNode(_ id: String, _ displayName: String, _ fn: @escaping StateGraphNodeFn, description: String = "") {
        nodes.append(StateGraphNode(id: id, displayName: displayName, fn: fn, description: description))
    }

    public func addEdge(from: String, to: String) {
        edges.append(StateGraphEdge(from: from, to: to))
    }

    public func addConditionalEdge(from: String, router: @escaping @Sendable (GraphState) async -> String, branches: [String: String]) {
        conditionalEdges.append(ConditionalEdge(from: from, router: router, branches: branches))
    }

    public func setEntryPoint(_ id: String) { entryPoint = id }
    public func setFinishPoint(_ id: String) { finishPoint = id }
    public func interruptBefore(_ nodeIds: [String]) { interruptBefore.formUnion(nodeIds) }
    public func interruptAfter(_ nodeIds: [String]) { interruptAfter.formUnion(nodeIds) }
    public func setReducer(_ key: String, _ reducer: StateGraphReducer) { reducers[key] = reducer }

    /// Validate the topology. Returns a description of the first problem
    /// found, or nil if valid. Port of the Linux `validate`
    /// (StateGraph.cpp:141-164): entry point set and present, no unknown
    /// node/edge references, no cycles over normal + conditional edges.
    public func validate() -> String? {
        if entryPoint.isEmpty { return "no entry point" }
        let ids = Set(nodes.map(\.id))
        if !ids.contains(entryPoint) { return "entry not found: \(entryPoint)" }
        for e in edges {
            if !ids.contains(e.from) { return "edge references unknown node: \(e.from)" }
            if e.to != stateGraphEnd && !ids.contains(e.to) { return "edge references unknown node: \(e.to)" }
        }
        for ce in conditionalEdges where !ids.contains(ce.from) {
            return "conditional edge from unknown: \(ce.from)"
        }
        // cycle check via DFS over normal + conditional adjacency
        var adj: [String: [String]] = [:]
        for e in edges { adj[e.from, default: []].append(e.to) }
        for ce in conditionalEdges { adj[ce.from, default: []].append(contentsOf: ce.branches.values) }
        var visited: Set<String> = []
        var onStack: Set<String> = []
        func dfs(_ u: String) -> String? {
            visited.insert(u); onStack.insert(u)
            for v in adj[u] ?? [] {
                if v == stateGraphEnd { continue }
                if !visited.contains(v) {
                    if let err = dfs(v) { return err }
                } else if onStack.contains(v) {
                    return "cycle detected at \(v)"
                }
            }
            onStack.remove(u)
            return nil
        }
        for n in nodes where !visited.contains(n.id) {
            if let err = dfs(n.id) { return err }
        }
        return nil
    }
}
