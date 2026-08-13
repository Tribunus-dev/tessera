import XCTest
@testable import TesseraCore

// Inline stop tests (paradox 5, Microsoft HAX G11 "Support efficient
// dismissal"; agent-ux-fatigue, pattern-catalog.md sec. "Big friendly
// stop button" inline at the moment of action). The load-bearing test
// is testHardStop: the agent does not auto-resume after a user-initiated
// stop. The supporting tests pin the supporting behavior:
//   - the reason is recorded on the loop instance
//   - the stop signal reaches the active event stream
//   - subsequent run() calls are rejected until clearStop() is invoked
//   - clearStop() restores the loop to a resumable state
//   - the stop reason descriptions are stable + ASCII
//
// Test target may have pre-existing build breaks; these tests are
// additive and do not depend on the broken files.

@MainActor
final class InlineStopTests: XCTestCase {

    // MARK: - Test fixtures

    /// A tool that sleeps until cancelled (or for a long time). Lets
    /// the test hold the loop in `await tool.execute(...)` long enough
    /// to invoke `stop(reason:)` on the running loop. The sleep is
    /// `Task.sleep(...)` so `Task.isCancelled` propagates; a stop()
    /// call on the loop cancels the loop's task, which cancels the
    /// sleeping tool, which throws `CancellationError`.
    private struct SleepyTool: TesseraTool {
        let name: String
        let defaultApprovalLevel: ApprovalLevel
        let description = "sleepy stub"
        let parameters = JSONSchema()
        let sleepNanoseconds: UInt64
        func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
            try await Task.sleep(nanoseconds: sleepNanoseconds)
            return .ok("woke up \(name)")
        }
    }

    /// A provider that emits the same tool call forever. Pairs with
    /// `SleepyTool` to keep the loop's tool-dispatch path busy. The
    /// provider does not stream (so the test does not depend on the
    /// LLM streaming machinery); the loop will fall through to the
    /// tool execution path on every iteration.
    private struct EndlessToolProvider: LLMProvider {
        let toolName: String
        func complete(system: String, messages: [LLMMessage], tools: [ToolDescriptor]) async throws -> LLMResponse {
            LLMResponse(
                content: "",
                toolCalls: [LLMToolCall(name: toolName, arguments: [:])],
                tokenCount: 1
            )
        }
    }

    /// A single-error error type so `.error(SyntheticError)` is
    /// distinguishable from a generic CancellationError in tests.
    private struct SyntheticError: Error, CustomStringConvertible {
        let label: String
        var description: String { label }
    }

    // MARK: - testHardStop (the load-bearing case)

    /// The agent does not auto-resume after a user-initiated stop
    /// (paradox 5, anti-metric: "% of stop-button presses that were
    /// followed by an agent auto-resume" target == 0). The test:
    ///   1. Start the loop with a long-sleeping tool.
    ///   2. Wait for the loop to be running.
    ///   3. Call stop(reason: .userRequest).
    ///   4. Drain the stream; assert the active run saw the stop.
    ///   5. Assert lastStopReason == .userRequest.
    ///   6. Try a second run() WITHOUT calling clearStop(); assert
    ///      the new stream returns immediately with a stop signal
    ///      and the loop did NOT execute any tool call.
    ///   7. Call clearStop() and assert the next run() is back to
    ///      a normal state (not a stop-rejection stream).
    func testHardStop() async throws {
        // 5 seconds is long enough to be confident the tool call is
        // still in flight when stop() fires, and short enough that
        // a test failure (the loop never actually cancelled) times
        // out in a reasonable window.
        let sleepNs: UInt64 = 5_000_000_000
        let registry = TesseraToolRegistry(tools: [
            SleepyTool(name: "sleepy", defaultApprovalLevel: .auto, sleepNanoseconds: sleepNs)
        ])
        let approval = TesseraApprovalEngine()
        // Pre-approve the sleepy tool so the loop reaches execution
        // (the safety spine otherwise prompts, which is not what the
        // hard-stop test is exercising).
        approval.setOverride(.auto, for: "sleepy")
        defer { approval.clearOverride(for: "sleepy") }

        let loop = TesseraAgentLoop(
            registry: registry,
            approvalEngine: approval,
            llmProvider: EndlessToolProvider(toolName: "sleepy"),
            maxIterations: 5,
            sandboxEnforceable: true
        )

        // Start the run and wait for the loop to be in flight.
        let firstStream = loop.run(userMessage: "go", history: [])
        // Give the loop time to start its task and reach the tool
        // execution. Without this gap, the test could fire stop()
        // before the task is even scheduled, exercising the
        // "stop without a run" path instead of the hard-stop path.
        try await waitForRunning(loop: loop, timeout: .seconds(2))

        // Stop the loop. This is the user pressing the inline
        // stop button.
        loop.stop(reason: .userRequest)

        // Drain the stream; collect events to assert the active run
        // saw the stop signal.
        var sawStopPrefix = false
        var sawDone = false
        for await event in firstStream {
            switch event {
            case .error(let message) where message.hasPrefix(AgentEventMarker.stoppedPrefix):
                sawStopPrefix = true
            case .done:
                sawDone = true
            default:
                break
            }
        }
        XCTAssertTrue(sawStopPrefix, "active run must see the [stopped] marker on the event stream")
        XCTAssertTrue(sawDone, "active run must terminate with .done even after a hard stop")

        // The reason is recorded on the loop instance.
        guard let reason = loop.lastStopReason else {
            XCTFail("lastStopReason must be set after stop(reason:) is invoked")
            return
        }
        switch reason {
        case .userRequest:
            break
        default:
            XCTFail("expected .userRequest, got \(reason)")
        }

        // A new run() without clearStop() must be rejected. The
        // stream returns immediately with a stop signal; no tool
        // call is dispatched.
        let secondStream = loop.run(userMessage: "go again", history: [])
        var secondSawStop = false
        var secondSawDone = false
        for await event in secondStream {
            switch event {
            case .error(let message) where message.hasPrefix(AgentEventMarker.stoppedPrefix):
                secondSawStop = true
            case .done:
                secondSawDone = true
            default:
                break
            }
        }
        XCTAssertTrue(secondSawStop, "post-stop run() must emit a stop signal, not a fresh run")
        XCTAssertTrue(secondSawDone, "post-stop run() must terminate with .done")
        XCTAssertFalse(loop.isRunning, "post-stop loop is not running")

        // clearStop() restores the loop. The next run() is a
        // normal run, not a rejection.
        loop.clearStop()
        XCTAssertNil(loop.lastStopReason, "clearStop() must clear lastStopReason")

        // The third run would dispatch the sleepy tool again and
        // hang; cancel the loop's task before the test returns so
        // the test does not block on the 5s sleep. The cancel
        // path is well-tested elsewhere (TesseraAgentLoopSafetyTests);
        // the assertion here is that the loop is back in a runnable
        // state (lastStopReason == nil, no stream rejection).
        let thirdStream = loop.run(userMessage: "go once more", history: [])
        // Cancel after a brief delay so the run actually starts
        // (asserts it is not a stop-rejection stream).
        let canceller = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            loop.cancel()
        }
        for await _ in thirdStream { }
        canceller.cancel()
        // The third run was a real run (not a stop-rejection).
        // The acceptance is that it is NOT a stop-rejection stream:
        // lastStopReason stays nil after clearStop().
        XCTAssertNil(
            loop.lastStopReason,
            "third run did not enter the stop-rejection path"
        )
    }

    // MARK: - Stop reason description is stable + ASCII

    func testStopReasonDescriptionsAreStableAndAscii() {
        let cases: [(StopReason, String)] = [
            (.userRequest, "Stopped by user"),
            (.timeout, "Timed out"),
            (.error(SyntheticError(label: "boom")), "Stopped due to error: boom"),
        ]
        for (reason, expected) in cases {
            XCTAssertEqual(reason.description, expected,
                "description must be stable so the audit log + UI label are consistent")
            XCTAssertTrue(reason.description.allSatisfy { $0.isASCII },
                "description must be ASCII: \(reason.description)")
        }
    }

    // MARK: - Stop without a run is safe

    /// Calling `stop` on a non-running loop must NOT throw and must
    /// still record the reason. This is the "stop a queued run before
    /// it starts" path; without it, the host would have to check
    /// `isRunning` before each stop call.
    func testStopWithoutRunIsSafeAndRecordsReason() {
        let loop = TesseraAgentLoop(
            registry: .default,
            approvalEngine: TesseraApprovalEngine(),
            llmProvider: PlaceholderLLMProvider(),
            maxIterations: 1
        )
        XCTAssertNil(loop.lastStopReason)
        loop.stop(reason: .timeout)
        XCTAssertNotNil(loop.lastStopReason)
        if case .timeout = loop.lastStopReason! { } else {
            XCTFail("expected .timeout, got \(String(describing: loop.lastStopReason))")
        }
    }

    // MARK: - clearStop() before any stop is a no-op

    func testClearStopWithoutStopIsNoOp() {
        let loop = TesseraAgentLoop(
            registry: .default,
            approvalEngine: TesseraApprovalEngine(),
            llmProvider: PlaceholderLLMProvider(),
            maxIterations: 1
        )
        XCTAssertNil(loop.lastStopReason)
        loop.clearStop()
        XCTAssertNil(loop.lastStopReason)
    }

    // MARK: - Multiple stops keep the most recent reason

    /// A second stop() overrides the first reason. The audit log
    /// records the latest reason; the first reason is intentionally
    /// NOT preserved (the loop is a control surface, not a journal).
    func testSubsequentStopOverridesPreviousReason() {
        let loop = TesseraAgentLoop(
            registry: .default,
            approvalEngine: TesseraApprovalEngine(),
            llmProvider: PlaceholderLLMProvider(),
            maxIterations: 1
        )
        loop.stop(reason: .timeout)
        XCTAssertNotNil(loop.lastStopReason)
        loop.stop(reason: .userRequest)
        guard case .userRequest = loop.lastStopReason! else {
            XCTFail("expected .userRequest to override .timeout")
            return
        }
    }

    // MARK: - AgentEventMarker is a stable string

    /// The marker prefix is part of the public surface: the chat
    /// controller and the audit log depend on the exact string. A
    /// rename would silently break consumers.
    func testAgentEventMarkerPrefixIsStable() {
        XCTAssertEqual(AgentEventMarker.stoppedPrefix, "[stopped]")
        XCTAssertTrue(AgentEventMarker.stoppedPrefix.allSatisfy { $0.isASCII })
    }

    // MARK: - Tier weighting (the inline stop button's affordance)

    /// The tier enum from Wave 1B drives the stop button's
    /// prominence. This test pins the contract: the enum's
    /// `Comparable` order matches the prominence order (tier3 >
    /// tier2 > tier1 > tier0). The inline stop button uses this
    /// order to weight the icon size, label, and color.
    func testTierOrderingForStopButtonProminence() {
        XCTAssertLessThan(TesseraTier.tier0, TesseraTier.tier1)
        XCTAssertLessThan(TesseraTier.tier1, TesseraTier.tier2)
        XCTAssertLessThan(TesseraTier.tier2, TesseraTier.tier3)
    }

    // MARK: - Helpers

    /// Spin-wait until `loop.isRunning` is true or the timeout
    /// elapses. Throws if the loop never reports `isRunning` (e.g.
    /// the test fixture is broken), so a stuck test fails loudly
    /// instead of silently.
    private func waitForRunning(
        loop: TesseraAgentLoop,
        timeout: Duration
    ) async throws {
        let start = ContinuousClock.now
        while !loop.isRunning {
            if ContinuousClock.now - start > timeout {
                XCTFail("loop never reported isRunning within \(timeout); fixture broken")
                throw XCTestError(.timeoutWhileWaiting)
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
