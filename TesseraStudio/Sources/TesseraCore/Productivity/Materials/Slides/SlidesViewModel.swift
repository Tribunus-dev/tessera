import Foundation
import SwiftUI

// MARK: - SlidesViewModel

/// The view-model for the Slides surface (the pptx/PDF deck library
/// + slide canvas). Owns the filtered list, the selection, the
/// search/tag/archived/trash states, the per-deck slide selection,
/// and the chat-panel integration.
///
/// `@MainActor` so all `@Published` writes happen on the main thread
/// (SwiftUI's expectation). The data layer facade is an actor; we
/// hop to it for reads and writes.
@MainActor
public final class SlidesViewModel: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var allDecks: [SlideDeck] = []
    @Published public private(set) var rows: [SlideDeckRow] = []
    @Published public var filter: SlideListFilter = .all
    @Published public var selectedDeckID: UUID?
    @Published public var selectedSlideIndex: Int = 0
    @Published public var activeTag: String?
    @Published public var searchText: String = ""
    @Published public var isLoading: Bool = false
    @Published public private(set) var loadError: String?
    @Published public private(set) var isChatDriven: Bool = false

    @Published public private(set) var editor: SlideDeckEditorViewModel?

    // MARK: - Dependencies

    public let store: SlideStore
    public let dataLayer: TesseraDataLayer
    public let userID: UserID

    public init(store: SlideStore, dataLayer: TesseraDataLayer, userID: UserID = UUID()) {
        self.store = store
        self.dataLayer = dataLayer
        self.userID = userID
    }

    // MARK: - Lifecycle

    public func refresh() async {
        isLoading = true
        loadError = nil
        do {
            let decks = try await store.list(limit: 1000)
            allDecks = decks
            applyFilter()
        } catch {
            loadError = String(describing: error)
        }
        isLoading = false
    }

    public func applyFilter() {
        var filtered = filter.apply(to: allDecks)
        if let tag = activeTag {
            filtered = filtered.filter { $0.tags.contains(tag) }
        }
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty {
            filtered = filtered.filter { deck in
                let hay = "\(deck.title.lowercased()) \(deck.tags.joined(separator: " ")) \(deck.snippet(maxLength: 1000).lowercased())"
                return hay.contains(needle)
            }
        }
        rows = filtered.map { SlideDeckRow(deck: $0) }
    }

    public func setAllDecksForTesting(_ decks: [SlideDeck]) {
        allDecks = decks
        applyFilter()
    }

    public func applyLocalSearch(_ needle: String) {
        searchText = needle
        applyFilter()
    }

    public var allTags: [String] {
        var seen: Set<String> = []
        for deck in allDecks { for tag in deck.tags { seen.insert(tag) } }
        return seen.sorted()
    }

    // MARK: - Selection

    public func select(_ deckID: UUID?) {
        selectedDeckID = deckID
        selectedSlideIndex = 0
        if let deckID, let deck = allDecks.first(where: { $0.id == deckID }) {
            editor = SlideDeckEditorViewModel(deck: deck, store: store, userID: userID)
        } else {
            editor = nil
        }
    }

    public func selectSlide(at index: Int) {
        guard let deck = selectedDeck, index >= 0, index < deck.slideCount else { return }
        selectedSlideIndex = index
    }

    public var selectedDeck: SlideDeck? {
        guard let id = selectedDeckID else { return nil }
        return allDecks.first(where: { $0.id == id })
    }

    // MARK: - CRUD

    @discardableResult
    public func createDeck(title: String, tags: [String] = []) async throws -> SlideDeck {
        let now = Date()
        var deck = SlideDeck.makeBlank(title: title)
        deck = SlideDeck(
            id: UUID(),
            title: title,
            body: deck.body,
            slideMeta: deck.slideMeta,
            tags: SlideDeck.normalizeTags(tags),
            createdAt: now, updatedAt: now)
        _ = try await store.upsert(deck)
        await refresh()
        return deck
    }

    public func deleteSelected() async {
        guard let id = selectedDeckID else { return }
        do {
            _ = try await store.delete(id: id)
            selectedDeckID = nil
            editor = nil
            await refresh()
        } catch {
            loadError = String(describing: error)
        }
    }

    // MARK: - Slide mutations (through the editor)

    public func insertSlide(layout: SlideLayout = .titleAndContent) async {
        guard let id = selectedDeckID else { return }
        let at = selectedSlideIndex + 1
        // Clamp to post-state bounds (append at end when on last slide).
        let count = selectedDeck?.slideCount ?? 0
        let insertAt = min(at, count)
        do {
            let updated = try await store.insertSlide(at: insertAt, for: id, layout: layout)
            if let idx = allDecks.firstIndex(where: { $0.id == id }) { allDecks[idx] = updated }
            applyFilter()
            editor?.refresh(with: updated)
            selectedSlideIndex = min(insertAt, max(0, updated.slideCount - 1))
        } catch {
            loadError = String(describing: error)
        }
    }

    public func deleteSlide(at index: Int) async {
        guard let id = selectedDeckID else { return }
        do {
            let updated = try await store.deleteSlide(at: index, for: id)
            if let idx = allDecks.firstIndex(where: { $0.id == id }) { allDecks[idx] = updated }
            applyFilter()
            editor?.refresh(with: updated)
            selectedSlideIndex = min(index, max(0, updated.slideCount - 1))
        } catch {
            loadError = String(describing: error)
        }
    }

    public func moveSlide(from: Int, to: Int) async {
        guard let id = selectedDeckID else { return }
        do {
            let updated = try await store.moveSlide(from: from, to: to, for: id)
            if let idx = allDecks.firstIndex(where: { $0.id == id }) { allDecks[idx] = updated }
            applyFilter()
            editor?.refresh(with: updated)
            // Keep selection on the moved slide.
            selectedSlideIndex = to
        } catch {
            loadError = String(describing: error)
        }
    }

    // MARK: - Chat-panel integration

    @discardableResult
    public func chatCreateDeck(title: String, tags: [String] = []) async throws -> SlideDeck {
        isChatDriven = true
        defer { isChatDriven = false }
        return try await createDeck(title: title, tags: tags)
    }

    @discardableResult
    public func chatEditDeck(deckID: UUID, apply: (SlideStore) async throws -> SlideDeck) async throws -> SlideDeck {
        isChatDriven = true
        defer { isChatDriven = false }
        let updated = try await apply(store)
        await refresh()
        if selectedDeckID == deckID, let editor { editor.refresh(with: updated) }
        return updated
    }

    // MARK: - Tag chip

    public func setActiveTag(_ tag: String?) {
        activeTag = tag
        applyFilter()
    }
}

// MARK: - SlideListFilter

public enum SlideListFilter: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case all
    case favorites
    case archived
    case trash

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "All"
        case .favorites: return "Favorites"
        case .archived: return "Archived"
        case .trash: return "Trash"
        }
    }

    public var systemImage: String {
        switch self {
        case .all: return "rectangle.on.rectangle"
        case .favorites: return "star.fill"
        case .archived: return "archivebox"
        case .trash: return "trash"
        }
    }

    public func apply(to decks: [SlideDeck]) -> [SlideDeck] {
        switch self {
        case .all: return decks.filter { !$0.isTrashed && !$0.isArchived }.sorted { $0.updatedAt > $1.updatedAt }
        case .favorites: return decks.filter { $0.isFavorite && !$0.isTrashed && !$0.isArchived }.sorted { $0.updatedAt > $1.updatedAt }
        case .archived: return decks.filter { $0.isArchived && !$0.isTrashed }.sorted { $0.updatedAt > $1.updatedAt }
        case .trash: return decks.filter { $0.isTrashed }.sorted { $0.updatedAt > $1.updatedAt }
        }
    }
}

// MARK: - SlideDeckRow

public struct SlideDeckRow: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let title: String
    public let snippet: String
    public let tags: [String]
    public let updatedAt: Date
    public let relativeTime: String
    public let isFavorite: Bool
    public let isArchived: Bool
    public let isTrashed: Bool
    public let slideCount: Int
    public let wordCount: Int
    public let thumbnailHint: String?

    public init(deck: SlideDeck, now: Date = Date()) {
        self.id = deck.id
        self.title = deck.displayTitle
        self.snippet = deck.snippet(maxLength: 200)
        self.tags = deck.tags
        self.updatedAt = deck.updatedAt
        self.relativeTime = SlideDeckRow.relativeTimeString(for: deck.updatedAt, now: now)
        self.isFavorite = deck.isFavorite
        self.isArchived = deck.isArchived
        self.isTrashed = deck.isTrashed
        self.slideCount = deck.slideCount
        self.wordCount = deck.wordCount
        // First image block's source across any slide.
        var hint: String? = nil
        for slide in deck.slides where hint == nil { hint = slide.thumbnailHint }
        self.thumbnailHint = hint
    }

    public static func relativeTimeString(for date: Date, now: Date) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 0 { return "just now" }
        if delta < 60 { return "just now" }
        let minutes = Int(delta / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = Int(delta / 3600)
        if hours < 24 { return "\(hours) hr ago" }
        let calendar = Calendar.current
        if calendar.isDateInYesterday(date) { return "yesterday" }
        let days = Int(delta / 86400)
        if days < 14 { return "\(days) days ago" }
        let weeks = days / 7
        if weeks < 5 { return "\(weeks) weeks ago" }
        let formatter = DateFormatter()
        let isCurrentYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = isCurrentYear ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: date)
    }
}

// MARK: - SlideDeckEditorViewModel

@MainActor
public final class SlideDeckEditorViewModel: ObservableObject {

    @Published public private(set) var deck: SlideDeck
    @Published public private(set) var document: DocumentAST
    @Published public var draftTitle: String
    @Published public var draftTag: String
    @Published public var isSaving: Bool = false
    @Published public private(set) var lastError: String?

    public let store: SlideStore
    public let userID: UserID

    public init(deck: SlideDeck, store: SlideStore, userID: UserID) {
        self.deck = deck
        self.document = deck.body
        self.draftTitle = deck.title
        self.draftTag = ""
        self.store = store
        self.userID = userID
    }

    public func refresh(with deck: SlideDeck) {
        self.deck = deck
        self.document = deck.body
        self.draftTitle = deck.title
    }

    // MARK: - Slide view helpers

    public var slides: [Slide] { deck.slides }

    public func slide(at index: Int) -> Slide? { deck.slide(at: index) }

    // MARK: - Title

    public func commitTitle() async {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != deck.title else { return }
        isSaving = true; defer { isSaving = false }
        do {
            var updated = deck
            updated.title = trimmed
            updated.updatedAt = Date()
            _ = try await store.upsert(updated)
            self.deck = updated
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Body (deck-wide AST)

    public func commitBody(_ ast: DocumentAST) async {
        guard ast != deck.body else { return }
        isSaving = true; defer { isSaving = false }
        do {
            let updated = try await store.setBody(ast, for: deck.id)
            self.deck = updated
            self.document = updated.body
        } catch {
            lastError = String(describing: error)
        }
    }

    public func setDocumentLocal(_ ast: DocumentAST) {
        self.document = ast
    }

    // MARK: - Slide AST (per-slide edit)

    /// Replace one slide's body (single-root slice) inside the deck.
    public func commitSlideBody(_ ast: DocumentAST, slideIndex: Int) async {
        guard slideIndex >= 0, slideIndex < deck.slideCount else { return }
        let oldRootID = deck.body.rootChildren[slideIndex]
        // ast is a single-root slice; extract its root block.
        guard let newRootID = ast.rootChildren.first,
              let newBlock = ast.blocks[newRootID] else { return }
        isSaving = true; defer { isSaving = false }
        do {
            var updated = deck
            // Carry over layout meta from the old root to the new root if the id changed.
            let oldKey = oldRootID.uuidString
            let newKey = newRootID.uuidString
            if oldKey != newKey, let meta = updated.slideMeta[oldKey] {
                updated.slideMeta[newKey] = meta
                updated.slideMeta.removeValue(forKey: oldKey)
            }
            // Replace the root child in place; swap the block map entries.
            updated.body.rootChildren[slideIndex] = newRootID
            // Remove old subtree blocks, insert new subtree blocks.
            var oldSubtree: Set<UUID> = [oldRootID]
            collectSubtree(rootID: oldRootID, ast: deck.body, into: &oldSubtree)
            for id in oldSubtree { updated.body.blocks.removeValue(forKey: id) }
            for (k, v) in ast.blocks { updated.body.blocks[k] = v }
            _ = try await store.upsert(updated)
            self.deck = updated
            self.document = updated.body
        } catch {
            lastError = String(describing: error)
        }
    }

    private func collectSubtree(rootID: UUID, ast: DocumentAST, into out: inout Set<UUID>) {
        guard let block = ast.blocks[rootID], !out.contains(rootID) else { return }
        out.insert(rootID)
        for child in block.children { collectSubtree(rootID: child, ast: ast, into: &out) }
    }

    // MARK: - Archive / Trash / Favorite

    public func toggleArchived() async {
        isSaving = true; defer { isSaving = false }
        do {
            let updated = deck.isArchived ? try await store.unarchive(deck.id) : try await store.archive(deck.id)
            self.deck = updated
        } catch { lastError = String(describing: error) }
    }

    public func toggleTrashed() async {
        isSaving = true; defer { isSaving = false }
        do {
            let updated = deck.isTrashed ? try await store.restore(deck.id) : try await store.trash(deck.id)
            self.deck = updated
        } catch { lastError = String(describing: error) }
    }

    public func toggleFavorite() async {
        isSaving = true; defer { isSaving = false }
        do {
            let updated = deck.isFavorite ? try await store.unfavorite(deck.id) : try await store.favorite(deck.id)
            self.deck = updated
        } catch { lastError = String(describing: error) }
    }

    // MARK: - Tags

    public func addDraftTag() async {
        let normalized = SlideDeck.normalizeTags([draftTag])
        guard let first = normalized.first, !deck.tags.contains(first) else {
            draftTag = ""; return
        }
        isSaving = true; defer { isSaving = false }
        do {
            let updated = try await store.addTag(first, to: deck.id)
            self.deck = updated
            self.draftTag = ""
        } catch { lastError = String(describing: error) }
    }

    public func removeTag(_ tag: String) async {
        isSaving = true; defer { isSaving = false }
        do {
            let updated = try await store.removeTag(tag, from: deck.id)
            self.deck = updated
        } catch { lastError = String(describing: error) }
    }

    // MARK: - Layout

    public func setLayout(_ layout: SlideLayout, at index: Int) async {
        isSaving = true; defer { isSaving = false }
        do {
            let updated = try await store.setSlideLayout(at: index, layout: layout, for: deck.id)
            self.deck = updated
        } catch { lastError = String(describing: error) }
    }

    // MARK: - Linking

    public func link(to otherEntityID: UUID, linkType: String = "related_to") async {
        isSaving = true; defer { isSaving = false }
        do {
            _ = try await store.link(deckID: deck.id, to: otherEntityID, linkType: linkType)
            if let fresh = try await store.get(id: deck.id) {
                self.deck = fresh
                self.document = fresh.body
            }
        } catch { lastError = String(describing: error) }
    }
}
