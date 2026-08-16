import Foundation

// MARK: - DocumentStoring

/// The minimum seam the Writer surface's agent tools / view-models
/// depend on. ``DocumentStore`` is the production implementation
/// (Postgres-backed ``TesseraDataLayer`` + signed receipts); unit
/// tests pass a thin in-memory fake (``InMemoryDocumentStore`` in
/// the test target). Mirrors ``ReminderStoring``/``CalendarStoring``'s
/// role for their materials: the protocol is the only public
/// contract callers depend on, the production type is the
/// implementation detail.
///
/// This is the full public method surface of ``DocumentStore`` --
/// load/save the AST, apply mutations (single + batch), read the
/// receipt chain, and the chat queue read/write pair. No raw
/// `TesseraDataLayer` API leaks through this protocol.
public protocol DocumentStoring: Sendable {
    func loadDocument(id: UUID) async throws -> DocumentAST
    func saveDocument(id: UUID, ast: DocumentAST) async throws
    func apply(mutation: Mutation, to documentID: UUID, actor: Actor) async throws -> Receipt
    func applyBatch(mutations: [Mutation], to documentID: UUID, actor: Actor) async throws -> Receipt
    func history(of documentID: UUID, limit: Int) async throws -> [Receipt]
    func loadChatQueue(documentID: UUID) async throws -> ChatQueue
    func saveChatQueue(_ queue: ChatQueue, documentID: UUID) async throws
}

// Default-argument convenience so call sites don't repeat the
// boring `limit: 100` (matches DocumentStore's own default).
extension DocumentStoring {
    public func history(of documentID: UUID) async throws -> [Receipt] {
        try await history(of: documentID, limit: 100)
    }
}

// ``DocumentStore`` already satisfies ``DocumentStoring``
// member-for-member (its defaulted `limit:` parameter covers the
// protocol's non-defaulted shape), so the conformance is a
// declaration, not a wrapper:
extension DocumentStore: DocumentStoring {}
