import XCTest
@testable import TesseraCore

/// `MasterPageLayoutPicker` (P1 1.9): the LO AutoLayout catalog
/// (`SlideLayoutSpec.builtins`, grown from 4 to ~25) plus the
/// idx-then-type apply-layout mutation (`SlideStore.applyingLayout`).
///
/// `SlideStore`'s async mutation API needs a live `TesseraDataLayer`
/// this test target doesn't stand up (see `MasterPageStoreTests`,
/// scoped the same way) - so this exercises the mutation logic at the
/// pure-model level via `SlideStore.applyingLayout(_:atSlideIndex:to:)`
/// directly, which is where the actual idx/type matching + orphan
/// preservation lives.
final class MasterPageLayoutPickerTests: XCTestCase {

    // MARK: - Catalog shape

    func testCatalogHasAroundTwentyFiveEntries() {
        XCTAssertEqual(SlideLayoutSpec.builtins.count, 25)
    }

    func testCatalogIDsAreUnique() {
        let ids = SlideLayoutSpec.builtins.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testCatalogCoversEverySlideLayoutCaseAsASubset() {
        // P0 0.7's `testBuiltinsCoverEverySlideLayoutCase` pinned an
        // exact Set equality between `builtins` and `SlideLayout
        // .allCases` - by design that invariant no longer holds once
        // P1 1.9 grows `builtins` to the AutoLayout catalog (see this
        // type's header comment). The surviving invariant is that the
        // 4 `SlideLayout`-backed defaults are still IN the catalog.
        let builtinIDs = Set(SlideLayoutSpec.builtins.map(\.id))
        let layoutIDs = Set(SlideLayout.allCases.map(\.rawValue))
        XCTAssertTrue(layoutIDs.isSubset(of: builtinIDs))
    }

    /// Every LEAF placeholder (a real content slot, as opposed to a
    /// purely structural wrapping container) in every catalog entry.
    private func leafPlaceholders(_ spec: SlideLayoutSpec) -> [SlideLayoutPlaceholder] {
        func leaves(_ p: SlideLayoutPlaceholder) -> [SlideLayoutPlaceholder] {
            p.children.isEmpty ? [p] : p.children.flatMap(leaves)
        }
        return spec.placeholders.flatMap(leaves)
    }

    func testEveryLeafPlaceholderInEveryBuiltinHasARealIdx() {
        for spec in SlideLayoutSpec.builtins {
            for leaf in leafPlaceholders(spec) {
                XCTAssertNotNil(leaf.idx, "\(spec.id) has a leaf placeholder (\(leaf.blockType)) with no idx")
            }
        }
    }

    func testIdxIsUniqueWithinEachSpec() {
        for spec in SlideLayoutSpec.builtins {
            let idxs = leafPlaceholders(spec).compactMap(\.idx)
            XCTAssertEqual(Set(idxs).count, idxs.count, "\(spec.id) has a duplicate placeholder idx")
        }
    }

    /// `.toggle` is reserved for the wrapping container - never a
    /// content slot itself - matching the pre-existing built-ins'
    /// convention (see `SlideLayoutSpec`'s own header comment).
    func testNoLeafPlaceholderIsAToggle() {
        for spec in SlideLayoutSpec.builtins {
            for leaf in leafPlaceholders(spec) {
                XCTAssertNotEqual(leaf.blockType, .toggle, "\(spec.id) uses .toggle as a content slot, not just a wrapper")
            }
        }
    }

    /// Regression guard for the 4 pre-existing built-ins: P1 1.9 only
    /// adds `idx`/`name` to them, it must not change the block-TYPE
    /// shape `SlideDeck.insertingSlide` actually produces (unlike the
    /// old P0 `SlideLayoutSpecTests`, this compares block types only,
    /// not full placeholder equality, since idx is new and deliberately
    /// absent from `insertingSlide`'s raw output).
    func testExistingFourBuiltinsStillMatchInsertingSlidesShape() {
        let deck = SlideDeck.makeEmpty(title: "T")
        for layout in SlideLayout.allCases {
            let withSlide = deck.insertingSlide(at: 0, layout: layout)
            let rootID = withSlide.body.rootChildren[0]
            let actualTypes = blockTypeShape(rootID: rootID, in: withSlide.body)
            let specTypes = placeholderTypeShape(SlideLayoutSpec.default(for: layout).placeholders)
            XCTAssertEqual(actualTypes, specTypes, "SlideLayoutSpec.default(for: \(layout)) drifted from insertingSlide's shape")
        }
    }

    private func blockTypeShape(rootID: UUID, in ast: DocumentAST) -> [BlockType] {
        guard let block = ast.blocks[rootID] else { return [] }
        if block.children.isEmpty { return [block.type] }
        return block.children.compactMap { ast.blocks[$0]?.type }
    }

    private func placeholderTypeShape(_ placeholders: [SlideLayoutPlaceholder]) -> [BlockType] {
        guard let top = placeholders.first else { return [] }
        return top.children.isEmpty ? [top.blockType] : top.children.map(\.blockType)
    }

    // MARK: - apply-layout: block-ID preservation (PowerPoint orphan rule)

    /// A 2-block starting slide (heading + paragraph, wrapped in a
    /// toggle - the real shape `insertingSlide(layout: .titleAndContent)`
    /// produces) so every catalog layout has to make a real matching
    /// decision, not just a trivial 1-block case.
    private func makeRichDeck() -> (deck: SlideDeck, headingID: UUID, paragraphID: UUID) {
        let deck = SlideDeck.makeEmpty(title: "T").insertingSlide(at: 0, layout: .titleAndContent)
        let rootID = deck.body.rootChildren[0]
        let root = deck.body.blocks[rootID]!
        let headingID = root.children.first { deck.body.blocks[$0]?.type == .heading }!
        let paragraphID = root.children.first { deck.body.blocks[$0]?.type == .paragraph }!
        return (deck, headingID, paragraphID)
    }

    func testApplyingEveryCatalogLayoutPreservesTheOriginalBlockIDs() {
        let (deck, headingID, paragraphID) = makeRichDeck()
        for spec in SlideLayoutSpec.builtins {
            let after = SlideStore.applyingLayout(spec, atSlideIndex: 0, to: deck)
            XCTAssertTrue(after.body.blocks.keys.contains(headingID), "\(spec.id) dropped the original heading block")
            XCTAssertTrue(after.body.blocks.keys.contains(paragraphID), "\(spec.id) dropped the original paragraph block")
            // Still exactly one slide (single root child) - orphans are
            // appended into the tree, never split into a second slide.
            XCTAssertEqual(after.slideCount, 1, "\(spec.id) changed the slide count")
        }
    }

    func testOrphanedBlockLosesItsPlaceholderIdxButSurvives() {
        let (deck, headingID, paragraphID) = makeRichDeck()
        // "titleOnly" has a single heading slot - the paragraph matches
        // nothing and must become an unassigned orphan, not vanish.
        let titleOnly = SlideLayoutSpec.builtins.first { $0.id == "titleOnly" }!
        let after = SlideStore.applyingLayout(titleOnly, atSlideIndex: 0, to: deck)

        let heading = after.body.blocks[headingID]!
        let headingIdx: Double? = heading.attributes["placeholderIdx"]?.numberValue
        XCTAssertEqual(headingIdx, Double(0))

        let paragraph = after.body.blocks[paragraphID]!
        XCTAssertNil(paragraph.attributes["placeholderIdx"], "orphaned block must not keep a stale placeholderIdx")
    }

    // MARK: - apply-layout: idempotency

    func testReapplyingEveryCatalogLayoutIsIdempotent() {
        let (deck, _, _) = makeRichDeck()
        for spec in SlideLayoutSpec.builtins {
            let once = SlideStore.applyingLayout(spec, atSlideIndex: 0, to: deck)
            let twice = SlideStore.applyingLayout(spec, atSlideIndex: 0, to: once)
            XCTAssertEqual(twice.body, once.body, "\(spec.id) is not idempotent on a second apply")
            XCTAssertEqual(twice.slideMeta, once.slideMeta, "\(spec.id) slideMeta drifted on a second apply")
        }
    }

    func testReapplyingSameLayoutTwiceCreatesNoNewBlocks() {
        let (deck, _, _) = makeRichDeck()
        let comparison = SlideLayoutSpec.builtins.first { $0.id == "comparison" }!
        let once = SlideStore.applyingLayout(comparison, atSlideIndex: 0, to: deck)
        let twice = SlideStore.applyingLayout(comparison, atSlideIndex: 0, to: once)
        XCTAssertEqual(Set(once.body.blocks.keys), Set(twice.body.blocks.keys))
    }

    // MARK: - apply-layout: idx match survives block reordering

    /// The whole point of `idx` (over positional matching): a block
    /// keeps its placeholder binding even if the deck's own child order
    /// is not the order the layout's slots are declared in.
    func testIdxMatchIsPositionIndependent() {
        let twoContent = SlideLayoutSpec.builtins.first { $0.id == "twoContent" }!
        let deck = SlideDeck.makeEmpty(title: "T").insertingSlide(at: 0, layout: .titleAndContent)
        let firstApply = SlideStore.applyingLayout(twoContent, atSlideIndex: 0, to: deck)
        let rootID = firstApply.body.rootChildren[0]
        var root = firstApply.body.blocks[rootID]!
        // Reverse the wrapper's own child order - idx match must still
        // land each block back on the SAME slot it had before.
        var reordered = firstApply
        root.children.reverse()
        reordered.body.blocks[rootID] = root

        let secondApply = SlideStore.applyingLayout(twoContent, atSlideIndex: 0, to: reordered)
        for childID in firstApply.body.blocks[rootID]!.children {
            XCTAssertEqual(
                firstApply.body.blocks[childID]?.attributes["placeholderIdx"],
                secondApply.body.blocks[childID]?.attributes["placeholderIdx"],
                "block \(childID) lost its placeholder idx binding after reordering"
            )
        }
    }

    // MARK: - setSlideLayout(spec:) / setSlideLayout(layout:) share one receipt type

    func testBothSetSlideLayoutOverloadsShareTheSameReceiptType() {
        // No new SlideReceiptType case was added for the spec-based
        // overload - both paths reuse `.setSlideLayout` (P1 1.9
        // contract: "reuse the EXISTING setSlideLayout receipt case").
        XCTAssertEqual(SlideReceiptType.setSlideLayout.rawValue, "slide_layout_changed")
        XCTAssertEqual(SlideReceiptType.allCases.filter { $0.rawValue.contains("layout") }.count, 1)
    }
}
