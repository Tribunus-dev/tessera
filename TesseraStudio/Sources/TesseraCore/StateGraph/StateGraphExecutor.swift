import Foundation

/// Runs a ``StateGraph``, streaming events, checkpointing each step, and
/// awaiting human approval at interrupts. An actor so concurrent runs and
/// approvals are serialized safely. Port of the Linux `executeThread`
/// (StateGraph.cpp:182-241) with one load-bearing improvement: the Linux
/// `approveInterrupt` is a no-op stub; this implementation actually suspends
/// the run at an interrupt until an approval is resolved.
public actor StateGraphExecutor {
    private let graph: StateGraph
    private let checkpointer: StateGraphCheckpointer

    // Pending approvals keyed by thread id. A run blocked at an interrupt
    // awaits its continuation; `approveInterrupt` resolves it.
    private var pendingApprovals: [String: CheckedContinuation<Bool, Never>] = [:]
    private var liveThreads: Set<String> = []

    public init(graph: StateGraph, checkpointer: StateGraphCheckpointer = MemoryCheckpointer()) {
        self.graph = graph
        self.checkpointer = checkpointer
    }

    public func currentGraph() -> StateGraph { graph }
    public func currentCheckpointer() -> StateGraphCheckpointer { checkpointer }

    /// Run from an initial state. Returns `(threadId, events)`. The events
    /// stream ends when the run finishes (reaches `__end__`, the finish
    /// point, fails validation, or a node throws).
    public func run(initial: GraphState) -> (String, AsyncStream<StateGraphEvent>) {
        let threadId = Self.newThreadId()
        let stream = AsyncStream<StateGraphEvent> { continuation in
            Task { [weak self] in
                guard let self else { continuation.finish(); return }
                await self.execute(threadId: threadId, state: initial, step: 0, resumeFrom: nil, continuation: continuation)
                continuation.finish()
            }
        }
        return (threadId, stream)
    }

    /// Resume from a checkpoint (time travel). The run restarts at the next
    /// node after the checkpoint's node, using the checkpoint's captured
    /// state. (The Linux port re-runs the checkpointed node; this version
    /// advances past it, since the checkpoint already captured its output.)
    public func resume(checkpointId: UUID) async -> (String, AsyncStream<StateGraphEvent>)? {
        guard let cp = try? await checkpointer.load(checkpointId: checkpointId) else { return nil }
        let resumeNode = await nextNode(after: cp.nodeId, state: cp.state)
        let stream = AsyncStream<StateGraphEvent> { continuation in
            Task { [weak self] in
                guard let self else { continuation.finish(); return }
                continuation.yield(StateGraphEvent(type: .log, message: "Resumed from checkpoint \(cp.id) at \(cp.nodeId)", stateSnapshot: cp.state))
                await self.execute(threadId: cp.threadId, state: cp.state, step: cp.step + 1, resumeFrom: resumeNode, continuation: continuation)
                continuation.finish()
            }
        }
        return (cp.threadId, stream)
    }

    /// Resolve an interrupt. Resumes the blocked run if approved, aborts it
    /// if denied. No-op if the thread isn't blocked.
    public func approveInterrupt(threadId: String, approved: Bool) {
        if let cont = pendingApprovals.removeValue(forKey: threadId) {
            cont.resume(returning: approved)
        }
    }

    // MARK: execution loop

    private func execute(
        threadId: String,
        state initial: GraphState,
        step initialStep: Int,
        resumeFrom: String?,
        continuation: AsyncStream<StateGraphEvent>.Continuation
    ) async {
        if let err = graph.validate() {
            continuation.yield(StateGraphEvent(type: .finished, message: "validate: \(err)", success: false, stateSnapshot: initial))
            return
        }
        liveThreads.insert(threadId)
        defer { liveThreads.remove(threadId) }

        var state = initial
        var step = initialStep
        var current: String = resumeFrom ?? graph.entryPoint
        var visited: Set<String> = []

        // Checkpoint the initial state before any node runs.
        await checkpoint(threadId: threadId, step: step, nodeId: current, state: state, continuation: continuation)
        continuation.yield(StateGraphEvent(type: .started, message: "StateGraph \(graph.name) started", stateSnapshot: state))

        while current != stateGraphEnd && current != graph.finishPoint {
            if visited.count > graph.nodes.count * 2 {
                continuation.yield(StateGraphEvent(type: .finished, message: "cycle guard", success: false, stateSnapshot: state))
                return
            }
            visited.insert(current)

            // Interrupt before the node: emit and await approval.
            if graph.interruptBefore.contains(current) {
                continuation.yield(StateGraphEvent(type: .interrupted, nodeId: current, message: "Approval required before \(current)", stateSnapshot: state))
                let approved = await waitForApproval(threadId: threadId)
                if !approved {
                    continuation.yield(StateGraphEvent(type: .finished, nodeId: current, message: "denied at interrupt", success: false, stateSnapshot: state))
                    return
                }
            }

            guard let node = graph.nodes.first(where: { $0.id == current }) else {
                continuation.yield(StateGraphEvent(type: .finished, nodeId: current, message: "unknown node \(current)", success: false, stateSnapshot: state))
                return
            }
            continuation.yield(StateGraphEvent(type: .nodeStarted, nodeId: current, message: node.displayName, stateSnapshot: state))

            let update: StateUpdate
            do {
                update = try await node.fn(state)
            } catch {
                continuation.yield(StateGraphEvent(type: .nodeFinished, nodeId: current, message: error.localizedDescription, success: false, stateSnapshot: state))
                continuation.yield(StateGraphEvent(type: .finished, message: "node \(current) failed", success: false, stateSnapshot: state))
                return
            }

            // Merge graph-level reducers into the update's per-key reducers.
            var merged = update
            for (key, reducer) in graph.reducers where merged.reducers[key] == nil {
                merged.reducers[key] = reducer
            }
            state = reduceState(current: state, merged)
            step += 1
            await checkpoint(threadId: threadId, step: step, nodeId: current, state: state, continuation: continuation)
            continuation.yield(StateGraphEvent(type: .nodeFinished, nodeId: current, message: node.displayName, stateSnapshot: state))

            // Interrupt after the node.
            if graph.interruptAfter.contains(current) {
                continuation.yield(StateGraphEvent(type: .interrupted, nodeId: current, message: "Approval required after \(current)", stateSnapshot: state))
                let approved = await waitForApproval(threadId: threadId)
                if !approved {
                    continuation.yield(StateGraphEvent(type: .finished, nodeId: current, message: "denied at interrupt", success: false, stateSnapshot: state))
                    return
                }
            }

            // Route: conditional edge takes priority over a normal edge.
            current = await nextNode(after: current, state: state)
        }
        continuation.yield(StateGraphEvent(type: .finished, message: "StateGraph finished", stateSnapshot: state))
    }

    private func checkpoint(threadId: String, step: Int, nodeId: String, state: GraphState, continuation: AsyncStream<StateGraphEvent>.Continuation) async {
        if let cp = try? await checkpointer.save(threadId, step: step, nodeId: nodeId, state: state) {
            continuation.yield(StateGraphEvent(type: .checkpoint, nodeId: nodeId, message: cp.id.uuidString, stateSnapshot: state))
        }
    }

    /// Resolve the node following `nodeId` given `state`. Conditional edges
    /// take priority over normal edges; falls back to `__default__`, then
    /// `__end__`. Shared by the main loop and the resume path so they agree.
    private func nextNode(after nodeId: String, state: GraphState) async -> String {
        for ce in graph.conditionalEdges where ce.from == nodeId {
            let r = await ce.router(state)
            if let target = ce.branches[r] { return target }
            if let fallback = ce.branches[stateGraphDefault] { return fallback }
            return stateGraphEnd
        }
        if let to = graph.edges.first(where: { $0.from == nodeId })?.to {
            return to.isEmpty ? stateGraphEnd : to
        }
        return stateGraphEnd
    }

    /// Suspend the run until `approveInterrupt(threadId:approved:)` resolves.
    /// Safe by construction: the continuation is resumed exactly once from
    /// `approveInterrupt`, or never (run is abandoned).
    private func waitForApproval(threadId: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            pendingApprovals[threadId] = cont
        }
    }

    private static func newThreadId() -> String {
        "thread-" + String(UUID().uuidString.prefix(8)).lowercased()
    }
}
