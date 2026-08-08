import SwiftUI
import TesseraCore

// MARK: - SlidesListView

/// The macOS Slides surface. Deck library + slide canvas.
///
/// **Layout.** A `NavigationSplitView` with three columns:
///   * Sidebar — the four list filters (All / Favorites / Archived /
///     Trash) + the tag chip strip.
///   * Middle — the deck rows for the active filter.
///   * Detail — the deck detail + slide canvas
///     (``SlideDeckDetailView`` + ``SlideCanvasView``).
public struct SlidesListView: View {

    @ObservedObject public var viewModel: SlidesViewModel

    public init(viewModel: SlidesViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            decksListColumn
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            detailColumn
        }
        .navigationTitle("Slides")
        .toolbar { toolbarContent }
        .task {
            await viewModel.refresh()
            if viewModel.selectedDeckID == nil, let first = viewModel.rows.first {
                viewModel.select(first.id)
            }
        }
        .onChange(of: viewModel.filter) { _, _ in viewModel.applyFilter() }
        .onChange(of: viewModel.activeTag) { _, _ in viewModel.applyFilter() }
        .onChange(of: viewModel.selectedDeckID) { _, new in viewModel.select(new) }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: filterSelection) {
            Section("Library") {
                ForEach(SlideListFilter.allCases) { f in
                    Label(f.displayName, systemImage: f.systemImage)
                        .tag(f)
                        .badge(rowCount(for: f))
                }
            }
            if !viewModel.allTags.isEmpty {
                Section("Tags") {
                    let chipBinding = Binding<String?>(
                        get: { viewModel.activeTag },
                        set: { viewModel.setActiveTag($0) }
                    )
                    SlidesTagChipsView(tags: viewModel.allTags, activeTag: chipBinding)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var filterSelection: Binding<SlideListFilter?> {
        Binding<SlideListFilter?>(
            get: { viewModel.filter },
            set: { if let v = $0 { viewModel.filter = v } }
        )
    }

    private func rowCount(for filter: SlideListFilter) -> Int {
        filter.apply(to: viewModel.allDecks).count
    }

    // MARK: - Decks list column

    private var decksListColumn: some View {
        Group {
            if viewModel.isLoading && viewModel.rows.isEmpty {
                ProgressView("Loading slides…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.loadError, viewModel.rows.isEmpty {
                errorState(error)
            } else if viewModel.rows.isEmpty {
                emptyState
            } else {
                decksList
            }
        }
        .searchable(text: searchTextBinding, prompt: "Search decks")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await createBlankDeck() }
                } label: {
                    Label("New Deck", systemImage: "rectangle.on.rectangle.badge.plus")
                }
                .help("Create a new deck (Cmd-N)")
                .accessibilityLabel("New Deck")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    private var decksList: some View {
        List(selection: selectionBinding) {
            ForEach(viewModel.rows) { row in
                SlideDeckRowView(row: row)
                    .tag(row.id)
            }
        }
        .listStyle(.inset)
    }

    private var selectionBinding: Binding<UUID?> {
        Binding<UUID?>(
            get: { viewModel.selectedDeckID },
            set: { viewModel.select($0) }
        )
    }

    private var searchTextBinding: Binding<String> {
        Binding<String>(
            get: { viewModel.searchText },
            set: { viewModel.applyLocalSearch($0) }
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyStateTitle, systemImage: "rectangle.on.rectangle")
        } description: {
            Text(emptyStateSubtitle)
        } actions: {
            Button {
                Task { await createBlankDeck() }
            } label: {
                Label("New Deck", systemImage: "rectangle.on.rectangle.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyStateTitle: String {
        switch viewModel.filter {
        case .all: return "No decks yet"
        case .favorites: return "No favorites"
        case .archived: return "Nothing archived"
        case .trash: return "Trash is empty"
        }
    }

    private var emptyStateSubtitle: String {
        switch viewModel.filter {
        case .all: return "Create a slide deck to get started."
        case .favorites: return "Star a deck to see it here."
        case .archived: return "Archive a deck to see it here."
        case .trash: return "Trashed decks appear here."
        }
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't load decks", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { Task { await viewModel.refresh() } }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Detail column

    @ViewBuilder
    private var detailColumn: some View {
        if let editor = viewModel.editor {
            SlideDeckDetailView(
                viewModel: editor,
                selectedSlideIndex: Binding(
                    get: { viewModel.selectedSlideIndex },
                    set: { viewModel.selectedSlideIndex = $0 }
                ),
                onDelete: { Task { await viewModel.deleteSelected() } },
                onInsertSlide: { layout in Task { await viewModel.insertSlide(layout: layout) } },
                onDeleteSlide: { idx in Task { await viewModel.deleteSlide(at: idx) } }
            )
            .id(editor.deck.id)
        } else {
            ContentUnavailableView(
                "Select or create a deck",
                systemImage: "rectangle.on.rectangle",
                description: Text("Choose a deck from the list or create a new one.")
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .secondaryAction) {
            Button { Task { await viewModel.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.body)
                    .symbolRenderingMode(.hierarchical)
            }
            .help("Reload decks")
            .accessibilityLabel("Reload decks")
        }
    }

    // MARK: - Actions

    private func createBlankDeck() async {
        do {
            let deck = try await viewModel.createDeck(title: "Untitled")
            viewModel.select(deck.id)
        } catch {}
    }
}

// MARK: - SlideDeckRowView

struct SlideDeckRowView: View {
    let row: SlideDeckRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if row.isFavorite {
                    Image(systemName: "star.fill").font(.caption).symbolRenderingMode(.hierarchical).foregroundStyle(.yellow)
                }
                if row.isArchived {
                    Image(systemName: "archivebox.fill").font(.caption).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                }
                if row.isTrashed {
                    Image(systemName: "trash.fill").font(.caption).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                }
                Text(row.title).font(.headline).lineLimit(1)
                Spacer()
                Text("\(row.slideCount) slide\(row.slideCount == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
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

// MARK: - SlidesTagChipsView

struct SlidesTagChipsView: View {
    let tags: [String]
    @Binding var activeTag: String?

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                Button {
                    activeTag = (activeTag == tag) ? nil : tag
                } label: {
                    Text("#\(tag)")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                        .opacity(activeTag == nil || activeTag == tag ? 1.0 : 0.4)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
