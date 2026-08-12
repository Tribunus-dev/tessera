import SwiftUI
import AppKit
import TesseraCore

// MARK: - CodeDetailView

/// The host view for the code editor surface. Owns the ribbon toolbar,
/// the shared coordinator + formatting state, and composes the
/// ``CodeEditorView`` child.
///
/// **Host/child split.** The ribbon toolbar lives in the window toolbar
/// (not inside the scrollable editor), matching the DocDetailView pattern.
/// The host passes the coordinator down so the toolbar can route view-level
/// commands to the text view without touching the document AST.
public struct CodeDetailView: View {

    @ObservedObject public var viewModel: CodeSurfaceViewModel
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Ribbon state (shared with editor)

    @State private var formattingState: FormattingState = FormattingState()
    @State private var isFocusMode: Bool = false
    @State private var editorCoordinator: TesseraEditorView.Coordinator = {
        TesseraEditorView.Coordinator(
            mode: .code,
            theme: .light,
            onMutationCommitted: nil,
            onViewCommand: nil,
            onFormattingStateChanged: nil
        )
    }()

    public init(viewModel: CodeSurfaceViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let file = viewModel.currentFile {
                CodeEditorView(
                    viewModel: viewModel,
                    editorCoordinator: editorCoordinator,
                    formattingState: $formattingState
                )
            } else {
                emptyState
            }

            if !isFocusMode {
                Divider()
                statusBar
            }
        }
        .toolbar { editorToolbar }
        .alert("Restore unsaved changes?", isPresented: Binding(
            get: { viewModel.pendingRecovery },
            set: { if !$0 { viewModel.discardRecovery() } }
        )) {
            Button("Restore") {
                Task { await viewModel.recoverFromBackup() }
            }
            Button("Discard", role: .destructive) {
                viewModel.discardRecovery()
            }
        } message: {
            Text("It looks like Tessera crashed while editing this file. A more recent version was found in the backup.")
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
            // Initialise line numbers from the code defaults.
            formattingState.showLineNumbers = true
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView(
            "Select a file to view or edit",
            systemImage: "chevron.left.forwardslash.chevron.right",
            description: Text("Choose a file from the sidebar.")
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .secondaryAction) {
            TesseraEditorToolbar(
                mode: .code,
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
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let file = viewModel.currentFile {
                Text("\(lineCount(for: file.body)) lines")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Text("~\(readingTime(for: file.body)) min read")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(viewModel.isSaving ? "Saving…" : "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let error = viewModel.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func lineCount(for body: String) -> Int {
        max(1, body.components(separatedBy: "\n").count)
    }

    private func readingTime(for body: String) -> Int {
        // Approximate: 50 lines/minute for code reading.
        let lines = lineCount(for: body)
        return max(1, (lines + 49) / 50)
    }

    // MARK: - Editor command handling

    private func handleEditorCommand(_ command: EditorCommand) {
        switch command {
        case .toggleLineNumbers:
            formattingState.showLineNumbers.toggle()
            editorCoordinator.handleViewCommand(command)
        case .enterFocusMode:
            withAnimation(.easeInOut(duration: 0.25)) {
                isFocusMode.toggle()
                editorCoordinator.updateFocusMode(isFocusMode)
            }
        default:
            // Code mode toolbar has no other commands; forward anyway.
            editorCoordinator.handleViewCommand(command)
        }
    }
}
