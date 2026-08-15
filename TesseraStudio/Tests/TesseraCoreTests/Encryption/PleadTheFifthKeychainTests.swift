import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Encryption/PleadTheFifthKeychain.swift
// doc comment -- "Idempotent on purpose: re-running the wipe... must not
// stall on a not found from a prior run" and `deleteEntry`'s doc comment:
// "Returns true if the entry was deleted or was already missing
// (errSecItemNotFound), false on any other failure."
//
// SAFETY: every test below uses a freshly-generated, random UUID-based
// `account` string, never `PleadTheFifthKeychain.volumePasswordAccount`
// or `.dataAccessKeyAccount` (the fixed production account names). This
// guarantees the tests can never collide with, read, or destroy a real
// user's actual Plead-the-Fifth Keychain entry on the host machine.
final class PleadTheFifthKeychainTests: DoctrineTestCase {

    private func freshAccountName() -> String {
        "doctrine-test-\(UUID().uuidString)"
    }

    func testDeletingANonExistentEntryReturnsTrue() {
        // Idempotency: errSecItemNotFound counts as success.
        XCTAssertTrue(PleadTheFifthKeychain.deleteEntry(account: freshAccountName()))
    }

    func testDeletingTheSameNonExistentEntryTwiceIsStillTrueBothTimes() {
        let account = freshAccountName()
        XCTAssertTrue(PleadTheFifthKeychain.deleteEntry(account: account))
        XCTAssertTrue(PleadTheFifthKeychain.deleteEntry(account: account), "re-running the delete must not stall or fail")
    }

    func testServiceAndAccountConstantsAreTheDocumentedProductionNames() {
        // Pinning the constants themselves (not exercising them) is safe
        // and verifies the account-name contract other modules rely on.
        XCTAssertEqual(PleadTheFifthKeychain.service, "com.tessera.studio.encryption")
        XCTAssertEqual(PleadTheFifthKeychain.volumePasswordAccount, "volume-password")
        XCTAssertEqual(PleadTheFifthKeychain.dataAccessKeyAccount, "data-access-key")
        XCTAssertEqual(PleadTheFifthKeychain.wrappingKeyAccount, "wrapping-key")
    }
}
