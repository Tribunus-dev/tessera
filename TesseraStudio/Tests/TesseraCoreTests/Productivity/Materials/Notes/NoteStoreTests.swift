import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Notes/NoteStore.swift
// doc comments + docs/tessera-productivity-materials-notes-design.md
// section 7's receipt table.
//
// `NoteStore` wraps `TesseraDataLayer` directly with no protocol seam.
// This is the ungated half of doctrine rule 11 (see
// CalendarStoreTests.swift's header for the `.closed`-propagation
// mechanism this file relies on) plus the receipt-type taxonomy pin. The
// receipt + persistence + no-op + not-found quartet needs a live row and
// lives in NoteStoreIntegrationTests.swift (TESSERA_DB_INTEGRATION-gated).

final class NoteStoreTests: DoctrineTestCase {

    private func makeStore() -> NoteStore {
        NoteStore(dataLayer: TesseraDataLayer())
    }

    // MARK: - Error propagation on a closed data layer

    func testUpsertOnClosedDataLayerThrowsRatherThanSucceeding() async {
        let store = makeStore()
        do {
            _ = try await store.upsert(Note(title: "x"))
            XCTFail("expected the closed data layer's error to propagate")
        } catch {
            XCTAssertTrue(error is TesseraDataStoreError, "expected TesseraDataStoreError, got \(error)")
        }
    }

    func testSetTitleOnClosedDataLayerThrowsRatherThanSucceeding() async {
        // setTitle's loadOrFail() calls get() -> dataLayer.getEntity, which
        // throws `.closed` here; it must NOT be mistaken for
        // NoteStoreError.noteNotFound (that case only fires when the data
        // layer successfully returns "no row").
        let store = makeStore()
        do {
            _ = try await store.setTitle("new title", for: UUID())
            XCTFail("expected the closed data layer's error to propagate")
        } catch let error as NoteStoreError {
            XCTFail("expected TesseraDataStoreError (closed data layer), got NoteStoreError \(error)")
        } catch {
            XCTAssertTrue(error is TesseraDataStoreError, "expected TesseraDataStoreError, got \(error)")
        }
    }

    // MARK: - Receipt type taxonomy pin (rule 5 + rule 7's independent
    // oracle: hardcoded from the design doc's table, section 7)

    func testNoteReceiptTypeRawValuesArePinned() {
        let expected: [NoteReceiptType: String] = [
            .upsert: "note_upsert",
            .delete: "note_delete",
            .titleChanged: "note_title_changed",
            .bodyChanged: "note_body_changed",
            .pinned: "note_pinned",
            .unpinned: "note_unpinned",
            .archived: "note_archived",
            .unarchived: "note_unarchived",
            .tagsChanged: "note_tags_changed",
            .tagAdded: "note_tag_added",
            .tagRemoved: "note_tag_removed",
            .linkCreated: "note_link_created",
        ]
        for (receiptType, rawValue) in expected {
            XCTAssertEqual(receiptType.rawValue, rawValue)
        }
    }

    func testNoteReceiptTypeHasNoUnexpectedCases() {
        let expected: Set<String> = [
            "note_upsert", "note_delete", "note_title_changed", "note_body_changed",
            "note_pinned", "note_unpinned", "note_archived", "note_unarchived",
            "note_tags_changed", "note_tag_added", "note_tag_removed", "note_link_created",
        ]
        XCTAssertEqual(Set(NoteReceiptType.allCases.map(\.rawValue)), expected)
    }

    // MARK: - NoteStoreError equality

    func testNoteStoreErrorNoteNotFoundEqualityIsByID() {
        let id = UUID()
        XCTAssertEqual(NoteStoreError.noteNotFound(id: id), NoteStoreError.noteNotFound(id: id))
        XCTAssertNotEqual(NoteStoreError.noteNotFound(id: id), NoteStoreError.noteNotFound(id: UUID()))
    }
}
