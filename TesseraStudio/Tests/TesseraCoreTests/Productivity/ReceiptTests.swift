import XCTest
import CryptoKit
@testable import TesseraCore

// MARK: - ReceiptTests
//
// Contract: Receipt.swift's own doc comments - "canonicalBytes()...
// EXCLUDES the signature and voidedBy fields"; "verify(against:) - True
// iff the signature is a valid ed25519 signature over the canonical
// content... Returns false (does not throw) on any verification error";
// "isVoided - True iff this receipt is voided (has a voidedBy set)."
// Doctrine rule 2 (round-trip identity) for Receipt/C2PAManifest/Actor.

final class ReceiptTests: DoctrineTestCase {

    private func signedReceipt(mutations: [Mutation] = [.setDocumentTitle(title: "t")]) throws -> (receipt: Receipt, privateKey: Curve25519.Signing.PrivateKey) {
        let key = Curve25519.Signing.PrivateKey()
        let signer = ReceiptSigner(signingKey: key)
        let receipt = try signer.sign(
            documentID: UUID(), mutations: mutations, priorReceiptID: nil, actor: .user(UUID()),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        return (receipt, key)
    }

    // MARK: - canonicalBytes excludes signature + voidedBy

    func testCanonicalBytesAreStableRegardlessOfSignatureBytes() throws {
        let (receipt, _) = try signedReceipt()
        var withDifferentSignature = receipt
        withDifferentSignature = Receipt(
            id: receipt.id, documentID: receipt.documentID, actor: receipt.actor, mutations: receipt.mutations,
            timestamp: receipt.timestamp, priorReceiptID: receipt.priorReceiptID, signature: Data([0xFF, 0xEE]),
            c2paManifest: receipt.c2paManifest, summary: receipt.summary, preMutationSnapshot: receipt.preMutationSnapshot
        )
        XCTAssertEqual(try receipt.canonicalBytes(), try withDifferentSignature.canonicalBytes(),
                        "canonicalBytes must exclude the signature field entirely - two receipts differing only in signature must canonicalize identically")
    }

    func testCanonicalBytesAreStableRegardlessOfVoidedBy() throws {
        let (receipt, _) = try signedReceipt()
        var voided = receipt
        voided.voidedBy = UUID()
        XCTAssertEqual(try receipt.canonicalBytes(), try voided.canonicalBytes(),
                        "canonicalBytes must exclude voidedBy - it is set AFTER the original commitment, not part of it")
    }

    // MARK: - verify

    func testVerifyReturnsTrueForAValidSignature() throws {
        let (receipt, key) = try signedReceipt()
        XCTAssertTrue(receipt.verify(against: key.publicKey))
    }

    func testVerifyReturnsFalseForTheWrongPublicKey() throws {
        let (receipt, _) = try signedReceipt()
        let wrongKey = Curve25519.Signing.PrivateKey()
        XCTAssertFalse(receipt.verify(against: wrongKey.publicKey))
    }

    func testVerifyReturnsFalseNotThrowsWhenContentWasTamperedWith() throws {
        let (receipt, key) = try signedReceipt()
        var tampered = receipt
        tampered = Receipt(
            id: receipt.id, documentID: receipt.documentID, actor: receipt.actor,
            mutations: [.setDocumentTitle(title: "tampered!")], timestamp: receipt.timestamp,
            priorReceiptID: receipt.priorReceiptID, signature: receipt.signature,
            c2paManifest: receipt.c2paManifest, summary: receipt.summary, preMutationSnapshot: receipt.preMutationSnapshot
        )
        XCTAssertFalse(tampered.verify(against: key.publicKey), "a tampered receipt must fail verification, not throw")
    }

    // MARK: - isVoided

    func testIsVoidedFalseByDefault() throws {
        let (receipt, _) = try signedReceipt()
        XCTAssertFalse(receipt.isVoided)
    }

    func testIsVoidedTrueOnceVoidedByIsSet() throws {
        var (receipt, _) = try signedReceipt()
        receipt.voidedBy = UUID()
        XCTAssertTrue(receipt.isVoided)
    }

    // MARK: - Round-trip identity (doctrine rule 2)

    func testReceiptEncodeDecodeIdentity() throws {
        let (receipt, _) = try signedReceipt()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(receipt)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Receipt.self, from: data)
        XCTAssertEqual(decoded, receipt)
    }

    func testActorEncodeDecodeIdentityBothCases() throws {
        let userActor = Actor.user(UUID())
        let agentActor = Actor.agent(UUID(), model: "claude", promptHash: "abc123")
        for actor in [userActor, agentActor] {
            let data = try JSONEncoder().encode(actor)
            let decoded = try JSONDecoder().decode(Actor.self, from: data)
            XCTAssertEqual(decoded, actor)
        }
    }

    func testC2PAManifestEncodeDecodeIdentity() throws {
        let manifest = C2PAManifest(
            assertions: [C2PAManifest.Assertion(label: "c2pa.hash.data", data: .string("sha256:abc"))],
            signature: "ed25519:xyz"
        )
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(C2PAManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
    }
}
