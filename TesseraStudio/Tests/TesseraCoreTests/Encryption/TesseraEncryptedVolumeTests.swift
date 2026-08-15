import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Encryption/TesseraEncryptedVolume.swift
// doc comments -- `TesseraVolumeConfig`'s defaults (1 GiB, /Volumes/
// TesseraVault) and `TesseraEncryptedVolumeError.kind`'s doc comment:
// "the machine-readable category... useful for switch-on-error in views".
//
// The actor itself (`create`/`mount`/`unmount`/`reset`) shells out to
// `hdiutil` against a real disk image -- empirical-probe territory
// (rule 10) that creates/mounts/unmounts a real macOS volume and is out
// of scope for the default suite in this pass (see openQuestions: a
// dedicated, clearly-labeled, gated probe file with an ungated shadow
// per rule 11 would be the correct home for that, and none existed to
// extend). This file covers the two pure value types the actor exposes:
// `TesseraVolumeConfig` and `TesseraEncryptedVolumeError`.
final class TesseraEncryptedVolumeTests: DoctrineTestCase {

    // MARK: - TesseraVolumeConfig defaults

    func testConfigDefaultsToOneGibibyteAndTesseraVaultNaming() {
        let config = TesseraVolumeConfig(bundleURL: URL(fileURLWithPath: "/tmp/vault.sparsebundle"))
        XCTAssertEqual(config.sizeBytes, 1024 * 1024 * 1024)
        XCTAssertEqual(config.volumeName, "TesseraVault")
        XCTAssertEqual(config.mountPoint, URL(fileURLWithPath: "/Volumes/TesseraVault"))
    }

    func testConfigEquality() {
        let a = TesseraVolumeConfig(bundleURL: URL(fileURLWithPath: "/tmp/a.sparsebundle"))
        let b = TesseraVolumeConfig(bundleURL: URL(fileURLWithPath: "/tmp/a.sparsebundle"))
        let c = TesseraVolumeConfig(bundleURL: URL(fileURLWithPath: "/tmp/b.sparsebundle"))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - TesseraEncryptedVolumeError.kind: independent oracle (rule
    // 7), the 11 documented cases pinned against the Kind enum's own
    // named cases from the doc comment, cross-checked against the error
    // enum's own kind mapping (not against a second computed copy).

    func testEveryErrorCaseMapsToItsOwnNamedKind() {
        let cases: [(TesseraEncryptedVolumeError, TesseraEncryptedVolumeError.Kind)] = [
            (.keychainRejected(operation: "op"), .keychainRejected),
            (.keychainMissingPassword, .keychainMissingPassword),
            (.hdiutilFailed(operation: "op", exitCode: 1, stderr: ""), .hdiutilFailed),
            (.bundleAlreadyExists(URL(fileURLWithPath: "/tmp/x")), .bundleAlreadyExists),
            (.bundleMissing(URL(fileURLWithPath: "/tmp/x")), .bundleMissing),
            (.notMounted, .notMounted),
            (.alreadyMounted(URL(fileURLWithPath: "/tmp/x")), .alreadyMounted),
            (.mountpointUnavailable(URL(fileURLWithPath: "/tmp/x")), .mountpointUnavailable),
            (.migrationFailed(reason: "r"), .migrationFailed),
            (.platformUnsupported, .platformUnsupported),
            (.other("m"), .other),
        ]
        for (error, expectedKind) in cases {
            XCTAssertEqual(error.kind, expectedKind, "\(error) must map to .\(expectedKind)")
        }
    }

    func testEveryErrorCaseHasANonEmptyLocalizedDescription() {
        let errors: [TesseraEncryptedVolumeError] = [
            .keychainRejected(operation: "create"),
            .keychainMissingPassword,
            .hdiutilFailed(operation: "attach", exitCode: 1, stderr: "boom"),
            .bundleAlreadyExists(URL(fileURLWithPath: "/tmp/x")),
            .bundleMissing(URL(fileURLWithPath: "/tmp/x")),
            .notMounted,
            .alreadyMounted(URL(fileURLWithPath: "/tmp/x")),
            .mountpointUnavailable(URL(fileURLWithPath: "/tmp/x")),
            .migrationFailed(reason: "disk full"),
            .platformUnsupported,
            .other("custom message"),
        ]
        for error in errors {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty, "\(error) must have a non-empty description")
        }
    }

    func testHdiutilFailedDescriptionIncludesExitCodeAndStderr() {
        let error = TesseraEncryptedVolumeError.hdiutilFailed(operation: "attach", exitCode: 42, stderr: "wrong password")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("42"))
        XCTAssertTrue(description.contains("wrong password"))
    }

    func testOtherCaseDescriptionIsThePassedMessageVerbatim() {
        let error = TesseraEncryptedVolumeError.other("a custom message")
        XCTAssertEqual(error.errorDescription, "a custom message")
    }
}
