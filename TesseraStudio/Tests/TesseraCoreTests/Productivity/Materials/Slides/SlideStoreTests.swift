import XCTest
import PostgresNIO
@testable import TesseraCore

final class SlideStoreTests: XCTestCase {

    func testStoreConstruction() {
        let dataLayer = TesseraDataLayer()
        let store = SlideStore(dataLayer: dataLayer)
        _ = store
    }

    func testJSONStringRoundTripViaDeckHelper() throws {
        let deck = SlideDeck(title: "Hello", body: .empty, tags: ["a"])
        let s = try deck.jsonDataString()
        XCTAssertTrue(s.contains("Hello"))
        let parsed = try SlideDeck.from(jsonDataString: s)
        XCTAssertEqual(parsed.title, "Hello")
    }

    func testInvalidBodyEquatable() {
        XCTAssertEqual(SlideStoreError.invalidBody(reason: "x"), SlideStoreError.invalidBody(reason: "x"))
        XCTAssertNotEqual(SlideStoreError.invalidBody(reason: "x"), SlideStoreError.invalidBody(reason: "y"))
    }

    func testDeckNotFoundEquatable() {
        let id = UUID()
        XCTAssertEqual(SlideStoreError.deckNotFound(id: id), SlideStoreError.deckNotFound(id: id))
        XCTAssertNotEqual(SlideStoreError.deckNotFound(id: id), SlideStoreError.deckNotFound(id: UUID()))
    }

    func testSlideOutOfBoundsEquatable() {
        XCTAssertEqual(SlideStoreError.slideOutOfBounds(index: 3, count: 2), SlideStoreError.slideOutOfBounds(index: 3, count: 2))
        XCTAssertNotEqual(SlideStoreError.slideOutOfBounds(index: 3, count: 2), SlideStoreError.slideOutOfBounds(index: 4, count: 2))
    }

    func testListFilterApply() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let a = SlideDeck(id: UUID(), title: "a", body: .empty, isFavorite: true, createdAt: now, updatedAt: now)
        let b = SlideDeck(id: UUID(), title: "b", body: .empty, isArchived: true, createdAt: now, updatedAt: now)
        let c = SlideDeck(id: UUID(), title: "c", body: .empty, isTrashed: true, createdAt: now, updatedAt: now)
        let all = [a, b, c]
        XCTAssertEqual(SlideListFilter.all.apply(to: all).map { $0.title }, ["a"])
        XCTAssertEqual(SlideListFilter.favorites.apply(to: all).map { $0.title }, ["a"])
        XCTAssertEqual(SlideListFilter.archived.apply(to: all).map { $0.title }, ["b"])
        XCTAssertEqual(SlideListFilter.trash.apply(to: all).map { $0.title }, ["c"])
    }

    func testNormalizeTagsViaDeck() {
        XCTAssertEqual(SlideDeck.normalizeTags([" Hello ", "hello"]), ["hello"])
    }

    func testMakeBlankHasOneSlideWithDefaultLayout() {
        let deck = SlideDeck.makeBlank(title: "T")
        XCTAssertEqual(deck.slideCount, 1)
        XCTAssertEqual(deck.slides[0].layout, .title)
    }

    func testInsertingSlideClampBeyondCount() {
        let deck = SlideDeck.makeBlank(title: "t")
        let next = deck.insertingSlide(at: 99, layout: .blank)
        XCTAssertEqual(next.slideCount, 2)
    }

    func testInsertingSlideNegativeIndexClampsToZero() {
        let deck = SlideDeck.makeBlank(title: "t")
        let next = deck.insertingSlide(at: -5, layout: .blank)
        XCTAssertEqual(next.slideCount, 2)
        XCTAssertEqual(next.body.rootChildren.count, 2)
    }

    func testSlideDeckRowHasSlideCount() {
        let deck = SlideDeck.makeBlank(title: "Hi")
        let row = SlideDeckRow(deck: deck)
        XCTAssertEqual(row.slideCount, 1)
        XCTAssertEqual(row.title, "Hi")
        XCTAssertFalse(row.isFavorite)
    }

    func testSlideDeckRowReadingRelativeTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(SlideDeckRow.relativeTimeString(for: now, now: now), "just now")
        XCTAssertEqual(
            SlideDeckRow.relativeTimeString(for: now.addingTimeInterval(-120), now: now),
            "2 min ago"
        )
    }

    func testSlideMetaCodable() throws {
        let meta = SlideMeta(layout: .image, notes: "hello notes")
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(SlideMeta.self, from: data)
        XCTAssertEqual(decoded, meta)
    }

    func testSlideMetaDefault() {
        XCTAssertEqual(SlideMeta.default.layout, .titleAndContent)
        XCTAssertEqual(SlideMeta.default.notes, "")
    }

    // MARK: - Comments (persistence round trip, gap closure)

    /// `SlideStore.addComment` is the only write path that actually
    /// attaches a `CommentThread` (`SlideDeck.addingCommentThread` and
    /// `.effectiveCommentThreads` were added centrally for it to use).
    /// The persistence round trip needs a live data layer, so this
    /// group is env-gated on `TESSERA_DB_INTEGRATION=1` matching
    /// `TransitionStoreTests`/`ProductivityTaskStoreIntegrationTests` -
    /// `swift test` still passes with no DB running.
    private static let commentsEnvEnabled: Bool = {
        ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1"
    }()

    private static let commentsHost = ProcessInfo.processInfo.environment["TESSERA_PG_HOST"] ?? "localhost"
    private static let commentsPort = Int(ProcessInfo.processInfo.environment["TESSERA_PG_PORT"] ?? "5432") ?? 5432
    private static let commentsUser = ProcessInfo.processInfo.environment["TESSERA_PG_USER"] ?? "tessera"
    private static let commentsPass = ProcessInfo.processInfo.environment["TESSERA_PG_PASSWORD"] ?? "tessera"
    private static let commentsDB = ProcessInfo.processInfo.environment["TESSERA_PG_DB"] ?? "tessera"

    private static func commentsLocateMigrationFiles() -> [(name: String, sql: String)] {
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

    private func makeCommentsDataLayer() async throws -> TesseraDataLayer {
        guard Self.commentsEnvEnabled else {
            throw XCTSkip("TESSERA_DB_INTEGRATION not set; skipping DB test")
        }
        let store = TesseraDataStore(
            configuration: .init(
                host: Self.commentsHost,
                port: Self.commentsPort,
                username: Self.commentsUser,
                password: Self.commentsPass,
                database: Self.commentsDB,
                useTLS: false
            )
        )
        try await store.connect()
        try await store.applyMigrations(Self.commentsLocateMigrationFiles())
        return TesseraDataLayer(dataStore: store, cache: TesseraCache(configuration: .init()))
    }

    /// `addComment` persists the thread into the deck body (not just
    /// the in-memory return value - reloading via a fresh
    /// `SlideStore.get` proves it actually reached storage), and emits
    /// `SlideReceiptType.addComment`.
    func testAddCommentPersistsThreadAndEmitsReceipt() async throws {
        let dataLayer = try await makeCommentsDataLayer()
        let slideStore = SlideStore(dataLayer: dataLayer)

        let deck = try await slideStore.upsert(SlideDeck.makeBlank(title: "Comment Round Trip"))
        let slideID = deck.body.rootChildren[0]
        let anchor = CommentAnchor.slide(slideID)

        let updated = try await slideStore.addComment(
            anchor: anchor, author: "author-guid-1", text: "Looks great!", for: deck.id
        )
        let thread = try XCTUnwrap(updated.effectiveCommentThreads.first)
        XCTAssertEqual(thread.anchor, anchor)
        XCTAssertEqual(thread.author, "author-guid-1")
        XCTAssertEqual(thread.messages.first?.text, "Looks great!")

        let reloaded = try await slideStore.get(id: deck.id)
        let reloadedThread = try XCTUnwrap(reloaded?.effectiveCommentThreads.first { $0.id == thread.id })
        XCTAssertEqual(reloadedThread.anchor, anchor)
        XCTAssertEqual(reloadedThread.author, "author-guid-1")
        XCTAssertEqual(reloadedThread.messages.first?.text, "Looks great!")

        let receipts = try await dataLayer.receipts(forEntity: deck.id)
        let receipt = try XCTUnwrap(receipts.first { $0.receiptType == SlideReceiptType.addComment.rawValue })
        XCTAssertEqual(receipt.payload["commentID"], .string(thread.id.uuidString))
    }

    /// A `.slide` anchor naming a slide id that isn't in the deck is
    /// rejected before anything is written - a slide id is a closed,
    /// checkable set (unlike a Sheet's arbitrary cell coordinate), so
    /// this is validated rather than silently persisted.
    func testAddCommentToUnknownSlideThrowsWithoutWriting() async throws {
        let dataLayer = try await makeCommentsDataLayer()
        let slideStore = SlideStore(dataLayer: dataLayer)

        let deck = try await slideStore.upsert(SlideDeck.makeBlank(title: "Comment Reject"))
        let bogusSlideID = UUID()

        do {
            _ = try await slideStore.addComment(
                anchor: .slide(bogusSlideID), author: "author-guid-2", text: "orphaned", for: deck.id
            )
            XCTFail("expected slideNotFound")
        } catch SlideStoreError.slideNotFound(let id) {
            XCTAssertEqual(id, bogusSlideID)
        }

        let reloaded = try await slideStore.get(id: deck.id)
        XCTAssertEqual(reloaded?.effectiveCommentThreads ?? [], [])
    }
}
