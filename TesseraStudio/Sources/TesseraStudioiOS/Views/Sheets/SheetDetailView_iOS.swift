#if os(iOS)
import SwiftUI
import TesseraCore

// MARK: - SheetDetailView_iOS

/// The iOS detail for a single Sheet. Title + metadata + tag bar
/// + grid (horizontally scrollable) + linked entities.
public struct SheetDetailView_iOS: View {

    @ObservedObject public var viewModel: SheetEditorViewModel
    @State private var showDeleteConfirm: Bool = false
    @State private var showLinkSheet: Bool = false
    @State private var linkQuery: String = ""

    public init(viewModel: SheetEditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerSection
                metadataRow
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
        .navigationTitle(viewModel.sheet.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { detailToolbar }
        .confirmationDialog("Delete this sheet?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { _ = try? await viewModel.store.delete(id: viewModel.sheet.id) }
            }
        } message: {
            Text("Hard delete removes the row. The receipt chain is preserved.")
        }
        .sheet(isPresented: $showLinkSheet) { linkSheet }
    }

    // MARK: - Header

    private var headerSection: some View {
        TextField("Title", text: $viewModel.draftTitle, onCommit: {
            Task { await viewModel.commitTitle() }
        })
        .textFieldStyle(.roundedBorder)
        .font(.title3).fontWeight(.bold)
    }

    private var metadataRow: some View {
        HStack(spacing: 8) {
            Text("\(viewModel.sheet.rowCount) x \(viewModel.sheet.columnCount)").font(.caption).foregroundStyle(.secondary)
            Text("·").font(.caption).foregroundStyle(.tertiary)
            Text(viewModel.sheet.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if viewModel.isSaving { ProgressView().controlSize(.small) }
        }
    }

    private var tagBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.sheet.tags, id: \.self) { tag in
                    Button {
                        Task { await viewModel.removeTag(tag) }
                    } label: {
                        HStack(spacing: 4) {
                            Text("#\(tag)")
                            Image(systemName: "xmark").font(.caption2)
                                .symbolRenderingMode(.hierarchical)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                TextField("Add tag…", text: $viewModel.draftTag, onCommit: {
                    Task { await viewModel.addDraftTag() }
                })
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 160)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                Task { await viewModel.toggleFavorite() }
            } label: {
                Label(viewModel.sheet.isFavorite ? "Favorited" : "Favorite",
                      systemImage: viewModel.sheet.isFavorite ? "star.fill" : "star")
            }
            .controlSize(.small)

            Button {
                Task { await viewModel.toggleArchived() }
            } label: {
                Label(viewModel.sheet.isArchived ? "Archived" : "Archive",
                      systemImage: viewModel.sheet.isArchived ? "archivebox.fill" : "archivebox")
            }
            .controlSize(.small)

            Button {
                Task { await viewModel.toggleTrashed() }
            } label: {
                Label(viewModel.sheet.isTrashed ? "In Trash" : "Trash",
                      systemImage: viewModel.sheet.isTrashed ? "trash.fill" : "trash")
            }
            .controlSize(.small)

            Spacer()
        }
        .font(.callout)
    }

    // MARK: - Grid

    private var gridSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Grid").font(.headline)
                Spacer()
                Text("\(viewModel.sheet.rowCount) x \(viewModel.sheet.columnCount)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if viewModel.sheet.rowCount == 0 || viewModel.sheet.columnCount == 0 {
                Text("No grid yet. Use the Mac detail to create one.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    SheetGridView_iOS(viewModel: viewModel)
                }
            }
        }
    }

    private var linkedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Linked entities").font(.headline)
            if viewModel.sheet.linkedEntityIDs.isEmpty {
                Text("No linked entities yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.sheet.linkedEntityIDs, id: \.self) { id in
                    HStack(spacing: 4) {
                        Image(systemName: "link").font(.caption)
                            .symbolRenderingMode(.hierarchical)
                        Text(id.uuidString.prefix(8) + "…").font(.caption)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { showLinkSheet = true } label: { Label("Link…", systemImage: "link.badge.plus") }
                Divider()
                Button("Delete", role: .destructive) { showDeleteConfirm = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }

    private var linkSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Paste an entity UUID", text: $linkQuery)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                Text("v1: paste a UUID. v2 wires hybrid_search.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showLinkSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Link") {
                        if let target = UUID(uuidString: linkQuery) {
                            Task {
                                await viewModel.link(to: target)
                                showLinkSheet = false
                                linkQuery = ""
                            }
                        }
                    }
                    .disabled(UUID(uuidString: linkQuery) == nil)
                }
            }
        }
    }
}

// MARK: - SheetGridView_iOS

private struct SheetGridView_iOS: View {
    @ObservedObject var viewModel: SheetEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                Text("#").frame(width: 36).font(.caption2).foregroundStyle(.secondary)
                    .frame(height: 28).background(.quaternary)
                ForEach(Array(viewModel.sheet.columns.enumerated()), id: \.offset) { idx, col in
                    let label = col.label.isEmpty ? defaultLabel(index: idx) : col.label
                    Text(label).font(.caption).fontWeight(.semibold).lineLimit(1)
                        .frame(width: 100, height: 28)
                        .background(.quaternary)
                        .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                }
            }
            // Data rows
            ForEach(0..<viewModel.sheet.rowCount, id: \.self) { row in
                HStack(spacing: 0) {
                    Text("\(row + 1)").font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(.quaternary.opacity(0.5))
                    ForEach(0..<viewModel.sheet.columnCount, id: \.self) { col in
                        let coord = SheetCellCoord(row: row, col: col)
                        let isSelected = viewModel.selectedCell == coord
                        let isEditing = viewModel.editingCell == coord
                        Group {
                            if isEditing {
                                TextField("", text: $viewModel.editingText, onCommit: {
                                    Task { await viewModel.commitEditingCell() }
                                })
                                .textFieldStyle(.plain).font(.caption)
                                .padding(.horizontal, 4)
                            } else {
                                Text(viewModel.sheet.cellText(row: row, col: col))
                                    .font(.caption).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 4)
                                    .contentShape(Rectangle())
                            }
                        }
                        .frame(width: 100, height: 36)
                        .background(isEditing ? Color.accentColor.opacity(0.08) : (isSelected ? Color.accentColor.opacity(0.12) : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(isSelected || isEditing ? Color.accentColor : Color.clear, lineWidth: 1))
                        .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                        .onTapGesture {
                            if isEditing { return }
                            if isSelected { viewModel.beginEditingCell(coord) }
                            else { viewModel.selectCell(coord) }
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 1))
    }

    private func defaultLabel(index: Int) -> String {
        var label = ""
        var n = index
        repeat {
            label = String(UnicodeScalar(65 + n % 26)!) + label
            n = n / 26 - 1
        } while n >= 0
        return label
    }
}
#endif
