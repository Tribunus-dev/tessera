import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Encryption/SidecarController.swift
// doc comments -- `NoOpSidecarController` is "silent no-ops"; the wipe
// executor's step 1/2 rely on `stopPostgres`/`stopValkey` never throwing
// for a build with no sidecars wired.
final class SidecarControllerTests: DoctrineTestCase {

    func testNoOpSidecarControllerStopPostgresDoesNotThrow() async {
        let controller = NoOpSidecarController()
        do {
            try await controller.stopPostgres()
        } catch {
            XCTFail("NoOpSidecarController.stopPostgres must never throw: \(error)")
        }
    }

    func testNoOpSidecarControllerStopValkeyDoesNotThrow() async {
        let controller = NoOpSidecarController()
        do {
            try await controller.stopValkey()
        } catch {
            XCTFail("NoOpSidecarController.stopValkey must never throw: \(error)")
        }
    }

    // MARK: - TesseraDataLayerSidecarController with a nil data layer
    // (the "no data layer configured" path, per its doc comment: "closes
    // those pools" -- with nil there is nothing to close, so this must
    // also be a safe no-op).

    func testDataLayerSidecarControllerWithNilLayerDoesNotThrow() async {
        let controller = TesseraDataLayerSidecarController(dataLayer: nil)
        do {
            try await controller.stopPostgres()
            try await controller.stopValkey()
        } catch {
            XCTFail("a nil data layer must not cause stopPostgres/stopValkey to throw: \(error)")
        }
    }
}
