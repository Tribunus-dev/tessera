import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Code/CodeFile.swift
// doc comments (languageForExtension's exhaustive mapping table,
// computeChecksum's "sha256:<hex>" format, filenameFromPath) plus
// docs/tessera-productivity-materials-code-design.md section 3
// (CodeFile model + language detection table).

final class CodeFileTests: DoctrineTestCase {

    private func makeFile(
        id: UUID = UUID(),
        path: String = "/repo/Sources/Foo.swift",
        body: String = "let x = 1\n"
    ) -> CodeFile {
        CodeFile(id: id, path: path, body: body)
    }

    // MARK: - Round-trip identity (doctrine rule 2)

    func testJSONEncodeDecodeRoundTripPreservesEveryField() throws {
        let original = CodeFile(
            path: "/repo/Sources/Foo.swift",
            body: "let x = 1\n",
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            linkedEntityIDs: [UUID()],
            tags: ["core"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decoded = try CodeFile.from(jsonData: original.jsonData())
        XCTAssertEqual(decoded, original)
    }

    func testByteIdenticalReEncodeIsDeterministic() throws {
        let file = makeFile()
        XCTAssertEqual(try file.jsonData(), try file.jsonData())
    }

    // MARK: - entityType / unknownLanguage pins

    func testEntityTypeIsPinnedToCode() {
        XCTAssertEqual(CodeFile.entityType, "code")
    }

    func testUnknownLanguageIsPinnedToPlain() {
        XCTAssertEqual(CodeFile.unknownLanguage, "plain")
    }

    // MARK: - filenameFromPath

    func testFilenameFromPathReturnsLastComponent() {
        XCTAssertEqual(CodeFile.filenameFromPath("/repo/Sources/Foo.swift"), "Foo.swift")
    }

    func testFilenameFromPathFallsBackToWholeStringForEmptyLastComponent() {
        let result = CodeFile.filenameFromPath("")
        XCTExpectFailure("SUSPECTED CODE BUG: filenameFromPath('')'s own fallback ternary (url.lastPathComponent.isEmpty ? path : url.lastPathComponent) is clearly written to handle a degenerate empty path by returning the original path - but URL(fileURLWithPath: \"\") resolves relative to the PROCESS'S CURRENT WORKING DIRECTORY rather than producing an empty URL, so lastPathComponent is never actually empty for this input; it returns the CWD's own directory name instead, making the function's result depend on the working directory it happens to run in - see findings") {
            XCTAssertEqual(result, "", "an empty path must fall back to the empty string, not whatever directory the process happens to be running in")
        }
    }

    // MARK: - Language detection (independent oracle: the exact extension
    // table from the design doc section 3, not derived from re-reading
    // the switch statement's case list back)

    func testLanguageForExtensionCoversTheDesignDocsTable() {
        let expected: [String: String] = [
            "swift": "swift", "py": "python", "pyi": "python",
            "js": "javascript", "mjs": "javascript", "cjs": "javascript",
            "ts": "typescript", "tsx": "typescript", "jsx": "typescript",
            "sql": "sql", "json": "json", "yaml": "yaml", "yml": "yaml",
            "md": "markdown", "markdown": "markdown",
            "sh": "shell", "bash": "shell", "zsh": "shell",
            "rs": "rust", "go": "go", "c": "c", "h": "c",
            "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hxx": "cpp",
            "rb": "ruby", "java": "java", "kt": "kotlin", "kts": "kotlin",
            "scala": "scala", "sc": "scala", "hs": "haskell", "lua": "lua",
            "ex": "elixir", "exs": "elixir", "r": "r", "m": "matlab",
            "dockerfile": "dockerfile", "mk": "makefile", "makefile": "makefile",
            "toml": "toml", "xml": "xml", "html": "html", "htm": "html",
            "css": "css", "scss": "scss", "sass": "scss", "vue": "vue",
            "svelte": "svelte", "proto": "protobuf", "graphql": "graphql",
            "gql": "graphql", "dart": "dart", "swiftinterface": "swift",
        ]
        for (ext, language) in expected {
            XCTAssertEqual(CodeFile.languageForExtension(ext), language, "extension .\(ext)")
        }
    }

    func testLanguageForExtensionReturnsNilForUnknownExtension() {
        XCTAssertNil(CodeFile.languageForExtension("xyz"))
    }

    func testDetectLanguageForPathUsesTheExtensionTable() {
        XCTAssertEqual(CodeFile.detectLanguage(forPath: "/repo/Foo.swift"), "swift")
    }

    func testDetectLanguageForPathFallsBackToUnknownLanguage() {
        XCTAssertEqual(CodeFile.detectLanguage(forPath: "/repo/Foo.xyz"), CodeFile.unknownLanguage)
    }

    func testInitInfersLanguageWhenNotProvided() {
        let file = CodeFile(path: "/repo/Foo.py", body: "x = 1")
        XCTAssertEqual(file.language, "python")
        XCTAssertEqual(file.subtypeString, "python")
    }

    // MARK: - hasKnownLanguage

    func testHasKnownLanguageTrueForRecognizedExtension() {
        XCTAssertTrue(makeFile(path: "/repo/Foo.swift").hasKnownLanguage)
    }

    func testHasKnownLanguageFalseForUnknownExtension() {
        XCTAssertFalse(makeFile(path: "/repo/Foo.xyz").hasKnownLanguage)
    }

    // MARK: - Checksum (fixture + property, doctrine rule 9)

    func testComputeChecksumHasSha256Prefix() {
        let checksum = CodeFile.computeChecksum(of: "let x = 1\n")
        XCTAssertTrue(checksum.hasPrefix("sha256:"))
    }

    func testComputeChecksumIsDeterministicForTheSameBody() {
        let a = CodeFile.computeChecksum(of: "let x = 1\n")
        let b = CodeFile.computeChecksum(of: "let x = 1\n")
        XCTAssertEqual(a, b)
    }

    func testComputeChecksumDiffersForDifferentBodies() {
        let a = CodeFile.computeChecksum(of: "let x = 1\n")
        let b = CodeFile.computeChecksum(of: "let x = 2\n")
        XCTAssertNotEqual(a, b)
    }

    func testComputeChecksumOfEmptyStringMatchesKnownSha256() {
        // SHA-256("") is a well-known constant; this is an independent
        // oracle, not derived from the implementation.
        let checksum = CodeFile.computeChecksum(of: "")
        XCTAssertEqual(
            checksum,
            "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testInitComputesChecksumWhenNotProvided() {
        let file = CodeFile(path: "/repo/Foo.swift", body: "let x = 1\n")
        XCTAssertEqual(file.checksum, CodeFile.computeChecksum(of: "let x = 1\n"))
    }

    func testBodyMatchesChecksumTrueForTheFilesOwnChecksum() {
        let file = makeFile(body: "let x = 1\n")
        XCTAssertTrue(file.bodyMatches(checksum: file.checksum))
    }

    func testBodyMatchesChecksumFalseForAMismatchedChecksum() {
        let file = makeFile(body: "let x = 1\n")
        XCTAssertFalse(file.bodyMatches(checksum: "sha256:0000000000000000000000000000000000000000000000000000000000000"))
    }

    // MARK: - size defaulting

    func testInitComputesSizeFromBodyUTF8ByteCountWhenNotProvided() {
        let file = CodeFile(path: "/repo/Foo.swift", body: "abc")
        XCTAssertEqual(file.size, 3)
    }
}
