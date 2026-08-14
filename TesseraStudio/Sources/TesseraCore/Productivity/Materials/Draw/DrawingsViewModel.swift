import Foundation
import SwiftUI

// MARK: - DrawingsViewModel

/// The view-model for the Draw surface's list/browse layer (the
/// drawing library - list, filter, search, tags, archive/trash/
/// favorite, selection).
///
/// **Scope note**: unlike `DocsViewModel`/`SlidesViewModel`, this has
/// no `editor: XEditorViewModel?` - a canvas-editing view-model (shape
/// selection, drag state, inline text editing) is exactly the "full
/// UI" studio-expansion-plan.md 0.15 defers; `selectedDrawing` exposes
/// the chosen `Drawing` value directly for whatever canvas UI lands
/// later to build its own interaction state on top of.
///
/// `@MainActor` so all `@Published` writes happen on the main thread
/// (SwiftUI's expectation). The data layer facade is an actor; we hop
/// to it for reads and writes.
@MainActor
public final class DrawingsViewModel: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var allDrawings: [Drawing] = []
    @Published public private(set) var rows: [DrawingRow] = []
    @Published public var filter: DrawingListFilter = .all
    @Published public var selectedDrawingID: UUID?
    @Published public var activeTag: String?
    @Published public var searchText: String = ""
    @Published public var isLoading: Bool = false
    @Published public private(set) var loadError: String?

    // MARK: - Dependencies

    public let store: DrawingStore
    public let dataLayer: TesseraDataLayer
    public let userID: UserID

    public init(store: DrawingStore, dataLayer: TesseraDataLayer, userID: UserID = UUID()) {
        self.store = store
        self.dataLayer = dataLayer
        self.userID = userID
    }

    // MARK: - Lifecycle

    public func refresh() async {
        isLoading = true
        loadError = nil
        do {
            let drawings = try await store.list(limit: 1000)
            allDrawings = drawings
            applyFilter()
        } catch {
            loadError = String(describing: error)
        }
        isLoading = false
    }

    public func applyFilter() {
        var filtered = filter.apply(to: allDrawings)
        if let tag = activeTag {
            filtered = filtered.filter { $0.tags.contains(tag) }
        }
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty {
            filtered = filtered.filter { drawing in
                let hay = "\(drawing.title.lowercased()) \(drawing.tags.joined(separator: " "))"
                return hay.contains(needle)
            }
        }
        rows = filtered.map { DrawingRow(drawing: $0) }
    }

    public func setAllDrawingsForTesting(_ drawings: [Drawing]) {
        allDrawings = drawings
        applyFilter()
    }

    public func applyLocalSearch(_ needle: String) {
        searchText = needle
        applyFilter()
    }

    public var allTags: [String] {
        var seen: Set<String> = []
        for drawing in allDrawings { for tag in drawing.tags { seen.insert(tag) } }
        return seen.sorted()
    }

    // MARK: - Selection

    public func select(_ drawingID: UUID?) {
        selectedDrawingID = drawingID
    }

    public var selectedDrawing: Drawing? {
        guard let id = selectedDrawingID else { return nil }
        return allDrawings.first { $0.id == id }
    }

    // MARK: - CRUD

    @discardableResult
    public func createDrawing(title: String, tags: [String] = []) async throws -> Drawing {
        let now = Date()
        let drawing = Drawing(title: title, tags: Drawing.normalizeTags(tags), createdAt: now, updatedAt: now)
        _ = try await store.upsert(drawing)
        await refresh()
        return drawing
    }

    public func deleteSelected() async {
        guard let id = selectedDrawingID else { return }
        do {
            _ = try await store.delete(id: id)
            selectedDrawingID = nil
            await refresh()
        } catch {
            loadError = String(describing: error)
        }
    }

    // MARK: - Tag chip

    public func setActiveTag(_ tag: String?) {
        activeTag = tag
        applyFilter()
    }
}

// MARK: - DrawingListFilter

public enum DrawingListFilter: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
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
        case .all: return "square.on.square"
        case .favorites: return "star.fill"
        case .archived: return "archivebox"
        case .trash: return "trash"
        }
    }

    public func apply(to drawings: [Drawing]) -> [Drawing] {
        switch self {
        case .all: return drawings.filter { !$0.isTrashed && !$0.isArchived }.sorted { $0.updatedAt > $1.updatedAt }
        case .favorites: return drawings.filter { $0.isFavorite && !$0.isTrashed && !$0.isArchived }.sorted { $0.updatedAt > $1.updatedAt }
        case .archived: return drawings.filter { $0.isArchived && !$0.isTrashed }.sorted { $0.updatedAt > $1.updatedAt }
        case .trash: return drawings.filter { $0.isTrashed }.sorted { $0.updatedAt > $1.updatedAt }
        }
    }
}

// MARK: - DrawingRow

public struct DrawingRow: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let title: String
    public let shapeCount: Int
    public let tags: [String]
    public let isFavorite: Bool
    public let isArchived: Bool
    public let isTrashed: Bool
    public let updatedAt: Date

    public init(drawing: Drawing) {
        self.id = drawing.id
        self.title = drawing.displayTitle
        self.shapeCount = drawing.shapeCount
        self.tags = drawing.tags
        self.isFavorite = drawing.isFavorite
        self.isArchived = drawing.isArchived
        self.isTrashed = drawing.isTrashed
        self.updatedAt = drawing.updatedAt
    }
}
