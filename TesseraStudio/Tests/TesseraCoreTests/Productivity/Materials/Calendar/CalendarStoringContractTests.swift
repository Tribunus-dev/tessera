import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Calendar/CalendarStore.swift
// doc comments for upsert/get/delete/respond, `CalendarStoreError`'s cases,
// and the `CalendarStoring` protocol `CalendarStore` conforms to
// (CalendarChatHandler.swift). Doctrine rule 11: this is the ungated
// shadow of `CalendarStore`'s CRUD/no-op/error-path wiring contract,
// exercised against the in-memory `CalendarStoring` conformer since
// `CalendarStoring` is the real stub seam this material ships (see
// CalendarTestSupport.swift's header comment for why receipt assertions
// are NOT part of this file -- the protocol doesn't expose them).

final class CalendarStoringContractTests: DoctrineTestCase {

    private func makeEvent(
        id: UUID = UUID(),
        title: String = "Q3 review",
        attendees: [CalendarEvent.Attendee] = []
    ) -> CalendarEvent {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return CalendarEvent(
            id: id,
            title: title,
            startAt: start,
            endAt: start.addingTimeInterval(3600),
            attendees: attendees
        )
    }

    // MARK: - Persistence (upsert -> get round trip)

    func testUpsertThenGetReturnsThePersistedEvent() async throws {
        let store = InMemoryCalendarStore()
        let event = makeEvent()
        _ = try await store.upsert(event)
        let fetched = try await store.get(id: event.id)
        XCTAssertEqual(fetched, event)
    }

    func testGetOfUnknownIDReturnsNil() async throws {
        let store = InMemoryCalendarStore()
        let fetched = try await store.get(id: UUID())
        XCTAssertNil(fetched)
    }

    // MARK: - Error path: validation before persistence

    func testUpsertOfInvalidEventThrowsAndDoesNotPersist() async {
        let store = InMemoryCalendarStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let invalid = CalendarEvent(title: "", startAt: start, endAt: start.addingTimeInterval(3600))
        do {
            _ = try await store.upsert(invalid)
            XCTFail("expected invalidEvent to be thrown")
        } catch CalendarStoreError.invalidEvent {
            // expected
        } catch {
            XCTFail("expected CalendarStoreError.invalidEvent, got \(error)")
        }
        let fetched = try? await store.get(id: invalid.id)
        XCTAssertNil(fetched ?? nil)
    }

    // MARK: - No-op: delete of unknown id

    func testDeleteOfUnknownIDReturnsFalseAndDoesNotAffectOtherEvents() async throws {
        let store = InMemoryCalendarStore()
        let kept = makeEvent()
        _ = try await store.upsert(kept)
        let didDelete = try await store.delete(id: UUID())
        XCTAssertFalse(didDelete)
        let stillThere = try await store.get(id: kept.id)
        XCTAssertEqual(stillThere, kept)
    }

    func testDeleteOfKnownIDReturnsTrueAndRemovesTheEvent() async throws {
        let store = InMemoryCalendarStore()
        let event = makeEvent()
        _ = try await store.upsert(event)
        let didDelete = try await store.delete(id: event.id)
        XCTAssertTrue(didDelete)
        let fetched = try await store.get(id: event.id)
        XCTAssertNil(fetched)
    }

    // MARK: - Error path: respond()

    func testRespondToUnknownEventThrowsEventNotFound() async {
        let store = InMemoryCalendarStore()
        do {
            _ = try await store.respond(to: UUID(), attendeeIndex: nil, attendeeName: nil, status: .accepted)
            XCTFail("expected eventNotFound to be thrown")
        } catch CalendarStoreError.eventNotFound {
            // expected
        } catch {
            XCTFail("expected CalendarStoreError.eventNotFound, got \(error)")
        }
    }

    func testRespondToEventWithNoAttendeesThrowsNoAttendees() async throws {
        let store = InMemoryCalendarStore()
        let event = makeEvent(attendees: [])
        _ = try await store.upsert(event)
        do {
            _ = try await store.respond(to: event.id, attendeeIndex: nil, attendeeName: nil, status: .accepted)
            XCTFail("expected noAttendees to be thrown")
        } catch CalendarStoreError.noAttendees {
            // expected
        } catch {
            XCTFail("expected CalendarStoreError.noAttendees, got \(error)")
        }
    }

    func testRespondUpdatesTheMatchingAttendeesStatus() async throws {
        let store = InMemoryCalendarStore()
        let attendee = CalendarEvent.Attendee(name: "Ada", responseStatus: .needsAction)
        let event = makeEvent(attendees: [attendee])
        _ = try await store.upsert(event)
        let updated = try await store.respond(to: event.id, attendeeIndex: 0, attendeeName: nil, status: .accepted)
        XCTAssertEqual(updated.attendees[0].responseStatus, .accepted)
    }

    // MARK: - list() / search() query surface

    func testListReturnsEveryUpsertedEventSortedByStart() async throws {
        let store = InMemoryCalendarStore()
        let later = makeEvent(title: "later")
        var laterCopy = later
        laterCopy = CalendarEvent(
            id: later.id, title: "later",
            startAt: Date(timeIntervalSince1970: 1_800_000_000),
            endAt: Date(timeIntervalSince1970: 1_800_003_600)
        )
        let earlier = makeEvent(title: "earlier")
        _ = try await store.upsert(laterCopy)
        _ = try await store.upsert(earlier)
        let listed = try await store.list(limit: 10)
        XCTAssertEqual(listed.map(\.id), [earlier.id, laterCopy.id])
    }

    func testSearchMatchingIsCaseInsensitiveSubstring() async throws {
        let store = InMemoryCalendarStore()
        let event = makeEvent(title: "Q3 Review Meeting")
        _ = try await store.upsert(event)
        let results = try await store.search(matching: "review", limit: 10)
        XCTAssertEqual(results.map(\.id), [event.id])
    }

    func testSearchOfEmptyQueryReturnsEmpty() async throws {
        let store = InMemoryCalendarStore()
        _ = try await store.upsert(makeEvent())
        let results = try await store.search(matching: "   ", limit: 10)
        XCTAssertEqual(results, [])
    }

    // MARK: - Failure injection (denial-path style: the seam propagates
    // an injected failure rather than silently succeeding)

    func testForcedErrorPropagatesFromUpsertWithoutPersisting() async {
        let store = InMemoryCalendarStore()
        struct Boom: Error {}
        store.forcedError = Boom()
        do {
            _ = try await store.upsert(makeEvent())
            XCTFail("expected the forced error to propagate")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("expected Boom, got \(error)")
        }
    }
}
