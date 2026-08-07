#if os(iOS)
import SwiftUI
import TesseraCore

// MARK: - SlidesListView_iOS

/// The iOS Slides surface. NavigationStack + segmented filter tabs
/// + searchable list. Mirrors the Mac surface's filters (All /
/// Favorites / Archived / Trash).
public struct SlidesListView_iOS: View {

    @ObservedObject public var viewModel: SlidesViewModel
    @State private var searchText: String = ""

    public init(viewModel: SlidesViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterTabs
                if viewModel.isLoading && viewModel.rows.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.rows.isEmpty {
                    emptyState
                } else {
                    decksList
                }
            }
            .navigationTitle("Slides")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText)
            .onChange(of: searchText) { _, new in viewModel.applyLocalSearch(new) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await createBlankDeck() } } label: {
                        Image(systemName: "rectangle.on.rectangle.badge.plus")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let editor = viewModel.editor, editor.deck.id == id {
                    SlideDeckDetailView_iOS(
                        viewModel: editor,
                        selectedSlideIndex: Binding(
                            get: { viewModel.selectedSlideIndex },
                            set: { viewModel.selectedSlideIndex = $0 }
                        ))
                } else if let deck = viewModel.allDecks.first(where: { $0.id == id }) {
                    let editor = SlideDeckEditorViewModel(deck: deck, store: viewModel.store, userID: viewModel.userID)
                    SlideDeckDetailView_iOS(
                        viewModel: editor,
                        selectedSlideIndex: Binding(
                            get: { viewModel.selectedSlideIndex },
                            set: { viewModel.selectedSlideIndex = $0 }
                        ))
                } else {
                    Text("Deck not found")
                }
            }
            .task { await viewModel.refresh() }
        }
    }

    private var filterTabs: some View {
        Picker("Filter", selection: $viewModel.filter) {
            ForEach(SlideListFilter.allCases) { f in Text(f.displayName).tag(f) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal).padding(.vertical, 8)
        .onChange(of: viewModel.filter) { _, _ in viewModel.applyFilter() }
    }

    private var decksList: some View {
        List {
            ForEach(viewModel.rows) { row in
                NavigationLink(value: row.id) {
                    SlideDeckRowView_iOS(row: row)
                }
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle").font(.system(size: 48)).foregroundStyle(.secondary)
            Text(emptyStateTitle).font(.headline)
            Button { Task { await createBlankDeck() } } label: {
                Label("New Deck", systemImage: "rectangle.on.rectangle.badge.plus")
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateTitle: String {
        switch viewModel.filter {
        case .all: return "No decks yet"
        case .favorites: return "No favorites"
        case .archived: return "Nothing archived"
        case .trash: return "Trash is empty"
        }
    }

    private func createBlankDeck() async {
        do {
            let deck = try await viewModel.createDeck(title: "Untitled")
            viewModel.select(deck.id)
        } catch {}
    }
}

// MARK: - SlideDeckRowView_iOS

struct SlideDeckRowView_iOS: View {
    let row: SlideDeckRow
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if row.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                if row.isArchived { Image(systemName: "archivebox.fill").foregroundStyle(.secondary).font(.caption) }
                if row.isTrashed { Image(systemName: "trash.fill").foregroundStyle(.secondary).font(.caption) }
                Text(row.title).font(.headline).lineLimit(1)
                Spacer()
                Text("\(row.slideCount) slide\(row.slideCount == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !row.snippet.isEmpty {
                Text(row.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 4) {
                Text(row.relativeTime).font(.caption).foregroundStyle(.secondary)
                Text("·").font(.caption).foregroundStyle(.tertiary)
                Text("\(row.wordCount) words").font(.caption).foregroundStyle(.secondary)
                if !row.tags.isEmpty {
                    Text("·").font(.caption).foregroundStyle(.tertiary)
                    Text(row.tags.prefix(3).map { "#\($0)" }.joined(separator: " "))
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

#endif
