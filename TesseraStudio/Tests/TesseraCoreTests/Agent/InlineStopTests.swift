import XCTest
@testable import TesseraCore

// EXACT file/name per docs/PROJECT-STATUS.md item 3C: "InlineStopTests.swift
// w/ testHardStop". Contract source: Sources/TesseraCore/Agent/
// TesseraAgentLoop.swift doc comments on `StopReason` / `stop(reason:)` /
// `clearStop()` -- "the loop does NOT auto-resume; a new run() call is
// rejected with a clear error until the caller explicitly invokes
// clearStop()" -- plus AGENTS.md's "the off-ramp is a hard stop... a
// manual nudge holds until the next user-initiated clearStop()" and the
// doctrine's explicit emphasis: "a run() call after stop() is rejected
// until clearStop()".
final class InlineStopTests: DoctrineTestCase {

    @MainActor
    private func makeLoop() -> TesseraAgentLoop {
        TesseraAgentLoop(
            registry: TesseraToolRegistry(tools: []),
            approvalEngine: TesseraApprovalEngine(),
            llmProvider: PlaceholderLLMProvider(),
            persona: .tessy
        )
    }

    /// The doctrine's own named contract test (docs/PROJECT-STATUS.md
    /// item 3C). A hard stop must (a) record the reason, (b) reject a
    /// subsequent `run()` with a `[stopped]`-prefixed error instead of
    /// running the loop, and (c) never flip `isRunning` true for that
    /// rejected run.
    @MainActor
    func testHardStop() async throws {
        let loop = makeLoop()
        XCTAssertNil(loop.lastStopReason)

        loop.stop(reason: .userRequest)
        XCTAssertNotNil(loop.lastStopReason, "stop(reason:) must record the reason immediately")

        var events: [AgentEvent] = []
        let stream = loop.run(userMessage: "hello", history: [])
        for await event in stream {
            events.append(event)
        }

        XCTAssertFalse(loop.isRunning, "a rejected run() must never flip isRunning true")
        guard case .error(let message)? = events.first else {
            return XCTFail("expected the rejected run to yield an .error event first, got \(events)")
        }
        XCTAssertTrue(
            message.hasPrefix(AgentEventMarker.stoppedPrefix),
            "the rejected-run error must carry the stopped-prefix marker: \(message)"
        )
        guard case .done? = events.last else {
            return XCTFail("expected the rejected run's stream to end with .done, got \(events)")
        }
    }

    @MainActor
    func testStopReasonDescriptionsAreStableHumanReadableStrings() {
        XCTAssertEqual(StopReason.userRequest.description, "Stopped by user")
        XCTAssertEqual(StopReason.timeout.description, "Timed out")
        struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
        XCTAssertTrue(StopReason.error(Boom()).description.contains("boom"))
    }

    @MainActor
    func testClearStopClearsLastStopReason() {
        let loop = makeLoop()
        loop.stop(reason: .userRequest)
        XCTAssertNotNil(loop.lastStopReason)
        loop.clearStop()
        XCTAssertNil(loop.lastStopReason)
    }

    /// After `clearStop()`, a new `run()` call is accepted (it does not
    /// immediately reject with the stopped-prefix error) -- the second
    /// half of the hard-stop contract: the agent does not auto-resume on
    /// its own, but an explicit `clearStop()` does unblock `run()`.
    @MainActor
    func testRunAfterClearStopIsAcceptedNotRejected() async throws {
        let loop = makeLoop()
        loop.stop(reason: .userRequest)
        loop.clearStop()

        var events: [AgentEvent] = []
        let stream = loop.run(userMessage: "hi", history: [])
        for await event in stream {
            events.append(event)
            // Drain fully so the loop's background task completes
            // deterministically before the test returns.
        }
        XCTAssertFalse(events.isEmpty, "a cleared loop's run() must still produce events")
        for event in events {
            if case .error(let message) = event {
                XCTAssertFalse(
                    message.hasPrefix(AgentEventMarker.stoppedPrefix),
                    "a run() after clearStop() must not be rejected as a stop signal: \(message)"
                )
            }
        }
    }

    /// Calling `stop` on a loop that never started is documented as a
    /// no-op that still records the reason (doc comment on `stop(reason:)`).
    @MainActor
    func testStopOnAnNeverStartedLoopStillRecordsTheReason() {
        let loop = makeLoop()
        XCTAssertFalse(loop.isRunning)
        loop.stop(reason: .timeout)
        XCTAssertNotNil(loop.lastStopReason)
        XCTAssertFalse(loop.isRunning)
    }

    // MARK: - Anti-metric guard (AGENTS.md measurement architecture,
    // item 3C anti-metric): "% of stop-button presses that were followed
    // by an agent auto-resume, ==0". Structural pin: `run()`'s hard-stop
    // guard is checked BEFORE any work begins, so a stopped loop can
    // never silently start running again without an explicit clearStop().

    @MainActor
    func testRepeatedRunCallsAfterStopAllRejectUntilExplicitlyCleared() async throws {
        let loop = makeLoop()
        loop.stop(reason: .userRequest)

        for _ in 0..<3 {
            var sawStoppedError = false
            for await event in loop.run(userMessage: "x", history: []) {
                if case .error(let message) = event, message.hasPrefix(AgentEventMarker.stoppedPrefix) {
                    sawStoppedError = true
                }
            }
            XCTAssertTrue(sawStoppedError, "every run() before clearStop() must reject with the stop marker")
            XCTAssertFalse(loop.isRunning)
        }
    }
}
