import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Agent/UnifiedChatRow.swift doc
// comments -- the five `LiveStateEntry` kinds (routing, toolCall,
// approvalPending, collabHandoff, holdQueue), each entry's `displayString`
// chip format, and `UnifiedChatRow.isSuperseded`.
final class UnifiedChatRowTests: DoctrineTestCase {

    // MARK: - UnifiedChatRow

    func testIsSupersededIsFalseByDefault() {
        let row = UnifiedChatRow(role: .user, content: "hi")
        XCTAssertFalse(row.isSuperseded)
    }

    func testIsSupersededIsTrueWhenSupersededByIDIsSet() {
        var row = UnifiedChatRow(role: .assistant, content: "hi")
        row.supersededByID = UUID()
        XCTAssertTrue(row.isSuperseded)
    }

    func testRowDefaultsIsStreamingFalseAndEmptyToolCalls() {
        let row = UnifiedChatRow(role: .assistant, content: "hi")
        XCTAssertFalse(row.isStreaming)
        XCTAssertTrue(row.toolCalls.isEmpty)
    }

    // MARK: - LiveRoutingEntry.chipLabel / displayString

    func testRoutingChipLabelTessyOnly() {
        let e = LiveRoutingEntry(useTessy: true, useSky: false, promptSummary: "p")
        XCTAssertEqual(e.chipLabel, "tessy only")
    }

    func testRoutingChipLabelSkyOnly() {
        let e = LiveRoutingEntry(useTessy: false, useSky: true, promptSummary: "p")
        XCTAssertEqual(e.chipLabel, "sky only")
    }

    func testRoutingChipLabelTeamUp() {
        let e = LiveRoutingEntry(useTessy: true, useSky: true, promptSummary: "p")
        XCTAssertEqual(e.chipLabel, "tessy + sky (team-up)")
    }

    func testRoutingChipLabelUnrouted() {
        let e = LiveRoutingEntry(useTessy: false, useSky: false, promptSummary: "p")
        XCTAssertEqual(e.chipLabel, "(unrouted)")
    }

    func testRoutingDisplayStringIncludesChipLabelAndPromptSummary() {
        let e = LiveRoutingEntry(useTessy: true, useSky: false, promptSummary: "hello world")
        XCTAssertEqual(e.displayString, "route: tessy only | prompt: hello world")
    }

    // MARK: - LiveToolCallEntry.displayString

    func testToolCallDisplayStringIncludesToolPersonaAndArgs() {
        let e = LiveToolCallEntry(persona: .sky, toolName: "quantize", argumentsSummary: "model=x")
        XCTAssertEqual(e.displayString, "tool: quantize | persona: sky | args: model=x")
    }

    // MARK: - LiveApprovalPendingEntry.displayString

    func testApprovalPendingDisplayStringIncludesAllFields() {
        let e = LiveApprovalPendingEntry(toolName: "bash", tierLabel: "T2", riskLabel: "medium", reason: "destructive verb")
        XCTAssertEqual(e.displayString, "approval: bash | risk: medium | tier: T2 | destructive verb")
    }

    // MARK: - LiveCollabHandoffEntry.displayString

    func testCollabHandoffDisplayStringShowsFromArrowTo() {
        let e = LiveCollabHandoffEntry(from: .tessy, to: .sky, text: "handing off complex task")
        XCTAssertEqual(e.displayString, "handoff: tessy -> sky | handing off complex task")
    }

    // MARK: - LiveHoldQueueEntry.displayString

    func testHoldQueueDisplayStringWhenRunning() {
        let e = LiveHoldQueueEntry(mode: .running, queuedCount: 0)
        XCTAssertEqual(e.displayString, "hold: running | queued: 0")
    }

    func testHoldQueueDisplayStringWhenHeldShowsQueuedCountAndResumeHint() {
        let e = LiveHoldQueueEntry(mode: .hold, queuedCount: 3)
        XCTAssertEqual(e.displayString, "hold: hold | queued: 3 | resume to drain")
    }

    func testHoldQueueDisplayStringWhenTransientlyPausedAlsoShowsResumeHint() {
        // holdRequested/resuming are transient-but-still-paused states
        // (HoldMode.isPaused doc comment); the display string treats them
        // the same as `.hold`.
        let e = LiveHoldQueueEntry(mode: .holdRequested, queuedCount: 1)
        XCTAssertEqual(e.displayString, "hold: holdRequested | queued: 1 | resume to drain")
    }

    func testHoldQueueDisplayStringWhenRunningIgnoresANonZeroQueuedCount() {
        // When not paused, the display string hardcodes "queued: 0"
        // regardless of the entry's `queuedCount` -- pinning this exact
        // (slightly surprising) behavior as documented by the source.
        let e = LiveHoldQueueEntry(mode: .running, queuedCount: 5)
        XCTAssertEqual(e.displayString, "hold: running | queued: 0")
    }

    // MARK: - LiveStateEntry: tagged union id/timestamp/kindLabel/displayString
    // delegation (independent oracle: pinned against the 5 documented
    // kinds, rule 7)

    func testLiveStateEntryHasExactlyFiveDocumentedKinds() {
        let kinds: Set<String> = [
            LiveStateEntry.routing(LiveRoutingEntry(useTessy: true, useSky: false, promptSummary: "")).kindLabel,
            LiveStateEntry.toolCall(LiveToolCallEntry(persona: .tessy, toolName: "x", argumentsSummary: "")).kindLabel,
            LiveStateEntry.approvalPending(LiveApprovalPendingEntry(toolName: "x", tierLabel: "T0", riskLabel: "low", reason: "")).kindLabel,
            LiveStateEntry.collabHandoff(LiveCollabHandoffEntry(from: .tessy, to: .sky, text: "")).kindLabel,
            LiveStateEntry.holdQueue(LiveHoldQueueEntry(mode: .running, queuedCount: 0)).kindLabel,
        ]
        XCTAssertEqual(kinds, ["Routing", "Tool calls", "Approvals", "Team-up handoffs", "Hold queue"])
    }

    func testLiveStateEntryIdDelegatesToTheWrappedEntry() {
        let routingEntry = LiveRoutingEntry(useTessy: true, useSky: false, promptSummary: "p")
        let wrapped = LiveStateEntry.routing(routingEntry)
        XCTAssertEqual(wrapped.id, routingEntry.id)
    }

    func testLiveStateEntryTimestampDelegatesToTheWrappedEntry() {
        let timestamp = Date(timeIntervalSince1970: 12345)
        let toolCallEntry = LiveToolCallEntry(timestamp: timestamp, persona: .tessy, toolName: "x", argumentsSummary: "")
        let wrapped = LiveStateEntry.toolCall(toolCallEntry)
        XCTAssertEqual(wrapped.timestamp, timestamp)
    }

    func testLiveStateEntryDisplayStringDelegatesToTheWrappedEntry() {
        let handoff = LiveCollabHandoffEntry(from: .sky, to: .tessy, text: "back to tessy")
        let wrapped = LiveStateEntry.collabHandoff(handoff)
        XCTAssertEqual(wrapped.displayString, handoff.displayString)
    }

    // MARK: - Equatable value semantics on entries (used by liveState
    // dedup/testing elsewhere)

    func testLiveRoutingEntryEqualityIsFieldwise() {
        let id = UUID()
        let timestamp = Date()
        let a = LiveRoutingEntry(id: id, timestamp: timestamp, useTessy: true, useSky: false, promptSummary: "p")
        let b = LiveRoutingEntry(id: id, timestamp: timestamp, useTessy: true, useSky: false, promptSummary: "p")
        XCTAssertEqual(a, b)
    }
}
