import Foundation

// MARK: - MasterPageStore

/// The Slides material's seam for master-page mutations - a peer of
/// ``SlideStore``, not a v2 of it (studio-expansion-plan.md 0.7):
/// master pages live inside a `SlideDeck`'s own body, so this store
/// operates on the SAME `graph_entity` rows `SlideStore` does, through
/// its own `TesseraDataLayer` reference, mirroring `SlideStore`'s
/// struct-not-actor shape for the same reason - the data layer actor
/// is the source of concurrency safety, this store holds no state of
/// its own.
///
/// **Receipt contract:** every mutation appends a signed receipt to
/// `graph_receipts` with a `receipt_type` from ``SlideReceiptType``,
/// matching `SlideStore`'s own contract exactly (the receipt vocabulary
/// is shared - see `SlideReceiptType.defineMasterPage` etc.).
public struct MasterPageStore: Sendable {

    private let dataLayer: TesseraDataLayer

    public init(dataLayer: TesseraDataLayer) {
        self.dataLayer = dataLayer
    }

    // MARK: - Mutations

    /// Define (or replace, by matching `id`) a master page on `deckID`.
    @discardableResult
    public func defineMasterPage(_ master: SlideMasterPage, for deckID: UUID) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        let replacedPrevious = deck.effectiveMasterPages[master.id.uuidString] != nil
        deck = deck.settingMasterPage(master)
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID,
            receiptType: SlideReceiptType.defineMasterPage.rawValue,
            payload: [
                "masterPageID": .string(master.id.uuidString),
                "name": .string(master.name),
                "replacedPrevious": .bool(replacedPrevious),
            ]
        )
        return deck
    }

    /// Remove a master page. Every slide referencing it falls back to
    /// no master (see `SlideDeck.removingMasterPage(_:)`). A no-op
    /// (still persisted, no receipt) if `masterPageID` isn't defined.
    @discardableResult
    public func undefineMasterPage(_ masterPageID: UUID, for deckID: UUID) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        guard deck.effectiveMasterPages[masterPageID.uuidString] != nil else { return deck }
        deck = deck.removingMasterPage(masterPageID)
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID,
            receiptType: SlideReceiptType.undefineMasterPage.rawValue,
            payload: ["masterPageID": .string(masterPageID.uuidString)]
        )
        return deck
    }

    /// Assign (or clear, with `masterPageID: nil`) the master page a
    /// slide uses.
    @discardableResult
    public func setMasterPage(
        _ masterPageID: UUID?,
        forSlideAt index: Int,
        for deckID: UUID
    ) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        guard index >= 0, index < deck.slideCount else {
            throw SlideStoreError.slideOutOfBounds(index: index, count: deck.slideCount)
        }
        let key = deck.body.rootChildren[index].uuidString
        var meta = deck.slideMeta[key] ?? .default
        meta.masterPageID = masterPageID
        deck.slideMeta[key] = meta
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID,
            receiptType: SlideReceiptType.setSlideMasterPage.rawValue,
            payload: [
                "index": .number(Double(index)),
                "masterPageID": masterPageID.map { .string($0.uuidString) } ?? .null,
            ]
        )
        return deck
    }

    // MARK: - Helpers

    /// Mirrors `SlideStore`'s own `upsert`/`get`/`loadOrFail` shape -
    /// see that file for why each store duplicates rather than shares
    /// this boilerplate (no base class; the data layer actor is the
    /// only shared seam).
    @discardableResult
    private func upsert(_ deck: SlideDeck) async throws -> SlideDeck {
        let body = try deck.jsonDataString()
        _ = try await dataLayer.upsertEntity(
            GraphEntityUpsert(
                id: deck.id,
                entityType: SlideDeck.entityType,
                subtype: SlideDeck.subtype,
                label: deck.displayTitle,
                body: body,
                sourceURL: nil,
                embedding: nil
            )
        )
        return deck
    }

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
