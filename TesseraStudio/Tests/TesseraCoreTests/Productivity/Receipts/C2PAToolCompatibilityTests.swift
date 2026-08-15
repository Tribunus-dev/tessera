import XCTest
@testable import TesseraCore

// MARK: - C2PAToolCompatibilityTests
//
// Contract: C2PAToolCompatibility.swift's own doc comments - "Transform a
// C2PAManifest into an es256-compatible JUMBF manifest. Returns nil when
// the input manifest is nil"; "The original Tessera ed25519 signature is
// preserved in the output's tessera_original_signature field"; the JUMBF
// envelope's documented top-level keys (jumbf_type/c2pa_manifest/
// es256_signature/es256_public_key/tessera_original_signature/
// tessera_document_id/tessera_receipt_id).
//
// NOTE on determinism (doctrine rule 4): `transform` intentionally
// generates a FRESH random P-256 key per call ("A fresh per-export P-256
// key is the correct approach for the external-tool use case" - the
// file's own doc comment) - so two independent passes are NOT expected to
// be byte-identical here, unlike a true renderer. This is a documented
// design choice, not the renderer shape rule 4 targets; this suite
// instead asserts the STRUCTURE is present and correct on every call.

final class C2PAToolCompatibilityTests: DoctrineTestCase {

    private func sampleManifest() -> C2PAManifest {
        C2PAManifest(
            assertions: [
                C2PAManifest.Assertion(label: "c2pa.hash.data", data: .string("sha256:abc")),
                C2PAManifest.Assertion(label: "tessera.summary", data: .string("did a thing")),
            ],
            signature: "ed25519:original-signature-bytes"
        )
    }

    // MARK: - nil in, nil out

    func testTransformReturnsNilWhenManifestIsNil() {
        let result = C2PAToolCompatibility.transform(nil, documentID: UUID(), receiptID: UUID())
        XCTAssertNil(result)
    }

    // MARK: - Envelope structure (content, doctrine rule 8)

    func testTransformProducesTheDocumentedTopLevelEnvelopeKeys() throws {
        let documentID = UUID()
        let receiptID = UUID()
        let data = C2PAToolCompatibility.transform(sampleManifest(), documentID: documentID, receiptID: receiptID)
        XCTAssertNotNil(data)
        let obj = try JSONSerialization.jsonObject(with: data!) as? [String: Any]
        XCTAssertEqual(obj?["jumbf_type"] as? String, "application/vnd.adobe.xmp+jwt")
        XCTAssertEqual(obj?["tessera_document_id"] as? String, documentID.uuidString)
        XCTAssertEqual(obj?["tessera_receipt_id"] as? String, receiptID.uuidString)
        XCTAssertEqual(obj?["tessera_original_signature"] as? String, "ed25519:original-signature-bytes",
                        "the original ed25519 signature must be preserved verbatim for Tessera-aware verification")
        XCTAssertNotNil(obj?["es256_signature"])
        XCTAssertNotNil(obj?["es256_public_key"])
        XCTAssertNotNil(obj?["c2pa_manifest"])
    }

    func testTransformEs256SignatureIsPrefixedWithEs256() throws {
        let data = C2PAToolCompatibility.transform(sampleManifest(), documentID: UUID(), receiptID: UUID())!
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let sig = obj?["es256_signature"] as? String
        XCTAssertTrue(sig?.hasPrefix("es256:") ?? false)
    }

    func testTransformPublicKeyJWKHasExpectedFields() throws {
        let data = C2PAToolCompatibility.transform(sampleManifest(), documentID: UUID(), receiptID: UUID())!
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let jwk = obj?["es256_public_key"] as? [String: String]
        XCTAssertEqual(jwk?["kty"], "EC")
        XCTAssertEqual(jwk?["crv"], "P-256")
        XCTAssertNotNil(jwk?["x"])
        XCTAssertNotNil(jwk?["y"])
        // base64url must never contain the standard-base64-only characters.
        XCTAssertFalse((jwk?["x"] ?? "").contains("+"))
        XCTAssertFalse((jwk?["x"] ?? "").contains("/"))
        XCTAssertFalse((jwk?["x"] ?? "").contains("="))
    }

    func testTransformC2PAManifestSubobjectCarriesTheOriginalAssertionsAndEs256Algorithm() throws {
        let data = C2PAToolCompatibility.transform(sampleManifest(), documentID: UUID(), receiptID: UUID())!
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let c2paManifest = obj?["c2pa_manifest"] as? [String: Any]
        XCTAssertEqual(c2paManifest?["format"] as? String, "c2pa.v2")
        let assertions = c2paManifest?["assertions"] as? [[String: Any]]
        XCTAssertEqual(assertions?.count, 2, "every assertion from the source manifest must carry over")
        let signatureInfo = c2paManifest?["signature_info"] as? [String: Any]
        XCTAssertEqual(signatureInfo?["alg"] as? String, "es256")
    }

    // MARK: - Every call succeeds independently (each generates its own fresh key)

    func testTransformSucceedsOnRepeatedCallsWithDifferentKeysEachTime() throws {
        let manifest = sampleManifest()
        let first = C2PAToolCompatibility.transform(manifest, documentID: UUID(), receiptID: UUID())!
        let second = C2PAToolCompatibility.transform(manifest, documentID: UUID(), receiptID: UUID())!
        let firstObj = try JSONSerialization.jsonObject(with: first) as? [String: Any]
        let secondObj = try JSONSerialization.jsonObject(with: second) as? [String: Any]
        let firstKey = (firstObj?["es256_public_key"] as? [String: String])?["x"]
        let secondKey = (secondObj?["es256_public_key"] as? [String: String])?["x"]
        XCTAssertNotEqual(firstKey, secondKey, "each export must generate a fresh P-256 key, per the file's documented rationale")
    }
}
