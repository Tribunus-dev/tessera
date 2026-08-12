import SwiftUI
import TesseraCore

// MARK: - SheetDetailView

/// The detail column for a single Sheet. Shows title + metadata
/// row + tag bar + action row + grid + linked entities.
public struct SheetDetailView: View {

    @ObservedObject public var viewModel: SheetEditorViewModel
    public let onDelete: () -> Void

    @State private var showDeleteConfirm: Bool = false
    @State private var showLinkSearch: Bool = false
    @State private var linkSearchQuery: String = ""
    /// Whether the grid's inline cell editor TextField should have keyboard focus.
    /// `.focused()` requires a FocusState.Binding; we hold the @FocusState here
    /// (at the highest common ancestor of the formula bar TextField and the
    /// grid's cell TextField) so both can share the same focus source.
    @FocusState private var gridEditingFocused: Bool

    public init(viewModel: SheetEditorViewModel, onDelete: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    headerSection
                    metadataRow
                    formulaBar
                    tagBar
                    actionRow
                    Divider()
                    gridSection
                    Divider()
                    linkedSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(.background)
        .toolbar { detailToolbar }
        .sheet(isPresented: $showDeleteConfirm) { deleteSheet }
        .sheet(isPresented: $showLinkSearch) { linkSheet }
        .onChange(of: viewModel.editingCell) { _, newCoord in
            // Drive focus into the grid's inline TextField.
            // When editingCell becomes non-nil, the TextField needs focus
            // so the user can type immediately without a second click.
            gridEditingFocused = newCoord != nil
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        TextField("Title", text: $viewModel.draftTitle, onCommit: {
            Task { await viewModel.commitTitle() }
        })
        .textFieldStyle(.plain)
        .font(.title)
        .fontWeight(.bold)
    }

    // MARK: - Metadata row

    private var metadataRow: some View {
        SurfaceMetadataRow(
            isSaving: viewModel.isSaving,
            lastError: viewModel.lastError,
            stats: [
                (label: "\(viewModel.sheet.rowCount)", value: "rows"),
                (label: "\(viewModel.sheet.columnCount)", value: "cols"),
                (label: "\(viewModel.sheet.cellCount)", value: "cells"),
            ]
        )
    }

    // MARK: - Tag bar

    private var tagBar: some View {
        SurfaceTagBar(
            tags: viewModel.sheet.tags,
            draftTag: $viewModel.draftTag,
            onRemove: { tag in Task { await viewModel.removeTag(tag) } },
            onAdd: { Task { await viewModel.addDraftTag() } }
        )
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 12) {
            Toggle(isOn: favoriteBinding) {
                Label(viewModel.sheet.isFavorite ? "Favorited" : "Favorite",
                      systemImage: viewModel.sheet.isFavorite ? "star.fill" : "star")
            }
            .toggleStyle(.button).controlSize(.small)

            Toggle(isOn: archiveBinding) {
                Label(viewModel.sheet.isArchived ? "Archived" : "Archive",
                      systemImage: viewModel.sheet.isArchived ? "archivebox.fill" : "archivebox")
            }
            .toggleStyle(.button).controlSize(.small)

            Toggle(isOn: trashBinding) {
                Label(viewModel.sheet.isTrashed ? "In Trash" : "Trash",
                      systemImage: viewModel.sheet.isTrashed ? "trash.fill" : "trash")
            }
            .toggleStyle(.button).controlSize(.small)

            Button { showLinkSearch = true } label: {
                Label("Link…", systemImage: "link.badge.plus")
            }
            .controlSize(.small)

            Spacer()
        }
        .font(.callout)
    }

    // MARK: - Formula bar

    private var formulaBar: some View {
        HStack(spacing: 0) {
            // Cell address (e.g. "B3")
            Text(cellAddressLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .center)
                .padding(.vertical, 6)
                .background(Color(.quaternarySystemFill))

            Rectangle()
                .fill(.separator)
                .frame(width: 1, height: 20)

            // fx label
            Text("fx")
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .center)

            Rectangle()
                .fill(.separator)
                .frame(width: 1, height: 20)

            // Editable formula bar
            if let coord = viewModel.selectedCell ?? viewModel.editingCell {
                TextField(
                    "Enter value…",
                    text: formulaBarBinding(coord: coord)
                )
                .font(.system(.caption, design: .monospaced))
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .focused($gridEditingFocused)
                .onSubmit {
                    Task { await viewModel.commitEditingCell() }
                }
            } else {
                Text("Select a cell")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
            }

            Spacer()
        }
        .frame(height: 32)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
    }

    private var cellAddressLabel: String {
        guard let coord = viewModel.selectedCell ?? viewModel.editingCell else { return "" }
        let colLabel = columnLabel(index: coord.col)
        return "\(colLabel)\(coord.row + 1)"
    }

    private func columnLabel(index: Int) -> String {
        var label = ""
        var n = index
        repeat {
            label = String(UnicodeScalar(65 + n % 26)!) + label
            n = n / 26 - 1
        } while n >= 0
        return label
    }

    private func formulaBarBinding(coord: SheetCellCoord) -> Binding<String> {
        Binding(
            get: {
                // Show the live editing text if this cell is being edited,
                // otherwise show the cell's current value.
                if viewModel.editingCell == coord {
                    return viewModel.editingText
                }
                return viewModel.sheet.cellText(row: coord.row, col: coord.col)
            },
            set: { newText in
                if viewModel.editingCell == nil {
                    // Editing started from formula bar — enter edit mode
                    viewModel.beginEditingCell(coord)
                }
                viewModel.editingText = newText
            }
        )
    }

    // MARK: - Grid

    private var gridSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Grid").font(.headline)
                Spacer()
                if viewModel.sheet.rowCount > 0 {
                    Text("\(viewModel.sheet.rowCount) x \(viewModel.sheet.columnCount)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if viewModel.sheet.rowCount == 0 || viewModel.sheet.columnCount == 0 {
                emptyGridState
            } else {
                SheetGridView(viewModel: viewModel, gridEditingFocused: $gridEditingFocused)
            }
        }
    }

    private var emptyGridState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tablecells.badge.ellipsis").font(.title2).foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            Text("No grid yet").font(.subheadline).foregroundStyle(.secondary)
            Button("Create 5 x 4 grid") {
                // Insert an initial table via a throwaway blank sheet's AST.
                let blank = Sheet.makeBlank(title: viewModel.sheet.title, rows: 5, cols: 4)
                Task {
                    var updated = viewModel.sheet
                    updated.body = blank.body
                    updated.columns = blank.columns
                    updated.updatedAt = Date()
                    _ = try? await viewModel.store.upsert(updated)
                    if let fresh = try? await viewModel.store.get(id: updated.id) {
                        viewModel.refresh(with: fresh)
                    }
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
    }

    // MARK: - Linked entities

    private var linkedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Linked entities").font(.headline)
                Spacer()
                if !viewModel.sheet.linkedEntityIDs.isEmpty {
                    Text("\(viewModel.sheet.linkedEntityIDs.count) link\(viewModel.sheet.linkedEntityIDs.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if viewModel.sheet.linkedEntityIDs.isEmpty {
                Text("No linked entities yet. Use Link… or the chat panel.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.sheet.linkedEntityIDs, id: \.self) { id in
                        SurfaceLinkedEntityChip(id: id)
                    }
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .destructiveAction) {
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Hard-delete this sheet")
            .accessibilityLabel("Delete sheet")
        }
    }

    // MARK: - Sheets

    private var deleteSheet: some View {
        VStack(spacing: 16) {
            Text("Delete this sheet?").font(.headline)
            Text("\"\(viewModel.sheet.displayTitle)\"").foregroundStyle(.secondary)
            Text("Hard delete removes the row. The receipt chain is preserved.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).font(.callout)
            HStack {
                Button("Cancel") { showDeleteConfirm = false }.keyboardShortcut(.defaultAction)
                Button("Delete", role: .destructive) { showDeleteConfirm = false; onDelete() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding().frame(width: 360)
    }

    private var linkSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link to another material").font(.headline)
            TextField("Paste an entity UUID", text: $linkSearchQuery)
                .textFieldStyle(.roundedBorder)
            Text("v1: paste a UUID. v2 wires hybrid_search.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showLinkSearch = false }
                Button("Link") {
                    if let target = UUID(uuidString: linkSearchQuery) {
                        Task {
                            await viewModel.link(to: target)
                            showLinkSearch = false
                            linkSearchQuery = ""
                        }
                    }
                }
                .disabled(UUID(uuidString: linkSearchQuery) == nil)
            }
        }
        .padding().frame(width: 460)
    }

    // MARK: - Bindings

    private var favoriteBinding: Binding<Bool> {
        Binding(get: { viewModel.sheet.isFavorite }, set: { _ in Task { await viewModel.toggleFavorite() } })
    }
    private var archiveBinding: Binding<Bool> {
        Binding(get: { viewModel.sheet.isArchived }, set: { _ in Task { await viewModel.toggleArchived() } })
    }
    private var trashBinding: Binding<Bool> {
        Binding(get: { viewModel.sheet.isTrashed }, set: { _ in Task { await viewModel.toggleTrashed() } })
    }
}

