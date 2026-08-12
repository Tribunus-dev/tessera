import SwiftUI
import TesseraCore

// MARK: - CodeEditorPaneView

/// Deprecated: the code editor is now `CodeDetailView`. This stub
/// exists only to satisfy any remaining callers during migration.
@available(*, deprecated, message: "Use CodeDetailView instead")
public struct CodeEditorPaneView: View {

    @ObservedObject public var viewModel: CodeSurfaceViewModel

    public init(viewModel: CodeSurfaceViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        CodeDetailView(viewModel: viewModel)
    }
}

