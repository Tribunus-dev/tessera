import XCTest
import Foundation
@testable import TesseraCore

// MARK: - SlideStoreAnimationTreeAndCustomShowTests
//
// Receipts-law coverage (testing-doctrine.md rule 1) for the P2 item
// 2.1 (`setAnimationTree`/`clearAnimationTree`) and 2.10
// (`defineCustomShow`/`updateCustomShow`/`removeCustomShow`) mutation
// methods added to SlideStore.swift this wave. Contract source:
// SlideStore.swift's own doc comments on each method (receipt type
// reused, no-op conditions).
//
// DB-GATED (doctrine rule 11), mirroring SlideStoreTests.swift's own
// header exactly: SlideStore has no in-memory data-layer double, so
// every test here talks to a real TesseraDataLayer and skips via
// XCTSkip unless TESSERA_DB_INTEGRATION=1 AND the local Postgres/
// Valkey stores are reachable. The UNGATED shadow for the pure-value
// half of each contract (encode/decode sync, effective* pruning,
// no-op-at-the-value-level helpers) lives in
// SlideDeckAnimationTreeAndCustomShowTests.swift - what THIS file adds
// is the receipts-law wiring that only exists at the store level,
// exactly as that sibling test file's own header states for the
// pattern it's mirroring.

private enum SlideAnimTestDataLayer {
    static func startedOrSkip() async throws -> TesseraDataLayer {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip("TESSERA_DB_INTEGRATION=1 not set - skipping DB-gated SlideStore test.")
        }
        let layer = TesseraDataLayer()
        let outcome = await layer.start()
        guard case .ready = outcome else {
            throw XCTSkip("TesseraDataLayer did not reach .ready (\(outcome)) - local Postgres/Valkey not reachable.")
        }
        return layer
    }
}

final class SlideStoreAnimationTreeAndCustomShowTests: DoctrineTestCase {

    /// Filters out the fire-and-forget material-receipt race, exactly
    /// as SlideStoreTests.slideReceipts(_:forDeck:) does (see that
    /// method's own doc comment for why).
    private func slideReceipts(_ store: SlideStore, forDeck id: UUID) async throws -> [GraphReceipt] {
        try await store.receipts(forDeck: id).filter { $0.receiptType != SlideReceiptPayload.receiptType }
    }

    // MARK: - setAnimationTree: receipt + persistence + syncs the flat projection

    func testSetAnimationTreeEmitsExactlyOneReceiptAndPersistsBothFields() async throws {
        let layer = try await SlideAnimTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        let deck = try await store.upsert(SlideDeck.makeBlank(title: "SetAnimationTree Gate Test"))
        let flat: AnimationEffectList = [
            AnimationEffect(targetBlockID: deck.body.rootChildren[0], presetID: "flyIn", trigger: .onClick, durationMS: 400, delayMS: 0),
        ]
        let tree = SMILAnimationTree(flat: flat)

        let updated = try await store.setAnimationTree(tree, forSlideAt: 0, for: deck.id)
        XCTAssertEqual(updated.slide(at: 0)?.layout, deck.slide(at: 0)?.layout, "setAnimationTree must not touch layout")

        let fetched = try await store.get(id: deck.id)
        let key = fetched?.body.rootChildren[0].uuidString ?? ""
        XCTAssertEqual(fetched?.slideMeta[key]?.animationTree, tree)
        XCTAssertEqual(fetched?.slideMeta[key]?.effectiveAnimations, flat, "the flat projection must be kept in sync by the mutation, not just by a later encode/decode")

        let receipts = try await slideReceipts(store, forDeck: deck.id)
        let treeReceipts = receipts.filter { $0.receiptType == SlideReceiptType.setAnimationEffects.rawValue }
        XCTAssertEqual(treeReceipts.count, 1, "setAnimationTree reuses the EXISTING setAnimationEffects receipt type")
        XCTAssertEqual(treeReceipts.first?.payload["effectCount"], .number(1))
    }

    // MARK: - setAnimationTree: identical-value no-op

    func testSetAnimationTreeWithIdenticalValueEmitsNoReceipt() async throws {
        let layer = try await SlideAnimTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        let deck = try await store.upsert(SlideDeck.makeBlank(title: "SetAnimationTree NoOp Gate Test"))
        let flat: AnimationEffectList = [
            AnimationEffect(targetBlockID: deck.body.rootChildren[0], presetID: "fade", trigger: .onClick, durationMS: 300, delayMS: 0),
        ]
        let tree = SMILAnimationTree(flat: flat)
        _ = try await store.setAnimationTree(tree, forSlideAt: 0, for: deck.id)

        let receiptsBefore = try await slideReceipts(store, forDeck: deck.id).count
        _ = try await store.setAnimationTree(tree, forSlideAt: 0, for: deck.id)
        let receiptsAfter = try await slideReceipts(store, forDeck: deck.id).count

        XCTAssertEqual(receiptsAfter, receiptsBefore, "setting the identical tree again must not append a receipt")
    }

    /// A tree lifted from a slide's EXISTING flat-only (pre-P2)
    /// animations must ALSO be recognized as identical - the no-op
    /// check compares against `effectiveAnimationTree`, not the raw
    /// (possibly-nil) `animationTree` field.
    func testSetAnimationTreeEquivalentToExistingFlatOnlyAnimationsEmitsNoReceipt() async throws {
        let layer = try await SlideAnimTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        let deck = try await store.upsert(SlideDeck.makeBlank(title: "SetAnimationTree LiftedNoOp Gate Test"))
        let flat: AnimationEffectList = [
            AnimationEffect(targetBlockID: deck.body.rootChildren[0], presetID: "wipe", trigger: .onClick, durationMS: 300, delayMS: 0),
        ]
        _ = try await store.setAnimations(flat, forSlideAt: 0, for: deck.id) // pre-P2 flat-only write path

        let receiptsBefore = try await slideReceipts(store, forDeck: deck.id).count
        _ = try await store.setAnimationTree(SMILAnimationTree(flat: flat), forSlideAt: 0, for: deck.id)
        let receiptsAfter = try await slideReceipts(store, forDeck: deck.id).count

        XCTAssertEqual(receiptsAfter, receiptsBefore, "a tree equivalent to the slide's existing flat-only animations (via lift) must not be treated as a change")
    }

    // MARK: - setAnimationTree: error path

    func testSetAnimationTreeOfOutOfBoundsSlideIndexThrowsWithoutPersisting() async throws {
        let layer = try await SlideAnimTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        let deck = try await store.upsert(SlideDeck.makeBlank(title: "SetAnimationTree ErrorPath Gate Test"))
        let tree = SMILAnimationTree(flat: [])

        do {
            _ = try await store.setAnimationTree(tree, forSlideAt: 9, for: deck.id)
            XCTFail("expected SlideStoreError.slideOutOfBounds")
        } catch SlideStoreError.slideOutOfBounds(let index, _) {
            XCTAssertEqual(index, 9)
        }

        let receipts = try await slideReceipts(store, forDeck: deck.id)
        XCTAssertTrue(receipts.filter { $0.receiptType == SlideReceiptType.setAnimationEffects.rawValue }.isEmpty)
    }

    // MARK: - clearAnimationTree: receipt + persistence

    func testClearAnimationTreeEmitsExactlyOneReceiptAndClearsBothFields() async throws {
        let layer = try await SlideAnimTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        var deck = try await store.upsert(SlideDeck.makeBlank(title: "ClearAnimationTree Gate Test"))
        let flat: AnimationEffectList = [
            AnimationEffect(targetBlockID: deck.body.rootChildren[0], presetID: "zoom", trigger: .onClick, durationMS: 200, delayMS: 0),
        ]
        deck = try await store.setAnimationTree(SMILAnimationTree(flat: flat), forSlideAt: 0, for: deck.id)

        let updated = try await store.clearAnimationTree(forSlideAt: 0, for: deck.id)
        let key = updated.body.rootChildren[0].uuidString
        XCTAssertNil(updated.slideMeta[key]?.animationTree)
        XCTAssertNil(updated.slideMeta[key]?.animations)

        let receipts = try await slideReceipts(store, forDeck: deck.id)
        let clearReceipts = receipts.filter { $0.receiptType == SlideReceiptType.removeAnimationEffect.rawValue }
        XCTAssertEqual(clearReceipts.count, 1, "clearAnimationTree reuses the EXISTING removeAnimationEffect receipt type")
    }

    // MARK: - clearAnimationTree: already-clear no-op

    func testClearAnimationTreeOfASlideWithNoAnimationsEmitsNoReceipt() async throws {
        let layer = try await SlideAnimTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        let deck = try await store.upsert(SlideDeck.makeBlank(title: "ClearAnimationTree NoOp Gate Test"))

        let receiptsBefore = try await slideReceipts(store, forDeck: deck.id).count
        _ = try await store.clearAnimationTree(forSlideAt: 0, for: deck.id)
        let receiptsAfter = try await slideReceipts(store, forDeck: deck.id).count

        XCTAssertEqual(receiptsAfter, receiptsBefore, "clearing an already-empty animation tree must not append a receipt")
    }

    // MARK: - defineCustomShow: receipt + persistence

    func testDefineCustomShowEmitsExactlyOneReceiptAndPersistsTheShow() async throws {
        let layer = try await SlideAnimTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        let deck = try await store.upsert(SlideDeck.makeBlank(title: "DefineCustomShow Gate Test"))
        let slideID = deck.body.rootChildren[0]

        let updated = try await store.defineCustomShow(name: "Quick Tour", slideIDs: [slideID], for: deck.id)
        XCTAssertEqual(updated.effectiveCustomShows.count, 1)
        XCTAssertEqual(updated.effectiveCustomShows.first?.name, "Quick Tour")
        XCTAssertEqual(updated.effectiveCustomShows.first?.slideIDs, [slideID])

        let receipts = try await slideReceipts(store, forDeck: deck.id)
        let defineReceipts = receipts.filter { $0.receiptType == SlideReceiptType.defineCustomShow.rawValue }
        XCTAssertEqual(defineReceipts.count, 1)
        XCTAssertEqual(defineReceipts.first?.payload["name"], .string("Quick Tour"))
    }

    // MARK: - updateCustomShow: receipt + persistence, and no-op paths

    func testUpdateCustomShowEmitsExactlyOneReceiptAndReplacesNameAndSlides() async throws {
        let layer = try await SlideAnimTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        var deck = try await store.upsert(SlideDeck.makeBlank(title: "UpdateCustomShow Gate Test"))
        deck = deck.insertingSlide(at: 1, layout: .blank)
        deck = try await store.upsert(deck)
        let slide0 = deck.body.rootChildren[0]
        let slide1 = deck.body.rootChildren[1]
        deck = try await store.defineCustomShow(name: "Original", slideIDs: [slide0], for: deck.id)
        let showID = try XCTUnwrap(deck.effectiveCustomShows.first?.id)

        let updated = try await store.updateCustomShow(showID, name: "Renamed", slideIDs: [slide0, slide1], for: deck.id)
        XCTAssertEqual(updated.effectiveCustomShows.first?.name, "Renamed")
        XCTAssertEqual(updated.effectiveCustomShows.first?.slideIDs, [slide0, slide1])

        let receipts = try await slideReceipts(store, forDeck: deck.id)
        let updateReceipts = receipts.filter { $0.receiptType == SlideReceiptType.updateCustomShow.rawValue }
        XCTAssertEqual(updateReceipts.count, 1)
    }

    func testUpdateCustomShowOfUnknownIDEmitsNoReceipt() async throws {
        let layer = try await SlideAnimTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        let deck = try await store.upsert(SlideDeck.makeBlank(title: "UpdateCustomShow NoOp Gate Test"))

        let receiptsBefore = try await slideReceipts(store, forDeck: deck.id).count
        _ = try await store.updateCustomShow(UUID(), name: "Ghost", slideIDs: [], for: deck.id)
        let receiptsAfter = try await slideReceipts(store, forDeck: deck.id).count

        XCTAssertEqual(receiptsAfter, receiptsBefore, "updating an unknown show id must not append a receipt")
    }

    func testUpdateCustomShowWithIdenticalNameAndSlidesEmitsNoReceipt() async throws {
        let layer = try await SlideAnimTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        var deck = try await store.upsert(SlideDeck.makeBlank(title: "UpdateCustomShow IdenticalNoOp Gate Test"))
        let slideID = deck.body.rootChildren[0]
        deck = try await store.defineCustomShow(name: "Same", slideIDs: [slideID], for: deck.id)
        let showID = try XCTUnwrap(deck.effectiveCustomShows.first?.id)

        let receiptsBefore = try await slideReceipts(store, forDeck: deck.id).count
        _ = try await store.updateCustomShow(showID, name: "Same", slideIDs: [slideID], for: deck.id)
        let receiptsAfter = try await slideReceipts(store, forDeck: deck.id).count

        XCTAssertEqual(receiptsAfter, receiptsBefore, "resubmitting the identical name+slides must not append a receipt")
    }

    // MARK: - removeCustomShow: receipt + persistence, and no-op path

    func testRemoveCustomShowEmitsExactlyOneReceiptAndDropsTheShow() async throws {
        let layer = try await SlideAnimTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        var deck = try await store.upsert(SlideDeck.makeBlank(title: "RemoveCustomShow Gate Test"))
        let slideID = deck.body.rootChildren[0]
        deck = try await store.defineCustomShow(name: "Doomed", slideIDs: [slideID], for: deck.id)
        let showID = try XCTUnwrap(deck.effectiveCustomShows.first?.id)

        let updated = try await store.removeCustomShow(showID, for: deck.id)
        XCTAssertTrue(updated.effectiveCustomShows.isEmpty)

        let receipts = try await slideReceipts(store, forDeck: deck.id)
        let removeReceipts = receipts.filter { $0.receiptType == SlideReceiptType.removeCustomShow.rawValue }
        XCTAssertEqual(removeReceipts.count, 1)
    }

    func testRemoveCustomShowOfUnknownIDEmitsNoReceipt() async throws {
        let layer = try await SlideAnimTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        let deck = try await store.upsert(SlideDeck.makeBlank(title: "RemoveCustomShow NoOp Gate Test"))

        let receiptsBefore = try await slideReceipts(store, forDeck: deck.id).count
        _ = try await store.removeCustomShow(UUID(), for: deck.id)
        let receiptsAfter = try await slideReceipts(store, forDeck: deck.id).count

        XCTAssertEqual(receiptsAfter, receiptsBefore, "removing an unknown show id must not append a receipt")
    }
}
