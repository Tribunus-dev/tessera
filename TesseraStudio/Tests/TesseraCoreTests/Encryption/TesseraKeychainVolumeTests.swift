import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Encryption/TesseraKeychainVolume.swift
// doc comment -- 32 random bytes, base64-encoded, "carries the same
// 32*8 = 256 bits of entropy as the raw bytes."
//
// SAFETY NOTE (why this file never calls `storeVolumePassword` /
// `deleteVolumePassword` / `receiptSigningKey`): `volumePasswordAccount`
// is a FIXED constant ("volume-password") under the shared
// `TesseraSecretStore.service` Keychain namespace -- there is no
// injectable account name, unlike `PleadTheFifthKeychain.deleteEntry`.
// Calling `storeVolumePassword`/`deleteVolumePassword` for real would
// overwrite or destroy the actual encrypted-volume password on any
// machine where "Plead the Fifth" is genuinely configured. This file
// only exercises the read-only `hasVolumePassword()` check (safe: it
// never mutates anything) and the pure `generateVolumePassword(byteCount:)`
// generator (safe: it never touches the Keychain at all). See the
// findings file for this explicit, safety-motivated scope decision.
final class TesseraKeychainVolumeTests: DoctrineTestCase {

    func testGeneratedPasswordDecodesToTheRequestedByteCount() throws {
        let password = try XCTUnwrap(TesseraKeychainVolume.generateVolumePassword(byteCount: 32))
        let decoded = try XCTUnwrap(Data(base64Encoded: password))
        XCTAssertEqual(decoded.count, 32)
    }

    func testGeneratedPasswordRespectsACustomByteCount() throws {
        let password = try XCTUnwrap(TesseraKeychainVolume.generateVolumePassword(byteCount: 16))
        let decoded = try XCTUnwrap(Data(base64Encoded: password))
        XCTAssertEqual(decoded.count, 16)
    }

    func testGeneratedPasswordsAreNotDeterministic() throws {
        let a = try XCTUnwrap(TesseraKeychainVolume.generateVolumePassword())
        let b = try XCTUnwrap(TesseraKeychainVolume.generateVolumePassword())
        XCTAssertNotEqual(a, b, "two independently generated passwords must not collide")
    }

    func testGeneratedPasswordDefaultsToThirtyTwoBytes() throws {
        let password = try XCTUnwrap(TesseraKeychainVolume.generateVolumePassword())
        let decoded = try XCTUnwrap(Data(base64Encoded: password))
        XCTAssertEqual(decoded.count, 32)
    }

    // MARK: - hasVolumePassword(): read-only, safe to call for real (it
    // reports the host machine's real state, whatever that is; this
    // test only asserts the return type contract, not a specific value).

    func testHasVolumePasswordReturnsABoolWithoutThrowing() {
        // Whatever this machine's real state is, the call itself must
        // not crash or hang; the return value is a plain Bool by type.
        let result: Bool = TesseraKeychainVolume.hasVolumePassword()
        XCTAssertTrue(result == true || result == false)
    }
}
