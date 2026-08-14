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
        let builtinIDs = Set(SlideLayoutSpec.builtins.map(\.id))
        let layoutIDs = Set(SlideLayout.allCases.map(\.rawValue))
        XCTAssertEqual(builtinIDs, layoutIDs)
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

    func testEveryBuiltinMatchesWhatInsertingSlideActuallyProduces() {
        let deck = SlideDeck.makeEmpty(title: "T")
        for layout in SlideLayout.allCases {
            let withSlide = deck.insertingSlide(at: 0, layout: layout)
            let actualShape = placeholderShape(ofSlideAt: 0, in: withSlide)
            XCTAssertEqual(
                actualShape, SlideLayoutSpec.default(for: layout).placeholders,
                "SlideLayoutSpec.default(for: \(layout)) has drifted from insertingSlide's real output"
            )
        }
    }
}
