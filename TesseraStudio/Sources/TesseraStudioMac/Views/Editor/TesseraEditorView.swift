import SwiftUI
import AppKit
import STTextView
import TesseraCore

// MARK: - TesseraEditorView

/// The SwiftUI view that hosts the platform-native text view
/// (STTextView on macOS, UITextView on iOS) and wires it to
/// the `TesseraTextContentManager` from Phase 2's editor layer.
///
/// **Architecture.** The view is a `NSViewRepresentable` that:
///   1. Owns a `TesseraTextContentManager` (the AST-backed
///      `NSTextContentManager`).
///   2. Owns a `TesseraSTTextView` (STTextView subclass) whose
///      `textContentManager` is set to a `TesseraTextContentStorage`
///      wrapping (1). The storage bridge is required because
///      STTextView's internal code calls
///      `(textContentManager as? NSTextContentStorage)?.textStorage`
///      to access the mutable attributed string — a raw
///      `NSTextContentManager` (no `textStorage` property) can't
///      satisfy that call site.
///   3. Listens to the text view's `NSText.didChangeNotification`
///      and converts the post-edit attributed string back into a
///      `Mutation` via `TextEditReducer`.
///   4. Hands the `Mutation` to the `EditorCoalescer`, which
///      aggregates a burst of edits into a single `Mutation` +
///      `ChatQueueItem` and posts a `didFlushNotification`.
///
/// **STTextView swap.** The `makeNSView` returns a
/// `TesseraSTTextView` (STTextView subclass) with our custom
/// `TesseraTextContentStorage` injected. STTextView brings: a
/// built-in gutter, line numbers, cleaner TextKit 2 internals,
/// and better IME/input method support. The swap is not drop-in
/// (STTextView's `init(frame:)` hardcodes `STTextContentStorage`,
/// so we override it to inject ours before `super.init()` fires).
public struct TesseraEditorView: NSViewRepresentable {

    public let mode: EditorMode
    public let theme: EditorTheme
    @Binding public var document: DocumentAST
    public let onMutationCommitted: (([Mutation], ChatQueueItem) -> Void)?
    /// Called for view-level commands (gutter, focus, etc.) that
    /// don't touch the document but need to be routed to the toolbar.
    public let onViewCommand: ((EditorCommand) -> Void)?
    /// Called when the text selection changes so the host can update
    /// FormattingState and highlight the correct toolbar buttons.
    public let onFormattingStateChanged: ((FormattingState) -> Void)?

    public init(
        mode: EditorMode = .document,
        theme: EditorTheme = .light,
        document: Binding<DocumentAST>,
        onMutationCommitted: (([Mutation], ChatQueueItem) -> Void)? = nil,
        onViewCommand: ((EditorCommand) -> Void)? = nil,
        onFormattingStateChanged: ((FormattingState) -> Void)? = nil
    ) {
        self.mode = mode
        self.theme = theme
        self._document = document
        self.onMutationCommitted = onMutationCommitted
        self.onViewCommand = onViewCommand
        self.onFormattingStateChanged = onFormattingStateChanged
    }

    /// Allows a host (e.g. NoteEditorColumn) to pre-create the coordinator
    /// and inject it so the toolbar can route view-level commands to it.
    public var injectedCoordinator: Coordinator?

    public func makeCoordinator() -> Coordinator {
        // If the host pre-created the coordinator, use it so the
        // toolbar can call handleViewCommand via the stored reference.
        if let injected = injectedCoordinator {
            return injected
        }
        return Coordinator(
            mode: mode,
            theme: theme,
            onMutationCommitted: onMutationCommitted,
            onViewCommand: onViewCommand,
            onFormattingStateChanged: onFormattingStateChanged
        )
    }

    public func makeNSView(context: Context) -> NSView {
        let container = NSScrollView()
        container.hasVerticalScroller = true
        container.hasHorizontalScroller = false
        container.borderType = .noBorder
        container.autohidesScrollers = true

        // Build the storage + manager chain:
        //   TesseraTextContentManagerData (document + element list)
        //     -> TesseraTextContentStorage (NSTextContentStorage subclass, satisfies STTextView)
        //       -> TesseraTextContentManager (NSTextContentManager, implements delegate callbacks)
        //         -> TesseraSTTextView (STTextView subclass, the platform text view)
        let contentManager = TesseraTextContentManager(document: document, mode: mode)
        let storage = TesseraTextContentStorage(data: contentManager.data)
        storage.tesseraDelegate = contentManager

        let textView = TesseraSTTextView(
            contentStorage: storage,
            initialAttributedString: contentManager.data.fullAttributedString()
        )
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFontPanel = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // textContainerInset: NSTextView API not present on STTextView.
        // Padding is managed through the text container's layout manager.
        // STTextView.isRichText, isFieldEditor, importsGraphics are all `let`s.

        context.coordinator.contentManager = contentManager
        context.coordinator.textView = textView
        context.coordinator.binding = $document
        context.coordinator.startObservingCoalescerFlush()
        context.coordinator.startObservingSelection()

        // Double-click handler: open table editor when user double-clicks a table block.
        // We do this via mouseDown override in TesseraSTTextView instead of doubleAction
        // (STTextView doesn't expose doubleAction/target on NSButton). The coordinator
        // sets the table click handler on the text view.
        let coordinator = context.coordinator
        textView.onTableBlockDoubleClicked = { blockID in
            coordinator.openTableEditor(for: blockID)
        }

        // Wire find bar callbacks (Phase 8).
        if coordinator.findCoordinator == nil {
            coordinator.findCoordinator = FindReplaceCoordinator()
        }
        if let fc = coordinator.findCoordinator {
            textView.onFindBarRequested = { [weak fc] in fc?.showBar() }
            textView.onFindNextRequested = { [weak fc] in fc?.findNext() }
            textView.onFindPreviousRequested = { [weak fc] in fc?.findPrevious() }
            textView.onFindBarDismissed = { [weak fc] in fc?.hideBar() }
            textView.onFindResultsChanged = { [weak fc] count, current in
                fc?.matchCount = count; fc?.currentMatch = current
            }
            fc.textView = textView
        }

        // Wire focus mode exit (Phase 9).
        textView.isFocusModeActive = false  // Set by host via updateNSView.
        textView.onExitFocusModeRequested = { [weak coordinator] in
            coordinator?.onViewCommand?(.enterFocusMode)
        }

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )

        container.documentView = textView
        return container
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let contentManager = context.coordinator.contentManager else { return }

        // Phase 10 P0: Skip re-sync if the binding update was triggered by our own
        // coalescer flush. The flush already mutated contentManager.data and did a
        // targeted replace — the text view is already in sync. Comparing rootChildren
        // handles external changes (chat panel, undo, etc.); the flush counter
        // handles the flush-triggered case where rootChildren also happens to differ.
        let fromOurFlush = context.coordinator.lastFlushCount > 0
        let documentsMatch = contentManager.data.document.rootChildren == document.rootChildren

        if fromOurFlush && documentsMatch {
            // Our flush updated contentManager.data; the binding update is redundant
            // from the text view's perspective. Skip the full replaceContent call
            // and the SwiftUI layout diffing it triggers.
            return
        }

        contentManager.data.setDocument(document)
        if let textView = (nsView as? NSScrollView)?.documentView as? TesseraSTTextView {
            textView.replaceContent(with: contentManager.data.fullAttributedString())
            // Sync focus mode state from host.
            // Note: isFocusMode is managed by the host (DocDetailView); we just reflect it here.
        }
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopObservingCoalescerFlush()
        coordinator.stopObservingSelection()
        NotificationCenter.default.removeObserver(coordinator)
    }

    // MARK: - Coordinator

    public final class Coordinator: NSObject {
        public var contentManager: TesseraTextContentManager?
        public weak var textView: STTextView?
        public var binding: Binding<DocumentAST>?
        public let mode: EditorMode
        public let theme: EditorTheme
        public let coalescer: EditorCoalescer
        public let reducer: TextEditReducer
        public var lastAttributedString: NSAttributedString?
        /// Find/replace coordinator — created lazily if nil, so the host can
        /// also pre-create and inject it to share state with a FindReplaceBar.
        public var findCoordinator: FindReplaceCoordinator?
        private var flushObserver: NSObjectProtocol?
        private var selectionObserver: NSObjectProtocol?
        /// Monotonically increasing counter incremented each time the coalescer
        /// flushes. updateNSView reads it to know whether the SwiftUI binding
        /// update was triggered by a flush (skip re-sync) vs. an external change
        /// (do the full sync). Written on the main thread only.
        fileprivate var lastFlushCount: Int = 0

        private let onMutationCommitted: (([Mutation], ChatQueueItem) -> Void)?
        public let onViewCommand: ((EditorCommand) -> Void)?
        /// Called when the text selection changes so the host can update
        /// FormattingState and highlight the correct toolbar buttons.
        public var onFormattingStateChanged: ((FormattingState) -> Void)?

        public init(
            mode: EditorMode,
            theme: EditorTheme,
            onMutationCommitted: (([Mutation], ChatQueueItem) -> Void)?,
            onViewCommand: ((EditorCommand) -> Void)?,
            onFormattingStateChanged: ((FormattingState) -> Void)?
        ) {
            self.mode = mode
            self.theme = theme
            self.coalescer = EditorCoalescer()
            self.reducer = TextEditReducer()
            self.onMutationCommitted = onMutationCommitted
            self.onViewCommand = onViewCommand
            self.onFormattingStateChanged = onFormattingStateChanged
        }

        deinit {
            stopObservingCoalescerFlush()
            stopObservingSelection()
        }

        public func startObservingCoalescerFlush() {
            flushObserver = NotificationCenter.default.addObserver(
                forName: EditorCoalescer.didFlushNotification,
                object: coalescer,
                queue: .main
            ) { [weak self] note in
                guard let self, let burst = note.userInfo?["burst"] as? EditorCoalescer.CoalescedBurst else {
                    return
                }
                self.handleFlushedBurst(burst)
            }
        }

        public func stopObservingCoalescerFlush() {
            if let flushObserver {
                NotificationCenter.default.removeObserver(flushObserver)
                self.flushObserver = nil
            }
        }

        public func startObservingSelection() {
            selectionObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self,
                      let tv = note.object as? TesseraSTTextView,
                      tv === self.textView else { return }
                self.handleSelectionChange()
            }
        }

        public func stopObservingSelection() {
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
                self.selectionObserver = nil
            }
        }

        private func handleSelectionChange() {
            guard let tv = textView as? TesseraSTTextView,
                  let contentManager = tv.textContentManager as? TesseraTextContentManager else { return }
            let range = tv.selectedRange()
            var state = FormattingState()
            let checkRange = range.length > 0 ? range : NSRange(location: max(0, range.location - 1), length: 1)
            let textStorage = (tv.textContentManager as? NSTextContentStorage)?.textStorage
            let attrs = textStorage?.attributes(at: max(0, checkRange.location), effectiveRange: nil) ?? [:]
            let typingAttrs = tv.typingAttributes
            let merged = attrs.isEmpty ? typingAttrs : attrs

            if let font = (attrs.isEmpty ? typingAttrs[.font] : attrs[.font]) as? NSFont {
                let desc = font.fontDescriptor
                state.isBold = desc.symbolicTraits.contains(.bold)
                state.isItalic = desc.symbolicTraits.contains(.italic)
            }
            state.isUnderline = (merged[.underlineStyle] as? Int) != nil
            state.isStrikethrough = (merged[.strikethroughStyle] as? Int) != nil
            if let font = merged[.font] as? NSFont {
                state.isCode = font == NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
            }
            // Paragraph alignment
            if let ps = merged[.paragraphStyle] as? NSParagraphStyle {
                switch ps.alignment {
                case .left:   state.alignment = .leading
                case .center: state.alignment = .center
                case .right:  state.alignment = .trailing
                case .justified: state.alignment = .justify
                default: state.alignment = .leading
                }
            }

            // Detect block type and heading level from the block at cursor.
            let loc = IntTextLocation(intValue: max(0, checkRange.location))
            if let element = contentManager.textElement(at: loc),
               let block = contentManager.data.document.blocks[element.blockID] {
                state.blockType = block.type
                if block.type == .heading {
                    state.headingLevel = block.attributes["level"]?.intValue
                } else if block.type == .listItem, let parentID = block.parentID {
                    state.blockType = .listItem
                }
            }

            onFormattingStateChanged?(state)
        }

        // MARK: - View-level commands

        /// Handles view-level commands that affect the text view's display
        /// (gutter, ruler, gridlines, focus mode, formatting, etc.) without
        /// touching the document AST. Called from the main thread.
        public func handleViewCommand(_ command: EditorCommand) {
            guard let textView = textView as? TesseraSTTextView else { return }
            let range = textView.selectedRange()
            switch command {
            // View toggles — all @MainActor on STTextView
            case .toggleLineNumbers:
                MainActor.assumeIsolated { textView.gutterLineNumbers.toggle() }
            case .toggleRuler:
                MainActor.assumeIsolated { textView.gutterRuler.toggle() }
            case .toggleGridlines:
                MainActor.assumeIsolated { textView.gutterGridlines.toggle() }
            case .enterFocusMode:
                // Handled by host via isFocusMode binding.
                break
            // Text formatting — applies to selection or typing attributes
            case .toggleBold:
                MainActor.assumeIsolated { textView.applyFormat(.bold, to: range) }
            case .toggleItalic:
                MainActor.assumeIsolated { textView.applyFormat(.italic, to: range) }
            case .toggleUnderline:
                MainActor.assumeIsolated { textView.applyFormat(.underline, to: range) }
            case .toggleStrikethrough:
                MainActor.assumeIsolated { textView.applyFormat(.strikethrough, to: range) }
            case .toggleCode:
                MainActor.assumeIsolated { textView.applyFormat(.code, to: range) }
            // Font size
            case .increaseFontSize:
                MainActor.assumeIsolated { textView.applyFontSizeChange(delta: 1, to: range) }
            case .decreaseFontSize:
                MainActor.assumeIsolated { textView.applyFontSizeChange(delta: -1, to: range) }
            case .setFontSize(let size):
                MainActor.assumeIsolated { textView.setFontSize(CGFloat(size), to: range) }
            // Alignment
            case .alignLeft:
                MainActor.assumeIsolated { textView.setParagraphAlignment(.left) }
            case .alignCenter:
                MainActor.assumeIsolated { textView.setParagraphAlignment(.center) }
            case .alignRight:
                MainActor.assumeIsolated { textView.setParagraphAlignment(.right) }
            case .alignJustify:
                MainActor.assumeIsolated { textView.setParagraphAlignment(.justified) }
            // Indent / outdent
            case .indent:
                // macOS standard: increase paragraph indent by 36pt
                MainActor.assumeIsolated {
                    let m = textView.typingAttributes
                    let cur = (m[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
                    let storage = (textView.textContentManager as? NSTextContentStorage)?.textStorage
                    if let ps = storage?.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSMutableParagraphStyle {
                        ps.firstLineHeadIndent = cur + 36
                        ps.headIndent = cur + 36
                        storage?.addAttribute(.paragraphStyle, value: ps, range: range)
                    }
                }
            case .outdent:
                MainActor.assumeIsolated {
                    let storage = (textView.textContentManager as? NSTextContentStorage)?.textStorage
                    if let ps = (storage?.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSMutableParagraphStyle) {
                        ps.firstLineHeadIndent = max(0, ps.firstLineHeadIndent - 36)
                        ps.headIndent = max(0, ps.headIndent - 36)
                        storage?.addAttribute(.paragraphStyle, value: ps, range: range)
                    }
                }
            // Breaks
            case .insertPageBreak:
                MainActor.assumeIsolated {
                    textView.insertText("\u{0C}", replacementRange: range)
                }
            case .insertColumnBreak:
                MainActor.assumeIsolated {
                    textView.insertText("\u{0D}", replacementRange: range)
                }
            // Lists
            case .toggleUnorderedList:
                MainActor.assumeIsolated { textView.toggleUnorderedList() }
            case .toggleOrderedList:
                MainActor.assumeIsolated { textView.toggleOrderedList() }
            // Block type / heading level
            case .setBlockType(let blockType):
                MainActor.assumeIsolated { textView.applyBlockTypeChange(blockType) }
            case .setHeadingLevel(let level):
                MainActor.assumeIsolated { textView.applyBlockTypeChange(.heading, level: level) }
            // Table insertion / editing
            case .insertTable, .insertTableCustom:
                MainActor.assumeIsolated { textView.insertTable(rows: 3, cols: 3) }
            // Image insertion
            case .insertImage, .insertImageCustom:
                MainActor.assumeIsolated { textView.promptAndInsertImage() }
            // Link insertion
            case .insertLinkCustom:
                showLinkInsertionDialog()
            case .insertLink(let url):
                MainActor.assumeIsolated {
                    textView.insertLink(url: url, range: range)
                }
            case .removeLink:
                MainActor.assumeIsolated { textView.removeLink(range: range) }
            // Page layout — mutates DocumentAST.meta.pageLayout
            case .setMargins(let preset):
                applyPageMarginPreset(preset)
            case .setOrientation(let orientation):
                applyPageOrientation(orientation)
            case .setColumns(let count):
                applyColumnCount(count)
            case .setPageColor(let hex):
                applyPageColor(hex)
            // Comments & track changes (Phase 7)
            case .insertComment:
                MainActor.assumeIsolated { textView.insertCommentBlock(text: "") }
            case .toggleTrackChanges, .toggleCommentsPanel, .acceptChange, .rejectChange, .spellCheck, .nextComment, .previousComment:
                // Phase 7/8/9 commands are forwarded to the host for state management.
                onViewCommand?(command)
            // Find / Replace (Phase 8)
            case .showFindReplace, .findNext, .findPrevious, .replaceNext, .replaceAll:
                onViewCommand?(command)
            default:
                break
            }
            // Forward to host so it can update FormattingState.
            onViewCommand?(command)
        }

        /// Show a link insertion dialog and insert a link.
        private func showLinkInsertionDialog() {
            MainActor.assumeIsolated {
                guard let textView = textView as? TesseraSTTextView else { return }
                let alert = NSAlert()
                alert.messageText = "Insert Link"
                alert.informativeText = "Enter the URL:"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Insert")
                alert.addButton(withTitle: "Cancel")

                let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
                input.placeholderString = "https://example.com"
                alert.accessoryView = input

                if alert.runModal() == .alertFirstButtonReturn {
                    let urlString = input.stringValue
                    if let url = URL(string: urlString) {
                        textView.insertLink(url: url, range: textView.selectedRange())
                    }
                }
            }
        }

        // MARK: - Page layout helpers

        /// Apply a margin preset to the document.
        private func applyPageMarginPreset(_ preset: MarginPreset) {
            guard let binding = binding else { return }
            var doc = binding.wrappedValue
            var m = doc.pageLayout
            switch preset {
            case .narrow:
                m.marginTop = 36; m.marginBottom = 36; m.marginLeft = 36; m.marginRight = 36
            case .normal:
                m.marginTop = 72; m.marginBottom = 72; m.marginLeft = 72; m.marginRight = 72
            case .wide:
                m.marginTop = 72; m.marginBottom = 72; m.marginLeft = 108; m.marginRight = 108
            case .veryWide:
                m.marginTop = 72; m.marginBottom = 72; m.marginLeft = 144; m.marginRight = 144
            }
            doc.meta.pageLayout = m
            binding.wrappedValue = doc
        }

        /// Apply page orientation (swaps width/height for landscape).
        private func applyPageOrientation(_ orientation: Orientation) {
            guard let binding = binding else { return }
            var doc = binding.wrappedValue
            var layout = doc.pageLayout
            switch orientation {
            case .portrait:
                layout.pageWidth = 595
                layout.pageHeight = 842
            case .landscape:
                layout.pageWidth = 842
                layout.pageHeight = 595
            }
            doc.meta.pageLayout = layout
            binding.wrappedValue = doc
        }

        /// Set the number of text columns.
        private func applyColumnCount(_ count: Int) {
            guard let binding = binding else { return }
            var doc = binding.wrappedValue
            doc.meta.pageLayout.columnCount = max(1, min(6, count))
            binding.wrappedValue = doc
        }

        /// Set the page background color.
        private func applyPageColor(_ hex: String) {
            guard let binding = binding else { return }
            var doc = binding.wrappedValue
            doc.meta.pageLayout.pageColor = hex
            binding.wrappedValue = doc
        }

        /// Open the table editor overlay for the given table block ID.
        public func openTableEditor(for tableBlockID: UUID) {
            MainActor.assumeIsolated {
                (textView as? TesseraSTTextView)?.showTableEditor(for: tableBlockID)
            }
        }

        /// Select a block by its UUID (used for comment navigation).
        public func selectBlock(id: UUID) {
            MainActor.assumeIsolated {
                guard let tv = textView as? TesseraSTTextView,
                      let contentManager = tv.textContentManager as? TesseraTextContentManager else { return }
                // Find the element for the target block.
                if let element = contentManager.data.elements.first(where: { $0.blockID == id }) {
                    let nsRange = NSRange(location: element.rangeStart, length: element.rangeEnd - element.rangeStart)
                    // setSelectedRange is internal on NSTextView; use performSelector.
                    tv.perform(Selector(("setSelectedRange:")), with: nsRange)
                    tv.scrollRangeToVisible(nsRange)
                }
            }
        }

        /// Update focus mode state on the text view (Phase 9: Enter exits focus mode).
        public func updateFocusMode(_ active: Bool) {
            MainActor.assumeIsolated {
                (textView as? TesseraSTTextView)?.isFocusModeActive = active
            }
        }

        /// Accept a tracked change by its block ID.
        /// Insertions are kept, deletions are removed.
        public func acceptChange(id: UUID) {
            guard let binding = binding else { return }
            var doc = binding.wrappedValue
            guard let block = doc.blocks[id] else { return }
            if block.type == .trackDeletion {
                // Accepting a deletion = delete the text. Remove the block.
                var engine = MutationEngine()
                do {
                    _ = try engine.apply(.deleteBlock(blockID: id), to: &doc)
                    binding.wrappedValue = doc
                } catch { NSLog("acceptChange: \(error)") }
            } else if block.type == .trackInsertion {
                // Accepting an insertion = convert to normal text. Strip track metadata.
                var newBlock = block
                newBlock.type = .paragraph
                newBlock.attributes = newBlock.attributes.filter { key, _ in
                    !["author", "timestamp", "anchorBlockID"].contains(key)
                }
                var engine = MutationEngine()
                do {
                    _ = try engine.apply(.replaceBlock(blockID: id, block: newBlock), to: &doc)
                    binding.wrappedValue = doc
                } catch { NSLog("acceptChange: \(error)") }
            }
        }

        /// Reject a tracked change by its block ID.
        /// Insertions are removed, deletions are restored.
        public func rejectChange(id: UUID) {
            guard let binding = binding else { return }
            var doc = binding.wrappedValue
            guard let block = doc.blocks[id] else { return }
            if block.type == .trackInsertion {
                // Rejecting an insertion = remove it.
                var engine = MutationEngine()
                do {
                    _ = try engine.apply(.deleteBlock(blockID: id), to: &doc)
                    binding.wrappedValue = doc
                } catch { NSLog("rejectChange: \(error)") }
            } else if block.type == .trackDeletion {
                // Rejecting a deletion = restore the text (convert back to normal text).
                var newBlock = block
                newBlock.type = .paragraph
                newBlock.attributes = newBlock.attributes.filter { key, _ in
                    !["author", "timestamp", "anchorBlockID"].contains(key)
                }
                var engine = MutationEngine()
                do {
                    _ = try engine.apply(.replaceBlock(blockID: id, block: newBlock), to: &doc)
                    binding.wrappedValue = doc
                } catch { NSLog("rejectChange: \(error)") }
            }
        }

        private func handleFlushedBurst(_ burst: EditorCoalescer.CoalescedBurst) {
            guard let binding = binding,
                  let contentManager = contentManager else { return }
            var working = binding.wrappedValue
            var engine = MutationEngine()
            do {
                for mutation in burst.mutations {
                    _ = try engine.apply(mutation, to: &working)
                }

                // Phase 10 P0: targeted replace.
                // Structural mutations (insert/delete/move) change element offsets —
                // fall back to full SwiftUI sync. Content-only mutations keep the
                // same element offsets — do a targeted batch replace so TextKit 2
                // keeps all cached NSTextLayoutFragment objects for unchanged blocks.
                let structural = contentManager.data.isStructuralChange(burst.mutations)
                if structural {
                    // Structural: full sync via binding update.
                    lastFlushCount += 1
                    binding.wrappedValue = working
                    onMutationCommitted?(burst.mutations, burst.queueItem)
                    return
                }

                let affected = contentManager.data.affectedBlocks(from: burst.mutations)
                guard !affected.isEmpty,
                      let storage = contentManager as? TesseraTextContentStorage else {
                    lastFlushCount += 1
                    binding.wrappedValue = working
                    onMutationCommitted?(burst.mutations, burst.queueItem)
                    return
                }

                // Get ranges from the CURRENT element list (pre-mutation).
                // applyMutations rebuilds the element list; the old ranges are still
                // valid for the replaced block's character range.
                let oldRanges = storage.rangesForBlocks(affected)

                // Apply mutations to the data layer.
                _ = try contentManager.data.applyMutations(burst.mutations)

                // Re-render only the affected blocks.
                let newDoc = contentManager.data.document
                let renderer = contentManager.data.renderer
                let mode = contentManager.data.mode
                var replacements: [(NSRange, NSAttributedString)] = []
                for (blockID, oldRange) in oldRanges {
                    guard let block = newDoc.blocks[blockID] else { continue }
                    let rendered = renderer.render(block, in: mode)
                    replacements.append((oldRange, rendered))
                }

                if !replacements.isEmpty {
                    storage.batchReplace(replacements)
                    // Invalidate layout so TextKit 2 re-lays out the changed blocks.
                    // Using the full document range (same pattern as existing
                    // rebuildTextStorage) is safe and avoids the complexity of
                    // targeted invalidation with TextKit 2's NSTextRange API.
                    if let tv = textView {
                        tv.textLayoutManager.invalidateLayout(for: tv.textLayoutManager.documentRange)
                    }
                }

                // Sync the binding so other views see the change. The flush counter
                // lets updateNSView skip the redundant re-sync.
                lastFlushCount += 1
                binding.wrappedValue = working
                onMutationCommitted?(burst.mutations, burst.queueItem)
            } catch {
                NSLog("TesseraEditorView: failed to apply flushed burst: \(error)")
            }
        }

        @objc public func textDidChange(_ note: Notification) {
            guard let textView = textView,
                  let contentManager = contentManager else { return }
            // STTextView's textContentManager is a TesseraTextContentStorage
            // (NSTextContentStorage subclass), so the cast succeeds.
            let current = (textView.textContentManager as? NSTextContentStorage)?.attributedString
                ?? NSAttributedString()
            if let last = lastAttributedString {
                if last.string == current.string && last.length == current.length {
                    return
                }
                let blockID = findActiveBlockID(in: current)
                let before = runs(from: last)
                let after = runs(from: current)
                let mutations = reducer.reduce(
                    blockID: blockID,
                    before: before,
                    after: after
                )
                for mutation in mutations {
                    coalescer.append(
                        mutation: mutation,
                        blockID: blockID,
                        documentID: contentManager.data.document.rootChildren.first ?? UUID(),
                        queueMessage: "You edited a block"
                    )
                }
            }
            lastAttributedString = current
        }

        private func findActiveBlockID(in attributed: NSAttributedString) -> UUID {
            guard let textView = textView,
                  let contentManager = contentManager else { return UUID() }
            let selectedRange = textView.selectedRange()
            if let element = contentManager.textElement(at: IntTextLocation(intValue: selectedRange.location)) {
                return element.blockID
            }
            return contentManager.data.elements.first?.blockID ?? UUID()
        }

        private func runs(from attributed: NSAttributedString) -> [InlineRun] {
            if attributed.length == 0 { return [] }
            return [InlineRun(text: attributed.string)]
        }
    }
}

// MARK: - TesseraSTTextView

/// An `STTextView` subclass that owns a `TesseraTextContentStorage`
/// (our `NSTextContentStorage` subclass) and wires it into STTextView's
/// TextKit 2 stack.
///
/// **Why subclass STTextView.** STTextView's `init(frame:)` hardcodes
/// `textContentManager = STTextContentStorage()` before calling
/// `super.init(frame:)`. Since `textContentManager` is `open dynamic`
/// on `NSView`, we CAN override the assignment before `super.init()`,
/// but only by providing our own `init(frame:)` that does the override.
///
/// **Chain:** `TesseraSTTextView` -> `STTextView` (handles all TextKit 2
/// plumbing) -> `TesseraTextContentStorage` (satisfies `textContentManager`
/// as `NSTextContentStorage`) -> `TesseraTextContentManagerData` (document AST).
@MainActor
public final class TesseraSTTextView: STTextView {
    private var initialAttributedString: NSAttributedString

    // MARK: - Ghost Text (Phase 11 P0)

    /// Active ghost text session. nil when no suggestion is showing.
    private var ghostTextState: GhostTextState?

    /// The ghost text manager. Set up in setupGhostTextManager().
    private var ghostTextManager: TesseraGhostTextManager?

    /// The streaming pipeline provider, injected by the Coordinator once the engine is ready.
    /// Weak to avoid retain cycle; the pipeline lives in the Coordinator.
    private weak var ghostTextProvider: LocalGhostTextProvider?

    /// Wire up ghost text manager once the text content manager is injected.
    private func setupGhostTextManager() {
        let manager = TesseraGhostTextManager(provider: ghostTextProvider)
        manager.delegate = self
        self.ghostTextManager = manager
    }

    // MARK: - Writing Tools Coordinator (Phase 11 P3)

    /// The Writing Tools coordinator. Set up in setupWritingToolsCoordinator().
    private var tesseraWritingToolsCoordinator: TesseraWritingToolsCoordinator?

    // MARK: - Phase 10 P2: Scroll-based image load management

    /// Tracks the last visible text range so we can detect scroll direction
    /// and cancel prefetch loads for blocks that scrolled out of view.
    private var lastVisibleElementRange: Range<Int>?

    /// KVO observer token for the clip view's bounds change. Stored strongly
    /// so it fires for the lifetime of this text view; removed in deinit.
    private var clipViewObserver: NSObjectProtocol?

    /// Set up observation of the scroll view's clip view bounds changes.
    /// Called once from init. Phase 10 P2: cancels loads for blocks that
    /// scroll out of the visible area and prefetches upcoming image blocks.
    private func setupScrollObservation() {
        guard let clipView = enclosingScrollView?.contentView else { return }
        clipViewObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.handleScrollBoundsChange()
        }
    }

    /// Called on every clip-view bounds change (scroll / resize). Cancels
    /// image loads for blocks that scrolled far outside the visible area
    /// and prefetches images for upcoming blocks.
    private func handleScrollBoundsChange() {
        guard let contentManager = textContentManager as? TesseraTextContentManager else { return }
        let elements = contentManager.data.elements

        // Estimate how many elements are visible from the clip view's visible rect.
        // TextKit 2 uses noncontiguous layout — only the visible area + overscroll
        // is laid out at any time. We use the visible rect height divided by the
        // average element height to approximate the visible element count.
        guard let clipView = enclosingScrollView?.contentView else { return }
        let visibleRect = clipView.documentVisibleRect
        let totalElements = max(1, elements.count)
        let avgElementHeight = max(1, self.frame.height / CGFloat(totalElements))
        let visibleElementCount = max(1, Int(ceil(visibleRect.height / avgElementHeight)))

        // Approximate the current visible element range by converting the visible rect
        // to a character offset range via the text layout manager.
        // We enumerate text fragments in the visible rect and map their character
        // ranges to element indices.
        let approxRange = computeVisibleElementRange(visibleRect: visibleRect)

        // Cancel loads for blocks that scrolled out of the keep-alive zone
        // (±1 viewport around the last known visible range).
        if let lastRange = lastVisibleElementRange, let current = approxRange {
            let keepAliveTop = current.lowerBound - visibleElementCount
            let keepAliveBottom = current.upperBound + visibleElementCount
            for idx in lastRange {
                if idx < keepAliveTop || idx >= keepAliveBottom {
                    if idx < elements.count {
                        ImageLoader.shared.cancel(for: elements[idx].blockID)
                    }
                }
            }
        }
        lastVisibleElementRange = approxRange

        // Prefetch image blocks in the upcoming viewport.
        guard let visibleRange = approxRange else { return }
        let prefetchEnd = min(visibleRange.upperBound + visibleElementCount, elements.count)
        var prefetchSources: [(UUID, String)] = []
        for idx in visibleRange.upperBound..<prefetchEnd {
            let blockID = elements[idx].blockID
            if let block = contentManager.data.document.blocks[blockID],
               block.type == .image,
               let source = block.attributes["source"]?.stringValue,
               !source.isEmpty {
                prefetchSources.append((blockID, source))
            }
        }
        if !prefetchSources.isEmpty {
            ImageLoader.shared.prefetch(sources: prefetchSources)
        }
    }

    /// Returns an approximate element index range for the visible document rect.
    /// Uses TextKit 2's `enumerateTextLayoutFragments(in:options:using:)` to get
    /// the character range of visible text fragments, then binary-searches the
    /// element list to map character offsets to element indices.
    private func computeVisibleElementRange(visibleRect: NSRect) -> Range<Int>? {
        guard let tcm = textContentManager as? TesseraTextContentManager else { return nil }
        let elements = tcm.data.elements
        guard !elements.isEmpty else { return nil }

        var minCharOffset = Int.max
        var maxCharOffset = 0

        // Find the first element that could be in the visible area (rough Y-based
        // pre-filter) and convert its character offset to an NSTextLocation so we can
        // call enumerateTextLayoutFragments(from:options:using:). We then check
        // each fragment's bounding rect against visibleRect to skip truly invisible
        // ones. Starting from element 0 is safe even for tall documents — the layout
        // manager will traverse only the visible region; the per-fragment bounding-rect
        // guard below ensures we don't over-count.
        let startOffset = elements[0].rangeStart
        let startLocation = tcm.textLocation(forCharacterOffset: startOffset)
        textLayoutManager.enumerateTextLayoutFragments(
            from: startLocation,
            options: [.ensuresLayout]
        ) { fragment in
            // fragment.rangeInElement is an NSTextRange with (location, length) typed as
            // any NSTextLocation existentials. Cast to IntTextLocation (our concrete type)
            // to extract the integer offsets. Guard with "flatMap" pattern: if either
            // end of the range isn't our concrete type, skip the fragment (this should
            // never happen in the editor since TesseraTextContentStorage only creates
            // IntTextLocation-based ranges).
            guard let startIntLoc = fragment.rangeInElement.location as? IntTextLocation,
                  let endIntLoc = fragment.rangeInElement.length as? IntTextLocation else {
                return true  // keep enumerating
            }
            let startLoc = startIntLoc.intValue
            let endLoc = endIntLoc.intValue
            minCharOffset = min(minCharOffset, startLoc)
            maxCharOffset = max(maxCharOffset, endLoc)
            return true
        }

        if minCharOffset == Int.max { return 0..<0 }

        // Binary search to map character offsets to element indices.
        func elementIndex(ofOffset offset: Int) -> Int {
            var lo = 0, hi = elements.count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                if offset < elements[mid].rangeStart {
                    hi = mid - 1
                } else if offset >= elements[mid].rangeEnd {
                    lo = mid + 1
                } else {
                    return mid
                }
            }
            return max(0, min(lo, elements.count - 1))
        }

        let topIdx = elementIndex(ofOffset: minCharOffset)
        let bottomIdx = elementIndex(ofOffset: maxCharOffset)
        return topIdx..<(bottomIdx + 1)
    }

    /// Controls whether the gutter shows line numbers.
    /// Mirrors STTextView.showsLineNumbers; wrapping it here keeps the
    /// @MainActor boundary inside this class so the Coordinator
    /// (not @MainActor) can call it without async.
    public var gutterLineNumbers: Bool {
        get { showsLineNumbers }
        set { showsLineNumbers = newValue }
    }

    /// Controls whether invisible characters (spaces, tabs, etc.) are visible.
    /// This is the text-editor equivalent of "gridlines" in a word processor.
    public var gutterGridlines: Bool {
        get { showsInvisibleCharacters }
        set { showsInvisibleCharacters = newValue }
    }

    /// Controls the horizontal ruler overlay via the scroll view.
    /// STTextView does not expose showsRuler; we attach NSRulerView to
    /// the enclosing NSScrollView when first enabled, then toggle visibility.
    private var _showRuler: Bool = false
    public var gutterRuler: Bool {
        get { _showRuler }
        set {
            _showRuler = newValue
            guard let scrollView = enclosingScrollView else { return }
            if newValue && scrollView.verticalRulerView == nil {
                let ruler = NSRulerView()
                ruler.ruleThickness = 20
                ruler.clientView = self
                scrollView.verticalRulerView = ruler
                scrollView.hasVerticalRuler = true
                scrollView.rulersVisible = true
            } else {
                scrollView.rulersVisible = newValue
            }
        }
    }

    public init(
        frame: NSRect = .zero,
        contentStorage: TesseraTextContentStorage,
        initialAttributedString: NSAttributedString
    ) {
        self.initialAttributedString = initialAttributedString
        // STTextView's init(frame:) runs in this order:
        //   1. Creates its own STTextContentStorage + STTextLayoutManager.
        //   2. Calls super.init(frame:).
        //   3. textLayoutManager.didSet fires and attaches to STTextContentStorage.
        //   4. self.text = text (uses new storage via didSet).
        // After super.init() the view is fully set up with the default storage.
        // We then swap in our TesseraTextContentStorage. This is safe because
        // textLayoutManager is open dynamic — re-assigning it fires didSet and
        // re-attaches the layout manager to whatever textContentManager is set.
        super.init(frame: frame)
        self.textContentManager = contentStorage
        // Re-trigger textLayoutManager.didSet so it re-hooks to our storage.
        // This calls setupTextLayoutManager + self.text = text with the new storage.
        self.textLayoutManager = textLayoutManager
        // Set the actual attributed content (didSet only sets self.text = String).
        self.replaceContent(with: initialAttributedString)
        // Phase 10 P2: observe scroll to cancel prefetch loads for blocks that
        // scroll out of the visible area, and prefetch upcoming image blocks.
        setupScrollObservation()
        // Phase 11 P3: Wire up Writing Tools coordinator after storage is set.
        setupWritingToolsCoordinator()
        // Phase 11 P0: Wire up ghost text manager after storage is set.
        setupGhostTextManager()
    }

    public required init?(coder: NSCoder) {
        fatalError("TesseraSTTextView requires init(frame:contentStorage:initialAttributedString:)")
    }

    deinit {
        if let observer = clipViewObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Replace the text view's entire content with a new attributed
    /// string. Used by the host when the agent mutates the document
    /// (the SwiftUI binding updates and `updateNSView` calls this).
    public func replaceContent(with attributed: NSAttributedString) {
        guard let storage = textContentManager as? TesseraTextContentStorage else { return }
        textContentManager.performEditingTransaction {
            storage.replaceAllCharacters(with: attributed)
        }
    }

    // MARK: - Text Formatting

    /// Text format variants available from the formatting toolbar.
    public enum TextFormat {
        case bold
        case italic
        case underline
        case strikethrough
        case code
    }

    /// Returns the font to use for normal (non-monospace) text at the given
    /// point size, inheriting the current font's family.
    private func normalFont(size: CGFloat) -> NSFont {
        let base = (typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: size)
        let family = base.familyName ?? NSFont.systemFont(ofSize: size).familyName ?? "System"
        return NSFont(name: family, size: size) ?? NSFont.systemFont(ofSize: size)
    }

    /// Returns true if `format` is currently active across the given range.
    /// For collapsed selections, checks typing attributes.
    public func isFormatActive(_ format: TextFormat, in range: NSRange) -> Bool {
        let textStorage = (textContentManager as? NSTextContentStorage)?.textStorage
        if range.length == 0 {
            // Check typing attributes for collapsed selection
            guard let font = typingAttributes[.font] as? NSFont else { return false }
            switch format {
            case .bold:     return font.fontDescriptor.symbolicTraits.contains(.bold)
            case .italic:   return font.fontDescriptor.symbolicTraits.contains(.italic)
            case .code:     return font == NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
            default:        return false
            }
        }
        guard let attrs = textStorage?.attributes(at: range.location, effectiveRange: nil) else { return false }
        switch format {
        case .bold:
            guard let font = attrs[.font] as? NSFont else { return false }
            return font.fontDescriptor.symbolicTraits.contains(.bold)
        case .italic:
            guard let font = attrs[.font] as? NSFont else { return false }
            return font.fontDescriptor.symbolicTraits.contains(.italic)
        case .underline:
            return (attrs[.underlineStyle] as? Int) != nil
        case .strikethrough:
            return (attrs[.strikethroughStyle] as? Int) != nil
        case .code:
            guard let font = attrs[.font] as? NSFont else { return false }
            return font == NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
        }
    }

    /// Toggles or applies a text format to the given range.
    /// For a collapsed selection, updates typing attributes so the format
    /// applies to subsequently typed text.
    public func applyFormat(_ format: TextFormat, to range: NSRange) {
        let active = isFormatActive(format, in: range)
        if range.length == 0 {
            // Collapsed selection — update typing attributes
            switch format {
            case .bold:
                let base = (typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 14)
                let size = base.pointSize
                typingAttributes[.font] = active
                    ? NSFont.systemFont(ofSize: size)
                    : NSFont.boldSystemFont(ofSize: size)
            case .italic:
                let base = (typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 14)
                let size = base.pointSize
                let traits = active ? [] : NSFontDescriptor.SymbolicTraits.italic
                let desc = base.fontDescriptor.withSymbolicTraits(traits)
                typingAttributes[.font] = NSFont(descriptor: desc, size: size) ?? NSFont.systemFont(ofSize: size)
            case .underline:
                typingAttributes[.underlineStyle] = active ? nil : NSUnderlineStyle.single.rawValue
            case .strikethrough:
                typingAttributes[.strikethroughStyle] = active ? nil : NSUnderlineStyle.single.rawValue
            case .code:
                let base = (typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 13)
                typingAttributes[.font] = active
                    ? normalFont(size: base.pointSize)
                    : NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
            }
        } else {
            // Range selected — modify the attributed string
            guard let storage = (textContentManager as? NSTextContentStorage)?.textStorage else { return }
            storage.beginEditing()
            switch format {
            case .bold:
                let current = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? NSFont.systemFont(ofSize: 14)
                let size = current.pointSize
                let newFont = active
                    ? NSFont.systemFont(ofSize: size)
                    : NSFont.boldSystemFont(ofSize: size)
                storage.addAttribute(.font, value: newFont, range: range)
            case .italic:
                let current = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? NSFont.systemFont(ofSize: 14)
                let size = current.pointSize
                let traits: NSFontDescriptor.SymbolicTraits = active ? [] : .italic
                let desc = current.fontDescriptor.withSymbolicTraits(traits)
                if let newFont = NSFont(descriptor: desc, size: size) {
                    storage.addAttribute(.font, value: newFont, range: range)
                }
            case .underline:
                if active {
                    storage.removeAttribute(.underlineStyle, range: range)
                } else {
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
            case .strikethrough:
                if active {
                    storage.removeAttribute(.strikethroughStyle, range: range)
                } else {
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
            case .code:
                let current = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? NSFont.systemFont(ofSize: 13)
                let size = current.pointSize
                storage.addAttribute(.font, value: active
                    ? normalFont(size: size)
                    : NSFont.monospacedSystemFont(ofSize: size, weight: .regular), range: range)
            }
            storage.endEditing()
            textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
        }
    }

    /// Changes the font size by `delta` points. For collapsed selections,
    /// updates typing attributes. For selections, applies to all characters.
    public func applyFontSizeChange(delta: CGFloat, to range: NSRange) {
        if range.length == 0 {
            let current = (typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 14)
            let newSize = max(1, min(512, current.pointSize + delta))
            if let family = current.familyName, let newFont = NSFont(name: family, size: newSize) {
                typingAttributes[.font] = newFont
            } else {
                typingAttributes[.font] = NSFont.systemFont(ofSize: newSize, weight: current.fontDescriptor.symbolicTraits.contains(.bold) ? .bold : .regular)
            }
        } else {
            guard let storage = (textContentManager as? NSTextContentStorage)?.textStorage else { return }
            storage.beginEditing()
            let current = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? NSFont.systemFont(ofSize: 14)
            let newSize = max(1, min(512, current.pointSize + delta))
            if let family = current.familyName, let newFont = NSFont(name: family, size: newSize) {
                storage.addAttribute(.font, value: newFont, range: range)
            } else {
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: newSize), range: range)
            }
            storage.endEditing()
            textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
        }
    }

    /// Sets the absolute font size in points.
    public func setFontSize(_ size: CGFloat, to range: NSRange) {
        applyFontSizeChange(delta: size - 14, to: range)  // relative to default 14pt
    }

    /// Sets the text alignment for the paragraph(s) containing the range.
    public func setParagraphAlignment(_ alignment: NSTextAlignment) {
        // Update typing attributes for collapsed selection
        let base = (typingAttributes[.paragraphStyle] as? NSParagraphStyle) ?? .default
        let mutablePS = base.mutableCopy() as! NSMutableParagraphStyle
        mutablePS.alignment = alignment
        typingAttributes[.paragraphStyle] = mutablePS

        // For a range, apply to the paragraph style
        let range = selectedRange()
        guard range.length > 0, let storage = (textContentManager as? NSTextContentStorage)?.textStorage else { return }
        storage.beginEditing()
        let ps = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle) ?? .default
        let mps = ps.mutableCopy() as! NSMutableParagraphStyle
        mps.alignment = alignment
        storage.addAttribute(.paragraphStyle, value: mps, range: range)
        storage.endEditing()
        textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
    }

    // MARK: - Keyboard shortcuts

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        // Ghost text interception (Phase 11 P0) — runs before existing shortcuts.
        if let manager = ghostTextManager {
            let mods = event.modifierFlags
            let char = event.charactersIgnoringModifiers ?? ""

            // Tab → accept full suggestion
            if event.keyCode == 48 && !mods.contains(.command) && !mods.contains(.option) {  // NSEvent.SpecialKey.tab
                manager.acceptFull()
                return
            }

            // Cmd+→ → accept next word
            if event.keyCode == 124 && mods.contains(.command) && !mods.contains(.option) {  // NSEvent.SpecialKey.rightArrow
                manager.acceptNextWord()
                return
            }

            // Escape → dismiss
            if event.keyCode == 53 {  // NSEvent.SpecialKey.escape
                manager.dismiss()
                return
            }

            // Any other key: check for divergence
            if !char.isEmpty && !mods.contains(.command) && !mods.contains(.control) {
                // Build prompt from current text context
                let prompt = currentTextContext()
                if manager.onKeystroke(character: char, prompt: prompt) {
                    // Divergence cancelled ghost text; fall through to normal handling
                }
            }
        }

        // [Rest of existing keyDown handling below]
        let mods = event.modifierFlags
        let cmd = mods.contains(.command)
        let opt = mods.contains(.option)
        let ctrl = mods.contains(.control)
        let shift = mods.contains(.shift)
        let char = event.charactersIgnoringModifiers

        // Ctrl+F — show find bar
        if ctrl && !cmd && !opt && char == "f" {
            onFindBarRequested?(); return
        }
        // Ctrl+H — find + replace
        if ctrl && !cmd && !opt && char == "h" {
            onFindBarRequested?(); return
        }
        // Ctrl+K — quick search (reuse find bar)
        if ctrl && !cmd && !opt && char == "k" {
            onFindBarRequested?(); return
        }
        // F3 / Shift+F3 — find next/previous
        if event.keyCode == 99 {
            if shift { onFindPreviousRequested?() } else { onFindNextRequested?() }
            return
        }
        // Escape — close find bar
        if event.keyCode == 53 {
            onFindBarDismissed?(); return
        }
        // F7 — spell check
        if event.keyCode == 100 && !cmd && !opt {
            checkSpelling(); return
        }
        // Enter — exit focus mode
        if event.keyCode == 36 {
            if isFocusModeActive { onExitFocusModeRequested?(); return }
        }

        // === Phase 3 formatting shortcuts ===

        if cmd && !opt {
            switch char {
            case "b": applyFormat(.bold, to: selectedRange()); return
            case "i": applyFormat(.italic, to: selectedRange()); return
            case "u": applyFormat(.underline, to: selectedRange()); return
            case "]": applyFontSizeChange(delta: 1, to: selectedRange()); return
            case "[": applyFontSizeChange(delta: -1, to: selectedRange()); return
            default: break
            }
        }
        // Cmd+Opt+> / Cmd+Opt+< — font size ±2pt
        if cmd && opt && char == ">" { applyFontSizeChange(delta: 2, to: selectedRange()); return }
        if cmd && opt && char == "<" { applyFontSizeChange(delta: -2, to: selectedRange()); return }

        // Ctrl+Alt+1/2/3/4 — Word-style heading shortcuts
        if ctrl && opt {
            switch char {
            case "1": applyBlockTypeChange(.heading, level: 1); return
            case "2": applyBlockTypeChange(.heading, level: 2); return
            case "3": applyBlockTypeChange(.heading, level: 3); return
            case "4": applyBlockTypeChange(.heading, level: 4); return
            default: break
            }
        }

        super.keyDown(with: event)
    }

    // MARK: - Block type and list commands

    /// Theme heading font sizes (cloned from BlockRenderer).
    private let headingSizes: [Int: CGFloat] = [
        1: 28, 2: 22, 3: 18, 4: 16, 5: 14, 6: 13
    ]

    /// Change the current block's type and optionally its heading level.
    /// Applies the block change to the AST via the text content manager,
    /// then rebuilds the element list and refreshes the text storage.
    public func applyBlockTypeChange(_ blockType: BlockType, level: Int? = nil) {
        guard let contentManager = textContentManager as? TesseraTextContentManager else { return }
        let doc = contentManager.data.document

        // Find the block at the current cursor position.
        let offset = selectedRange().location
        let loc = IntTextLocation(intValue: offset)
        guard let element = contentManager.textElement(at: loc),
              let block = doc.blocks[element.blockID] else { return }

        var mutations: [Mutation] = []

        if blockType == .heading {
            // Convert any block to a heading. Preserve content, set level.
            let newBlock = Block(
                id: block.id,
                type: .heading,
                attributes: level.map { ["level": AnyCodable.number(Double($0))] } ?? [:],
                content: block.content,
                children: block.children,
                parentID: block.parentID
            )
            mutations = [.replaceBlock(blockID: block.id, block: newBlock)]
        } else if blockType == .paragraph {
            // Remove heading/list type, convert to plain paragraph.
            let newBlock = Block(
                id: block.id,
                type: .paragraph,
                attributes: [:],
                content: block.content,
                children: block.children,
                parentID: block.parentID
            )
            mutations = [.replaceBlock(blockID: block.id, block: newBlock)]
        }

        guard !mutations.isEmpty else { return }
        do {
            _ = try contentManager.applyMutations(mutations)
            // Rebuild the element list and refresh text storage.
            rebuildTextStorage()
        } catch {
            NSLog("TesseraSTTextView.applyBlockTypeChange: \(error)")
        }
    }

    /// Toggle the current paragraph to/from an unordered (bullet) list.
    /// If the block is already a listItem in an unordered list, converts it back
    /// to a paragraph. Otherwise, wraps the block in a list container.
    public func toggleUnorderedList() {
        toggleList(style: "unordered")
    }

    /// Toggle the current paragraph to/from an ordered (numbered) list.
    /// If the block is already a listItem in an ordered list, converts it back
    /// to a paragraph. Otherwise, wraps the block in a list container.
    public func toggleOrderedList() {
        toggleList(style: "ordered")
    }

    private func toggleList(style: String) {
        guard let contentManager = textContentManager as? TesseraTextContentManager else { return }
        let doc = contentManager.data.document

        let offset = selectedRange().location
        let loc = IntTextLocation(intValue: offset)
        guard let element = contentManager.textElement(at: loc),
              let block = doc.blocks[element.blockID] else { return }

        // Detect if this block is already a listItem in the list we're toggling.
        let isAlreadyThisList = block.type == .listItem
            && block.parentID != nil
            && (doc.blocks[block.parentID!]?.attributes["style"]?.stringValue) == style

        if isAlreadyThisList {
            // Convert back to a paragraph: move the listItem content to a paragraph
            // and insert it after the list container, then delete the listItem.
            guard let parentID = block.parentID,
                  let parentBlock = doc.blocks[parentID] else { return }
            let grandparentID = parentBlock.parentID

            // Find the index of the listItem within its parent.
            let itemIndex = parentBlock.children.firstIndex(of: block.id) ?? 0
            // Anchor is the sibling before the listItem (or the list container itself).
            let anchorID: UUID? = itemIndex > 0 ? parentBlock.children[itemIndex - 1] : parentID

            let paragraphBlock = Block(
                id: block.id,
                type: .paragraph,
                attributes: [:],
                content: block.content,
                children: [],
                parentID: grandparentID
            )
            let mutations: [Mutation] = [
                .insertBlockAfter(parentID: grandparentID, anchorID: anchorID, block: paragraphBlock),
                .deleteBlock(blockID: block.id)
            ]
            do {
                _ = try contentManager.applyMutations(mutations)
                rebuildTextStorage()
            } catch {
                NSLog("TesseraSTTextView.toggleList: \(error)")
            }
        } else {
            // Wrap the current block in a new list container.
            // Find anchor: the block immediately before the current one.
            let parentID = block.parentID
            let siblings = doc.children(of: parentID)
            let currentIdx = siblings.firstIndex(of: block.id) ?? 0
            let anchorID: UUID? = currentIdx > 0 ? siblings[currentIdx - 1] : nil

            // Build the new list container + listItem block.
            let listItemBlock = Block(
                id: UUID(),  // fresh ID for the listItem
                type: .listItem,
                attributes: [:],
                content: block.content,
                children: [],
                parentID: nil  // set by engine
            )
            let listContainer = Block(
                id: UUID(),  // fresh ID for the list container
                type: .list,
                attributes: ["style": AnyCodable.string(style)],
                content: [],
                children: [listItemBlock.id],
                parentID: parentID
            )

            let mutations: [Mutation] = [
                .deleteBlock(blockID: block.id),
                .insertBlockAfter(parentID: parentID, anchorID: anchorID, block: listContainer),
                .insertBlockAfter(parentID: listContainer.id, anchorID: nil, block: listItemBlock)
            ]
            do {
                _ = try contentManager.applyMutations(mutations)
                rebuildTextStorage()
            } catch {
                NSLog("TesseraSTTextView.toggleList: \(error)")
            }
        }
    }

    /// Rebuild the element list and refresh the text storage from the AST.
    /// Call this after any mutation that changes block structure or type.
    private func rebuildTextStorage() {
        guard let contentManager = textContentManager as? TesseraTextContentManager else { return }
        guard let storage = textContentManager as? TesseraTextContentStorage else { return }

        // Rebuild elements from the updated document.
        contentManager.data.setDocument(contentManager.data.document)

        // Rebuild the full attributed string from the new elements.
        let fresh = contentManager.data.fullAttributedString()

        textContentManager.performEditingTransaction {
            storage.replaceAllCharacters(with: fresh)
        }
        textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
    }

    // MARK: - Table insertion

    /// Insert a table block with the given dimensions and show the table editor overlay.
    public func insertTable(rows: Int, cols: Int) {
        guard let contentManager = textContentManager as? TesseraTextContentManager else { return }
        let doc = contentManager.data.document

        // Find anchor: the block before the cursor.
        let offset = selectedRange().location
        let loc = IntTextLocation(intValue: offset)
        let anchorID: UUID?
        let parentID: UUID?
        if let element = contentManager.textElement(at: loc),
           let block = doc.blocks[element.blockID] {
            parentID = block.parentID
            let siblings = doc.children(of: parentID)
            if let idx = siblings.firstIndex(of: block.id), idx > 0 {
                anchorID = siblings[idx - 1]
            } else {
                anchorID = nil
            }
        } else {
            parentID = nil
            anchorID = doc.rootChildren.last
        }

        // Build cell blocks (tableCell type, one per cell).
        var cellBlocks: [Block] = []
        for _ in 0..<(rows * cols) {
            cellBlocks.append(Block(type: .tableCell, content: [InlineRun(text: "")]))
        }

        // Build the table container.
        let tableBlock = Block(
            type: .table,
            attributes: [
                "rows": AnyCodable.number(Double(rows)),
                "cols": AnyCodable.number(Double(cols)),
                "columnWidths": AnyCodable.array((0..<cols).map { _ in AnyCodable.number(120.0) }),
            ],
            content: [],
            children: cellBlocks.map { $0.id }
        )

        // Insert the table block followed by its cell blocks.
        var mutations: [Mutation] = [.insertBlockAfter(parentID: parentID, anchorID: anchorID, block: tableBlock)]
        for (i, cell) in cellBlocks.enumerated() {
            let cellAnchor: UUID? = i == 0 ? tableBlock.id : cellBlocks[i - 1].id
            mutations.append(.insertBlockAfter(parentID: tableBlock.id, anchorID: cellAnchor, block: cell))
        }

        do {
            _ = try contentManager.applyMutations(mutations)
            rebuildTextStorage()
            // Show the table editor overlay for the newly inserted table.
            showTableEditor(for: tableBlock.id)
        } catch {
            NSLog("TesseraSTTextView.insertTable: \(error)")
        }
    }

    // MARK: - Table editor overlay

    private var tableEditorOverlay: TesseraTableEditorOverlay?

    /// Show the table editor overlay for the given table block ID.
    public func showTableEditor(for tableBlockID: UUID) {
        guard let contentManager = textContentManager as? TesseraTextContentManager else { return }
        let doc = contentManager.data.document
        guard let tableBlock = doc.blocks[tableBlockID], tableBlock.type == .table else { return }

        // Extract cell text from the cell blocks.
        let rows = tableBlock.attributes["rows"]?.intValue ?? 3
        let cols = tableBlock.attributes["cols"]?.intValue ?? 3
        let cellText: [[String]] = (0..<rows).map { row in
            (0..<cols).map { col in
                let idx = row * cols + col
                guard idx < tableBlock.children.count else { return "" }
                let cellID = tableBlock.children[idx]
                if let cellBlock = doc.blocks[cellID] {
                    return cellBlock.content.map(\.text).joined()
                }
                return ""
            }
        }

        // Dismiss any existing overlay.
        tableEditorOverlay?.removeFromSuperview()

        // Position the overlay near the table block's text range.
        // Find the element for this block.
        var overlayY: CGFloat = 100
        for element in contentManager.data.elements {
            if element.blockID == tableBlockID {
                // Use the element's rangeEnd for Y positioning.
                overlayY = CGFloat(element.rangeEnd)
                break
            }
        }

        let scrollViewHeight = enclosingScrollView?.contentSize.height ?? 600
        let overlayWidth: CGFloat = min(CGFloat(cols) * 130 + 40, 600)
        let overlayHeight: CGFloat = CGFloat(rows) * 28 + 80
        let overlayRect = NSRect(
            x: 40,
            y: max(overlayY - overlayHeight - 20, scrollViewHeight - overlayHeight - 40),
            width: overlayWidth,
            height: overlayHeight
        )

        let overlay = TesseraTableEditorOverlay(frame: overlayRect)
        overlay.configure(with: tableBlock)
        overlay.setCellText(cellText)
        overlay.onDismiss = { [weak self] (updatedBlock: Block?) in
            self?.commitTableEdit(blockID: tableBlockID, updatedBlock: updatedBlock)
            self?.tableEditorOverlay?.removeFromSuperview()
            self?.tableEditorOverlay = nil
        }

        // Add to the scroll view's document view.
        if let scrollView = enclosingScrollView,
           let docView = scrollView.documentView {
            docView.addSubview(overlay)
        }

        tableEditorOverlay = overlay
    }

    private func commitTableEdit(blockID: UUID, updatedBlock: Block?) {
        guard let updatedBlock,
              let contentManager = textContentManager as? TesseraTextContentManager else { return }
        let doc = contentManager.data.document
        guard let tableBlock = doc.blocks[blockID] else { return }

        // Update each cell's content.
        let newCellText = updatedBlock.children.compactMap { id -> [InlineRun]? in
            if let block = doc.blocks[id] {
                return block.content
            }
            return nil
        }

        var mutations: [Mutation] = []
        for (i, cellID) in tableBlock.children.enumerated() {
            if i < newCellText.count {
                mutations.append(.setBlockContent(blockID: cellID, content: [InlineRun(text: newCellText[i].map(\.text).joined())]))
            }
        }

        guard !mutations.isEmpty else { return }
        do {
            _ = try contentManager.applyMutations(mutations)
            rebuildTextStorage()
        } catch {
            NSLog("TesseraSTTextView.commitTableEdit: \(error)")
        }
    }

    // MARK: - Table double-click handling

    /// Callback invoked when the user double-clicks a table block.
    /// Set by the coordinator in makeNSView.
    public var onTableBlockDoubleClicked: ((UUID) -> Void)?

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            // Detect double-click on a table block.
            if let contentManager = textContentManager as? TesseraTextContentManager {
                let clickLoc = selectedRange().location
                let loc = IntTextLocation(intValue: clickLoc)
                if let element = contentManager.textElement(at: loc),
                   let block = contentManager.data.document.blocks[element.blockID],
                   block.type == .table {
                    onTableBlockDoubleClicked?(block.id)
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: - Image handling

    /// Prompt the user with an NSOpenPanel for an image file, then insert it.
    public func promptAndInsertImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg, .gif, .heic, .tiff, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image to insert"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                self?.insertImage(from: url)
            }
        }
    }

    /// Insert an image block from a URL and show the image overlay.
    public func insertImage(from url: URL, alt: String = "image") {
        guard let contentManager = textContentManager as? TesseraTextContentManager else { return }
        let doc = contentManager.data.document

        // Find anchor.
        let offset = selectedRange().location
        let loc = IntTextLocation(intValue: offset)
        let anchorID: UUID?
        let parentID: UUID?
        if let element = contentManager.textElement(at: loc),
           let block = doc.blocks[element.blockID] {
            parentID = block.parentID
            let siblings = doc.children(of: parentID)
            if let idx = siblings.firstIndex(of: block.id), idx > 0 {
                anchorID = siblings[idx - 1]
            } else { anchorID = nil }
        } else {
            parentID = nil
            anchorID = doc.rootChildren.last
        }

        let imageBlock = Block(
            type: .image,
            attributes: [
                "source": .string(url.absoluteString),
                "alt": .string(alt),
            ]
        )

        let mutations: [Mutation] = [.insertBlockAfter(parentID: parentID, anchorID: anchorID, block: imageBlock)]
        do {
            _ = try contentManager.applyMutations(mutations)
            rebuildTextStorage()
        } catch {
            NSLog("TesseraSTTextView.insertImage: \(error)")
        }
    }

    /// Show resize handles for the selected image block.
    public func showImageResizeOverlay(for blockID: UUID) {
        // Image resize overlay: handled via selection tracking in the coordinator.
        // The coordinator detects when the cursor is inside an image block and
        // the selection is a single character — at that point it shows handles.
        // For now, image selection is detected in handleSelectionChange and
        // the overlay is managed by the coordinator.
    }

    // MARK: - Find / Replace

    /// Direction for find operations.
    public enum FindDirection {
        case forward
        case backward
    }

    /// Search options for find operations.
    public struct FindOptions: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let caseSensitive  = FindOptions(rawValue: 1 << 0)
        public static let wholeWord      = FindOptions(rawValue: 1 << 1)
        public static let regularExpr    = FindOptions(rawValue: 1 << 2)
        public static let wrap           = FindOptions(rawValue: 1 << 3)
    }

    /// Callback fired when find results change (match count, current index).
    /// Set by the coordinator so the FindReplaceBar can update its badge.
    public var onFindResultsChanged: ((_ matchCount: Int, _ currentMatch: Int) -> Void)?

    /// Perform a find operation and scroll to the result.
    /// Uses a manual search so it works with STTextView's TextKit 2 internals.
    public func performFind(searchText: String, options: FindOptions, direction: FindDirection) {
        guard !searchText.isEmpty else { return }
        let string = (textContentManager as? NSTextContentStorage)?.textStorage?.string ?? ""
        let nsRange = NSRange(location: 0, length: string.utf16.count)
        let cur = selectedRange()
        let searchStart: Int
        let searchEnd: Int

        if direction == .forward {
            searchStart = max(0, cur.location + cur.length)
            searchEnd = nsRange.upperBound
        } else {
            searchStart = 0
            searchEnd = cur.location
        }

        let matchCount = countMatches(searchText: searchText, options: options)
        let foundRange = findOne(
            searchText: searchText,
            in: string,
            searchRange: NSRange(location: searchStart, length: max(0, searchEnd - searchStart)),
            options: options
        )

        if let found = foundRange {
            perform(Selector(("setSelectedRange:")), with: found)
            scrollRangeToVisible(found)
            onFindResultsChanged?(matchCount, 1)
        } else if options.contains(.wrap) {
            // Wrap around.
            let wrappedRange = NSRange(location: 0, length: direction == .forward ? searchStart : nsRange.upperBound)
            if let wrapped = findOne(searchText: searchText, in: string, searchRange: wrappedRange, options: options) {
                perform(Selector(("setSelectedRange:")), with: wrapped)
                scrollRangeToVisible(wrapped)
            }
            onFindResultsChanged?(matchCount, 0)
        } else {
            onFindResultsChanged?(matchCount, 0)
        }
    }

    /// Find one match of searchText in string within searchRange.
    private func findOne(searchText: String, in string: String, searchRange: NSRange, options: FindOptions) -> NSRange? {
        if options.contains(.regularExpr) {
            do {
                let regex = try NSRegularExpression(pattern: searchText, options: [])
                if let match = regex.firstMatch(in: string, options: [], range: searchRange) {
                    return match.range
                }
            } catch { return nil }
        } else {
            var nsOpts: NSString.CompareOptions = []
            if !options.contains(.caseSensitive) { nsOpts.insert(.caseInsensitive) }
            if let strRange = Range(searchRange, in: string),
               let r = string.range(of: searchText, options: nsOpts, range: strRange) {
                return NSRange(r, in: string)
            }
        }
        return nil
    }

    /// Replace the current selection with replacement text.
    public func replaceSelection(with replacement: String) {
        insertText(replacement, replacementRange: selectedRange())
    }

    /// Replace all occurrences of searchText with replacement.
    public func replaceAllOccurrences(searchText: String, with replacement: String, options: FindOptions) {
        guard let storage = (textContentManager as? NSTextContentStorage)?.textStorage else { return }
        let string = storage.string
        let fullRange = NSRange(location: 0, length: string.utf16.count)

        if options.contains(.regularExpr) {
            do {
                let regex = try NSRegularExpression(pattern: searchText, options: [])
                let matches = regex.matches(in: string, options: [], range: fullRange)
                storage.beginEditing()
                for match in matches.reversed() {
                    storage.replaceCharacters(in: match.range, with: replacement)
                }
                storage.endEditing()
            } catch { }
        } else {
            var nsOpts: NSString.CompareOptions = []
            if !options.contains(.caseSensitive) { nsOpts.insert(.caseInsensitive) }
            var matchRanges: [NSRange] = []
            var pos = string.startIndex
            while let r = string.range(of: searchText, options: nsOpts, range: pos..<string.endIndex) {
                matchRanges.append(NSRange(r, in: string))
                pos = r.upperBound
            }
            storage.beginEditing()
            for r in matchRanges.reversed() {
                storage.replaceCharacters(in: r, with: replacement)
            }
            storage.endEditing()
        }
        textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
    }

    /// Count how many matches exist for searchText in the document.
    public func countMatches(searchText: String, options: FindOptions) -> Int {
        guard !searchText.isEmpty else { return 0 }
        let string = (textContentManager as? NSTextContentStorage)?.textStorage?.string ?? ""
        let range = NSRange(location: 0, length: string.utf16.count)

        if options.contains(.regularExpr) {
            do {
                let regex = try NSRegularExpression(pattern: searchText, options: [])
                return regex.numberOfMatches(in: string, options: [], range: range)
            } catch { return 0 }
        } else {
            var nsOptions: NSString.CompareOptions = []
            if !options.contains(.caseSensitive) {
                nsOptions.insert(.caseInsensitive)
            }
            var count = 0
            var searchStart = string.startIndex
            let wordChars = CharacterSet.alphanumerics
            while let r = string.range(of: searchText, options: nsOptions, range: searchStart..<string.endIndex) {
                // For whole-word, check boundaries.
                let isWordStart = r.lowerBound == string.startIndex ||
                    wordChars.contains(string[string.index(before: r.lowerBound)].unicodeScalars.first!)
                let isWordEnd = r.upperBound == string.endIndex ||
                    wordChars.contains(string[r.upperBound].unicodeScalars.first!)
                if !options.contains(.wholeWord) || (isWordStart && isWordEnd) {
                    count += 1
                }
                searchStart = r.upperBound
            }
            return count
        }
    }

    // MARK: - Comment insertion

    /// Insert a comment anchored to the current selection.
    /// Creates a `.comment` block and places a highlight in the text.
    public func insertCommentBlock(text: String = "", author: String = "Me") {
        guard let contentManager = textContentManager as? TesseraTextContentManager else { return }
        let doc = contentManager.data.document

        let sel = selectedRange()
        let anchorBlockID: UUID
        let anchorRangeStart: Int
        let anchorRangeEnd: Int

        // If there's a selection, use it. Otherwise anchor at cursor.
        if sel.length > 0 {
            let loc = IntTextLocation(intValue: sel.location)
            if let element = contentManager.textElement(at: loc) {
                anchorBlockID = element.blockID
            } else {
                anchorBlockID = doc.rootChildren.first ?? UUID()
            }
            anchorRangeStart = sel.location
            anchorRangeEnd = sel.location + sel.length
        } else {
            let loc = IntTextLocation(intValue: sel.location)
            if let element = contentManager.textElement(at: loc) {
                anchorBlockID = element.blockID
                anchorRangeStart = sel.location
                anchorRangeEnd = sel.location
            } else {
                anchorBlockID = doc.rootChildren.first ?? UUID()
                anchorRangeStart = 0
                anchorRangeEnd = 0
            }
        }

        let commentBlock = Block(
            type: .comment,
            attributes: [
                "anchorBlockID": .string(anchorBlockID.uuidString),
                "anchorRangeStart": .number(Double(anchorRangeStart)),
                "anchorRangeEnd": .number(Double(anchorRangeEnd)),
                "author": .string(author),
                "timestamp": .number(Date().timeIntervalSince1970),
                "resolved": .bool(false),
            ],
            content: [InlineRun(text: text)]
        )

        // Insert the comment block after the anchor block.
        let anchorIdx = doc.rootChildren.firstIndex(of: anchorBlockID) ?? (doc.rootChildren.count - 1)
        let anchorID: UUID? = anchorIdx >= 0 ? doc.rootChildren[anchorIdx] : nil

        let mutations: [Mutation] = [.insertBlockAfter(parentID: nil, anchorID: anchorID, block: commentBlock)]
        do {
            _ = try contentManager.applyMutations(mutations)
            rebuildTextStorage()
        } catch {
            NSLog("TesseraSTTextView.insertCommentBlock: \(error)")
        }
    }

    // MARK: - Spell check

    /// Check spelling in the document using the standard spell checker.
    public func checkSpelling() {
        // Use NSResponder.perform(Selector:) to call the spell checker panel.
        // "checkSpelling:" is an informal NSResponder method.
        let selector = NSSelectorFromString("checkSpelling:")
        if self.responds(to: selector) {
            self.perform(selector, with: nil)
        }
    }

    // MARK: - Link insertion

    /// Insert a link over the given range.
    public func insertLink(url: URL, range: NSRange) {
        guard let storage = (textContentManager as? NSTextContentStorage)?.textStorage else { return }
        storage.beginEditing()
        storage.addAttribute(.link, value: url, range: range)
        storage.endEditing()
        textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
    }

    /// Remove link attributes from the given range.
    public func removeLink(range: NSRange) {
        guard let storage = (textContentManager as? NSTextContentStorage)?.textStorage else { return }
        storage.beginEditing()
        storage.removeAttribute(.link, range: range)
        storage.endEditing()
        textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
    }



    // MARK: - Find bar callbacks

    /// Called when Ctrl+F/H/K is pressed. Set by the coordinator.
    public var onFindBarRequested: (() -> Void)?
    /// Called when F3 is pressed (find next).
    public var onFindNextRequested: (() -> Void)?
    /// Called when Shift+F3 is pressed (find previous).
    public var onFindPreviousRequested: (() -> Void)?
    /// Called when Escape is pressed while find bar is open.
    public var onFindBarDismissed: (() -> Void)?

    // MARK: - Focus mode (Phase 9)

    /// Set to true when focus mode is active; Enter key exits focus mode.
    public var isFocusModeActive: Bool = false

    /// Called when Enter is pressed in focus mode.
    public var onExitFocusModeRequested: (() -> Void)?
    // MARK: - Ghost Text Helpers (Phase 11 P0)

    /// Returns the text context (surrounding text) for the ghost text prompt.
    /// Returns ±500 chars around the caret.
    private func currentTextContext() -> String {
        guard let storage = (textContentManager as? NSTextContentStorage)?.textStorage else {
            return ""
        }
        let selectedRange = self.selectedRange()
        let text = storage.string as NSString
        let contextStart = max(0, selectedRange.location - 500)
        let contextEnd = min(text.length, selectedRange.location + 500)
        return text.substring(
            with: NSRange(location: contextStart, length: contextEnd - contextStart)
        )
    }

    /// The current typing attributes at the caret, used for ghost text rendering.
    private var typingAttributesForGhostText: [NSAttributedString.Key: Any] {
        typingAttributes
    }

    /// Inject the GhostTextProvider (called by Coordinator once streaming pipeline exists).
    public func setGhostTextProvider(_ provider: LocalGhostTextProvider?) {
        self.ghostTextProvider = provider
        ghostTextManager?.setProvider(provider)
    }

    // MARK: - Writing Tools Coordinator (Phase 11 P3)

    /// Set up Writing Tools integration once text content manager is injected.
    private func setupWritingToolsCoordinator() {
        guard let cm = textContentManager as? TesseraTextContentManager else { return }
        let coordinator = TesseraWritingToolsCoordinator(textView: self, contentManager: cm)
        coordinator.rewriteDelegate = self
        coordinator.writingToolsBehavior = .complete
        coordinator.activate()
        self.tesseraWritingToolsCoordinator = coordinator
    }

    // MARK: - NSServicesMenuRequestor (Tier 2 Writing Tools shortcut)

    /// Returns a requestor for Writing Tools service types so the Edit menu's
    /// Transform submenu items (Rewrite, Proofread, etc.) are active when text
    /// is selected. This is the Tier 2 shortcut — the full Tier 3 coordinator
    /// (setup above) handles the actual rewrite lifecycle.
    public func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> NSObject? {
        if sendType == .string || returnType == .string {
            return self
        }
        return nil
    }

    /// Write the current selection to the pasteboard for the service.
    public func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) {
        guard types.contains(.string) else { return }
        let range = selectedRange()
        guard range.length > 0 else { return }
        if let textStorage = (textContentManager as? NSTextContentStorage)?.textStorage {
            let selectedText = textStorage.attributedSubstring(from: range)
            pasteboard.clearContents()
            pasteboard.setString(selectedText.string, forType: .string)
        }
    }

    /// Read the replaced text from the pasteboard after the service runs.
    public override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return false }
        return pasteboard.string(forType: .string) != nil
    }
}

// MARK: - GhostTextManagerDelegate

extension TesseraSTTextView: GhostTextManagerDelegate {
    public func ghostTextManager(
        _ manager: TesseraGhostTextManager,
        renderGhostText attributedString: NSAttributedString,
        at range: NSRange
    ) {
        guard let storage = (textContentManager as? NSTextContentStorage)?.textStorage else {
            return
        }
        storage.replaceCharacters(in: range, with: attributedString)
    }

    public func ghostTextManager(
        _ manager: TesseraGhostTextManager,
        removeGhostTextAt range: NSRange,
        caretLocation: Int
    ) {
        guard let storage = (textContentManager as? NSTextContentStorage)?.textStorage else {
            return
        }
        storage.replaceCharacters(in: range, with: NSAttributedString())
        perform(Selector(("setSelectedRange:")), with: NSValue(range: NSRange(location: caretLocation, length: 0)))
    }

    public func ghostTextManager(
        _ manager: TesseraGhostTextManager,
        acceptGhostTextAt range: NSRange,
        committedText: NSAttributedString
    ) {
        guard let storage = (textContentManager as? NSTextContentStorage)?.textStorage else {
            return
        }
        storage.replaceCharacters(in: range, with: committedText)
        let newCaret = range.location + committedText.length
        perform(Selector(("setSelectedRange:")), with: NSValue(range: NSRange(location: newCaret, length: 0)))
    }

    public func ghostTextManager(
        _ manager: TesseraGhostTextManager,
        acceptPartialGhostTextAt range: NSRange,
        wordCount: Int,
        remainingGhostText: NSAttributedString
    ) {
        guard let storage = (textContentManager as? NSTextContentStorage)?.textStorage else {
            return
        }
        // Already-committed words are in the storage as normal text.
        // remainingGhostText replaces the rest of the ghost text range.
        storage.replaceCharacters(in: range, with: remainingGhostText)
    }
}

// MARK: - TesseraWritingToolsRewriteDelegate conformance

@available(macOS 15.2, *)
extension TesseraSTTextView: TesseraWritingToolsRewriteDelegate {
    public func tesseraWritingToolsCoordinator(
        _ coordinator: TesseraWritingToolsCoordinator,
        applyReplacement text: NSAttributedString,
        at documentRange: NSRange,
        originalContextRange: NSRange
    ) {
        guard let storage = (textContentManager as? NSTextContentStorage)?.textStorage else { return }
        storage.replaceCharacters(in: documentRange, with: text)
    }
}

