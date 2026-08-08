import SwiftUI
import TesseraCore

// MARK: - DocEditorView

/// Wraps ``TesseraEditorView`` in `.document` mode for the Docs
/// surface. The host (``DocDetailView``) owns the `Doc` + the
/// `DocumentAST` binding; this view bridges the binding to the
/// editor and routes coalesced commits through
/// ``DocEditorViewModel/commitBody(_:)``.
///
/// Keep the toolbar minimal — the Doc surface's metadata row +
/// tag chips already carry most of the chrome.
public struct DocEditorView: View {

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject public var viewModel: DocEditorViewModel

    public init(viewModel: DocEditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        TesseraEditorView(
            mode: .document,
            theme: EditorTheme.current(isDark: colorScheme == .dark),
            document: documentBinding,
            onMutationCommitted: { _, _ in
                let ast = viewModel.document
                Task { await viewModel.commitBody(ast) }
            }
        )
    }

    private var documentBinding: Binding<DocumentAST> {
        Binding<DocumentAST>(
            get: { viewModel.document },
            set: { viewModel.setDocumentLocal($0) }
        )
    }
}
