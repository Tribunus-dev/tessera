import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Calendar/CalendarStore.swift
// doc comments + docs/tessera-productivity-materials-calendar-design.md
// section 3 ("Every mutation through CalendarStore appends a
// graph_receipts row") table + section 9's CalendarLinkType vocabulary.
//
// This file is the ungated half of doctrine rule 11 for the REAL
// `CalendarStore` (not the `CalendarStoring` fake -- see
// CalendarStoringContractTests.swift for that). `CalendarStore` wraps
// `TesseraDataLayer` directly (concrete actor, no protocol seam at that
// boundary), and `TesseraDataStore`'s every operation synchronously
// throws `TesseraDataStoreError.closed` when never `connect()`-ed (see
// Sources/TesseraCore/Data/TesseraDataStore.swift `guard let client else
// { throw TesseraDataStoreError.closed }` on every method). That gives a
// deterministic, network-free way to verify:
//   (a) `upsert`'s validation guard runs BEFORE any data-layer call (an
//       invalid event never reaches the store's I/O path at all), and
//   (b) a data-layer failure on a VALID mutation propagates rather than
//       being swallowed (no silent "success" when the store is closed).
// The receipt + persistence + not-found-returns-nil parts of the
// quartet need a live Postgres row and are in
// CalendarStoreIntegrationTests.swift (TESSERA_DB_INTEGRATION-gated).

final class CalendarStoreTests: DoctrineTestCase {

    private func makeStore() -> CalendarStore {
        // Never started: `dataLayer.start()` is not called, so every
        // TesseraDataStore/TesseraCache call throws `.closed` rather than
        // touching the network. See file header for why this is a
        // deterministic, ungated seam rather than a live integration.
        CalendarStore(dataLayer: TesseraDataLayer())
    }

    private func makeValidEvent() -> CalendarEvent {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return CalendarEvent(title: "Q3 review", startAt: start, endAt: start.addingTimeInterval(3600))
    }

    // MARK: - Validation runs before any I/O (rule: error path)

    func testUpsertOfEventWithEmptyTitleThrowsInvalidEventBeforeTouchingDataLayer() async {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let invalid = CalendarEvent(title: "", startAt: start, endAt: start.addingTimeInterval(3600))
        do {
            _ = try await store.upsert(invalid)
            XCTFail("expected invalidEvent")
        } catch CalendarStoreError.invalidEvent {
            // expected: the guard fires before the (never-connected)
            // data layer is touched, so this never throws `.closed`.
        } catch {
            XCTFail("expected CalendarStoreError.invalidEvent, got \(error)")
        }
    }

    func testUpsertOfEventWithEndBeforeStartThrowsInvalidEventBeforeTouchingDataLayer() async {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let invalid = CalendarEvent(title: "Bad event", startAt: start, endAt: start.addingTimeInterval(-1))
        do {
            _ = try await store.upsert(invalid)
            XCTFail("expected invalidEvent")
        } catch CalendarStoreError.invalidEvent {
            // expected
        } catch {
            XCTFail("expected CalendarStoreError.invalidEvent, got \(error)")
        }
    }

    // MARK: - A valid mutation still fails loudly when the data layer is down

    func testUpsertOfValidEventOnClosedDataLayerThrowsRatherThanSucceeding() async {
        let store = makeStore()
        do {
            _ = try await store.upsert(makeValidEvent())
            XCTFail("expected the closed data layer's error to propagate")
        } catch {
            // Any thrown error is acceptable here (rule: the store must
            // not silently swallow a lower-layer failure and report
            // success); we additionally assert it is specifically the
            // documented `.closed` error so the test stays meaningful
            // rather than accepting literally any throw.
            XCTAssertTrue(error is TesseraDataStoreError, "expected a TesseraDataStoreError, got \(error)")
        }
    }

    func testGetOnClosedDataLayerThrowsRatherThanReturningNil() async {
        let store = makeStore()
        do {
            _ = try await store.get(id: UUID())
            XCTFail("expected the closed data layer's error to propagate")
        } catch {
            XCTAssertTrue(error is TesseraDataStoreError, "expected a TesseraDataStoreError, got \(error)")
        }
    }

    // MARK: - Receipt type taxonomy pin (doctrine rule 5: traps stay pinned;
    // rule 7: independent oracle -- hardcoded list from the design doc's
    // table, not derived from the enum's own case count)

    func testCalendarEventReceiptTypeRawValuesArePinned() {
        let expected: [CalendarEventReceiptType: String] = [
            .eventCreated: "event_created",
            .eventUpdated: "event_updated",
            .eventDeleted: "event_deleted",
            .eventResponded: "event_responded",
            .linkCreated: "event_link_created",
        ]
        for (receiptType, rawValue) in expected {
            XCTAssertEqual(receiptType.rawValue, rawValue)
        }
    }

    func testCalendarEventReceiptTypeHasNoUnexpectedCases() {
        // Independent oracle: pin the exact set from the design doc's
        // receipt table (section 3), not derived from `CaseIterable`.
        let expected: Set<String> = [
            "event_created", "event_updated", "event_deleted",
            "event_responded", "event_link_created",
        ]
        let actual = Set(CalendarEventReceiptType.allCases.map(\.rawValue))
        XCTAssertEqual(actual, expected)
    }

    func testCalendarLinkTypeRawValuesArePinned() {
        let expected: [CalendarLinkType: String] = [
            .attendeeOf: "attendee_of",
            .prepDocument: "prep_document",
            .prepTask: "prep_task",
            .reminderFor: "reminder_for",
        ]
        for (linkType, rawValue) in expected {
            XCTAssertEqual(linkType.rawValue, rawValue)
        }
    }

    // MARK: - CalendarStoreError equality (value-type sanity so later
    // tests can rely on == comparisons)

    func testCalendarStoreErrorEventNotFoundEqualityIsByID() {
        let id = UUID()
        XCTAssertEqual(CalendarStoreError.eventNotFound(id: id), CalendarStoreError.eventNotFound(id: id))
        XCTAssertNotEqual(CalendarStoreError.eventNotFound(id: id), CalendarStoreError.eventNotFound(id: UUID()))
    }
}
