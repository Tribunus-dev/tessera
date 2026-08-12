import SwiftUI
import TesseraCore

// MARK: - DocDetailView

/// The detail column for a single Doc. Shows the cover image,
/// icon, title, metadata row, tag bar, editor, and linked
/// entities.
///
/// **Ribbon toolbar.** The ``TesseraEditorToolbar`` lives in the
/// macOS window toolbar (`.toolbar`) — it does not scroll with
/// the document. The host owns the shared state
/// (`formattingState`, `isFocusMode`, `editorCoordinator`) and
/// passes them to both the toolbar and the editor.
public struct DocDetailView: View {

    @ObservedObject public var viewModel: DocEditorViewModel
    public let onDelete: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    @State private var showDeleteConfirm: Bool = false
    @State private var showLinkSearch: Bool = false
    @State private var showVersionHistory: Bool = false
    @State private var showLayoutInspector: Bool = false
    @State private var showCommentsSidebar: Bool = false
    @State private var linkSearchQuery: String = ""

    // MARK: - Ribbon state (shared with editor)

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

    public init(viewModel: DocEditorViewModel, onDelete: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !isFocusMode {
                        coverSection
                        headerSection
                        metadataRow
                        tagBar
                        actionRow
                        Divider()
                    }
                    editorSection
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
            Text("It looks like Tessera crashed during your last session. A more recent version of this document was found in the backup.")
        }
        .sheet(isPresented: $showVersionHistory) {
            VersionHistorySheet(doc: viewModel.doc, store: viewModel.store)
        }
        .sheet(isPresented: $showLayoutInspector) {
            LayoutInspectorView(
                document: Binding(
                    get: { viewModel.document },
                    set: { newDoc in
                        // Directly push the updated AST through the coordinator.
                        editorCoordinator.binding?.wrappedValue = newDoc
                    }
                ),
                onCommand: { command in
                    editorCoordinator.handleViewCommand(command)
                }
            )
        }
        .sheet(isPresented: $showCommentsSidebar) {
            CommentsSidebarView(
                document: Binding(
                    get: { viewModel.document },
                    set: { newDoc in
                        editorCoordinator.binding?.wrappedValue = newDoc
                    }
                ),
                trackChangesEnabled: formattingState.isTrackChangesEnabled,
                onInsertComment: {
                    editorCoordinator.handleViewCommand(.insertComment)
                },
                onNavigateToComment: { threadID in
                    // Navigate: select the anchor block of the comment thread.
                    if let block = viewModel.document.blocks[threadID],
                       let anchorID = UUID(uuidString: block.attributes["anchorBlockID"]?.stringValue ?? "") {
                        editorCoordinator.selectBlock(id: anchorID)
                    }
                },
                onAcceptChange: { changeID in
                    editorCoordinator.acceptChange(id: changeID)
                    updateCommentCounts()
                },
                onRejectChange: { changeID in
                    editorCoordinator.rejectChange(id: changeID)
                    updateCommentCounts()
                },
                onResolveComment: { threadID in
                    resolveComment(id: threadID)
                },
                onDismiss: { showCommentsSidebar = false }
            )
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // App became active — check for recovery backup.
                viewModel.checkRecovery()
            case .inactive, .background:
                // App going to background — flush any pending save and write recovery file.
                Task { await viewModel.flushBody() }
                viewModel.saveRecoveryFile()
            @unknown default:
                break
            }
        }
        .onAppear {
            // Selection-change observer fires handleEditorCommand which updates
            // formattingState directly; no additional wiring needed here.
            editorCoordinator.onFormattingStateChanged = { newState in
                self.formattingState = newState
            }
            // Initialize comment/change counts for the Review tab badges.
            updateCommentCounts()
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
                Label("Delete", systemImage: "trash")
            }
            .help("Hard-delete this document")
            .accessibilityLabel("Delete document")
        }
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
                Text(emoji).font(.title).accessibilityHidden(true)
            }
            TextField("Title", text: $viewModel.draftTitle, onCommit: {
                Task { await viewModel.commitTitle() }
            })
            .textFieldStyle(.plain)
            .font(.title)
            .fontWeight(.bold)
            .accessibilityLabel("Document title")
        }
    }

    // MARK: - Metadata row

    private var metadataRow: some View {
        SurfaceMetadataRow(
            isSaving: viewModel.isSaving,
            lastError: viewModel.lastError,
            stats: [
                (label: "\(viewModel.doc.wordCount)", value: "words"),
                (label: "\(viewModel.doc.readingTimeMinutes)", value: "min read"),
            ]
        )
    }

    // MARK: - Tag bar

    private var tagBar: some View {
        SurfaceTagBar(
            tags: viewModel.doc.tags,
            draftTag: $viewModel.draftTag,
            onRemove: { tag in Task { await viewModel.removeTag(tag) } },
            onAdd: { Task { await viewModel.addDraftTag() } }
        )
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 12) {
            Toggle(isOn: favoriteBinding) {
                Label(viewModel.doc.isFavorite ? "Favorited" : "Favorite",
                      systemImage: viewModel.doc.isFavorite ? "star.fill" : "star")
            }
            .toggleStyle(.button).controlSize(.small)
            .accessibilityLabel(viewModel.doc.isFavorite ? "Favorited" : "Favorite")
            .accessibilityValue(viewModel.doc.isFavorite ? "Document is favorited" : "Document is not favorited")

            Toggle(isOn: archiveBinding) {
                Label(viewModel.doc.isArchived ? "Archived" : "Archive",
                      systemImage: viewModel.doc.isArchived ? "archivebox.fill" : "archivebox")
            }
            .toggleStyle(.button).controlSize(.small)
            .accessibilityLabel(viewModel.doc.isArchived ? "Archived" : "Archive document")
            .accessibilityValue(viewModel.doc.isArchived ? "Document is archived" : "Document is not archived")

            Toggle(isOn: trashBinding) {
                Label(viewModel.doc.isTrashed ? "In Trash" : "Trash",
                      systemImage: viewModel.doc.isTrashed ? "trash.fill" : "trash")
            }
            .toggleStyle(.button).controlSize(.small)
            .accessibilityLabel(viewModel.doc.isTrashed ? "In Trash" : "Move to Trash")
            .accessibilityValue(viewModel.doc.isTrashed ? "Document is in trash" : "Document is not in trash")

            Button { showLinkSearch = true } label: {
                Label("Link…", systemImage: "link.badge.plus")
            }
            .controlSize(.small)
            .accessibilityLabel("Link to another material")
            .accessibilityHint("Opens a sheet to paste an entity UUID and create a link")

            Spacer()
        }
        .font(.callout)
    }

    // MARK: - Editor

    private var editorSection: some View {
        DocEditorView(
            viewModel: viewModel,
            editorCoordinator: editorCoordinator,
            formattingState: $formattingState,
            isFocusMode: $isFocusMode,
            onUnhandledCommand: { command in
                handleEditorCommand(command)
            }
        )
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
                        SurfaceLinkedEntityChip(id: id)
                    }
                }
            }
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
                Button("Cancel") { showDeleteConfirm = false }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) { showDeleteConfirm = false; onDelete() }
                    .keyboardShortcut(.defaultAction)
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
        case .showVersionHistory:
            showVersionHistory = true
        case .setMargins, .setOrientation, .setColumns, .setPageColor:
            editorCoordinator.handleViewCommand(command)
            showLayoutInspector = true
        case .showWordCount:
            // Word count is shown in the status bar; no action needed here.
            break
        // Phase 7: Comments & Track Changes
        case .toggleTrackChanges:
            formattingState.isTrackChangesEnabled.toggle()
            editorCoordinator.handleViewCommand(command)
        case .toggleCommentsPanel:
            showCommentsSidebar.toggle()
            formattingState.isCommentsPanelVisible = showCommentsSidebar
            updateCommentCounts()
        case .insertComment:
            editorCoordinator.handleViewCommand(command)
            if !showCommentsSidebar {
                showCommentsSidebar = true
                formattingState.isCommentsPanelVisible = true
            }
        case .acceptChange, .rejectChange:
            editorCoordinator.handleViewCommand(command)
            updateCommentCounts()
        case .spellCheck:
            editorCoordinator.handleViewCommand(command)
        case .nextComment, .previousComment:
            editorCoordinator.handleViewCommand(command)
        // Phase 8: Find / Replace
        case .showFindReplace, .findNext, .findPrevious, .replaceNext, .replaceAll:
            editorCoordinator.handleViewCommand(command)
        default:
            editorCoordinator.handleViewCommand(command)
        }
        let ast = viewModel.document
        Task { await viewModel.commitBody(ast) }
    }

    private func updateCommentCounts() {
        let doc = viewModel.document
        formattingState.commentCount = CommentStore.count(from: doc)
        formattingState.pendingChangeCount = CommentStore.pendingChangeCount(from: doc)
    }

    private func resolveComment(id: UUID) {
        guard var doc = editorCoordinator.binding?.wrappedValue else { return }
        guard var block = doc.blocks[id], block.type == .comment else { return }
        block.attributes["resolved"] = .bool(true)
        doc.blocks[id] = block
        editorCoordinator.binding?.wrappedValue = doc
        updateCommentCounts()
        Task {
            await viewModel.commitBody(doc)
        }
    }
}

