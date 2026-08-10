import Foundation

/// Postgres-backed ``StateGraphCheckpointer``. Stores each checkpoint as a row
/// in the `graph_checkpoints` table (migration `0014_graph_checkpoints.sql`),
/// so a graph run (chat thread or workflow) is durable across launches and
/// can be resumed, branched, or inspected.
///
/// The state column is JSONB holding the serialized `GraphState`
/// (`[String: JSONValue]`); `JSONValue` is `Codable`, so a dictionary encode
/// round-trips through Foundation's `JSONEncoder`.
public actor PostgresCheckpointer: StateGraphCheckpointer {
    private let dataLayer: TesseraDataLayer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(dataLayer: TesseraDataLayer) {
        self.dataLayer = dataLayer
    }

    public func save(_ threadId: String, step: Int, nodeId: String, state: GraphState) async throws -> Checkpoint {
        let cp = Checkpoint(threadId: threadId, step: step, nodeId: nodeId, state: state)
        let stateJSON = try encodeState(state)
        try await dataLayer.saveGraphCheckpoint(id: cp.id, threadId: threadId, step: step, nodeId: nodeId, stateJSON: stateJSON)
        return cp
    }

    public func load(checkpointId: UUID) async throws -> Checkpoint? {
        guard let row = try await dataLayer.loadGraphCheckpoint(id: checkpointId) else { return nil }
        return Checkpoint(
            id: checkpointId,
            threadId: row.threadId,
            step: row.step,
            nodeId: row.nodeId,
            state: try decodeState(row.stateJSON),
            createdAt: row.createdAt
        )
    }

    public func list(threadId: String) async throws -> [Checkpoint] {
        let rows = try await dataLayer.listGraphCheckpoints(threadId: threadId)
        return try rows.map { row in
            Checkpoint(
                id: row.id,
                threadId: threadId,
                step: row.step,
                nodeId: row.nodeId,
                state: try decodeState(row.stateJSON),
                createdAt: row.createdAt
            )
        }
    }

    public func latest(threadId: String) async throws -> Checkpoint? {
        try await list(threadId: threadId).last
    }

    public func purge(threadId: String) async throws {
        try await dataLayer.purgeGraphCheckpoints(threadId: threadId)
    }

    // MARK: - GraphState codec

    private func encodeState(_ state: GraphState) throws -> String {
        let data = try encoder.encode(state)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func decodeState(_ json: String) throws -> GraphState {
        guard let data = json.data(using: .utf8) else { return [:] }
        return try decoder.decode(GraphState.self, from: data)
    }
}
