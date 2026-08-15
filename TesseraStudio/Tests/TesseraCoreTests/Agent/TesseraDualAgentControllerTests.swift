import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Agent/TesseraDualAgentController.swift
// public value types (`DualAgentMessage`, `CollabTraceEntry`) plus the
// controller's documented reset methods. Per
// docs/AGENT-UX-FATIGUE-REVIEW.md 3.2, this controller is the LEGACY
// chat path superseded by `UnifiedChatController` / `ChatGraphBuilder`
// ("the legacy chat admits it is decorative" -- `TesseraDualAgentController.swift:208-209`).
// `send(_:)` drives the real streaming/tool-call/approval machinery end
// to end and is out of scope for this pass; this file covers the pure
// value types and the reset/seed methods, which are the parts genuinely
// independent of a live provider.
@MainActor
final class TesseraDualAgentControllerTests: DoctrineTestCase {

    // MARK: - DualAgentMessage

    func testDualAgentMessageDefaultsToNotStreamingAndEmptyToolCalls() {
        let message = DualAgentMessage(role: .assistant, speaker: .tessy, content: "hi")
        XCTAssertFalse(message.isStreaming)
        XCTAssertTrue(message.toolCalls.isEmpty)
    }

    func testDualAgentMessageCarriesSpeakerAndContent() {
        let message = DualAgentMessage(role: .assistant, speaker: .sky, content: "cloud says hi")
        XCTAssertEqual(message.speaker, .sky)
        XCTAssertEqual(message.content, "cloud says hi")
        XCTAssertEqual(message.role, .assistant)
    }

    // MARK: - CollabTraceEntry

    func testCollabTraceEntryCarriesFromPersonaAndText() {
        let entry = CollabTraceEntry(from: .tessy, text: "handing off")
        XCTAssertEqual(entry.from, .tessy)
        XCTAssertEqual(entry.text, "handing off")
    }

    func testCollabTraceEntryHasAUniqueIDPerInstance() {
        let a = CollabTraceEntry(from: .tessy, text: "x")
        let b = CollabTraceEntry(from: .tessy, text: "x")
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - Controller reset methods

    private func makeController() -> TesseraDualAgentController {
        let tessy = TesseraAgentLoop(
            registry: TesseraToolRegistry(tools: []),
            approvalEngine: TesseraApprovalEngine(),
            llmProvider: PlaceholderLLMProvider(),
            persona: .tessy
        )
        let sky = TesseraAgentLoop(
            registry: TesseraToolRegistry(tools: []),
            approvalEngine: TesseraApprovalEngine(),
            llmProvider: PlaceholderLLMProvider(),
            persona: .sky
        )
        return TesseraDualAgentController(tessyLoop: tessy, skyLoop: sky)
    }

    func testFreshControllerStartsEmpty() {
        let controller = makeController()
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertTrue(controller.collabTrace.isEmpty)
        XCTAssertFalse(controller.isRunning)
        XCTAssertNil(controller.pendingApproval)
    }

    func testClearCollabTraceEmptiesTheTrace() {
        let controller = makeController()
        controller.seedCollabTraceIfNeeded()
        controller.clearCollabTrace()
        XCTAssertTrue(controller.collabTrace.isEmpty)
    }

    func testSeedCollabTraceIfNeededPopulatesOnlyWhenEmpty() {
        let controller = makeController()
        controller.seedCollabTraceIfNeeded()
        let seededCount = controller.collabTrace.count
        XCTAssertGreaterThan(seededCount, 0)
        // Calling again when non-empty must be a no-op (doc comment:
        // "guard collabTrace.isEmpty else { return }").
        controller.seedCollabTraceIfNeeded()
        XCTAssertEqual(controller.collabTrace.count, seededCount)
    }

    func testClearTranscriptEmptiesMessagesAndResetsRunningState() {
        let controller = makeController()
        controller.clearTranscript()
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertFalse(controller.isRunning)
    }
}
