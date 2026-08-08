#if os(iOS)
import SwiftUI
import TesseraCore

// MARK: - DocsListView_iOS

/// The iOS Docs surface. NavigationStack + segmented filter tabs
/// + searchable list. Mirrors ``NotesView_iOS`` but with the
/// Docs-specific filters (All / Favorites / Archived / Trash).
public struct DocsListView_iOS: View {

    @ObservedObject public var viewModel: DocsViewModel
    @State private var searchText: String = ""

    public init(viewModel: DocsViewModel) {
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
                    docsList
                }
            }
            .navigationTitle("Docs")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText)
            .onChange(of: searchText) { _, new in viewModel.applyLocalSearch(new) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await createBlankDoc() } } label: {
                        Image(systemName: "doc.badge.plus")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let editor = viewModel.editor, editor.doc.id == id {
                    DocDetailView_iOS(viewModel: editor)
                } else if let doc = viewModel.allDocs.first(where: { $0.id == id }) {
                    let editor = DocEditorViewModel(doc: doc, store: viewModel.store, userID: viewModel.userID)
                    DocDetailView_iOS(viewModel: editor)
                } else {
                    Text("Document not found")
                }
            }
            .task { await viewModel.refresh() }
        }
    }

    private var filterTabs: some View {
        Picker("Filter", selection: $viewModel.filter) {
            ForEach(DocListFilter.allCases) { f in Text(f.displayName).tag(f) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal).padding(.vertical, 8)
        .onChange(of: viewModel.filter) { _, _ in viewModel.applyFilter() }
    }

    private var docsList: some View {
        List {
            ForEach(viewModel.rows) { row in
                NavigationLink(value: row.id) {
                    DocRowView_iOS(row: row)
                }
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyStateTitle, systemImage: "doc.text")
        } actions: {
            Button { Task { await createBlankDoc() } } label: {
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

    private func createBlankDoc() async {
        do {
            let doc = try await viewModel.createDoc(title: "Untitled")
            viewModel.select(doc.id)
        } catch { }
    }
}

// MARK: - DocRowView_iOS

struct DocRowView_iOS: View {
    let row: DocRow
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let emoji = row.iconEmoji, !emoji.isEmpty { Text(emoji).font(.caption) }
                if row.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                if row.isArchived { Image(systemName: "archivebox.fill").foregroundStyle(.secondary).font(.caption) }
                if row.isTrashed { Image(systemName: "trash.fill").foregroundStyle(.secondary).font(.caption) }
                Text(row.title).font(.headline).lineLimit(1)
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
