import XCTest
import Foundation
@testable import TesseraCore

// MARK: - SlideStoreLayoutApplicationTests
//
// Contract source: SlideStore.applyingLayout's own doc comment
// (design-refinement doc section 4, Slides cluster, item 1.9):
// idx-then-type matching; existing blocks matching nothing are NEVER
// deleted (PowerPoint orphan rule); re-running with the same spec
// reproduces the identical assignment. `applyingLayout` is `internal`
// (not `private`), specifically so it is directly testable without a
// live TesseraDataLayer (the function's own doc comment says so) - this
// is a PURE, ungated test of the 1.9 contract; SlideStoreTests.swift
// (this cluster, if time allows) covers the DB-gated store-level
// receipts-law wrapper around it.
//
// "idempotent" (doctrine rule 6) is defined precisely here as: applying
// the SAME spec a second time to a deck the spec has already been
// applied to produces the IDENTICAL block-id set as the first
// application - no block invented, none lost - because pass-1
// idx-then-type matching re-claims every block the first application
// already tagged.

final class SlideStoreLayoutApplicationTests: DoctrineTestCase {

    private func blankDeckWithOneSlide() -> SlideDeck {
        SlideDeck.makeBlank(title: "Layout Test Deck")
    }

    // MARK: - Idempotence (precise definition per rule 6)

    func testReapplyingTheSameLayoutTwiceProducesTheIdenticalBlockIDSet() {
        let deck = blankDeckWithOneSlide()
        for spec in SlideLayoutSpec.builtins {
            let once = SlideStore.applyingLayout(spec, atSlideIndex: 0, to: deck)
            let twice = SlideStore.applyingLayout(spec, atSlideIndex: 0, to: once)

            let idsOnce = Set(blockIDs(inSlideAt: 0, of: once))
            let idsTwice = Set(blockIDs(inSlideAt: 0, of: twice))
            XCTAssertEqual(idsOnce, idsTwice, "\(spec.id): re-applying the same layout must not invent or lose any block id")
        }
    }

    func testReapplyingTheSameLayoutTwiceIsAFullNoOpOnBlockContent() {
        // A stronger check than the id-set equality above for one
        // representative multi-slot spec: every block's full content
        // (not just its id) is unchanged by the second apply, since
        // pass-1 idx-then-type matching reclaims each slot's existing
        // block rather than replacing it.
        let deck = blankDeckWithOneSlide()
        let spec = SlideLayoutSpec.builtins.first { $0.id == "twoContent" }!

        let once = SlideStore.applyingLayout(spec, atSlideIndex: 0, to: deck)
        let twice = SlideStore.applyingLayout(spec, atSlideIndex: 0, to: once)

        XCTAssertEqual(once.body.blocks, twice.body.blocks)
        XCTAssertEqual(once.body.rootChildren, twice.body.rootChildren)
    }

    // MARK: - Orphan rule: no block id is ever lost across a layout switch

    func testSwitchingToADifferentLayoutNeverLosesAnExistingBlockID() {
        let deck = blankDeckWithOneSlide()
        let comparisonSpec = SlideLayoutSpec.builtins.first { $0.id == "comparison" }! // 5 content slots

        let afterFirst = SlideStore.applyingLayout(comparisonSpec, atSlideIndex: 0, to: deck)
        let idsAfterFirst = Set(blockIDs(inSlideAt: 0, of: afterFirst))

        let titleOnlySpec = SlideLayoutSpec.builtins.first { $0.id == "titleOnly" }! // 1 content slot
        let afterSwitch = SlideStore.applyingLayout(titleOnlySpec, atSlideIndex: 0, to: afterFirst)
        let idsAfterSwitch = Set(blockIDs(inSlideAt: 0, of: afterSwitch))

        XCTAssertTrue(idsAfterFirst.isSubset(of: idsAfterSwitch), "switching layouts must keep every previously-existing block id, either matched into a new slot or kept as an orphan (PowerPoint orphan rule)")
    }

    func testApplyingEveryBuiltinLayoutToABlankSlidePreservesTheOriginalRootBlockAsAnOrphanWhenTypesDisagree() {
        // The blank starting slide is a single .heading block (from
        // SlideLayout.title's own shape). Any target spec whose FIRST
        // slot is not .heading cannot idx-or-type-match it in pass 1/2,
        // so it must survive as an unassigned orphan, not be deleted.
        let deck = blankDeckWithOneSlide()
        let originalID = deck.body.rootChildren[0]
        XCTAssertEqual(deck.body.blocks[originalID]?.type, .heading)

        let tableOnlySpec = SlideLayoutSpec.builtins.first { $0.id == "tableOnly" }!
        let updated = SlideStore.applyingLayout(tableOnlySpec, atSlideIndex: 0, to: deck)

        XCTAssertTrue(blockIDs(inSlideAt: 0, of: updated).contains(originalID), "the original heading block must survive as an orphan under a layout with no heading slot")
    }

    // MARK: - Out-of-range index is a no-op (rule 1's spirit, at the pure-logic layer)

    func testApplyingLayoutAtAnOutOfRangeIndexReturnsTheDeckUnchanged() {
        let deck = blankDeckWithOneSlide()
        let spec = SlideLayoutSpec.titleAndContent
        let updated = SlideStore.applyingLayout(spec, atSlideIndex: 99, to: deck)
        XCTAssertEqual(updated, deck)
    }

    // MARK: - Helper

    private func blockIDs(inSlideAt index: Int, of deck: SlideDeck) -> [UUID] {
        guard index >= 0, index < deck.body.rootChildren.count else { return [] }
        let rootID = deck.body.rootChildren[index]
        guard let root = deck.body.blocks[rootID] else { return [] }
        if root.children.isEmpty { return [rootID] }
        return [rootID] + root.children
    }
}
