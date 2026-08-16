import Foundation
import CryptoKit
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Receipts/
// ReceiptExportServicing.swift's doc comment + ReceiptExportService.export's
// own doc comments -- "requires a userConfirmed: true flag", "consults the
// configured EgressPolicy before building the artifact", "logged as a
// chain entry" (doctrine rule 11's in-memory/stub seam). This fake is an
// independent reimplementation of `export`'s GATING/WIRING contract only
// (userConfirmed -> noReceipts -> egress policy -> build -> log-one-
// receipt) against an injected `DocumentStoring`, not a wrapper around the
// real `ReceiptExportService` -- the real service's format-specific build
// helpers (buildMarkdownSummary/buildSignedJSONBundle/buildC2PADocument)
// are pure and already exercised directly and ungated by
// ReceiptExportServiceTests.swift, so this fake stands in a minimal
// payload rather than duplicating that formatting logic.

/// An in-memory `ReceiptExportServicing` conformer for ungated tests.
final class InMemoryReceiptExportService: ReceiptExportServicing, @unchecked Sendable {
    private let documentStore: DocumentStoring
    private let signer: ReceiptSigner
    private let egressPolicy: any EgressPolicy
    private let lock = NSLock()
    private var exportedReceipts: [UUID: [Receipt]] = [:]

    var forcedError: Error?

    init(
        documentStore: DocumentStoring,
        signer: ReceiptSigner = ReceiptSigner(signingKey: Curve25519.Signing.PrivateKey()),
        egressPolicy: any EgressPolicy = AllowAllEgressPolicy()
    ) {
        self.documentStore = documentStore
        self.signer = signer
        self.egressPolicy = egressPolicy
    }

    func export(
        documentID: UUID,
        format: ReceiptExportFormat,
        documentTitle: String,
        userID: UserID,
        userConfirmed: Bool
    ) async throws -> ExportArtifact {
        if let forcedError { throw forcedError }

        guard userConfirmed else {
            throw ExportError.userDenied
        }

        let chain = try await documentStore.history(of: documentID, limit: 1000)
        guard !chain.isEmpty else {
            throw ExportError.noReceipts
        }

        guard egressPolicy.allowsExport(documentID: documentID, format: format) else {
            throw ExportError.buildFailed("egress policy denied the export")
        }

        guard let privateKey = signer.injectedSigningKey else {
            throw ExportError.buildFailed("signing key unavailable")
        }

        let filename = ReceiptExportService.makeFilename(documentTitle: documentTitle, format: format)
        let summary = "Exported \(chain.count) receipt\(chain.count == 1 ? "" : "s") as \(format.displayName)"
        let priorReceiptID = chain.last?.id

        var receipt = Receipt(
            documentID: documentID,
            actor: .user(userID),
            mutations: [],
            priorReceiptID: priorReceiptID,
            signature: Data(),
            summary: summary
        )
        let canonical = try receipt.canonicalBytes()
        let signature = try privateKey.signature(for: canonical)
        receipt = Receipt(
            id: receipt.id,
            documentID: receipt.documentID,
            actor: receipt.actor,
            mutations: receipt.mutations,
            timestamp: receipt.timestamp,
            priorReceiptID: receipt.priorReceiptID,
            signature: signature,
            c2paManifest: receipt.c2paManifest,
            summary: receipt.summary,
            preMutationSnapshot: receipt.preMutationSnapshot,
            voidedBy: receipt.voidedBy
        )

        // Logged into this fake's own dictionary, not appended onto
        // `documentStore`'s chain: DocumentStoring has no "append a
        // receipt-only entry" method (by design -- receipts without
        // mutations are the export service's own concern, per the real
        // ReceiptExportService going straight to dataLayer.appendReceiptToChain
        // rather than through DocumentStore.apply). loggedExports(for:)
        // below is the assertion surface in place of that shared chain.
        lock.lock()
        exportedReceipts[documentID, default: []].append(receipt)
        lock.unlock()

        return ExportArtifact(
            documentID: documentID,
            format: format,
            filename: filename,
            payload: Data("fake-export-payload".utf8),
            receiptID: receipt.id
        )
    }

    /// Test-only accessor: every export receipt logged for `documentID`,
    /// in append order.
    func loggedExports(for documentID: UUID) -> [Receipt] {
        lock.lock()
        defer { lock.unlock() }
        return exportedReceipts[documentID] ?? []
    }
}
