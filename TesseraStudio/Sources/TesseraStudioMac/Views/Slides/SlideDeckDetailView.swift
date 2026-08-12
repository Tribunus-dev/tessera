import SwiftUI
import TesseraCore

// MARK: - SlideDeckDetailView

/// The detail column for a single SlideDeck. Acts as the host:
/// owns the ribbon state (`formattingState`, `editorCoordinator`,
/// `isFocusMode`) and the window toolbar, and renders the child
/// ``SlideDeckEditorView`` for the scrollable content.
///
/// **Architecture parity with DocDetailView.** The toolbar lives
/// in the window toolbar (`.toolbar { editorToolbar }`) — it does
/// not scroll with the content. The host owns the shared state and
/// passes them to both the toolbar and the child editor.
public struct SlideDeckDetailView: View {

    @ObservedObject public var viewModel: SlideDeckEditorViewModel
    @Binding public var selectedSlideIndex: Int
    public let onDelete: () -> Void
    public let onInsertSlide: (SlideLayout) -> Void
    public let onDeleteSlide: (Int) -> Void

    @Environment(\.scenePhase) private var scenePhase

    @State private var formattingState: FormattingState = FormattingState()
    @State private var isFocusMode: Bool = false
    @State private var editorCoordinator: TesseraEditorView.Coordinator = {
        TesseraEditorView.Coordinator(
            mode: .document,
            theme: .light,
            onMutationCommitted: nil,
            onViewCommand: nil,
            onFormattingStateChanged: nil
        )
    }()

    @State private var showDeleteConfirm: Bool = false
    @State private var showLinkSearch: Bool = false
    @State private var showLayoutPicker: Bool = false
    @State private var linkSearchQuery: String = ""

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
                    if !isFocusMode {
                        headerSection
                        metadataRow
                        tagBar
                        actionRow
                        Divider()
                        thumbnailRail
                    }
                    SlideDeckEditorView(
                        viewModel: viewModel,
                        editorCoordinator: editorCoordinator,
                        formattingState: $formattingState,
                        isFocusMode: $isFocusMode,
                        selectedSlideIndex: $selectedSlideIndex,
                        onInsertSlide: onInsertSlide,
                        onDeleteSlide: onDeleteSlide
                    )
                    if !isFocusMode {
                        Divider()
                        linkedSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(.background)
        .toolbar { editorToolbar }
        .sheet(isPresented: $showDeleteConfirm) { deleteSheet }
        .sheet(isPresented: $showLinkSearch) { linkSheet }
        .alert("Restore unsaved changes?", isPresented: $viewModel.pendingRecovery) {
            Button("Restore") {
                Task { await viewModel.recoverFromBackup() }
            }
            Button("Discard", role: .destructive) {
                viewModel.discardRecovery()
            }
        } message: {
            Text("It looks like Tessera crashed during your last session. A more recent version of this deck was found in the backup.")
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                viewModel.checkRecovery()
            case .inactive, .background:
                Task { await viewModel.flushBody() }
                viewModel.saveRecoveryFile()
            @unknown default:
                break
            }
        }
        .onAppear {
            editorCoordinator.onFormattingStateChanged = { newState in
                self.formattingState = newState
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .secondaryAction) {
            TesseraEditorToolbar(
                mode: .document,
                formattingState: $formattingState,
                onCommand: { command in
                    handleEditorCommand(command)
                },
                isFocusModeActive: isFocusMode
            )
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isFocusMode.toggle()
                }
            } label: {
                Label(
                    isFocusMode ? "Exit Focus" : "Focus",
                    systemImage: isFocusMode
                        ? "arrow.up.right.and.arrow.down.left.rectangle"
                        : "arrow.down.left.and.arrow.up.right.rectangle"
                )
            }
            .help("Toggle focus mode")
            .accessibilityLabel(isFocusMode ? "Exit Focus" : "Focus")
        }

        ToolbarItem(placement: .destructiveAction) {
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Label("Delete Deck", systemImage: "trash")
            }
            .help("Delete this deck")
            .accessibilityLabel("Delete deck")
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
            .accessibilityLabel("Slide deck title")
        }
    }

    // MARK: - Metadata row

    private var metadataRow: some View {
        SurfaceMetadataRow(
            isSaving: viewModel.isSaving,
            lastError: viewModel.lastError,
            stats: [
                (label: "\(viewModel.deck.slideCount)", value: viewModel.deck.slideCount == 1 ? "slide" : "slides"),
                (label: "\(viewModel.deck.wordCount)", value: "words"),
            ]
        )
    }

    // MARK: - Tag bar

    private var tagBar: some View {
        SurfaceTagBar(
            tags: viewModel.deck.tags,
            draftTag: $viewModel.draftTag,
            onRemove: { tag in Task { await viewModel.removeTag(tag) } },
            onAdd: { Task { await viewModel.addDraftTag() } }
        )
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
                .accessibilityLabel("Add new slide")
            }
            if viewModel.slides.isEmpty {
                Text("No slides yet. Add one to get started.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(viewModel.slides) { slide in
                            VStack(spacing: 4) {
                                Button { selectedSlideIndex = slide.index } label: {
                                    SlideThumbnailView(
                                        slide: slide,
                                        isSelected: slide.index == selectedSlideIndex)
                                }
                                .buttonStyle(.plain)
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
                        SurfaceLinkedEntityChip(id: id)
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

    // MARK: - Editor command handling

    private func handleEditorCommand(_ command: EditorCommand) {
        switch command {
        case .toggleLineNumbers:
            formattingState.showLineNumbers.toggle()
            editorCoordinator.handleViewCommand(command)
        case .toggleRuler:
            formattingState.showRuler.toggle()
            editorCoordinator.handleViewCommand(command)
        case .toggleGridlines:
            formattingState.showGridlines.toggle()
            editorCoordinator.handleViewCommand(command)
        case .enterFocusMode:
            withAnimation(.easeInOut(duration: 0.25)) {
                isFocusMode.toggle()
                editorCoordinator.updateFocusMode(isFocusMode)
            }
            editorCoordinator.handleViewCommand(command)
        case .toggleBold:
            formattingState.isBold.toggle()
            editorCoordinator.handleViewCommand(command)
        case .toggleItalic:
            formattingState.isItalic.toggle()
            editorCoordinator.handleViewCommand(command)
        case .toggleUnderline:
            formattingState.isUnderline.toggle()
            editorCoordinator.handleViewCommand(command)
        case .toggleStrikethrough:
            formattingState.isStrikethrough.toggle()
            editorCoordinator.handleViewCommand(command)
        case .toggleCode:
            formattingState.isCode.toggle()
            editorCoordinator.handleViewCommand(command)
        case .alignLeft:
            formattingState.alignment = .leading
            editorCoordinator.handleViewCommand(command)
        case .alignCenter:
            formattingState.alignment = .center
            editorCoordinator.handleViewCommand(command)
        case .alignRight:
            formattingState.alignment = .trailing
            editorCoordinator.handleViewCommand(command)
        case .alignJustify:
            formattingState.alignment = .justify
            editorCoordinator.handleViewCommand(command)
        case .showWordCount:
            break
        default:
            editorCoordinator.handleViewCommand(command)
        }
        let ast = viewModel.document
        Task { await viewModel.commitBody(ast) }
    }
}
