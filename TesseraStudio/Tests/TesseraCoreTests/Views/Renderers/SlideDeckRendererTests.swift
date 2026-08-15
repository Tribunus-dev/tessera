import XCTest
import CoreGraphics
@testable import TesseraCore

/// `SlideDeckRenderer` (P1 1.7): one slide -> one `CGContext` pass.
/// Primary contract (studio-expansion-design-refinement-2026-08-14.md
/// section 4, Slides cluster): a title+content fixture slide renders to
/// a byte-identical bitmap across two independent passes - proves the
/// render path has no dependency on non-deterministic state (random
/// palette seeds, wall-clock-derived values, ...). The rest of this file
/// covers the same "no-crash across the built-in catalog" +
/// "pixel-content sanity" style `ChartRendererTests` already
/// established, plus pure-logic coverage of the `idx`/position/type-
/// default frame resolution (mirroring how `SlideStoreTests` exercises
/// `SlideStore.applyingLayout` at the pure-model level).
final class SlideDeckRendererTests: XCTestCase {

    // MARK: - Fixtures

    /// A title+content slide with KNOWN text in both placeholders -
    /// `insertingSlide(layout: .titleAndContent, title:)` populates the
    /// heading but leaves the paragraph placeholder empty, so this fills
    /// that in too.
    private func titleAndContentDeck() -> SlideDeck {
        var deck = SlideDeck.makeEmpty(title: "Fixture")
        deck = deck.insertingSlide(at: 0, layout: .titleAndContent, title: "Q1 Review")
        let rootID = deck.body.rootChildren[0]
        guard let wrapper = deck.body.blocks[rootID],
              let paragraphID = wrapper.children.first(where: { deck.body.blocks[$0]?.type == .paragraph })
        else {
            XCTFail("insertingSlide(layout: .titleAndContent) should produce a toggle wrapping a heading + paragraph")
            return deck
        }
        var paragraph = deck.body.blocks[paragraphID]!
        paragraph.content = [InlineRun(text: "Revenue is up 12% quarter over quarter.")]
        deck.body.blocks[paragraphID] = paragraph
        return deck
    }

    private func makeBitmapContext(size: CGSize) -> CGContext {
        let width = Int(size.width)
        let height = Int(size.height)
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }

    private func fullPixelBuffer(_ context: CGContext, size: CGSize) -> Data {
        let count = Int(size.width) * Int(size.height) * 4
        let pointer = context.data!.assumingMemoryBound(to: UInt8.self)
        return Data(bytes: pointer, count: count)
    }

    /// A plain tuple isn't `Equatable` (no protocol conformance despite
    /// the standard library's ad-hoc `==` overloads for small tuples),
    /// so `XCTAssertEqual` can't compare two `pixel(...)` results
    /// directly - this struct is the small, real `Equatable` type that
    /// makes those assertions possible.
    private struct RGB: Equatable {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    private func pixel(_ context: CGContext, x: Int, y: Int) -> RGB {
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = (y * context.bytesPerRow) + (x * 4)
        return RGB(r: data[offset], g: data[offset + 1], b: data[offset + 2])
    }

    private func containsColor(_ context: CGContext, size: CGSize, r: UInt8, g: UInt8, b: UInt8) -> Bool {
        for y in 0..<Int(size.height) {
            for x in 0..<Int(size.width) {
                let p = pixel(context, x: x, y: y)
                if p.r == r, p.g == g, p.b == b { return true }
            }
        }
        return false
    }

    // MARK: - Determinism (the item's primary test contract)

    func testTitleAndContentFixtureRendersDeterministically() {
        let deck = titleAndContentDeck()
        let size = CGSize(width: 400, height: 300)
        let rect = CGRect(origin: .zero, size: size)

        let contextA = makeBitmapContext(size: size)
        SlideDeckRenderer().render(deck: deck, slideIndex: 0, in: contextA, rect: rect)
        let bufferA = fullPixelBuffer(contextA, size: size)

        let contextB = makeBitmapContext(size: size)
        SlideDeckRenderer().render(deck: deck, slideIndex: 0, in: contextB, rect: rect)
        let bufferB = fullPixelBuffer(contextB, size: size)

        XCTAssertEqual(bufferA, bufferB, "two renders of the same slide must produce byte-identical pixel buffers")
        XCTAssertTrue(bufferA.contains { $0 != 255 }, "a title+content slide must paint something - an all-white buffer would mean a silent no-op")
    }

    // MARK: - No-crash across the built-in catalog

    func testEveryBuiltInSlideLayoutRendersWithoutCrashing() {
        for layout in SlideLayout.allCases {
            let deck = SlideDeck.makeEmpty(title: "T").insertingSlide(at: 0, layout: layout, title: "Slide")
            let size = CGSize(width: 200, height: 150)
            let context = makeBitmapContext(size: size)
            SlideDeckRenderer().render(deck: deck, slideIndex: 0, in: context, rect: CGRect(origin: .zero, size: size))
        }
    }

    func testOutOfRangeSlideIndexDoesNotCrash() {
        let deck = SlideDeck.makeBlank(title: "T")
        let size = CGSize(width: 100, height: 100)
        let context = makeBitmapContext(size: size)
        SlideDeckRenderer().render(deck: deck, slideIndex: 99, in: context, rect: CGRect(origin: .zero, size: size))
    }

    func testZeroSizeRectDoesNotCrash() {
        let deck = SlideDeck.makeBlank(title: "T")
        let context = makeBitmapContext(size: CGSize(width: 10, height: 10))
        SlideDeckRenderer().render(deck: deck, slideIndex: 0, in: context, rect: .zero)
    }

    // MARK: - Background resolution

    func testBackgroundIsPlainWhiteWithNoMasterPage() {
        let deck = SlideDeck.makeBlank(title: "Deck")
        let size = CGSize(width: 40, height: 40)
        let context = makeBitmapContext(size: size)
        SlideDeckRenderer().render(deck: deck, slideIndex: 0, in: context, rect: CGRect(origin: .zero, size: size))
        XCTAssertEqual(pixel(context, x: 1, y: 1), RGB(r: 255, g: 255, b: 255))
    }

    func testBackgroundPaintsTheAssignedMasterPagesLiteralColor() {
        let master = SlideMasterPage(name: "Dark", backgroundColorHex: "#112233")
        var deck = SlideDeck.makeBlank(title: "Deck").settingMasterPage(master)
        let rootID = deck.body.rootChildren[0]
        deck.slideMeta[rootID.uuidString] = SlideMeta(layout: .title, masterPageID: master.id)

        let size = CGSize(width: 40, height: 40)
        let context = makeBitmapContext(size: size)
        SlideDeckRenderer().render(deck: deck, slideIndex: 0, in: context, rect: CGRect(origin: .zero, size: size))
        XCTAssertEqual(pixel(context, x: 1, y: 1), RGB(r: 0x11, g: 0x22, b: 0x33))
    }

    func testBackgroundResolvesAThemeSlotAgainstTheDecksActiveTheme() {
        let master = SlideMasterPage(name: "Themed", backgroundColorHex: .theme(slot: .accent1, tint: 0))
        var deck = SlideDeck.makeBlank(title: "Deck").settingMasterPage(master)
        let theme = Theme(name: "Brand", colors: [.accent1: "#334455"])
        deck = deck.settingTheme(theme).settingActiveThemeID(theme.id)
        let rootID = deck.body.rootChildren[0]
        deck.slideMeta[rootID.uuidString] = SlideMeta(layout: .title, masterPageID: master.id)

        let size = CGSize(width: 40, height: 40)
        let context = makeBitmapContext(size: size)
        SlideDeckRenderer().render(deck: deck, slideIndex: 0, in: context, rect: CGRect(origin: .zero, size: size))
        XCTAssertEqual(pixel(context, x: 1, y: 1), RGB(r: 0x33, g: 0x44, b: 0x55))
    }

    func testBackgroundIsPlainWhiteWhenTheSlideHasNoMasterPageAssignedEvenIfTheDeckHasOne() {
        let master = SlideMasterPage(name: "Dark", backgroundColorHex: "#112233")
        let deck = SlideDeck.makeBlank(title: "Deck").settingMasterPage(master)
        // Never assigned to the slide via `slideMeta`.
        let size = CGSize(width: 40, height: 40)
        let context = makeBitmapContext(size: size)
        SlideDeckRenderer().render(deck: deck, slideIndex: 0, in: context, rect: CGRect(origin: .zero, size: size))
        XCTAssertEqual(pixel(context, x: 1, y: 1), RGB(r: 255, g: 255, b: 255))
    }

    // MARK: - Shape paint order (zIndex, not document/array order)

    func testShapesPaintInZIndexOrderRegardlessOfDocumentOrder() {
        let geometry = ShapeGeometry(x: 40, y: 40, width: 100, height: 100)
        // Same geometry, fully overlapping - whichever paints LAST wins
        // every pixel in that rect.
        let winner = Shape(kind: .rect, geometry: geometry, fill: ShapeFill(colorHex: "#00FF00"), zIndex: 5)
        let loser = Shape(kind: .rect, geometry: geometry, fill: ShapeFill(colorHex: "#800080"), zIndex: 1)

        var ast = DocumentAST()
        let winnerBlock = Block(shape: winner)
        let loserBlock = Block(shape: loser)
        // Document/array order is winner-then-loser - the OPPOSITE of
        // zIndex order. If paint order followed array position instead
        // of `zIndex`, the loser (last in this array) would end up on
        // top instead of the winner.
        ast.blocks[winnerBlock.id] = winnerBlock
        ast.blocks[loserBlock.id] = loserBlock
        let rootID = UUID()
        ast.blocks[rootID] = Block(id: rootID, type: .toggle, children: [winnerBlock.id, loserBlock.id])
        ast.rootChildren = [rootID]

        var deck = SlideDeck.makeEmpty(title: "Shapes")
        deck.body = ast
        deck.slideMeta[rootID.uuidString] = SlideMeta(layout: .blank)

        let size = CGSize(width: 200, height: 200)
        let context = makeBitmapContext(size: size)
        SlideDeckRenderer().render(deck: deck, slideIndex: 0, in: context, rect: CGRect(origin: .zero, size: size))

        XCTAssertTrue(containsColor(context, size: size, r: 0, g: 255, b: 0), "the higher-zIndex shape should be visible")
        XCTAssertFalse(containsColor(context, size: size, r: 0x80, g: 0, b: 0x80), "the lower-zIndex shape is fully covered and should not be visible")
    }

    // MARK: - Content-block enumeration (pure logic)

    func testContentBlocksForATitleAndContentSlideAreTheWrapperChildren() {
        let deck = SlideDeck.makeEmpty(title: "T").insertingSlide(at: 0, layout: .titleAndContent, title: "Hello")
        let blocks = SlideDeckRenderer.contentBlocks(of: deck.slide(at: 0)!.body)
        XCTAssertEqual(blocks.map(\.type), [.heading, .paragraph])
    }

    func testContentBlocksForASingleLeafLayoutIsTheRootItself() {
        let deck = SlideDeck.makeEmpty(title: "T").insertingSlide(at: 0, layout: .title, title: "Hello")
        let blocks = SlideDeckRenderer.contentBlocks(of: deck.slide(at: 0)!.body)
        XCTAssertEqual(blocks.map(\.type), [.heading])
    }

    // MARK: - Placeholder-slot flattening (pure logic)

    func testFlattenedSlotsUnwrapsAWrappingTopPlaceholder() {
        XCTAssertEqual(SlideDeckRenderer.flattenedSlots(of: .titleAndContent).map(\.blockType), [.heading, .paragraph])
    }

    func testFlattenedSlotsForASingleLeafTopPlaceholderIsThatPlaceholderItself() {
        XCTAssertEqual(SlideDeckRenderer.flattenedSlots(of: .title).map(\.blockType), [.heading])
    }

    // MARK: - Frame resolution (pure logic)

    func testResolveFrameMatchesByRecordedIdxEvenWhenPositionDisagrees() {
        let slots = [
            SlideLayoutPlaceholder(blockType: .heading, idx: 0, frameU: CGRect(x: 0, y: 0, width: 1, height: 0.2)),
            SlideLayoutPlaceholder(blockType: .paragraph, idx: 1, frameU: CGRect(x: 0, y: 0.2, width: 1, height: 0.8)),
        ]
        var block = Block(type: .paragraph)
        block.attributes["placeholderIdx"] = .number(1)
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        // Position 0 would (wrongly) match the HEADING slot by position;
        // the recorded idx must win instead.
        let frame = SlideDeckRenderer.resolveFrame(for: block, at: 0, targetSlots: slots, rect: rect)
        XCTAssertEqual(frame, CGRect(x: 0, y: 20, width: 100, height: 80))
    }

    func testResolveFrameFallsBackToPositionWhenNoIdxIsRecorded() {
        let slots = [
            SlideLayoutPlaceholder(blockType: .heading, idx: 0, frameU: CGRect(x: 0, y: 0, width: 1, height: 0.2)),
            SlideLayoutPlaceholder(blockType: .paragraph, idx: 1, frameU: CGRect(x: 0, y: 0.2, width: 1, height: 0.8)),
        ]
        // A block `insertingSlide` created directly, never round-tripped
        // through `setSlideLayout` - no `placeholderIdx` attribute yet.
        let block = Block(type: .paragraph)
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let frame = SlideDeckRenderer.resolveFrame(for: block, at: 1, targetSlots: slots, rect: rect)
        XCTAssertEqual(frame, CGRect(x: 0, y: 20, width: 100, height: 80))
    }

    func testResolveFrameFallsBackToTheTypeDefaultWhenNothingMatches() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let headingFrame = SlideDeckRenderer.resolveFrame(for: Block(type: .heading), at: 9, targetSlots: [], rect: rect)
        let paragraphFrame = SlideDeckRenderer.resolveFrame(for: Block(type: .paragraph), at: 9, targetSlots: [], rect: rect)
        XCTAssertGreaterThan(headingFrame.width, 0)
        XCTAssertLessThan(headingFrame.maxY, paragraphFrame.minY, "the heading default should sit in a title band above the content band")
    }

    // MARK: - Shape enumeration (pure logic)

    func testOrderedShapesSortsByZIndexNotDocumentOrder() {
        let low = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 10, height: 10), zIndex: 5)
        let high = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 10, height: 10), zIndex: 1)
        var ast = DocumentAST()
        let lowBlock = Block(shape: low)
        let highBlock = Block(shape: high)
        ast.blocks[lowBlock.id] = lowBlock
        ast.blocks[highBlock.id] = highBlock
        ast.rootChildren = [lowBlock.id, highBlock.id]

        let ordered = SlideDeckRenderer.orderedShapes(in: ast)
        XCTAssertEqual(ordered.map(\.zIndex), [1, 5])
    }

    // MARK: - DeckExportCoordinator (PNG / JPG / PDF, same render path)

    func testDeckExportCoordinatorRendersPNGData() {
        let deck = titleAndContentDeck()
        let data = DeckExportCoordinator().renderPNG(deck: deck, slideIndex: 0, pixelSize: CGSize(width: 320, height: 180))
        XCTAssertEqual(data?.prefix(8).map { $0 }, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "PNG magic bytes")
    }

    func testDeckExportCoordinatorRendersJPEGData() {
        let deck = titleAndContentDeck()
        let data = DeckExportCoordinator().renderJPEG(deck: deck, slideIndex: 0, pixelSize: CGSize(width: 320, height: 180))
        XCTAssertEqual(data?.prefix(2).map { $0 }, [0xFF, 0xD8], "JPEG SOI marker")
    }

    func testDeckExportCoordinatorRendersOnePDFPagePerSlide() {
        var deck = SlideDeck.makeEmpty(title: "Deck")
        deck = deck.insertingSlide(at: 0, layout: .title, title: "One")
        deck = deck.insertingSlide(at: 1, layout: .title, title: "Two")
        let data = DeckExportCoordinator().renderPDF(deck: deck)
        XCTAssertEqual(data?.prefix(5).map { $0 }, Array("%PDF-".utf8))
    }

    func testDeckExportCoordinatorReturnsNilPDFForAnEmptyDeck() {
        let deck = SlideDeck.makeEmpty(title: "Empty")
        XCTAssertNil(DeckExportCoordinator().renderPDF(deck: deck))
    }
}
