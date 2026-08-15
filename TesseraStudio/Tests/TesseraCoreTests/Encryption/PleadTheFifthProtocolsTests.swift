import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Encryption/PleadTheFifthTrigger.swift
// and Sources/TesseraCore/Encryption/PleadTheFifthVolume.swift doc
// comments. Both are narrow seam protocols with no default
// implementations; this file exercises them via minimal recording mocks
// (the doc comment on `PleadTheFifthTrigger` explicitly names this
// pattern: "The test mock RecordingPleadTheFifthTrigger also conforms so
// the trigger logic is unit-testable in isolation").
final class PleadTheFifthProtocolsTests: DoctrineTestCase {

    // MARK: - PleadTheFifthTriggerSource: exhaustive categorical set
    // (independent oracle, rule 7)

    func testTriggerSourceHasTheThreeDocumentedCases() {
        let expected: Set<String> = ["hotkey", "menu", "covert"]
        let actual: Set<String> = [
            PleadTheFifthTriggerSource.hotkey.rawValue,
            PleadTheFifthTriggerSource.menu.rawValue,
            PleadTheFifthTriggerSource.covert.rawValue,
        ]
        XCTAssertEqual(actual, expected)
    }

    // MARK: - PleadTheFifthTrigger: a mock conformer records fire calls

    private actor RecordingTrigger: PleadTheFifthTrigger {
        private(set) var fired: [PleadTheFifthTriggerSource] = []
        func fire(trigger: PleadTheFifthTriggerSource) async throws {
            fired.append(trigger)
        }
    }

    func testMockTriggerRecordsTheSourceItWasFiredWith() async throws {
        let trigger = RecordingTrigger()
        try await trigger.fire(trigger: .hotkey)
        let fired = await trigger.fired
        XCTAssertEqual(fired, [.hotkey])
    }

    func testMockTriggerRecordsMultipleFiresInOrder() async throws {
        let trigger = RecordingTrigger()
        try await trigger.fire(trigger: .menu)
        try await trigger.fire(trigger: .covert)
        let fired = await trigger.fired
        XCTAssertEqual(fired, [.menu, .covert])
    }

    // MARK: - PleadTheFifthVolume: a mock conformer supplies the three
    // seams the executor needs (unmount, isMounted, encryptedArtifacts)

    private actor MockVolume: PleadTheFifthVolume {
        private var mounted: Bool
        var artifacts: [URL]
        private(set) var unmountCallCount = 0

        init(mounted: Bool, artifacts: [URL] = []) {
            self.mounted = mounted
            self.artifacts = artifacts
        }

        func unmount() async throws {
            unmountCallCount += 1
            mounted = false
        }

        func isMounted() async -> Bool { mounted }
        var encryptedArtifacts: [URL] { get async { artifacts } }
    }

    func testMockVolumeReflectsMountedStateBeforeAndAfterUnmount() async throws {
        let volume = MockVolume(mounted: true)
        let before = await volume.isMounted()
        XCTAssertTrue(before)
        try await volume.unmount()
        let after = await volume.isMounted()
        XCTAssertFalse(after)
    }

    func testMockVolumeExposesEncryptedArtifacts() async {
        let artifact = URL(fileURLWithPath: "/tmp/doctrine-fake-vault.sparsebundle")
        let volume = MockVolume(mounted: true, artifacts: [artifact])
        let artifacts = await volume.encryptedArtifacts
        XCTAssertEqual(artifacts, [artifact])
    }
}
