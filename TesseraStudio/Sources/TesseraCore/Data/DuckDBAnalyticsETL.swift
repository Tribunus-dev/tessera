import Foundation
import Logging
import DuckDB

// MARK: - DuckDBAnalyticsETL

/// DuckDB-backed graph analytics ETL. Reads from Postgres (source of truth)
/// and upserts computed analytics into DuckDB. The DuckDB file lives at
/// `~/Library/Application Support/Tessera/tessera_analytics.duckdb`
/// (on macOS) and is opened in-process.
///
/// DuckDB is columnar and analytical — it never replaces Postgres.
/// Analytics are recomputed on demand via ``runAnalyticsETL()``.
///
/// The DuckDB Swift SDK (`duckdb-swift`) is used directly; the
/// `duckdb` module is imported at the top of this file.
public actor DuckDBAnalyticsETL {

    // MARK: - Schema

    /// Schema for the DuckDB `graph_analytics` table.
    public struct GraphAnalyticsRow: Sendable {
        public let entityID: UUID
        public let entityType: String
        public let degree: Int
        public let avgEdgeWeight: Float
        public let lastUpdated: Date

        public init(entityID: UUID, entityType: String, degree: Int, avgEdgeWeight: Float, lastUpdated: Date) {
            self.entityID = entityID
            self.entityType = entityType
            self.degree = degree
            self.avgEdgeWeight = avgEdgeWeight
            self.lastUpdated = lastUpdated
        }
    }

    // MARK: - Paths

    private static var duckDBPath: String {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let tesseraDir = base.appendingPathComponent("Tessera", isDirectory: true)
        try? fm.createDirectory(at: tesseraDir, withIntermediateDirectories: true)
        return tesseraDir.appendingPathComponent("tessera_analytics.duckdb").path
    }

    // MARK: - State

    private var logger: Logger
    private var isOpen: Bool = false
    private var db: Database?
    private var conn: Connection?

    public init(logger: Logger = Logger(label: "tessera.data.duckdb-etl")) {
        self.logger = logger
    }

    deinit {
        Task { await self.close() }
    }

    // MARK: - Lifecycle

    /// Open the DuckDB file. Creates the schema if the file is new.
    public func open() throws {
        guard !isOpen else { return }
        let path = Self.duckDBPath
        self.db = try Database(store: .file(path: path))
        self.conn = try db?.connect()
        try createSchemaIfNeeded()
        isOpen = true
        logger.info("DuckDB opened at \(path)")
    }

    /// Close the DuckDB connection and database. Idempotent.
    public func close() {
        conn = nil
        db = nil
        isOpen = false
    }

    private func createSchemaIfNeeded() throws {
        guard let conn else { throw ETLError.closed }

        let schemaSQL = """
            CREATE SEQUENCE IF NOT EXISTS ga_seq;
            CREATE TABLE IF NOT EXISTS graph_analytics (
                entity_id UUID PRIMARY KEY,
                entity_type TEXT NOT NULL,
                degree INTEGER NOT NULL DEFAULT 0,
                avg_edge_weight REAL NOT NULL DEFAULT 1.0,
                last_updated TIMESTAMPTZ NOT NULL DEFAULT NOW()
            );
            CREATE TABLE IF NOT EXISTS token_usage (
                ts TIMESTAMPTZ,
                model TEXT,
                provider TEXT,
                prompt_tokens INTEGER,
                completion_tokens INTEGER,
                total_tokens INTEGER
            );
            CREATE TABLE IF NOT EXISTS run_stats (
                run_id TEXT PRIMARY KEY,
                model TEXT,
                status TEXT,
                started_at TIMESTAMPTZ,
                finished_at TIMESTAMPTZ,
                duration_ms INTEGER
            );
        """
        for statement in schemaSQL.components(separatedBy: ";") {
            let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            try conn.execute(trimmed)
        }
    }

    // MARK: - Analytics ETL

    /// Compute degree centrality for every entity and upsert to DuckDB.
    /// Degree = in-degree + out-degree from `entity_links`. The avg edge
    /// weight is the mean weight of all edges touching the entity.
    ///
    /// This method reads from Postgres (via `dataLayer`) and writes to
    /// DuckDB in one call. The background task caller is responsible
    /// for running this off the main thread.
    public func computeDegreeCentrality(
        from dataLayer: TesseraDataLayer
    ) async throws -> Int {
        guard isOpen, let conn else {
            throw ETLError.closed
        }

        // Walk all links from Postgres.
        let links = try await dataLayer.listAllLinks(limit: 1_000_000)

        // Aggregate degree and avg weight per entity.
        var degree: [UUID: Int] = [:]
        var weightSum: [UUID: Float] = [:]
        var weightCount: [UUID: Int] = [:]

        for link in links {
            degree[link.sourceID, default: 0] += 1
            degree[link.targetID, default: 0] += 1
            weightSum[link.sourceID, default: 0] += link.weight
            weightSum[link.targetID, default: 0] += link.weight
            weightCount[link.sourceID, default: 0] += 1
            weightCount[link.targetID, default: 0] += 1
        }

        // Fetch entity types from Postgres.
        var entityType: [UUID: String] = [:]
        for id in degree.keys {
            if let e = try? await dataLayer.getEntity(id: id) {
                entityType[id] = e.entityType
            }
        }

        let now = ISO8601DateFormatter().string(from: Date())

        var upsertCount = 0
        let upsertSQL = """
            INSERT INTO graph_analytics (entity_id, entity_type, degree, avg_edge_weight, last_updated)
            VALUES (?, ?, ?, ?, ?::timestamptz)
            ON CONFLICT (entity_id) DO UPDATE SET
                degree = EXCLUDED.degree,
                avg_edge_weight = EXCLUDED.avg_edge_weight,
                last_updated = EXCLUDED.last_updated
        """
        let prepared = try conn.prepare(upsertSQL)

        for (id, deg) in degree {
            let et = entityType[id] ?? "unknown"
            let wSum = weightSum[id] ?? 1.0
            let wCnt = weightCount[id] ?? 1
            let avgWeight = wSum / Float(wCnt)

            try prepared.execute([
                id.uuidString,
                et,
                String(deg),
                String(format: "%.6f", avgWeight),
                now
            ])
            upsertCount += 1
        }

        logger.info("Degree centrality ETL complete: \(upsertCount) entities updated")
        return upsertCount
    }

    /// Run the full analytics ETL. Currently calls ``computeDegreeCentrality``.
    /// Future analytics (PageRank, community detection) slot in here.
    public func runAnalyticsETL(from dataLayer: TesseraDataLayer) async throws -> Int {
        try open()
        return try await computeDegreeCentrality(from: dataLayer)
    }
}

// MARK: - Errors

public enum ETLError: Error, Sendable {
    case closed
}
