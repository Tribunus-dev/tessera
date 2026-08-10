import Foundation

/// One resumable state snapshot in a graph run. The `(threadId, step, nodeId,
/// state)` tuple is the LangGraph checkpoint identity. Port of the Linux
/// `Checkpoint` struct (StateGraph.h:47-54), upgraded with real UUID/Date
/// and Codable so it serializes through JSONValue/Postgres cleanly.
public struct Checkpoint: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let threadId: String
    public let step: Int
    public let nodeId: String
    public let state: GraphState
    public let createdAt: Date

    public init(id: UUID = UUID(), threadId: String, step: Int, nodeId: String, state: GraphState, createdAt: Date = Date()) {
        self.id = id
        self.threadId = threadId
        self.step = step
        self.nodeId = nodeId
        self.state = state
        self.createdAt = createdAt
    }
}

/// Durably stores checkpoints so a graph run can be resumed, branched, or
/// inspected after relaunch. Port of the Linux `PostgresCheckpointer`
/// (StateGraph.h:60-72), as a protocol so the in-memory test checkpointer
/// and the Postgres-backed production checkpointer share one shape.
///
/// The Linux checkpointer is plumbed but inert (its `DataLayer*` is always
/// null because `workflow_surface_new()` takes no DataLayer). This protocol
/// is the seam the Swift port fills with a real Postgres-backed impl in
/// Part D; `MemoryCheckpointer` below serves the tests and the no-Postgres
/// fallback.
public protocol StateGraphCheckpointer: Sendable {
    func save(_ threadId: String, step: Int, nodeId: String, state: GraphState) async throws -> Checkpoint
    func load(checkpointId: UUID) async throws -> Checkpoint?
    func list(threadId: String) async throws -> [Checkpoint]
    func latest(threadId: String) async throws -> Checkpoint?
    func purge(threadId: String) async throws
}

/// In-memory checkpointer. Used by tests and as the no-Postgres fallback.
/// Holds the latest checkpoint per step per thread; `list` returns them in
/// step order.
public actor MemoryCheckpointer: StateGraphCheckpointer {
    private var byThread: [String: [Int: Checkpoint]] = [:]

    public init() {}

    public func save(_ threadId: String, step: Int, nodeId: String, state: GraphState) async -> Checkpoint {
        let cp = Checkpoint(threadId: threadId, step: step, nodeId: nodeId, state: state)
        byThread[threadId, default: [:]][step] = cp
        return cp
    }

    public func load(checkpointId: UUID) async -> Checkpoint? {
        for (_, steps) in byThread {
            if let cp = steps.values.first(where: { $0.id == checkpointId }) {
                return cp
            }
        }
        return nil
    }

    public func list(threadId: String) async -> [Checkpoint] {
        let steps = byThread[threadId] ?? [:]
        return steps.values.sorted { $0.step < $1.step }
    }

    public func latest(threadId: String) async -> Checkpoint? {
        try? await list(threadId: threadId).last
    }

    public func purge(threadId: String) async {
        byThread[threadId] = nil
    }
}
