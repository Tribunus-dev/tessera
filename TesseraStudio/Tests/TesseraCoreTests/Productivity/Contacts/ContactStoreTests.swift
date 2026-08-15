import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Contacts/ContactStore.swift
// doc comments (receipt table is enumerated by the `ContactReceiptType`
// enum's own doc comments, no separate design doc exists for the
// top-level Contacts engine per this cluster's brief -- fallback
// hierarchy: doc comments). `ContactStore` wraps `TesseraDataLayer`
// directly with no protocol seam; this is the ungated half of doctrine
// rule 11 (see CalendarStoreTests.swift's header for the
// `.closed`-propagation mechanism) plus the receipt-type taxonomy pin
// and the pure `TesseraContactEgressGuard` allow-list logic. The
// receipt + persistence + no-op + not-found quartet needs a live row
// and lives in ContactStoreIntegrationTests.swift (TESSERA_DB_INTEGRATION-gated).

final class ContactStoreTests: DoctrineTestCase {

    private func makeStore() -> ContactStore {
        ContactStore(dataLayer: TesseraDataLayer())
    }

    private func makeContact() -> Contact {
        Contact(subtype: .person, name: NameComponents(first: "Ada", last: "Example"))
    }

    // MARK: - Error propagation on a closed data layer

    func testUpsertOnClosedDataLayerThrowsRatherThanSucceeding() async {
        let store = makeStore()
        do {
            _ = try await store.upsert(makeContact())
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

    // MARK: - Receipt type taxonomy pin (rule 5 + rule 7's independent oracle)

    func testContactReceiptTypeRawValuesArePinned() {
        let expected: [ContactReceiptType: String] = [
            .upsert: "contact_upsert",
            .delete: "contact_delete",
            .linkCreated: "contact_link_created",
            .linkDeleted: "contact_link_deleted",
            .contactExport: "contact_export",
        ]
        for (receiptType, rawValue) in expected {
            XCTAssertEqual(receiptType.rawValue, rawValue)
        }
    }

    func testContactReceiptTypeHasNoUnexpectedCases() {
        let expected: Set<String> = [
            "contact_upsert", "contact_delete", "contact_link_created",
            "contact_link_deleted", "contact_export",
        ]
        XCTAssertEqual(Set(ContactReceiptType.allCases.map(\.rawValue)), expected)
    }

    // MARK: - ContactStoreError equality

    func testContactStoreErrorNotFoundEqualityIsByID() {
        let id = UUID()
        XCTAssertEqual(ContactStoreError.contactNotFound(id: id), ContactStoreError.contactNotFound(id: id))
        XCTAssertNotEqual(ContactStoreError.contactNotFound(id: id), ContactStoreError.contactNotFound(id: UUID()))
    }

    // MARK: - Egress guard (pure logic, safety surface -- every ratified
    // invariant gets a named test)

    func testEgressGuardAllowsUserExplicitExport() {
        XCTAssertTrue(TesseraContactEgressGuard.allows("user_explicit_export"))
    }

    func testEgressGuardAllowsShareSheet() {
        XCTAssertTrue(TesseraContactEgressGuard.allows("share_sheet"))
    }

    func testEgressGuardAllowsAgentForUser() {
        XCTAssertTrue(TesseraContactEgressGuard.allows("agent_for_user"))
    }

    func testEgressGuardDeniesUnknownProvenance() {
        XCTAssertFalse(TesseraContactEgressGuard.allows("scraped_from_web"))
    }

    func testEgressGuardDeniesEmptyProvenance() {
        XCTAssertFalse(TesseraContactEgressGuard.allows(""))
    }

    func testExportVCardThrowsEgressDeniedForDisallowedProvenanceWithoutTouchingDataLayer() async {
        let store = makeStore()
        let contact = makeContact()
        do {
            _ = try await store.exportVCard(contact, preEncodedVCard: Data("BEGIN:VCARD".utf8), provenance: "scraped_from_web")
            XCTFail("expected egressDenied")
        } catch ContactStoreError.egressDenied(let provenance) {
            XCTAssertEqual(provenance, "scraped_from_web")
        } catch {
            XCTFail("expected ContactStoreError.egressDenied, got \(error)")
        }
    }
}
