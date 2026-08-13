import XCTest
@testable import TesseraCore

/// The tool-approval gate, end to end from the engine's parked
/// continuation to the surface that resolves it.
///
/// The regression these cover: `requestApprovalForced` parks a
/// continuation, and for three waves nothing in the app ever resumed it
/// (`ApprovalSheet` was never constructed, `resolvePending` had no
/// non-test caller). A gated tool call hung the turn forever with no
/// visible prompt. Every test here fails if that wiring is cut again.
@MainActor
final class ApprovalGateWiringTests: XCTestCase {

    // MARK: - Engine publishes its pending request

    /// A parked gate must reach an observer. Without this the sheet has
    /// nothing to present and the loop blocks forever.
    func testForcedRequestNotifiesObserverBeforeParking() async {
        let engine = TesseraApprovalEngine()
        var seen: [String?] = []
        engine.onPendingChange = { seen.append($0?.toolName) }

        let task = Task { await engine.requestApprovalForced(toolName: "write_file", arguments: [:]) }
        await Task.yield()

        XCTAssertEqual(seen, ["write_file"], "the gate must publish before it parks")
        XCTAssertEqual(engine.pendingRequest?.toolName, "write_file")

        engine.resolvePending(approved: true)
        let approved = await task.value
        XCTAssertTrue(approved)
    }

    /// Resolving clears the published request, so a surface bound to it
    /// dismisses rather than showing a stale gate.
    func testResolveClearsPendingAndNotifiesNil() async {
        let engine = TesseraApprovalEngine()
        var seen: [String?] = []
        engine.onPendingChange = { seen.append($0?.toolName) }

        let task = Task { await engine.requestApprovalForced(toolName: "delete_file", arguments: [:]) }
        await Task.yield()
        engine.resolvePending(approved: false)

        let approved = await task.value
        XCTAssertFalse(approved)
        XCTAssertNil(engine.pendingRequest)
        XCTAssertEqual(seen, ["delete_file", nil])
    }

    /// A denial must propagate as `false`, not merely dismiss the sheet.
    /// The loop turns this into "Denied by user" and feeds the breaker.
    func testDenialPropagatesFalse() async {
        let engine = TesseraApprovalEngine()
        let task = Task { await engine.requestApprovalForced(toolName: "send_email", arguments: [:]) }
        await Task.yield()
        engine.resolvePending(approved: false)
        let approved = await task.value
        XCTAssertFalse(approved)
    }

    /// Resolving with nothing parked must not trap. The surface can race
    /// a dismissal against the loop finishing on its own.
    func testResolveWithNoPendingIsSafe() {
        let engine = TesseraApprovalEngine()
        engine.resolvePending(approved: true)
        XCTAssertNil(engine.pendingRequest)
    }

    /// A superseding request must not strand the older continuation.
    /// One loop awaits its own gate so this is unreachable today, but a
    /// dropped continuation is an unrecoverable hang, so it fails safe.
    func testSupersedingRequestDeniesTheOlderOneRatherThanStrandingIt() async {
        let engine = TesseraApprovalEngine()
        let first = Task { await engine.requestApprovalForced(toolName: "first", arguments: [:]) }
        await Task.yield()
        let second = Task { await engine.requestApprovalForced(toolName: "second", arguments: [:]) }
        await Task.yield()

        let firstResult = await first.value
        XCTAssertFalse(firstResult, "the superseded gate must resolve, denied")

        engine.resolvePending(approved: true)
        let secondResult = await second.value
        XCTAssertTrue(secondResult)
    }

    // MARK: - Controller bridges the engine to the surface

    /// The controller must republish either loop's gate as the union the
    /// dock's sheet binds to. This is the link that was missing.
    func testControllerPublishesTessyGateAsPendingApproval() async {
        let controller = UnifiedChatController()
        XCTAssertNil(controller.pendingApproval)

        let task = Task {
            await controller.tessyLoop.approvalEngine.requestApprovalForced(
                toolName: "write_file",
                arguments: ["path": .string("/tmp/x")]
            )
        }
        await Task.yield()

        XCTAssertEqual(controller.pendingApproval?.toolName, "write_file")
        XCTAssertEqual(controller.pendingApproval?.speaker, .tessy)

        controller.tessyLoop.approvalEngine.resolvePending(approved: true)
        _ = await task.value
    }

    /// Sky's gate is bridged too, and tagged with the right speaker so
    /// the sheet names the agent that asked.
    func testControllerPublishesSkyGateWithSkySpeaker() async {
        let controller = UnifiedChatController()
        let task = Task {
            await controller.skyLoop.approvalEngine.requestApprovalForced(
                toolName: "search_web",
                arguments: [:]
            )
        }
        await Task.yield()

        XCTAssertEqual(controller.pendingApproval?.speaker, .sky)

        controller.skyLoop.approvalEngine.resolvePending(approved: false)
        _ = await task.value
    }

    /// Resolving through the union's closure must resume the loop. This
    /// is the exact path the sheet's Approve button takes.
    func testResolveApprovalThroughUnionResumesTheLoop() async {
        let controller = UnifiedChatController()
        let task = Task {
            await controller.tessyLoop.approvalEngine.requestApprovalForced(
                toolName: "write_file",
                arguments: [:]
            )
        }
        await Task.yield()

        guard let pending = controller.pendingApproval else {
            return XCTFail("no gate was published")
        }
        controller.resolveApproval(pending, approved: true)

        let approved = await task.value
        XCTAssertTrue(approved, "the sheet's Approve must resume the parked loop")
        XCTAssertNil(controller.pendingApproval)
    }

    /// The gate also lands in the progress feed, so a user who dismissed
    /// their attention elsewhere can still find what was asked.
    func testGateIsRecordedInTheProgressFeed() async {
        let controller = UnifiedChatController()
        let task = Task {
            await controller.tessyLoop.approvalEngine.requestApprovalForced(
                toolName: "delete_file",
                arguments: [:]
            )
        }
        await Task.yield()

        let approvals = controller.liveState.compactMap { entry -> LiveApprovalPendingEntry? in
            if case .approvalPending(let e) = entry { return e }
            return nil
        }
        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(approvals.first?.toolName, "delete_file")

        controller.tessyLoop.approvalEngine.resolvePending(approved: false)
        _ = await task.value
    }
}

// MARK: - Safety facts

/// ``ApprovalSafetyFacts`` is the one derivation the sheet, the feed,
/// and the audit log share. If it drifts, the same action gets two
/// different tiers on two surfaces.
final class ApprovalSafetyFactsTests: XCTestCase {

    /// Pure: same action in, same facts out.
    func testDerivationIsPure() {
        let a = ApprovalSafetyFacts(toolName: "delete_file", arguments: ["path": .string("/tmp/x")])
        let b = ApprovalSafetyFacts(toolName: "delete_file", arguments: ["path": .string("/tmp/x")])
        XCTAssertEqual(a, b)
    }

    /// A destructive verb must not be labelled reversible; the sheet
    /// swaps its button emphasis on exactly this flag.
    func testDestructiveVerbIsIrreversible() {
        let facts = ApprovalSafetyFacts(toolName: "delete_file", arguments: ["path": .string("/tmp/x")])
        XCTAssertTrue(facts.isIrreversible)
        XCTAssertEqual(facts.reversibilityLabel, "irreversible")
    }

    /// An irreversible action must never land in the auto tier.
    func testIrreversibleActionIsNotTier0() {
        let facts = ApprovalSafetyFacts(toolName: "delete_file", arguments: [:])
        XCTAssertGreaterThan(facts.tier, .tier0)
    }

    /// The chip vocabulary matches the audit-log head: `field: value`
    /// pairs joined by `|`, capped at the shared field cap.
    func testDisplayStringUsesSharedChipVocabulary() {
        let facts = ApprovalSafetyFacts(toolName: "write_file", arguments: [:])
        let fields = facts.displayString.components(separatedBy: " | ")
        XCTAssertLessThanOrEqual(fields.count, AuditLogHead.fieldCap)
        XCTAssertTrue(facts.displayString.hasPrefix("tier: "))
        XCTAssertTrue(fields.allSatisfy { $0.contains(": ") })
        XCTAssertTrue(facts.displayString.contains("tool: write_file"))
    }

    /// An unclassifiable action must still render a tier rather than an
    /// empty chip: fail-closed to medium, per the verifier contract.
    func testUnknownToolFallsBackToMediumRisk() {
        let facts = ApprovalSafetyFacts(toolName: "zzz_unknown_tool", arguments: [:])
        XCTAssertEqual(facts.risk, .medium)
        XCTAssertFalse(facts.displayString.contains("class: \n"))
    }
}
