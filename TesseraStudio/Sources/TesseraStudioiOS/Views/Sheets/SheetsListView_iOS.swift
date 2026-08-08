#if os(iOS)
import SwiftUI
import TesseraCore

// MARK: - SheetsListView_iOS

/// The iOS Sheets surface. NavigationStack + segmented filter tabs
/// + searchable list.
public struct SheetsListView_iOS: View {

    @ObservedObject public var viewModel: SheetsViewModel
    @State private var searchText: String = ""

    public init(viewModel: SheetsViewModel) {
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
                    sheetsList
                }
            }
            .navigationTitle("Sheets")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText)
            .onChange(of: searchText) { _, new in viewModel.applyLocalSearch(new) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await createBlankSheet() } } label: {
                        Image(systemName: "tablecells.badge.ellipsis")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let editor = viewModel.editor, editor.sheet.id == id {
                    SheetDetailView_iOS(viewModel: editor)
                } else if let sheet = viewModel.allSheets.first(where: { $0.id == id }) {
                    let editor = SheetEditorViewModel(sheet: sheet, store: viewModel.store, userID: viewModel.userID)
                    SheetDetailView_iOS(viewModel: editor)
                } else {
                    Text("Sheet not found")
                }
            }
            .task { await viewModel.refresh() }
        }
    }

    private var filterTabs: some View {
        Picker("Filter", selection: $viewModel.filter) {
            ForEach(SheetListFilter.allCases) { f in Text(f.displayName).tag(f) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal).padding(.vertical, 8)
        .onChange(of: viewModel.filter) { _, _ in viewModel.applyFilter() }
    }

    private var sheetsList: some View {
        List {
            ForEach(viewModel.rows) { row in
                NavigationLink(value: row.id) {
                    SheetRowView_iOS(row: row)
                }
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tablecells").font(.largeTitle).foregroundStyle(.secondary)
            Text(emptyStateTitle).font(.headline)
            Button { Task { await createBlankSheet() } } label: {
                Label("New Sheet", systemImage: "tablecells.badge.ellipsis")
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateTitle: String {
        switch viewModel.filter {
        case .all: return "No sheets yet"
        case .favorites: return "No favorites"
        case .archived: return "Nothing archived"
        case .trash: return "Trash is empty"
        }
    }

    private func createBlankSheet() async {
        do {
            let sheet = try await viewModel.createSheet(title: "Untitled")
            viewModel.select(sheet.id)
        } catch {}
    }
}

// MARK: - SheetRowView_iOS

struct SheetRowView_iOS: View {
    let row: SheetRow
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if row.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                if row.isArchived { Image(systemName: "archivebox.fill").foregroundStyle(.secondary).font(.caption) }
                if row.isTrashed { Image(systemName: "trash.fill").foregroundStyle(.secondary).font(.caption) }
                Text(row.title).font(.headline).lineLimit(1)
            }
            if !row.snippet.isEmpty {
                Text(row.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 6) {
                Label("\(row.rowCount) x \(row.columnCount)", systemImage: "tablecells")
                    .font(.caption).foregroundStyle(.secondary)
                Text("·").font(.caption).foregroundStyle(.tertiary)
                Text(row.relativeTime).font(.caption).foregroundStyle(.secondary)
                if !row.tags.isEmpty {
                    Text("·").font(.caption).foregroundStyle(.tertiary)
                    Text(row.tags.prefix(2).map { "#\($0)" }.joined(separator: " "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
#endif
