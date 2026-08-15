import XCTest
import PostgresNIO
@testable import TesseraCore

final class DocStoreTests: XCTestCase {

    func testStoreConstruction() {
        let dataLayer = TesseraDataLayer()
        let store = DocStore(dataLayer: dataLayer)
        _ = store
    }

    func testDocJSONStringRoundTripViaStoreHelper() throws {
        let doc = Doc(title: "Hello", body: .empty, tags: ["a"])
        let s = try doc.jsonDataString()
        XCTAssertTrue(s.contains("Hello"))
        let parsed = try Doc.from(jsonDataString: s)
        XCTAssertEqual(parsed.title, "Hello")
    }

    func testInvalidBodyEquatable() {
        XCTAssertEqual(DocStoreError.invalidBody(reason: "x"), DocStoreError.invalidBody(reason: "x"))
        XCTAssertNotEqual(DocStoreError.invalidBody(reason: "x"), DocStoreError.invalidBody(reason: "y"))
    }

    func testDocNotFoundEquatable() {
        let id = UUID()
        XCTAssertEqual(DocStoreError.docNotFound(id: id), DocStoreError.docNotFound(id: id))
        XCTAssertNotEqual(DocStoreError.docNotFound(id: id), DocStoreError.docNotFound(id: UUID()))
    }

    func testListFilterApply() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let a = Doc(id: UUID(), title: "a", body: .empty, isFavorite: true, createdAt: now, updatedAt: now)
        let b = Doc(id: UUID(), title: "b", body: .empty, isArchived: true, createdAt: now, updatedAt: now)
        let c = Doc(id: UUID(), title: "c", body: .empty, isTrashed: true, createdAt: now, updatedAt: now)
        let all = [a, b, c]
        XCTAssertEqual(DocListFilter.all.apply(to: all).map { $0.title }, ["a"])
        XCTAssertEqual(DocListFilter.favorites.apply(to: all).map { $0.title }, ["a"])
        XCTAssertEqual(DocListFilter.archived.apply(to: all).map { $0.title }, ["b"])
        XCTAssertEqual(DocListFilter.trash.apply(to: all).map { $0.title }, ["c"])
    }

    func testNormalizeTagsViaDoc() {
        XCTAssertEqual(Doc.normalizeTags([" Hello ", "hello"]), ["hello"])
    }

    // MARK: - Revisions (persistence round trip, gap closure)

    /// `acceptRevision`/`rejectRevision` need a live data layer to
    /// prove the persist-then-reload half of the contract (not just
    /// the in-memory return value), so this group is env-gated on
    /// `TESSERA_DB_INTEGRATION=1` matching `SlideStoreTests`/
    /// `ProductivityTaskStoreIntegrationTests` - `swift test` still
    /// passes with no DB running.
    private static let revisionsEnvEnabled: Bool = {
        ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1"
    }()

    private static let revisionsHost = ProcessInfo.processInfo.environment["TESSERA_PG_HOST"] ?? "localhost"
    private static let revisionsPort = Int(ProcessInfo.processInfo.environment["TESSERA_PG_PORT"] ?? "5432") ?? 5432
    private static let revisionsUser = ProcessInfo.processInfo.environment["TESSERA_PG_USER"] ?? "tessera"
    private static let revisionsPass = ProcessInfo.processInfo.environment["TESSERA_PG_PASSWORD"] ?? "tessera"
    private static let revisionsDB = ProcessInfo.processInfo.environment["TESSERA_PG_DB"] ?? "tessera"

    private static func revisionsLocateMigrationFiles() -> [(name: String, sql: String)] {
        let fm = FileManager.default
        var dirs = [
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("tools/tessera/db/migrations"),
        ]
        if let workspaceRoot = ProcessInfo.processInfo.environment["TESSERA_WORKSPACE_ROOT"] {
            dirs.append(URL(fileURLWithPath: workspaceRoot).appendingPathComponent("tools/tessera/db/migrations"))
        }
        for dir in dirs where fm.fileExists(atPath: dir.path) {
            var out: [(name: String, sql: String)] = []
            if let names = try? fm.contentsOfDirectory(atPath: dir.path) {
                for name in names.sorted() where name.hasSuffix(".sql") {
                    let url = dir.appendingPathComponent(name)
                    if let sql = try? String(contentsOf: url, encoding: .utf8) {
                        out.append((name: name, sql: sql))
                    }
                }
            }
            if !out.isEmpty { return out }
        }
        return []
    }

    private func makeRevisionsDataLayer() async throws -> TesseraDataLayer {
        guard Self.revisionsEnvEnabled else {
            throw XCTSkip("TESSERA_DB_INTEGRATION not set; skipping DB test")
        }
        let store = TesseraDataStore(
            configuration: .init(
                host: Self.revisionsHost,
                port: Self.revisionsPort,
                username: Self.revisionsUser,
                password: Self.revisionsPass,
                database: Self.revisionsDB,
                useTLS: false
            )
        )
        try await store.connect()
        try await store.applyMigrations(Self.revisionsLocateMigrationFiles())
        return TesseraDataLayer(dataStore: store, cache: TesseraCache(configuration: .init()))
    }

    /// A doc whose body is a single `.trackInsertion` block, no
    /// grouping attribute - its own `id` is its revision id, matching
    /// `RevisionControllerTests.singleInsertionFixture`.
    private func makeTrackInsertionDoc() -> (doc: Doc, revisionID: UUID) {
        let insID = UUID()
        let insertion = Block(
            id: insID,
            type: .trackInsertion,
            attributes: ["author": .string("alice"), "timestamp": .string("2026-08-14T00:00:00Z")],
            content: [InlineRun(text: "inserted text")]
        )
        let ast = DocumentAST(blocks: [insID: insertion], rootChildren: [insID])
        let doc = Doc(title: "Revision Round Trip", body: ast)
        return (doc, insID)
    }

    func testAcceptRevisionConvertsTrackInsertionAndPersists() async throws {
        let dataLayer = try await makeRevisionsDataLayer()
        let store = DocStore(dataLayer: dataLayer)
        let (fixture, revisionID) = makeTrackInsertionDoc()
        let saved = try await store.upsert(fixture)

        let updated = try await store.acceptRevision(revisionID, for: saved.id)
        let block = try XCTUnwrap(updated.body.blocks[revisionID])
        XCTAssertEqual(block.type, .paragraph)
        XCTAssertEqual(block.content.first?.text, "inserted text")

        let reloaded = try await store.get(id: saved.id)
        let reloadedBlock = try XCTUnwrap(reloaded?.body.blocks[revisionID])
        XCTAssertEqual(reloadedBlock.type, .paragraph)

        let receipts = try await dataLayer.receipts(forEntity: saved.id)
        let receipt = try XCTUnwrap(receipts.first { $0.receiptType == DocReceiptType.revisionAccepted.rawValue })
        XCTAssertEqual(receipt.payload["revisionID"], .string(revisionID.uuidString))
    }

    func testRejectRevisionRemovesTrackInsertionAndPersists() async throws {
        let dataLayer = try await makeRevisionsDataLayer()
        let store = DocStore(dataLayer: dataLayer)
        let (fixture, revisionID) = makeTrackInsertionDoc()
        let saved = try await store.upsert(fixture)

        let updated = try await store.rejectRevision(revisionID, for: saved.id)
        XCTAssertNil(updated.body.blocks[revisionID])
        XCTAssertFalse(updated.body.rootChildren.contains(revisionID))

        let reloaded = try await store.get(id: saved.id)
        XCTAssertNil(reloaded?.body.blocks[revisionID])

        let receipts = try await dataLayer.receipts(forEntity: saved.id)
        let receipt = try XCTUnwrap(receipts.first { $0.receiptType == DocReceiptType.revisionRejected.rawValue })
        XCTAssertEqual(receipt.payload["revisionID"], .string(revisionID.uuidString))
    }

    /// An unknown revisionID resolves to an empty group - `acceptRevision`
    /// returns the doc unchanged, writes no new upsert, and appends no
    /// receipt (see `DocStore.acceptRevision`'s doc comment for why).
    func testAcceptUnknownRevisionIDIsGracefulNoOp() async throws {
        let dataLayer = try await makeRevisionsDataLayer()
        let store = DocStore(dataLayer: dataLayer)
        let (fixture, _) = makeTrackInsertionDoc()
        let saved = try await store.upsert(fixture)
        let receiptsBefore = try await dataLayer.receipts(forEntity: saved.id)

        let result = try await store.acceptRevision(UUID(), for: saved.id)
        XCTAssertEqual(result.body, saved.body)

        let receiptsAfter = try await dataLayer.receipts(forEntity: saved.id)
        XCTAssertEqual(receiptsAfter.count, receiptsBefore.count)
    }

    // MARK: - Search (persistence round trip, gap closure)

    /// A doc whose body is a single paragraph block with well-known text,
    /// letting find/replace tests assert directly on the block's own
    /// content (joined, since `splice` can leave a match's replacement
    /// as its own run alongside the untouched head/tail runs).
    private func makeSearchableDoc() -> (doc: Doc, blockID: UUID) {
        let blockID = UUID()
        let block = Block(id: blockID, type: .paragraph, content: [InlineRun(text: "The quick brown fox jumps over the lazy dog")])
        let ast = DocumentAST(blocks: [blockID: block], rootChildren: [blockID])
        let doc = Doc(title: "Find Replace Round Trip", body: ast)
        return (doc, blockID)
    }

    func testFindAndReplaceReplacesMatchedTextAndPersists() async throws {
        let dataLayer = try await makeRevisionsDataLayer()
        let store = DocStore(dataLayer: dataLayer)
        let (fixture, blockID) = makeSearchableDoc()
        let saved = try await store.upsert(fixture)

        let (updated, replacedCount) = try await store.findAndReplace("fox", with: "cat", for: saved.id)
        XCTAssertEqual(replacedCount, 1)
        let updatedText = try XCTUnwrap(updated.body.blocks[blockID]).content.map { $0.text }.joined()
        XCTAssertEqual(updatedText, "The quick brown cat jumps over the lazy dog")

        let reloaded = try await store.get(id: saved.id)
        let reloadedText = try XCTUnwrap(reloaded?.body.blocks[blockID]).content.map { $0.text }.joined()
        XCTAssertEqual(reloadedText, "The quick brown cat jumps over the lazy dog")
    }

    /// A query that matches nothing is a no-op through: no upsert (so
    /// the persisted doc, re-fetched independently of `findAndReplace`'s
    /// own return value, has the identical `updatedAt`) and no new
    /// receipt in the chain.
    func testFindAndReplaceNoMatchIsNoOpAndDoesNotTouchPersistedDoc() async throws {
        let dataLayer = try await makeRevisionsDataLayer()
        let store = DocStore(dataLayer: dataLayer)
        let (fixture, _) = makeSearchableDoc()
        let saved = try await store.upsert(fixture)
        let receiptsBefore = try await dataLayer.receipts(forEntity: saved.id)

        let (result, replacedCount) = try await store.findAndReplace("giraffe", with: "cat", for: saved.id)
        XCTAssertEqual(replacedCount, 0)
        XCTAssertEqual(result.body, saved.body)

        let receiptsAfter = try await dataLayer.receipts(forEntity: saved.id)
        XCTAssertEqual(receiptsAfter.count, receiptsBefore.count)

        let reloaded = try await store.get(id: saved.id)
        XCTAssertEqual(reloaded?.updatedAt, result.updatedAt)
    }

    func testFindAndReplaceEmitsFindReplaceReceiptWhenSomethingChanged() async throws {
        let dataLayer = try await makeRevisionsDataLayer()
        let store = DocStore(dataLayer: dataLayer)
        let (fixture, _) = makeSearchableDoc()
        let saved = try await store.upsert(fixture)

        _ = try await store.findAndReplace("fox", with: "cat", for: saved.id)

        let receipts = try await dataLayer.receipts(forEntity: saved.id)
        let receipt = try XCTUnwrap(receipts.first { $0.receiptType == DocReceiptType.findReplace.rawValue })
        XCTAssertEqual(receipt.payload["query"], .string("fox"))
        XCTAssertEqual(receipt.payload["replacement"], .string("cat"))
        XCTAssertEqual(receipt.payload["replacedCount"], .number(1))
        // DocumentSearchIndex's own placeholder "receiptType" field is
        // stripped before persisting - DocReceiptType.findReplace is now
        // the receipt's real receipt_type, so the literal would be a
        // redundant duplicate.
        XCTAssertNil(receipt.payload["receiptType"])
    }

}
