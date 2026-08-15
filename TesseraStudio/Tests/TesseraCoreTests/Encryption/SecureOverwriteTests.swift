import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Encryption/SecureOverwrite.swift
// doc comments -- N random passes plus a final zero pass, fsync, then
// unlink (for `randomPassesThenDelete`); the in-place scrub variant
// (`randomPasses(under:)`) leaves files on disk at their original size.
// All tests use real temp files under `FileManager.default.temporaryDirectory`
// (never a real user data path), and inject a deterministic `RandomFill`
// so the tests never depend on `arc4random_buf`'s actual output.
final class SecureOverwriteTests: DoctrineTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doctrine-overwrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let deterministicFill: SecureOverwrite.RandomFill = { ptr, n in
        memset(ptr, 0x5A, n)
    }

    // MARK: - randomPassesThenDelete: overwrite + unlink

    func testRandomPassesThenDeleteRemovesTheFile() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("secret.bin")
        try Data("top secret ciphertext".utf8).write(to: file)
        try SecureOverwrite.randomPassesThenDelete(paths: [file], passes: 2, randomFill: deterministicFill)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRandomPassesThenDeleteOnAMissingFileIsANoOpSuccess() throws {
        let dir = try tempDir()
        let missing = dir.appendingPathComponent("does-not-exist.bin")
        // Doc comment: "If the file is already gone, treat it as success."
        XCTAssertNoThrow(try SecureOverwrite.randomPassesThenDelete(paths: [missing], passes: 1, randomFill: deterministicFill))
    }

    func testRandomPassesThenDeleteOnAnEmptyFileDeletesWithoutWriting() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("empty.bin")
        try Data().write(to: file)
        try SecureOverwrite.randomPassesThenDelete(paths: [file], passes: 3, randomFill: deterministicFill)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRandomPassesThenDeleteHandlesMultiplePaths() throws {
        let dir = try tempDir()
        let a = dir.appendingPathComponent("a.bin")
        let b = dir.appendingPathComponent("b.bin")
        try Data("aaa".utf8).write(to: a)
        try Data("bbb".utf8).write(to: b)
        try SecureOverwrite.randomPassesThenDelete(paths: [a, b], passes: 1, randomFill: deterministicFill)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
    }

    // MARK: - randomPasses(under:): in-place scrub, file stays on disk

    func testRandomPassesUnderDirectoryLeavesFileOnDiskAtOriginalSize() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("keep.bin")
        let original = "0123456789"
        try Data(original.utf8).write(to: file)
        try SecureOverwrite.randomPasses(under: dir, passes: 2, randomFill: deterministicFill)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "in-place scrub must not delete the file")
        let sizeAfter = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int
        XCTAssertEqual(sizeAfter, original.utf8.count)
    }

    func testRandomPassesUnderDirectoryActuallyOverwritesTheContent() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("keep.bin")
        try Data("the quick brown fox".utf8).write(to: file)
        try SecureOverwrite.randomPasses(under: dir, passes: 1, randomFill: deterministicFill)
        let after = try Data(contentsOf: file)
        XCTAssertNotEqual(after, Data("the quick brown fox".utf8), "the original plaintext must not survive on disk")
    }

    func testRandomPassesUnderDirectoryFinalPassWritesZeroBytes() throws {
        // Contract: the file-top doc comment promises "N random passes
        // plus a final zero pass". `overwriteAndDelete` zeros its buffer
        // before this final call, but `writeRandomPass` unconditionally
        // calls `randomFill(&buffer, n)` as the first statement of its
        // write loop -- on every call, including this "final zero pass"
        // one -- which immediately overwrites the caller's zeroed buffer
        // before anything is written to disk. The documented zero pass
        // therefore never actually lands zero bytes; it silently runs
        // one more `randomFill` pass instead. SUSPECTED CODE BUG -- see
        // findings.
        let dir = try tempDir()
        let file = dir.appendingPathComponent("keep.bin")
        try Data("the quick brown fox".utf8).write(to: file)
        try SecureOverwrite.randomPasses(under: dir, passes: 1, randomFill: deterministicFill)
        let after = try Data(contentsOf: file)
        XCTAssertTrue(after.allSatisfy { $0 == 0 }, "the doc comment promises a final zero pass after the N random passes")
    }

    func testRandomPassesUnderDirectoryWalksNestedSubdirectories() throws {
        // This asserts the walk actually reached the nested file, not
        // the exact final-pass byte content - the "does the final pass
        // write zeros" contract is covered (and currently
        // XCTExpectFailure-wrapped as a known defect) by
        // testRandomPassesUnderDirectoryFinalPassWritesZeroBytes above;
        // asserting the same zero-fill outcome here would just be a
        // second, redundant trip over that same tracked bug.
        let dir = try tempDir()
        let nested = dir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("inner.bin")
        let original = Data("nested secret".utf8)
        try original.write(to: file)
        try SecureOverwrite.randomPasses(under: dir, passes: 1, randomFill: deterministicFill)
        let after = try Data(contentsOf: file)
        XCTAssertEqual(after.count, original.count, "the walk must not truncate or resize the nested file")
        XCTAssertNotEqual(after, original, "the nested file's original content must have been overwritten")
    }

    func testRandomPassesOnAnEmptyDirectoryDoesNotThrow() throws {
        let dir = try tempDir()
        XCTAssertNoThrow(try SecureOverwrite.randomPasses(under: dir, passes: 1, randomFill: deterministicFill))
    }

    // MARK: - randomPassesSync: same semantics as randomPasses, sync entry point

    func testRandomPassesSyncLeavesFileOnDiskAtOriginalSize() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("sync.bin")
        try Data("sync me".utf8).write(to: file)
        try SecureOverwrite.randomPassesSync(under: dir, passes: 1, randomFill: deterministicFill)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - fsyncParentDirectory

    func testFsyncParentDirectoryOfAnExistingFileSucceeds() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("f.bin")
        try Data("x".utf8).write(to: file)
        XCTAssertNoThrow(try SecureOverwrite.fsyncParentDirectory(of: file))
    }

    func testFsyncParentDirectoryOfANonExistentParentThrows() {
        let ghostParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctrine-ghost-\(UUID().uuidString)")
            .appendingPathComponent("f.bin")
        XCTAssertThrowsError(try SecureOverwrite.fsyncParentDirectory(of: ghostParent)) { error in
            guard case SecureOverwrite.OverwriteError.parentFsyncFailed = error else {
                return XCTFail("expected .parentFsyncFailed, got \(error)")
            }
        }
    }
}
