import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Calendar/CalendarStore.swift
// doc comments + docs/tessera-productivity-materials-calendar-design.md
// section 3's receipt table + docs/tessera-data-layer-design.md section 7.1
// ("env-gated integration tests... TESSERA_DB_INTEGRATION=1... default to
// tessera/tessera/tessera"). Doctrine rule 11: this is the gated half,
// paired with the ungated shadows in CalendarStoreTests.swift (validation
// path) and CalendarStoringContractTests.swift (CRUD/no-op/error-path
// wiring against the in-memory `CalendarStoring` fake).
//
// Doctrine rule 1 (receipts law) + the Store-mutation coverage shape:
// receipt + persistence + no-op zero-receipt + error path, all against a
// real Postgres row.

final class CalendarStoreIntegrationTests: DoctrineTestCase {
    override var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.probe }

    /// Connects a real `TesseraDataLayer` against the docker-compose
    /// defaults (docs/tessera-data-layer-design.md Appendix B), or skips
    /// cleanly. Gated on `TESSERA_DB_INTEGRATION=1` per doctrine rule 11;
    /// additionally skips (rather than failing) if the flag is set but
    /// the services are not actually reachable, since a flake here is a
    /// environment problem, not a contract violation this suite should
    /// report as a failure.
    private func connectedDataLayer() async throws -> TesseraDataLayer {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip("TESSERA_DB_INTEGRATION not set; skipping live-Postgres CalendarStore tests")
        }
        let layer = TesseraDataLayer()
        let outcome = await layer.start()
        guard outcome == .ready else {
            throw XCTSkip("TesseraDataLayer did not reach .ready (\(outcome)); skipping live-Postgres CalendarStore tests")
        }
        return layer
    }

    private func makeEvent(title: String = "Q3 review") -> CalendarEvent {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // Explicit whole-second createdAt/updatedAt (doctrine rule 4: no
        // bare Date() in fixtures) - a sub-second Date() default would
        // round-trip through the .iso8601 encoder with its fractional
        // seconds truncated, breaking the fetched-equals-original check.
        return CalendarEvent(
            title: title, startAt: start, endAt: start.addingTimeInterval(3600),
            createdAt: start, updatedAt: start
        )
    }

    // MARK: - Receipt + persistence (create)

    func testUpsertOfNewEventPersistsAndEmitsExactlyOneEventCreatedReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = CalendarStore(dataLayer: layer)
        let event = makeEvent()

        _ = try await store.upsert(event)

        let fetched = try await store.get(id: event.id)
        XCTAssertEqual(fetched, event)

        let receipts = try await store.receipts(forEvent: event.id)
        let created = receipts.filter { $0.receiptType == CalendarEventReceiptType.eventCreated.rawValue }
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?.payload["title"], .string(event.title))
        XCTAssertEqual(created.first?.payload["allDay"], .bool(false))
    }

    func testUpsertOfExistingEventEmitsEventUpdatedNotEventCreated() async throws {
        let layer = try await connectedDataLayer()
        let store = CalendarStore(dataLayer: layer)
        var event = makeEvent()
        _ = try await store.upsert(event)

        event.title = "Q3 review (rescheduled)"
        _ = try await store.upsert(event)

        let receipts = try await store.receipts(forEvent: event.id)
        let created = receipts.filter { $0.receiptType == CalendarEventReceiptType.eventCreated.rawValue }
        let updated = receipts.filter { $0.receiptType == CalendarEventReceiptType.eventUpdated.rawValue }
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(updated.count, 1)
    }

    // MARK: - Error path: not found

    func testGetOfUnknownIDReturnsNil() async throws {
        let layer = try await connectedDataLayer()
        let store = CalendarStore(dataLayer: layer)
        let fetched = try await store.get(id: UUID())
        XCTAssertNil(fetched)
    }

    func testRespondToUnknownEventThrowsEventNotFoundWithoutWriting() async throws {
        let layer = try await connectedDataLayer()
        let store = CalendarStore(dataLayer: layer)
        let unknownID = UUID()
        do {
            _ = try await store.respond(to: unknownID, status: .accepted)
            XCTFail("expected eventNotFound")
        } catch CalendarStoreError.eventNotFound(let id) {
            XCTAssertEqual(id, unknownID)
        }
        let receipts = try await store.receipts(forEvent: unknownID)
        XCTAssertEqual(receipts.count, 0)
    }

    // MARK: - No-op: delete of unknown id emits zero receipts

    func testDeleteOfUnknownIDReturnsFalseAndEmitsZeroReceipts() async throws {
        let layer = try await connectedDataLayer()
        let store = CalendarStore(dataLayer: layer)
        let unknownID = UUID()
        let didDelete = try await store.delete(id: unknownID)
        XCTAssertFalse(didDelete)
        let receipts = try await store.receipts(forEvent: unknownID)
        XCTAssertEqual(receipts.count, 0)
    }

    func testDeleteOfKnownEventEmitsExactlyOneEventDeletedReceiptAndRemovesTheRow() async throws {
        let layer = try await connectedDataLayer()
        let store = CalendarStore(dataLayer: layer)
        let event = makeEvent()
        _ = try await store.upsert(event)

        let didDelete = try await store.delete(id: event.id)
        XCTAssertTrue(didDelete)

        let fetched = try await store.get(id: event.id)
        XCTAssertNil(fetched)

        let receipts = try await store.receipts(forEvent: event.id)
        let deleted = receipts.filter { $0.receiptType == CalendarEventReceiptType.eventDeleted.rawValue }
        XCTAssertEqual(deleted.count, 1)
    }

    // MARK: - respond() receipt

    func testRespondEmitsExactlyOneEventRespondedReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = CalendarStore(dataLayer: layer)
        var event = makeEvent()
        event.attendees = [CalendarEvent.Attendee(name: "Ada")]
        _ = try await store.upsert(event)

        _ = try await store.respond(to: event.id, status: .accepted)

        let receipts = try await store.receipts(forEvent: event.id)
        let responded = receipts.filter { $0.receiptType == CalendarEventReceiptType.eventResponded.rawValue }
        XCTAssertEqual(responded.count, 1)
        XCTAssertEqual(responded.first?.payload["status"], .string("accepted"))
    }

    // MARK: - link() receipt

    func testLinkEventEmitsExactlyOneEventLinkCreatedReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = CalendarStore(dataLayer: layer)
        let event = makeEvent()
        _ = try await store.upsert(event)
        let targetID = UUID()
        _ = try await layer.upsertEntity(GraphEntityUpsert(id: targetID, entityType: "note", label: "target"))

        _ = try await store.linkEvent(event.id, to: targetID, linkType: CalendarLinkType.prepDocument.rawValue)

        let receipts = try await store.receipts(forEvent: event.id)
        let linkCreated = receipts.filter { $0.receiptType == CalendarEventReceiptType.linkCreated.rawValue }
        XCTAssertEqual(linkCreated.count, 1)
        XCTAssertEqual(linkCreated.first?.payload["targetEntityID"], .string(targetID.uuidString))
        XCTAssertEqual(linkCreated.first?.payload["linkType"], .string(CalendarLinkType.prepDocument.rawValue))
    }
}
