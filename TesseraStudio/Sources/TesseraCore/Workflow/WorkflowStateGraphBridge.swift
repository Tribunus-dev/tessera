import Foundation

/// Bridges the existing typed-port ``Workflow`` model onto the
/// ``StateGraph`` execution plane. A workflow is converted to a `StateGraph`
/// (nodes become ``StateGraphNode``s, edges become ``StateGraphEdge``s), and
/// port values flow through ``GraphState`` instead of a separate inputs dict.
/// The run is driven by ``StateGraphExecutor``, so workflows gain
/// checkpoints, resumability, and interrupt-driven approval for free.
///
/// The editor's authoring format (``Workflow`` JSON), the typed-port
/// validation, and ``WorkflowNodeRegistry`` are unchanged — only the run
/// backing swaps from the legacy topological executor to StateGraph.
public enum WorkflowStateGraphBridge {

    /// Convert a workflow into a runnable StateGraph. Each node's function
    /// reads its input ports from `state["ports.<nodeId>"]`, runs the
    /// registered ``WorkflowNodeType.execute``, and writes its output ports
    /// back into state at the same key plus hands them to downstream nodes.
    public static func makeGraph(
        for workflow: Workflow,
        registry: WorkflowNodeRegistry,
        context: WorkflowExecutionContext
    ) async -> StateGraph {
        let g = StateGraph(name: workflow.name)
        for node in workflow.nodes {
            let nodeID = node.id
            let typeID = node.type
            let params = node.parameters
            let fn: StateGraphNodeFn = { state in
                guard let type = await registry.nodeType(for: typeID) else {
                    throw WorkflowBridgeError.unknownType(nodeID, typeID)
                }
                let inputs = readInputs(for: nodeID, from: state)
                let ctx = WorkflowExecutionContext(
                    fileSystem: context.fileSystem,
                    logger: context.logger)
                let outputs = try await type.execute(parameters: params, inputs: inputs, context: ctx)
                var updates = writeOutputs(for: nodeID, outputs: outputs)
                // Hand each output to the downstream node's input port so the
                // next node sees it. This mirrors the legacy executor's
                // `inputs[to][toPort] = value` threading, expressed as a
                // GraphState update.
                for edge in workflow.edges where edge.fromNode == nodeID {
                    if let value = outputs[edge.fromPort] {
                        updates.merge(intoPort: edge.toPort, on: edge.toNode, value: value)
                    }
                }
                return StateUpdate(updates: updates)
            }
            g.addNode(nodeID, nodeID, fn)
            // Seed the node's own output-port state key so reducers can append.
            // (replace semantics by default; one-shot workflow nodes don't
            // accumulate across visits.)
        }
        for edge in workflow.edges {
            g.addEdge(from: edge.fromNode, to: edge.toNode)
        }
        // Entry: the zero-in-degree node (Kahn's first). The legacy executor
        // validated acyclicity; StateGraph's own cycle detection re-checks.
        if let entry = await entryNode(of: workflow) {
            g.setEntryPoint(entry)
        }
        return g
    }

    /// Run a workflow via the StateGraph execution plane. Returns the event
    /// stream (translated to ``WorkflowEvent``s so the editor's progress pane
    /// is unchanged) and the thread id (for checkpoint resume).
    public static func run(
        _ workflow: Workflow,
        registry: WorkflowNodeRegistry,
        context: WorkflowExecutionContext = WorkflowExecutionContext()
    ) async -> (threadId: String, events: AsyncStream<WorkflowEvent>) {
        let graph = await makeGraph(for: workflow, registry: registry, context: context)
        let executor = StateGraphExecutor(graph: graph)
        let (threadId, stateStream) = await executor.run(initial: [:])
        let events = AsyncStream<WorkflowEvent> { continuation in
            let task = Task {
                var totalNodes = 0
                var lastNode: String?
                for await event in stateStream {
                    switch event.type {
                    case .started:
                        totalNodes = workflow.nodes.count
                        continuation.yield(.started(workflowName: workflow.name, totalNodes: totalNodes))
                    case .nodeStarted:
                        lastNode = event.nodeId
                        let typeId = workflow.nodes.first(where: { $0.id == event.nodeId })?.type ?? ""
                        continuation.yield(.nodeStarted(nodeId: event.nodeId, typeId: typeId))
                    case .nodeFinished:
                        continuation.yield(.nodeFinished(nodeId: event.nodeId, success: event.success, message: event.success ? nil : event.message))
                    case .finished:
                        continuation.yield(.finished(success: event.success, message: event.success ? nil : event.message))
                    case .log, .interrupted, .checkpoint:
                        break
                    }
                    _ = lastNode
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (threadId, events)
    }

    // MARK: - GraphState <-> port values

    private static func readInputs(for nodeID: String, from state: GraphState) -> [String: WorkflowPortValue] {
        guard case .object(let portObj) = state["ports.\(nodeID)"] ?? .null else { return [:] }
        var inputs: [String: WorkflowPortValue] = [:]
        for (portId, json) in portObj {
            if let v = workflowPortValue(from: json) {
                inputs[portId] = v
            }
        }
        return inputs
    }

    private static func writeOutputs(for nodeID: String, outputs: [String: WorkflowPortValue]) -> GraphState {
        var portObj: [String: JSONValue] = [:]
        for (portId, value) in outputs {
            portObj[portId] = jsonValue(from: value)
        }
        return ["ports.\(nodeID)": .object(portObj)]
    }

    private static func entryNode(of workflow: Workflow) async -> String? {
        var inDegree: [String: Int] = [:]
        for node in workflow.nodes { inDegree[node.id] = 0 }
        for edge in workflow.edges { inDegree[edge.toNode, default: 0] += 1 }
        return workflow.nodes.first(where: { (inDegree[$0.id] ?? 0) == 0 })?.id
    }
}

enum WorkflowBridgeError: Error {
    case unknownType(String, String)
}

private extension Dictionary where Key == String, Value == JSONValue {
    /// Write a port value into the downstream node's input-port state key,
    /// merging with any ports already there for that node.
    mutating func merge(intoPort port: String, on node: String, value: WorkflowPortValue) {
        let key = "ports.\(node)"
        let existing: [String: JSONValue]
        if case .object(let o) = self[key] ?? .null { existing = o } else { existing = [:] }
        var merged = existing
        merged[port] = jsonValue(from: value)
        self[key] = .object(merged)
    }
}

private func jsonValue(from port: WorkflowPortValue) -> JSONValue {
    port.asJSONValue
}

private func workflowPortValue(from json: JSONValue) -> WorkflowPortValue? {
    switch json {
    case .string(let v): return .string(v)
    case .number(let v): return .number(v)
    case .bool(let v): return .boolean(v)
    case .object(let v): return .bag(v)
    case .array, .null: return nil
    }
}
