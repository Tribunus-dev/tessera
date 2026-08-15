import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Encryption/TesseraDataRoot.swift
// doc comments -- "While the encrypted volume is mounted, every data
// path is rooted at the volume's mount point. When the volume is not
// mounted... the redirector falls back to the original sandbox path."
//
// `TesseraDataRoot` is a global path resolver backed by process-wide
// mutable state. `setMountedRoot(_:)` has a clean unset path (`nil`),
// captured/restored in setUp/tearDown below. `setSandboxRoot(_:for:)`
// does NOT: the source exposes no reset/unset API for the three
// per-kind overrides once set (see `_appSupportSandboxOverride` and
// siblings), only the documented "point it at a tmp directory" setter.
// The doc comment on `sandboxRoot(for:)` calls this exact override the
// "documented test-only seam", so this file still exercises it (the
// fallback-to-sandbox contract is real and worth pinning), using inert
// `/tmp/doctrine-*` placeholder paths only -- never a real data
// location -- but the override DOES leak for the remainder of the
// `swift test` process once set. Logged in the findings file as a
// known, source-side limitation (no reset API exists to fix from the
// test side) rather than worked around silently.
final class TesseraDataRootTests: DoctrineTestCase {

    private var savedMountedRoot: URL?

    override func setUp() {
        super.setUp()
        savedMountedRoot = TesseraDataRoot.mountedRoot()
        TesseraDataRoot.setMountedRoot(nil)
    }

    override func tearDown() {
        TesseraDataRoot.setMountedRoot(savedMountedRoot)
        super.tearDown()
    }

    // MARK: - Unmounted: falls back to the sandbox root

    func testAppSupportFallsBackToSandboxRootWhenNotMounted() {
        let sandbox = URL(fileURLWithPath: "/tmp/doctrine-sandbox-\(UUID().uuidString)")
        TesseraDataRoot.setSandboxRoot(sandbox, for: .appSupport)
        let resolved = TesseraDataRoot.appSupport()
        XCTAssertEqual(resolved.path, sandbox.appendingPathComponent("Library/Application Support/TesseraStudio", isDirectory: true).path)
    }

    func testAppSupportStoreFileAppendsDefaultStoreToAppSupport() {
        let sandbox = URL(fileURLWithPath: "/tmp/doctrine-sandbox-\(UUID().uuidString)")
        TesseraDataRoot.setSandboxRoot(sandbox, for: .appSupport)
        XCTAssertEqual(TesseraDataRoot.appSupportStoreFile().lastPathComponent, "default.store")
    }

    func testCachesFallsBackToSandboxCachesRoot() {
        let sandbox = URL(fileURLWithPath: "/tmp/doctrine-caches-\(UUID().uuidString)")
        TesseraDataRoot.setSandboxRoot(sandbox, for: .caches)
        let resolved = TesseraDataRoot.caches()
        XCTAssertEqual(resolved.path, sandbox.appendingPathComponent("Library/Caches/TesseraStudio", isDirectory: true).path)
    }

    func testPreferencesFallsBackToSandboxPreferencesRoot() {
        let sandbox = URL(fileURLWithPath: "/tmp/doctrine-prefs-\(UUID().uuidString)")
        TesseraDataRoot.setSandboxRoot(sandbox, for: .preferences)
        let resolved = TesseraDataRoot.preferences()
        XCTAssertEqual(resolved.path, sandbox.appendingPathComponent("Library/Preferences", isDirectory: true).path)
    }

    func testIsUsingEncryptedVolumeIsFalseWhenNotMounted() {
        XCTAssertFalse(TesseraDataRoot.isUsingEncryptedVolume())
    }

    // MARK: - Mounted: every path roots at the volume mount point

    func testAllDataPathsRootAtTheMountedVolumeWhenMounted() {
        let mount = URL(fileURLWithPath: "/tmp/doctrine-volume-\(UUID().uuidString)")
        TesseraDataRoot.setMountedRoot(mount)
        XCTAssertEqual(TesseraDataRoot.appSupport().path, mount.appendingPathComponent("Library/Application Support/TesseraStudio", isDirectory: true).path)
        XCTAssertEqual(TesseraDataRoot.caches().path, mount.appendingPathComponent("Library/Caches/TesseraStudio", isDirectory: true).path)
        XCTAssertEqual(TesseraDataRoot.preferences().path, mount.appendingPathComponent("Library/Preferences", isDirectory: true).path)
        XCTAssertEqual(TesseraDataRoot.postgresDataDir().path, mount.appendingPathComponent("postgres/data", isDirectory: true).path)
        XCTAssertEqual(TesseraDataRoot.valkeyDataDir().path, mount.appendingPathComponent("valkey/data", isDirectory: true).path)
        XCTAssertEqual(TesseraDataRoot.duckdbFile().path, mount.appendingPathComponent("duckdb", isDirectory: true).appendingPathComponent("tessera.duckdb").path)
    }

    func testIsUsingEncryptedVolumeIsTrueWhenMounted() {
        TesseraDataRoot.setMountedRoot(URL(fileURLWithPath: "/tmp/doctrine-mounted"))
        XCTAssertTrue(TesseraDataRoot.isUsingEncryptedVolume())
    }

    func testClearingTheMountedRootFallsBackToTheSandboxAgain() {
        let sandbox = URL(fileURLWithPath: "/tmp/doctrine-sandbox-\(UUID().uuidString)")
        TesseraDataRoot.setSandboxRoot(sandbox, for: .appSupport)
        TesseraDataRoot.setMountedRoot(URL(fileURLWithPath: "/tmp/doctrine-mounted"))
        XCTAssertTrue(TesseraDataRoot.appSupport().path.hasPrefix("/tmp/doctrine-mounted"))
        TesseraDataRoot.setMountedRoot(nil)
        XCTAssertEqual(TesseraDataRoot.appSupport().path, sandbox.appendingPathComponent("Library/Application Support/TesseraStudio", isDirectory: true).path)
    }

    func testMountedRootAccessorReflectsWhatWasSet() {
        let mount = URL(fileURLWithPath: "/tmp/doctrine-mounted-accessor")
        TesseraDataRoot.setMountedRoot(mount)
        XCTAssertEqual(TesseraDataRoot.mountedRoot(), mount)
        TesseraDataRoot.setMountedRoot(nil)
        XCTAssertNil(TesseraDataRoot.mountedRoot())
    }

    func testDuckdbFileNameIsTesseraDuckdb() {
        let mount = URL(fileURLWithPath: "/tmp/doctrine-volume-2")
        TesseraDataRoot.setMountedRoot(mount)
        XCTAssertEqual(TesseraDataRoot.duckdbFile().lastPathComponent, "tessera.duckdb")
    }
}
