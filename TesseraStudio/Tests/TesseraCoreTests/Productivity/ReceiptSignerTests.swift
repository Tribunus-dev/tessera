import XCTest
import CryptoKit
@testable import TesseraCore

// MARK: - ReceiptSignerTests
//
// Contract: ReceiptSigner.swift's own doc comments - "For testing, the
// signer accepts an injected private key via init(signingKey:) so unit
// tests don't need a real Keychain entry"; composeSummary's documented
// grouping behavior ("Group by shortDescription to compress repeated
// edits"); the C2PA manifest's fixed assertion set ("Standard
// c2pa.hash.data assertion (always present...)", "c2pa.actions", the two
// "Tessera-specific" assertions, and the receipt-id cross-reference
// assertion).

final class ReceiptSignerTests: DoctrineTestCase {

    private func injectedSigner() -> (signer: ReceiptSigner, key: Curve25519.Signing.PrivateKey) {
        let key = Curve25519.Signing.PrivateKey()
        return (ReceiptSigner(signingKey: key), key)
    }

    // MARK: - Injected key basics

    func testInjectedSignerHasSigningKeyAndExposesThePublicKey() {
        let (signer, key) = injectedSigner()
        XCTAssertTrue(signer.hasSigningKey)
        XCTAssertEqual(signer.publicKey?.rawRepresentation, key.publicKey.rawRepresentation)
        XCTAssertEqual(signer.injectedSigningKey?.rawRepresentation, key.rawRepresentation)
    }

    func testProductionKeychainSignerHasNoInjectedKey() {
        let signer = ReceiptSigner()
        XCTAssertNil(signer.injectedSigningKey, "the Keychain-backed signer must not expose an injected key")
    }

    // MARK: - sign() self-verifies and produces a verifiable receipt

    func testSignedReceiptVerifiesAgainstItsOwnPublicKey() throws {
        let (signer, key) = injectedSigner()
        let receipt = try signer.sign(documentID: UUID(), mutations: [.setDocumentTitle(title: "x")], priorReceiptID: nil, actor: .user(UUID()))
        XCTAssertTrue(receipt.verify(against: key.publicKey))
        XCTAssertFalse(receipt.signature.isEmpty)
    }

    func testSignPropagatesPriorReceiptIDAndTimestamp() throws {
        let (signer, _) = injectedSigner()
        let priorID = UUID()
        let timestamp = Date(timeIntervalSince1970: 12345)
        let receipt = try signer.sign(documentID: UUID(), mutations: [], priorReceiptID: priorID, actor: .user(UUID()), timestamp: timestamp)
        XCTAssertEqual(receipt.priorReceiptID, priorID)
        XCTAssertEqual(receipt.timestamp, timestamp)
    }

    // MARK: - verify(_:against:) discriminated result

    func testVerifyWrapperReturnsValidForAGoodSignature() throws {
        let (signer, key) = injectedSigner()
        let receipt = try signer.sign(documentID: UUID(), mutations: [], priorReceiptID: nil, actor: .user(UUID()))
        XCTAssertEqual(signer.verify(receipt, against: key.publicKey), .valid)
    }

    func testVerifyWrapperReturnsInvalidForTheWrongKey() throws {
        let (signer, _) = injectedSigner()
        let receipt = try signer.sign(documentID: UUID(), mutations: [], priorReceiptID: nil, actor: .user(UUID()))
        let wrongKey = Curve25519.Signing.PrivateKey()
        XCTAssertEqual(signer.verify(receipt, against: wrongKey.publicKey), .invalid)
    }

    func testVerifyWrapperReturnsVoidedWhenVoidedByIsSetRegardlessOfSignature() throws {
        let (signer, key) = injectedSigner()
        var receipt = try signer.sign(documentID: UUID(), mutations: [], priorReceiptID: nil, actor: .user(UUID()))
        let voidingReceiptID = UUID()
        receipt.voidedBy = voidingReceiptID
        XCTAssertEqual(signer.verify(receipt, against: key.publicKey), .voided(by: voidingReceiptID))
    }

    func testReceiptVerificationIsAcceptableOnlyForValid() {
        XCTAssertTrue(ReceiptVerification.valid.isAcceptable)
        XCTAssertFalse(ReceiptVerification.invalid.isAcceptable)
        XCTAssertFalse(ReceiptVerification.voided(by: UUID()).isAcceptable)
    }

    // MARK: - Summary composition (private composeSummary, observed via receipt.summary)

    func testSummaryForNoMutationsIsNoOp() throws {
        let (signer, _) = injectedSigner()
        let receipt = try signer.sign(documentID: UUID(), mutations: [], priorReceiptID: nil, actor: .user(UUID()))
        XCTAssertEqual(receipt.summary, "no-op")
    }

    func testSummaryForOneMutationIsItsShortDescription() throws {
        let (signer, _) = injectedSigner()
        let mutation = Mutation.deleteBlock(blockID: UUID())
        let receipt = try signer.sign(documentID: UUID(), mutations: [mutation], priorReceiptID: nil, actor: .user(UUID()))
        XCTAssertEqual(receipt.summary, mutation.shortDescription)
    }

    func testSummaryGroupsRepeatedShortDescriptionsWithACount() throws {
        let (signer, _) = injectedSigner()
        let mutations: [Mutation] = [
            .deleteBlock(blockID: UUID()),
            .deleteBlock(blockID: UUID()),
            .deleteBlock(blockID: UUID()),
        ]
        let receipt = try signer.sign(documentID: UUID(), mutations: mutations, priorReceiptID: nil, actor: .user(UUID()))
        XCTAssertEqual(receipt.summary, "3 × delete block")
    }

    func testSummaryForMultipleDistinctMutationsIsAlphabeticallySortedAndCommaJoined() throws {
        let (signer, _) = injectedSigner()
        let mutations: [Mutation] = [
            .deleteBlock(blockID: UUID()),           // "delete block"
            .appendInlineRun(blockID: UUID(), run: InlineRun(text: "x")), // "append text"
        ]
        let receipt = try signer.sign(documentID: UUID(), mutations: mutations, priorReceiptID: nil, actor: .user(UUID()))
        XCTAssertEqual(receipt.summary, "append text, delete block", "alphabetical order: 'append text' < 'delete block'")
    }

    // MARK: - C2PA manifest: fixed assertion set

    func testC2PAManifestCarriesAllFiveDocumentedAssertions() throws {
        let (signer, _) = injectedSigner()
        let receipt = try signer.sign(documentID: UUID(), mutations: [], priorReceiptID: nil, actor: .user(UUID()), documentContentHash: "sha256:abc")
        let labels = Set(receipt.c2paManifest?.assertions.map(\.label) ?? [])
        XCTAssertEqual(labels, ["c2pa.hash.data", "c2pa.actions", "tessera.actor", "tessera.summary", "tessera.receipt_id"])
    }

    func testC2PAManifestHashDataAssertionIsNullSentinelWhenNoContentHashProvided() throws {
        let (signer, _) = injectedSigner()
        let receipt = try signer.sign(documentID: UUID(), mutations: [], priorReceiptID: nil, actor: .user(UUID()))
        let hashAssertion = receipt.c2paManifest?.assertions.first { $0.label == "c2pa.hash.data" }
        XCTAssertEqual(hashAssertion?.data, .null)
    }

    func testC2PAManifestHashDataAssertionCarriesTheProvidedContentHash() throws {
        let (signer, _) = injectedSigner()
        let receipt = try signer.sign(documentID: UUID(), mutations: [], priorReceiptID: nil, actor: .user(UUID()), documentContentHash: "sha256:deadbeef")
        let hashAssertion = receipt.c2paManifest?.assertions.first { $0.label == "c2pa.hash.data" }
        XCTAssertEqual(hashAssertion?.data, .string("sha256:deadbeef"))
    }

    func testC2PAManifestActorAssertionTagsUserVsAgent() throws {
        let (signer, _) = injectedSigner()
        let userID = UUID()
        let userReceipt = try signer.sign(documentID: UUID(), mutations: [], priorReceiptID: nil, actor: .user(userID))
        let userActorAssertion = userReceipt.c2paManifest?.assertions.first { $0.label == "tessera.actor" }
        guard case .object(let userFields)? = userActorAssertion?.data else { return XCTFail("expected an object") }
        XCTAssertEqual(userFields["type"], .string("user"))
        XCTAssertEqual(userFields["id"], .string(userID.uuidString))

        let agentReceipt = try signer.sign(documentID: UUID(), mutations: [], priorReceiptID: nil, actor: .agent(UUID(), model: "claude", promptHash: "h"))
        let agentActorAssertion = agentReceipt.c2paManifest?.assertions.first { $0.label == "tessera.actor" }
        guard case .object(let agentFields)? = agentActorAssertion?.data else { return XCTFail("expected an object") }
        XCTAssertEqual(agentFields["type"], .string("agent"))
        XCTAssertEqual(agentFields["model"], .string("claude"))
    }

    func testC2PAManifestFormatIsPinnedToC2PAv2() throws {
        let (signer, _) = injectedSigner()
        let receipt = try signer.sign(documentID: UUID(), mutations: [], priorReceiptID: nil, actor: .user(UUID()))
        XCTAssertEqual(receipt.c2paManifest?.format, "c2pa.v2")
        XCTAssertTrue(receipt.c2paManifest?.signature.hasPrefix("ed25519:") ?? false)
    }
}
