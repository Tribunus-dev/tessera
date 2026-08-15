import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Contacts/ContactStore.swift
// doc comments + `ContactReceiptType`'s own doc comments. Doctrine rule
// 11's gated half, paired with ContactStoreTests.swift's ungated shadow.

final class ContactStoreIntegrationTests: DoctrineTestCase {
    override var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.probe }

    private func connectedDataLayer() async throws -> TesseraDataLayer {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip("TESSERA_DB_INTEGRATION not set; skipping live-Postgres ContactStore tests")
        }
        let layer = TesseraDataLayer()
        let outcome = await layer.start()
        guard outcome == .ready else {
            throw XCTSkip("TesseraDataLayer did not reach .ready (\(outcome)); skipping live-Postgres ContactStore tests")
        }
        return layer
    }

    private func makeContact(first: String = "Ada") -> Contact {
        Contact(subtype: .person, name: NameComponents(first: first, last: "Example"))
    }

    // MARK: - Receipt + persistence (upsert)

    func testUpsertPersistsAndEmitsExactlyOneContactUpsertReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = ContactStore(dataLayer: layer)
        let contact = makeContact()

        _ = try await store.upsert(contact)

        let fetched = try await store.get(id: contact.id)
        XCTAssertEqual(fetched, contact)

        let receipts = try await store.receipts(forContact: contact.id)
        let upserts = receipts.filter { $0.receiptType == ContactReceiptType.upsert.rawValue }
        XCTAssertEqual(upserts.count, 1)
        XCTAssertEqual(upserts.first?.payload["displayName"], .string(contact.displayName))
    }

    // MARK: - Error path: not found

    func testGetOfUnknownIDReturnsNil() async throws {
        let layer = try await connectedDataLayer()
        let store = ContactStore(dataLayer: layer)
        let fetched = try await store.get(id: UUID())
        XCTAssertNil(fetched)
    }

    // MARK: - No-op: delete of unknown id

    func testDeleteOfUnknownIDReturnsFalseAndEmitsZeroReceipts() async throws {
        let layer = try await connectedDataLayer()
        let store = ContactStore(dataLayer: layer)
        let unknownID = UUID()
        let didDelete = try await store.delete(id: unknownID)
        XCTAssertFalse(didDelete)
        let receipts = try await store.receipts(forContact: unknownID)
        XCTAssertEqual(receipts.count, 0)
    }

    func testDeleteOfKnownContactEmitsExactlyOneContactDeleteReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = ContactStore(dataLayer: layer)
        let contact = makeContact()
        _ = try await store.upsert(contact)

        let didDelete = try await store.delete(id: contact.id)
        XCTAssertTrue(didDelete)

        let fetched = try await store.get(id: contact.id)
        XCTAssertNil(fetched)

        let receipts = try await store.receipts(forContact: contact.id)
        XCTAssertEqual(receipts.filter { $0.receiptType == ContactReceiptType.delete.rawValue }.count, 1)
    }

    // MARK: - link() receipt

    func testLinkContactEmitsExactlyOneContactLinkCreatedReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = ContactStore(dataLayer: layer)
        let contact = makeContact()
        _ = try await store.upsert(contact)
        let targetID = UUID()

        _ = try await store.linkContact(contact.id, to: targetID, linkType: "attendee_of")

        let receipts = try await store.receipts(forContact: contact.id)
        let linkCreated = receipts.filter { $0.receiptType == ContactReceiptType.linkCreated.rawValue }
        XCTAssertEqual(linkCreated.count, 1)
        XCTAssertEqual(linkCreated.first?.payload["linkType"], .string("attendee_of"))
    }

    // MARK: - exportVCard() receipt (allowed provenance)

    func testExportVCardWithAllowedProvenanceEmitsExactlyOneContactExportReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = ContactStore(dataLayer: layer)
        let contact = makeContact()
        _ = try await store.upsert(contact)
        let data = Data("BEGIN:VCARD\nEND:VCARD".utf8)

        let returned = try await store.exportVCard(contact, preEncodedVCard: data, provenance: "user_explicit_export")
        XCTAssertEqual(returned, data)

        let receipts = try await store.receipts(forContact: contact.id)
        let exports = receipts.filter { $0.receiptType == ContactReceiptType.contactExport.rawValue }
        XCTAssertEqual(exports.count, 1)
        XCTAssertEqual(exports.first?.payload["provenance"], .string("user_explicit_export"))
    }

    // MARK: - search()

    func testSearchMatchingReturnsUpsertedContactByNamePrefix() async throws {
        let layer = try await connectedDataLayer()
        let store = ContactStore(dataLayer: layer)
        let contact = makeContact(first: "Zephyrine-\(UUID().uuidString.prefix(8))")
        _ = try await store.upsert(contact)

        let results = try await store.search(matching: contact.displayName.lowercased())
        XCTAssertTrue(results.contains { $0.id == contact.id })
    }
}
