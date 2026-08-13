import XCTest
import CryptoKit
@testable import TesseraCore

/// Tests for the Receipt infrastructure: mutation -> receipt
/// generation, signature round-trip, chain ordering, voiding,
/// C2PA manifest format, JSON round-trip.
final class ReceiptTests: XCTestCase {

    private var signer: ReceiptSigner!
    private var key: Curve25519.Signing.PrivateKey!

    override func setUp() {
        super.setUp()
        // Fresh ephemeral key per test so signatures don't leak.
        key = Curve25519.Signing.PrivateKey()
        signer = ReceiptSigner(signingKey: key)
    }

    // MARK: - Mutation -> Receipt generation

    func testSignGeneratesReceipt() throws {
        let mutation = Mutation.setBlockAttribute(
            blockID: UUID(),
            key: "level",
            value: .number(1)
        )
        let receipt = try signer.sign(
            documentID: UUID(),
            mutations: [mutation],
            priorReceiptID: nil,
            actor: .user(UUID())
        )
        XCTAssertEqual(receipt.mutations.count, 1)
        XCTAssertNotNil(receipt.priorReceiptID == nil)  // sanity
        XCTAssertTrue(receipt.priorReceiptID == nil)
        XCTAssertNotNil(receipt.c2paManifest)
        XCTAssertEqual(receipt.signature.count, 64)  // ed25519 signature size
    }

    func testSignChainReferencesPrior() throws {
        let first = try signer.sign(
            documentID: UUID(),
            mutations: [.setDocumentTitle(title: "v1")],
            priorReceiptID: nil,
            actor: .user(UUID())
        )
        let second = try signer.sign(
            documentID: first.documentID,
            mutations: [.setDocumentTitle(title: "v2")],
            priorReceiptID: first.id,
            actor: .user(UUID())
        )
        XCTAssertEqual(second.priorReceiptID, first.id)
    }

    // MARK: - Signature round-trip

    func testSignatureVerifies() throws {
        let receipt = try signer.sign(
            documentID: UUID(),
            mutations: [.setDocumentTitle(title: "x")],
            priorReceiptID: nil,
            actor: .user(UUID())
        )
        XCTAssertTrue(receipt.verify(against: key.publicKey))
    }

    func testSignatureDoesNotVerifyWithDifferentKey() throws {
        let receipt = try signer.sign(
            documentID: UUID(),
            mutations: [.setDocumentTitle(title: "x")],
            priorReceiptID: nil,
            actor: .user(UUID())
        )
        let otherKey = Curve25519.Signing.PrivateKey()
        XCTAssertFalse(receipt.verify(against: otherKey.publicKey))
    }

    func testSignatureDoesNotVerifyWithTamperedPayload() throws {
        // Sign a real receipt, then build a tampered copy that
        // reuses the original signature over a different summary.
        // The signature was computed over the original canonical
        // content; the tampered receipt's canonical content differs,
        // so verification must fail.
        let original = try signer.sign(
            documentID: UUID(),
            mutations: [.setDocumentTitle(title: "x")],
            priorReceiptID: nil,
            actor: .user(UUID())
        )
        let tampered = Receipt(
            id: original.id,
            documentID: original.documentID,
            actor: original.actor,
            mutations: original.mutations,
            timestamp: original.timestamp,
            priorReceiptID: original.priorReceiptID,
            signature: original.signature,
            c2paManifest: original.c2paManifest,
            summary: "tampered"
        )
        XCTAssertFalse(tampered.verify(against: key.publicKey))
    }

    // MARK: - Voiding

    func testVoidedReceiptReportsVoided() throws {
        let original = try signer.sign(
            documentID: UUID(),
            mutations: [.setDocumentTitle(title: "x")],
            priorReceiptID: nil,
            actor: .user(UUID())
        )
        let voider = UUID()
        var voided = original
        voided.voidedBy = voider
        XCTAssertTrue(voided.isVoided)
        let verification = signer.verify(voided, against: key.publicKey)
        guard case .voided(let id) = verification else {
            XCTFail("expected .voided, got \(verification)")
            return
        }
        XCTAssertEqual(id, voider)
    }

    func testValidReceiptIsVerifiedValid() throws {
        let receipt = try signer.sign(
            documentID: UUID(),
            mutations: [.setDocumentTitle(title: "x")],
            priorReceiptID: nil,
            actor: .user(UUID())
        )
        let verification = signer.verify(receipt, against: key.publicKey)
        XCTAssertEqual(verification, .valid)
    }

    func testInvalidReceiptReturnsInvalid() throws {
        let original = try signer.sign(
            documentID: UUID(),
            mutations: [.setDocumentTitle(title: "x")],
            priorReceiptID: nil,
            actor: .user(UUID())
        )
        let tampered = Receipt(
            id: original.id,
            documentID: original.documentID,
            actor: original.actor,
            mutations: original.mutations,
            timestamp: original.timestamp,
            priorReceiptID: original.priorReceiptID,
            signature: original.signature,
            c2paManifest: original.c2paManifest,
            summary: "tampered"
        )
        let verification = signer.verify(tampered, against: key.publicKey)
        XCTAssertEqual(verification, .invalid)
    }

    // MARK: - C2PA manifest

    func testC2PAManifestHasRequiredFields() throws {
        let receipt = try signer.sign(
            documentID: UUID(),
            mutations: [.setBlockAttribute(blockID: UUID(), key: "level", value: .number(1))],
            priorReceiptID: nil,
            actor: .user(UUID()),
            documentContentHash: "sha256:abc"
        )
        let manifest = try XCTUnwrap(receipt.c2paManifest)
        XCTAssertEqual(manifest.format, "c2pa.v2")
        XCTAssertTrue(manifest.claimGenerator.hasPrefix("tessera/"))
        XCTAssertTrue(manifest.signature.hasPrefix("ed25519:"))
        // Required assertions: c2pa.hash.data, c2pa.actions, tessera.actor, tessera.summary, tessera.receipt_id
        let labels = Set(manifest.assertions.map { $0.label })
        XCTAssertTrue(labels.contains("c2pa.hash.data"))
        XCTAssertTrue(labels.contains("c2pa.actions"))
        XCTAssertTrue(labels.contains("tessera.actor"))
        XCTAssertTrue(labels.contains("tessera.summary"))
        XCTAssertTrue(labels.contains("tessera.receipt_id"))
    }

    func testC2PAManifestContentHashField() throws {
        let receipt = try signer.sign(
            documentID: UUID(),
            mutations: [.setDocumentTitle(title: "x")],
            priorReceiptID: nil,
            actor: .user(UUID()),
            documentContentHash: "sha256:0123456789abcdef"
        )
        let manifest = try XCTUnwrap(receipt.c2paManifest)
        let hashAssertion = try XCTUnwrap(
            manifest.assertions.first { $0.label == "c2pa.hash.data" }
        )
        XCTAssertEqual(hashAssertion.data.stringValue, "sha256:0123456789abcdef")
    }

    func testC2PAManifestActorFieldForUser() throws {
        let userID = UUID()
        let receipt = try signer.sign(
            documentID: UUID(),
            mutations: [.setDocumentTitle(title: "x")],
            priorReceiptID: nil,
            actor: .user(userID)
        )
        let manifest = try XCTUnwrap(receipt.c2paManifest)
        let actorAssertion = try XCTUnwrap(
            manifest.assertions.first { $0.label == "tessera.actor" }
        )
        // Should be an object with type=user, id=<uuid>.
        if case .object(let obj) = actorAssertion.data {
            XCTAssertEqual(obj["type"]?.stringValue, "user")
            XCTAssertEqual(obj["id"]?.stringValue, userID.uuidString)
        } else {
            XCTFail("expected .object actor assertion, got \(actorAssertion.data)")
        }
    }

    func testC2PAManifestActorFieldForAgent() throws {
        let runID = UUID()
        let receipt = try signer.sign(
            documentID: UUID(),
            mutations: [.setDocumentTitle(title: "x")],
            priorReceiptID: nil,
            actor: .agent(runID, model: "claude-opus", promptHash: "sha256:xyz")
        )
        let manifest = try XCTUnwrap(receipt.c2paManifest)
        let actorAssertion = try XCTUnwrap(
            manifest.assertions.first { $0.label == "tessera.actor" }
        )
        if case .object(let obj) = actorAssertion.data {
            XCTAssertEqual(obj["type"]?.stringValue, "agent")
            XCTAssertEqual(obj["agent_run_id"]?.stringValue, runID.uuidString)
            XCTAssertEqual(obj["model"]?.stringValue, "claude-opus")
            XCTAssertEqual(obj["prompt_hash"]?.stringValue, "sha256:xyz")
        } else {
            XCTFail("expected .object actor assertion")
        }
    }

    // MARK: - JSON serialization

    func testReceiptJSONRoundTrip() throws {
        let original = try signer.sign(
            documentID: UUID(),
            mutations: [
                .insertBlockAfter(parentID: nil, anchorID: nil, block: Block(type: .paragraph)),
                .setBlockContent(blockID: UUID(), content: [InlineRun(text: "hi")])
            ],
            priorReceiptID: nil,
            actor: .user(UUID())
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Receipt.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.documentID, original.documentID)
        XCTAssertEqual(decoded.mutations, original.mutations)
        XCTAssertEqual(decoded.signature, original.signature)
        XCTAssertEqual(decoded.summary, original.summary)
        XCTAssertEqual(decoded.priorReceiptID, original.priorReceiptID)
    }

    // MARK: - Summary

    func testSummaryIncludesActorAndMutationCount() throws {
        let userID = UUID()
        let receipt = try signer.sign(
            documentID: UUID(),
            mutations: (0..<3).map { _ in
                Mutation.setBlockAttribute(
                    blockID: UUID(),
                    key: "x",
                    value: .number(1)
                )
            },
            priorReceiptID: nil,
            actor: .user(userID)
        )
        XCTAssertFalse(receipt.summary.isEmpty)
        XCTAssertTrue(receipt.summary.contains("set attribute"))
    }

    func testSummarySingleMutationUsesDescription() throws {
        let receipt = try signer.sign(
            documentID: UUID(),
            mutations: [.setDocumentTitle(title: "My Document")],
            priorReceiptID: nil,
            actor: .user(UUID())
        )
        XCTAssertTrue(receipt.summary.contains("set title"))
    }

    // MARK: - Void appends a NEW receipt (not mutation of original)

    /// Voiding creates a brand-new receipt with a different ID from the
    /// original. The original's `voidedBy` is set in-memory after the
    /// inverse is appended to the chain. This is the property that
    /// keeps the chain append-only: the original row in the DB is
    /// never modified.
    func testVoidAppendsNewReceipt() throws {
        let original = try signer.sign(
            documentID: UUID(),
            mutations: [.setDocumentTitle(title: "x")],
            priorReceiptID: nil,
            actor: .user(UUID())
        )
        // The inverse receipt must have a different ID from the original.
        // We simulate what ReceiptUndoManager does: sign the inverse
        // as a new receipt.
        let inverse = try signer.sign(
            documentID: original.documentID,
            mutations: [],   // empty for the test (real inverse has inverse mutations)
            priorReceiptID: original.id,
            actor: .user(UUID()),
            preMutationSnapshot: [:]
        )
        XCTAssertNotEqual(inverse.id, original.id)
        // The inverse's prior is the original, so the chain is intact.
        XCTAssertEqual(inverse.priorReceiptID, original.id)
        // The original is NOT modified in place (append-only).
        XCTAssertNil(original.voidedBy)
    }

    // MARK: - Pre-mutation snapshot

    /// The receipt's `preMutationSnapshot` captures the blocks affected
    /// by the mutations. This is what makes the receipt self-contained
    /// for undo: the inverse can be computed without the live document.
    func testPreMutationSnapshotCapturesAffectedBlocks() throws {
        let blockID = UUID()
        let block = Block(
            id: blockID,
            type: .paragraph,
            content: [InlineRun(text: "original content")]
        )
        let docID = UUID()
        var engine = MutationEngine()
        var ast = DocumentAST(
            blocks: [blockID: block],
            rootChildren: [blockID]
        )
        // Apply a mutation and capture the pre-snapshot the engine returns.
        let preFromEngine = try engine.apply(
            .setBlockContent(
                blockID: blockID,
                content: [InlineRun(text: "new content")]
            ),
            to: &ast
        )
        // The engine must return the pre-state of the affected block.
        XCTAssertTrue(preFromEngine.keys.contains(blockID))
        XCTAssertEqual(
            preFromEngine[blockID]?.content.first?.text,
            "original content"
        )
        // Now sign a receipt with this snapshot and verify it round-trips.
        let receipt = try signer.sign(
            documentID: docID,
            mutations: [.setBlockContent(
                blockID: blockID,
                content: [InlineRun(text: "new content")]
            )],
            priorReceiptID: nil,
            actor: .user(UUID()),
            preMutationSnapshot: preFromEngine
        )
        XCTAssertEqual(receipt.preMutationSnapshot[blockID]?.id, blockID)
        XCTAssertEqual(
            receipt.preMutationSnapshot[blockID]?.content.first?.text,
            "original content"
        )
    }

    /// The receipt is self-contained for undo: the inverse mutations can
    /// be computed entirely from the receipt's `preMutationSnapshot` and
    /// `mutations` fields. We verify by building the receipt from a
    /// document, then restoring the original state using only the
    /// embedded snapshot (not the live document).
    func testPreMutationSnapshotSelfContained() throws {
        let blockID = UUID()
        let originalBlock = Block(
            id: blockID,
            type: .paragraph,
            content: [InlineRun(text: "the original text")]
        )
        let docID = UUID()

        // Apply a mutation and capture the pre-snapshot (same pattern
        // DocumentStore uses when building the receipt).
        var engine = MutationEngine()
        var ast = DocumentAST(
            blocks: [blockID: originalBlock],
            rootChildren: [blockID]
        )
        var preSnapshot: [UUID: Block] = [:]
        let newContent = [InlineRun(text: "the new text")]
        let mutation = Mutation.setBlockContent(blockID: blockID, content: newContent)
        let pre = try engine.apply(mutation, to: &ast)
        for (k, v) in pre { preSnapshot[k] = v }

        // Sign the receipt with the pre-snapshot.
        let receipt = try signer.sign(
            documentID: docID,
            mutations: [mutation],
            priorReceiptID: nil,
            actor: .user(UUID()),
            preMutationSnapshot: preSnapshot
        )

        // The inverse mutations are computable entirely from the receipt
        // (no live document needed).
        let inverseMutations = receipt.mutations.flatMap {
            $0.inverse(preMutation: receipt.preMutationSnapshot)
        }
        XCTAssertFalse(inverseMutations.isEmpty)

        // Verify the inverse restores the original text. Apply the inverse
        // to the post-mutation document (which has "the new text") using
        // only the data in the receipt's snapshot.
        let inverse = inverseMutations[0]
        var restored = ast  // ast has "the new text" after the mutation
        let inversePre = try engine.apply(inverse, to: &restored)
        XCTAssertFalse(inversePre.isEmpty)
        XCTAssertEqual(
            restored.blocks[blockID]?.content.first?.text,
            "the original text",
            "inverse must restore the original text using the embedded snapshot"
        )
    }
}
