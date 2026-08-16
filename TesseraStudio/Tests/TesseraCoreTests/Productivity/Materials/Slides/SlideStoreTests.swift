import XCTest
import Foundation
@testable import TesseraCore

// MARK: - SlideStoreTests
//
// Contract sources: SlideStore.swift's own doc comment ("Receipt
// contract: every mutation that changes deck state... appends a signed
// receipt"), testing-doctrine.md rule 1 ("no receipt without a
// mutation" is a standing rule; its tests are mandatory per store
// method, both directions), SlideMeta.swift's `animations` field doc
// comment (P2-0, this cluster's own item 1), MediaBlock.swift +
// SlideReceiptType's `.attachMedia`/`.removeMedia` cases (P2-0 item 2),
// and Comments.swift's `CommentThread.addingReply(_:)`/`.resolved()` +
// `SlideDeck.replacingCommentThread(_:)`/`.removingCommentThread(id:)`
// pre-landed helpers (P2-0 item 5).
//
// DB-GATED (doctrine rule 11): every test in this file talks to a real
// TesseraDataLayer (Postgres + Valkey) and is skipped unless
// TESSERA_DB_INTEGRATION=1 is set AND the stores are actually reachable
// - mirrors DrawingStoreTests.swift's own `DrawTestDataLayer` gate
// exactly (that file's header comment explains why: this cluster's
// store tests have no in-memory data-layer double to fall back to).
// Store-level animation/media/comment mutations wrap pure SlideDeck/
// SlideMeta field writes that have no separate pure-mutator type to
// give an ungated shadow to (unlike DrawingStore's group/ungroup,
// which delegates to `DrawingStore.applyingGroup`/`.applyingUngroup`) -
// the mutation IS "set an optional struct field" or "append/replace an
// array entry", already covered by SlideDeck/Comments' own round-trip
// and helper tests; what THIS file adds is the receipts-law wiring
// that only exists at the store level.

private enum SlideTestDataLayer {
    /// Starts a real `TesseraDataLayer` against the default local
    /// Postgres/Valkey configuration. Skips the calling test (via
    /// `XCTSkip`) rather than failing when TESSERA_DB_INTEGRATION isn't
    /// set, or when it is set but the local stores aren't actually up -
    /// mirrors `DrawingStoreTests.swift`'s `DrawTestDataLayer` helper.
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

final class SlideStoreTests: DoctrineTestCase {
    override var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.standard }

    /// `SlideStore.upsert`/`delete` schedule a "material receipt" on an
    /// unawaited `Task` (fire-and-forget, documented as intentional -
    /// same shape as `SheetStore`'s). A before/after receipt-count
    /// snapshot taken immediately after a mutation can race that
    /// still-in-flight task and see it land on the WRONG side of the
    /// snapshot, miscounting a genuine no-op as a mutation (or vice
    /// versa) - not a receipts-law violation, a test-timing artifact.
    /// Filtering out `SlideReceiptPayload.receiptType` here is this
    /// file's copy of `SheetStoreTests.sheetReceipts(_:forSheet:)`,
    /// the fix already established for the identical race there.
    private func slideReceipts(_ store: SlideStore, forDeck id: UUID) async throws -> [GraphReceipt] {
        try await store.receipts(forDeck: id).filter { $0.receiptType != SlideReceiptPayload.receiptType }
    }

    // MARK: - setAnimations: receipt + persistence (rule 1, mutation direction)

    func testSetAnimationsEmitsExactlyOneReceiptAndPersistsTheEffectList() async throws {
        let layer = try await SlideTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        let deck = try await store.upsert(SlideDeck.makeBlank(title: "Animations Gate Test"))
        let effect = AnimationEffect(
            targetBlockID: deck.body.rootChildren[0], presetID: "flyIn", trigger: .onClick, durationMS: 400, delayMS: 0)

        let updated = try await store.setAnimations([effect], forSlideAt: 0, for: deck.id)
        XCTAssertEqual(updated.slide(at: 0)?.layout, deck.slide(at: 0)?.layout, "setAnimations must not touch layout")

        let fetched = try await store.get(id: deck.id)
        let key = fetched?.body.rootChildren[0].uuidString ?? ""
        XCTAssertEqual(fetched?.slideMeta[key]?.effectiveAnimations, [effect])

        let receipts = try await slideReceipts(store, forDeck: deck.id)
        let animationReceipts = receipts.filter { $0.receiptType == SlideReceiptType.setAnimationEffects.rawValue }
        XCTAssertEqual(animationReceipts.count, 1)
        XCTAssertEqual(animationReceipts.first?.payload["effectCount"], .number(1))
    }

    // MARK: - setAnimations: identical-value no-op (rule 1, no-op direction)

    func testSetAnimationsWithIdenticalValueEmitsNoReceipt() async throws {
        let layer = try await SlideTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        let deck = try await store.upsert(SlideDeck.makeBlank(title: "Animations NoOp Gate Test"))

        // Slide starts with no animations (effectiveAnimations == []);
        // setting [] again must not be treated as a change.
        let receiptsBefore = try await slideReceipts(store, forDeck: deck.id).count
        _ = try await store.setAnimations([], forSlideAt: 0, for: deck.id)
        let receiptsAfter = try await slideReceipts(store, forDeck: deck.id).count

        XCTAssertEqual(receiptsAfter, receiptsBefore, "setting an empty list when the slide already has no animations must not append a receipt")
    }

    // MARK: - setAnimations: error path

    func testSetAnimationsOfOutOfBoundsSlideIndexThrowsWithoutPersisting() async throws {
        let layer = try await SlideTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        let deck = try await store.upsert(SlideDeck.makeBlank(title: "Animations ErrorPath Gate Test"))

        do {
            _ = try await store.setAnimations([], forSlideAt: 5, for: deck.id)
            XCTFail("expected SlideStoreError.slideOutOfBounds")
        } catch SlideStoreError.slideOutOfBounds(let index, _) {
            XCTAssertEqual(index, 5)
        }

        let receipts = try await slideReceipts(store, forDeck: deck.id)
        XCTAssertTrue(receipts.filter { $0.receiptType == SlideReceiptType.setAnimationEffects.rawValue }.isEmpty)
    }

    // MARK: - removeAnimationEffect: receipt + persistence

    func testRemoveAnimationEffectEmitsExactlyOneReceiptAndRemovesTheEntry() async throws {
        let layer = try await SlideTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        var deck = try await store.upsert(SlideDeck.makeBlank(title: "RemoveAnimation Gate Test"))
        let blockID = deck.body.rootChildren[0]
        let a = AnimationEffect(targetBlockID: blockID, presetID: "fade", trigger: .onClick, durationMS: 300, delayMS: 0)
        let b = AnimationEffect(targetBlockID: blockID, presetID: "wipe", trigger: .withPrevious, durationMS: 300, delayMS: 0)
        deck = try await store.setAnimations([a, b], forSlideAt: 0, for: deck.id)

        let updated = try await store.removeAnimationEffect(at: 0, forSlideAt: 0, for: deck.id)
        let key = updated.body.rootChildren[0].uuidString
        XCTAssertEqual(updated.slideMeta[key]?.effectiveAnimations, [b])

        let receipts = try await slideReceipts(store, forDeck: deck.id)
        let removeReceipts = receipts.filter { $0.receiptType == SlideReceiptType.removeAnimationEffect.rawValue }
        XCTAssertEqual(removeReceipts.count, 1)
    }

    // MARK: - removeAnimationEffect: out-of-range no-op

    func testRemoveAnimationEffectOfOutOfRangeIndexEmitsNoReceipt() async throws {
        let layer = try await SlideTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        let deck = try await store.upsert(SlideDeck.makeBlank(title: "RemoveAnimation NoOp Gate Test"))

        let receiptsBefore = try await slideReceipts(store, forDeck: deck.id).count
        _ = try await store.removeAnimationEffect(at: 0, forSlideAt: 0, for: deck.id)
        let receiptsAfter = try await slideReceipts(store, forDeck: deck.id).count

        XCTAssertEqual(receiptsAfter, receiptsBefore, "removing an effect index from a slide with no animations must not append a receipt")
    }

    // MARK: - attachMedia: receipt + persistence, slide slicing includes it

    func testAttachMediaEmitsExactlyOneReceiptAndTheSlideSliceIncludesTheMediaBlock() async throws {
        let layer = try await SlideTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        let deck = try await store.upsert(SlideDeck.makeBlank(title: "AttachMedia Gate Test"))
        let media = MediaBlock(kind: .video, sourceURL: "assets/demo.mp4")

        let updated = try await store.attachMedia(media, toSlideAt: 0, for: deck.id)

        let slice = updated.slide(at: 0)
        let mediaBlocks = slice?.body.blocks.values.filter { $0.type == .media } ?? []
        XCTAssertEqual(mediaBlocks.count, 1)
        XCTAssertEqual(mediaBlocks.first?.media, media)

        let receipts = try await slideReceipts(store, forDeck: deck.id)
        let attachReceipts = receipts.filter { $0.receiptType == SlideReceiptType.attachMedia.rawValue }
        XCTAssertEqual(attachReceipts.count, 1)
        XCTAssertEqual(attachReceipts.first?.payload["kind"], .string("video"))
    }

    // MARK: - removeMedia: receipt + persistence

    func testRemoveMediaEmitsExactlyOneReceiptAndDropsTheBlock() async throws {
        let layer = try await SlideTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        var deck = try await store.upsert(SlideDeck.makeBlank(title: "RemoveMedia Gate Test"))
        deck = try await store.attachMedia(MediaBlock(kind: .audio, sourceURL: "assets/a.mp3"), toSlideAt: 0, for: deck.id)
        let mediaBlockID = deck.slide(at: 0)?.body.blocks.values.first { $0.type == .media }?.id
        let mediaID = try XCTUnwrap(mediaBlockID)

        let updated = try await store.removeMedia(mediaID, for: deck.id)
        XCTAssertNil(updated.body.blocks[mediaID])

        let receipts = try await slideReceipts(store, forDeck: deck.id)
        let removeReceipts = receipts.filter { $0.receiptType == SlideReceiptType.removeMedia.rawValue }
        XCTAssertEqual(removeReceipts.count, 1)
    }

    // MARK: - removeMedia: unknown id no-op

    func testRemoveMediaOfUnknownIDEmitsNoReceipt() async throws {
        let layer = try await SlideTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        let deck = try await store.upsert(SlideDeck.makeBlank(title: "RemoveMedia NoOp Gate Test"))

        let receiptsBefore = try await slideReceipts(store, forDeck: deck.id).count
        _ = try await store.removeMedia(UUID(), for: deck.id)
        let receiptsAfter = try await slideReceipts(store, forDeck: deck.id).count

        XCTAssertEqual(receiptsAfter, receiptsBefore, "removing an unknown media block id must not append a receipt")
    }

    // MARK: - Comment lifecycle: reply

    func testReplyToCommentEmitsExactlyOneReceiptAndAppendsTheMessage() async throws {
        let layer = try await SlideTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        var deck = try await store.upsert(SlideDeck.makeBlank(title: "ReplyComment Gate Test"))
        let slideID = deck.body.rootChildren[0]
        deck = try await store.addComment(anchor: .slide(slideID), author: "alice", text: "root", for: deck.id)
        let threadID = try XCTUnwrap(deck.effectiveCommentThreads.first?.id)

        let updated = try await store.replyToComment(threadID, author: "bob", text: "reply", for: deck.id)
        let thread = try XCTUnwrap(updated.effectiveCommentThreads.first { $0.id == threadID })
        XCTAssertEqual(thread.messages.count, 2)
        XCTAssertEqual(thread.messages.last?.text, "reply")

        let receipts = try await slideReceipts(store, forDeck: deck.id)
        let replyReceipts = receipts.filter { $0.receiptType == SlideReceiptType.commentReplied.rawValue }
        XCTAssertEqual(replyReceipts.count, 1)
    }

    func testReplyToCommentOfUnknownThreadIDEmitsNoReceipt() async throws {
        let layer = try await SlideTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        let deck = try await store.upsert(SlideDeck.makeBlank(title: "ReplyComment NoOp Gate Test"))

        let receiptsBefore = try await slideReceipts(store, forDeck: deck.id).count
        _ = try await store.replyToComment(UUID(), author: "bob", text: "reply", for: deck.id)
        let receiptsAfter = try await slideReceipts(store, forDeck: deck.id).count

        XCTAssertEqual(receiptsAfter, receiptsBefore, "replying to an unknown thread id must not append a receipt")
    }

    // MARK: - Comment lifecycle: resolve

    func testResolveCommentEmitsExactlyOneReceiptAndSetsIsResolved() async throws {
        let layer = try await SlideTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        var deck = try await store.upsert(SlideDeck.makeBlank(title: "ResolveComment Gate Test"))
        let slideID = deck.body.rootChildren[0]
        deck = try await store.addComment(anchor: .slide(slideID), author: "alice", text: "root", for: deck.id)
        let threadID = try XCTUnwrap(deck.effectiveCommentThreads.first?.id)

        let updated = try await store.resolveComment(threadID, for: deck.id)
        XCTAssertEqual(updated.effectiveCommentThreads.first { $0.id == threadID }?.isResolved, true)

        let receipts = try await slideReceipts(store, forDeck: deck.id)
        let resolveReceipts = receipts.filter { $0.receiptType == SlideReceiptType.commentResolved.rawValue }
        XCTAssertEqual(resolveReceipts.count, 1)
    }

    func testResolveCommentOfAlreadyResolvedThreadEmitsNoReceipt() async throws {
        let layer = try await SlideTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        var deck = try await store.upsert(SlideDeck.makeBlank(title: "ResolveComment NoOp Gate Test"))
        let slideID = deck.body.rootChildren[0]
        deck = try await store.addComment(anchor: .slide(slideID), author: "alice", text: "root", for: deck.id)
        let threadID = try XCTUnwrap(deck.effectiveCommentThreads.first?.id)
        deck = try await store.resolveComment(threadID, for: deck.id)

        let receiptsBefore = try await slideReceipts(store, forDeck: deck.id).count
        _ = try await store.resolveComment(threadID, for: deck.id)
        let receiptsAfter = try await slideReceipts(store, forDeck: deck.id).count

        XCTAssertEqual(receiptsAfter, receiptsBefore, "resolving an already-resolved thread must not append a receipt")
    }

    // MARK: - Comment lifecycle: delete

    func testDeleteCommentEmitsExactlyOneReceiptAndRemovesTheThread() async throws {
        let layer = try await SlideTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        var deck = try await store.upsert(SlideDeck.makeBlank(title: "DeleteComment Gate Test"))
        let slideID = deck.body.rootChildren[0]
        deck = try await store.addComment(anchor: .slide(slideID), author: "alice", text: "root", for: deck.id)
        let threadID = try XCTUnwrap(deck.effectiveCommentThreads.first?.id)

        let updated = try await store.deleteComment(threadID, for: deck.id)
        XCTAssertTrue(updated.effectiveCommentThreads.isEmpty)

        let receipts = try await slideReceipts(store, forDeck: deck.id)
        let deleteReceipts = receipts.filter { $0.receiptType == SlideReceiptType.commentDeleted.rawValue }
        XCTAssertEqual(deleteReceipts.count, 1)
    }

    func testDeleteCommentOfUnknownThreadIDEmitsNoReceipt() async throws {
        let layer = try await SlideTestDataLayer.startedOrSkip()
        let store = SlideStore(dataLayer: layer)
        let deck = try await store.upsert(SlideDeck.makeBlank(title: "DeleteComment NoOp Gate Test"))

        let receiptsBefore = try await slideReceipts(store, forDeck: deck.id).count
        _ = try await store.deleteComment(UUID(), for: deck.id)
        let receiptsAfter = try await slideReceipts(store, forDeck: deck.id).count

        XCTAssertEqual(receiptsAfter, receiptsBefore, "deleting an unknown thread id must not append a receipt")
    }
}
