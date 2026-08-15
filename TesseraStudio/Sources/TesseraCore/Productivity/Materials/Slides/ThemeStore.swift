import Foundation

// MARK: - ThemeStore

/// The Slides material's seam for theme mutations (P1 1.5) - a peer
/// of ``MasterPageStore``, not a v2 of it: theme state lives inside a
/// `SlideDeck`'s own body, so this store operates on the SAME
/// `graph_entity` rows every other Slides store does, through its own
/// `TesseraDataLayer` reference, mirroring `MasterPageStore`'s
/// struct-not-actor shape for the same reason - the data layer actor
/// is the source of concurrency safety, this store holds no state of
/// its own.
///
/// **Storage note - deck-level state, mirrored per master:** the
/// design contract (studio-expansion-design-refinement-2026-08-14.md
/// section 4, Slides cluster, item 1.5) describes the theme catalog
/// and the active-theme selection as deck-level concepts, but
/// `SlideDeck.swift` is out of scope for this file list (a large,
/// heavily cross-referenced file this pass deliberately avoids
/// touching), and Swift extensions cannot add new STORED properties
/// to a struct declared elsewhere - only `SlideMasterPage`, declared
/// in this file, can gain new fields. This store therefore mirrors
/// `SlideMasterPage.themeCatalog` / `.activeThemeID` onto EVERY
/// master page in the deck, atomically, on every mutation
/// (`SlideDeck.settingTheme(_:)` / `.settingActiveThemeID(_:)`,
/// `SlideMasterPage.swift`). Since this store is the only writer of
/// those two fields and always applies the same value to every
/// master, they can never drift, so any one master's copy is
/// authoritative (`SlideDeck.effectiveThemes` / `.activeTheme` read
/// from `effectiveMasterPages.values.first`). A deck needs at least
/// one master page defined (`MasterPageStore.defineMasterPage`)
/// before a theme can be defined or activated here -
/// `ThemeStoreError.noMasterPages` is thrown rather than silently
/// no-oping. The clean fix is two small additive fields directly on
/// `SlideDeck` (`themes: [String: Theme]?`, `activeThemeID: UUID?`,
/// mirroring `masterPages`'s own optional-dict convention) in a
/// follow-up pass that touches that file.
///
/// **Receipt contract:** every mutation appends a signed receipt to
/// `graph_receipts` with a `receipt_type` from ``SlideReceiptType``
/// (`.defineTheme` / `.setDeckTheme`, added ahead of this batch).
public struct ThemeStore: Sendable {

    private let dataLayer: TesseraDataLayer

    public init(dataLayer: TesseraDataLayer) {
        self.dataLayer = dataLayer
    }

    // MARK: - Mutations

    /// Define (or replace, by matching `id`) a theme in `deckID`'s
    /// catalog. Throws `ThemeStoreError.noMasterPages` if the deck
    /// has none defined yet (see this file's own doc comment for why
    /// a master page is where the catalog is actually stored).
    @discardableResult
    public func defineTheme(_ theme: Theme, for deckID: UUID) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        guard !deck.effectiveMasterPages.isEmpty else {
            throw ThemeStoreError.noMasterPages(deckID: deckID)
        }
        let replacedPrevious = deck.effectiveThemes[theme.id.uuidString] != nil
        deck = deck.settingTheme(theme)
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID,
            receiptType: SlideReceiptType.defineTheme.rawValue,
            payload: [
                "themeID": .string(theme.id.uuidString),
                "name": .string(theme.name),
                "replacedPrevious": .bool(replacedPrevious),
            ]
        )
        return deck
    }

    /// Set (or clear, with `themeID: nil`) the deck's active theme.
    /// Throws `ThemeStoreError.themeNotFound` if `themeID` doesn't
    /// match a catalog entry defined via `defineTheme(_:for:)`, or
    /// `ThemeStoreError.noMasterPages` per `defineTheme(_:for:)`'s
    /// own note.
    @discardableResult
    public func setDeckTheme(_ themeID: UUID?, for deckID: UUID) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        guard !deck.effectiveMasterPages.isEmpty else {
            throw ThemeStoreError.noMasterPages(deckID: deckID)
        }
        if let themeID, deck.effectiveThemes[themeID.uuidString] == nil {
            throw ThemeStoreError.themeNotFound(id: themeID)
        }
        deck = deck.settingActiveThemeID(themeID)
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID,
            receiptType: SlideReceiptType.setDeckTheme.rawValue,
            payload: ["themeID": themeID.map { .string($0.uuidString) } ?? .null]
        )
        return deck
    }

    // MARK: - Helpers

    /// Mirrors `MasterPageStore`'s own `upsert`/`loadOrFail` shape -
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

// MARK: - ThemeStoreError

/// Errors specific to theme mutations with no existing
/// ``SlideStoreError`` equivalent - "deck not found" reuses
/// ``SlideStoreError/deckNotFound(id:)`` the same way this file's
/// `loadOrFail` does, rather than duplicating it.
public enum ThemeStoreError: Error, Sendable, Equatable {
    /// `defineTheme`/`setDeckTheme` need at least one master page to
    /// carry the deck-level theme state - see this file's own doc
    /// comment. Define one via `MasterPageStore.defineMasterPage`
    /// first.
    case noMasterPages(deckID: UUID)
    /// `setDeckTheme` was given an id with no matching catalog entry.
    case themeNotFound(id: UUID)
}
