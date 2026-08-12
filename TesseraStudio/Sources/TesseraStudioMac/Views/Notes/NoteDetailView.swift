import SwiftUI
import AppKit
import TesseraCore

// MARK: - NoteDetailView

/// The detail column for a single note. Shows the title,
/// tag bar, pin/archive toggles, the editor, and linked
/// entities.
///
/// **Ribbon toolbar.** The ``TesseraEditorToolbar`` lives in the
/// macOS window toolbar (`.toolbar`) — it does not scroll with
/// the note. The host owns the shared state
/// (`formattingState`, `isFocusMode`, `editorCoordinator`) and
/// passes them to both the toolbar and the editor.
public struct NoteDetailView: View {

    @ObservedObject public var viewModel: NoteEditorViewModel
    public let onDelete: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    @State private var showDeleteConfirm: Bool = false
    @State private var showLinkSearch: Bool = false
    @State private var linkSearchQuery: String = ""

    // MARK: - Ribbon state (shared with editor)

    @State private var formattingState: FormattingState = FormattingState()
    @State private var isFocusMode: Bool = false
    @State private var editorCoordinator: TesseraEditorView.Coordinator = {
        TesseraEditorView.Coordinator(
            mode: .notes,
            theme: .light,
            onMutationCommitted: nil,
            onViewCommand: nil,
            onFormattingStateChanged: nil
        )
    }()

    public init(viewModel: NoteEditorViewModel, onDelete: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !isFocusMode {
                        headerSection
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
            Text("It looks like Tessera crashed during your last session. A more recent version of this note was found in the backup.")
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
                mode: .notes,
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
            .help("Toggle focus mode (Cmd-\\)")
            .accessibilityLabel(isFocusMode ? "Exit Focus" : "Focus")
            .keyboardShortcut("\\", modifiers: .command)
        }

        ToolbarItem(placement: .destructiveAction) {
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete this note")
            .accessibilityLabel("Delete note")
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
        .accessibilityLabel("Note title")
    }

    // MARK: - Tag bar

    private var tagBar: some View {
        HStack(spacing: 6) {
            FlowLayout(spacing: 4) {
                ForEach(viewModel.note.tags, id: \.self) { tag in
                    Button {
                        Task { await viewModel.removeTag(tag) }
                    } label: {
                        HStack(spacing: 4) {
                            Text("#\(tag)")
                            Image(systemName: "xmark")
                                .symbolRenderingMode(.hierarchical)
                                .font(.caption2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove tag \(tag)")
                    .accessibilityHint("Removes the tag '\(tag)' from this note")
                }
            }
            TextField("Add tag…", text: $viewModel.draftTag, onCommit: {
                Task { await viewModel.addDraftTag() }
            })
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(maxWidth: 160)
        }
    }

    // MARK: - Action row (pin / archive / link)

    private var actionRow: some View {
        HStack(spacing: 12) {
            Toggle(isOn: pinBinding) {
                Label(
                    viewModel.note.isPinned ? "Pinned" : "Pin",
                    systemImage: viewModel.note.isPinned ? "pin.fill" : "pin"
                )
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .accessibilityLabel(viewModel.note.isPinned ? "Pinned" : "Pin note")
            .accessibilityValue(viewModel.note.isPinned ? "Note is pinned" : "Note is not pinned")

            Toggle(isOn: archiveBinding) {
                Label(
                    viewModel.note.isArchived ? "Archived" : "Archive",
                    systemImage: viewModel.note.isArchived ? "archivebox.fill" : "archivebox"
                )
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .accessibilityLabel(viewModel.note.isArchived ? "Archived" : "Archive note")
            .accessibilityValue(viewModel.note.isArchived ? "Note is archived" : "Note is not archived")

            Button { showLinkSearch = true } label: {
                Label("Link…", systemImage: "link.badge.plus")
            }
            .controlSize(.small)
            .accessibilityLabel("Link to another material")
            .accessibilityHint("Opens a sheet to paste an entity UUID and create a link")

            Spacer()

            if viewModel.isSaving {
                ProgressView()
                    .controlSize(.small)
            }
            if let err = viewModel.lastError {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .font(.callout)
    }

    // MARK: - Editor

    private var editorSection: some View {
        NoteEditorView(
            viewModel: viewModel,
            editorCoordinator: editorCoordinator,
            formattingState: $formattingState,
            isFocusMode: $isFocusMode
        )
        .frame(minHeight: 260)
    }

    // MARK: - Linked entities

    private var linkedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Linked entities")
                    .font(.headline)
                Spacer()
                if !viewModel.note.linkedEntityIDs.isEmpty {
                    Text("\(viewModel.note.linkedEntityIDs.count) link\(viewModel.note.linkedEntityIDs.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if viewModel.note.linkedEntityIDs.isEmpty {
                Text("No linked entities yet. Use the Link… button or chat panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(viewModel.note.linkedEntityIDs, id: \.self) { id in
                        LinkedEntityChip(id: id)
                    }
                }
            }
        }
    }

    // MARK: - Sheets

    private var deleteSheet: some View {
        VStack(spacing: 16) {
            Text("Delete this note?")
                .font(.headline)
            Text("\"\(viewModel.note.displayTitle)\"")
                .foregroundStyle(.secondary)
            Text("The note is removed from your library. The receipt chain is preserved for the audit trail.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)
            HStack {
                Button("Cancel") { showDeleteConfirm = false }
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    showDeleteConfirm = false
                    onDelete()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 360)
    }

    private var linkSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link to another material")
                .font(.headline)
            TextField("Paste an entity UUID",
                      text: $linkSearchQuery)
                .textFieldStyle(.roundedBorder)
            Text("v1: paste an entity UUID. v2 wires hybrid_search.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        .padding()
        .frame(width: 460)
    }

    // MARK: - Bindings

    private var pinBinding: Binding<Bool> {
        Binding<Bool>(
            get: { viewModel.note.isPinned },
            set: { _ in Task { await viewModel.togglePinned() } }
        )
    }

    private var archiveBinding: Binding<Bool> {
        Binding<Bool>(
            get: { viewModel.note.isArchived },
            set: { _ in Task { await viewModel.toggleArchived() } }
        )
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
        default:
            editorCoordinator.handleViewCommand(command)
        }
        let ast = viewModel.document
        Task { await viewModel.commitBody(ast) }
    }
}

// MARK: - LinkedEntityChip

/// A small chip showing a linked entity's UUID in a
/// compact form. v1 is a placeholder — v2 will resolve
/// the UUID to the entity's display label via the data
/// layer.
private struct LinkedEntityChip: View {
    let id: UUID

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "link")
                .symbolRenderingMode(.hierarchical)
            Text(String(id.uuidString.prefix(8)) + "…")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Linked entity, ID \(String(id.uuidString.prefix(8)))")
    }
}
