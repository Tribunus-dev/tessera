import SwiftUI
import TesseraCore

// MARK: - DrawDetailView
//
// The top-level detail view for a single Drawing (P2-0 item 3). No
// Draw-material view existed anywhere in the app before this file -
// verified by grep (`grep -rln "Drawing\b" TesseraStudioMac` returned
// nothing) before creating it. Follows the sibling `DocDetailView.swift`
// pattern (header / metadata / action row / tag bar / content / linked
// entities, all in a `ScrollView`), trimmed to what `DrawingsViewModel`
// actually exposes: that view-model is deliberately list/browse-only
// (its own doc comment: "a canvas-editing view-model... is exactly the
// 'full UI'... `selectedDrawing` exposes the chosen `Drawing` value
// directly for whatever canvas UI lands later to build its own
// interaction state on top of") - this view (and ``DrawCanvasView``
// inside it) IS that later canvas UI, so per-drawing mutations
// (favorite/archive/trash/tags/title) go straight through
// `viewModel.store` here rather than waiting on a richer view-model.
public struct DrawDetailView: View {

    @ObservedObject public var viewModel: DrawingsViewModel
    public let onDelete: () -> Void

    @State private var drawing: Drawing
    @State private var undoManager: ReceiptUndoManager
    @State private var draftTitle: String
    @State private var draftTag: String = ""
    @State private var showDeleteConfirm: Bool = false
    @State private var lastError: String?

    public init(viewModel: DrawingsViewModel, drawing: Drawing, onDelete: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDelete = onDelete
        self._drawing = State(initialValue: drawing)
        self._undoManager = State(initialValue: ReceiptUndoManager(documentID: drawing.id))
        self._draftTitle = State(initialValue: drawing.title)
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
                    canvasSection
                    Divider()
                    linkedSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(.background)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showDeleteConfirm) { deleteSheet }
        .onChange(of: viewModel.selectedDrawing) { _, updated in
            guard let updated, updated.id == drawing.id else { return }
            drawing = updated
            draftTitle = updated.title
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .destructiveAction) {
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Hard-delete this drawing")
            .accessibilityLabel("Delete drawing")
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "square.on.circle").font(.title).foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Title", text: $draftTitle, onCommit: { Task { await commitTitle() } })
                .textFieldStyle(.plain)
                .font(.title)
                .fontWeight(.bold)
                .accessibilityLabel("Drawing title")
        }
    }

    // MARK: - Metadata row

    private var metadataRow: some View {
        HStack(spacing: 12) {
            Text("\(drawing.shapeCount) shape\(drawing.shapeCount == 1 ? "" : "s")")
                .font(.callout).foregroundStyle(.secondary)
            Text("\(Int(drawing.canvasSize.width))\u{00d7}\(Int(drawing.canvasSize.height)) pt")
                .font(.callout).foregroundStyle(.secondary)
            if let lastError {
                Text(lastError).font(.caption).foregroundStyle(.red)
            }
            Spacer()
        }
    }

    // MARK: - Tag bar

    private var tagBar: some View {
        HStack(spacing: 6) {
            ForEach(drawing.tags, id: \.self) { tag in
                HStack(spacing: 3) {
                    Text(tag).font(.caption)
                    Button {
                        Task { await removeTag(tag) }
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove tag \(tag)")
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.quaternary.opacity(0.4), in: Capsule())
            }
            TextField("Add tag", text: $draftTag, onCommit: { Task { await addDraftTag() } })
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(width: 90)
        }
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 12) {
            Toggle(isOn: favoriteBinding) {
                Label(drawing.isFavorite ? "Favorited" : "Favorite",
                      systemImage: drawing.isFavorite ? "star.fill" : "star")
            }
            .toggleStyle(.button).controlSize(.small)
            .accessibilityLabel(drawing.isFavorite ? "Favorited" : "Favorite")

            Toggle(isOn: archiveBinding) {
                Label(drawing.isArchived ? "Archived" : "Archive",
                      systemImage: drawing.isArchived ? "archivebox.fill" : "archivebox")
            }
            .toggleStyle(.button).controlSize(.small)
            .accessibilityLabel(drawing.isArchived ? "Archived" : "Archive drawing")

            Toggle(isOn: trashBinding) {
                Label(drawing.isTrashed ? "In Trash" : "Trash",
                      systemImage: drawing.isTrashed ? "trash.fill" : "trash")
            }
            .toggleStyle(.button).controlSize(.small)
            .accessibilityLabel(drawing.isTrashed ? "In Trash" : "Move to Trash")

            Spacer()
        }
        .font(.callout)
    }

    // MARK: - Canvas

    private var canvasSection: some View {
        DrawCanvasView(
            drawing: $drawing,
            store: viewModel.store,
            undoManager: undoManager,
            userID: viewModel.userID
        )
        .frame(minHeight: 420)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 1))
    }

    // MARK: - Linked entities

    private var linkedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Linked entities").font(.headline)
                Spacer()
                if !drawing.linkedEntityIDs.isEmpty {
                    Text("\(drawing.linkedEntityIDs.count) link\(drawing.linkedEntityIDs.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if drawing.linkedEntityIDs.isEmpty {
                Text("No linked entities yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Sheets

    private var deleteSheet: some View {
        VStack(spacing: 16) {
            Text("Delete this drawing?").font(.headline)
            Text("\"\(drawing.displayTitle)\"").foregroundStyle(.secondary)
            Text("Hard delete removes the row. The receipt chain is preserved.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).font(.callout)
            HStack {
                Button("Cancel") { showDeleteConfirm = false }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) { showDeleteConfirm = false; onDelete() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding().frame(width: 360)
    }

    // MARK: - Bindings

    private var favoriteBinding: Binding<Bool> {
        Binding(get: { drawing.isFavorite }, set: { _ in Task { await toggleFavorite() } })
    }
    private var archiveBinding: Binding<Bool> {
        Binding(get: { drawing.isArchived }, set: { _ in Task { await toggleArchived() } })
    }
    private var trashBinding: Binding<Bool> {
        Binding(get: { drawing.isTrashed }, set: { _ in Task { await toggleTrashed() } })
    }

    // MARK: - Mutations

    @MainActor
    private func commitTitle() async {
        guard draftTitle != drawing.title else { return }
        do {
            var updated = drawing
            updated.title = draftTitle
            drawing = try await viewModel.store.upsert(updated)
        } catch {
            lastError = String(describing: error)
        }
    }

    @MainActor
    private func toggleFavorite() async {
        do {
            drawing = drawing.isFavorite
                ? try await viewModel.store.unfavorite(drawing.id)
                : try await viewModel.store.favorite(drawing.id)
        } catch {
            lastError = String(describing: error)
        }
    }

    @MainActor
    private func toggleArchived() async {
        do {
            drawing = drawing.isArchived
                ? try await viewModel.store.unarchive(drawing.id)
                : try await viewModel.store.archive(drawing.id)
        } catch {
            lastError = String(describing: error)
        }
    }

    @MainActor
    private func toggleTrashed() async {
        do {
            drawing = drawing.isTrashed
                ? try await viewModel.store.restore(drawing.id)
                : try await viewModel.store.trash(drawing.id)
        } catch {
            lastError = String(describing: error)
        }
    }

    @MainActor
    private func addDraftTag() async {
        let tag = draftTag
        guard !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            drawing = try await viewModel.store.addTag(tag, to: drawing.id)
            draftTag = ""
        } catch {
            lastError = String(describing: error)
        }
    }

    @MainActor
    private func removeTag(_ tag: String) async {
        do {
            drawing = try await viewModel.store.removeTag(tag, from: drawing.id)
        } catch {
            lastError = String(describing: error)
        }
    }
}
