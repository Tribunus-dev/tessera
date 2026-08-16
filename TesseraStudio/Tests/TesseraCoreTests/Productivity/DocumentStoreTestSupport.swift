import Foundation
import CryptoKit
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/DocumentStoring.swift's
// doc comment -- "DocumentStore is the production implementation
// (Postgres-backed TesseraDataLayer + signed receipts); unit tests pass a
// thin in-memory fake" -- and DocumentStore.swift's own apply/applyBatch/
// history doc comments (doctrine rule 11's in-memory/stub seam). This fake
// reuses the exact same pure decision-makers the real store does
// (`MutationEngine`, `DocumentAST.contentHash()`, `ReceiptSigner`) so the
// mutation/receipt semantics are identical; only the persistence substrate
// (an in-memory dictionary instead of `TesseraDataLayer`/Postgres) differs.
// The real store's Postgres wiring is separately verified by
// DocumentStoreTests.swift (TESSERA_DB_INTEGRATION-gated).

/// An in-memory `DocumentStoring` conformer for ungated tests.
final class InMemoryDocumentStore: DocumentStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var documents: [UUID: DocumentAST] = [:]
    private var receiptChains: [UUID: [Receipt]] = [:]
    private var chatQueues: [UUID: ChatQueue] = [:]
    private let signer: ReceiptSigner

    var forcedError: Error?

    init(signer: ReceiptSigner = ReceiptSigner(signingKey: Curve25519.Signing.PrivateKey())) {
        self.signer = signer
    }

    func loadDocument(id: UUID) async throws -> DocumentAST {
        if let forcedError { throw forcedError }
        lock.lock()
        defer { lock.unlock() }
        return documents[id] ?? .empty
    }

    func saveDocument(id: UUID, ast: DocumentAST) async throws {
        if let forcedError { throw forcedError }
        lock.lock()
        defer { lock.unlock() }
        documents[id] = ast
    }

    func apply(mutation: Mutation, to documentID: UUID, actor: Actor) async throws -> Receipt {
        try await applyBatch(mutations: [mutation], to: documentID, actor: actor)
    }

    func applyBatch(mutations: [Mutation], to documentID: UUID, actor: Actor) async throws -> Receipt {
        if let forcedError { throw forcedError }
        guard !mutations.isEmpty else {
            throw DocumentStoreError.emptyMutationBatch
        }

        // Mirrors DocumentStore.applyBatch: apply in memory first: an
        // error here means nothing is persisted and no receipt is
        // appended (the batch-atomicity contract).
        var ast = try await loadDocument(id: documentID)
        var engine = MutationEngine()
        var preSnapshot: [UUID: Block] = [:]
        for mutation in mutations {
            let pre = try engine.apply(mutation, to: &ast)
            for (k, v) in pre { preSnapshot[k] = v }
        }

        let contentHash = try ast.contentHash()
        let priorReceiptID: UUID?
        lock.lock()
        priorReceiptID = receiptChains[documentID]?.last?.id
        lock.unlock()

        let receipt = try signer.sign(
            documentID: documentID,
            mutations: mutations,
            priorReceiptID: priorReceiptID,
            actor: actor,
            documentContentHash: contentHash,
            preMutationSnapshot: preSnapshot
        )

        lock.lock()
        documents[documentID] = ast
        receiptChains[documentID, default: []].append(receipt)
        lock.unlock()

        return receipt
    }

    func history(of documentID: UUID, limit: Int = 100) async throws -> [Receipt] {
        if let forcedError { throw forcedError }
        lock.lock()
        defer { lock.unlock() }
        return Array((receiptChains[documentID] ?? []).prefix(limit))
    }

    func loadChatQueue(documentID: UUID) async throws -> ChatQueue {
        if let forcedError { throw forcedError }
        lock.lock()
        defer { lock.unlock() }
        return chatQueues[documentID] ?? .empty
    }

    func saveChatQueue(_ queue: ChatQueue, documentID: UUID) async throws {
        if let forcedError { throw forcedError }
        lock.lock()
        defer { lock.unlock() }
        chatQueues[documentID] = queue
    }
}
