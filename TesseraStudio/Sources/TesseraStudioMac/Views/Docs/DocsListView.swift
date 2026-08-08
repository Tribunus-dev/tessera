import SwiftUI
import TesseraCore

// MARK: - DocsListView

/// The macOS Docs surface. Notion/Craft-style document library.
///
/// **Layout.** A `NavigationSplitView` with three columns:
///   * Sidebar — the four list filters (All / Favorites / Archived /
///     Trash) + the tag chip strip.
///   * Middle — the doc rows for the active filter.
///   * Detail — the doc detail + editor (``DocDetailView``).
public struct DocsListView: View {

    @ObservedObject public var viewModel: DocsViewModel

    public init(viewModel: DocsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            docsListColumn
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            detailColumn
        }
        .navigationTitle("Docs")
        .toolbar { toolbarContent }
        .task {
            await viewModel.refresh()
            if viewModel.selectedDocID == nil, let first = viewModel.rows.first {
                viewModel.select(first.id)
            }
        }
        .onChange(of: viewModel.filter) { _, _ in viewModel.applyFilter() }
        .onChange(of: viewModel.activeTag) { _, _ in viewModel.applyFilter() }
        .onChange(of: viewModel.selectedDocID) { _, new in viewModel.select(new) }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: filterSelection) {
            Section("Library") {
                ForEach(DocListFilter.allCases) { f in
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
                    DocsTagChipsView(tags: viewModel.allTags, activeTag: chipBinding)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var filterSelection: Binding<DocListFilter?> {
        Binding<DocListFilter?>(
            get: { viewModel.filter },
            set: { if let v = $0 { viewModel.filter = v } }
        )
    }

    private func rowCount(for filter: DocListFilter) -> Int {
        filter.apply(to: viewModel.allDocs).count
    }

    // MARK: - Docs list column

    private var docsListColumn: some View {
        Group {
            if viewModel.isLoading && viewModel.rows.isEmpty {
                ProgressView("Loading docs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.loadError, viewModel.rows.isEmpty {
                errorState(error)
            } else if viewModel.rows.isEmpty {
                emptyState
            } else {
                docsList
            }
        }
        .searchable(text: searchTextBinding, prompt: "Search docs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await createBlankDoc() }
                } label: {
                    Label("New Doc", systemImage: "doc.badge.plus")
                }
                .help("Create a new document (Cmd-N)")
                .accessibilityLabel("New Doc")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    private var docsList: some View {
        List(selection: selectionBinding) {
            ForEach(viewModel.rows) { row in
                DocRowView(row: row)
                    .tag(row.id)
            }
        }
        .listStyle(.inset)
    }

    private var selectionBinding: Binding<UUID?> {
        Binding<UUID?>(
            get: { viewModel.selectedDocID },
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
            Label(emptyStateTitle, systemImage: "doc.text")
        } description: {
            Text(emptyStateSubtitle)
        } actions: {
            Button {
                Task { await createBlankDoc() }
            } label: {
                Label("New Doc", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyStateTitle: String {
        switch viewModel.filter {
        case .all: return "No documents yet"
        case .favorites: return "No favorites"
        case .archived: return "Nothing archived"
        case .trash: return "Trash is empty"
        }
    }

    private var emptyStateSubtitle: String {
        switch viewModel.filter {
        case .all: return "Create a document to get started."
        case .favorites: return "Star a document to see it here."
        case .archived: return "Archive a document to see it here."
        case .trash: return "Trashed documents appear here."
        }
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't load docs", systemImage: "exclamationmark.triangle")
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
            DocDetailView(
                viewModel: editor,
                onDelete: { Task { await viewModel.deleteSelected() } }
            )
            .id(editor.doc.id)
        } else {
            ContentUnavailableView(
                "Select or create a document",
                systemImage: "doc.text",
                description: Text("Choose a document from the list or create a new one.")
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
            .help("Reload docs")
            .accessibilityLabel("Reload docs")
        }
    }

    // MARK: - Actions

    private func createBlankDoc() async {
        do {
            let doc = try await viewModel.createDoc(title: "Untitled")
            viewModel.select(doc.id)
        } catch { }
    }
}

// MARK: - DocRowView

struct DocRowView: View {
    let row: DocRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let emoji = row.iconEmoji, !emoji.isEmpty {
                    Text(emoji)
                        .font(.caption)
                }
                if row.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.yellow)
                }
                if row.isArchived {
                    Image(systemName: "archivebox.fill")
                        .font(.caption)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                if row.isTrashed {
                    Image(systemName: "trash.fill")
                        .font(.caption)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                if row.hasCover {
                    Image(systemName: "photo")
                        .font(.caption)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                Text(row.title)
                    .font(.headline)
                    .lineLimit(1)
            }
            if !row.snippet.isEmpty {
                Text(row.snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(row.relativeTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("\(row.wordCount) words · \(row.readingTimeMinutes) min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !row.tags.isEmpty {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    ForEach(row.tags.prefix(3), id: \.self) { tag in
                        DocTagPill(text: tag, isCompact: true)
                    }
                    if row.tags.count > 3 {
                        Text("+\(row.tags.count - 3)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - DocTagPill

struct DocTagPill: View {
    let text: String
    var isCompact: Bool = false

    var body: some View {
        Text("#\(text)")
            .font(isCompact ? .caption2 : .caption)
            .padding(.horizontal, isCompact ? 6 : 8)
            .padding(.vertical, isCompact ? 2 : 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
    }
}

// MARK: - DocsTagChipsView

struct DocsTagChipsView: View {
    let tags: [String]
    @Binding var activeTag: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // FlowLayout lives in Notes/FlowLayout.swift; reuse it
            // via a simple wrapping HStack fallback here.
            WrappingHStack(spacing: 4) {
                ForEach(tags, id: \.self) { tag in
                    Button {
                        activeTag = (activeTag == tag) ? nil : tag
                    } label: {
                        DocTagPill(text: tag, isCompact: true)
                            .opacity(activeTag == nil || activeTag == tag ? 1.0 : 0.4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - WrappingHStack (local fallback; Notes uses FlowLayout)

private struct WrappingHStack<Content: View>: View {
    var spacing: CGFloat = 4
    @ViewBuilder var content: Content

    var body: some View {
        // Simple flow via flexible HStack + line-break on overflow.
        // v1 keeps this as a vertical stack of HStackes would be
        // over-engineered; a single HStack with .lineLimit is
        // good enough for the tag counts we see in practice.
        // The production swap is to import Notes/FlowLayout.
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
    }
}
