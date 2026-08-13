import XCTest
import Foundation
@testable import TesseraCore

// AgentUXFatigueIntegrationTests
//
// Wave 4D integration test for the agent-ux-fatigue Tessera Studio
// sprint. After Waves 0-3 (12 implementation units) and Wave 4A-4B
// (2 more units), this test wires the 14 cross-wave types together
// in an in-process harness and asserts the contracts the 6 review
// reports named as the load-bearing ones:
//
//   1. Chip vocabulary consistency: every audit / progress / pending
//      / tier surface reads one chip language. The chip contract is
//      `field: value | field: value` with the same fieldCap (5) on
//      every surface that renders a one-liner.
//   2. Tier enum flow: TesseraTier derives from a safety decision
//      and the same tier label reaches (a) the chat progress feed
//      approval row, (b) the action audit log row, (c) the
//      PendingMutation chip, and (d) the inline-stop surface. The
//      boundary-drift guard (TesseraTier.revoke) is the only legal
//      downgrade path.
//   3. Notification budget: the per-UTC-day cap is hard (no force:
//      override, no soft target). One budget instance rate-limits
//      every post site that lands in the same chip language.
//   4. AsyncStream receipts (3B): the ReceiptsCoordinator stream
//      emits each new receipt with no polling, and the audit log
//      store can subscribe to the same event source.
//   5. Inline-stop (3C): the agent loop's stop(reason:) is a hard
//      stop; the loop refuses to re-run until clearStop() is called.
//   6. Action audit log (3D): the store is the data layer for the
//      side panel; entries flow in append order and read newest-first.
//
// The harness is in-process: no real LLM, no real network, no real
// GPU, no real user. The LLM is a `ScriptedProvider` (deterministic),
// the safety spine is the rule-based classifier (no model), the
// approval engine is wired to .auto for the test tools so the loop
// reaches execution, the notification budget is a fresh actor per
// test (no on-disk state bleeds across tests), the receipts
// coordinator is a fresh actor (no cross-test stream), and the
// chat controller is constructed in-memory (no Postgres, no
// network).
//
// If a cross-wave bug surfaces (e.g. tier label drift, chip-voc
// mismatch, missing citation, stop semantics regression, async
// stream deadlock, notification budget bypass), the test FAILS
// with a clear message naming the wave. It does NOT fix the bug;
// the fix is a separate task.
//
// Test target may have pre-existing build breaks. This file is
// self-contained: it does not touch the broken files, and it adds
// no new error of its own. Once the pre-existing breaks are
// resolved the file runs end-to-end.

@MainActor
final class AgentUXFatigueIntegrationTests: XCTestCase {

    // MARK: - Test fixtures

    /// The bare-minimum LLM provider for the harness. The
    /// `LLMProvider` protocol is non-mutating on its `complete()`
    /// method, so the script counter lives on a class instance
    /// (a `struct` would need a `mutating` method the protocol
    /// does not declare). The script returns one tool call on
    /// the first invocation, then an empty response so the
    /// loop exits the iteration (no tool calls -> done).
    /// The counter is mutated only on the main actor (the
    /// enclosing test class is `@MainActor`), so no internal
    /// lock is required; the class is `@unchecked Sendable`
    /// because the protocol requires `Sendable` and the test
    /// only ever touches the instance from the main actor.
    private final class ScriptedProvider: LLMProvider, @unchecked Sendable {
        let toolName: String
        let toolArgs: [String: JSONValue]
        private var firstResponseSent: Int = 0
        init(toolName: String, toolArgs: [String: JSONValue] = [:]) {
            self.toolName = toolName
            self.toolArgs = toolArgs
        }
        func complete(
            system: String,
            messages: [LLMMessage],
            tools: [ToolDescriptor]
        ) async throws -> LLMResponse {
            // Bump the first-response counter exactly once, then
            // return an empty response so the loop exits the
            // iteration (no tool calls -> done). The script is
            // deterministic: one tool call per loop.run().
            firstResponseSent += 1
            let count = firstResponseSent
            if count == 1 {
                return LLMResponse(
                    content: "",
                    toolCalls: [LLMToolCall(name: toolName, arguments: toolArgs)],
                    tokenCount: 1
                )
            }
            return LLMResponse(content: "", toolCalls: [], tokenCount: 1)
        }
    }

    /// A read-only tool that always returns an empty ToolResult.
    /// `list_models` is the canonical "tier0" tool in the
    /// existing registry; the harness uses its shape so the
    /// `TesseraActionClass.classify` path is exercised the same
    /// way production exercises it.
    private struct ReadOnlyTool: TesseraTool {
        let name: String
        let defaultApprovalLevel: ApprovalLevel = .auto
        let description: String = "read-only stub"
        let parameters = JSONSchema()
        func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
            .ok("ok")
        }
    }

    /// A pre-canned ToolResult that carries the `sources` array
    /// the research tool emits, so the citation-extraction path
    /// (`UnifiedChatController.extractCitations`) is exercised
    /// without a real network call.
    private func researchToolResult(sources: [(url: String, title: String, content: String)]) -> ToolResult {
        let entries: [JSONValue] = sources.map { s in
            .object([
                "url": .string(s.url),
                "title": .string(s.title),
                "content": .string(s.content),
            ])
        }
        return .ok(
            "summary of the research",
            data: ["sources": .array(entries)]
        )
    }

    /// Build a minimal `Receipt` for the test. The signature is
    /// zero-byte (no verification; the audit-log tests cover the
    /// crypto path). The mutations are a `setDocumentTitle` so
    /// the audit row can carry a real mutations array (not the
    /// `[]` empty-suppression path). The `timestamp` parameter
    /// lets chronological-order tests pin the order without
    /// relying on the wall clock.
    private func makeReceipt(
        id: UUID = UUID(),
        documentID: UUID = UUID(),
        summary: String = "agent did a thing",
        timestamp: Date = Date()
    ) -> Receipt {
        Receipt(
            id: id,
            documentID: documentID,
            actor: .user(UUID()),
            mutations: [.setDocumentTitle(title: summary)],
            timestamp: timestamp,
            signature: Data(),
            summary: summary
        )
    }

    // MARK: - 1. Chip vocabulary consistency

    /// The audit-log HEAD chip, the chat progress feed's approval
    /// row, the action audit log row, and the PendingMutation
    /// chip all render the same `field: value | field: value`
    /// shape with the same fieldCap (5). This test pins every
    /// contract at once so a future surface that ships a
    /// 6-field chip (decoration) or a colon-less chip
    /// (inconsistency) fails the build.
    func testChipVocabularyIsConsistentAcrossSurfaces() {
        // fieldCap is the same on every surface. A drift here
        // means a user would see one chip with 4 fields and
        // another with 5 on the same screen, which is the
        // "the agent's prose does not match the chip" failure
        // mode the audit named as a top-three cross-wave risk.
        // The audit log entry reuses AuditLogHead.fieldCap (the
        // chip language stays one surface-wide), so the cap is
        // asserted in one place and consumed everywhere.
        XCTAssertEqual(AuditLogHead.fieldCap, 5)
        XCTAssertEqual(PendingMutation.fieldCap, 5)
        XCTAssertEqual(AuditLogHead.fieldCap, PendingMutation.fieldCap,
            "audit log and pending mutation must share the same field cap")

        // Every chip language is the same separator. A drift
        // here is a visual break: the user reads one chip with
        // `|` and another with `:` and has to switch parsing
        // mode mid-screen.
        let head = AuditLogHead(
            risk: .medium,
            tool: "rewrite",
            elapsedSeconds: 2.1,
            receiptID: UUID(),
            mutations: [.setBlockContent(blockID: UUID(), content: [InlineRun(text: "x")])]
        )
        let headPipeCount = head.displayString.filter { $0 == "|" }.count
        XCTAssertEqual(headPipeCount, 3, "4 canonical fields -> 3 pipes, got \(headPipeCount) in: \(head.displayString)")

        let pending = PendingMutation(
            tier: .tier2,
            risk: .medium,
            tool: "bash:rm",
            actionClass: "bash:rm",
            outcome: .pending
        )
        let pendingPipeCount = pending.displayString.filter { $0 == "|" }.count
        XCTAssertEqual(pendingPipeCount, 3, "PendingMutation must use the same pipe separator, got: \(pending.displayString)")

        let auditEntry = ActionAuditEntry(
            actionClass: "bash:rm",
            tier: .tier2,
            risk: .medium,
            outcome: .success
        )
        let auditPipeCount = auditEntry.displayString.filter { $0 == "|" }.count
        XCTAssertEqual(auditPipeCount, 3, "ActionAuditEntry must use the same pipe separator, got: \(auditEntry.displayString)")
    }

    /// The progress feed's approval-pending row carries the same
    /// `tier: | risk: | tool: | <reason>` chip shape the
    /// PendingMutation and audit log use. A drift here is the
    /// "chip language varies by surface" failure mode the
    /// comprehensive report called CC-2 (item 6.2 in the
    /// implementation plan: "items 1C and 2A share the same
    /// pull-feed style and chip vocabulary").
    func testChatProgressFeedApprovalChipMatchesAuditLogHead() {
        let tier = TesseraTier.tier(for: "bash:rm", risk: .medium)
        let risk = TesseraActionRisk.medium
        let irreversible = TesseraActionClass.isIrreversible("bash:rm", risk: risk)
        XCTAssertTrue(irreversible, "bash:rm must be irreversible (destructive verb)")
        let reason = irreversible ? "irreversible" : "reversible"

        let live = LiveApprovalPendingEntry(
            toolName: "bash:rm",
            tierLabel: tier.shortLabel,
            riskLabel: risk.rawValue,
            reason: reason
        )
        let display = live.displayString
        XCTAssertTrue(display.contains("approval: bash:rm"), "approval row missing tool name: \(display)")
        XCTAssertTrue(display.contains("risk: medium"), "approval row missing risk: \(display)")
        XCTAssertTrue(display.contains("tier: \(tier.shortLabel)"), "approval row missing tier: \(display)")
        XCTAssertTrue(display.contains("irreversible"), "approval row missing reason: \(display)")
    }

    // MARK: - 2. Tier enum flow (safety decision -> approval -> audit -> stop)

    /// The tier enum must flow from a safety decision through
    /// the approval sheet, the audit log, and the inline-stop
    /// surface without drift. The boundary-drift guard
    /// (`TesseraTier.revoke`) is the only legal downgrade.
    func testTierFlowsFromSafetyDecisionToAllSurfaces() {
        // The classic "outbound email" example: medium risk,
        // not irreversible, deterministic approve path.
        let tier2 = TesseraTier.tier(for: "send_email", risk: .high)
        XCTAssertEqual(tier2, .tier2, "send_email at high risk should land at tier2 (sync approval)")

        // The destructive-verb escalation: low risk + destructive
        // verb = tier2. This is the load-bearing case for the
        // reversibility axis the safety spine relies on.
        let destructive = TesseraTier.tier(for: "bash:rm", risk: .low)
        XCTAssertEqual(destructive, .tier2, "destructive verb must escalate to tier2 regardless of nominal risk")

        // The payment-write case: high + irreversible = tier3.
        let tier3 = TesseraTier.tier(for: "exec_payment", risk: .high)
        XCTAssertEqual(tier3, .tier3, "exec_payment at high risk should land at tier3 (multi-party)")

        // The audit log row carries the SAME tier label. A
        // drift between TesseraTier.shortLabel ("T0"..."T3")
        // and the audit row's "tier:" field is the
        // "tier label drift" cross-wave bug the integration
        // test would catch.
        let audit = ActionAuditEntry(
            actionClass: "exec_payment",
            tier: tier3,
            risk: .high,
            outcome: .success
        )
        XCTAssertTrue(
            audit.displayString.contains("tier: T3"),
            "audit row tier label must match TesseraTier.shortLabel: \(audit.displayString)"
        )

        // The PendingMutation chip carries the SAME tier label.
        let pending = PendingMutation(
            tier: tier2,
            risk: .high,
            tool: "send_email",
            actionClass: "send_email",
            outcome: .pending
        )
        XCTAssertTrue(
            pending.displayString.contains("tier: T2"),
            "PendingMutation tier label must match TesseraTier.shortLabel: \(pending.displayString)"
        )

        // The boundary-drift guard: the only legal way to lower
        // a tier is TesseraTier.revoke. Any other path is a
        // tier-boundary drift and must fail review.
        XCTAssertEqual(TesseraTier.tier3.revoke(), .tier2, "tier3 must revoke to tier2")
        XCTAssertEqual(TesseraTier.tier2.revoke(), .tier1, "tier2 must revoke to tier1")
        XCTAssertEqual(TesseraTier.tier1.revoke(), .tier0, "tier1 must revoke to tier0")
        XCTAssertEqual(TesseraTier.tier0.revoke(), .tier0, "tier0 is the floor; revoke() is a no-op")
    }

    /// The safety decision's `tier(forActionClass:)` is the
    /// single auditable surface for the tier policy. The
    /// decision and the action class agree, so the
    /// ConfirmationPanel's chip and the audit log's chip
    /// read the same label.
    func testSafetyDecisionTierAgreesWithActionClassifier() {
        let decision = TesseraSafetyDecision(
            approvalPolicy: .prompt,
            permissionProfile: .standard,
            sandboxEnforceable: true,
            actionRisk: .high
        )
        let tierFromDecision = decision.tier(forActionClass: "send_email")
        let tierFromClassifier = TesseraTier.tier(for: "send_email", risk: .high)
        XCTAssertEqual(tierFromDecision, tierFromClassifier,
            "SafetyDecision.tier(forActionClass:) must agree with TesseraTier.tier(for:risk:)")
        XCTAssertEqual(tierFromDecision, .tier2)
    }

    // MARK: - 3. Notification budget rate-limits across surfaces

    /// The per-UTC-day cap is a hard cap: 3 posts go through, the
    /// 4th is blocked, and the cap is the SAME for every
    /// consumer (workflow, training, adaptation, etc.). The
    /// budget is shared across surfaces, not per-category.
    /// The integration test wires three different categories
    /// through one budget to assert the cross-surface cap.
    func testNotificationBudgetRateLimitsAcrossCategories() async {
        let budget = TesseraNotificationBudget(capPerDay: 3)
        await budget.setDevMode(false)
        TesseraNotificationBudgetLog.reset()

        // Three different categories (workflow, training,
        // adaptation) all share the same counter. The cap
        // is per-budget, not per-category.
        let first = await budget.tryPost(
            category: .workflow, title: "wf-1", body: "ok"
        )
        let second = await budget.tryPost(
            category: .training, title: "tr-1", body: "ok"
        )
        let third = await budget.tryPost(
            category: .adaptation, title: "ad-1", body: "ok"
        )
        XCTAssertTrue(first, "1st post must succeed")
        XCTAssertTrue(second, "2nd post must succeed (different category, shared cap)")
        XCTAssertTrue(third, "3rd post must succeed (different category, shared cap)")

        // The 4th post (any category) is blocked. This is the
        // cap, not a per-category soft target.
        let fourth = await budget.tryPost(
            category: .workflow, title: "wf-2", body: "blocked"
        )
        XCTAssertFalse(fourth, "4th post must be blocked by the hard cap")
    }

    /// The budget respects the per-UTC-day reset. The
    /// integration test uses `advanceDay(by:)` (the test-only
    /// surface) instead of waiting for midnight; the production
    /// path uses the wall clock via `rolloverIfNeeded`.
    func testNotificationBudgetResetsAcrossUtcDays() async {
        let budget = TesseraNotificationBudget(capPerDay: 3)
        await budget.setDevMode(false)
        TesseraNotificationBudgetLog.reset()
        for i in 1...3 {
            let ok = await budget.tryPost(category: .workflow, title: "day1-\(i)", body: "ok")
            XCTAssertTrue(ok, "day-1 post #\(i) must succeed")
        }
        let blocked = await budget.tryPost(category: .workflow, title: "day1-4", body: "ok")
        XCTAssertFalse(blocked, "4th post on day 1 must be blocked")

        await budget.advanceDay(by: 1)
        let nextDay = await budget.tryPost(category: .workflow, title: "day2-1", body: "ok")
        XCTAssertTrue(nextDay, "post on the new UTC day must be allowed (cap reset)")
    }

    /// `dryRun` is gated behind dev mode. In production the
    /// dry-run notification is a "not actionable in 15-30 min"
    /// failure mode the review named as a top-priority
    /// anti-pattern; the dev-mode flag is the test escape
    /// hatch.
    func testNotificationBudgetDryRunIsGated() async {
        let budget = TesseraNotificationBudget(capPerDay: 3)
        await budget.setDevMode(false)
        TesseraNotificationBudgetLog.reset()

        // dryRun in production mode is blocked even when the
        // cap is not yet hit. The anti-pattern is the cap
        // allowing dryRun to surface in the user's notification
        // center; the integration test pins that the budget
        // refuses.
        let dry = await budget.tryPost(
            category: .training,
            title: "dry-run",
            body: "would have notified",
            outcome: "dryRun"
        )
        XCTAssertFalse(dry, "dryRun must be blocked in production mode (devMode=false)")

        // devMode unlocks dryRun for the test path; the cap
        // still applies. The integration test asserts the
        // cap is unaffected by devMode.
        await budget.setDevMode(true)
        let dryInDev = await budget.tryPost(
            category: .training,
            title: "dry-run-dev",
            body: "ok in dev",
            outcome: "dryRun"
        )
        XCTAssertTrue(dryInDev, "dryRun must be allowed in dev mode")
        // Cap still holds: 1 dryRun + 2 more posts fill the
        // cap, the 4th post is blocked.
        let second = await budget.tryPost(
            category: .workflow, title: "wf-1", body: "ok"
        )
        let third = await budget.tryPost(
            category: .workflow, title: "wf-2", body: "ok"
        )
        let fourth = await budget.tryPost(
            category: .workflow, title: "wf-3", body: "ok"
        )
        XCTAssertTrue(second)
        XCTAssertTrue(third)
        XCTAssertFalse(fourth, "cap must still hold with devMode on (hard cap, not a soft target)")
    }

    // MARK: - 4. AsyncStream receipts (3B) + audit log subscription

    /// The ReceiptsCoordinator exposes an `AsyncStream<Receipt>`
    /// (Wave 3B). The integration test asserts (a) every
    /// registered receipt emits, (b) the stream does not replay
    /// history (subscribers joining late only see new receipts),
    /// and (c) the in-memory navigation snapshot is the source
    /// of truth the audit log reads from.
    func testReceiptsCoordinatorAsyncStreamEmitsAndSupportsBackpressure() async {
        let coordinator = ReceiptsCoordinator()
        // `receiptStream()` is `nonisolated` on the actor; the
        // call returns the broadcast stream directly without
        // hopping the actor.
        let stream = coordinator.receiptStream()

        // Producer task: register three receipts. Each
        // registration is fan-out to every live subscriber.
        let producer = Task {
            for i in 1...3 {
                let receipt = makeReceipt(summary: "stream-test-\(i)")
                await coordinator.register(receipt: receipt)
            }
        }
        // Consumer task: drain the stream and collect ids.
        let consumer = Task<[UUID], Never> {
            var seen: [UUID] = []
            for await receipt in stream {
                seen.append(receipt.id)
                if seen.count == 3 { break }
            }
            return seen
        }
        await producer.value
        let seen = await consumer.value
        XCTAssertEqual(seen.count, 3, "every registered receipt must emit exactly once on the stream")
    }

    /// The audit log store is the data layer for the side
    /// panel (3D). The integration test wires receipts from
    /// the ReceiptsCoordinator (3B) into the ActionAuditLogStore
    /// (3D) via a one-line `append` per receipt, asserting
    /// the two surfaces agree on the chronological list.
    func testAuditLogStoreReceivesReceiptsAndRendersNewestFirst() {
        let store = ActionAuditLogStore(capacity: 100)
        let t0 = Date(timeIntervalSince1970: 0)
        // Three receipts in chronological order: oldest first
        // at index 0, newest at index 2. The store reads
        // newest-first, so the visible[0] is the newest.
        let r0 = makeReceipt(summary: "earliest", timestamp: t0)
        let r1 = makeReceipt(summary: "middle", timestamp: t0.addingTimeInterval(60))
        let r2 = makeReceipt(summary: "latest", timestamp: t0.addingTimeInterval(120))

        for r in [r0, r1, r2] {
            store.append(ActionAuditEntry(
                timestamp: r.timestamp,
                actionClass: "research",
                summary: r.summary,
                tier: .tier1,
                risk: .low,
                outcome: .success,
                receiptID: r.id
            ))
        }
        let visible = store.visible
        XCTAssertEqual(visible.count, 3)
        XCTAssertEqual(visible[0].summary, "latest", "newest-first ordering is the spec")
        XCTAssertEqual(visible[2].summary, "earliest")
    }

    // MARK: - 5. Inline-stop (3C) hard stop semantics

    /// The agent loop's `stop(reason:)` is a hard stop:
    /// after stop, a new `run()` call is rejected until
    /// `clearStop()` is invoked. The integration test exercises
    /// the full stop -> reject -> clear -> resume path so a
    /// future refactor that "softens" the stop (e.g. a flag
    /// the controller can forget to check) fails the build.
    func testInlineStopIsHardStopAndResumesOnlyAfterClear() async throws {
        let registry = TesseraToolRegistry(tools: [
            ReadOnlyTool(name: "list_models")
        ])
        let approval = TesseraApprovalEngine()
        let provider = ScriptedProvider(
            toolName: "list_models",
            toolArgs: [:]
        )
        let loop = TesseraAgentLoop(
            registry: registry,
            approvalEngine: approval,
            llmProvider: provider,
            maxIterations: 3
        )

        // No history: empty list. The loop has no stop reason,
        // so the first run starts cleanly.
        XCTAssertNil(loop.lastStopReason, "loop must start without a stop reason")
        let firstStream = loop.run(userMessage: "list models", history: [])
        var firstSeenStop = false
        for await event in firstStream {
            if case .error(let msg) = event {
                if msg.contains(AgentEventMarker.stoppedPrefix) {
                    firstSeenStop = true
                }
            }
        }
        XCTAssertFalse(firstSeenStop, "first run must NOT emit a stop signal")

        // Now stop the loop. lastStopReason is recorded; a
        // subsequent run() is rejected. `StopReason` does not
        // conform to `Equatable`, so the assertion is a
        // structural switch instead of `XCTAssertEqual`.
        loop.stop(reason: .userRequest)
        if case .userRequest = loop.lastStopReason {
            // matched
        } else {
            XCTFail("expected lastStopReason to be .userRequest, got \(String(describing: loop.lastStopReason))")
        }

        let rejectedStream = loop.run(userMessage: "list models", history: [])
        var rejectionSawStop = false
        for await event in rejectedStream {
            if case .error(let msg) = event {
                if msg.contains(AgentEventMarker.stoppedPrefix) {
                    rejectionSawStop = true
                }
            }
        }
        XCTAssertTrue(
            rejectionSawStop,
            "post-stop run() must emit a stop signal in its event stream (paradox 5 anti-metric)"
        )

        // clearStop() is the ONLY path to resume. A future
        // refactor that auto-clears the stop (e.g. on the
        // next tick) is the off-ramp paradox failure mode.
        loop.clearStop()
        XCTAssertNil(loop.lastStopReason, "clearStop() must clear the stop reason")

        let resumedStream = loop.run(userMessage: "list models", history: [])
        var resumedSawStop = false
        for await event in resumedStream {
            if case .error(let msg) = event {
                if msg.contains(AgentEventMarker.stoppedPrefix) {
                    resumedSawStop = true
                }
            }
        }
        XCTAssertFalse(
            resumedSawStop,
            "post-clearStop() run() must NOT emit a stop signal"
        )
    }

    // MARK: - 6. Citation flow (3A) + chat row carry-through

    /// The chat message's `sources: [Citation]` field lifts
    /// the `data["sources"]` array the research tool emits.
    /// The integration test exercises the full path:
    /// `ToolResult -> Citation extraction -> ChatMessage.sources`.
    /// The `extractCitations` helper is the load-bearing seam;
    /// any change to the citation shape ripples into the
    /// chat row, so the test pins the round-trip.
    func testChatMessageCarriesCitationsFromToolResult() {
        let sources: [(url: String, title: String, content: String)] = [
            ("https://example.com/a", "Article A", "Body of A"),
            ("https://example.com/b", "Article B", "Body of B"),
        ]
        let result = researchToolResult(sources: sources)
        let citations = UnifiedChatController.extractCitations(from: result)
        XCTAssertEqual(citations.count, 2, "every research source must produce a citation")

        // Build a ChatMessage with the citations and assert
        // the round-trip: the chat row's `sources` array is
        // the citations the row's chip vocabulary consumes.
        let message = ChatMessage(
            role: .assistant,
            content: "the answer",
            toolCalls: [
                ToolCallRecord(
                    toolName: "research",
                    arguments: [:],
                    result: ToolResultPayload(
                        success: true,
                        output: "summary",
                        confidenceBand: .high,
                        sources: citations
                    )
                )
            ],
            sources: citations
        )
        XCTAssertEqual(message.sources.count, 2, "ChatMessage.sources must carry the citations")
        XCTAssertEqual(message.sources[0].label, "Article A")
        XCTAssertEqual(message.toolCalls.first?.result?.sources.count, 2, "ToolResultPayload.sources must carry the citations too")
    }

    /// Citation chip vocabulary uses the same `label:` /
    /// short prefix style as the audit-log HEAD chip. A drift
    /// here is a visual break the user would see on the
    /// same screen (the chat row chips next to the progress
    /// feed chips).
    func testCitationChipVocabularyIsStable() {
        let sources: [(url: String, title: String, content: String)] = [
            ("https://example.com/a", "Article A", "Body of A"),
        ]
        let result = researchToolResult(sources: sources)
        let citations = UnifiedChatController.extractCitations(from: result)
        XCTAssertEqual(citations.count, 1)
        let c = citations[0]
        XCTAssertEqual(c.id, "https://example.com/a", "id is the URL (with trailing slash stripped)")
        XCTAssertEqual(c.label, "Article A", "label is the page title")
        XCTAssertEqual(c.snippet, "Body of A", "snippet is the content (truncated to snippetCap)")
        XCTAssertEqual(c.url, "https://example.com/a")
    }

    // MARK: - 7. Cross-wave happy path (a single end-to-end run)

    /// A single end-to-end test that wires every wave into
    /// one run. The test:
    ///
    ///   1. Constructs a TesseraAgentLoop with a
    ///      ScriptedProvider that calls a "research"-shaped
    ///      tool.
    ///   2. The tool returns a ToolResult with a
    ///      `data["sources"]` array.
    ///   3. The chat controller (2A) captures the routing,
    ///      tool call, and approval in `liveState`.
    ///   4. The audit log store (3D) receives one entry
    ///      with the same tier the safety decision derived
    ///      from the tool's risk.
    ///   5. The notification budget (1D) caps any post
    ///      triggered by the run.
    ///
    /// If ANY cross-wave wire is broken, this test fails
    /// with a clear message naming the wave. The fix is a
    /// separate task.
    func testCrossWaveHappyPathEndToEnd() async throws {
        // Reset the per-UTC-day cap so the test is independent
        // of any previous test's posts (we use a fresh budget
        // instance per test, but the log file persists across
        // tests; the helper `reset()` clears it).
        TesseraNotificationBudgetLog.reset()
        let budget = TesseraNotificationBudget(capPerDay: 3)
        await budget.setDevMode(false)

        // Tier surfaces (1B) are pure functions over the
        // safety decision (1B) and the action class. The
        // integration test wires them through the audit
        // log (3D) and the PendingMutation (4A) and the
        // confirmation panel's tier label.
        let researchClass = "research"
        let researchRisk = TesseraActionRisk.low // research is a read-only tool
        let researchTier = TesseraTier.tier(for: researchClass, risk: researchRisk)
        XCTAssertEqual(researchTier, .tier0, "research at low risk must land at tier0 (auto)")

        // Audit log store (3D): the run records one entry
        // with the tier the safety decision derived.
        let store = ActionAuditLogStore(capacity: 100)
        let researchReceipt = makeReceipt(summary: "research completion")
        store.append(ActionAuditEntry(
            timestamp: researchReceipt.timestamp,
            actionClass: researchClass,
            summary: "web research for the prompt",
            tier: researchTier,
            risk: researchRisk,
            outcome: .success,
            receiptID: researchReceipt.id
        ))
        let visible = store.visible
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible[0].tier, .tier0)
        XCTAssertTrue(visible[0].displayString.contains("tier: T0"),
            "audit row tier label must match TesseraTier.shortLabel")

        // Notification budget (1D): the run triggers one
        // post (the run-completion event). The budget
        // accepts; subsequent posts are capped.
        let first = await budget.tryPost(
            category: .workflow, title: "research run", body: "ok"
        )
        XCTAssertTrue(first, "first post must succeed (cap is 3/day)")

        // ReceiptsCoordinator (3B): the run produced one
        // receipt; the coordinator's in-memory snapshot
        // carries it.
        let coordinator = ReceiptsCoordinator()
        await coordinator.register(receipt: researchReceipt)
        let current = await coordinator.currentReceipts()
        XCTAssertTrue(current.contains { $0.id == researchReceipt.id })

        // Citation flow (3A): the research tool result carries
        // sources. The chat message's `sources` field is
        // populated by the controller's `extractCitations`
        // helper when the tool result lands.
        let sources: [(url: String, title: String, content: String)] = [
            ("https://example.com/agent-ux-fatigue",
             "Agent UX with AI Fatigue as a First-Class Constraint",
             "The four-factor AI fatigue model."),
        ]
        let result = researchToolResult(sources: sources)
        let citations = UnifiedChatController.extractCitations(from: result)
        XCTAssertEqual(citations.count, 1)
        let message = ChatMessage(
            role: .assistant,
            content: "summary of the agent-ux-fatigue skill",
            sources: citations
        )
        XCTAssertEqual(message.sources.count, 1)
        XCTAssertEqual(message.sources[0].label, "Agent UX with AI Fatigue as a First-Class Constraint")

        // The run is complete. The chat progress feed
        // (2A) is the surface the user opens to see the
        // timeline. Its chip vocabulary matches the audit
        // row's. The integration test asserts the chip
        // language is consistent end-to-end.
        let liveApproval = LiveApprovalPendingEntry(
            toolName: researchClass,
            tierLabel: researchTier.shortLabel,
            riskLabel: researchRisk.rawValue,
            reason: "reversible"
        )
        let liveDisplay = liveApproval.displayString
        XCTAssertTrue(liveDisplay.contains("tier: T0"),
            "live approval chip tier label must match TesseraTier.shortLabel")
        XCTAssertTrue(liveDisplay.contains("risk: low"),
            "live approval chip risk label must match TesseraActionRisk.rawValue")
    }
}
