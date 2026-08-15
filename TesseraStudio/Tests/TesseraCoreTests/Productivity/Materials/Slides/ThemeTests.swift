import XCTest
@testable import TesseraCore

/// `Theme` / `ColorRef` (P1 1.5): the OOXML 12-slot color vocabulary
/// + major/minor fonts, and the `.literal` | `.theme(slot, tint)`
/// split that keeps `InlineRun` colors literal at P1. Async
/// `ThemeStore` mutations aren't exercised here - see
/// `ThemeStoreTests`'s doc comment (same scoping as
/// `MasterPageStoreTests`/`SlideMasterPageTests`): this file pins the
/// mutation LOGIC at the pure-model level via `SlideDeck`'s own
/// `settingTheme(_:)`/`settingActiveThemeID(_:)`.
final class ThemeTests: XCTestCase {

    // MARK: - resolve(_:)

    func testLiteralResolvesAsIs() {
        let theme = Theme(name: "Corporate")
        XCTAssertEqual(theme.resolve(.literal("#ABCDEF")), "#ABCDEF")
    }

    func testThemeSlotResolvesCustomColorAtZeroTint() {
        let theme = Theme(name: "Corporate", colors: [.accent1: "#123456"])
        XCTAssertEqual(theme.resolve(.theme(slot: .accent1, tint: 0)), "#123456")
    }

    func testUnsetSlotFallsBackToBuiltinDefault() {
        let theme = Theme(name: "Corporate")
        XCTAssertEqual(
            theme.resolve(.theme(slot: .accent1, tint: 0)),
            Theme.builtinDefault(for: .accent1)
        )
    }

    /// The test contract's own scenario: swapping which `Theme` a
    /// `.theme` reference resolves against changes the resolved
    /// color.
    func testThemeSwapChangesResolvedColor() {
        let before = Theme(name: "Before", colors: [.accent1: "#111111"])
        let after = Theme(name: "After", colors: [.accent1: "#222222"])
        let ref = ColorRef.theme(slot: .accent1, tint: 0)
        XCTAssertEqual(before.resolve(ref), "#111111")
        XCTAssertEqual(after.resolve(ref), "#222222")
        XCTAssertNotEqual(before.resolve(ref), after.resolve(ref))
    }

    func testFullPositiveTintLightensToWhite() {
        let theme = Theme(name: "Corporate", colors: [.accent1: "#334455"])
        XCTAssertEqual(theme.resolve(.theme(slot: .accent1, tint: 1)), "#FFFFFF")
    }

    func testFullNegativeTintDarkensToBlack() {
        let theme = Theme(name: "Corporate", colors: [.accent1: "#334455"])
        XCTAssertEqual(theme.resolve(.theme(slot: .accent1, tint: -1)), "#000000")
    }

    func testZeroTintIsExactPassthroughNotARoundTrippedReparse() {
        let theme = Theme(name: "Corporate", colors: [.accent1: "#aabbcc"])
        XCTAssertEqual(theme.resolve(.theme(slot: .accent1, tint: 0)), "#aabbcc")
    }

    func testTintIsClampedBeyondFullRange() {
        let theme = Theme(name: "Corporate", colors: [.accent1: "#334455"])
        XCTAssertEqual(theme.resolve(.theme(slot: .accent1, tint: 5)), "#FFFFFF")
        XCTAssertEqual(theme.resolve(.theme(slot: .accent1, tint: -5)), "#000000")
    }

    // MARK: - ColorRef literal convenience

    func testColorRefExpressibleByStringLiteral() {
        let ref: ColorRef = "#665544"
        XCTAssertEqual(ref, .literal("#665544"))
    }

    // MARK: - Codable round trip

    func testThemeRoundTripsThroughJSON() throws {
        let theme = Theme(
            id: UUID(), name: "Corporate",
            colors: [.dk1: "#000000", .accent1: "#4472C4"],
            majorFont: "Georgia", minorFont: "Verdana"
        )
        let data = try JSONEncoder().encode(theme)
        let restored = try JSONDecoder().decode(Theme.self, from: data)
        XCTAssertEqual(restored, theme)
    }

    func testColorRefRoundTripsThroughJSON() throws {
        let refs: [ColorRef] = [.literal("#FFAA00"), .theme(slot: .accent3, tint: -0.5)]
        for ref in refs {
            let data = try JSONEncoder().encode(ref)
            let restored = try JSONDecoder().decode(ColorRef.self, from: data)
            XCTAssertEqual(restored, ref)
        }
    }

    // MARK: - SlideMasterPage / SlideDeck integration

    func testMasterPageBackgroundAcceptsLiteralHexAsBefore() {
        // Source-compat with P0 call sites, via ExpressibleByStringLiteral.
        let master = SlideMasterPage(name: "Dark", backgroundColorHex: "#111111")
        XCTAssertEqual(master.backgroundColorHex, .literal("#111111"))
    }

    func testDeckHasNoThemesUntilOneIsDefined() {
        let deck = SlideDeck.makeBlank(title: "Deck")
        XCTAssertTrue(deck.effectiveThemes.isEmpty)
        XCTAssertNil(deck.activeTheme)
    }

    func testSettingThemeAddsItToTheCatalogOnEveryMasterPage() {
        var deck = SlideDeck.makeBlank(title: "Deck")
        deck = deck.settingMasterPage(SlideMasterPage(name: "Master A"))
        deck = deck.settingMasterPage(SlideMasterPage(name: "Master B"))
        let theme = Theme(name: "Corporate", colors: [.accent1: "#4472C4"])

        deck = deck.settingTheme(theme)

        XCTAssertEqual(deck.effectiveThemes.count, 1)
        XCTAssertEqual(deck.effectiveThemes[theme.id.uuidString]?.name, "Corporate")
        XCTAssertEqual(deck.effectiveMasterPages.count, 2)
        for master in deck.effectiveMasterPages.values {
            XCTAssertEqual(master.themeCatalog?[theme.id.uuidString]?.name, "Corporate")
        }
    }

    func testSettingWithAnExistingThemeIDReplacesRatherThanDuplicates() {
        var deck = SlideDeck.makeBlank(title: "Deck")
        deck = deck.settingMasterPage(SlideMasterPage(name: "Master A"))
        let theme = Theme(name: "Corporate")
        deck = deck.settingTheme(theme)
        let renamed = Theme(id: theme.id, name: "Corporate Renamed")

        deck = deck.settingTheme(renamed)

        XCTAssertEqual(deck.effectiveThemes.count, 1)
        XCTAssertEqual(deck.effectiveThemes[theme.id.uuidString]?.name, "Corporate Renamed")
    }

    func testSettingActiveThemeIDResolvesThroughTheCatalog() {
        var deck = SlideDeck.makeBlank(title: "Deck")
        deck = deck.settingMasterPage(SlideMasterPage(name: "Master A"))
        let theme = Theme(name: "Corporate", colors: [.accent1: "#4472C4"])
        deck = deck.settingTheme(theme)

        deck = deck.settingActiveThemeID(theme.id)

        XCTAssertEqual(deck.activeThemeID, theme.id)
        XCTAssertEqual(deck.activeTheme?.id, theme.id)
    }

    func testClearingActiveThemeIDResolvesToNil() {
        var deck = SlideDeck.makeBlank(title: "Deck")
        deck = deck.settingMasterPage(SlideMasterPage(name: "Master A"))
        let theme = Theme(name: "Corporate")
        deck = deck.settingTheme(theme).settingActiveThemeID(theme.id)
        XCTAssertNotNil(deck.activeTheme)

        deck = deck.settingActiveThemeID(nil)

        XCTAssertNil(deck.activeThemeID)
        XCTAssertNil(deck.activeTheme)
    }

    func testActiveThemeIsNilWhenTheIDNoLongerResolves() {
        var deck = SlideDeck.makeBlank(title: "Deck")
        deck = deck.settingMasterPage(SlideMasterPage(name: "Master A"))
        deck = deck.settingActiveThemeID(UUID())
        XCTAssertNil(deck.activeTheme, "a dangling id resolves to no active theme, not a crash")
    }

    // MARK: - Theme swap never rewrites block bodies (design contract's
    // own test requirement)

    /// "theme swap changes resolved colors while every block body's
    /// jsonData() is byte-identical" - `InlineRun` colors are plain
    /// literal hex strings (`InlineRun.Annotation.color(hex:)`), not
    /// `ColorRef`, so nothing about a block changes when the deck's
    /// theme changes.
    func testThemeSwapNeverTouchesBlockBodyJSON() throws {
        let run = InlineRun(text: "Hello", annotations: [.color(hex: "#ABCDEF")])
        let blockID = UUID()
        let block = Block(id: blockID, type: .paragraph, content: [run])
        let ast = DocumentAST(blocks: [blockID: block], rootChildren: [blockID])
        var deck = SlideDeck(title: "Deck", body: ast)
        let before = try deck.body.jsonData()

        deck = deck.settingMasterPage(SlideMasterPage(name: "Master A"))
        let themeA = Theme(name: "A", colors: [.accent1: "#111111"])
        let themeB = Theme(name: "B", colors: [.accent1: "#222222"])
        deck = deck.settingTheme(themeA).settingActiveThemeID(themeA.id)
        deck = deck.settingTheme(themeB).settingActiveThemeID(themeB.id)

        let after = try deck.body.jsonData()
        XCTAssertEqual(
            before, after,
            "InlineRun colors stay literal - a theme swap must not rewrite block bodies"
        )
        // Sanity: the swap actually changed what a theme-relative color resolves to.
        let ref = ColorRef.theme(slot: .accent1, tint: 0)
        XCTAssertNotEqual(themeA.resolve(ref), themeB.resolve(ref))
    }
}
