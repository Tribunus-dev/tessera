import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Notes/NoteStore.swift
// doc comments + docs/tessera-productivity-materials-notes-design.md
// section 7 ("Idempotency. Pinning a pinned note is a no-op for the data
// layer, but the store still appends a receipt so the audit trail
// captures the intent"). Doctrine rule 11's gated half, paired with
// NoteStoreTests.swift's ungated shadow.
//
// NOTE (architectural nuance worth calling out): unlike most of this
// cluster's stores, `pin`/`unpin`/`archive`/`unarchive`/`addTag`/
// `removeTag` are documented as "no-op for the DATA (no row rewrite) but
// STILL emits a receipt" -- i.e. NOT a "zero receipts" no-op in the
// generic doctrine-rule-1 sense. This file tests that documented
// behavior exactly (a receipt IS expected, carrying a `wasAlready*`
// flag), and reserves the true "zero receipts" no-op assertion for
// `delete(id:)` of an unknown id, which is the one NoteStore method that
// genuinely skips the receipt call.

final class NoteStoreIntegrationTests: DoctrineTestCase {
    override var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.probe }

    private func connectedDataLayer() async throws -> TesseraDataLayer {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip("TESSERA_DB_INTEGRATION not set; skipping live-Postgres NoteStore tests")
        }
        let layer = TesseraDataLayer()
        let outcome = await layer.start()
        guard outcome == .ready else {
            throw XCTSkip("TesseraDataLayer did not reach .ready (\(outcome)); skipping live-Postgres NoteStore tests")
        }
        return layer
    }

    private func makeNote(title: String = "Q3 review") -> Note {
        Note(title: title, tags: ["q3"])
    }

    // MARK: - Receipt + persistence (upsert)

    func testUpsertPersistsAndEmitsExactlyOneNoteUpsertReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = NoteStore(dataLayer: layer)
        let note = makeNote()

        _ = try await store.upsert(note)

        let fetched = try await store.get(id: note.id)
        XCTAssertEqual(fetched, note)

        let receipts = try await store.receipts(forNote: note.id)
        let upserts = receipts.filter { $0.receiptType == NoteReceiptType.upsert.rawValue }
        XCTAssertEqual(upserts.count, 1)
        XCTAssertEqual(upserts.first?.payload["tagCount"], .number(1))
        XCTAssertEqual(upserts.first?.payload["pinned"], .bool(false))
    }

    // MARK: - Error path: not found

    func testGetOfUnknownIDReturnsNil() async throws {
        let layer = try await connectedDataLayer()
        let store = NoteStore(dataLayer: layer)
        let fetched = try await store.get(id: UUID())
        XCTAssertNil(fetched)
    }

    func testSetTitleOfUnknownIDThrowsNoteNotFoundWithoutWriting() async throws {
        let layer = try await connectedDataLayer()
        let store = NoteStore(dataLayer: layer)
        let unknownID = UUID()
        do {
            _ = try await store.setTitle("new", for: unknownID)
            XCTFail("expected noteNotFound")
        } catch NoteStoreError.noteNotFound(let id) {
            XCTAssertEqual(id, unknownID)
        }
        let receipts = try await store.receipts(forNote: unknownID)
        XCTAssertEqual(receipts.count, 0)
    }

    // MARK: - No-op: delete of unknown id (the one genuine zero-receipt no-op)

    func testDeleteOfUnknownIDReturnsFalseAndEmitsZeroReceipts() async throws {
        let layer = try await connectedDataLayer()
        let store = NoteStore(dataLayer: layer)
        let unknownID = UUID()
        let didDelete = try await store.delete(id: unknownID)
        XCTAssertFalse(didDelete)
        let receipts = try await store.receipts(forNote: unknownID)
        XCTAssertEqual(receipts.count, 0)
    }

    func testDeleteOfKnownNoteEmitsExactlyOneNoteDeleteReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = NoteStore(dataLayer: layer)
        let note = makeNote()
        _ = try await store.upsert(note)

        let didDelete = try await store.delete(id: note.id)
        XCTAssertTrue(didDelete)

        let receipts = try await store.receipts(forNote: note.id)
        XCTAssertEqual(receipts.filter { $0.receiptType == NoteReceiptType.delete.rawValue }.count, 1)
    }

    // MARK: - Documented idempotent-but-still-receipted pin/unpin

    func testPinningAnAlreadyPinnedNoteStillAppendsAReceiptMarkedAlreadyPinned() async throws {
        let layer = try await connectedDataLayer()
        let store = NoteStore(dataLayer: layer)
        let note = makeNote()
        _ = try await store.upsert(note)
        _ = try await store.pin(note.id)

        _ = try await store.pin(note.id)

        let receipts = try await store.receipts(forNote: note.id)
        let pinned = receipts.filter { $0.receiptType == NoteReceiptType.pinned.rawValue }
        XCTAssertEqual(pinned.count, 2, "pin() always appends a receipt per the design doc's idempotency note")
        XCTAssertEqual(pinned.first?.payload["wasAlreadyPinned"], .bool(false))
        XCTAssertEqual(pinned.last?.payload["wasAlreadyPinned"], .bool(true))
    }

    func testAddingAnExistingTagStillAppendsAReceiptMarkedAlreadyPresent() async throws {
        let layer = try await connectedDataLayer()
        let store = NoteStore(dataLayer: layer)
        let note = makeNote()
        _ = try await store.upsert(note)

        _ = try await store.addTag("q3", to: note.id)

        let receipts = try await store.receipts(forNote: note.id)
        let tagAdded = receipts.filter { $0.receiptType == NoteReceiptType.tagAdded.rawValue }
        XCTAssertEqual(tagAdded.count, 1)
        XCTAssertEqual(tagAdded.first?.payload["wasAlreadyPresent"], .bool(true))
    }

    // MARK: - link() receipt

    func testLinkEmitsExactlyOneNoteLinkCreatedReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = NoteStore(dataLayer: layer)
        let note = makeNote()
        _ = try await store.upsert(note)
        let targetID = UUID()

        _ = try await store.link(noteID: note.id, to: targetID, linkType: "summarizes")

        let receipts = try await store.receipts(forNote: note.id)
        let linkCreated = receipts.filter { $0.receiptType == NoteReceiptType.linkCreated.rawValue }
        XCTAssertEqual(linkCreated.count, 1)
        XCTAssertEqual(linkCreated.first?.payload["linkType"], .string("summarizes"))
    }
}
