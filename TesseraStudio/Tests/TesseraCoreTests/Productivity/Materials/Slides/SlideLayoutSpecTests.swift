import XCTest
@testable import TesseraCore

/// `SlideLayoutSpec` (P0 0.7): the 4-case `SlideLayout` enum's
/// built-in defaults. `SlideDeck.insertingSlide` is NOT refactored to
/// read these (see `SlideLayoutSpec`'s doc comment for why) - so the
/// most important thing these tests pin is that the two stay in sync:
/// each built-in's placeholder tree must describe exactly the block
/// shape `insertingSlide` actually produces for that layout.
final class SlideLayoutSpecTests: XCTestCase {

    // MARK: - Builtins cover every SlideLayout case

    func testBuiltinsCoverEverySlideLayoutCase() {
        // Not equality: P1 1.9 extended builtins with the ~25-entry LO
        // AutoLayout catalog as DATA, on top of the 4 ids the closed
        // SlideLayout enum names - builtins is now intentionally a
        // superset. The invariant this test actually protects is that
        // every SlideLayout case still resolves to a builtin.
        let builtinIDs = Set(SlideLayoutSpec.builtins.map(\.id))
        let layoutIDs = Set(SlideLayout.allCases.map(\.rawValue))
        XCTAssertTrue(layoutIDs.isSubset(of: builtinIDs))
    }

    func testDefaultForEachLayoutReturnsTheMatchingBuiltin() {
        XCTAssertEqual(SlideLayoutSpec.default(for: .title).id, SlideLayoutSpec.title.id)
        XCTAssertEqual(SlideLayoutSpec.default(for: .titleAndContent).id, SlideLayoutSpec.titleAndContent.id)
        XCTAssertEqual(SlideLayoutSpec.default(for: .image).id, SlideLayoutSpec.image.id)
        XCTAssertEqual(SlideLayoutSpec.default(for: .blank).id, SlideLayoutSpec.blank.id)
    }

    // MARK: - Placeholder shapes

    func testTitleSpecIsASingleHeadingPlaceholder() {
        XCTAssertEqual(SlideLayoutSpec.title.placeholders.map(\.blockType), [.heading])
    }

    func testTitleAndContentSpecIsAToggleWrappingHeadingAndParagraph() {
        let placeholders = SlideLayoutSpec.titleAndContent.placeholders
        XCTAssertEqual(placeholders.map(\.blockType), [.toggle])
        XCTAssertEqual(placeholders[0].children.map(\.blockType), [.heading, .paragraph])
    }

    func testImageSpecIsASingleImagePlaceholder() {
        XCTAssertEqual(SlideLayoutSpec.image.placeholders.map(\.blockType), [.image])
    }

    func testBlankSpecIsASingleParagraphPlaceholder() {
        XCTAssertEqual(SlideLayoutSpec.blank.placeholders.map(\.blockType), [.paragraph])
    }

    // MARK: - Cross-check against SlideDeck.insertingSlide's real output

    /// Walks the block tree `insertingSlide` actually built for one
    /// slide and reduces it to the same `[BlockType]`-tree shape a
    /// `SlideLayoutSpec`'s placeholders describe, so the two can be
    /// compared directly.
    private func placeholderShape(ofSlideAt index: Int, in deck: SlideDeck) -> [SlideLayoutPlaceholder] {
        let rootID = deck.body.rootChildren[index]
        guard let block = deck.body.blocks[rootID] else { return [] }
        return [shape(of: block, in: deck)]
    }

    private func shape(of block: Block, in deck: SlideDeck) -> SlideLayoutPlaceholder {
        SlideLayoutPlaceholder(
            blockType: block.type,
            children: block.children.compactMap { deck.body.blocks[$0] }.map { shape(of: $0, in: deck) }
        )
    }

    /// Strips idx/name/frameU (P1 1.9/1.7 additions, absent from
    /// `insertingSlide`'s own output per its doc comment - that switch
    /// is deliberately unrefactored) so the comparison below is purely
    /// about blockType/children shape, matching what `shape(of:)`
    /// above already produces.
    private func stripMetadata(_ placeholders: [SlideLayoutPlaceholder]) -> [SlideLayoutPlaceholder] {
        placeholders.map {
            SlideLayoutPlaceholder(blockType: $0.blockType, children: stripMetadata($0.children))
        }
    }

    func testEveryBuiltinMatchesWhatInsertingSlideActuallyProduces() {
        let deck = SlideDeck.makeEmpty(title: "T")
        for layout in SlideLayout.allCases {
            let withSlide = deck.insertingSlide(at: 0, layout: layout)
            let actualShape = placeholderShape(ofSlideAt: 0, in: withSlide)
            XCTAssertEqual(
                actualShape, stripMetadata(SlideLayoutSpec.default(for: layout).placeholders),
                "SlideLayoutSpec.default(for: \(layout)) has drifted from insertingSlide's real output"
            )
        }
    }
}
