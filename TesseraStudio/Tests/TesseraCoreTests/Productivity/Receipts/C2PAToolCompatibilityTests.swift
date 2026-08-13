import XCTest
import CryptoKit
@testable import TesseraCore

/// Tests for the c2patool compatibility layer: ed25519 C2PAManifest
/// -> es256 JUMBF manifest transformation.
final class C2PAToolCompatibilityTests: XCTestCase {

    private var signer: ReceiptSigner!
    private var key: Curve25519.Signing.PrivateKey!

    override func setUp() {
        super.setUp()
        key = Curve25519.Signing.PrivateKey()
        signer = ReceiptSigner(signingKey: key)
    }

    // MARK: - Transform with valid manifest

    func testTransformProducesValidJSON() throws {
        let receipt = try signer.sign(
            documentID: UUID(),
            mutations: [.setDocumentTitle(title: "Test")],
            priorReceiptID: nil,
            actor: .user(UUID()),
            documentContentHash: "sha256:abc123"
        )
        let manifest = try XCTUnwrap(receipt.c2paManifest)

        let output = C2PAToolCompatibility.transform(
            manifest,
            documentID: receipt.documentID,
            receiptID: receipt.id
        )
        XCTAssertNotNil(output, "transform must not return nil for a valid manifest")

        // The output must be valid JSON.
        let parsed = try JSONSerialization.jsonObject(with: output!) as? [String: Any]
        XCTAssertNotNil(parsed, "output must be valid JSON")
    }

    func testTransformOutputContainsExpectedKeys() throws {
        let docID = UUID()
        let receiptID = UUID()
        let receipt = try signer.sign(
            documentID: docID,
            mutations: [.setDocumentTitle(title: "Test Doc")],
            priorReceiptID: nil,
            actor: .user(UUID()),
            documentContentHash: "sha256:testhash"
        )
        let manifest = try XCTUnwrap(receipt.c2paManifest)

        let output = C2PAToolCompatibility.transform(
            manifest,
            documentID: docID,
            receiptID: receiptID
        )!
        let parsed = try JSONSerialization.jsonObject(with: output) as? [String: Any]
        XCTAssertNotNil(parsed)

        // Required top-level keys.
        XCTAssertNotNil(parsed?["jumbf_type"])
        XCTAssertNotNil(parsed?["c2pa_manifest"])
        XCTAssertNotNil(parsed?["es256_signature"])
        XCTAssertNotNil(parsed?["es256_public_key"])
        XCTAssertNotNil(parsed?["tessera_original_signature"])
        XCTAssertEqual(parsed?["tessera_document_id"] as? String, docID.uuidString)
        XCTAssertEqual(parsed?["tessera_receipt_id"] as? String, receiptID.uuidString)
    }

    func testEs256SignatureHasCorrectPrefix() throws {
        let receipt = try signer.sign(
            documentID: UUID(),
            mutations: [],
            priorReceiptID: nil,
            actor: .user(UUID())
        )
        let manifest = try XCTUnwrap(receipt.c2paManifest)

        let output = C2PAToolCompatibility.transform(
            manifest,
            documentID: UUID(),
            receiptID: receipt.id
        )!
        let parsed = try JSONSerialization.jsonObject(with: output) as? [String: Any]
        let sig = parsed?["es256_signature"] as? String
        XCTAssertTrue(sig?.hasPrefix("es256:") == true, "signature must have es256: prefix")
        XCTAssertFalse(sig?.contains("ed25519") == true, "es256 output must not use ed25519 prefix")
    }

    func testTesseraOriginalSignaturePreserved() throws {
        let receipt = try signer.sign(
            documentID: UUID(),
            mutations: [],
            priorReceiptID: nil,
            actor: .user(UUID())
        )
        let manifest = try XCTUnwrap(receipt.c2paManifest)

        let output = C2PAToolCompatibility.transform(
            manifest,
            documentID: UUID(),
            receiptID: receipt.id
        )!
        let parsed = try JSONSerialization.jsonObject(with: output) as? [String: Any]
        let originalSig = parsed?["tessera_original_signature"] as? String
        XCTAssertEqual(originalSig, manifest.signature)
    }

    func testC2PAManifestInOutputHasRequiredFields() throws {
        let receipt = try signer.sign(
            documentID: UUID(),
            mutations: [.setDocumentTitle(title: "Test")],
            priorReceiptID: nil,
            actor: .user(UUID()),
            documentContentHash: "sha256:xyz"
        )
        let manifest = try XCTUnwrap(receipt.c2paManifest)

        let output = C2PAToolCompatibility.transform(
            manifest,
            documentID: UUID(),
            receiptID: receipt.id
        )!
        let parsed = try JSONSerialization.jsonObject(with: output) as? [String: Any]
        let c2pa = parsed?["c2pa_manifest"] as? [String: Any]
        XCTAssertNotNil(c2pa)
        XCTAssertEqual(c2pa?["format"] as? String, "c2pa.v2")
        XCTAssertTrue(c2pa?["claim_generator"] as? String == manifest.claimGenerator)

        // The assertions must be preserved.
        let assertions = c2pa?["assertions"] as? [[String: Any]]
        XCTAssertNotNil(assertions)
        let labels = Set(assertions?.compactMap { $0["label"] as? String } ?? [])
        XCTAssertTrue(labels.contains("c2pa.hash.data"))
        XCTAssertTrue(labels.contains("c2pa.actions"))
        XCTAssertTrue(labels.contains("tessera.actor"))
        XCTAssertTrue(labels.contains("tessera.summary"))
    }

    func testES256PublicKeyHasCorrectJWKFields() throws {
        let receipt = try signer.sign(
            documentID: UUID(),
            mutations: [],
            priorReceiptID: nil,
            actor: .user(UUID())
        )

        let output = C2PAToolCompatibility.transform(
            receipt.c2paManifest,
            documentID: UUID(),
            receiptID: receipt.id
        )!
        let parsed = try JSONSerialization.jsonObject(with: output) as? [String: Any]
        let jwk = parsed?["es256_public_key"] as? [String: String]
        XCTAssertNotNil(jwk)
        XCTAssertEqual(jwk?["kty"], "EC")
        XCTAssertEqual(jwk?["crv"], "P-256")
        XCTAssertNotNil(jwk?["x"])
        XCTAssertNotNil(jwk?["y"])
    }

    // MARK: - Transform with nil manifest

    func testTransformWithNilManifestReturnsNil() {
        let output = C2PAToolCompatibility.transform(
            nil,
            documentID: UUID(),
            receiptID: UUID()
        )
        XCTAssertNil(output)
    }

    // MARK: - Signature info

    func testSignatureInfoIncludesES256Algorithm() throws {
        let receipt = try signer.sign(
            documentID: UUID(),
            mutations: [],
            priorReceiptID: nil,
            actor: .user(UUID())
        )

        let output = C2PAToolCompatibility.transform(
            receipt.c2paManifest,
            documentID: UUID(),
            receiptID: receipt.id
        )!
        let parsed = try JSONSerialization.jsonObject(with: output) as? [String: Any]
        let c2pa = parsed?["c2pa_manifest"] as? [String: Any]
        let sigInfo = c2pa?["signature_info"] as? [String: Any]
        XCTAssertNotNil(sigInfo)
        XCTAssertEqual(sigInfo?["alg"] as? String, "es256")
    }

    // MARK: - Receipt with agent actor

    func testTransformWithAgentActor() throws {
        let receipt = try signer.sign(
            documentID: UUID(),
            mutations: [.setDocumentTitle(title: "Agent edit")],
            priorReceiptID: nil,
            actor: .agent(
                UUID(),
                model: "tessera-1",
                promptHash: "sha256:agentprompt"
            )
        )
        let manifest = try XCTUnwrap(receipt.c2paManifest)

        let output = C2PAToolCompatibility.transform(
            manifest,
            documentID: receipt.documentID,
            receiptID: receipt.id
        )!
        let parsed = try JSONSerialization.jsonObject(with: output) as? [String: Any]
        let c2pa = parsed?["c2pa_manifest"] as? [String: Any]
        let assertions = c2pa?["assertions"] as? [[String: Any]]
        let actorAssertion = assertions?.first { ($0["label"] as? String) == "tessera.actor" }
        XCTAssertNotNil(actorAssertion)
        let actorData = actorAssertion?["data"] as? [String: Any]
        XCTAssertEqual(actorData?["type"] as? String, "agent")
        XCTAssertEqual(actorData?["model"] as? String, "tessera-1")
    }
}
