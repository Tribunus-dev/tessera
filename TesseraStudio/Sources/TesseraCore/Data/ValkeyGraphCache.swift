import Foundation

// MARK: - ValkeyGraphCache

/// Graph-adjacent Valkey patterns. Canonical graph lives in
/// Postgres; Valkey is a read-through hot cache for frequently-
/// accessed adjacency sets.
///
/// **Key format**
/// `tessera:{ns}:neighbors:{entityID}:{depth}` -> sorted set
/// of neighbour UUID strings by recency score (Unix timestamp
/// at insert time).
///
/// **Run locks**
/// `tessera:{ns}:run:{runId}` -> `"acquired"` (string, TTL = ttlSeconds).
/// `SET NX` for mutual exclusion.
public protocol ValkeyGraphCache {
    /// Get cached neighbours at depth N. Returns nil on cache miss.
    func neighbors(of entityID: UUID, depth: Int) async throws -> [UUID]?

    /// Invalidate cache for entity (after link/unlink).
    func invalidateNeighbors(of entityID: UUID) async throws

    /// Recent entity IDs sorted by recency score (for dashboard).
    func recentEntities(limit: Int) async throws -> [UUID]

    /// Acquire a run lock. Returns true if acquired; false if
    /// the lock is already held by another owner.
    func acquireRunLock(runId: UUID, ttlSeconds: Int) async throws -> Bool

    /// Release a run lock.
    func releaseRunLock(runId: UUID) async throws
}

// MARK: - ValkeyGraphCache on TesseraCache

/// ``ValkeyGraphCache`` implementation backed by ``TesseraCache``.
extension TesseraCache: ValkeyGraphCache {

    /// Key for the neighbour set of entity at a given depth.
    private func neighborKey(entityID: UUID, depth: Int) -> String {
        key("neighbors", entityID.uuidString, String(depth))
    }

    /// Key for the recent-entities sorted set.
    private var recentEntitiesKey: String {
        key("graph", "recent_entities")
    }

    /// Key for a run lock.
    private func runLockKey(runId: UUID) -> String {
        key("run", runId.uuidString)
    }

    /// Get cached neighbours at depth N. Returns nil when the
    /// key does not exist (cache miss).
    public func neighbors(of entityID: UUID, depth: Int) async throws -> [UUID]? {
        let k = neighborKey(entityID: entityID, depth: depth)
        let members = try await zrangebyscore(k, min: .zero, max: .infinity, withScores: false)
        guard !members.isEmpty else {
            // Empty set vs no-key: zrangebyscore returns [] for both.
            // Distinguish by checking TTL — no-key has TTL -2.
            let t = try? await ttl(k)
            if t == -2 {
                return nil  // key does not exist
            }
            return []
        }
        return members.compactMap { UUID(uuidString: $0.member) }
    }

    /// Invalidate all cached depths for one entity.
    /// Calling code should invalidate source AND target after
    /// a link/unlink since both adjacency sets change.
    public func invalidateNeighbors(of entityID: UUID) async throws {
        // We invalidate all reasonable depths (0..=5) since we don't
        // know which depths are cached.
        let keys = (0...5).map { neighborKey(entityID: entityID, depth: $0) }
        // Filter to only keys that exist (TTL != -2).
        var toDelete: [String] = []
        for k in keys {
            let t = try? await ttl(k)
            if t != -2 {
                toDelete.append(k)
            }
        }
        if !toDelete.isEmpty {
            _ = try await del(toDelete)
        }
    }

    /// Recent entity IDs sorted by recency score (Unix timestamp).
    /// Used by the dashboard to show recently-touched entities.
    public func recentEntities(limit: Int) async throws -> [UUID] {
        let members = try await zrangebyscore(
            recentEntitiesKey,
            min: .zero,
            max: .infinity,
            withScores: false,
            limit: limit
        )
        return members.compactMap { UUID(uuidString: $0.member) }
    }

    /// Record an entity touch in the recency set. Call this after
    /// any entity mutation so the dashboard can surface the entity.
    /// Score = current Unix timestamp.
    public func touch(entityID: UUID) async throws {
        let now = Date().timeIntervalSince1970
        _ = try await zadd(recentEntitiesKey, members: [(entityID.uuidString, now)])
    }

    /// Acquire a run lock. Uses `SET NX EX` for mutual exclusion.
    /// Returns true if acquired; false if the key already existed.
    public func acquireRunLock(runId: UUID, ttlSeconds: Int) async throws -> Bool {
        let k = runLockKey(runId: runId)
        return try await setIfAbsent(k, value: "acquired", ttlSeconds: ttlSeconds)
    }

    /// Release a run lock. Best-effort delete.
    public func releaseRunLock(runId: UUID) async throws {
        let k = runLockKey(runId: runId)
        _ = try await del([k])
    }
}
