import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Code/CodeStore.swift
// doc comments -- notably: "No Postgres in v1 unit tests. The store has
// an init(dataLayer:) that takes a real TesseraDataLayer and an init()
// that uses a no-op data layer for tests. The apply and query methods
// work against an in-memory file index; the data layer is the durable
// mirror. Tests of the pure logic (mutation engine, receipt shape)
// don't need a database." -- plus
// docs/tessera-productivity-materials-code-design.md section 9's
// receipt-type list.
//
// Unlike this cluster's other stores, `CodeStore()` (no data layer) is
// the DOCUMENTED unit-test seam, not a workaround: `upsert`/`get`/
// `listAll`/`delete`/`rename`/`link`/`apply` all mutate the in-memory
// `index`/`pathToID` first, and every not-found check
// (`CodeStoreError.fileNotFound`) fires from that in-memory lookup
// BEFORE any data-layer call. That makes the full CRUD + no-op +
// error-path quartet genuinely testable ungated. The one piece that is
// NOT testable this way is "exactly one receipt": `appendReceipt` is a
// silent no-op when `dataLayer == nil` (`guard let dataLayer else {
// return }`), so `receipts(forFile:)` always returns `[]` under
// `CodeStore()`. That half of the quartet is in
// CodeStoreIntegrationTests.swift (TESSERA_DB_INTEGRATION-gated, a real
// `TesseraDataLayer`).

final class CodeStoreTests: DoctrineTestCase {

    private func makeFile(path: String = "/repo/Sources/Foo.swift", body: String = "let x = 1\n") -> CodeFile {
        CodeFile(path: path, body: body)
    }

    // MARK: - Persistence into the in-memory index

    func testUpsertThenGetByIDReturnsThePersistedFile() async throws {
        let store = CodeStore()
        let file = makeFile()
        _ = try await store.upsert(file)
        XCTAssertEqual(store.get(id: file.id), file)
    }

    func testUpsertThenGetByPathReturnsThePersistedFile() async throws {
        let store = CodeStore()
        let file = makeFile(path: "/repo/Sources/Foo.swift")
        _ = try await store.upsert(file)
        XCTAssertEqual(store.get(path: "/repo/Sources/Foo.swift"), file)
    }

    func testGetOfUnknownIDReturnsNil() {
        let store = CodeStore()
        XCTAssertNil(store.get(id: UUID()))
    }

    func testGetOfUnknownPathReturnsNil() {
        let store = CodeStore()
        XCTAssertNil(store.get(path: "/nope"))
    }

    func testListAllReturnsEveryUpsertedFileSortedByPath() async throws {
        let store = CodeStore()
        let b = makeFile(path: "/repo/b.swift")
        let a = makeFile(path: "/repo/a.swift")
        _ = try await store.upsert(b)
        _ = try await store.upsert(a)
        XCTAssertEqual(store.listAll().map(\.path), ["/repo/a.swift", "/repo/b.swift"])
    }

    // MARK: - No receipts emitted when there is no data layer (documented,
    // not an oversight -- see file header)

    func testUpsertOnNoDataLayerConstructorEmitsZeroReceipts() async throws {
        let store = CodeStore()
        let file = makeFile()
        _ = try await store.upsert(file)
        let receipts = try await store.receipts(forFile: file.id)
        XCTAssertEqual(receipts, [])
    }

    // MARK: - Error path: apply/delete/rename/link on an unknown id throw
    // synchronously from the in-memory index, without touching a data
    // layer at all (the real contract, not a workaround for this store)

    func testApplyOnUnknownFileIDThrowsFileNotFoundWithoutMutatingTheIndex() async {
        let store = CodeStore()
        let unknownID = UUID()
        do {
            _ = try await store.apply(.addTag(fileID: unknownID, tag: "core"), to: unknownID)
            XCTFail("expected fileNotFound")
        } catch CodeStoreError.fileNotFound(let id) {
            XCTAssertEqual(id, unknownID)
        } catch {
            XCTFail("expected CodeStoreError.fileNotFound, got \(error)")
        }
        XCTAssertEqual(store.listAll(), [])
    }

    func testDeleteOnUnknownFileIDThrowsFileNotFound() async {
        let store = CodeStore()
        let unknownID = UUID()
        do {
            try await store.delete(id: unknownID)
            XCTFail("expected fileNotFound")
        } catch CodeStoreError.fileNotFound(let id) {
            XCTAssertEqual(id, unknownID)
        } catch {
            XCTFail("expected CodeStoreError.fileNotFound, got \(error)")
        }
    }

    func testDeleteOfKnownFileRemovesItFromTheIndex() async throws {
        let store = CodeStore()
        let file = makeFile()
        _ = try await store.upsert(file)
        try await store.delete(id: file.id)
        XCTAssertNil(store.get(id: file.id))
        XCTAssertNil(store.get(path: file.path))
    }

    func testRenameOnUnknownFileIDThrowsFileNotFound() async {
        let store = CodeStore()
        let unknownID = UUID()
        do {
            _ = try await store.rename(id: unknownID, to: "/repo/New.swift")
            XCTFail("expected fileNotFound")
        } catch CodeStoreError.fileNotFound(let id) {
            XCTAssertEqual(id, unknownID)
        } catch {
            XCTFail("expected CodeStoreError.fileNotFound, got \(error)")
        }
    }

    func testRenameOfKnownFileUpdatesPathAndFilenameKeepingIDStable() async throws {
        let store = CodeStore()
        let file = makeFile(path: "/repo/Old.swift")
        _ = try await store.upsert(file)

        let renamed = try await store.rename(id: file.id, to: "/repo/New.swift")

        XCTAssertEqual(renamed.id, file.id)
        XCTAssertEqual(renamed.path, "/repo/New.swift")
        XCTAssertEqual(renamed.filename, "New.swift")
        XCTAssertNil(store.get(path: "/repo/Old.swift"))
        XCTAssertEqual(store.get(path: "/repo/New.swift")?.id, file.id)
    }

    func testLinkOnUnknownFileIDThrowsFileNotFound() async {
        let store = CodeStore()
        let unknownID = UUID()
        do {
            _ = try await store.link(unknownID, to: UUID())
            XCTFail("expected fileNotFound")
        } catch CodeStoreError.fileNotFound(let id) {
            XCTAssertEqual(id, unknownID)
        } catch {
            XCTFail("expected CodeStoreError.fileNotFound, got \(error)")
        }
    }

    func testLinkOnNoDataLayerConstructorReturnsNilWithoutThrowing() async throws {
        // `link` checks the in-memory index first (throws fileNotFound if
        // absent), then early-returns nil when there is no data layer
        // (`guard let dataLayer else { return nil }`) rather than
        // attempting the link.
        let store = CodeStore()
        let file = makeFile()
        _ = try await store.upsert(file)
        let link = try await store.link(file.id, to: UUID())
        XCTAssertNil(link)
    }

    // MARK: - apply(): the mutation engine actually mutates the body

    func testApplyReplaceCodeBlockUpdatesTheBodyAndChecksum() async throws {
        let store = CodeStore()
        let file = makeFile(body: "let x = 1\n")
        _ = try await store.upsert(file)

        let result = try await store.apply(.replaceCodeBlock(fileID: file.id, newBody: "let x = 2\n"), to: file.id)

        XCTAssertEqual(result.updated.body, "let x = 2\n")
        XCTAssertEqual(store.get(id: file.id)?.body, "let x = 2\n")
        XCTAssertNotEqual(result.updated.checksum, file.checksum)
    }

    // MARK: - loadAll() on a no-data-layer store is a documented no-op

    func testLoadAllOnNoDataLayerConstructorLeavesTheIndexUntouched() async throws {
        let store = CodeStore()
        let file = makeFile()
        _ = try await store.upsert(file)

        try await store.loadAll()

        XCTAssertEqual(store.listAll(), [file])
    }
}
