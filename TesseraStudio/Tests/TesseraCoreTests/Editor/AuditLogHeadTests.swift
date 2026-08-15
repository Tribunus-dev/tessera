import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Editor/AuditLogHead.swift doc
// comments plus AGENTS.md "AuditLogHeadChip ... rendered only on
// state == .diffComplete or .editable, suppressed on .streaming and when
// Receipt.mutations is empty" and docs/PROJECT-STATUS.md item 1C (field
// cap of 5, chip format `risk: ... | tool: ... | Ns | receipt: ...`).
//
// `AuditLogHeadChip` (the SwiftUI view) has no independently-testable
// logic beyond what `AuditLogHead` (the pure value type) already carries
// -- the view just splits `displayString` at "receipt: " for a tappable
// region. This file covers `AuditLogHead` and `AuditLogRenderState`.
final class AuditLogHeadTests: DoctrineTestCase {

    private func makeHead(
        risk: AuditLogHead.Risk = .medium,
        tool: String = "rewrite",
        elapsedSeconds: Double = 2.1,
        receiptID: UUID = UUID(uuidString: "a1b2c3d4-0000-0000-0000-000000000000")!,
        mutations: [Mutation] = [.setDocumentTitle(title: "Untitled")],
        summary: String? = nil,
        actor: String? = nil
    ) -> AuditLogHead {
        AuditLogHead(
            risk: risk, tool: tool, elapsedSeconds: elapsedSeconds,
            receiptID: receiptID, mutations: mutations, summary: summary, actor: actor
        )
    }

    // MARK: - shouldRender: state gating (AGENTS.md invariant)

    func testShouldRenderOnDiffComplete() {
        XCTAssertTrue(makeHead().shouldRender(for: .diffComplete))
    }

    func testShouldRenderOnEditable() {
        XCTAssertTrue(makeHead().shouldRender(for: .editable))
    }

    func testShouldNotRenderOnStreaming() {
        XCTAssertFalse(makeHead().shouldRender(for: .streaming))
    }

    func testShouldNotRenderOnIdle() {
        XCTAssertFalse(makeHead().shouldRender(for: .idle))
    }

    // MARK: - shouldRender: mutations-empty guard (AGENTS.md invariant)

    func testShouldNotRenderOnDiffCompleteWhenMutationsEmpty() {
        let head = makeHead(mutations: [])
        XCTAssertFalse(head.shouldRender(for: .diffComplete))
    }

    func testShouldNotRenderOnEditableWhenMutationsEmpty() {
        let head = makeHead(mutations: [])
        XCTAssertFalse(head.shouldRender(for: .editable))
    }

    func testMutationsEmptyGuardAppliesAcrossEveryRenderState() {
        let head = makeHead(mutations: [])
        for state: AuditLogRenderState in [.idle, .streaming, .diffComplete, .editable] {
            XCTAssertFalse(head.shouldRender(for: state), "state \(state) must not render with empty mutations")
        }
    }

    // MARK: - shortReceiptID / receiptIDLabel

    func testShortReceiptIDIsFirstEightCharsOfUUID() {
        let id = UUID(uuidString: "a1b2c3d4-5566-7788-99aa-bbccddeeff00")!
        let head = makeHead(receiptID: id)
        XCTAssertEqual(head.shortReceiptID, "A1B2C3D4")
    }

    func testReceiptIDLabelAppendsEllipsis() {
        let id = UUID(uuidString: "a1b2c3d4-5566-7788-99aa-bbccddeeff00")!
        let head = makeHead(receiptID: id)
        XCTAssertEqual(head.receiptIDLabel, "A1B2C3D4...")
    }

    // MARK: - displayString: field format + order

    func testDisplayStringWithNoOptionalFieldsHasFourFields() {
        let head = makeHead(risk: .medium, tool: "rewrite", elapsedSeconds: 2.1)
        XCTAssertEqual(
            head.displayString,
            "risk: medium | tool: rewrite | 2.1s | receipt: A1B2C3D4..."
        )
    }

    func testDisplayStringAppendsSummaryAsFifthFieldWhenPresent() {
        let head = makeHead(summary: "fixed the header")
        XCTAssertTrue(head.displayString.hasSuffix("| summary: fixed the header"))
        XCTAssertEqual(head.displayString.components(separatedBy: " | ").count, 5)
    }

    func testDisplayStringAppendsActorAsFifthFieldWhenSummaryNilAndActorPresent() {
        let head = makeHead(summary: nil, actor: "agent:llama3")
        XCTAssertTrue(head.displayString.hasSuffix("| actor: agent:llama3"))
        XCTAssertEqual(head.displayString.components(separatedBy: " | ").count, 5)
    }

    func testDisplayStringPrefersSummaryOverActorWhenBothPresent() {
        let head = makeHead(summary: "fixed the header", actor: "agent:llama3")
        let fields = head.displayString.components(separatedBy: " | ")
        XCTAssertEqual(fields.count, 5)
        XCTAssertEqual(fields[4], "summary: fixed the header")
    }

    func testDisplayStringOmitsFifthFieldWhenSummaryEmptyAndActorNil() {
        let head = makeHead(summary: "", actor: nil)
        XCTAssertEqual(head.displayString.components(separatedBy: " | ").count, 4)
    }

    func testDisplayStringElapsedSecondsFormatsToOneDecimalPlace() {
        let head = makeHead(elapsedSeconds: 12.0)
        XCTAssertTrue(head.displayString.contains("12.0s"))
    }

    // MARK: - fieldCap invariant (shared chip vocabulary discipline)

    func testFieldCapIsFive() {
        XCTAssertEqual(AuditLogHead.fieldCap, 5)
    }

    func testDisplayStringNeverExceedsFieldCapFields() {
        // Even with both a non-empty summary AND (hypothetically) more
        // fields, the cap holds. Today's fields are 4 + at most 1 optional,
        // so this pins the invariant at the current shape.
        let head = makeHead(summary: "a very long summary that keeps going")
        let fieldCount = head.displayString.components(separatedBy: " | ").count
        XCTAssertLessThanOrEqual(fieldCount, AuditLogHead.fieldCap)
    }

    // MARK: - Risk.displayLabel (ASCII, categorical -- not numeric confidence)

    func testRiskDisplayLabelsAreLowercaseASCII() {
        XCTAssertEqual(AuditLogHead.Risk.low.displayLabel, "low")
        XCTAssertEqual(AuditLogHead.Risk.medium.displayLabel, "medium")
        XCTAssertEqual(AuditLogHead.Risk.high.displayLabel, "high")
        XCTAssertEqual(AuditLogHead.Risk.forbidden.displayLabel, "forbidden")
    }

    func testRiskIsExhaustivelyFourCategoricalCases() {
        // Independent oracle (rule 7): pinned against the spec list, not
        // against AuditLogHead.Risk.allCases itself.
        let expected: Set<String> = ["low", "medium", "high", "forbidden"]
        let actual = Set(AuditLogHead.Risk.allCases.map(\.rawValue))
        XCTAssertEqual(actual, expected)
    }

    // MARK: - Round-trip identity (rule 2) for AuditLogHead.Risk

    func testRiskEncodeDecodeIdentity() throws {
        for risk in AuditLogHead.Risk.allCases {
            let data = try JSONEncoder().encode(risk)
            let decoded = try JSONDecoder().decode(AuditLogHead.Risk.self, from: data)
            XCTAssertEqual(decoded, risk)
        }
    }

    func testRiskDecodesFromLegacyRawStringJSON() throws {
        // Pin the on-disk shape: a bare quoted string, matching the
        // `String` raw-value Codable synthesis.
        let json = Data("\"medium\"".utf8)
        let decoded = try JSONDecoder().decode(AuditLogHead.Risk.self, from: json)
        XCTAssertEqual(decoded, .medium)
    }
}
