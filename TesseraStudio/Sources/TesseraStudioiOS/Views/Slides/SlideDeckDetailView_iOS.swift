#if os(iOS)
import SwiftUI
import TesseraCore

// MARK: - SlideDeckDetailView_iOS

/// The iOS detail for one deck. Vertical scroll: header + metadata
/// + tags + action row + thumbnail rail + swipeable 16:9 canvas
/// + speaker notes + linked entities. The thumbnail rail and the
/// canvas stay in sync via `selectedSlideIndex`.
public struct SlideDeckDetailView_iOS: View {

    @ObservedObject public var viewModel: SlideDeckEditorViewModel
    @Binding public var selectedSlideIndex: Int

    @State private var draftTitle: String = ""
    @State private var showDeleteConfirm = false

    public init(viewModel: SlideDeckEditorViewModel, selectedSlideIndex: Binding<Int>) {
        self.viewModel = viewModel
        self._selectedSlideIndex = selectedSlideIndex
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
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
        .navigationTitle(viewModel.deck.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { detailToolbar }
        .onAppear { draftTitle = viewModel.deck.title }
        .alert("Move to Trash?", isPresented: $showDeleteConfirm) {
            Button("Move to Trash", role: .destructive) {
                Task { await viewModel.toggleTrashed() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can restore this deck from Trash later.")
        }
        .onChange(of: viewModel.deck.slideCount) { _, count in
            if selectedSlideIndex >= count { selectedSlideIndex = max(0, count - 1) }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "rectangle.on.rectangle").foregroundStyle(.secondary)
            TextField("Title", text: $draftTitle, onCommit: {
                viewModel.draftTitle = draftTitle
                Task { await viewModel.commitTitle() }
            })
            .textFieldStyle(.plain)
            .font(.title3).fontWeight(.bold)
        }
        .onAppear { draftTitle = viewModel.deck.title }
        .onChange(of: viewModel.deck.title) { _, new in draftTitle = new }
    }

    // MARK: - Metadata

    private var metadataRow: some View {
        HStack(spacing: 8) {
            Text("\(viewModel.deck.slideCount) slide\(viewModel.deck.slideCount == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            Text("·").font(.caption).foregroundStyle(.tertiary)
            Text(viewModel.deck.updatedAt, style: .relative)
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if viewModel.isSaving { ProgressView().controlSize(.small) }
        }
    }

    // MARK: - Tag bar

    private var tagBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.deck.tags, id: \.self) { tag in
                    Button { Task { await viewModel.removeTag(tag) } } label: {
                        HStack(spacing: 4) {
                            Text("#\(tag)").font(.caption)
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
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
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                Task { await viewModel.toggleFavorite() }
            } label: {
                Label(viewModel.deck.isFavorite ? "Favorited" : "Favorite",
                      systemImage: viewModel.deck.isFavorite ? "star.fill" : "star")
            }
            .controlSize(.small)

            Button {
                Task { await viewModel.toggleArchived() }
            } label: {
                Label(viewModel.deck.isArchived ? "Archived" : "Archive",
                      systemImage: viewModel.deck.isArchived ? "archivebox.fill" : "archivebox")
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
                        Button("New \(layout.displayName)") {
                            Task {
                                let updated = try? await viewModel.store.insertSlide(
                                    at: selectedSlideIndex + 1, for: viewModel.deck.id, layout: layout)
                                if let fresh = updated { viewModel.refresh(with: fresh) }
                            }
                        }
                    }
                } label: {
                    Label("Add", systemImage: "plus.rectangle.on.rectangle")
                        .font(.caption)
                }
            }
            if viewModel.slides.isEmpty {
                Text("No slides yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(viewModel.slides) { slide in
                            VStack(spacing: 4) {
                                SlideThumbnailView_iOS(
                                    slide: slide,
                                    isSelected: slide.index == selectedSlideIndex)
                                .onTapGesture { selectedSlideIndex = slide.index }
                                Text("\(slide.index + 1)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Canvas (swipeable)

    private var canvasSection: some View {
        Group {
            if let slide = viewModel.slide(at: selectedSlideIndex) {
                VStack(spacing: 8) {
                    SlideCanvasView_iOS(slide: slide)
                        .frame(height: 190)
                        .gesture(
                            DragGesture(minimumDistance: 30)
                                .onEnded { value in
                                    if value.translation.width < -40,
                                       selectedSlideIndex < viewModel.deck.slideCount - 1 {
                                        withAnimation { selectedSlideIndex += 1 }
                                    } else if value.translation.width > 40, selectedSlideIndex > 0 {
                                        withAnimation { selectedSlideIndex -= 1 }
                                    }
                                }
                        )
                    HStack(spacing: 8) {
                        Button { if selectedSlideIndex > 0 { selectedSlideIndex -= 1 } } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(selectedSlideIndex == 0)
                        Spacer()
                        Text("Slide \(selectedSlideIndex + 1) of \(viewModel.deck.slideCount)")
                            .font(.caption).foregroundStyle(.secondary)
                        if !slide.layout.displayName.isEmpty {
                            Text("·").font(.caption).foregroundStyle(.tertiary)
                            Text(slide.layout.displayName).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { if selectedSlideIndex < viewModel.deck.slideCount - 1 { selectedSlideIndex += 1 } } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(selectedSlideIndex >= viewModel.deck.slideCount - 1)
                    }
                    .controlSize(.small)
                    Text("Swipe to move between slides.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08))
                    .frame(height: 160)
                    .overlay { Text("No slide selected").foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: - Speaker notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Speaker notes").font(.headline)
            if let slide = viewModel.slide(at: selectedSlideIndex) {
                if slide.notes.isEmpty {
                    Text("No speaker notes for this slide.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(slide.notes).font(.callout)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                }
            }
        }
    }

    // MARK: - Linked entities

    private var linkedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Linked entities").font(.headline)
            if viewModel.deck.linkedEntityIDs.isEmpty {
                Text("No linked entities yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.deck.linkedEntityIDs, id: \.self) { id in
                        Label(id.uuidString.prefix(8) + "…", systemImage: "link")
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color.secondary.opacity(0.10)))
                    }
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Favorite") { Task { await viewModel.toggleFavorite() } }
                Button(viewModel.deck.isArchived ? "Unarchive" : "Archive") {
                    Task { await viewModel.toggleArchived() }
                }
                Button("Move to Trash", role: .destructive) { showDeleteConfirm = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

// MARK: - SlideCanvasView_iOS

private struct SlideCanvasView_iOS: View {
    let slide: Slide
    var body: some View {
        SlideCanvasView(slide: slide, isSelected: true)
    }
}

// MARK: - SlideThumbnailView_iOS

private struct SlideThumbnailView_iOS: View {
    let slide: Slide
    let isSelected: Bool
    var body: some View {
        SlideThumbnailView(slide: slide, isSelected: isSelected)
    }
}

#endif
