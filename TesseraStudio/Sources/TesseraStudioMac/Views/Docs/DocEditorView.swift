import SwiftUI
import AppKit
import TesseraCore

// MARK: - DocEditorView

/// The document editor surface. Wraps ``TesseraEditorView`` in
/// `.document` mode. The host (``DocDetailView``) owns the ribbon
/// toolbar and all shared state (coordinator, formattingState,
/// isFocusMode) and passes them in here.
///
/// **Why the ribbon lives in the host, not here.**
/// Pages/Word keep the ribbon in the window toolbar — it doesn't
/// scroll with the document. Nesting the ribbon inside the
/// scrollable content (as a plain VStack child) would make it
/// scroll away. The correct architecture: host owns ribbon state,
/// host places ribbon in `.toolbar`, host passes coordinator down.
public struct DocEditorView: View {

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject public var viewModel: DocEditorViewModel

    /// Injected from the host (``DocDetailView``) so the toolbar
    /// can share the same coordinator instance.
    public var editorCoordinator: TesseraEditorView.Coordinator

    /// Host passes these so this editor can toggle them without
    /// owning the state directly.
    public var formattingState: Binding<FormattingState>
    public var isFocusMode: Binding<Bool>

    /// Commands that DocEditorView doesn't handle go here.
    /// DocDetailView uses this to handle Phase 7+ commands (comments, find, etc.).
    public var onUnhandledCommand: ((EditorCommand) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        viewModel: DocEditorViewModel,
        editorCoordinator: TesseraEditorView.Coordinator,
        formattingState: Binding<FormattingState>,
        isFocusMode: Binding<Bool>,
        onUnhandledCommand: ((EditorCommand) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.editorCoordinator = editorCoordinator
        self.formattingState = formattingState
        self.isFocusMode = isFocusMode
        self.onUnhandledCommand = onUnhandledCommand
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            editor
            Divider()
            if isFocusMode.wrappedValue {
                focusStatusBar
                    .transition(.opacity)
            }
        }
        .background(.background)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isFocusMode.wrappedValue)
        .onKeyPress(.escape) {
            if isFocusMode.wrappedValue {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15)) {
                    isFocusMode.wrappedValue = false
                }
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Editor

    private var editor: some View {
        var editorView = TesseraEditorView(
            mode: .document,
            theme: EditorTheme.current(isDark: colorScheme == .dark),
            document: documentBinding,
            onMutationCommitted: { _, _ in
                let ast = viewModel.document
                Task { await viewModel.commitBody(ast) }
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

    // MARK: - Focus mode status bar

    private var focusStatusBar: some View {
        SurfaceFocusStatusBar(
            wordCount: viewModel.doc.wordCount,
            readingMinutes: viewModel.doc.readingTimeMinutes,
            onExit: {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15)) {
                    isFocusMode.wrappedValue = false
                }
            }
        )
    }

    // MARK: - Editor command handling

    private func handleEditorCommand(_ command: EditorCommand) {
        switch command {
        case .toggleLineNumbers:
            formattingState.wrappedValue.showLineNumbers.toggle()
            editorCoordinator.handleViewCommand(command)
        case .toggleRuler:
            formattingState.wrappedValue.showRuler.toggle()
            editorCoordinator.handleViewCommand(command)
        case .toggleGridlines:
            formattingState.wrappedValue.showGridlines.toggle()
            editorCoordinator.handleViewCommand(command)
        case .enterFocusMode:
            withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15)) {
                isFocusMode.wrappedValue = true
            }
            editorCoordinator.handleViewCommand(command)
        case .toggleBold:
            formattingState.wrappedValue.isBold.toggle()
            editorCoordinator.handleViewCommand(command)
        case .toggleItalic:
            formattingState.wrappedValue.isItalic.toggle()
            editorCoordinator.handleViewCommand(command)
        case .toggleUnderline:
            formattingState.wrappedValue.isUnderline.toggle()
            editorCoordinator.handleViewCommand(command)
        case .toggleStrikethrough:
            formattingState.wrappedValue.isStrikethrough.toggle()
            editorCoordinator.handleViewCommand(command)
        case .toggleCode:
            formattingState.wrappedValue.isCode.toggle()
            editorCoordinator.handleViewCommand(command)
        case .alignLeft:
            formattingState.wrappedValue.alignment = .leading
            editorCoordinator.handleViewCommand(command)
        case .alignCenter:
            formattingState.wrappedValue.alignment = .center
            editorCoordinator.handleViewCommand(command)
        case .alignRight:
            formattingState.wrappedValue.alignment = .trailing
            editorCoordinator.handleViewCommand(command)
        case .alignJustify:
            formattingState.wrappedValue.alignment = .justify
            editorCoordinator.handleViewCommand(command)
        case .increaseFontSize, .decreaseFontSize, .setFontSize,
             .toggleUnorderedList, .toggleOrderedList,
             .setBlockType, .setHeadingLevel,
             .indent, .outdent, .insertPageBreak, .insertColumnBreak,
             .pastePlainText,
             .sortAscending, .sortDescending,
             .insertTableCustom, .insertImageCustom, .insertLinkCustom,
             .insertHeader, .insertFooter,
             .setMargins, .setOrientation, .setColumns, .setPageColor,
             .showWordCount, .insertComment,
             .toggleTrackChanges, .toggleCommentsPanel,
             .acceptChange, .rejectChange, .spellCheck,
             .nextComment, .previousComment,
             .showFindReplace, .findNext, .findPrevious, .replaceNext, .replaceAll,
             .insertLink, .removeLink:
            // Phase 7+ commands: forward to host (DocDetailView) for full handling.
            onUnhandledCommand?(command)
        default:
            editorCoordinator.handleViewCommand(command)
        }
        let ast = viewModel.document
        Task { await viewModel.commitBody(ast) }
    }
}
