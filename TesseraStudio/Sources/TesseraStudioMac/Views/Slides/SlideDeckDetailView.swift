import SwiftUI
import TesseraCore

// MARK: - SlideDeckDetailView

/// The detail column for a single SlideDeck. Shows the deck header
/// + metadata row + tag bar + action row + the horizontal thumbnail
/// rail + the 16:9 slide canvas + speaker-notes editor + linked
/// entities. The canvas is ``SlideCanvasView`` (read-only in v1);
/// the deck-wide body can be edited via the embedded editor.
public struct SlideDeckDetailView: View {

    @ObservedObject public var viewModel: SlideDeckEditorViewModel
    @Binding public var selectedSlideIndex: Int
    public let onDelete: () -> Void
    public let onInsertSlide: (SlideLayout) -> Void
    public let onDeleteSlide: (Int) -> Void

    @State private var showDeleteConfirm: Bool = false
    @State private var showLinkSearch: Bool = false
    @State private var linkSearchQuery: String = ""
    @State private var showLayoutPicker: Bool = false

    public init(
        viewModel: SlideDeckEditorViewModel,
        selectedSlideIndex: Binding<Int>,
        onDelete: @escaping () -> Void,
        onInsertSlide: @escaping (SlideLayout) -> Void,
        onDeleteSlide: @escaping (Int) -> Void
    ) {
        self.viewModel = viewModel
        self._selectedSlideIndex = selectedSlideIndex
        self.onDelete = onDelete
        self.onInsertSlide = onInsertSlide
        self.onDeleteSlide = onDeleteSlide
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
                    thumbnailRail
                    canvasSection
                    notesSection
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
        .onChange(of: viewModel.deck.slideCount) { _, count in
            if selectedSlideIndex >= count { selectedSlideIndex = max(0, count - 1) }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "rectangle.on.rectangle")
                .symbolRenderingMode(.hierarchical)
                .font(.title3).foregroundStyle(.secondary)
            TextField("Title", text: $viewModel.draftTitle, onCommit: {
                Task { await viewModel.commitTitle() }
            })
            .textFieldStyle(.plain).font(.title).fontWeight(.bold)
        }
    }

    // MARK: - Metadata row

    private var metadataRow: some View {
        HStack(spacing: 8) {
            Text("\(viewModel.deck.slideCount) slide\(viewModel.deck.slideCount == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            Text("·").font(.caption).foregroundStyle(.tertiary)
            Text("\(viewModel.deck.wordCount) words")
                .font(.caption).foregroundStyle(.secondary)
            Text("·").font(.caption).foregroundStyle(.tertiary)
            Text(viewModel.deck.updatedAt, style: .relative)
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
            ForEach(viewModel.deck.tags, id: \.self) { tag in
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
            .textFieldStyle(.roundedBorder).controlSize(.small)
            .frame(maxWidth: 160)
        }
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 12) {
            Toggle(isOn: favoriteBinding) {
                Label(viewModel.deck.isFavorite ? "Favorited" : "Favorite",
                      systemImage: viewModel.deck.isFavorite ? "star.fill" : "star")
            }
            .toggleStyle(.button).controlSize(.small)

            Toggle(isOn: archiveBinding) {
                Label(viewModel.deck.isArchived ? "Archived" : "Archive",
                      systemImage: viewModel.deck.isArchived ? "archivebox.fill" : "archivebox")
            }
            .toggleStyle(.button).controlSize(.small)

            Toggle(isOn: trashBinding) {
                Label(viewModel.deck.isTrashed ? "In Trash" : "Trash",
                      systemImage: viewModel.deck.isTrashed ? "trash.fill" : "trash")
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

    // MARK: - Thumbnail rail

    private var thumbnailRail: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Slides").font(.headline)
                Text("(\(viewModel.deck.slideCount))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(SlideLayout.allCases, id: \.self) { layout in
                        Button("New \(layout.displayName)") { onInsertSlide(layout) }
                    }
                } label: {
                    Label("Add Slide", systemImage: "plus.rectangle.on.rectangle")
                }
                .controlSize(.small)
            }
            if viewModel.slides.isEmpty {
                Text("No slides yet. Add one to get started.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(viewModel.slides) { slide in
                            VStack(spacing: 4) {
                                SlideThumbnailView(
                                    slide: slide,
                                    isSelected: slide.index == selectedSlideIndex)
                                .onTapGesture { selectedSlideIndex = slide.index }
                                Text("\(slide.index + 1)").font(.caption2).foregroundStyle(.secondary)
                            }
                            .contextMenu {
                                Button("Duplicate") {
                                    Task {
                                        _ = try? await viewModel.store.duplicateSlide(
                                            at: slide.index, for: viewModel.deck.id)
                                        if let fresh = try? await viewModel.store.get(id: viewModel.deck.id) {
                                            viewModel.refresh(with: fresh)
                                        }
                                    }
                                }
                                Button("Delete", role: .destructive) {
                                    onDeleteSlide(slide.index)
                                }
                                Divider()
                                ForEach(SlideLayout.allCases, id: \.self) { layout in
                                    Button("Layout: \(layout.displayName)") {
                                        Task { await viewModel.setLayout(layout, at: slide.index) }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Canvas

    @ViewBuilder
    private var canvasSection: some View {
        if let slide = viewModel.slide(at: selectedSlideIndex) {
            SlideCanvasView(slide: slide, isSelected: true)
                .frame(height: 220)
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 8) {
                        Text(slide.layout.displayName)
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(.quaternary))
                        Menu {
                            ForEach(SlideLayout.allCases, id: \.self) { layout in
                                Button(layout.displayName) {
                                    Task { await viewModel.setLayout(layout, at: selectedSlideIndex) }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.caption)
                                .symbolRenderingMode(.hierarchical)
                        }
                        .menuStyle(.borderlessButton)
                    }
                    .padding(8)
                }
            HStack(spacing: 8) {
                Button {
                    selectedSlideIndex = max(0, selectedSlideIndex - 1)
                } label: {
                    Label("Prev", systemImage: "chevron.left")
                }
                .disabled(selectedSlideIndex == 0)
                Spacer()
                Text("Slide \(selectedSlideIndex + 1) of \(viewModel.deck.slideCount)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    selectedSlideIndex = min(viewModel.deck.slideCount - 1, selectedSlideIndex + 1)
                } label: {
                    Label("Next", systemImage: "chevron.right")
                }
                .disabled(selectedSlideIndex >= viewModel.deck.slideCount - 1)
            }
            .controlSize(.small)
        } else {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                .frame(height: 160)
                .overlay { Text("No slide selected").foregroundStyle(.secondary) }
        }
    }

    // MARK: - Speaker notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Speaker notes").font(.headline)
                Spacer()
                if let slide = viewModel.slide(at: selectedSlideIndex), !slide.notes.isEmpty {
                    Text("\(slide.notes.count) chars").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let slide = viewModel.slide(at: selectedSlideIndex) {
                if slide.notes.isEmpty {
                    Text("No speaker notes for this slide.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(slide.notes).font(.callout).foregroundStyle(.primary)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                }
            }
        }
    }

    // MARK: - Linked entities

    private var linkedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Linked entities").font(.headline)
                Spacer()
                if !viewModel.deck.linkedEntityIDs.isEmpty {
                    Text("\(viewModel.deck.linkedEntityIDs.count) link\(viewModel.deck.linkedEntityIDs.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if viewModel.deck.linkedEntityIDs.isEmpty {
                Text("No linked entities yet. Use Link… or the chat panel.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.deck.linkedEntityIDs, id: \.self) { id in
                        SlideLinkedEntityChip(id: id)
                    }
                }
            }
        }
    }

    // MARK: - Bindings

    private var favoriteBinding: Binding<Bool> {
        Binding(
            get: { viewModel.deck.isFavorite },
            set: { _ in Task { await viewModel.toggleFavorite() } })
    }
    private var archiveBinding: Binding<Bool> {
        Binding(
            get: { viewModel.deck.isArchived },
            set: { _ in Task { await viewModel.toggleArchived() } })
    }
    private var trashBinding: Binding<Bool> {
        Binding(
            get: { viewModel.deck.isTrashed },
            set: { _ in Task { await viewModel.toggleTrashed() } })
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .destructiveAction) {
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Label("Delete Deck", systemImage: "trash")
            }
            .help("Delete this deck")
            .accessibilityLabel("Delete deck")
        }
    }

    // MARK: - Sheets

    private var deleteSheet: some View {
        VStack(spacing: 16) {
            Text("Delete this deck?").font(.headline)
            Text("This moves the deck to Trash. You can restore it later.")
                .foregroundStyle(.secondary).font(.callout)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Cancel", role: .cancel) { showDeleteConfirm = false }
                Button("Move to Trash", role: .destructive) {
                    showDeleteConfirm = false
                    Task { await viewModel.toggleTrashed() }
                }
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private var linkSheet: some View {
        VStack(spacing: 12) {
            Text("Link entity").font(.headline)
            TextField("Entity ID (UUID)", text: $linkSearchQuery)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel", role: .cancel) { showLinkSearch = false }
                Spacer()
                Button("Link") {
                    if let uuid = UUID(uuidString: linkSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        Task { await viewModel.link(to: uuid) }
                    }
                    showLinkSearch = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - SlideLinkedEntityChip

private struct SlideLinkedEntityChip: View {
    let id: UUID
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "link").font(.caption2).foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            Text(id.uuidString.prefix(8) + "…").font(.caption).foregroundStyle(.primary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(.quaternary))
    }
}
