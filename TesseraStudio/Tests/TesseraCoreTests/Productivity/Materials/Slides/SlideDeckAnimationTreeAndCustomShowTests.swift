import XCTest
import Foundation
@testable import TesseraCore

// MARK: - SlideDeckAnimationTreeAndCustomShowTests
//
// Pure-model (no data layer, no soffice) coverage for P2 items 2.1
// (SlideMeta.animationTree, the encode/decode sync contract) and 2.10
// (SlideDeck.customShows / effectiveCustomShows). Contract sources:
// SlideMeta.swift's/SlideDeck.swift's own doc comments (this wave's
// additions), .scratch/sota-p2-core-report.md's "2.1"/"2.10" design-
// contract sections, and testing-doctrine.md rule 2 (round-trip
// identity triple: encode-decode identity, legacy-JSON decode,
// byte-identical re-encode where the type has a canonical
// serialization) + rule 3 (derived-never-stored: effectiveCustomShows/
// effectiveAnimationTree are read-through views, never persisted
// copies - proven here by asserting the STORED field is untouched
// while the EFFECTIVE view differs).
//
// SlideStore-level receipts-law coverage for the mutation methods that
// use these types lives in SlideStoreAnimationTreeAndCustomShowTests
// .swift (DB-gated, no in-memory double available for SlideStore - see
// that file's header, mirroring SlideStoreTests.swift's own).

final class SlideDeckAnimationTreeAndCustomShowTests: DoctrineTestCase {

    // MARK: - SlideMeta.animationTree: encode syncs animations from the tree

    func testSlideMetaEncodeSyncsAnimationsFromAnimationTreeWhenTreeIsSet() throws {
        let flat: AnimationEffectList = [
            AnimationEffect(targetBlockID: UUID(), presetID: "zoom", trigger: .onClick, durationMS: 200, delayMS: 0),
        ]
        let tree = SMILAnimationTree(flat: flat)
        let meta = SlideMeta(animationTree: tree)
        XCTAssertNil(meta.animations, "constructing with only animationTree leaves the flat field literally as passed (nil) until encode/decode or a store mutation syncs it")

        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(SlideMeta.self, from: data)
        XCTAssertEqual(decoded.animationTree, tree)
        XCTAssertEqual(decoded.animations, flat, "encode must write the tree's flattened projection even though the in-memory value's own `animations` field was nil")
    }

    // MARK: - SlideMeta.animationTree: decode lifts from legacy flat-only data (P2-0 vintage)

    func testSlideMetaDecodeLiftsAnimationTreeFromLegacyFlatOnlyData() throws {
        let flat: AnimationEffectList = [
            AnimationEffect(targetBlockID: UUID(), presetID: "fade", trigger: .onClick, durationMS: 300, delayMS: 0),
            AnimationEffect(targetBlockID: UUID(), presetID: "spin", trigger: .withPrevious, durationMS: 150, delayMS: 25),
        ]
        let legacyMeta = SlideMeta(animations: flat) // P2-0 vintage: flat field only, no tree.
        let data = try JSONEncoder().encode(legacyMeta)
        let jsonString = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(jsonString.contains("animationTree"), "a SlideMeta built with only the flat field must encode with no animationTree key at all - the legacy shape this test proves decode-compat against")

        let decoded = try JSONDecoder().decode(SlideMeta.self, from: data)
        XCTAssertEqual(decoded.animations, flat)
        XCTAssertEqual(decoded.animationTree, SMILAnimationTree(flat: flat), "decode must LIFT animationTree from the flat field when no tree key is present")
    }

    // MARK: - SlideMeta.animationTree: decode PREFERS the tree over a disagreeing flat value

    func testSlideMetaDecodePrefersAnimationTreeWhenBothKeysPresentAndDisagree() throws {
        let flatA: AnimationEffectList = [AnimationEffect(targetBlockID: UUID(), presetID: "fade", trigger: .onClick, durationMS: 300, delayMS: 0)]
        let flatB: AnimationEffectList = [AnimationEffect(targetBlockID: UUID(), presetID: "wipe", trigger: .onClick, durationMS: 500, delayMS: 0)]
        let treeB = SMILAnimationTree(flat: flatB)

        // Encode a self-consistent SlideMeta (tree B, correctly synced
        // animations = flatB), then deliberately corrupt just the
        // top-level "animations" value to simulate stale/disagreeing
        // wire data no writer of this type would ever legitimately
        // produce - proving decode does not trust it when a tree is
        // present.
        let selfConsistent = SlideMeta(animationTree: treeB)
        let encoded = try JSONEncoder().encode(selfConsistent)
        var jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        jsonObject["animations"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(flatA))
        let corruptedData = try JSONSerialization.data(withJSONObject: jsonObject)

        let decoded = try JSONDecoder().decode(SlideMeta.self, from: corruptedData)
        XCTAssertEqual(decoded.animationTree, treeB, "decode must prefer the tree")
        XCTAssertEqual(decoded.animations, flatB, "decode must resync animations FROM the tree, discarding the disagreeing flat value that was on the wire")
    }

    // MARK: - SlideMeta.animationTree: legacy pre-P2-0 data (neither field) still decodes

    func testLegacySlideMetaJSONWithNeitherAnimationsFieldStillDecodes() throws {
        let preP20 = SlideMeta(layout: .title, notes: "speaker notes")
        let data = try JSONEncoder().encode(preP20)
        let decoded = try JSONDecoder().decode(SlideMeta.self, from: data)
        XCTAssertEqual(decoded.layout, .title)
        XCTAssertEqual(decoded.notes, "speaker notes")
        XCTAssertNil(decoded.animations)
        XCTAssertNil(decoded.animationTree)
    }

    // MARK: - SlideMeta.effectiveAnimationTree: read-through, never stored (rule 3)

    func testEffectiveAnimationTreeLiftsOnDemandWhenOnlyFlatFieldIsSetInMemory() {
        let flat: AnimationEffectList = [AnimationEffect(targetBlockID: UUID(), presetID: "wipe", trigger: .onClick, durationMS: 100, delayMS: 0)]
        let meta = SlideMeta(animations: flat)
        XCTAssertNil(meta.animationTree, "the stored field itself stays nil - only the read-through accessor lifts")
        XCTAssertEqual(meta.effectiveAnimationTree, SMILAnimationTree(flat: flat))
    }

    func testEffectiveAnimationTreeIsNilWhenNeitherFieldIsSet() {
        XCTAssertNil(SlideMeta.default.effectiveAnimationTree)
    }

    // MARK: - CustomShow: round-trip identity (rule 2)

    func testCustomShowEncodeDecodeIdentity() throws {
        let show = CustomShow(name: "Executive Summary", slideIDs: [UUID(), UUID(), UUID()])
        let data = try JSONEncoder().encode(show)
        let decoded = try JSONDecoder().decode(CustomShow.self, from: data)
        XCTAssertEqual(decoded, show)
    }

    func testCustomShowEncodeDecodeIdentityWithEmptySlideList() throws {
        let show = CustomShow(name: "Empty Show")
        let data = try JSONEncoder().encode(show)
        let decoded = try JSONDecoder().decode(CustomShow.self, from: data)
        XCTAssertEqual(decoded, show)
        XCTAssertEqual(decoded.slideIDs, [])
    }

    // MARK: - SlideDeck.customShows: legacy deck JSON (pre-this-wave) still decodes

    func testSlideDeckEncodedWithNoCustomShowsOmitsTheKeyAndDecodesBackToNil() throws {
        let deck = SlideDeck.makeBlank(title: "No Custom Shows")
        XCTAssertNil(deck.customShows)

        let data = try deck.jsonData()
        let jsonString = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(jsonString.contains("customShows"), "a deck that never had a custom show encodes with no customShows key at all - proving legacy (pre-P2-B) deck JSON has this exact shape")

        let decoded = try SlideDeck.from(jsonData: data)
        XCTAssertNil(decoded.customShows)
        XCTAssertEqual(decoded.effectiveCustomShows, [])
    }

    // MARK: - SlideDeck.effectiveCustomShows: pruning (rule 3: derived, never stored)

    func testEffectiveCustomShowsPrunesDanglingIDsWhileStoredListStaysUntouched() {
        var deck = SlideDeck.makeBlank(title: "Pruning Test")
        deck = deck.insertingSlide(at: 1, layout: .blank)
        XCTAssertEqual(deck.slideCount, 2)
        let slide0 = deck.body.rootChildren[0]
        let slide1 = deck.body.rootChildren[1]
        let danglingID = UUID()
        let show = CustomShow(name: "Show A", slideIDs: [slide0, danglingID, slide1])
        deck = deck.addingCustomShow(show)

        XCTAssertEqual(deck.customShows?.first?.slideIDs, [slide0, danglingID, slide1], "the STORED list keeps the dangling id exactly as given")
        XCTAssertEqual(deck.effectiveCustomShows.first?.slideIDs, [slide0, slide1], "the EFFECTIVE view drops the dangling id")
    }

    /// The design contract's own words: "deleting a slide leaves the
    /// STORED custom-show list untouched but the EFFECTIVE list
    /// pruned." Simulated at the pure-model level (the receipted
    /// SlideStore.deleteSlide path is covered separately, DB-gated) by
    /// applying exactly the same `body`/`slideMeta` edits that method
    /// makes.
    func testDeletingASlideLeavesStoredCustomShowListUntouchedButEffectiveListPruned() {
        var deck = SlideDeck.makeBlank(title: "Delete Slide Test")
        deck = deck.insertingSlide(at: 1, layout: .blank)
        let slide0 = deck.body.rootChildren[0]
        let slide1 = deck.body.rootChildren[1]
        deck = deck.addingCustomShow(CustomShow(name: "Both Slides", slideIDs: [slide0, slide1]))

        deck.body.blocks.removeValue(forKey: slide1)
        deck.body.rootChildren.removeAll { $0 == slide1 }
        deck.slideMeta.removeValue(forKey: slide1.uuidString)

        XCTAssertEqual(deck.customShows?.first?.slideIDs, [slide0, slide1], "stored list untouched by the slide deletion")
        XCTAssertEqual(deck.effectiveCustomShows.first?.slideIDs, [slide0], "effective list pruned to only the still-live slide")
    }

    // MARK: - SlideDeck custom-show helpers (adding/replacing/removing)

    func testAddingReplacingAndRemovingCustomShowHelpers() {
        var deck = SlideDeck.makeBlank(title: "Helpers Test")
        let show = CustomShow(name: "Original", slideIDs: [deck.body.rootChildren[0]])
        deck = deck.addingCustomShow(show)
        XCTAssertEqual(deck.customShows?.count, 1)

        let renamed = CustomShow(id: show.id, name: "Renamed", slideIDs: show.slideIDs)
        deck = deck.replacingCustomShow(renamed)
        XCTAssertEqual(deck.customShows?.first?.name, "Renamed")
        XCTAssertEqual(deck.customShows?.count, 1, "replace must not append a second entry")

        deck = deck.removingCustomShow(id: show.id)
        XCTAssertEqual(deck.customShows?.count, 0)
    }

    func testReplacingOrRemovingAnUnknownCustomShowIDDoesNotAlterExistingEntries() {
        var deck = SlideDeck.makeBlank(title: "Unknown ID Test")
        let show = CustomShow(name: "Kept", slideIDs: [deck.body.rootChildren[0]])
        deck = deck.addingCustomShow(show)
        let before = deck.customShows

        deck = deck.replacingCustomShow(CustomShow(name: "Ghost", slideIDs: []))
        XCTAssertEqual(deck.customShows, before, "replacing an unknown id must not change any existing entry")

        deck = deck.removingCustomShow(id: UUID())
        XCTAssertEqual(deck.customShows, before, "removing an unknown id must not change the list")
    }
}
