import Foundation

// MARK: - TransitionStore

/// The Slides material's seam for slide-transition assignment (P1 1.6,
/// refinement doc section 4, Slides cluster) - a peer of
/// ``MasterPageStore``, not a v2 of it. Unlike master pages, the
/// transition VOCABULARY (``TransitionCatalog``) is a single static
/// catalog shared by every deck, not a per-deck custom collection - so
/// this store has no `define`/`undefine` pair, only the per-slide
/// assignment mutation.
///
/// **Receipt contract:** every mutation appends a signed receipt to
/// `graph_receipts` with a `receipt_type` from ``SlideReceiptType``,
/// matching `SlideStore`/`MasterPageStore`'s own contract.
///
/// **Known gap - assignment is not yet persisted.** `SlideMeta`
/// (`SlideDeck.swift`) has fields for `layout`, `notes`, and
/// `masterPageID` only; it has no field to hold a per-slide transition
/// id. `SlideDeck.swift` is outside this deliverable's file list (a
/// shared checkout with other agents touching different files this
/// batch), so ``setSlideTransition(_:forSlideAt:for:)`` validates the
/// assignment and records it as a receipt (`payload["persisted"] ==
/// false`) but does not write it into the deck body. A follow-up patch
/// that adds `SlideMeta.transitionID: String?` (mirroring
/// `masterPageID`'s `nil`-means-none optional, but `String?` since it
/// names a ``TransitionCatalog`` entry, not a `UUID`) is what turns
/// this into a real assignment - see the P1 1.6 task report.
public struct TransitionStore: Sendable {

    private let dataLayer: TesseraDataLayer

    public init(dataLayer: TesseraDataLayer) {
        self.dataLayer = dataLayer
    }

    // MARK: - Mutations

    /// Assign (or clear, with `id: nil`) the transition a slide plays
    /// when it enters. `id` must resolve in ``TransitionCatalog`` or
    /// this throws ``TransitionStoreError/unknownTransitionID(_:)``
    /// before anything is recorded - an unresolvable id is rejected,
    /// never silently accepted. See the type doc's "Known gap": the
    /// returned deck's `slideMeta` is unchanged today.
    @discardableResult
    public func setSlideTransition(
        _ id: String?,
        forSlideAt index: Int,
        for deckID: UUID
    ) async throws -> SlideDeck {
        let deck = try await loadOrFail(id: deckID)
        guard index >= 0, index < deck.slideCount else {
            throw SlideStoreError.slideOutOfBounds(index: index, count: deck.slideCount)
        }
        if let id, TransitionCatalog.spec(forID: id) == nil {
            throw TransitionStoreError.unknownTransitionID(id)
        }
        try await appendReceipt(
            entityID: deckID,
            receiptType: SlideReceiptType.setSlideTransition.rawValue,
            payload: [
                "index": .number(Double(index)),
                "transitionID": id.map { .string($0) } ?? .null,
                "persisted": .bool(false),
            ]
        )
        return deck
    }

    // MARK: - Helpers

    /// Mirrors `MasterPageStore`'s own `loadOrFail` shape - see that
    /// file for why each store duplicates rather than shares this
    /// boilerplate (no base class; the data layer actor is the only
    /// shared seam).
    private func loadOrFail(id: UUID) async throws -> SlideDeck {
        guard let entity = try await dataLayer.getEntity(id: id),
              entity.entityType == SlideDeck.entityType,
              entity.subtype == SlideDeck.subtype,
              let body = entity.body, !body.isEmpty
        else {
            throw SlideStoreError.deckNotFound(id: id)
        }
        return try SlideDeck.from(jsonDataString: body)
    }

    private func appendReceipt(
        entityID: UUID, receiptType: String, payload: [String: JSONValue]
    ) async throws {
        _ = try await dataLayer.appendReceipt(
            entityID: entityID, receiptType: receiptType, payload: payload)
    }
}

// MARK: - TransitionStoreError

public enum TransitionStoreError: Error, Sendable, Equatable {
    /// `id` does not resolve to any ``TransitionCatalog`` entry.
    case unknownTransitionID(String)
}
