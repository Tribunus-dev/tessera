import XCTest
@testable import TesseraCore

// MARK: - BlockRendererEquationTests
//
// Contract: item 2.14 (StarMathEditor - LaTeX-first over SwiftMath),
// studio-expansion-design-refinement-2026-08-14.md section 5 (search
// "2.14"). `renderEquation`/`renderLaTeX`: `attributes["latex"]` is
// canonical; SwiftMath renders it into the same `NSAttributedString`
// shape every other `render*` method returns; malformed LaTeX degrades
// to a visible error indicator (never throws/crashes); this track's
// item 6 test list: "SwiftMath renders a few hand-picked LaTeX
// fixtures without crashing and produces non-empty output (content
// assertion where feasible, not just no-crash); malformed LaTeX
// degrades to a visible error indicator."
//
// Coverage shape (doctrine rule 8, renderer): determinism first (rule
// 4: two independent passes byte-identical), then content (pixel/byte
// checks at known locations - here, the rendered image's own byte
// representation and pixel size, since SwiftMath's output is an image,
// not text).

final class BlockRendererEquationTests: DoctrineTestCase {

    private let renderer = BlockRenderer(theme: .light)

    private func equationBlock(latex: String) -> Block {
        var block = Block(type: .equation)
        block.attributes["latex"] = .string(latex)
        return block
    }

    // MARK: - Determinism (doctrine rule 4): two independent passes are byte-identical

    func testRenderLaTeXIsDeterministicAcrossTwoIndependentPasses() {
        let first = renderer.renderLaTeX("x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}")
        let second = renderer.renderLaTeX("x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}")
        guard let firstImage = first.soleAttachmentImage, let secondImage = second.soleAttachmentImage else {
            return XCTFail("expected both passes to produce an attachment image")
        }
        XCTAssertEqual(firstImage.tiffOrPNGRepresentationForTesting, secondImage.tiffOrPNGRepresentationForTesting,
                        "two independent renders of the same LaTeX must be byte-identical (doctrine rule 4)")
    }

    // MARK: - Content: well-formed LaTeX fixtures render non-empty images

    func testWellKnownQuadraticFormulaRendersANonEmptyAttachmentImage() throws {
        let attributed = renderer.renderLaTeX("x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}")
        let image = try XCTUnwrap(attributed.soleAttachmentImage, "a well-formed formula must render to an attachment image, not fall through to the error/placeholder text path")
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testSimpleFractionRendersANonEmptyAttachmentImage() throws {
        let attributed = renderer.renderLaTeX("\\frac{1}{2}")
        let image = try XCTUnwrap(attributed.soleAttachmentImage)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testGreekLetterSumRendersANonEmptyAttachmentImage() throws {
        let attributed = renderer.renderLaTeX("\\sum_{i=1}^{n} \\alpha_i")
        let image = try XCTUnwrap(attributed.soleAttachmentImage)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    /// A visually richer formula should produce a WIDER image than a
    /// single glyph - a cheap, real content assertion (not just "some
    /// image exists") that the renderer is actually laying out the
    /// LaTeX structure, not returning a fixed-size stub.
    func testLongerFormulaProducesAWiderImageThanASingleCharacter() throws {
        let short = try XCTUnwrap(renderer.renderLaTeX("a").soleAttachmentImage)
        let long = try XCTUnwrap(renderer.renderLaTeX("a + b + c + d + e = f").soleAttachmentImage)
        XCTAssertGreaterThan(long.size.width, short.size.width)
    }

    // MARK: - renderEquation reads attributes["latex"] (the canonical field)

    func testRenderEquationReadsTheLatexAttributeAndProducesAnImage() throws {
        let block = equationBlock(latex: "\\pi r^2")
        let attributed = renderer.render(block, in: .document)
        XCTAssertNotNil(attributed.soleAttachmentImage, "attributes[\"latex\"] must reach SwiftMath via the exact same path as renderLaTeX")
    }

    func testRenderEquationWithMissingLatexAttributeDegradesToEmptyPlaceholderNotACrash() {
        let block = Block(type: .equation) // no attributes["latex"] at all
        let attributed = renderer.render(block, in: .document)
        XCTAssertNil(attributed.soleAttachmentImage)
        XCTAssertTrue(attributed.string.contains("Empty equation"), attributed.string)
    }

    // MARK: - Malformed LaTeX degrades to a visible error indicator (never crashes)

    func testMismatchedBracesDegradesToVisibleErrorIndicatorNotACrash() {
        let attributed = renderer.renderLaTeX("\\frac{1")
        XCTAssertNil(attributed.soleAttachmentImage, "a malformed formula must NOT produce an attachment image")
        XCTAssertTrue(attributed.string.contains("[Equation error:"), attributed.string)
    }

    func testUnknownCommandDegradesToVisibleErrorIndicatorNotACrash() {
        let attributed = renderer.renderLaTeX("\\thisIsNotARealLaTeXCommand{x}")
        XCTAssertNil(attributed.soleAttachmentImage)
        XCTAssertTrue(attributed.string.contains("[Equation error:"), attributed.string)
    }

    func testUnbalancedLeftRightDelimitersDegradesToVisibleErrorIndicatorNotACrash() {
        let attributed = renderer.renderLaTeX("\\left( x")
        XCTAssertNil(attributed.soleAttachmentImage)
        XCTAssertTrue(attributed.string.contains("[Equation error:"), attributed.string)
    }

    /// The error indicator must be visually distinct (red foreground) -
    /// "a visible error indicator", not merely non-crashing text that
    /// blends into ordinary body copy.
    func testErrorIndicatorUsesTheRedForegroundColorConvention() {
        let attributed = renderer.renderLaTeX("\\frac{1")
        let color = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? PlatformColor
        XCTAssertEqual(color, PlatformColor.systemRed)
    }

    // MARK: - Empty/whitespace-only LaTeX is a neutral placeholder, not an error

    func testEmptyLatexIsANeutralPlaceholderNotAnErrorIndicator() {
        let attributed = renderer.renderLaTeX("")
        XCTAssertNil(attributed.soleAttachmentImage)
        XCTAssertTrue(attributed.string.contains("Empty equation"), attributed.string)
        XCTAssertFalse(attributed.string.contains("error"), "empty input is not a malformed-input error")
    }

    func testWhitespaceOnlyLatexIsANeutralPlaceholder() {
        let attributed = renderer.renderLaTeX("   \n  ")
        XCTAssertNil(attributed.soleAttachmentImage)
        XCTAssertTrue(attributed.string.contains("Empty equation"))
    }
}

// MARK: - Test-only image byte helper

extension PlatformImage {
    /// A comparable byte representation for the determinism test above
    /// - TIFF on macOS (`NSImage` has no direct PNG accessor),
    /// PNG on iOS. Test-only; production code never needs to compare
    /// image bytes.
    var tiffOrPNGRepresentationForTesting: Data? {
        #if canImport(AppKit)
        return self.tiffRepresentation
        #elseif canImport(UIKit)
        return self.pngData()
        #endif
    }
}
