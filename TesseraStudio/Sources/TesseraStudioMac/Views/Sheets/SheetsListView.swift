import SwiftUI
import TesseraCore

// MARK: - SheetsListView

/// The macOS Sheets surface. Spreadsheet library.
///
/// **Layout.** A `NavigationSplitView` with three columns:
///   * Sidebar — the four list filters (All / Favorites / Archived /
///     Trash) + the tag chip strip.
///   * Middle — the sheet rows for the active filter.
///   * Detail — the sheet detail + grid (``SheetDetailView``).
public struct SheetsListView: View {

    @ObservedObject public var viewModel: SheetsViewModel

    public init(viewModel: SheetsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            sheetsListColumn
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            detailColumn
        }
        .navigationTitle("Sheets")
        .toolbar { toolbarContent }
        .task {
            await viewModel.refresh()
            if viewModel.selectedSheetID == nil, let first = viewModel.rows.first {
                viewModel.select(first.id)
            }
        }
        .onChange(of: viewModel.filter) { _, _ in viewModel.applyFilter() }
        .onChange(of: viewModel.activeTag) { _, _ in viewModel.applyFilter() }
        .onChange(of: viewModel.selectedSheetID) { _, new in viewModel.select(new) }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: filterSelection) {
            Section("Library") {
                ForEach(SheetListFilter.allCases) { f in
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
                    SheetsTagChipsView(tags: viewModel.allTags, activeTag: chipBinding)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var filterSelection: Binding<SheetListFilter?> {
        Binding<SheetListFilter?>(
            get: { viewModel.filter },
            set: { if let v = $0 { viewModel.filter = v } }
        )
    }

    private func rowCount(for filter: SheetListFilter) -> Int {
        filter.apply(to: viewModel.allSheets).count
    }

    // MARK: - Sheets list column

    private var sheetsListColumn: some View {
        Group {
            if viewModel.isLoading && viewModel.rows.isEmpty {
                ProgressView("Loading sheets…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.loadError, viewModel.rows.isEmpty {
                errorState(error)
            } else if viewModel.rows.isEmpty {
                emptyState
            } else {
                sheetsList
            }
        }
        .searchable(text: searchTextBinding, prompt: "Search sheets")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await createBlankSheet() }
                } label: {
                    Label("New Sheet", systemImage: "tablecells.badge.ellipsis")
                }
                .help("Create a new sheet (Cmd-N)")
                .accessibilityLabel("New Sheet")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    private var sheetsList: some View {
        List(selection: selectionBinding) {
            ForEach(viewModel.rows) { row in
                SheetRowView(row: row)
                    .tag(row.id)
            }
        }
        .listStyle(.inset)
    }

    private var selectionBinding: Binding<UUID?> {
        Binding<UUID?>(
            get: { viewModel.selectedSheetID },
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
            Label(emptyStateTitle, systemImage: "tablecells")
        } description: {
            Text(emptyStateSubtitle)
        } actions: {
            Button {
                Task { await createBlankSheet() }
            } label: {
                Label("New Sheet", systemImage: "tablecells.badge.ellipsis")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyStateTitle: String {
        switch viewModel.filter {
        case .all: return "No sheets yet"
        case .favorites: return "No favorites"
        case .archived: return "Nothing archived"
        case .trash: return "Trash is empty"
        }
    }

    private var emptyStateSubtitle: String {
        switch viewModel.filter {
        case .all: return "Create your first spreadsheet. It lives as table blocks in the Block AST."
        case .favorites: return "Star a sheet to see it here."
        case .archived: return "Archived sheets appear here."
        case .trash: return "Trashed sheets appear here. Hard delete is in the detail toolbar."
        }
    }

    private func errorState(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Could not load sheets", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error)
        } actions: {
            Button("Retry") { Task { await viewModel.refresh() } }
                .buttonStyle(.borderedProminent)
        }
    }

    private var detailColumn: some View {
        Group {
            if let editor = viewModel.editor {
                SheetDetailView(viewModel: editor, onDelete: {
                    Task { await viewModel.deleteSelected() }
                })
            } else {
                ContentUnavailableView(
                    "Select a sheet",
                    systemImage: "tablecells",
                    description: Text("Choose a sheet from the list or create a new one.")
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .secondaryAction) {
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.body)
                    .symbolRenderingMode(.hierarchical)
            }
            .help("Reload sheets")
            .accessibilityLabel("Reload sheets")
        }
    }

    private func createBlankSheet() async {
        do {
            let sheet = try await viewModel.createSheet(title: "Untitled")
            viewModel.select(sheet.id)
        } catch {}
    }
}

// MARK: - SheetRowView

struct SheetRowView: View {
    let row: SheetRow
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if row.isFavorite { Image(systemName: "star.fill").font(.caption).symbolRenderingMode(.hierarchical).foregroundStyle(.yellow) }
                if row.isArchived { Image(systemName: "archivebox.fill").font(.caption).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary) }
                if row.isTrashed { Image(systemName: "trash.fill").font(.caption).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary) }
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
                    ForEach(row.tags.prefix(3), id: \.self) { tag in
                        Text("#\(tag)").font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - SheetsTagChipsView

struct SheetsTagChipsView: View {
    let tags: [String]
    @Binding var activeTag: String?
    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Button {
                    activeTag = (activeTag == tag ? nil : tag)
                } label: {
                    Text("#\(tag)")
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(activeTag == tag ? Color.accentColor : Color(.quaternaryLabelColor).opacity(0.18), in: Capsule())
                        .foregroundStyle(activeTag == tag ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
    }
}

// FlowLayout is provided by TesseraStudioMac/Views/Notes/FlowLayout.swift; no local copy.
