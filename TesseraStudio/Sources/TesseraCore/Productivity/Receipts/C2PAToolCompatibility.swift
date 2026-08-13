import Foundation
import CryptoKit

// MARK: - C2PAToolCompatibility

/// A compatibility layer that transforms a ``C2PAManifest`` (signed with
/// the device's ed25519 key) into an `es256:` (ECDSA P-256) JUMBF
/// manifest that external C2PA tools (`c2patool`, Adobe Content
/// Authenticity) can parse.
///
/// The transformation is:
///   1. Extract the assertions from the source manifest (no verification
///      of the original ed25519 signature is performed).
///   2. Generate a fresh P-256 key pair for the `es256:` signature.
///   3. Sign the canonical assertion list with the new P-256 key.
///   4. Package as a JUMBF-compatible JSON structure.
///
/// The original Tessera ed25519 signature is preserved in the output's
/// `tessera_original_signature` field so a Tessera-aware verifier can
/// still validate the device-produced proof. The es256 layer is an
/// additional signature that external tools can verify independently.
///
/// Why a new P-256 key instead of deriving from the ed25519 key?
/// CryptoKit's Curve25519 and P256 key types are different curves.
/// Deriving a P-256 key from an ed25519 seed is non-standard and would
/// reduce compatibility rather than improve it. A fresh per-export P-256
/// key is the correct approach for the external-tool use case.
public struct C2PAToolCompatibility {

    // MARK: - Public API

    /// Transform a ``C2PAManifest`` into an es256-compatible JUMBF
    /// manifest. Returns nil when the input manifest is nil.
    ///
    /// The output is a JSON file that `c2patool` can parse. The
    /// structure follows the C2PA Technical Specification 2.x's
    /// JSON-based manifest format.
    ///
    /// - Parameters:
    ///   - manifest: The Tessera C2PA manifest (ed25519-signed).
    ///   - documentID: The document this manifest is for.
    ///   - receiptID: The receipt ID that produced this manifest.
    /// - Returns: A JUMBF-compatible JSON document, or nil when the
    ///   input is nil.
    public static func transform(
        _ manifest: C2PAManifest?,
        documentID: UUID,
        receiptID: UUID
    ) -> Data? {
        guard let manifest else { return nil }

        // 1. Generate a fresh P-256 key pair for this export.
        let p256Key = P256.Signing.PrivateKey()

        // 2. Extract assertions and build the es256-compatible manifest.
        guard let output = buildES256Manifest(
            from: manifest,
            p256Key: p256Key,
            documentID: documentID,
            receiptID: receiptID
        ) else {
            return nil
        }

        return output
    }

    // MARK: - JUMBF structure builder

    private static func buildES256Manifest(
        from tesseraManifest: C2PAManifest,
        p256Key: P256.Signing.PrivateKey,
        documentID: UUID,
        receiptID: UUID
    ) -> Data? {
        // Canonicalize the assertions the same way the original manifest does.
        let canonicalAssertions: Data
        do {
            canonicalAssertions = try tesseraManifest.canonicalBytes()
        } catch {
            return nil
        }

        // Sign with P-256 (es256). The signature type is
        // P256.Signing.ECDSASignature; convert to raw bytes for
        // base64 encoding.
        let es256SignatureRaw: P256.Signing.ECDSASignature
        do {
            es256SignatureRaw = try p256Key.signature(for: canonicalAssertions)
        } catch {
            return nil
        }
        let es256Signature = es256SignatureRaw.rawRepresentation

        // Extract the assertion data from AnyCodable values.
        let assertionData = tesseraManifest.assertions.map { assertion -> [String: Any] in
            let dataValue: Any
            switch assertion.data {
            case .string(let s): dataValue = s
            case .number(let n): dataValue = n
            case .bool(let b): dataValue = b
            case .null: dataValue = NSNull()
            case .object(let o): dataValue = o.compactMapValues { anyCodableToAny($0) }
            case .array(let a): dataValue = a.map { anyCodableToAny($0) }
            }
            return [
                "label": assertion.label,
                "data": dataValue
            ]
        }

        // Encode the P-256 public key as JWK (for verification tooling).
        let publicKeyJWK = encodeJWK(p256Key.publicKey)
        guard JSONSerialization.isValidJSONObject([publicKeyJWK]) else { return nil }

        // Build the C2PA-format manifest (es256 structure).
        let c2paManifest: [String: Any] = [
            "format": "c2pa.v2",
            "claim_generator": tesseraManifest.claimGenerator,
            "assertions": assertionData,
            "signature_info": [
                "alg": "es256",
                "issuer": "Tessera/\(bundleVersion)",
                "time": ISO8601DateFormatter().string(from: Date())
            ]
        ]

        // Assemble the full JUMBF-compatible envelope.
        let envelope: [String: Any] = [
            "jumbf_type": "application/vnd.adobe.xmp+jwt",
            "c2pa_manifest": c2paManifest,
            "es256_signature": "es256:" + es256Signature.base64EncodedString(),
            "es256_public_key": publicKeyJWK,
            "tessera_original_signature": tesseraManifest.signature,
            "tessera_document_id": documentID.uuidString,
            "tessera_receipt_id": receiptID.uuidString
        ]

        // JSONSerialization handles [String: Any] natively.
        return try? JSONSerialization.data(
            withJSONObject: envelope,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    // MARK: - JWK encoding

    /// Encode a P-256 public key as a JWK (RFC 7517).
    /// The raw representation is 64 bytes: 32 bytes for x, then 32 for y.
    private static func encodeJWK(_ publicKey: P256.Signing.PublicKey) -> [String: String] {
        let raw = publicKey.rawRepresentation
        precondition(raw.count == 64, "P-256 raw public key must be 64 bytes")
        let xBytes = raw.prefix(32)
        let yBytes = raw.suffix(32)
        return [
            "kty": "EC",
            "crv": "P-256",
            "x": base64urlEncode(xBytes),
            "y": base64urlEncode(yBytes)
        ]
    }

    private static func base64urlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - AnyCodable helpers

    private static func anyCodableToAny(_ value: AnyCodable) -> Any {
        switch value {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        case .object(let o): return o.compactMapValues { anyCodableToAny($0) }
        case .array(let a): return a.map { anyCodableToAny($0) }
        }
    }

    // MARK: - Bundle version

    private static var bundleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

// MARK: - C2PAToolExportFormat

/// The format of a c2patool-compatible export. Extends the existing
/// ``ReceiptExportFormat`` with the new es256 export option.
public enum C2PAToolExportFormat: String, CaseIterable, Sendable, Codable, Identifiable {
    /// Export the receipt chain as a JUMBF-compatible es256 manifest
    /// that `c2patool` can parse.
    case es256JUMBF = "es256JUMBF"

    public var id: String { rawValue }

    public var displayName: String {
        "C2PA manifest (es256, for c2patool)"
    }

    public var fileExtension: String {
        "c2pa.json"
    }
}

// MARK: - ExportError extension

public enum C2PAExportError: Error, Sendable, Equatable {
    case noManifest
    case transformFailed
    case signFailed
}
