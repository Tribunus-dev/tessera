import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Data/TesseraCache.swift doc
// comments ("all key names are automatically prefixed with
// tessera:<namespace>:") + docs/tessera-data-layer-design.md section 5
// (cache key patterns table, default TTLs). Ungated half of doctrine
// rule 11: every public method throws `TesseraCacheError.closed`
// synchronously when the pool was never connected (same pattern as
// `TesseraDataStore` -- see TesseraDataStoreTests.swift's header). The
// gated half (CacheTTLTests-equivalent real Valkey round trip) is out of
// scope for this pass -- see this cluster's findings file.

final class TesseraCacheTests: DoctrineTestCase {

    private func makeCache() -> TesseraCache {
        TesseraCache()
    }

    func testConfigurationDefaults() {
        let config = TesseraCache.Configuration()
        XCTAssertEqual(config.host, "localhost")
        XCTAssertEqual(config.port, 6379)
        XCTAssertEqual(config.databaseNumber, 0)
        XCTAssertEqual(config.namespace, "default")
    }

    // MARK: - Error propagation on a never-connected cache

    func testGetOnUnconnectedCacheThrowsClosed() async {
        let cache = makeCache()
        do {
            _ = try await cache.get("some-key")
            XCTFail("expected .closed")
        } catch TesseraCacheError.closed {
            // expected
        } catch {
            XCTFail("expected TesseraCacheError.closed, got \(error)")
        }
    }

    func testSetOnUnconnectedCacheThrowsClosed() async {
        let cache = makeCache()
        do {
            try await cache.set("some-key", value: "v", ttlSeconds: 60)
            XCTFail("expected .closed")
        } catch TesseraCacheError.closed {
            // expected
        } catch {
            XCTFail("expected TesseraCacheError.closed, got \(error)")
        }
    }

    func testDelOnUnconnectedCacheThrowsClosed() async {
        let cache = makeCache()
        do {
            _ = try await cache.del(["some-key"])
            XCTFail("expected .closed")
        } catch TesseraCacheError.closed {
            // expected
        } catch {
            XCTFail("expected TesseraCacheError.closed, got \(error)")
        }
    }

    func testZaddOnUnconnectedCacheThrowsClosed() async {
        let cache = makeCache()
        do {
            _ = try await cache.zadd("some-zset", members: [(member: "m", score: 1.0)])
            XCTFail("expected .closed")
        } catch TesseraCacheError.closed {
            // expected
        } catch {
            XCTFail("expected TesseraCacheError.closed, got \(error)")
        }
    }

    // MARK: - TesseraCacheError equality (hand-written ==, needs its own test)

    func testErrorEqualityMatchesSameCase() {
        XCTAssertEqual(TesseraCacheError.closed, TesseraCacheError.closed)
        XCTAssertEqual(TesseraCacheError.commandFailed("x"), TesseraCacheError.commandFailed("x"))
        XCTAssertEqual(
            TesseraCacheError.typeMismatch(expected: "string", got: "list"),
            TesseraCacheError.typeMismatch(expected: "string", got: "list")
        )
    }

    func testErrorEqualityDistinguishesDifferentCases() {
        XCTAssertNotEqual(TesseraCacheError.closed, TesseraCacheError.connectionFailed)
    }

    func testErrorEqualityDistinguishesDifferentPayloads() {
        XCTAssertNotEqual(TesseraCacheError.commandFailed("a"), TesseraCacheError.commandFailed("b"))
    }
}
