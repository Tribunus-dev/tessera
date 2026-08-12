import SwiftUI
import TesseraCore

// MARK: - SheetDetailView

/// The detail column for a single Sheet. Hosts the ribbon toolbar,
/// shared editor state, and delegates the editing surface to
/// ``SheetEditorView``.
///
/// **Ribbon toolbar.** The ``TesseraEditorToolbar`` lives in the
/// macOS window toolbar (`.toolbar`) — it does not scroll with
/// the document. The host owns the shared state
/// (`formattingState`, `isFocusMode`, `editorCoordinator`) and
/// passes them to both the toolbar and the editor.
///
/// **Focus mode.** Animates the grid to full-screen; a status bar
/// shows "Sheet" (grid has no word count).
public struct SheetDetailView: View {

    @ObservedObject public var viewModel: SheetEditorViewModel
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
            mode: .sheets,
            theme: .light,
            onMutationCommitted: nil,
            onViewCommand: nil,
            onFormattingStateChanged: nil
        )
    }()

    /// Controls whether the grid's inline cell editor TextField
    /// has keyboard focus. `.focused()` requires a FocusState.Binding;
    /// we hold the `@FocusState` at the host so both the formula
    /// bar TextField and the grid's cell TextField share the same
    /// focus source.
    @FocusState private var gridEditingFocused: Bool

    public init(viewModel: SheetEditorViewModel, onDelete: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !isFocusMode {
                        headerSection
                        metadataRow
                        formulaBar
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
            Text("It looks like Tessera crashed during your last session. A more recent version of this sheet was found in the backup.")
        }
        .onChange(of: viewModel.editingCell) { _, newCoord in
            gridEditingFocused = newCoord != nil
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
                mode: .sheets,
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
            .help("Hard-delete this sheet")
            .accessibilityLabel("Delete sheet")
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
        .accessibilityLabel("Sheet title")
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
            Text(cellAddressLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .center)
                .padding(.vertical, 6)
                .background(Color(.quaternarySystemFill))

            Rectangle()
                .fill(.separator)
                .frame(width: 1, height: 20)

            Text("fx")
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .center)

            Rectangle()
                .fill(.separator)
                .frame(width: 1, height: 20)

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
                .accessibilityLabel("Cell formula for \(cellAddressLabel)")
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
                if viewModel.editingCell == coord {
                    return viewModel.editingText
                }
                return viewModel.sheet.cellText(row: coord.row, col: coord.col)
            },
            set: { newText in
                if viewModel.editingCell == nil {
                    viewModel.beginEditingCell(coord)
                }
                viewModel.editingText = newText
            }
        )
    }

    // MARK: - Editor

    private var editorSection: some View {
        VStack(spacing: 0) {
            SheetEditorView(
                viewModel: viewModel,
                editorCoordinator: editorCoordinator,
                formattingState: $formattingState,
                gridEditingFocused: $gridEditingFocused
            )

            if isFocusMode {
                focusStatusBar
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Focus status bar

    /// The focus-mode status bar shown at the bottom of the editor
    /// when `isFocusMode` is active. Sheets have no word count (the
    /// grid is the surface), so we show "Sheet" as the label.
    private var focusStatusBar: some View {
        SurfaceFocusStatusBar(
            wordCount: 0,
            readingMinutes: 0,
            onExit: {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isFocusMode.toggle()
                }
            }
        )
        .overlay(alignment: .leading) {
            Text("Sheet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        }
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

    // MARK: - Sheets

    private var deleteSheet: some View {
        VStack(spacing: 16) {
            Text("Delete this sheet?").font(.headline)
            Text("\"\(viewModel.sheet.displayTitle)\"").foregroundStyle(.secondary)
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
        Binding(get: { viewModel.sheet.isFavorite }, set: { _ in Task { await viewModel.toggleFavorite() } })
    }
    private var archiveBinding: Binding<Bool> {
        Binding(get: { viewModel.sheet.isArchived }, set: { _ in Task { await viewModel.toggleArchived() } })
    }
    private var trashBinding: Binding<Bool> {
        Binding(get: { viewModel.sheet.isTrashed }, set: { _ in Task { await viewModel.toggleTrashed() } })
    }

    // MARK: - Editor command handling

    /// Handles editor commands from the toolbar. Sheets only support
    /// focus-mode commands; all other commands are forwarded to the
    /// coordinator for future extension.
    private func handleEditorCommand(_ command: EditorCommand) {
        switch command {
        case .enterFocusMode:
            withAnimation(.easeInOut(duration: 0.25)) {
                isFocusMode.toggle()
                editorCoordinator.updateFocusMode(isFocusMode)
            }
        default:
            editorCoordinator.handleViewCommand(command)
        }
    }
}
