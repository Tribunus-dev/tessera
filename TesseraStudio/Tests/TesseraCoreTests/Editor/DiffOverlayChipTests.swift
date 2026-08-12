import XCTest
import Foundation
@testable import TesseraCore

/// Tests for the audit-log HEAD chip (review #5 of the
/// agent-ux-fatigue audit). The chip inlines the audit-log
/// HEAD as a one-line label between the diff and the
/// Accept/Reject controls, so the user can verify the rewrite
/// in place instead of opening the receipts drawer.
///
/// The chip has three testable gates:
///   1. State: show on `.diffComplete` and `.editable`;
///      suppress on `.streaming` and `.idle` (paradox 6:
///      XAI -- the audit is incomplete while the rewrite
///      is in flight).
///   2. Mutations: suppress when the underlying receipt has
///      no mutations (a non-document receipt, per
///      `ReceiptExportService` "Mutations: (none - non-document
///      receipt)").
///   3. Field cap: the chip carries at most 5 fields; extras
///      are silently dropped so the chip never becomes a wall
///      of text.
///
/// The chip's *display string* is what the test exercises
/// here. The SwiftUI view itself is exercised by the build.
final class DiffOverlayChipTests: XCTestCase {

    // MARK: - Test fixtures

    /// A non-empty mutations list, the minimum a real chip
    /// needs to render. Uses `setBlockContent` on a fresh
    /// block; we do not need the mutation to actually
    /// execute, only to be non-empty.
    private func makeMutations() -> [Mutation] {
        let blockID = UUID()
        return [
            .setBlockContent(
                blockID: blockID,
                content: [InlineRun(text: "rewritten")]
            )
        ]
    }

    /// Build one `AuditLogHead` with sensible defaults so each
    /// test only has to override the field it cares about.
    private func makeHead(
        risk: AuditLogHead.Risk = .medium,
        tool: String = "rewrite",
        elapsedSeconds: Double = 2.1,
        receiptID: UUID = UUID(),
        mutations: [Mutation]? = nil,
        summary: String? = nil,
        actor: String? = nil
    ) -> AuditLogHead {
        AuditLogHead(
            risk: risk,
            tool: tool,
            elapsedSeconds: elapsedSeconds,
            receiptID: receiptID,
            mutations: mutations ?? makeMutations(),
            summary: summary,
            actor: actor
        )
    }

    // MARK: - State gate

    func testShouldRenderOnDiffComplete() {
        let head = makeHead()
        XCTAssertTrue(head.shouldRender(for: .diffComplete))
    }

    func testShouldRenderOnEditable() {
        let head = makeHead()
        XCTAssertTrue(head.shouldRender(for: .editable))
    }

    func testShouldNotRenderOnStreaming() {
        let head = makeHead()
        XCTAssertFalse(head.shouldRender(for: .streaming))
    }

    func testShouldNotRenderOnIdle() {
        let head = makeHead()
        XCTAssertFalse(head.shouldRender(for: .idle))
    }

    // MARK: - Mutations-empty guard

    func testShouldNotRenderWhenMutationsEmpty() {
        let head = AuditLogHead(
            risk: .low,
            tool: "rewrite",
            elapsedSeconds: 0.0,
            receiptID: UUID(),
            mutations: []
        )
        XCTAssertFalse(head.shouldRender(for: .diffComplete))
        XCTAssertFalse(head.shouldRender(for: .editable))
    }

    func testShouldNotRenderOnStreamingEvenWhenMutationsEmpty() {
        let head = AuditLogHead(
            risk: .low,
            tool: "rewrite",
            elapsedSeconds: 0.0,
            receiptID: UUID(),
            mutations: []
        )
        XCTAssertFalse(head.shouldRender(for: .streaming))
    }

    // MARK: - Display string

    func testDisplayStringCarriesFourBaseFields() {
        let receiptID = UUID()
        let head = makeHead(
            risk: .medium,
            tool: "rewrite",
            elapsedSeconds: 2.1,
            receiptID: receiptID
        )
        let s = head.displayString
        XCTAssertTrue(s.contains("risk: medium"), s)
        XCTAssertTrue(s.contains("tool: rewrite"), s)
        XCTAssertTrue(s.contains("2.1s"), s)
        XCTAssertTrue(s.contains("receipt: \(head.shortReceiptID)..."), s)
    }

    func testDisplayStringJoinsWithPipe() {
        let head = makeHead()
        let s = head.displayString
        // The pipe is the field separator; the chip is
        // structural data, not a sentence, so a stable
        // separator is required.
        let pipes = s.filter { $0 == "|" }.count
        XCTAssertEqual(pipes, 3, "expected 3 pipes (4 fields), got \(pipes) in: \(s)")
    }

    func testShortReceiptIDIsFirstEightCharsOfUUID() {
        let id = UUID()
        let head = makeHead(receiptID: id)
        XCTAssertEqual(head.shortReceiptID, String(id.uuidString.prefix(8)))
    }

    func testReceiptIDLabelIncludesEllipsisAscii() {
        let id = UUID()
        let head = makeHead(receiptID: id)
        // The label carries "..." so the displayed substring
        // is unambiguous. AGENTS.md requires ASCII.
        XCTAssertTrue(head.receiptIDLabel.hasSuffix("..."), head.receiptIDLabel)
    }

    // MARK: - Field cap

    func testDisplayStringStaysAtFourFieldsWithoutExtras() {
        let head = makeHead()
        let s = head.displayString
        let pipes = s.filter { $0 == "|" }.count
        XCTAssertEqual(pipes, 3, "no extras means 4 fields = 3 pipes: \(s)")
    }

    func testDisplayStringAddsSummaryAsFifthField() {
        let head = makeHead(summary: "3 paragraphs updated")
        let s = head.displayString
        XCTAssertTrue(s.contains("summary: 3 paragraphs updated"), s)
        let pipes = s.filter { $0 == "|" }.count
        XCTAssertEqual(pipes, 4, "summary adds 1 field, total 5 = 4 pipes: \(s)")
    }

    func testDisplayStringAddsActorWhenSummaryMissing() {
        let head = makeHead(actor: "agent:llama3")
        let s = head.displayString
        XCTAssertTrue(s.contains("actor: agent:llama3"), s)
    }

    func testDisplayStringPrefersSummaryOverActor() {
        // When both are present, summary wins so the chip
        // surfaces human-readable intent, not machine identity.
        let head = makeHead(summary: "shorten", actor: "agent:llama3")
        let s = head.displayString
        XCTAssertTrue(s.contains("summary: shorten"), s)
        XCTAssertFalse(s.contains("actor:"), s)
    }

    func testFieldCapIsFive() {
        XCTAssertEqual(AuditLogHead.fieldCap, 5)
    }

    // MARK: - Elapsed formatting

    func testDisplayStringFormatsElapsedWithOneDecimal() {
        let head = makeHead(elapsedSeconds: 1.234)
        let s = head.displayString
        XCTAssertTrue(s.contains("1.2s"), s)
    }

    func testDisplayStringFormatsZeroElapsed() {
        let head = makeHead(elapsedSeconds: 0.0)
        let s = head.displayString
        XCTAssertTrue(s.contains("0.0s"), s)
    }

    // MARK: - Risk labels

    func testRiskDisplayLabelLow() {
        XCTAssertEqual(AuditLogHead.Risk.low.displayLabel, "low")
    }

    func testRiskDisplayLabelMedium() {
        XCTAssertEqual(AuditLogHead.Risk.medium.displayLabel, "medium")
    }

    func testRiskDisplayLabelHigh() {
        XCTAssertEqual(AuditLogHead.Risk.high.displayLabel, "high")
    }

    func testRiskDisplayLabelForbidden() {
        XCTAssertEqual(AuditLogHead.Risk.forbidden.displayLabel, "forbidden")
    }

    // MARK: - ASCII guard

    func testDisplayStringIsPureASCII() {
        // The chip is a structural surface; non-ASCII would
        // break the display-string contract and the
        // review-mandated ASCII-only policy.
        let head = makeHead(
            risk: .medium,
            tool: "rewrite",
            elapsedSeconds: 2.1,
            summary: "rewrite tightened",
            actor: "agent:llama3"
        )
        let s = head.displayString
        for scalar in s.unicodeScalars {
            XCTAssertLessThan(
                scalar.value, 128,
                "non-ASCII scalar \(scalar) in displayString: \(s)"
            )
        }
    }
}
