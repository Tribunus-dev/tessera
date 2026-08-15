import XCTest
@testable import TesseraCore

// Contract source (all pure Codable value types, no design doc beyond
// their own source doc comments -- contract fallback per this cluster's
// instructions):
// - Sources/TesseraCore/Learning/TesseraWorldOutcomeContracts.swift
// - Sources/TesseraCore/Learning/TesseraReceiptsContracts.swift
// - Sources/TesseraCore/Learning/TesseraForagingContracts.swift
// - Sources/TesseraCore/Learning/TesseraCurationContracts.swift
final class TesseraLearningReceiptsAndOutcomesTests: DoctrineTestCase {

    // MARK: - TesseraWorldOutcomeKind: independent oracle (rule 7)

    func testWorldOutcomeKindHasTheFourDocumentedCases() {
        XCTAssertEqual(Set(TesseraWorldOutcomeKind.allCases.map(\.rawValue)), ["build", "test", "commit", "revert"])
    }

    func testWorldOutcomeDefaultsToEmptyDetailAndNilProposalID() {
        let outcome = TesseraWorldOutcome(kind: .build, success: true)
        XCTAssertEqual(outcome.detail, "")
        XCTAssertNil(outcome.proposalId)
    }

    func testWorldOutcomeEncodeDecodeIdentity() throws {
        let outcome = TesseraWorldOutcome(kind: .test, success: false, detail: "3 failures", proposalId: "p1", timestamp: Date(timeIntervalSince1970: 1000))
        let data = try JSONEncoder().encode(outcome)
        let decoded = try JSONDecoder().decode(TesseraWorldOutcome.self, from: data)
        XCTAssertEqual(decoded, outcome)
    }

    // MARK: - TesseraLearningReceipt: schemaVersion is always the current
    // constant (doc comment: "a schema-versioned evidence record")

    func testLearningReceiptAlwaysStampsTheCurrentSchemaVersion() {
        let receipt = TesseraLearningReceipt(kind: "outcome", summary: "s")
        XCTAssertEqual(receipt.schemaVersion, TesseraLearningReceipt.currentSchemaVersion)
        XCTAssertEqual(TesseraLearningReceipt.currentSchemaVersion, 1)
    }

    func testLearningReceiptDefaultsToEmptyPayload() {
        let receipt = TesseraLearningReceipt(kind: "outcome", summary: "s")
        XCTAssertTrue(receipt.payload.isEmpty)
    }

    func testLearningReceiptEncodeDecodeIdentity() throws {
        let receipt = TesseraLearningReceipt(
            kind: "adaptation", summary: "ran adaptation",
            payload: ["epsilon": .number(0.1), "adapted": .bool(false)],
            timestamp: Date(timeIntervalSince1970: 3000)
        )
        let data = try JSONEncoder().encode(receipt)
        let decoded = try JSONDecoder().decode(TesseraLearningReceipt.self, from: data)
        XCTAssertEqual(decoded, receipt)
    }

    func testLearningReceiptDecodesFromTheDocumentedWireShapeWithEmptyPayload() throws {
        let json = Data(#"{"id":"x","schemaVersion":1,"kind":"outcome","timestamp":0,"summary":"s","payload":{}}"#.utf8)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TesseraLearningReceipt.self, from: json)
        XCTAssertEqual(decoded.kind, "outcome")
        XCTAssertTrue(decoded.payload.isEmpty)
    }

    // MARK: - TesseraAdaptationRecord

    func testAdaptationRecordEncodeDecodeIdentity() throws {
        let record = TesseraAdaptationRecord(
            timestamp: Date(timeIntervalSince1970: 4000), dryRun: true, guardPassed: true, adapted: false,
            epsilon: 0.05, score: TesseraCapabilityScore(generalCompetence: 0.9), hasBaseline: true,
            backend: "dry-run", note: "v1 does not adapt"
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(TesseraAdaptationRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }

    // MARK: - TesseraForagingSource / TesseraForagingRecord / Summary

    func testForagingSourceHasTheThreeDocumentedCases() {
        XCTAssertEqual(Set(TesseraForagingSource.allCases.map(\.rawValue)), ["local-playbook", "local-reference", "remote"])
    }

    func testForagingRecordDefaultsToEmptyTeacherIDs() {
        let record = TesseraForagingRecord(problemClass: "failing-test", source: .localPlaybook)
        XCTAssertTrue(record.teacherIds.isEmpty)
    }

    func testForagingSummaryResolvedLocallyIsPlaybookPlusReference() {
        let summary = TesseraForagingSummary(total: 10, localPlaybook: 3, localReference: 4, remote: 3)
        XCTAssertEqual(summary.resolvedLocally, 7)
    }

    func testForagingSummaryDefaultsToAllZero() {
        let summary = TesseraForagingSummary()
        XCTAssertEqual(summary.total, 0)
        XCTAssertEqual(summary.resolvedLocally, 0)
    }

    func testForagingRecordEncodeDecodeIdentity() throws {
        let record = TesseraForagingRecord(problemClass: "hard-tail", source: .remote, teacherIds: ["t1", "t2"], timestamp: Date(timeIntervalSince1970: 6000))
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(TesseraForagingRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }

    // MARK: - TesseraPreferencePair / TesseraCurationSummary

    func testPreferencePairCarriesChosenAndRejectedOutcomes() {
        let chosen = TesseraWorldOutcome(kind: .test, success: true)
        let rejected = TesseraWorldOutcome(kind: .test, success: false)
        let pair = TesseraPreferencePair(problemClass: "x", chosen: chosen, rejected: rejected)
        XCTAssertEqual(pair.chosen, chosen)
        XCTAssertEqual(pair.rejected, rejected)
    }

    func testCurationSummaryDefaultsToAllZero() {
        let summary = TesseraCurationSummary()
        XCTAssertEqual(summary.stored, 0)
        XCTAssertEqual(summary.dedupSkipped, 0)
        XCTAssertEqual(summary.preferencePairs, 0)
        XCTAssertEqual(summary.meanQuality, 0)
    }

    func testPreferencePairEncodeDecodeIdentity() throws {
        let chosen = TesseraWorldOutcome(kind: .commit, success: true)
        let rejected = TesseraWorldOutcome(kind: .revert, success: false)
        let pair = TesseraPreferencePair(problemClass: "x", chosen: chosen, rejected: rejected)
        let data = try JSONEncoder().encode(pair)
        let decoded = try JSONDecoder().decode(TesseraPreferencePair.self, from: data)
        XCTAssertEqual(decoded, pair)
    }

    func testCurationSummaryEncodeDecodeIdentity() throws {
        let summary = TesseraCurationSummary(stored: 5, dedupSkipped: 1, preferencePairs: 2, meanQuality: 0.75)
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(TesseraCurationSummary.self, from: data)
        XCTAssertEqual(decoded, summary)
    }
}
