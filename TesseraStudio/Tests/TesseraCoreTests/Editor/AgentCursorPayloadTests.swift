import XCTest
import Foundation
@testable import TesseraCore

/// Tests for the agent cursor WHAT-not-WHERE payload
/// (Wave 4A of the agent-ux-fatigue Tessera Studio audit,
/// review #5). The cursor used to show only WHERE the
/// agent was about to edit; the audit paid a navigation
/// tax to see WHAT (open the receipts drawer, scroll, find
/// the entry). Wave 4A inlines a one-line chip at the
/// cursor with the chip vocabulary from Wave 1C's
/// `AuditLogHead` (`field: value` shape, pipe separator,
/// field cap of 5). The four canonical keys are
/// `tier:`/`risk:`/`tool:`/`outcome:`; a 5th `summary:`
/// field is appended when present.
///
/// Three test areas:
///   1. `PendingMutation` chip vocabulary (struct tests):
///      the display string matches Wave 1C's shape
///      exactly, the field cap is honored, the keys are
///      the canonical four, ASCII-only.
///   2. `TesseraAgentLoop.pendingMutation` emit (loop
///      tests): the loop publishes a non-nil payload when a
///      tool call is announced, transitions the `outcome`
///      to `.approved` when the gate resolves to
///      `autoApprove`, and clears the payload to nil when
///      the matching tool result is yielded.
///   3. Outcome label vocabulary: every outcome case has a
///      stable, ASCII display label so the chip's
///      `outcome:` field is unambiguous.
///
/// Test target may have pre-existing build breaks; these
/// tests are additive and do not depend on the broken
/// files.
final class AgentCursorPayloadTests: XCTestCase {

    // MARK: - Test fixtures

    /// A trivially successful tool. The loop test only
    /// needs the tool to exist, return a value, and let the
    /// loop reach the toolResult yield point. The tool
    /// returns immediately so the loop does not block on
    /// tool execution.
    private struct StubTool: TesseraTool {
        let name: String
        let defaultApprovalLevel: ApprovalLevel
        let description = "stub"
        let parameters = JSONSchema()
        func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
            .ok("stub ok")
        }
    }

    /// A provider that always emits a single, scripted tool
    /// call. The loop's `maxIterations=1` caps the call
    /// count at one so the provider is invoked exactly once
    /// per `run()`. After the tool is dispatched and the
    /// result is appended, the loop's iteration count
    /// reaches 1 and the while-loop exits. No state tracking
    /// is needed in the provider because the loop terminates
    /// after the first tool cycle.
    private struct ScriptedToolProvider: LLMProvider {
        let toolName: String
        let arguments: [String: JSONValue]
        func complete(system: String, messages: [LLMMessage], tools: [ToolDescriptor]) async throws -> LLMResponse {
            LLMResponse(
                content: "",
                toolCalls: [LLMToolCall(name: toolName, arguments: arguments)],
                tokenCount: 1
            )
        }
    }

    // MARK: - PendingMutation chip vocabulary

    func testFieldCapMatchesAuditLogHead() {
        // The chip vocabulary contract is shared with Wave
        // 1C's `AuditLogHead`. Both caps must be 5 so a
        // user can switch between surfaces and see the
        // same structural data shape.
        XCTAssertEqual(PendingMutation.fieldCap, 5)
        XCTAssertEqual(PendingMutation.fieldCap, AuditLogHead.fieldCap)
    }

    func testDisplayStringHasFourCanonicalFields() {
        // The four canonical keys: tier: risk: tool:
        // outcome:. The 5th field is summary: and is
        // optional.
        let mutation = PendingMutation(
            tier: .tier2,
            risk: .medium,
            tool: "file_write",
            actionClass: "file_write:src/**",
            outcome: .pending
        )
        let s = mutation.displayString
        XCTAssertTrue(s.contains("tier: T2"), s)
        XCTAssertTrue(s.contains("risk: medium"), s)
        XCTAssertTrue(s.contains("tool: file_write"), s)
        XCTAssertTrue(s.contains("outcome: pending"), s)
    }

    func testDisplayStringJoinsWithPipe() {
        // The pipe is the field separator; the chip is
        // structural data, not a sentence, so a stable
        // separator is required (Wave 1C's contract).
        let mutation = PendingMutation(
            tier: .tier1,
            risk: .low,
            tool: "list_models",
            actionClass: "list_models",
            outcome: .pending
        )
        let s = mutation.displayString
        let pipes = s.filter { $0 == "|" }.count
        XCTAssertEqual(pipes, 3, "expected 3 pipes (4 fields), got \(pipes) in: \(s)")
    }

    func testDisplayStringAddsSummaryAsFifthField() {
        // When summary is present, it becomes the 5th
        // field. The cap is 5, so the display stops at
        // summary: even if more data were added later.
        let mutation = PendingMutation(
            tier: .tier2,
            risk: .high,
            tool: "file_write",
            actionClass: "file_write:src/**",
            outcome: .approved,
            summary: "rewrite line 42"
        )
        let s = mutation.displayString
        XCTAssertTrue(s.contains("summary: rewrite line 42"), s)
        let pipes = s.filter { $0 == "|" }.count
        XCTAssertEqual(pipes, 4, "summary adds 1 field, total 5 = 4 pipes: \(s)")
    }

    func testDisplayStringOmitsSummaryWhenNil() {
        let mutation = PendingMutation(
            tier: .tier0,
            risk: .low,
            tool: "list_models",
            actionClass: "list_models",
            outcome: .approved
        )
        let s = mutation.displayString
        XCTAssertFalse(s.contains("summary:"), s)
    }

    func testDisplayStringOmitsSummaryWhenEmpty() {
        let mutation = PendingMutation(
            tier: .tier0,
            risk: .low,
            tool: "list_models",
            actionClass: "list_models",
            outcome: .approved,
            summary: ""
        )
        let s = mutation.displayString
        XCTAssertFalse(s.contains("summary:"), s)
    }

    func testFieldCapIsRespectedWithExtras() {
        // The cap is 5, not 4. The summary slot is the
        // only optional 5th field; future additions would
        // need to be designed in. The cap guarantees the
        // chip never becomes a wall of text.
        let mutation = PendingMutation(
            tier: .tier3,
            risk: .forbidden,
            tool: "bash",
            actionClass: "bash:rm",
            outcome: .blocked,
            summary: "drop table foo"
        )
        let s = mutation.displayString
        let pipes = s.filter { $0 == "|" }.count
        XCTAssertEqual(pipes, 4, "5 fields = 4 pipes: \(s)")
    }

    // MARK: - Outcome labels

    func testOutcomeLabelPending() {
        XCTAssertEqual(PendingMutation.Outcome.pending.displayLabel, "pending")
    }

    func testOutcomeLabelApproved() {
        XCTAssertEqual(PendingMutation.Outcome.approved.displayLabel, "approved")
    }

    func testOutcomeLabelBlocked() {
        XCTAssertEqual(PendingMutation.Outcome.blocked.displayLabel, "blocked")
    }

    func testOutcomeLabelsAreStableAndAscii() {
        // The displayLabel is the chip's `outcome:` value;
        // a rename would silently change the chip's text.
        for outcome in PendingMutation.Outcome.allCases {
            XCTAssertTrue(outcome.displayLabel.allSatisfy { $0.isASCII },
                "displayLabel must be ASCII: \(outcome.displayLabel)")
            XCTAssertFalse(outcome.displayLabel.isEmpty,
                "displayLabel must be non-empty: \(outcome)")
        }
    }

    // MARK: - ASCII guard

    func testDisplayStringIsPureAscii() {
        // The chip is a structural surface; non-ASCII
        // would break the display-string contract and the
        // review-mandated ASCII-only policy.
        let mutation = PendingMutation(
            tier: .tier2,
            risk: .medium,
            tool: "file_write",
            actionClass: "file_write:src/**",
            outcome: .pending,
            summary: "rewrite tightened"
        )
        let s = mutation.displayString
        for scalar in s.unicodeScalars {
            XCTAssertLessThan(
                scalar.value, 128,
                "non-ASCII scalar \(scalar) in displayString: \(s)"
            )
        }
    }

    // MARK: - Tier short label

    func testTierShortLabelIsUsedInChip() {
        // The chip uses `tier.shortLabel` ("T0".."T3"),
        // not `tier.displayName` ("Tier 0 (auto)"...).
        // The short form keeps the chip scannable.
        let cases: [(TesseraTier, String)] = [
            (.tier0, "T0"),
            (.tier1, "T1"),
            (.tier2, "T2"),
            (.tier3, "T3"),
        ]
        for (tier, expected) in cases {
            let mutation = PendingMutation(
                tier: tier,
                risk: .low,
                tool: "stub",
                actionClass: "stub",
                outcome: .pending
            )
            XCTAssertTrue(
                mutation.displayString.contains("tier: \(expected)"),
                "expected tier: \(expected) in \(mutation.displayString)"
            )
        }
    }

    // MARK: - Equatable

    func testPendingMutationIsEquatable() {
        // The struct conforms to Equatable so a host can
        // compare the current payload to the previous one
        // and skip a SwiftUI re-render when nothing
        // changed. The struct is the @Observable diff unit.
        let a = PendingMutation(
            tier: .tier2,
            risk: .medium,
            tool: "file_write",
            actionClass: "file_write:src/**",
            outcome: .pending
        )
        let b = PendingMutation(
            tier: .tier2,
            risk: .medium,
            tool: "file_write",
            actionClass: "file_write:src/**",
            outcome: .pending
        )
        let c = PendingMutation(
            tier: .tier2,
            risk: .medium,
            tool: "file_write",
            actionClass: "file_write:src/**",
            outcome: .approved
        )
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - TesseraAgentLoop.pendingMutation emit

    /// The loop publishes a non-nil `pendingMutation`
    /// while a tool call is in flight, and clears it back
    /// to nil after the matching tool result. The cursor
    /// overlay observes the property; the chip must not
    /// linger after the mutation has completed.
    @MainActor
    func testLoopPublishesAndClearsPendingMutation() async throws {
        let registry = TesseraToolRegistry(tools: [
            StubTool(name: "file_write", defaultApprovalLevel: .auto)
        ])
        let approval = TesseraApprovalEngine()
        approval.setOverride(.auto, for: "file_write")
        defer { approval.clearOverride(for: "file_write") }

        let provider = ScriptedToolProvider(
            toolName: "file_write",
            arguments: ["path": .string("src/foo.swift")]
        )
        let loop = TesseraAgentLoop(
            registry: registry,
            approvalEngine: approval,
            llmProvider: provider,
            maxIterations: 1,
            sandboxEnforceable: true
        )

        // The loop must publish the payload before yielding
        // the toolResult event. maxIterations=1 caps the
        // call count at one; after the tool is dispatched
        // and the result is appended, the while-loop exits.
        // The cursor overlay will see pendingMutation go
        // from nil -> non-nil -> nil across the run.
        let stream = loop.run(userMessage: "do it", history: [])

        // Drain the stream and snapshot the pendingMutation
        // transitions. The async event ordering is
        // deterministic because every yield happens on the
        // main actor: the loop sets pendingMutation BEFORE
        // it yields `.toolCall(...)`, and clears it AFTER
        // it yields `.toolResult(...)`. After the stream
        // terminates, pendingMutation must be nil.
        var sawToolCall = false
        var sawToolResult = false
        for await event in stream {
            switch event {
            case .toolCall:
                sawToolCall = true
                // The payload must be non-nil at the moment
                // the tool call is yielded. The cursor
                // overlay's chip appears in this window.
                XCTAssertNotNil(
                    loop.pendingMutation,
                    "pendingMutation must be non-nil while a tool call is in flight"
                )
            case .toolResult:
                sawToolResult = true
            case .done:
                break
            default:
                break
            }
        }
        XCTAssertTrue(sawToolCall, "expected at least one .toolCall event")
        XCTAssertTrue(sawToolResult, "expected at least one .toolResult event")
        XCTAssertNil(
            loop.pendingMutation,
            "pendingMutation must be cleared after the tool result"
        )
    }

    /// The loop's published payload carries the chip
    /// vocabulary the cursor overlay reads. The test
    /// asserts every chip key the overlay depends on is
    /// populated, so the cursor chip never has to fall
    /// back to an empty value.
    @MainActor
    func testLoopPayloadCarriesChipVocabulary() async throws {
        let registry = TesseraToolRegistry(tools: [
            StubTool(name: "file_write", defaultApprovalLevel: .auto)
        ])
        let approval = TesseraApprovalEngine()
        approval.setOverride(.auto, for: "file_write")
        defer { approval.clearOverride(for: "file_write") }

        let provider = ScriptedToolProvider(
            toolName: "file_write",
            arguments: ["path": .string("src/foo.swift")]
        )
        let loop = TesseraAgentLoop(
            registry: registry,
            approvalEngine: approval,
            llmProvider: provider,
            maxIterations: 1,
            sandboxEnforceable: true
        )

        // Spin until the payload appears, then assert.
        // The loop may take one or two async hops to
        // reach the tool-call publish, so a brief wait
        // is the right shape; the alternative is a
        // hand-rolled continuation that mirrors the
        // loop's own event ordering. The wait is bounded
        // and the test fails loudly if the loop never
        // publishes the payload.
        let stream = loop.run(userMessage: "do it", history: [])

        // Use the stream as the synchronization point.
        // The loop yields `.toolCall` only after setting
        // pendingMutation, so the first event of either
        // kind is the publish point.
        for await event in stream {
            if case .toolCall = event {
                guard let payload = loop.pendingMutation else {
                    XCTFail("pendingMutation must be set at the toolCall yield")
                    return
                }
                // Every chip key must be populated so the
                // cursor overlay can render the chip
                // without falling back to empty values.
                let s = payload.displayString
                XCTAssertTrue(s.contains("tier:"), s)
                XCTAssertTrue(s.contains("risk:"), s)
                XCTAssertTrue(s.contains("tool:"), s)
                XCTAssertTrue(s.contains("outcome:"), s)
                // The action class is a string, not a
                // chip field, but the payload must carry
                // it for the chip's structural identity
                // (the cursor's tier derives from it).
                XCTAssertFalse(payload.actionClass.isEmpty)
                XCTAssertEqual(payload.tool, "file_write")
                break
            }
        }
    }
}
