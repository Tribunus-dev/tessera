import SwiftUI
import TesseraCore

// MARK: - SheetEditorView

/// The sheet editor surface. The grid is the primary surface — no
/// ``TesseraEditorView`` is needed for the spreadsheet itself.
///
/// If the sheet carries a text body alongside the grid (some sheets
/// have both a grid and a markdown/structured body), a
/// ``TesseraEditorView`` is rendered for it below the grid.
/// Otherwise this view is minimal: it wraps ``SheetGridView`` only.
///
/// The host (``SheetDetailView``) owns the ribbon toolbar and all
/// shared state (coordinator, formattingState, isFocusMode) and
/// passes them in here.
public struct SheetEditorView: View {

    @ObservedObject public var viewModel: SheetEditorViewModel

    /// Injected from the host so the toolbar can share the same
    /// coordinator instance. Unused for the grid (sheets mode has no
    /// formatting), but kept for parity with DocEditorView.
    public var editorCoordinator: TesseraEditorView.Coordinator

    /// Host passes these so this editor can toggle them without
    /// owning the state directly.
    public var formattingState: Binding<FormattingState>

    /// Controls whether the grid's inline cell editor TextField
    /// has keyboard focus. `.focused()` requires a FocusState.Binding;
    /// we hold the `@FocusState` at the host so both the formula
    /// bar TextField and the grid's cell TextField share the same
    /// focus source.
    public var gridEditingFocused: FocusState<Bool>.Binding

    @State private var bodyDocument: DocumentAST = DocumentAST()

    /// True when the sheet has a non-empty text body in addition to
    /// the grid. We check the body blocks count — an empty body has
    /// zero blocks.
    private var hasTextBody: Bool {
        !viewModel.sheet.body.blocks.isEmpty
    }

    public init(
        viewModel: SheetEditorViewModel,
        editorCoordinator: TesseraEditorView.Coordinator,
        formattingState: Binding<FormattingState>,
        gridEditingFocused: FocusState<Bool>.Binding
    ) {
        self.viewModel = viewModel
        self.editorCoordinator = editorCoordinator
        self.formattingState = formattingState
        self.gridEditingFocused = gridEditingFocused
        self._bodyDocument = State(initialValue: viewModel.sheet.body)
    }

    public var body: some View {
        VStack(spacing: 0) {
            gridSection

            if hasTextBody {
                Divider()
                textBodySection
            }

            Divider()
            linkedSection
        }
    }

    // MARK: - Grid

    private var gridSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Grid").font(.headline)
                Spacer()
                if viewModel.sheet.rowCount > 0 {
                    Text("\(viewModel.sheet.rowCount) x \(viewModel.sheet.columnCount)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if viewModel.sheet.rowCount == 0 || viewModel.sheet.columnCount == 0 {
                emptyGridState
            } else {
                SheetGridView(viewModel: viewModel, gridEditingFocused: gridEditingFocused)
            }
        }
    }

    private var emptyGridState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tablecells.badge.ellipsis").font(.title2).foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            Text("No grid yet").font(.subheadline).foregroundStyle(.secondary)
            Button("Create 5 x 4 grid") {
                let blank = Sheet.makeBlank(title: viewModel.sheet.title, rows: 5, cols: 4)
                Task {
                    var updated = viewModel.sheet
                    updated.body = blank.body
                    updated.columns = blank.columns
                    updated.updatedAt = Date()
                    _ = try? await viewModel.store.upsert(updated)
                    if let fresh = try? await viewModel.store.get(id: updated.id) {
                        viewModel.refresh(with: fresh)
                    }
                }
            }
            .controlSize(.small)
            .accessibilityLabel("Create a 5 by 4 grid")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
    }

    // MARK: - Text body

    private var textBodySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes").font(.headline)
            TesseraEditorView(
                mode: .sheets,
                document: $bodyDocument,
                onMutationCommitted: nil,
                onViewCommand: nil,
                onFormattingStateChanged: nil
            )
            .frame(minHeight: 120)
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
}
