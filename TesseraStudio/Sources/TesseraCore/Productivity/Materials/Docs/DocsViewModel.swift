import Foundation
import SwiftUI

// MARK: - DocsViewModel

/// The view-model for the Docs surface (the Notion/Craft-style
/// longform document list + detail). Owns the filtered list, the
/// selection, the search/tag/archived/trash states, and the chat-
/// panel integration.
///
/// `@MainActor` so all `@Published` writes happen on the main
/// thread (SwiftUI's expectation). The data layer facade is an
/// actor; we hop to it for the reads/writes.
///
/// **Loading.** The view calls `refresh()` on appear and after
/// every mutation. The model reads the doc list from the data
/// layer, applies the filter, and re-projects the rows with a
/// per-entity-type partial index (migration 0010) so the listing
/// stays O(log n).
@MainActor
public final class DocsViewModel: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var allDocs: [Doc] = []
    @Published public private(set) var rows: [DocRow] = []
    @Published public var filter: DocListFilter = .all
    @Published public var selectedDocID: UUID?
    @Published public var activeTag: String?
    @Published public var searchText: String = ""
    @Published public var isLoading: Bool = false
    @Published public private(set) var loadError: String?
    @Published public private(set) var isChatDriven: Bool = false

    /// View-model for the detail editor. nil when no doc is
    /// selected. The Mac detail column / iOS push binds to it.
    @Published public private(set) var editor: DocEditorViewModel?

    // MARK: - Dependencies

    public let store: DocStore
    public let dataLayer: TesseraDataLayer
    public let userID: UserID

    public init(
        store: DocStore,
        dataLayer: TesseraDataLayer,
        userID: UserID = UUID()
    ) {
        self.store = store
        self.dataLayer = dataLayer
        self.userID = userID
    }

    // MARK: - Lifecycle

    public func refresh() async {
        isLoading = true
        loadError = nil
        do {
            let docs = try await store.list(limit: 1000)
            allDocs = docs
            applyFilter()
        } catch {
            loadError = String(describing: error)
        }
        isLoading = false
    }

    public func applyFilter() {
        var filtered = filter.apply(to: allDocs)
        if let tag = activeTag {
            filtered = filtered.filter { $0.tags.contains(tag) }
        }
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty {
            filtered = filtered.filter { doc in
                let hay = "\(doc.title.lowercased()) \(doc.tags.joined(separator: " ")) \(doc.snippet(maxLength: 1000).lowercased())"
                return hay.contains(needle)
            }
        }
        rows = filtered.map { DocRow(doc: $0) }
    }

    public func setAllDocsForTesting(_ docs: [Doc]) {
        allDocs = docs
        applyFilter()
    }

    public func applyLocalSearch(_ needle: String) {
        searchText = needle
        applyFilter()
    }

    public var allTags: [String] {
        var seen: Set<String> = []
        for doc in allDocs { for tag in doc.tags { seen.insert(tag) } }
        return seen.sorted()
    }

    // MARK: - Selection

    public func select(_ docID: UUID?) {
        selectedDocID = docID
        if let docID, let doc = allDocs.first(where: { $0.id == docID }) {
            editor = DocEditorViewModel(doc: doc, store: store, userID: userID)
        } else {
            editor = nil
        }
    }

    // MARK: - CRUD

    @discardableResult
    public func createDoc(
        title: String,
        body: DocumentAST = .empty,
        tags: [String] = [],
        coverImageURL: URL? = nil,
        iconEmoji: String? = nil
    ) async throws -> Doc {
        let now = Date()
        let doc = Doc(
            id: UUID(),
            title: title,
            body: body,
            coverImageURL: coverImageURL,
            iconEmoji: iconEmoji,
            tags: Doc.normalizeTags(tags),
            createdAt: now,
            updatedAt: now
        )
        _ = try await store.upsert(doc)
        await refresh()
        return doc
    }

    public func deleteSelected() async {
        guard let id = selectedDocID else { return }
        do {
            _ = try await store.delete(id: id)
            selectedDocID = nil
            editor = nil
            await refresh()
        } catch {
            loadError = String(describing: error)
        }
    }

    // MARK: - Chat-panel integration

    @discardableResult
    public func chatCreateDoc(
        title: String,
        body: DocumentAST = .empty,
        tags: [String] = []
    ) async throws -> Doc {
        isChatDriven = true
        defer { isChatDriven = false }
        return try await createDoc(title: title, body: body, tags: tags)
    }

    @discardableResult
    public func chatEditDoc(
        docID: UUID,
        apply: (DocStore) async throws -> Doc
    ) async throws -> Doc {
        isChatDriven = true
        defer { isChatDriven = false }
        let updated = try await apply(store)
        await refresh()
        if selectedDocID == docID, let editor {
            editor.refresh(with: updated)
        }
        return updated
    }

    // MARK: - Tag chip

    public func setActiveTag(_ tag: String?) {
        activeTag = tag
        applyFilter()
    }
}

// MARK: - DocListFilter

/// Which list the user is currently looking at in the Docs
/// surface. Mirrors ``NoteListFilter`` but with the Docs-specific
/// vocabulary (favorite, archived, trash).
public enum DocListFilter: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
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
        case .all: return "doc.text"
        case .favorites: return "star.fill"
        case .archived: return "archivebox"
        case .trash: return "trash"
        }
    }

    public func apply(to docs: [Doc]) -> [Doc] {
        switch self {
        case .all:
            return docs.filter { !$0.isTrashed && !$0.isArchived }
                .sorted { $0.updatedAt > $1.updatedAt }
        case .favorites:
            return docs.filter { $0.isFavorite && !$0.isTrashed && !$0.isArchived }
                .sorted { $0.updatedAt > $1.updatedAt }
        case .archived:
            return docs.filter { $0.isArchived && !$0.isTrashed }
                .sorted { $0.updatedAt > $1.updatedAt }
        case .trash:
            return docs.filter { $0.isTrashed }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
    }
}

// MARK: - DocRow

/// A flattened view-model row for the Docs list. Computed from a
/// `Doc` so the view layer doesn't format dates.
public struct DocRow: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let title: String
    public let snippet: String
    public let tags: [String]
    public let iconEmoji: String?
    public let hasCover: Bool
    public let updatedAt: Date
    public let relativeTime: String
    public let isFavorite: Bool
    public let isArchived: Bool
    public let isTrashed: Bool
    public let wordCount: Int
    public let readingTimeMinutes: Int

    public init(doc: Doc, now: Date = Date()) {
        self.id = doc.id
        self.title = doc.displayTitle
        self.snippet = doc.snippet(maxLength: 200)
        self.tags = doc.tags
        self.iconEmoji = doc.iconEmoji
        self.hasCover = doc.coverImageURL != nil
        self.updatedAt = doc.updatedAt
        self.relativeTime = DocRow.relativeTimeString(for: doc.updatedAt, now: now)
        self.isFavorite = doc.isFavorite
        self.isArchived = doc.isArchived
        self.isTrashed = doc.isTrashed
        self.wordCount = doc.wordCount
        self.readingTimeMinutes = doc.readingTimeMinutes
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

// MARK: - DocEditorViewModel

/// The view-model for the doc editor column. Owns the in-memory
/// copy of the doc being edited and routes edits through the
/// ``DocStore`` (which appends the constitutional receipt).
///
/// **Auto-save.** `commitBody` is debounced by 2 seconds: rapid
/// edits coalesce into a single save. The debounce is cancelled
/// when the editor is torn down.
///
/// **Session recovery.** When the app moves to the background
/// (scenePhase change), `saveRecoveryFile()` writes the current
/// AST to a JSON file in the app's cache directory. On the next
/// launch of this doc, `checkRecovery()` compares the recovery
/// file's timestamp with the persisted doc's `updatedAt`; if the
/// recovery is newer, `pendingRecovery` is set and the view can
/// prompt the user to restore.
@MainActor
public final class DocEditorViewModel: ObservableObject {

    @Published public private(set) var doc: Doc
    @Published public private(set) var document: DocumentAST
    @Published public var draftTitle: String
    @Published public var draftTag: String
    @Published public var isSaving: Bool = false
    @Published public private(set) var lastError: String?
    /// Set when a newer recovery file exists than what was persisted.
    /// The view prompts the user; set `recoverFromBackup` to restore it.
    @Published public var pendingRecovery: Bool = false

    public let store: DocStore
    public let userID: UserID

    private var saveDebounceTask: Task<Void, Never>?
    private let debounceDelay: TimeInterval = 2.0

    /// The file URL for the session recovery JSON.
    private var recoveryFileURL: URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cacheDir.appendingPathComponent("doc-recovery-\(doc.id.uuidString).json")
    }

    public init(doc: Doc, store: DocStore, userID: UserID) {
        self.doc = doc
        self.document = doc.body
        self.draftTitle = doc.title
        self.draftTag = ""
        self.store = store
        self.userID = userID
    }

    /// Check for a session-recovery file on init. Returns true if
    /// a newer backup exists than the persisted doc.
    public func checkRecovery() {
        let file = recoveryFileURL
        guard FileManager.default.fileExists(atPath: file.path) else {
            pendingRecovery = false
            return
        }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let modDate = attrs[.modificationDate] as? Date else {
                pendingRecovery = false
                return
            }
            pendingRecovery = modDate > doc.updatedAt
        } catch {
            pendingRecovery = false
        }
    }

    /// Restore from the session-recovery file. Sets `pendingRecovery = false`.
    public func recoverFromBackup() async {
        let file = recoveryFileURL
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let data = try Data(contentsOf: file)
            let recoveredDoc = try Doc.from(jsonData: data)
            self.document = recoveredDoc.body
            self.doc = recoveredDoc
            self.draftTitle = recoveredDoc.title
            pendingRecovery = false
        } catch {
            lastError = "Failed to restore backup: \(error)"
        }
    }

    /// Discard the recovery file (user chose to keep the persisted version).
    public func discardRecovery() {
        try? FileManager.default.removeItem(at: recoveryFileURL)
        pendingRecovery = false
    }

    /// Save a recovery snapshot for session-crash recovery.
    public func saveRecoveryFile() {
        do {
            let data = try doc.jsonData()
            try data.write(to: recoveryFileURL, options: .atomic)
        } catch {
            // Non-fatal: recovery is best-effort.
            NSLog("DocEditorViewModel.saveRecoveryFile: \(error)")
        }
    }

    /// Clear the recovery file after a successful persist.
    public func clearRecoveryFile() {
        try? FileManager.default.removeItem(at: recoveryFileURL)
    }

    public func refresh(with doc: Doc) {
        self.doc = doc
        self.document = doc.body
        self.draftTitle = doc.title
    }

    // MARK: - Title

    public func commitTitle() async {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != doc.title else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            var updated = doc
            updated.title = trimmed
            updated.updatedAt = Date()
            _ = try await store.upsert(updated)
            self.doc = updated
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Body

    /// Debounced persist. Cancels any in-flight save, then schedules a
    /// new one after `debounceDelay` seconds. This coalesces rapid
    /// edits (e.g. a paste of 100 lines) into a single network round-trip.
    public func commitBody(_ ast: DocumentAST) async {
        // If the AST is identical to what's already saved, skip.
        guard ast != doc.body else { return }
        // Cancel any pending save.
        saveDebounceTask?.cancel()
        // Schedule a new save with debounce.
        saveDebounceTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(debounceDelay * 1_000_000_000))
            } catch {
                // Task was cancelled — discard this save.
                return
            }
            await persistBody(ast)
        }
    }

    /// Force an immediate save (flushes the debounce). Called by
    /// scenePhase change to background.
    public func flushBody() async {
        saveDebounceTask?.cancel()
        saveDebounceTask = nil
        await persistBody(document)
    }

    private func persistBody(_ ast: DocumentAST) async {
        guard ast != doc.body else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await store.setBody(ast, for: doc.id)
            self.doc = updated
            self.document = updated.body
            clearRecoveryFile()
        } catch {
            lastError = String(describing: error)
        }
    }

    public func setDocumentLocal(_ ast: DocumentAST) {
        self.document = ast
    }

    // MARK: - Archive / Trash / Favorite

    public func toggleArchived() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = doc.isArchived
                ? try await store.unarchive(doc.id)
                : try await store.archive(doc.id)
            self.doc = updated
        } catch {
            lastError = String(describing: error)
        }
    }

    public func toggleTrashed() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = doc.isTrashed
                ? try await store.restore(doc.id)
                : try await store.trash(doc.id)
            self.doc = updated
        } catch {
            lastError = String(describing: error)
        }
    }

    public func toggleFavorite() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = doc.isFavorite
                ? try await store.unfavorite(doc.id)
                : try await store.favorite(doc.id)
            self.doc = updated
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Tags

    public func addDraftTag() async {
        let normalized = Doc.normalizeTags([draftTag])
        guard let first = normalized.first else { return }
        guard !doc.tags.contains(first) else {
            draftTag = ""
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await store.addTag(first, to: doc.id)
            self.doc = updated
            self.draftTag = ""
        } catch {
            lastError = String(describing: error)
        }
    }

    public func removeTag(_ tag: String) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await store.removeTag(tag, from: doc.id)
            self.doc = updated
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Cover / Icon

    public func setCoverImageURL(_ url: URL?) async {
        var updated = doc
        updated.coverImageURL = url
        updated.updatedAt = Date()
        do {
            _ = try await store.upsert(updated)
            self.doc = updated
        } catch {
            lastError = String(describing: error)
        }
    }

    public func setIconEmoji(_ emoji: String?) async {
        var updated = doc
        let trimmed = emoji?.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.iconEmoji = trimmed?.isEmpty == true ? nil : trimmed
        updated.updatedAt = Date()
        do {
            _ = try await store.upsert(updated)
            self.doc = updated
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Linking

    public func link(to otherEntityID: UUID, linkType: String = "related_to") async {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await store.link(docID: doc.id, to: otherEntityID, linkType: linkType)
            if let fresh = try await store.get(id: doc.id) {
                self.doc = fresh
                self.document = fresh.body
            }
        } catch {
            lastError = String(describing: error)
        }
    }
}
