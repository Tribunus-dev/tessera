import SwiftUI
import TesseraCore

// MARK: - DocDetailView

/// The detail column for a single Doc. Shows the cover image +
/// icon + title + metadata row + tag bar + editor + linked
/// entities. The editor is ``DocEditorView`` configured for
/// `EditorMode.document`.
public struct DocDetailView: View {

    @ObservedObject public var viewModel: DocEditorViewModel
    public let onDelete: () -> Void

    @State private var showDeleteConfirm: Bool = false
    @State private var showLinkSearch: Bool = false
    @State private var linkSearchQuery: String = ""

    public init(viewModel: DocEditorViewModel, onDelete: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    coverSection
                    headerSection
                    metadataRow
                    tagBar
                    actionRow
                    Divider()
                    editorSection
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

    // MARK: - Cover

    @ViewBuilder
    private var coverSection: some View {
        if let url = viewModel.doc.coverImageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                        .frame(height: 160)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                case .failure:
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .frame(height: 80)
                        .overlay { Label("Cover unavailable", systemImage: "photo.slash").foregroundStyle(.secondary).font(.caption) }
                case .empty:
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary.opacity(0.6))
                        .frame(height: 80)
                        .overlay { ProgressView() }
                @unknown default:
                    EmptyView()
                }
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let emoji = viewModel.doc.iconEmoji, !emoji.isEmpty {
                Text(emoji).font(.title)
            }
            TextField("Title", text: $viewModel.draftTitle, onCommit: {
                Task { await viewModel.commitTitle() }
            })
            .textFieldStyle(.plain)
            .font(.title)
            .fontWeight(.bold)
        }
    }

    // MARK: - Metadata row

    private var metadataRow: some View {
        HStack(spacing: 8) {
            Text("\(viewModel.doc.wordCount) words")
                .font(.caption).foregroundStyle(.secondary)
            Text("·").font(.caption).foregroundStyle(.tertiary)
            Text("\(viewModel.doc.readingTimeMinutes) min read")
                .font(.caption).foregroundStyle(.secondary)
            Text("·").font(.caption).foregroundStyle(.tertiary)
            Text(viewModel.doc.updatedAt, style: .relative)
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
            ForEach(viewModel.doc.tags, id: \.self) { tag in
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

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 12) {
            Toggle(isOn: favoriteBinding) {
                Label(viewModel.doc.isFavorite ? "Favorited" : "Favorite",
                      systemImage: viewModel.doc.isFavorite ? "star.fill" : "star")
            }
            .toggleStyle(.button).controlSize(.small)

            Toggle(isOn: archiveBinding) {
                Label(viewModel.doc.isArchived ? "Archived" : "Archive",
                      systemImage: viewModel.doc.isArchived ? "archivebox.fill" : "archivebox")
            }
            .toggleStyle(.button).controlSize(.small)

            Toggle(isOn: trashBinding) {
                Label(viewModel.doc.isTrashed ? "In Trash" : "Trash",
                      systemImage: viewModel.doc.isTrashed ? "trash.fill" : "trash")
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

    // MARK: - Editor

    private var editorSection: some View {
        DocEditorView(viewModel: viewModel)
            .frame(minHeight: 260)
    }

    // MARK: - Linked entities

    private var linkedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Linked entities").font(.headline)
                Spacer()
                if !viewModel.doc.linkedEntityIDs.isEmpty {
                    Text("\(viewModel.doc.linkedEntityIDs.count) link\(viewModel.doc.linkedEntityIDs.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if viewModel.doc.linkedEntityIDs.isEmpty {
                Text("No linked entities yet. Use Link… or the chat panel.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.doc.linkedEntityIDs, id: \.self) { id in
                        DocLinkedEntityChip(id: id)
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
            .help("Hard-delete this document")
            .accessibilityLabel("Delete document")
        }
    }

    // MARK: - Sheets

    private var deleteSheet: some View {
        VStack(spacing: 16) {
            Text("Delete this document?").font(.headline)
            Text("\"\(viewModel.doc.displayTitle)\"").foregroundStyle(.secondary)
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
        Binding(get: { viewModel.doc.isFavorite }, set: { _ in Task { await viewModel.toggleFavorite() } })
    }
    private var archiveBinding: Binding<Bool> {
        Binding(get: { viewModel.doc.isArchived }, set: { _ in Task { await viewModel.toggleArchived() } })
    }
    private var trashBinding: Binding<Bool> {
        Binding(get: { viewModel.doc.isTrashed }, set: { _ in Task { await viewModel.toggleTrashed() } })
    }
}

// MARK: - DocLinkedEntityChip

struct DocLinkedEntityChip: View {
    let id: UUID
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "link")
                .symbolRenderingMode(.hierarchical)
            Text(id.uuidString.prefix(8) + "…")
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(.quaternary))
        .foregroundStyle(.secondary)
    }
}
