import XCTest
@testable import TesseraCore

// MARK: - EditorModeTests
//
// Contract: EditorMode.swift's own doc comments - `isCodeMode`: "case
// .code, .codeWithConfig: return true"; `CodeEditorConfiguration.default`'s
// documented defaults ("Line numbers on... syntax highlighting on...
// folding on... multi-cursor on... find-in-file on... minimap off by
// default"); `EditorTheme.current(isDark:)` picks `.dark`/`.light`.

final class EditorModeTests: DoctrineTestCase {

    // MARK: - isCodeMode

    func testIsCodeModeTrueOnlyForCodeAndCodeWithConfig() {
        XCTAssertTrue(EditorMode.code.isCodeMode)
        XCTAssertTrue(EditorMode.codeWithConfig.isCodeMode)
        XCTAssertFalse(EditorMode.document.isCodeMode)
        XCTAssertFalse(EditorMode.notes.isCodeMode)
        XCTAssertFalse(EditorMode.sheets.isCodeMode)
    }

    // MARK: - CodeEditorConfiguration.default documented defaults

    func testCodeEditorConfigurationDefaultMatchesTheDocumentedDefaults() {
        let config = CodeEditorConfiguration.default
        XCTAssertTrue(config.showLineNumbers, "line numbers on by default - the design doc calls this non-negotiable for code")
        XCTAssertTrue(config.codeFolding)
        XCTAssertTrue(config.multiCursor)
        XCTAssertTrue(config.findInFile)
        XCTAssertFalse(config.minimap, "minimap is off by default, opt-in per the design doc")
        XCTAssertNil(config.syntaxHighlightingLanguage)
    }

    func testEditorModeCodeDefaultMatchesCodeEditorConfigurationDefault() {
        XCTAssertEqual(EditorMode.codeDefault, CodeEditorConfiguration.default)
    }

    // MARK: - EditorTheme.current(isDark:)

    func testEditorThemeCurrentPicksDarkOrLightBySystemAppearance() {
        XCTAssertEqual(EditorTheme.current(isDark: true), EditorTheme.dark)
        XCTAssertEqual(EditorTheme.current(isDark: false), EditorTheme.light)
    }

    func testLightAndDarkThemesAreDistinctValues() {
        XCTAssertNotEqual(EditorTheme.light, EditorTheme.dark)
    }

    // MARK: - FontDescriptor factory methods

    func testFontDescriptorSystemFactorySetsSystemFamily() {
        let descriptor = FontDescriptor.system(size: 14, weight: .bold)
        XCTAssertEqual(descriptor.family, .system)
        XCTAssertEqual(descriptor.size, 14)
        XCTAssertEqual(descriptor.weight, .bold)
        XCTAssertFalse(descriptor.italic)
    }

    func testFontDescriptorMonospaceFactorySetsMonospaceFamily() {
        let descriptor = FontDescriptor.monospace(size: 13)
        XCTAssertEqual(descriptor.family, .monospace)
        XCTAssertEqual(descriptor.weight, .regular, "default weight when unspecified")
    }

    // MARK: - Round-trip identity (doctrine rule 2)

    func testEditorModeEncodeDecodeIdentityEveryCase() throws {
        for mode in EditorMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(EditorMode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }

    func testEditorThemeEncodeDecodeIdentity() throws {
        let data = try JSONEncoder().encode(EditorTheme.dark)
        let decoded = try JSONDecoder().decode(EditorTheme.self, from: data)
        XCTAssertEqual(decoded, EditorTheme.dark)
    }

    // MARK: - CaseIterable totality (independent oracle)

    func testEditorModeCaseIterableMatchesThePinnedList() {
        let expected: Set<String> = ["document", "notes", "code", "codeWithConfig", "sheets"]
        XCTAssertEqual(Set(EditorMode.allCases.map(\.rawValue)), expected)
    }
}
