import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Code/CodeStore.swift
// doc comments + Sources/TesseraCore/Productivity/Materials/Code/CodeReceiptType.swift
// doc comments + docs/tessera-productivity-materials-code-design.md
// section 9's receipt-type list. Doctrine rule 11's gated half, paired
// with CodeStoreTests.swift's ungated shadow (which covers the full
// in-memory-index quartet minus receipt assertions -- see that file's
// header for why receipts specifically need a real data layer here).

final class CodeStoreIntegrationTests: DoctrineTestCase {
    override var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.probe }

    private func connectedDataLayer() async throws -> TesseraDataLayer {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip("TESSERA_DB_INTEGRATION not set; skipping live-Postgres CodeStore tests")
        }
        let layer = TesseraDataLayer()
        let outcome = await layer.start()
        guard outcome == .ready else {
            throw XCTSkip("TesseraDataLayer did not reach .ready (\(outcome)); skipping live-Postgres CodeStore tests")
        }
        return layer
    }

    private func makeFile(path: String = "/repo/Sources/Foo.swift", body: String = "let x = 1\n") -> CodeFile {
        CodeFile(path: path, body: body)
    }

    // MARK: - Receipt + persistence (import)

    func testUpsertOfNewFileEmitsExactlyOneCodeFileImportedReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = CodeStore(dataLayer: layer)
        let file = makeFile()

        _ = try await store.upsert(file)

        let receipts = try await store.receipts(forFile: file.id)
        XCTAssertEqual(receipts.filter { $0.receiptType == CodeReceiptType.imported.rawValue }.count, 1)
    }

    func testUpsertOfExistingPathEmitsCodeFileModifiedNotImported() async throws {
        let layer = try await connectedDataLayer()
        let store = CodeStore(dataLayer: layer)
        var file = makeFile()
        _ = try await store.upsert(file)

        file.body = "let x = 2\n"
        _ = try await store.upsert(file)

        let receipts = try await store.receipts(forFile: file.id)
        XCTAssertEqual(receipts.filter { $0.receiptType == CodeReceiptType.imported.rawValue }.count, 1)
        XCTAssertEqual(receipts.filter { $0.receiptType == CodeReceiptType.modified.rawValue }.count, 1)
    }

    // MARK: - Error path: not found (zero receipts, per CodeStoreTests.swift's
    // ungated coverage of the throw itself; this file adds the receipt
    // assertion which needs a real data layer to be meaningful)

    func testDeleteOfUnknownFileThrowsAndEmitsZeroReceipts() async throws {
        let layer = try await connectedDataLayer()
        let store = CodeStore(dataLayer: layer)
        let unknownID = UUID()
        do {
            try await store.delete(id: unknownID)
            XCTFail("expected fileNotFound")
        } catch CodeStoreError.fileNotFound {
            // expected
        }
        let receipts = try await store.receipts(forFile: unknownID)
        XCTAssertEqual(receipts.count, 0)
    }

    func testDeleteOfKnownFileEmitsExactlyOneCodeFileDeletedReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = CodeStore(dataLayer: layer)
        let file = makeFile()
        _ = try await store.upsert(file)

        try await store.delete(id: file.id)

        let receipts = try await store.receipts(forFile: file.id)
        XCTAssertEqual(receipts.filter { $0.receiptType == CodeReceiptType.deleted.rawValue }.count, 1)
    }

    // MARK: - rename() receipt

    func testRenameEmitsExactlyOneCodeFileRenamedReceiptWithOldAndNewPaths() async throws {
        let layer = try await connectedDataLayer()
        let store = CodeStore(dataLayer: layer)
        let file = makeFile(path: "/repo/Old.swift")
        _ = try await store.upsert(file)

        _ = try await store.rename(id: file.id, to: "/repo/New.swift")

        let receipts = try await store.receipts(forFile: file.id)
        let renamed = receipts.filter { $0.receiptType == CodeReceiptType.renamed.rawValue }
        XCTAssertEqual(renamed.count, 1)
        XCTAssertEqual(renamed.first?.payload["oldPath"], .string("/repo/Old.swift"))
        XCTAssertEqual(renamed.first?.payload["newPath"], .string("/repo/New.swift"))
    }

    // MARK: - apply() receipt

    func testApplyReplaceCodeBlockEmitsExactlyOneCodeFileBodyReplacedReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = CodeStore(dataLayer: layer)
        let file = makeFile(body: "let x = 1\n")
        _ = try await store.upsert(file)

        _ = try await store.apply(.replaceCodeBlock(fileID: file.id, newBody: "let x = 2\n"), to: file.id)

        let receipts = try await store.receipts(forFile: file.id)
        XCTAssertEqual(receipts.filter { $0.receiptType == CodeReceiptType.bodyReplaced.rawValue }.count, 1)
    }

    // MARK: - link() receipt

    func testLinkEmitsExactlyOneCodeFileLinkedReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = CodeStore(dataLayer: layer)
        let file = makeFile()
        _ = try await store.upsert(file)
        let targetID = UUID()

        _ = try await store.link(file.id, to: targetID, linkType: "implements")

        let receipts = try await store.receipts(forFile: file.id)
        XCTAssertEqual(receipts.filter { $0.receiptType == CodeReceiptType.linked.rawValue }.count, 1)
    }

    // MARK: - loadAll() rebuilds the in-memory index from the data layer

    func testLoadAllRebuildsTheIndexFromPersistedRows() async throws {
        let layer = try await connectedDataLayer()
        let writer = CodeStore(dataLayer: layer)
        let file = makeFile()
        _ = try await writer.upsert(file)

        let reader = CodeStore(dataLayer: layer)
        try await reader.loadAll()

        XCTAssertEqual(reader.get(id: file.id)?.path, file.path)
    }
}
