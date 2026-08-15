import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Agent/UnifiedChatController.swift
// doc comments -- `liveState`/`liveStateCap` ("Bounded buffer of recent
// agent-loop events for the chat-dock Progress Feed... older entries fall
// off the end") and construction defaults. `extractCitations(from:)` (the
// citation-provenance pure function this controller owns) is covered in
// ChatMessageCitationTests.swift per that file's contract ownership.
//
// The controller's default `init()` reaches for
// `TesseraLLMProviderFactory.makeFromSettings()`, which reads real
// application settings; every test here injects lightweight loops
// (`PlaceholderLLMProvider`, an empty tool registry) and an in-memory
// checkpointer instead, so construction is deterministic and has no
// dependency on the host machine's model directory.
@MainActor
final class UnifiedChatControllerTests: DoctrineTestCase {

    private func makeController() -> UnifiedChatController {
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
        return UnifiedChatController(tessyLoop: tessy, skyLoop: sky, checkpointer: MemoryCheckpointer())
    }

    func testFreshControllerStartsWithNoRowsNoLiveStateNotRunning() {
        let controller = makeController()
        XCTAssertTrue(controller.rows.isEmpty)
        XCTAssertTrue(controller.liveState.isEmpty)
        XCTAssertFalse(controller.isRunning)
        XCTAssertNil(controller.pendingApproval)
    }

    func testFreshControllerHoldModeIsRunning() {
        XCTAssertEqual(makeController().holdMode, .running)
    }

    // MARK: - liveState: bounded buffer (doc comment: "older entries fall
    // off the end")

    func testAppendLiveStateGrowsInOrder() {
        let controller = makeController()
        let a = LiveStateEntry.routing(LiveRoutingEntry(useTessy: true, useSky: false, promptSummary: "a"))
        let b = LiveStateEntry.routing(LiveRoutingEntry(useTessy: false, useSky: true, promptSummary: "b"))
        controller.appendLiveState(a)
        controller.appendLiveState(b)
        XCTAssertEqual(controller.liveState.count, 2)
        XCTAssertEqual(controller.liveState.first?.id, a.id)
        XCTAssertEqual(controller.liveState.last?.id, b.id)
    }

    func testLiveStateCapConstantIsFifty() {
        XCTAssertEqual(UnifiedChatController.liveStateCap, 50)
    }

    func testAppendLiveStateTrimsFromTheHeadPastTheCap() {
        let controller = makeController()
        // Push one more than the cap; the oldest entry must fall off.
        var ids: [UUID] = []
        for i in 0..<(UnifiedChatController.liveStateCap + 1) {
            let entry = LiveStateEntry.routing(LiveRoutingEntry(useTessy: true, useSky: false, promptSummary: "\(i)"))
            ids.append(entry.id)
            controller.appendLiveState(entry)
        }
        XCTAssertEqual(controller.liveState.count, UnifiedChatController.liveStateCap)
        XCTAssertEqual(controller.liveState.first?.id, ids[1], "the very first (index 0) entry must have fallen off")
        XCTAssertEqual(controller.liveState.last?.id, ids.last)
    }

    // MARK: - setDocumentContext

    func testDocumentContextStartsNilAndCanBeSetAndCleared() {
        let controller = makeController()
        XCTAssertNil(controller.documentContext)
        let context = DocumentContext(documentID: UUID(), title: "Doc", promptSection: { "" })
        controller.setDocumentContext(context)
        XCTAssertEqual(controller.documentContext?.documentID, context.documentID)
        controller.setDocumentContext(nil)
        XCTAssertNil(controller.documentContext)
    }
}
