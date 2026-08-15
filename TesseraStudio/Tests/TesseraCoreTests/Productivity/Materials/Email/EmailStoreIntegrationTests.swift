import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Email/EmailStore.swift
// doc comments + docs/tessera-productivity-materials-email-design.md
// section 8's receipt table + section 5 ("The draft is also persisted in
// .drafts immediately"). Doctrine rule 11's gated half, paired with
// EmailStoreTests.swift's ungated shadow.

final class EmailStoreIntegrationTests: DoctrineTestCase {
    override var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.probe }

    private func connectedDataLayer() async throws -> TesseraDataLayer {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip("TESSERA_DB_INTEGRATION not set; skipping live-Postgres EmailStore tests")
        }
        let layer = TesseraDataLayer()
        let outcome = await layer.start()
        guard outcome == .ready else {
            throw XCTSkip("TesseraDataLayer did not reach .ready (\(outcome)); skipping live-Postgres EmailStore tests")
        }
        return layer
    }

    private func makeMessage(subject: String = "Q3 numbers") -> EmailMessage {
        EmailMessage(
            messageID: "abc-\(UUID().uuidString)@example.com",
            from: EmailAddress(email: "ada@example.com"),
            subject: subject
        )
    }

    // MARK: - Receipt + persistence (upsert)

    func testUpsertPersistsAndEmitsExactlyOneEmailUpsertReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = EmailStore(dataLayer: layer)
        let message = makeMessage()

        _ = try await store.upsert(message)

        let fetched = try await store.get(id: message.id)
        XCTAssertEqual(fetched, message)

        let receipts = try await store.receipts(forEmail: message.id)
        let upserts = receipts.filter { $0.receiptType == EmailReceiptType.upsert.rawValue }
        XCTAssertEqual(upserts.count, 1)
        XCTAssertEqual(upserts.first?.payload["subject"], .string(message.displaySubject))
    }

    // MARK: - Error path: not found

    func testGetOfUnknownIDReturnsNil() async throws {
        let layer = try await connectedDataLayer()
        let store = EmailStore(dataLayer: layer)
        let fetched = try await store.get(id: UUID())
        XCTAssertNil(fetched)
    }

    func testMarkReadOfUnknownIDReturnsNilAndEmitsZeroReceipts() async throws {
        let layer = try await connectedDataLayer()
        let store = EmailStore(dataLayer: layer)
        let unknownID = UUID()
        let result = try await store.markRead(unknownID)
        XCTAssertNil(result)
        let receipts = try await store.receipts(forEmail: unknownID)
        XCTAssertEqual(receipts.count, 0)
    }

    // MARK: - No-op: re-setting the same read state emits zero receipts

    func testMarkReadWithUnchangedStateEmitsZeroAdditionalReceipts() async throws {
        let layer = try await connectedDataLayer()
        let store = EmailStore(dataLayer: layer)
        var message = makeMessage()
        message.isRead = true
        _ = try await store.upsert(message)

        let before = try await store.receipts(forEmail: message.id).count
        let result = try await store.markRead(message.id, read: true)
        XCTAssertEqual(result?.isRead, true)
        let after = try await store.receipts(forEmail: message.id).count

        XCTAssertEqual(after, before, "marking an already-read email as read again must not append a receipt")
    }

    func testMarkReadWithChangedStateEmitsExactlyOneEmailReadReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = EmailStore(dataLayer: layer)
        var message = makeMessage()
        message.isRead = false
        _ = try await store.upsert(message)

        _ = try await store.markRead(message.id, read: true)

        let receipts = try await store.receipts(forEmail: message.id)
        let readReceipts = receipts.filter { $0.receiptType == EmailReceiptType.read.rawValue }
        XCTAssertEqual(readReceipts.count, 1)
        XCTAssertEqual(readReceipts.first?.payload["prior"], .bool(false))
        XCTAssertEqual(readReceipts.first?.payload["next"], .bool(true))
    }

    // MARK: - No-op: delete of unknown id

    func testDeleteOfUnknownIDReturnsFalseAndEmitsZeroReceipts() async throws {
        let layer = try await connectedDataLayer()
        let store = EmailStore(dataLayer: layer)
        let unknownID = UUID()
        let didDelete = try await store.delete(id: unknownID)
        XCTAssertFalse(didDelete)
        let receipts = try await store.receipts(forEmail: unknownID)
        XCTAssertEqual(receipts.count, 0)
    }

    func testDeleteOfKnownEmailEmitsExactlyOneEmailDeleteReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = EmailStore(dataLayer: layer)
        let message = makeMessage()
        _ = try await store.upsert(message)

        let didDelete = try await store.delete(id: message.id)
        XCTAssertTrue(didDelete)

        let fetched = try await store.get(id: message.id)
        XCTAssertNil(fetched)

        let receipts = try await store.receipts(forEmail: message.id)
        let deletes = receipts.filter { $0.receiptType == EmailReceiptType.delete.rawValue }
        XCTAssertEqual(deletes.count, 1)
    }

    // MARK: - Folder mutations pick the right receipt type

    func testSetFolderToArchiveEmitsEmailArchivedReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = EmailStore(dataLayer: layer)
        let message = makeMessage()
        _ = try await store.upsert(message)

        _ = try await store.setFolder(message.id, folder: .archive)

        let receipts = try await store.receipts(forEmail: message.id)
        XCTAssertEqual(receipts.filter { $0.receiptType == EmailReceiptType.archived.rawValue }.count, 1)
        XCTAssertEqual(receipts.filter { $0.receiptType == EmailReceiptType.folderChanged.rawValue }.count, 0)
    }

    func testSaveDraftForcesFolderToDrafts() async throws {
        let layer = try await connectedDataLayer()
        let store = EmailStore(dataLayer: layer)
        var draft = makeMessage()
        draft.folder = .sent

        let saved = try await store.saveDraft(draft)
        XCTAssertEqual(saved.folder, .drafts)

        let fetched = try await store.get(id: draft.id)
        XCTAssertEqual(fetched?.folder, .drafts)
    }
}
