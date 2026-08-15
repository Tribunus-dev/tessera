import XCTest
import Foundation
@testable import TesseraCore

// MARK: - ThemeTests
//
// Contract source: Theme.swift's own doc comments (studio-expansion-
// design-refinement-2026-08-14.md section 4, Slides cluster, item 1.5):
// the OOXML 12-slot color vocabulary verbatim; ColorRef.literal returns
// its string as-is; ColorRef.theme resolves against the theme's own
// colors dict, falling back to builtinDefault(for:) when unset, blended
// toward black/white by tint; tint==0 returns the base hex untouched.

final class ThemeTests: DoctrineTestCase {

    // MARK: - 12-slot vocabulary (independent oracle, rule 7 / rule 5 trap)

    func testThemeColorSlotHasExactlyTheOOXMLTwelveSlotVocabulary() {
        // Hardcoded from the OOXML clrScheme spec (ECMA-376 §20.1.6.2)
        // / the refinement doc's own list, NOT derived from
        // ThemeColorSlot.allCases itself (rule 7).
        let expected: Set<String> = [
            "dk1", "lt1", "dk2", "lt2",
            "accent1", "accent2", "accent3", "accent4", "accent5", "accent6",
            "hlink", "folHlink",
        ]
        let actual = Set(ThemeColorSlot.allCases.map(\.rawValue))
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(ThemeColorSlot.allCases.count, 12)
    }

    // MARK: - ColorRef.literal

    func testLiteralColorRefResolvesToItsOwnStringUnchanged() {
        let theme = Theme(name: "T")
        XCTAssertEqual(theme.resolve(.literal("#123456")), "#123456")
    }

    func testColorRefIsExpressibleByStringLiteralAsLiteral() {
        let ref: ColorRef = "#ABCDEF"
        XCTAssertEqual(ref, .literal("#ABCDEF"))
    }

    // MARK: - ColorRef.theme - fixtures (hand-computed against the blend formula)

    func testThemeSlotWithTintZeroResolvesToTheStoredHexUnchanged() {
        let theme = Theme(name: "T", colors: [.accent1: "#336699"])
        XCTAssertEqual(theme.resolve(.theme(slot: .accent1, tint: 0)), "#336699")
    }

    func testThemeSlotWithTintOneBlendsFullyToWhite() {
        let theme = Theme(name: "T", colors: [.accent1: "#336699"])
        // amount=1, target=1 (white): every channel -> 255 -> #FFFFFF.
        XCTAssertEqual(theme.resolve(.theme(slot: .accent1, tint: 1)), "#FFFFFF")
    }

    func testThemeSlotWithTintNegativeOneBlendsFullyToBlack() {
        let theme = Theme(name: "T", colors: [.accent1: "#336699"])
        XCTAssertEqual(theme.resolve(.theme(slot: .accent1, tint: -1)), "#000000")
    }

    func testThemeSlotWithTintHalfBlendsHalfwayTowardWhite() {
        // #000000 blended 50% toward white -> #808080 (0 + (255-0)*0.5 = 127.5 -> rounds to 128 = 0x80).
        let theme = Theme(name: "T", colors: [.accent1: "#000000"])
        XCTAssertEqual(theme.resolve(.theme(slot: .accent1, tint: 0.5)), "#808080")
    }

    func testThemeSlotWithTintClampsBeyondPlusMinusOne() {
        let theme = Theme(name: "T", colors: [.accent1: "#000000"])
        XCTAssertEqual(theme.resolve(.theme(slot: .accent1, tint: 5)), theme.resolve(.theme(slot: .accent1, tint: 1)))
        XCTAssertEqual(theme.resolve(.theme(slot: .accent1, tint: -5)), theme.resolve(.theme(slot: .accent1, tint: -1)))
    }

    func testUnsetSlotFallsBackToBuiltinDefault() {
        let theme = Theme(name: "T", colors: [:])
        XCTAssertEqual(theme.resolve(.theme(slot: .accent1, tint: 0)), Theme.builtinDefault(for: .accent1))
    }

    func testEveryBuiltinDefaultIsAWellFormedSixOrEightDigitHex() {
        for slot in ThemeColorSlot.allCases {
            let hex = Theme.builtinDefault(for: slot)
            XCTAssertTrue(hex.hasPrefix("#"))
            XCTAssertTrue(hex.count == 7 || hex.count == 9, "\(slot): '\(hex)' is not #RRGGBB or #RRGGBBAA")
        }
    }

    // MARK: - Theme round trip (rule 2)

    func testThemeEncodeDecodeIsIdentity() throws {
        let theme = Theme(name: "Corporate", colors: [.accent1: "#112233", .dk1: "#000000"], majorFont: "Georgia", minorFont: "Verdana")
        let data = try JSONEncoder().encode(theme)
        let decoded = try JSONDecoder().decode(Theme.self, from: data)
        XCTAssertEqual(decoded, theme)
    }

    func testColorRefLiteralEncodeDecodeIsIdentity() throws {
        let ref = ColorRef.literal("#445566")
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(ColorRef.self, from: data)
        XCTAssertEqual(decoded, ref)
    }

    func testColorRefThemeEncodeDecodeIsIdentity() throws {
        let ref = ColorRef.theme(slot: .accent3, tint: 0.25)
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(ColorRef.self, from: data)
        XCTAssertEqual(decoded, ref)
    }

    // MARK: - 1.5 test contract: theme swap changes resolved colors while
    // block body encoding stays byte-identical for the paths that HAVE
    // adopted ColorRef (master backgrounds - SlideMasterPage).

    func testSwappingActiveThemeChangesResolvedMasterBackgroundColorWithoutRewritingTheMasterPagesStoredJSON() throws {
        let themeA = Theme(name: "A", colors: [.accent1: "#111111"])
        let themeB = Theme(name: "B", colors: [.accent1: "#222222"])
        var deck = SlideDeck.makeBlank()
        let master = SlideMasterPage(name: "Main", backgroundColorHex: .theme(slot: .accent1, tint: 0))
        deck = deck.settingMasterPage(master)
        deck = deck.settingTheme(themeA)
        deck = deck.settingTheme(themeB)

        deck = deck.settingActiveThemeID(themeA.id)
        let resolvedUnderA = deck.activeTheme.map { $0.resolve(master.backgroundColorHex!) }
        let masterJSONUnderA = try JSONEncoder().encode(deck.effectiveMasterPages[master.id.uuidString]!.backgroundColorHex)

        deck = deck.settingActiveThemeID(themeB.id)
        let resolvedUnderB = deck.activeTheme.map { $0.resolve(master.backgroundColorHex!) }
        let masterJSONUnderB = try JSONEncoder().encode(deck.effectiveMasterPages[master.id.uuidString]!.backgroundColorHex)

        XCTAssertEqual(resolvedUnderA, "#111111")
        XCTAssertEqual(resolvedUnderB, "#222222")
        XCTAssertNotEqual(resolvedUnderA, resolvedUnderB, "the swap must actually change the RESOLVED color")
        XCTAssertEqual(masterJSONUnderA, masterJSONUnderB, "the swap must not rewrite the stored ColorRef itself - only resolution changes")
    }

    // MARK: - ColorRef adoption gap on StyleDefinition (SUSPECTED CODE BUG)
    //
    // See Tests/TesseraCoreTests/Productivity/Materials/Draw/ShapeTests.swift's
    // testShapeFillColorAcceptsThemeReferencePerColorRefContract for the
    // ShapeFill half of the same audit finding (item 1.5, 1-of-3
    // adoption). This is the StyleDefinition (StyleProperties.textColorHex)
    // half.

    func testStylePropertiesTextColorAcceptsThemeReferencePerColorRefContract() {
        let json = """
        {"textColorHex": {"theme": {"slot": "accent2", "tint": 0}}}
        """.data(using: .utf8)!

        let decoded = try? JSONDecoder().decode(StyleProperties.self, from: json)
        XCTExpectFailure("SUSPECTED CODE BUG: StyleProperties.textColorHex (StyleRegistry.swift) is still a literal String? field, not ColorRef, so it cannot decode a theme color reference - contract: studio-expansion-design-refinement-2026-08-14.md section 4 Slides cluster item 1.5 (\"ColorRef... adopted by StyleDefinition...\"); confirmed still literal at docs/p1-post-claim-audit-2026-08-15.md item 1.5 (\"ColorRef adopted 1-of-3\").") {
            XCTAssertNotNil(decoded, "StyleProperties.textColorHex should accept a ColorRef.theme wire value per the ratified contract")
        }
    }
}
