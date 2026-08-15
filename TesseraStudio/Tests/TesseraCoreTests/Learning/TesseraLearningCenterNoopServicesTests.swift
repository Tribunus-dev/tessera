import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Learning/TesseraLearningCenter.swift
// -- the five `TesseraNoop*Service` types conforming to the protocols in
// TesseraAutonomyContracts.swift. Each is a documented "no data, no
// error" default used before the real service installs (see
// TesseraLearningServices.installDefaults). This file pins exactly the
// inert behavior each no-op promises.
final class TesseraLearningCenterNoopServicesTests: DoctrineTestCase {

    // MARK: - TesseraNoopEscalationService

    func testNoopEscalationServiceHasNoAvailableTeachers() {
        XCTAssertEqual(TesseraNoopEscalationService().availableTeachers(), [])
    }

    func testNoopEscalationServiceAssessTeachersReturnsEmpty() async throws {
        let result = try await TesseraNoopEscalationService().assessTeachers()
        XCTAssertEqual(result, [])
    }

    // MARK: - TesseraNoopCurationService

    func testNoopCurationServiceScrubIsIdentity() {
        let service = TesseraNoopCurationService()
        XCTAssertEqual(service.scrub("has a secret sk-abc123"), "has a secret sk-abc123")
    }

    func testNoopCurationServiceSummaryIsAllZero() {
        let summary = TesseraNoopCurationService().summary()
        XCTAssertEqual(summary, TesseraCurationSummary())
    }

    func testNoopCurationServicePurgeReturnsZero() throws {
        XCTAssertEqual(try TesseraNoopCurationService().purgeTrainingData(), 0)
    }

    // Unlike its read-only/inert siblings (scrub/summary/purgeTrainingData),
    // ingest(outcome:) is a RECORDING action - the no-op deliberately
    // throws .notConfigured rather than silently pretending to have
    // recorded something it didn't, per TesseraLearningCenter.swift's
    // actual implementation (verified against source, not assumed).
    func testNoopCurationServiceIngestThrowsNotConfiguredRatherThanSilentlySucceeding() async {
        let outcome = TesseraWorldOutcome(kind: .build, success: true)
        do {
            _ = try await TesseraNoopCurationService().ingest(outcome: outcome)
            XCTFail("the no-op curation service must not silently pretend to have recorded an outcome")
        } catch TesseraLearningError.notConfigured(let what) {
            XCTAssertEqual(what, "curation service")
        } catch {
            XCTFail("expected TesseraLearningError.notConfigured, got \(error)")
        }
    }

    // MARK: - TesseraNoopPlaybookStore

    func testNoopPlaybookStoreHasNoStrategiesForAnyProblemClass() {
        let store = TesseraNoopPlaybookStore()
        XCTAssertEqual(store.strategies(forProblemClass: "anything"), [])
        XCTAssertTrue(store.all().isEmpty)
    }

    func testNoopPlaybookStorePurgeReturnsZero() throws {
        XCTAssertEqual(try TesseraNoopPlaybookStore().purgeTrainingData(), 0)
    }

    // MARK: - TesseraNoopReferenceStore

    func testNoopReferenceStoreLookupIsAlwaysEmpty() {
        XCTAssertEqual(TesseraNoopReferenceStore().lookup(query: "anything"), [])
    }

    func testNoopReferenceStorePurgeReturnsZero() throws {
        XCTAssertEqual(try TesseraNoopReferenceStore().purgeTrainingData(), 0)
    }

    // MARK: - TesseraNoopWorldSignalObserver

    // Same rationale as the curation service above: record(_:) is a
    // recording action, so the no-op throws rather than silently
    // pretending to have recorded the outcome.
    func testNoopWorldSignalObserverRecordThrowsNotConfiguredRatherThanSilentlySucceeding() async {
        let outcome = TesseraWorldOutcome(kind: .commit, success: true)
        do {
            _ = try await TesseraNoopWorldSignalObserver().record(outcome)
            XCTFail("the no-op world-signal observer must not silently pretend to have recorded an outcome")
        } catch TesseraLearningError.notConfigured(let what) {
            XCTAssertEqual(what, "world-signal observer")
        } catch {
            XCTFail("expected TesseraLearningError.notConfigured, got \(error)")
        }
    }
}
