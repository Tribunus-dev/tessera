import Foundation

/// Registry of node functions keyed by id, so a graph topology (the node ids
/// + edges) can be encoded and persisted while the node behaviour stays in
/// code. A loaded topology is rehydrated by looking up each node id here.
public actor StateGraphNodeRegistry {
    public static let shared = StateGraphNodeRegistry()

    private var factories: [String: () -> StateGraphNodeFn] = [:]

    public init() {}

    public func register(_ id: String, _ factory: @escaping () -> StateGraphNodeFn) {
        factories[id] = factory
    }

    public func resolve(_ id: String) -> StateGraphNodeFn? {
        factories[id]?()
    }

    public func contains(_ id: String) -> Bool {
        factories[id] != nil
    }
}

/// Codable graph topology: node ids + display metadata + edges + conditions,
/// without the functions. Persists to disk/Postgres; rehydrate by resolving
/// node ids against ``StateGraphNodeRegistry``.
public struct StateGraphTopology: Codable, Sendable {
    public struct NodeSpec: Codable, Sendable, Equatable {
        public let id: String
        public let displayName: String
        public let description: String
        public init(id: String, displayName: String, description: String) {
            self.id = id; self.displayName = displayName; self.description = description
        }
    }
    public struct ConditionalEdgeSpec: Codable, Sendable, Equatable {
        public let from: String
        public let branches: [String: String]
        public init(from: String, branches: [String: String]) {
            self.from = from; self.branches = branches
        }
    }

    public var schema: String = "tessera.state-graph.v1"
    public var name: String
    public var nodes: [NodeSpec]
    public var edges: [StateGraphEdge]
    public var conditionalEdges: [ConditionalEdgeSpec]
    public var entryPoint: String
    public var finishPoint: String
    public var interruptBefore: [String]
    public var interruptAfter: [String]
    public var reducers: [String: StateGraphReducer]

    public init(
        name: String,
        nodes: [NodeSpec],
        edges: [StateGraphEdge],
        conditionalEdges: [ConditionalEdgeSpec],
        entryPoint: String,
        finishPoint: String = stateGraphEnd,
        interruptBefore: [String] = [],
        interruptAfter: [String] = [],
        reducers: [String: StateGraphReducer] = [:]
    ) {
        self.name = name
        self.nodes = nodes
        self.edges = edges
        self.conditionalEdges = conditionalEdges
        self.entryPoint = entryPoint
        self.finishPoint = finishPoint
        self.interruptBefore = interruptBefore
        self.interruptAfter = interruptAfter
        self.reducers = reducers
    }

    /// Rehydrate a runnable ``StateGraph`` from this topology by resolving
    /// each node id against the registry. Returns nil (with an error
    /// message) if any node id is unregistered.
    public func rehydrate(from registry: StateGraphNodeRegistry) async -> (StateGraph?, String?) {
        let g = StateGraph(name: name)
        for spec in nodes {
            guard let fn = await registry.resolve(spec.id) else {
                return (nil, "unregistered node: \(spec.id)")
            }
            g.addNode(spec.id, spec.displayName, fn, description: spec.description)
        }
        for e in edges { g.addEdge(from: e.from, to: e.to) }
        for ce in conditionalEdges {
            // The router is not part of the persistable topology; callers
            // re-attach routers when rehydrating, since routing logic is
            // domain-specific (e.g. the chat classifier). Here we register a
            // pass-through that always takes the first branch, which is
            // wrong for real use but lets a topology round-trip for
            // inspection. Real rehydration is call-site-owned.
            if let first = ce.branches.values.first {
                g.addConditionalEdge(from: ce.from, router: { _ in first }, branches: ce.branches)
            }
        }
        g.setEntryPoint(entryPoint)
        g.setFinishPoint(finishPoint)
        g.interruptBefore(interruptBefore)
        g.interruptAfter(interruptAfter)
        for (key, reducer) in reducers { g.setReducer(key, reducer) }
        return (g, nil)
    }

    /// Snapshot a topology from a constructed graph (functions dropped).
    public static func snapshot(of graph: StateGraph) -> StateGraphTopology {
        StateGraphTopology(
            name: graph.name,
            nodes: graph.nodes.map { NodeSpec(id: $0.id, displayName: $0.displayName, description: $0.description) },
            edges: graph.edges,
            conditionalEdges: graph.conditionalEdges.map { ConditionalEdgeSpec(from: $0.from, branches: $0.branches) },
            entryPoint: graph.entryPoint,
            finishPoint: graph.finishPoint,
            interruptBefore: Array(graph.interruptBefore),
            interruptAfter: Array(graph.interruptAfter),
            reducers: graph.reducers
        )
    }
}
