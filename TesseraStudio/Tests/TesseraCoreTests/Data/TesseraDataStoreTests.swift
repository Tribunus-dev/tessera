import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Data/TesseraDataStore.swift doc
// comments + docs/tessera-data-layer-design.md section 6.1 ("the data
// layer facade... every other cluster's Store tests assume this receipt/
// upsert contract holds"). This is the ungated half of doctrine rule 11:
// `TesseraDataStore` is a real `actor` wrapping `PostgresClient` with no
// in-memory mode (see this cluster's findings file, "Architectural
// notes"), but every public method has an explicit `guard let client
// else { throw TesseraDataStoreError.closed }` BEFORE touching the
// network, which is deterministically, synchronously testable without a
// live Postgres. The gated half (a live CRUD + receipt round trip) is
// TesseraDataStoreIntegrationTests.swift (TESSERA_DB_INTEGRATION-gated).

final class TesseraDataStoreTests: DoctrineTestCase {

    // MARK: - Configuration.from(connectionString:) (pure, fixtures)

    func testConfigurationFromConnectionStringParsesEveryComponent() {
        let config = TesseraDataStore.Configuration.from(
            connectionString: "postgres://myuser:mypass@myhost:5555/mydb"
        )
        XCTAssertEqual(config?.host, "myhost")
        XCTAssertEqual(config?.port, 5555)
        XCTAssertEqual(config?.username, "myuser")
        XCTAssertEqual(config?.password, "mypass")
        XCTAssertEqual(config?.database, "mydb")
    }

    func testConfigurationFromConnectionStringDefaultsMissingComponents() {
        let config = TesseraDataStore.Configuration.from(connectionString: "postgres:///mydb")
        XCTAssertEqual(config?.host, "localhost")
        XCTAssertEqual(config?.port, 5432)
        XCTAssertEqual(config?.username, "tessera")
    }

    func testConfigurationFromConnectionStringReturnsNilForMalformedURL() {
        // An empty string is not a valid URL per Foundation's URL(string:).
        XCTAssertNil(TesseraDataStore.Configuration.from(connectionString: ""))
    }

    func testConfigurationDefaultsMatchDockerComposeDefaults() {
        // docs/tessera-data-layer-design.md Appendix B: "default to
        // tessera/tessera/tessera -- matching the docker-compose defaults."
        let config = TesseraDataStore.Configuration()
        XCTAssertEqual(config.host, "localhost")
        XCTAssertEqual(config.port, 5432)
        XCTAssertEqual(config.username, "tessera")
        XCTAssertEqual(config.password, "tessera")
        XCTAssertEqual(config.database, "tessera")
    }

    // MARK: - embeddingDimension pin

    func testEmbeddingDimensionIsPinnedTo1536() {
        // docs/tessera-data-layer-design.md section 3.2: "vector(1536)."
        XCTAssertEqual(TesseraDataStore.embeddingDimension, 1536)
    }

    // MARK: - Error propagation on a never-connected store (rule: no
    // silent success from any public mutation/read when closed)

    func testGetEntityOnUnconnectedStoreThrowsClosed() async {
        let store = TesseraDataStore()
        do {
            _ = try await store.getEntity(id: UUID())
            XCTFail("expected .closed")
        } catch TesseraDataStoreError.closed {
            // expected
        } catch {
            XCTFail("expected TesseraDataStoreError.closed, got \(error)")
        }
    }

    func testUpsertEntityOnUnconnectedStoreThrowsClosed() async {
        let store = TesseraDataStore()
        do {
            _ = try await store.upsertEntity(GraphEntityUpsert(entityType: "note", label: "x"))
            XCTFail("expected .closed")
        } catch TesseraDataStoreError.closed {
            // expected
        } catch {
            XCTFail("expected TesseraDataStoreError.closed, got \(error)")
        }
    }

    func testDeleteEntityOnUnconnectedStoreThrowsClosed() async {
        let store = TesseraDataStore()
        do {
            _ = try await store.deleteEntity(id: UUID())
            XCTFail("expected .closed")
        } catch TesseraDataStoreError.closed {
            // expected
        } catch {
            XCTFail("expected TesseraDataStoreError.closed, got \(error)")
        }
    }

    func testAppendReceiptOnUnconnectedStoreThrowsClosed() async {
        let store = TesseraDataStore()
        do {
            _ = try await store.appendReceipt(entityID: UUID(), receiptType: "note_upsert", payload: [:])
            XCTFail("expected .closed")
        } catch TesseraDataStoreError.closed {
            // expected
        } catch {
            XCTFail("expected TesseraDataStoreError.closed, got \(error)")
        }
    }

    // MARK: - setConfiguration is only safe before connect()

    func testSetConfigurationSucceedsBeforeConnect() async throws {
        let store = TesseraDataStore()
        try await store.setConfiguration(.init(host: "otherhost"))
        // No throw is the assertion; there is no getter to read the
        // configuration back (by design -- see the doc comment), so this
        // just pins that the guard does not misfire on a fresh store.
    }

    // MARK: - TesseraDataStoreError equality (value-type sanity; the
    // custom == is hand-written, not synthesized, so it needs its own test)

    func testErrorEqualityMatchesSameCase() {
        let id = UUID()
        XCTAssertEqual(TesseraDataStoreError.closed, TesseraDataStoreError.closed)
        XCTAssertEqual(TesseraDataStoreError.notFound(id: id), TesseraDataStoreError.notFound(id: id))
        XCTAssertEqual(
            TesseraDataStoreError.invalidEmbedding(expected: 1536, got: 512),
            TesseraDataStoreError.invalidEmbedding(expected: 1536, got: 512)
        )
    }

    func testErrorEqualityDistinguishesDifferentCases() {
        XCTAssertNotEqual(TesseraDataStoreError.closed, TesseraDataStoreError.connectionFailed(reason: "x"))
    }

    func testErrorEqualityDistinguishesDifferentPayloads() {
        XCTAssertNotEqual(
            TesseraDataStoreError.queryFailed(reason: "a"),
            TesseraDataStoreError.queryFailed(reason: "b")
        )
    }
}
