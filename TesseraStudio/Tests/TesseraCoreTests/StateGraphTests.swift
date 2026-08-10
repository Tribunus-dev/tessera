import XCTest
@testable import TesseraCore

// MARK: - reduceState

final class StateGraphReduceTests: XCTestCase {
    func test_replace_overwrites() {
        let s: GraphState = ["a": .string("old")]
        let out = reduceState(current: s, .init(updates: ["a": .string("new")]))
        XCTAssertEqual(out["a"], .string("new"))
    }

    func test_append_joinsStringsWithNewline() {
        let s: GraphState = ["msg": .string("hello")]
        let out = reduceState(current: s, .init(updates: ["msg": .string("world")], reducers: ["msg": .append]))
        XCTAssertEqual(out["msg"], .string("hello\nworld"))
    }

    func test_append_emptyExistingOverwrites() {
        let out = reduceState(current: [:], .init(updates: ["msg": .string("first")], reducers: ["msg": .append]))
        XCTAssertEqual(out["msg"], .string("first"))
    }

    func test_append_concatenatesArrays() {
        let s: GraphState = ["list": .array([.number(1)])]
        let out = reduceState(current: s, .init(updates: ["list": .array([.number(2), .number(3)])], reducers: ["list": .append]))
        XCTAssertEqual(out["list"], .array([.number(1), .number(2), .number(3)]))
    }

    func test_add_sumsNumbers() {
        let s: GraphState = ["count": .number(5)]
        let out = reduceState(current: s, .init(updates: ["count": .number(3)], reducers: ["count": .add]))
        XCTAssertEqual(out["count"], .number(8))
    }

    func test_add_missingExistingStartsFromZero() {
        let out = reduceState(current: [:], .init(updates: ["count": .number(7)], reducers: ["count": .add]))
        XCTAssertEqual(out["count"], .number(7))
    }

    func test_defaultReducer_appliedWhenNoPerKeyOverride() {
        let s: GraphState = ["msg": .string("hello")]
        let out = reduceState(current: s, .init(updates: ["msg": .string("world")]), defaultReducer: .append)
        XCTAssertEqual(out["msg"], .string("hello\nworld"))
    }
}

// MARK: - StateGraph.validate

final class StateGraphValidateTests: XCTestCase {
    private func threeNodeGraph() -> StateGraph {
        let g = StateGraph(name: "test")
        g.addNode("a", "A", { _ in .init(updates: [:]) })
        g.addNode("b", "B", { _ in .init(updates: [:]) })
        g.addNode("c", "C", { _ in .init(updates: [:]) })
        g.addEdge(from: "a", to: "b")
        g.addEdge(from: "b", to: "c")
        g.addEdge(from: "c", to: stateGraphEnd)
        g.setEntryPoint("a")
        return g
    }

    func test_happyPath_validates() {
        XCTAssertNil(threeNodeGraph().validate())
    }

    func test_missingEntryPoint_returnsError() {
        let g = StateGraph(name: "test")
        g.addNode("a", "A", { _ in .init(updates: [:]) })
        XCTAssertEqual(g.validate(), "no entry point")
    }

    func test_entryNotPresent_returnsError() {
        let g = StateGraph(name: "test")
        g.addNode("a", "A", { _ in .init(updates: [:]) })
        g.setEntryPoint("missing")
        XCTAssertEqual(g.validate(), "entry not found: missing")
    }

    func test_unknownEdgeTarget_returnsError() {
        let g = StateGraph(name: "test")
        g.addNode("a", "A", { _ in .init(updates: [:]) })
        g.addEdge(from: "a", to: "ghost")
        g.setEntryPoint("a")
        XCTAssertEqual(g.validate(), "edge references unknown node: ghost")
    }

    func test_cycle_returnsError() {
        let g = StateGraph(name: "test")
        g.addNode("a", "A", { _ in .init(updates: [:]) })
        g.addNode("b", "B", { _ in .init(updates: [:]) })
        g.addEdge(from: "a", to: "b")
        g.addEdge(from: "b", to: "a")
        g.setEntryPoint("a")
        XCTAssertNotNil(g.validate())
    }

    func test_endSentinel_notTreatedAsCycle() {
        let g = StateGraph(name: "test")
        g.addNode("a", "A", { _ in .init(updates: [:]) })
        g.addEdge(from: "a", to: stateGraphEnd)
        g.addEdge(from: "a", to: stateGraphEnd)
        g.setEntryPoint("a")
        XCTAssertNil(g.validate())
    }
}

// MARK: - StateGraphExecutor run + checkpoints

final class StateGraphExecutorTests: XCTestCase {
    /// Build a 3-node graph that appends to `messages` at each step.
    private func appendingGraph() -> StateGraph {
        let g = StateGraph(name: "append-test")
        g.setReducer("messages", .append)
        g.addNode("first", "First", { _ in .init(updates: ["messages": .string("a")]) })
        g.addNode("second", "Second", { _ in .init(updates: ["messages": .string("b")]) })
        g.addNode("third", "Third", { _ in .init(updates: ["messages": .string("c")]) })
        g.addEdge(from: "first", to: "second")
        g.addEdge(from: "second", to: "third")
        g.addEdge(from: "third", to: stateGraphEnd)
        g.setEntryPoint("first")
        return g
    }

    private func collectEvents(_ stream: AsyncStream<StateGraphEvent>) async -> [StateGraphEvent] {
        var events: [StateGraphEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    func test_run_producesThreeCheckpointsAndAppendedState() async {
        let checkpointer = MemoryCheckpointer()
        let executor = StateGraphExecutor(graph: appendingGraph(), checkpointer: checkpointer)
        let (threadId, stream) = await executor.run(initial: [:])
        let events = await collectEvents(stream)

        // Final finished event carries the appended state.
        let finished = events.last(where: { $0.type == .finished })
        XCTAssertEqual(finished?.stateSnapshot["messages"], .string("a\nb\nc"))

        // Step 0 = entry checkpoint (before any node), then steps 1,2,3 after
        // each node appends. That's 4 checkpoints for a 3-node run.
        let checkpoints = try! await checkpointer.list(threadId: threadId)
        XCTAssertEqual(checkpoints.count, 4)
        XCTAssertEqual(checkpoints.map(\.step), [0, 1, 2, 3])
        XCTAssertEqual(checkpoints.map(\.nodeId), ["first", "first", "second", "third"])
    }

    func test_resume_continuesFromCheckpoint() async {
        let checkpointer = MemoryCheckpointer()
        let executor = StateGraphExecutor(graph: appendingGraph(), checkpointer: checkpointer)
        let (threadId, stream) = await executor.run(initial: [:])
        _ = await collectEvents(stream) // drain so all checkpoints land

        // Capture the checkpoint after `second` (step 2) and resume from it.
        let checkpoints = try! await checkpointer.list(threadId: threadId)
        let step2 = checkpoints.first(where: { $0.step == 2 })!
        let resumed = await executor.resume(checkpointId: step2.id)
        XCTAssertNotNil(resumed)
        if let (_, stream) = resumed {
            let events = await collectEvents(stream)
            // After resuming at step 2 (node `second` done), only `third`
            // remains, so the final state is the resumed state plus "c".
            XCTAssertEqual(events.last(where: { $0.type == .finished })?.stateSnapshot["messages"], .string("a\nb\nc"))
        }
    }

    func test_conditionalEdge_routesToChosenBranch() async {
        let g = StateGraph(name: "router-test")
        g.addNode("entry", "Entry", { _ in .init(updates: ["path": .string("go-b")]) })
        g.addNode("a", "A", { _ in .init(updates: ["taken": .string("a")]) })
        g.addNode("b", "B", { _ in .init(updates: ["taken": .string("b")]) })
        g.addConditionalEdge(from: "entry", router: { state in
            state["path"]?.stringValue == "go-b" ? "to-b" : "to-a"
        }, branches: ["to-a": "a", "to-b": "b"])
        g.addEdge(from: "a", to: stateGraphEnd)
        g.addEdge(from: "b", to: stateGraphEnd)
        g.setEntryPoint("entry")

        let executor = StateGraphExecutor(graph: g)
        let events = await collectEvents(await executor.run(initial: [:]).1)
        XCTAssertEqual(events.last(where: { $0.type == .finished })?.stateSnapshot["taken"], .string("b"))
        // Node "a" should never have been visited.
        XCTAssertFalse(events.contains(where: { $0.type == .nodeStarted && $0.nodeId == "a" }))
    }

    func test_nodeThrowing_emitsFailureAndStops() async {
        struct Boom: Error {}
        let g = StateGraph(name: "fail-test")
        g.addNode("boom", "Boom", { _ in throw Boom() })
        g.addNode("after", "After", { _ in .init(updates: ["reached": .bool(true)]) })
        g.addEdge(from: "boom", to: "after")
        g.addEdge(from: "after", to: stateGraphEnd)
        g.setEntryPoint("boom")

        let executor = StateGraphExecutor(graph: g)
        let events = await collectEvents(await executor.run(initial: [:]).1)
        XCTAssertEqual(events.last(where: { $0.type == .nodeFinished })?.success, false)
        XCTAssertNotNil(events.last(where: { $0.type == .finished && !$0.success }))
        XCTAssertNil(events.last(where: { $0.type == .finished })?.stateSnapshot["reached"])
    }
}

// MARK: - interrupt-before + approveInterrupt

final class StateGraphInterruptTests: XCTestCase {
    func test_interruptBefore_blocksUntilApproved() async {
        let g = StateGraph(name: "interrupt-test")
        g.addNode("start", "Start", { _ in .init(updates: ["ran": .bool(true)]) })
        g.addNode("gated", "Gated", { _ in .init(updates: ["gated_ran": .bool(true)]) })
        g.addEdge(from: "start", to: "gated")
        g.addEdge(from: "gated", to: stateGraphEnd)
        g.setEntryPoint("start")
        g.interruptBefore(["gated"])

        let executor = StateGraphExecutor(graph: g)
        let (threadId, stream) = await executor.run(initial: [:])

        // Collect events in a task so the run can block at the interrupt.
        let collect = Task { [weak executor] () -> [StateGraphEvent] in
            var events: [StateGraphEvent] = []
            for await event in stream { events.append(event) }
            // After the run ends, assert nothing more to do here.
            _ = executor
            return events
        }
        // Give the run a moment to reach the interrupt.
        try? await Task.sleep(nanoseconds: 150_000_000)
        await executor.approveInterrupt(threadId: threadId, approved: true)

        let events = await collect.value
        let interrupted = events.contains(where: { $0.type == .interrupted && $0.nodeId == "gated" })
        XCTAssertTrue(interrupted, "expected an interrupted event before `gated`")
        XCTAssertEqual(events.last(where: { $0.type == .finished })?.stateSnapshot["gated_ran"], .bool(true))
    }

    func test_interruptDenied_aborts() async {
        let g = StateGraph(name: "deny-test")
        g.addNode("start", "Start", { _ in .init(updates: [:]) })
        g.addNode("gated", "Gated", { _ in .init(updates: ["gated_ran": .bool(true)]) })
        g.addEdge(from: "start", to: "gated")
        g.addEdge(from: "gated", to: stateGraphEnd)
        g.setEntryPoint("start")
        g.interruptBefore(["gated"])

        let executor = StateGraphExecutor(graph: g)
        let (threadId, stream) = await executor.run(initial: [:])
        let collect = Task { () -> [StateGraphEvent] in
            var events: [StateGraphEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        await executor.approveInterrupt(threadId: threadId, approved: false)

        let events = await collect.value
        let finished = events.last(where: { $0.type == .finished })
        XCTAssertEqual(finished?.success, false)
        XCTAssertNil(finished?.stateSnapshot["gated_ran"])
    }
}
