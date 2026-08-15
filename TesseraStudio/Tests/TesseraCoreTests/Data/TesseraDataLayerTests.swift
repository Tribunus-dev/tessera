import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Data/TesseraDataLayer.swift doc
// comments (StartOutcome's four cases, cacheKey's "tessera:<ns>:" prefix
// scheme) + docs/tessera-data-layer-design.md section 5 ("Key prefix is
// tessera:<namespace>:... automatically added by every method on
// TesseraCache, so callers can't accidentally bypass it"). Ungated:
// `cacheKey(_:)` only reads `TesseraCache.configuration.namespace` (no
// pool access), so it works even on a never-started layer; every other
// pass-through method propagates the same `.closed`/`.closed` errors as
// the underlying `TesseraDataStore`/`TesseraCache` (see
// TesseraDataStoreTests.swift / TesseraCacheTests.swift for that
// mechanism in depth -- this file only spot-checks that the facade
// forwards rather than swallows).

final class TesseraDataLayerTests: DoctrineTestCase {

    // MARK: - StartOutcome equality (hand-written associated-value cases)

    func testStartOutcomeReadyEqualsReady() {
        XCTAssertEqual(TesseraDataLayer.StartOutcome.ready, .ready)
    }

    func testStartOutcomeCacheDegradedEqualityIsByReason() {
        XCTAssertEqual(
            TesseraDataLayer.StartOutcome.cacheDegraded(reason: "x"),
            TesseraDataLayer.StartOutcome.cacheDegraded(reason: "x")
        )
        XCTAssertNotEqual(
            TesseraDataLayer.StartOutcome.cacheDegraded(reason: "x"),
            TesseraDataLayer.StartOutcome.cacheDegraded(reason: "y")
        )
    }

    func testStartOutcomeDistinguishesCacheDegradedFromDataStoreDegraded() {
        XCTAssertNotEqual(
            TesseraDataLayer.StartOutcome.cacheDegraded(reason: "x"),
            TesseraDataLayer.StartOutcome.dataStoreDegraded(reason: "x")
        )
    }

    // MARK: - cacheKey (pure: reads the namespace, no pool access)

    func testCacheKeyPrefixesWithTesseraAndTheDefaultNamespace() async {
        let layer = TesseraDataLayer()
        let key = await layer.cacheKey("scratchpad", "agent-1", "task-a")
        XCTAssertEqual(key, "tessera:default:scratchpad:agent-1:task-a")
    }

    func testCacheKeyUsesTheConfiguredNamespace() async {
        var config = TesseraDataLayer.Configuration()
        config.cache.namespace = "staging"
        let layer = TesseraDataLayer(configuration: config)
        let key = await layer.cacheKey("session", "user-1")
        XCTAssertEqual(key, "tessera:staging:session:user-1")
    }

    // MARK: - HybridSearchWeights defaults (rule 5 trap: the calibrated
    // weights are pinned per docs/tessera-data-layer-design.md section 4.2)

    func testHybridSearchWeightsDefaultMatchesTheCalibratedValues() {
        let weights = TesseraDataLayer.HybridSearchWeights.default
        XCTAssertEqual(weights.graph, 0.2, accuracy: 0.0001)
        XCTAssertEqual(weights.vector, 0.5, accuracy: 0.0001)
        XCTAssertEqual(weights.keyword, 0.3, accuracy: 0.0001)
    }

    // MARK: - Error propagation on a never-started facade

    func testGetEntityOnNeverStartedFacadeThrowsRatherThanSucceeding() async {
        let layer = TesseraDataLayer()
        do {
            _ = try await layer.getEntity(id: UUID())
            XCTFail("expected the underlying store's closed error to propagate")
        } catch {
            XCTAssertTrue(error is TesseraDataStoreError, "expected TesseraDataStoreError, got \(error)")
        }
    }

    func testCacheGetOnNeverStartedFacadeThrowsRatherThanSucceeding() async {
        let layer = TesseraDataLayer()
        do {
            _ = try await layer.cacheGet("some-key")
            XCTFail("expected the underlying cache's closed error to propagate")
        } catch {
            XCTAssertTrue(error is TesseraCacheError, "expected TesseraCacheError, got \(error)")
        }
    }

    // MARK: - isReady reflects start() state

    func testIsReadyIsFalseBeforeStart() async {
        let layer = TesseraDataLayer()
        let ready = await layer.isReady
        XCTAssertFalse(ready)
    }
}
