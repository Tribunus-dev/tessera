import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Email/EmailStore.swift
// doc comments + docs/tessera-productivity-materials-email-design.md
// section 8's receipt table.
//
// `EmailStore` wraps `TesseraDataLayer` directly with no protocol seam
// (unlike CalendarStore/ReminderStore -- see this cluster's findings
// file, "Architectural notes"). This file is the ungated half of
// doctrine rule 11: it exercises everything reachable without a live
// Postgres row -- error propagation through a never-connected data layer
// (`TesseraDataStoreError.closed`, see CalendarStoreTests.swift's header
// for the mechanism) plus the receipt-type taxonomy pin. The
// receipt + persistence + no-op + not-found-returns-nil quartet needs a
// live row and lives in EmailStoreIntegrationTests.swift
// (TESSERA_DB_INTEGRATION-gated).

final class EmailStoreTests: DoctrineTestCase {

    private func makeStore() -> EmailStore {
        EmailStore(dataLayer: TesseraDataLayer())
    }

    private func makeMessage() -> EmailMessage {
        EmailMessage(
            messageID: "abc@example.com",
            from: EmailAddress(email: "ada@example.com"),
            subject: "Q3 numbers"
        )
    }

    // MARK: - Error propagation on a closed data layer (no silent success)

    func testUpsertOnClosedDataLayerThrowsRatherThanSucceeding() async {
        let store = makeStore()
        do {
            _ = try await store.upsert(makeMessage())
            XCTFail("expected the closed data layer's error to propagate")
        } catch {
            XCTAssertTrue(error is TesseraDataStoreError, "expected TesseraDataStoreError, got \(error)")
        }
    }

    func testGetOnClosedDataLayerThrowsRatherThanReturningNil() async {
        let store = makeStore()
        do {
            _ = try await store.get(id: UUID())
            XCTFail("expected the closed data layer's error to propagate")
        } catch {
            XCTAssertTrue(error is TesseraDataStoreError, "expected TesseraDataStoreError, got \(error)")
        }
    }

    func testMarkReadOnClosedDataLayerThrowsRatherThanReturningNil() async {
        let store = makeStore()
        do {
            _ = try await store.markRead(UUID())
            XCTFail("expected the closed data layer's error to propagate")
        } catch {
            XCTAssertTrue(error is TesseraDataStoreError, "expected TesseraDataStoreError, got \(error)")
        }
    }

    // MARK: - Receipt type taxonomy pin (rule 5 + rule 7's independent
    // oracle: hardcoded from the design doc's table, section 8)

    func testEmailReceiptTypeRawValuesArePinned() {
        let expected: [EmailReceiptType: String] = [
            .upsert: "email_upsert",
            .delete: "email_delete",
            .read: "email_read",
            .starred: "email_starred",
            .folderChanged: "email_folder_changed",
            .archived: "email_archived",
            .trashed: "email_trashed",
            .replied: "email_replied",
            .forwarded: "email_forwarded",
            .imported: "email_imported",
            .linkCreated: "email_link_created",
            .linkDeleted: "email_link_deleted",
            .draftSaved: "email_draft_saved",
            .routedToShareSheet: "email_routed_to_share_sheet",
        ]
        for (receiptType, rawValue) in expected {
            XCTAssertEqual(receiptType.rawValue, rawValue)
        }
    }

    func testEmailReceiptTypeHasNoUnexpectedCases() {
        let expected: Set<String> = [
            "email_upsert", "email_delete", "email_read", "email_starred",
            "email_folder_changed", "email_archived", "email_trashed",
            "email_replied", "email_forwarded", "email_imported",
            "email_link_created", "email_link_deleted", "email_draft_saved",
            "email_routed_to_share_sheet",
        ]
        XCTAssertEqual(Set(EmailReceiptType.allCases.map(\.rawValue)), expected)
    }

    // MARK: - EmailStoreError equality

    func testEmailStoreErrorEmailNotFoundEqualityIsByID() {
        let id = UUID()
        XCTAssertEqual(EmailStoreError.emailNotFound(id: id), EmailStoreError.emailNotFound(id: id))
        XCTAssertNotEqual(EmailStoreError.emailNotFound(id: id), EmailStoreError.emailNotFound(id: UUID()))
    }
}
