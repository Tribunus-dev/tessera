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
        HStack(spacing: 8) {
            Text("\(viewModel.sheet.rowCount) rows")
                .font(.caption).foregroundStyle(.secondary)
            Text("·").font(.caption).foregroundStyle(.tertiary)
            Text("\(viewModel.sheet.columnCount) cols")
                .font(.caption).foregroundStyle(.secondary)
            Text("·").font(.caption).foregroundStyle(.tertiary)
            Text("\(viewModel.sheet.cellCount) cells")
                .font(.caption).foregroundStyle(.secondary)
            Text("·").font(.caption).foregroundStyle(.tertiary)
            Text(viewModel.sheet.updatedAt, style: .relative)
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if viewModel.isSaving { ProgressView().controlSize(.small) }
            if let err = viewModel.lastError {
                Text(err).foregroundStyle(.red).font(.caption).lineLimit(1)
            }
        }
    }

    // MARK: - Tag bar

    private var tagBar: some View {
        HStack(spacing: 6) {
            ForEach(viewModel.sheet.tags, id: \.self) { tag in
                Button {
                    Task { await viewModel.removeTag(tag) }
                } label: {
                    HStack(spacing: 4) {
                        Text("#\(tag)")
                        Image(systemName: "xmark").font(.caption2)
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
                SheetGridView(viewModel: viewModel)
            }
        }
    }

    private var emptyGridState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tablecells.badge.ellipsis").font(.title2).foregroundStyle(.secondary)
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
                        SheetLinkedEntityChip(id: id)
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

// MARK: - SheetLinkedEntityChip

struct SheetLinkedEntityChip: View {
    let id: UUID
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "link")
            Text(id.uuidString.prefix(8) + "…")
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(.quaternary))
        .foregroundStyle(.secondary)
    }
}
