import SwiftUI
import AppKit
import TesseraCore

// MARK: - CodeEditorView

/// The code editor surface. Wraps ``TesseraEditorView`` in `.code`
/// mode with a single-block paragraph AST bridging the plain-text
/// file body.
///
/// **Host/child split.** The host (``CodeDetailView``) owns the
/// ribbon toolbar and shared state (coordinator, formattingState).
/// This view owns only the editor binding and wires mutations back
/// to the view model via `commitBody`.
public struct CodeEditorView: View {

    @ObservedObject public var viewModel: CodeSurfaceViewModel
    public var editorCoordinator: TesseraEditorView.Coordinator
    public var formattingState: Binding<FormattingState>

    @Environment(\.colorScheme) private var colorScheme

    public init(
        viewModel: CodeSurfaceViewModel,
        editorCoordinator: TesseraEditorView.Coordinator,
        formattingState: Binding<FormattingState>
    ) {
        self.viewModel = viewModel
        self.editorCoordinator = editorCoordinator
        self.formattingState = formattingState
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            editor
        }
        .background(Color(.textBackgroundColor))
    }

    // MARK: - Editor

    private var editor: some View {
        var editorView = TesseraEditorView(
            mode: .code,
            theme: EditorTheme.current(isDark: colorScheme == .dark),
            document: documentBinding,
            onMutationCommitted: { _, _ in
                Task { await viewModel.commitBody(viewModel.document) }
            },
            onViewCommand: { command in
                handleEditorCommand(command)
            }
        )
        editorView.injectedCoordinator = editorCoordinator
        return editorView
    }

    private var documentBinding: Binding<DocumentAST> {
        Binding<DocumentAST>(
            get: { viewModel.document },
            set: { viewModel.setDocumentLocal($0) }
        )
    }

    // MARK: - Command handling

    private func handleEditorCommand(_ command: EditorCommand) {
        switch command {
        case .toggleLineNumbers:
            formattingState.wrappedValue.showLineNumbers.toggle()
            editorCoordinator.handleViewCommand(command)
        case .enterFocusMode:
            // Handled by host (CodeDetailView) via isFocusMode state.
            editorCoordinator.handleViewCommand(command)
        default:
            // Code mode has no other formatting commands; forward anyway.
            editorCoordinator.handleViewCommand(command)
        }
    }
}
