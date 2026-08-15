import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Encryption/TesseraVolumeMigrator.swift
// doc comments -- `Destination.init(volumeRoot:)`'s doc comment: "The
// three subdirectories mirror TesseraDataRoot's layout so the
// redirector's path resolution and the migrator's destination are
// guaranteed to agree."
//
// `migrate(into:from:onProgress:)` requires a real `TesseraEncryptedVolume`
// (hdiutil-backed, not protocol-abstracted) and its copy/verify/wipe
// helpers are `private` (inaccessible even via `@testable import`), so
// the end-to-end migration flow is out of reach for a fast, safe,
// non-hdiutil-shelling test in this pass -- see openQuestions. This file
// covers the pure, public value types: `Report`, `Source`, `Destination`.
final class TesseraVolumeMigratorTests: DoctrineTestCase {

    func testDestinationDerivesTheThreeSubdirectoriesFromTheVolumeRoot() {
        let root = URL(fileURLWithPath: "/Volumes/TesseraVault")
        let destination = TesseraVolumeMigrator.Destination(volumeRoot: root)
        XCTAssertEqual(destination.volumeRoot, root)
        XCTAssertEqual(destination.appSupport, root.appendingPathComponent("Library/Application Support/TesseraStudio", isDirectory: true))
        XCTAssertEqual(destination.caches, root.appendingPathComponent("Library/Caches/TesseraStudio", isDirectory: true))
        XCTAssertEqual(destination.preferences, root.appendingPathComponent("Library/Preferences", isDirectory: true))
    }

    func testDestinationSubdirectoriesMirrorTesseraDataRootsLayout() {
        // The doc comment's explicit invariant: the migrator's
        // destination and the redirector's mounted-volume paths must
        // agree, since both derive the same relative subpaths under a
        // volume root.
        let root = URL(fileURLWithPath: "/tmp/doctrine-volume-\(UUID().uuidString)")
        var restoreMountedRoot: URL?
        restoreMountedRoot = TesseraDataRoot.mountedRoot()
        TesseraDataRoot.setMountedRoot(root)
        defer { TesseraDataRoot.setMountedRoot(restoreMountedRoot) }

        let destination = TesseraVolumeMigrator.Destination(volumeRoot: root)
        XCTAssertEqual(destination.appSupport, TesseraDataRoot.appSupport())
        XCTAssertEqual(destination.caches, TesseraDataRoot.caches())
        XCTAssertEqual(destination.preferences, TesseraDataRoot.preferences())
    }

    func testSourceCarriesTheThreeInjectedRoots() {
        let source = TesseraVolumeMigrator.Source(
            appSupport: URL(fileURLWithPath: "/tmp/a"),
            caches: URL(fileURLWithPath: "/tmp/c"),
            preferences: URL(fileURLWithPath: "/tmp/p")
        )
        XCTAssertEqual(source.appSupport, URL(fileURLWithPath: "/tmp/a"))
        XCTAssertEqual(source.caches, URL(fileURLWithPath: "/tmp/c"))
        XCTAssertEqual(source.preferences, URL(fileURLWithPath: "/tmp/p"))
    }

    func testReportEquality() {
        let a = TesseraVolumeMigrator.Report(copiedFiles: 3, copiedBytes: 100, originalBytesOverwritten: 100, duration: 1.2, verified: true)
        let b = TesseraVolumeMigrator.Report(copiedFiles: 3, copiedBytes: 100, originalBytesOverwritten: 100, duration: 1.2, verified: true)
        let c = TesseraVolumeMigrator.Report(copiedFiles: 4, copiedBytes: 100, originalBytesOverwritten: 100, duration: 1.2, verified: true)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testMigratorIsConstructibleWithNoArguments() {
        _ = TesseraVolumeMigrator()
    }
}
