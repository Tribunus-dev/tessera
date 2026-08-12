import SwiftUI
import AppKit
import TesseraCore

// MARK: - SlideDeckEditorView

/// The slide canvas + speaker-notes editor surface. The host
/// (``SlideDeckDetailView``) owns the ribbon toolbar and all shared
/// state (coordinator, formattingState, isFocusMode) and passes
/// them in here.
///
/// **What lives here vs. in the host.**
/// The host holds the window toolbar and the full-screen chrome.
/// This view holds the slide canvas, the per-slide text-formatting
/// mini toolbar, and the editable speaker-notes section.
///
/// **Speaker notes editor.** Each slide's `notes` string is wrapped
/// in a ``TesseraEditorView`` in `.notes` mode. Mutations are
/// debounced (2 s) and committed back to the slide store.
public struct SlideDeckEditorView: View {

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ObservedObject public var viewModel: SlideDeckEditorViewModel
    public var editorCoordinator: TesseraEditorView.Coordinator
    public var formattingState: Binding<FormattingState>
    public var isFocusMode: Binding<Bool>
    public var selectedSlideIndex: Binding<Int>
    public let onInsertSlide: (SlideLayout) -> Void
    public let onDeleteSlide: (Int) -> Void

    /// Per-slide notes editor state. Initialized from the selected slide.
    @State private var notesDocument: DocumentAST = {
        var ast = DocumentAST()
        let id = UUID()
        ast.blocks[id] = Block(id: id, type: .paragraph, content: [])
        ast.rootChildren = [id]
        return ast
    }()

    public init(
        viewModel: SlideDeckEditorViewModel,
        editorCoordinator: TesseraEditorView.Coordinator,
        formattingState: Binding<FormattingState>,
        isFocusMode: Binding<Bool>,
        selectedSlideIndex: Binding<Int>,
        onInsertSlide: @escaping (SlideLayout) -> Void,
        onDeleteSlide: @escaping (Int) -> Void
    ) {
        self.viewModel = viewModel
        self.editorCoordinator = editorCoordinator
        self.formattingState = formattingState
        self.isFocusMode = isFocusMode
        self.selectedSlideIndex = selectedSlideIndex
        self.onInsertSlide = onInsertSlide
        self.onDeleteSlide = onDeleteSlide
    }

    public var body: some View {
        VStack(spacing: 0) {
            slidesToolbar
            canvasSection
            notesSection
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
        .onChange(of: selectedSlideIndex.wrappedValue) { _, newIndex in
            // Re-initialize the notes editor when the selected slide changes.
            rebuildNotesDocument(for: newIndex)
        }
    }

    // MARK: - Slides formatting toolbar

    /// A compact version of the ribbon, showing only text-formatting controls.
    /// Mirrors the mini toolbar that PowerPoint shows on text selection.
    private var slidesToolbar: some View {
        HStack(spacing: 8) {
            // Font family picker
            Menu {
                Button("System") { }
                Button("Helvetica Neue") { }
                Button("Georgia") { }
                Button("Courier") { }
            } label: {
                Label("Font", systemImage: "textformat")
                    .font(.system(size: 11))
            }
            .controlSize(.small)

            Divider().frame(height: 16)

            // Bold / Italic / Underline
            MiniToggleButton(label: "B", weight: .bold) {
                formattingState.wrappedValue.isBold.toggle()
                editorCoordinator.handleViewCommand(.toggleBold)
            }
            MiniToggleButton(label: "I", italic: true) {
                formattingState.wrappedValue.isItalic.toggle()
                editorCoordinator.handleViewCommand(.toggleItalic)
            }
            MiniToggleButton(label: "U", underline: true) {
                formattingState.wrappedValue.isUnderline.toggle()
                editorCoordinator.handleViewCommand(.toggleUnderline)
            }

            Divider().frame(height: 16)

            // Font size stepper
            Stepper("18 pt", value: .constant(18), in: 8...144)
                .labelsHidden()
                .controlSize(.small)

            Divider().frame(height: 16)

            // Alignment
            MiniToggleButton(icon: "text.alignleft") {
                formattingState.wrappedValue.alignment = .leading
                editorCoordinator.handleViewCommand(.alignLeft)
            }
            MiniToggleButton(icon: "text.aligncenter") {
                formattingState.wrappedValue.alignment = .center
                editorCoordinator.handleViewCommand(.alignCenter)
            }
            MiniToggleButton(icon: "text.alignright") {
                formattingState.wrappedValue.alignment = .trailing
                editorCoordinator.handleViewCommand(.alignRight)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separatorColor)).frame(height: 1)
        }
    }

    // MARK: - Canvas

    @ViewBuilder
    private var canvasSection: some View {
        if let slide = viewModel.slide(at: selectedSlideIndex.wrappedValue) {
            SlideCanvasView(slide: slide, isSelected: true)
                .frame(height: 220)
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 8) {
                        Text(slide.layout.displayName)
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(.quaternary))
                        Menu {
                            ForEach(SlideLayout.allCases, id: \.self) { layout in
                                Button(layout.displayName) {
                                    Task { await viewModel.setLayout(layout, at: selectedSlideIndex.wrappedValue) }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.caption)
                                .symbolRenderingMode(.hierarchical)
                        }
                        .menuStyle(.borderlessButton)
                    }
                    .padding(8)
                }
            HStack(spacing: 8) {
                Button {
                    selectedSlideIndex.wrappedValue = max(0, selectedSlideIndex.wrappedValue - 1)
                } label: {
                    Label("Prev", systemImage: "chevron.left")
                }
                .disabled(selectedSlideIndex.wrappedValue == 0)
                Spacer()
                Text("Slide \(selectedSlideIndex.wrappedValue + 1) of \(viewModel.deck.slideCount)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    selectedSlideIndex.wrappedValue = min(viewModel.deck.slideCount - 1, selectedSlideIndex.wrappedValue + 1)
                } label: {
                    Label("Next", systemImage: "chevron.right")
                }
                .disabled(selectedSlideIndex.wrappedValue >= viewModel.deck.slideCount - 1)
            }
            .controlSize(.small)
        } else {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                .frame(height: 160)
                .overlay { Text("No slide selected").foregroundStyle(.secondary) }
        }
    }

    // MARK: - Speaker notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Speaker notes").font(.headline)
                Spacer()
                if let slide = viewModel.slide(at: selectedSlideIndex.wrappedValue), !slide.notes.isEmpty {
                    Text("\(slide.notes.count) chars").font(.caption).foregroundStyle(.secondary)
                }
            }
            notesEditor
                .frame(minHeight: 80)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        }
    }

    /// The TesseraEditorView for speaker notes, with coordinator pre-injected.
    private var notesEditor: some View {
        var editor = TesseraEditorView(
            mode: .notes,
            theme: EditorTheme.current(isDark: colorScheme == .dark),
            document: notesDocumentBinding,
            onMutationCommitted: { _, _ in
                commitNotesFromDocument()
            },
            onViewCommand: { command in
                editorCoordinator.handleViewCommand(command)
            },
            onFormattingStateChanged: { newState in
                formattingState.wrappedValue = newState
            }
        )
        editor.injectedCoordinator = editorCoordinator
        return editor
    }

    // MARK: - Focus mode status bar

    private var focusStatusBar: some View {
        SurfaceFocusStatusBar(
            wordCount: viewModel.deck.wordCount,
            readingMinutes: viewModel.deck.wordCount / 200,
            onExit: {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15)) {
                    isFocusMode.wrappedValue = false
                }
            }
        )
    }

    // MARK: - Helpers

    /// Binding that bridges the TesseraEditorView's DocumentAST to the notes state.
    private var notesDocumentBinding: Binding<DocumentAST> {
        Binding(
            get: { notesDocument },
            set: { notesDocument = $0 }
        )
    }

    /// Rebuild the notesDocument AST from the slide at the given index.
    private func rebuildNotesDocument(for slideIndex: Int) {
        let notes = viewModel.slide(at: slideIndex)?.notes ?? ""
        var ast = DocumentAST()
        let id = UUID()
        ast.blocks[id] = Block(id: id, type: .paragraph, content: [InlineRun(text: notes)])
        ast.rootChildren = [id]
        notesDocument = ast
    }

    /// Extract text from notesDocument and commit it as the slide's notes.
    private func commitNotesFromDocument() {
        guard let rootID = notesDocument.rootChildren.first,
              let block = notesDocument.blocks[rootID] else { return }
        let text = block.content.map(\.text).joined()
        Task {
            await viewModel.commitSlideNotes(text, at: selectedSlideIndex.wrappedValue)
        }
    }
}

// MARK: - MiniToggleButton

/// Compact toggle button for the slides mini toolbar.
private struct MiniToggleButton: View {
    var label: String? = nil
    var weight: Font.Weight = .regular
    var italic: Bool = false
    var underline: Bool = false
    var icon: String? = nil
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let icon {
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 12))
            } else if let label {
                Text(label)
                    .font(.system(size: 11, weight: weight))
                    .italic(italic)
                    .underline(underline)
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: 24, minHeight: 22)
        .padding(.horizontal, 4)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(3)
    }
}
