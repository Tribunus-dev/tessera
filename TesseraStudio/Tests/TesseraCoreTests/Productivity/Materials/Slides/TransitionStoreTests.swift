import XCTest
import PostgresNIO
@testable import TesseraCore

/// `TransitionStore` (P1 1.6, gap closure). `testStoreConstruction`
/// mirrors `MasterPageStoreTests`/`SlideStoreTests`'s own scoping - this
/// test target does not stand up a live data layer by default. The
/// persistence round trip (`setSlideTransition` actually writing
/// `SlideMeta.transitionID`, not just validating and receipting) needs
/// one, so it is env-gated on `TESSERA_DB_INTEGRATION=1` matching
/// `ProductivityTaskStoreIntegrationTests`/`ContactStoreIntegrationTests`
/// - `swift test` still passes with no DB running.
final class TransitionStoreTests: XCTestCase {

    func testStoreConstruction() {
        let dataLayer = TesseraDataLayer()
        let store = TransitionStore(dataLayer: dataLayer)
        _ = store
    }

    func testUnknownTransitionIDEquatable() {
        XCTAssertEqual(TransitionStoreError.unknownTransitionID("x"), TransitionStoreError.unknownTransitionID("x"))
        XCTAssertNotEqual(TransitionStoreError.unknownTransitionID("x"), TransitionStoreError.unknownTransitionID("y"))
    }

    // MARK: - Persistence round trip (needs a live data layer)

    private static let envEnabled: Bool = {
        ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1"
    }()

    private static let host = ProcessInfo.processInfo.environment["TESSERA_PG_HOST"] ?? "localhost"
    private static let port = Int(ProcessInfo.processInfo.environment["TESSERA_PG_PORT"] ?? "5432") ?? 5432
    private static let user = ProcessInfo.processInfo.environment["TESSERA_PG_USER"] ?? "tessera"
    private static let pass = ProcessInfo.processInfo.environment["TESSERA_PG_PASSWORD"] ?? "tessera"
    private static let db = ProcessInfo.processInfo.environment["TESSERA_PG_DB"] ?? "tessera"

    private static func locateMigrationFiles() -> [(name: String, sql: String)] {
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

    private func makeDataLayer() async throws -> TesseraDataLayer {
        guard Self.envEnabled else {
            throw XCTSkip("TESSERA_DB_INTEGRATION not set; skipping DB test")
        }
        let store = TesseraDataStore(
            configuration: .init(
                host: Self.host,
                port: Self.port,
                username: Self.user,
                password: Self.pass,
                database: Self.db,
                useTLS: false
            )
        )
        try await store.connect()
        try await store.applyMigrations(Self.locateMigrationFiles())
        return TesseraDataLayer(dataStore: store, cache: TesseraCache(configuration: .init()))
    }

    /// The round trip the type doc comment promises: `setSlideTransition`
    /// writes `SlideMeta.transitionID` into the deck body (not just the
    /// in-memory return value - reloading via a fresh `SlideStore.get`
    /// proves it actually reached storage), and the receipt payload's
    /// `"persisted"` field is `true` (flipped from the pre-fix `false`).
    func testSetSlideTransitionPersistsAndReceiptSaysSo() async throws {
        let dataLayer = try await makeDataLayer()
        let slideStore = SlideStore(dataLayer: dataLayer)
        let transitionStore = TransitionStore(dataLayer: dataLayer)

        let deck = try await slideStore.upsert(SlideDeck.makeBlank(title: "Transition Round Trip"))
        let key = deck.body.rootChildren[0].uuidString

        let updated = try await transitionStore.setSlideTransition("fade", forSlideAt: 0, for: deck.id)
        XCTAssertEqual(updated.slideMeta[key]?.transitionID, "fade")

        let reloaded = try await slideStore.get(id: deck.id)
        XCTAssertEqual(reloaded?.slideMeta[key]?.transitionID, "fade")

        let receipts = try await dataLayer.receipts(forEntity: deck.id)
        let receipt = try XCTUnwrap(receipts.first { $0.receiptType == SlideReceiptType.setSlideTransition.rawValue })
        XCTAssertEqual(receipt.payload["persisted"], .bool(true))
        XCTAssertEqual(receipt.payload["transitionID"], .string("fade"))
    }

    /// Clearing (`id: nil`) writes `nil` back into `SlideMeta
    /// .transitionID` and that clear also survives a reload, not just
    /// the assignment case.
    func testSetSlideTransitionClearingPersistsNil() async throws {
        let dataLayer = try await makeDataLayer()
        let slideStore = SlideStore(dataLayer: dataLayer)
        let transitionStore = TransitionStore(dataLayer: dataLayer)

        let deck = try await slideStore.upsert(SlideDeck.makeBlank(title: "Transition Clear"))
        let key = deck.body.rootChildren[0].uuidString
        _ = try await transitionStore.setSlideTransition("wipe", forSlideAt: 0, for: deck.id)

        let cleared = try await transitionStore.setSlideTransition(nil, forSlideAt: 0, for: deck.id)
        XCTAssertNil(cleared.slideMeta[key]?.transitionID)

        let reloaded = try await slideStore.get(id: deck.id)
        XCTAssertNil(reloaded?.slideMeta[key]?.transitionID)
    }

    /// An id outside `TransitionCatalog` is rejected before anything is
    /// written - the deck body is untouched on the reload.
    func testSetSlideTransitionUnknownIDThrowsWithoutWriting() async throws {
        let dataLayer = try await makeDataLayer()
        let slideStore = SlideStore(dataLayer: dataLayer)
        let transitionStore = TransitionStore(dataLayer: dataLayer)

        let deck = try await slideStore.upsert(SlideDeck.makeBlank(title: "Transition Reject"))
        let key = deck.body.rootChildren[0].uuidString

        do {
            _ = try await transitionStore.setSlideTransition("not-a-real-id", forSlideAt: 0, for: deck.id)
            XCTFail("expected unknownTransitionID")
        } catch TransitionStoreError.unknownTransitionID(let id) {
            XCTAssertEqual(id, "not-a-real-id")
        }

        let reloaded = try await slideStore.get(id: deck.id)
        XCTAssertNil(reloaded?.slideMeta[key]?.transitionID)
    }
}
