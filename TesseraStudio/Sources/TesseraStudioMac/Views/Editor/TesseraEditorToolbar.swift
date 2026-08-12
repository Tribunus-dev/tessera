import SwiftUI
import AppKit
import TesseraCore

// MARK: - RouteChip

/// Privacy badge: shows the active AI route. Tapping opens Settings → AI.
/// When AI is disabled, the chip is hidden entirely (opt-in, not bundled).
struct RouteChip: View {
    @AppStorage(TesseraSettingsKey.aiEnabled) private var aiEnabled = TesseraSettingsDefault.aiEnabled
    @AppStorage(TesseraSettingsKey.aiRoute) private var aiRoute = TesseraSettingsDefault.aiRoute

    var body: some View {
        if aiEnabled {
            HStack(spacing: 4) {
                Circle()
                    .fill(aiRoute == "local" ? Color.green : Color.blue)
                    .frame(width: 6, height: 6)
                Text(aiRoute == "local" ? "Granite · Local" : "Cloud")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color(.controlBackgroundColor))
                    .overlay(
                        Capsule()
                            .stroke(Color(.separatorColor), lineWidth: 0.5)
                    )
            )
            .help("AI enabled: \(aiRoute == "local" ? "Granite running locally" : "Using cloud endpoint")")
            .accessibilityLabel("AI route: \(aiRoute == "local" ? "Granite running locally" : "Cloud endpoint")")
        }
    }
}

// MARK: - FormattingState

/// The current formatting state at the user's caret. The
/// toolbar reads this to highlight the active buttons
/// (bold, italic, etc.). The state is updated by the
/// platform text view's selection change; Phase 3 wires
/// the live update.
public struct FormattingState: Equatable {
    public var isBold: Bool = false
    public var isItalic: Bool = false
    public var isUnderline: Bool = false
    public var isStrikethrough: Bool = false
    public var isCode: Bool = false
    public var headingLevel: Int? = nil
    public var linkURL: URL? = nil
    public var blockType: BlockType = .paragraph
    public var alignment: Alignment = .leading
    // Document-level state — not derived from text selection.
    public var isTrackChangesEnabled: Bool = false
    public var isCommentsPanelVisible: Bool = false
    public var showLineNumbers: Bool = false
    public var showRuler: Bool = false
    public var showGridlines: Bool = false
    public var commentCount: Int = 0
    public var pendingChangeCount: Int = 0

    public enum Alignment: Int, Equatable {
        case leading = 0  // Left
        case center = 1
        case trailing = 2 // Right
        case justify = 3
    }

    public init() {}
}

// MARK: - TesseraEditorToolbar

/// The SwiftUI formatting toolbar that sits above (or
/// below) the editor. The toolbar composes the
/// platform-agnostic primitives (text style buttons,
/// block-type pickers) with custom buttons for the
/// block types the productivity surface promotes
/// (callout, table, image, code block).
///
/// **Per-surface configuration.** The `mode` parameter
/// controls which block types the toolbar offers as
/// one-click inserts:
///   * `.document` — full set: paragraph, heading,
///     list, quote, callout, code block, image, table.
///   * `.notes` — paragraph, heading, callout, quote,
///     divider (no tables, no images, no code blocks).
///   * `.code` — code block, list (no inline
///     formatting; the code surface is monospaced).
///
/// **Actions.** Every action calls into the
/// `EditorCommand` closure with a typed intent; the host
/// (the `TesseraEditorView`'s coordinator) converts the
/// intent into a `Mutation` and routes it through the
/// `EditorCoalescer`. The toolbar never edits the
/// document directly — it never touches the
/// `DocumentAST` or the `NSAttributedString`. This is
/// the load-bearing constraint that makes "user edits
/// and agent edits are the same thing" work.
///
/// **RichTextKit upgrade path.** Phase 2 ships a
/// hand-rolled SwiftUI toolbar. The recommended
/// production upgrade is `RichTextKit` (Daniel Saidi),
/// which provides a mature SwiftUI rich-text toolbar
/// with attribute pickers, alignment, lists, etc. The
/// toolbar's public API is the same `EditorCommand`
/// closure, so the swap is a no-op for the editor's
/// view layer.
public struct TesseraEditorToolbar: View {
    public let mode: EditorMode
    @Binding public var formattingState: FormattingState
    public let onCommand: (EditorCommand) -> Void
    /// When true, the Focus Mode button shows "Exit Focus" (active state).
    /// If nil, the button acts as a one-shot "Enter Focus" trigger.
    public var isFocusModeActive: Bool? = nil
    @State private var activeTab: RibbonTab = .home

    public init(
        mode: EditorMode,
        formattingState: Binding<FormattingState>,
        onCommand: @escaping (EditorCommand) -> Void,
        isFocusModeActive: Bool? = nil
    ) {
        self.mode = mode
        self._formattingState = formattingState
        self.onCommand = onCommand
        self.isFocusModeActive = isFocusModeActive
    }

    // MARK: - RibbonTab

    private enum RibbonTab: String, CaseIterable {
        case home, insert, layout, review, view

        var title: String {
            switch self {
            case .home:    return "Home"
            case .insert:  return "Insert"
            case .layout:  return "Layout"
            case .review:  return "Review"
            case .view:    return "View"
            }
        }

        func isAvailable(for mode: EditorMode) -> Bool {
            switch self {
            case .home:    return true
            case .insert:  return mode == .document || mode == .notes
            case .layout:  return mode == .document
            case .review:  return mode == .document || mode == .notes
            case .view:    return true
            }
        }
    }

    public var body: some View {
        Group {
            if mode.isCodeMode {
                codeToolbarContent
            } else {
                VStack(spacing: 0) {
                    ribbonTabBar
                    ribbonContentArea
                }
            }
        }
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - Code mode toolbar

    /// Compact single-row toolbar for `.code` and `.codeWithConfig` modes.
    /// Shows: language badge, focus toggle, line numbers toggle.
    /// No text formatting (bold/italic/etc. don't apply to code).
    private var codeToolbarContent: some View {
        HStack(spacing: 8) {
            // Language badge — placeholder; host passes language via
            // formattingState.blockType metadata or a dedicated binding.
            Text(formattingState.isCode ? "Code" : "")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(.separatorColor), lineWidth: 0.5)
                )

            Spacer()

            // Focus mode toggle.
            RibbonToggleButton(
                label: isFocusModeActive == true ? "Exit Focus" : "Focus",
                icon: "rectangle.center.inset.filled",
                isActive: isFocusModeActive ?? false
            ) {
                onCommand(.enterFocusMode)
            }

            // Line numbers toggle.
            RibbonToggleButton(
                label: "Lines",
                icon: "list.number",
                isActive: formattingState.showLineNumbers
            ) {
                formattingState.showLineNumbers.toggle()
                onCommand(.toggleLineNumbers)
            }

            Spacer()

            RouteChip()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separatorColor)).frame(height: 1)
        }
    }

    // MARK: - Tab bar

    private var ribbonTabBar: some View {
        HStack(spacing: 0) {
            ForEach(RibbonTab.allCases, id: \.self) { tab in
                RibbonTabButton(
                    title: tab.title,
                    isActive: activeTab == tab,
                    hasContent: tab.isAvailable(for: mode)
                ) {
                    activeTab = tab
                }
            }
            Spacer()
            RouteChip()
                .padding(.trailing, 8)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separatorColor)).frame(height: 1)
        }
    }

    // MARK: - Content area

    private var ribbonContentArea: some View {
        HStack(spacing: 0) {
            switch activeTab {
            case .home:    homeContent
            case .insert:  insertContent
            case .layout:  layoutContent
            case .review:  reviewContent
            case .view:    viewContent
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separatorColor)).frame(height: 1)
        }
    }

    // MARK: - Home tab

    private var homeContent: some View {
        HStack(spacing: 0) {
            ribbonGroup {
                RibbonButton(label: "Paste", icon: "doc.on.clipboard", shortcut: "⌘V") {
                    onCommand(.insertLink(URL(string: "tessera://clipboard/paste")!))
                }
            }
            groupSeparator()

            ribbonGroup {
                RibbonToggleButton(label: "B", weight: .bold, isActive: formattingState.isBold, shortcut: "⌘B", action: { onCommand(.toggleBold) })
                RibbonToggleButton(label: "I", italic: true, isActive: formattingState.isItalic, shortcut: "⌘I", action: { onCommand(.toggleItalic) })
                RibbonToggleButton(label: "U", underline: true, isActive: formattingState.isUnderline, shortcut: "⌘U", action: { onCommand(.toggleUnderline) })
                RibbonToggleButton(label: "S", strikethrough: true, isActive: formattingState.isStrikethrough, action: { onCommand(.toggleStrikethrough) })
                RibbonButton(label: "</>", shortcut: "⌘E", monospaced: true) { onCommand(.toggleCode) }
                groupDivider()
                RibbonButton(label: "A-", icon: nil, monospaced: true) { onCommand(.decreaseFontSize) }
                RibbonButton(label: "A+", icon: nil, monospaced: true) { onCommand(.increaseFontSize) }
            }
            groupSeparator()

            ribbonGroup {
                RibbonToggleButton(icon: "text.alignleft", isActive: formattingState.alignment == .leading, shortcut: "⌘L", action: { onCommand(.alignLeft) })
                RibbonToggleButton(icon: "text.aligncenter", isActive: formattingState.alignment == .center, shortcut: "⌘⇧C", action: { onCommand(.alignCenter) })
                RibbonToggleButton(icon: "text.alignright", isActive: formattingState.alignment == .trailing, shortcut: "⌘⇧R", action: { onCommand(.alignRight) })
                RibbonToggleButton(icon: "text.justify", isActive: formattingState.alignment == .justify, shortcut: "⌘J", action: { onCommand(.alignJustify) })
                groupDivider()
                RibbonButton(icon: "list.bullet", shortcut: "⌘⇧U") { onCommand(.toggleUnorderedList) }
                RibbonButton(icon: "list.number", shortcut: "⌘⇧O") { onCommand(.toggleOrderedList) }
                groupDivider()
                RibbonButton(icon: "increase.indent", shortcut: "⌘]") { onCommand(.indent) }
                RibbonButton(icon: "decrease.indent", shortcut: "⌘[") { onCommand(.outdent) }
            }
            groupSeparator()

            ribbonGroup {
                StyleButton(label: "Normal", isActive: formattingState.blockType == .paragraph) { onCommand(.setBlockType(.paragraph)) }
                StyleButton(label: "Heading 1", level: 1, isActive: formattingState.headingLevel == 1) { onCommand(.setBlockType(.heading)) }
                StyleButton(label: "Heading 2", level: 2, isActive: formattingState.headingLevel == 2) { onCommand(.setBlockType(.heading)) }
                StyleButton(label: "Heading 3", level: 3, isActive: formattingState.headingLevel == 3) { onCommand(.setBlockType(.heading)) }
            }
            groupSeparator()

            ribbonGroup {
                aiRewriteMenu
            }
        }
    }

    // MARK: - AI Rewrite (Phase 11 P2)

    private var aiRewriteMenu: some View {
        Menu {
            ForEach(RewriteMode.allCases, id: \.self) { mode in
                Button {
                    onCommand(.aiRewrite(mode: mode))
                } label: {
                    Label(mode.rawValue.capitalized, systemImage: modeIcon(mode))
                }
            }
        } label: {
            Image(systemName: "wand.and.stars")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 13))
                .frame(minWidth: 32, minHeight: 28)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .help("AI Rewrite")
    }

    private func modeIcon(_ mode: RewriteMode) -> String {
        switch mode {
        case .friendly:     return "face.smiling"
        case .professional: return "briefcase"
        case .concise:      return "scissors"
        case .improve:      return "wand.and.stars"
        case .custom:       return "text.cursor"
        }
    }

    // MARK: - Insert tab

    private var insertContent: some View {
        HStack(spacing: 0) {
            ribbonGroup {
                RibbonButton(label: "Table", icon: "tablecells") { onCommand(.insertTableCustom) }
            }
            groupSeparator()
            ribbonGroup {
                RibbonButton(label: "Image", icon: "photo") { onCommand(.insertImageCustom) }
                RibbonButton(label: "Code Block", icon: "chevron.left.forwardslash.chevron.right") { onCommand(.insertCodeBlock) }
            }
            groupSeparator()
            ribbonGroup {
                RibbonButton(label: "Link", icon: "link") { onCommand(.insertLinkCustom) }
            }
            groupSeparator()
            ribbonGroup {
                RibbonButton(label: "Header", icon: "header") { onCommand(.insertHeader) }
                RibbonButton(label: "Footer", icon: "footer") { onCommand(.insertFooter) }
            }
            groupSeparator()
            ribbonGroup {
                RibbonButton(label: "Page Break", icon: "rectangle.split.3x1") { onCommand(.insertPageBreak) }
            }
        }
    }

    // MARK: - Layout tab (Docs only)

    private var layoutContent: some View {
        HStack(spacing: 0) {
            ribbonGroup {
                RibbonButton(label: "Margins", icon: "square.dashed") { onCommand(.setMargins(.normal)) }
                RibbonButton(label: "Orientation", icon: "rectangle.portrait") { onCommand(.setOrientation(.portrait)) }
                RibbonButton(label: "Columns", icon: "rectangle.split.2x1") { onCommand(.setColumns(1)) }
            }
            groupSeparator()
            ribbonGroup {
                RibbonButton(label: "Page Color", icon: "paintpalette") { onCommand(.setPageColor("white")) }
            }
        }
    }

    // MARK: - Review tab

    private var reviewContent: some View {
        HStack(spacing: 0) {
            ribbonGroup {
                RibbonToggleButton(
                    label: "Track Changes",
                    icon: "pencil.line",
                    isActive: formattingState.isTrackChangesEnabled
                ) {
                    formattingState.isTrackChangesEnabled.toggle()
                    onCommand(.toggleTrackChanges)
                }
                if formattingState.pendingChangeCount > 0 {
                    Text("\(formattingState.pendingChangeCount)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.orange)
                        .cornerRadius(6)
                }
            }
            groupSeparator()
            ribbonGroup {
                RibbonToggleButton(
                    label: "Comments",
                    icon: "bubble.left",
                    isActive: formattingState.isCommentsPanelVisible
                ) {
                    formattingState.isCommentsPanelVisible.toggle()
                    onCommand(.toggleCommentsPanel)
                }
                if formattingState.commentCount > 0 {
                    Text("\(formattingState.commentCount)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.accentColor)
                        .cornerRadius(6)
                }
                RibbonButton(label: "New", icon: nil) { onCommand(.insertComment) }
                    .help("Insert comment (Ctrl+Alt+M)")
                RibbonButton(label: "Accept", icon: "checkmark.circle") { onCommand(.acceptChange) }
                RibbonButton(label: "Reject", icon: "xmark.circle") { onCommand(.rejectChange) }
            }
            groupSeparator()
            ribbonGroup {
                RibbonButton(label: "Word Count", icon: "number") { onCommand(.showWordCount) }
                RibbonButton(label: "History", icon: "clock.arrow.circlepath") { onCommand(.showVersionHistory) }
            }
        }
    }

    // MARK: - View tab

    private var viewContent: some View {
        HStack(spacing: 0) {
            ribbonGroup {
                RibbonToggleButton(
                    label: "Ruler",
                    icon: "ruler",
                    isActive: formattingState.showRuler
                ) {
                    onCommand(.toggleRuler)
                }
                RibbonToggleButton(
                    label: "Gridlines",
                    icon: "grid",
                    isActive: formattingState.showGridlines
                ) {
                    onCommand(.toggleGridlines)
                }
            }
            groupSeparator()
            ribbonGroup {
                RibbonToggleButton(
                    label: "Line Numbers",
                    icon: "list.number",
                    isActive: formattingState.showLineNumbers
                ) {
                    onCommand(.toggleLineNumbers)
                }
            }
            groupSeparator()
            ribbonGroup {
                RibbonToggleButton(
                    label: isFocusModeActive == true ? "Exit Focus" : "Focus Mode",
                    icon: "rectangle.center.inset.filled",
                    isActive: isFocusModeActive ?? false
                ) {
                    onCommand(.enterFocusMode)
                }
            }
        }
    }

    // MARK: - Ribbon helpers

    private func ribbonGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 2) {
            content()
        }
        .padding(.horizontal, 4)
    }

    private func groupSeparator() -> some View {
        Rectangle()
            .fill(Color(.separatorColor))
            .frame(width: 1, height: 36)
    }

    private func groupDivider() -> some View {
        Rectangle()
            .fill(Color(.separatorColor))
            .frame(width: 1, height: 18)
    }

    // MARK: - Ribbon button components

    /// Tab button with underline active indicator (4px pill).
    private struct RibbonTabButton: View {
        let title: String
        let isActive: Bool
        let hasContent: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                VStack(spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(hasContent ? (isActive ? Color.accentColor : Color.primary) : Color.secondary)

                    Rectangle()
                        .fill(isActive ? Color.accentColor : Color.clear)
                        .frame(height: 2)
                        .cornerRadius(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isActive ? Color.accentColor.opacity(0.06) : Color.clear)
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .disabled(!hasContent)
        }
    }

    /// A group of buttons with a group label shown on hover.
    private struct RibbonButton: View {
        var label: String = ""
        var icon: String? = nil
        var shortcut: String? = nil
        var monospaced: Bool = false
        var action: () -> Void = {}

        var body: some View {
            Button(action: action) {
                VStack(spacing: 1) {
                    if let icon {
                        Image(systemName: icon)
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: 13))
                    }
                    if !label.isEmpty {
                        Text(label)
                            .font(.system(size: 9, design: monospaced ? .monospaced : .default))
                            .lineLimit(1)
                    }
                }
                .frame(minWidth: 32, minHeight: 28)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(shortcutHint)
            .accessibilityLabel(shortcutHint)
        }

        private var shortcutHint: String {
            if let s = shortcut { return "\(label) (\(s))" }
            return label
        }
    }

    /// Toggle button with active state (filled vs outlined).
    private struct RibbonToggleButton: View {
        var label: String? = nil
        var weight: Font.Weight = .regular
        var italic: Bool = false
        var underline: Bool = false
        var strikethrough: Bool = false
        var monospaced: Bool = false
        var icon: String? = nil
        var isActive: Bool = false
        var shortcut: String? = nil
        var action: () -> Void = {}

        var body: some View {
            Button(action: action) {
                VStack(spacing: 1) {
                    if let icon {
                        Image(systemName: icon)
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: 13))
                    } else if let label {
                        Text(label)
                            .font(.system(size: 13, weight: weight, design: monospaced ? .monospaced : .default))
                            .italic(italic)
                            .underline(underline)
                            .strikethrough(strikethrough)
                    }
                    if let shortcut {
                        Text(shortcut)
                            .font(.system(size: 7))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 28, minHeight: 28)
                .padding(.horizontal, 4)
                .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isActive ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label ?? icon ?? "")
        }
    }

    /// Style picker button (Normal / Heading 1 / Heading 2 / Heading 3).
    private struct StyleButton: View {
        let label: String
        var level: Int? = nil
        var isActive: Bool = false
        let action: () -> Void

        private var font: Font {
            if let l = level {
                return .system(size: CGFloat(18 - l * 2), weight: .semibold)
            }
            return .system(size: 12)
        }

        var body: some View {
            Button(action: action) {
                Text(label)
                    .font(font)
                    .foregroundStyle(isActive ? Color.accentColor : .primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
                    .cornerRadius(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(isActive ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        }
    }

}

// MARK: - ToolbarButton

/// A simple text-based toolbar button with an active state.
struct ToolbarButton: View {
    let label: String
    var weight: Font.Weight = .regular
    var italic: Bool = false
    var underline: Bool = false
    var strikethrough: Bool = false
    var monospaced: Bool = false
    var isActive: Bool = false
    var shortcut: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(label)
                    .font(.system(
                        size: 13,
                        weight: weight,
                        design: monospaced ? .monospaced : .default
                    ))
                    .italic(italic)
                    .underline(underline)
                    .strikethrough(strikethrough)
                if let shortcut {
                    Text(shortcut)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 28, minHeight: 22)
            .padding(.horizontal, 4)
            .background(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ToolbarIconButton

/// An SF Symbol toolbar button.
struct ToolbarIconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .symbolRenderingMode(.hierarchical)
                .frame(minWidth: 24, minHeight: 22)
                .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - EditorCommand

/// The toolbar's command vocabulary. The toolbar emits
/// one of these for every action; the host converts the
/// command into a `Mutation` and routes it through the
/// `EditorCoalescer`. The enum is `Codable` so the
/// commands can be sent over the wire in a future
/// remote-editor scenario.
public enum EditorCommand: Codable, Equatable, Hashable {
    case toggleBold
    case toggleItalic
    case toggleUnderline
    case toggleStrikethrough
    case toggleCode
    case setBlockType(BlockType)
    case insertTable
    case insertImage
    case insertCodeBlock
    case insertCallout
    case toggleUnorderedList
    case toggleOrderedList
    case insertLink(URL)
    case removeLink
    // Alignment
    case alignLeft
    case alignCenter
    case alignRight
    case alignJustify
    // Font size
    case increaseFontSize
    case decreaseFontSize
    case setFontSize(Int)
    case setHeadingLevel(Int)
    // Paste
    case pastePlainText
    // Breaks
    case insertPageBreak
    case insertColumnBreak
    // Indent / outdent
    case indent
    case outdent
    // Sort
    case sortAscending
    case sortDescending
    // Insert tab
    case insertTableCustom
    case insertImageCustom
    case insertLinkCustom
    case insertHeader
    case insertFooter
    // Layout tab
    case setMargins(MarginPreset)
    case setOrientation(Orientation)
    case setColumns(Int)
    case setPageColor(String)
    // Review tab
    case toggleTrackChanges
    case showWordCount
    case showVersionHistory
    case insertComment
    case acceptChange
    case rejectChange
    case toggleCommentsPanel
    // View tab
    case toggleRuler
    case toggleGridlines
    case toggleLineNumbers
    case enterFocusMode
    // Find / Replace
    case showFindReplace
    case findNext
    case findPrevious
    case replaceNext
    case replaceAll
    // Spell check
    case spellCheck
    // Comment navigation
    case nextComment
    case previousComment
    // AI Rewrite (Phase 11 P2)
    case aiRewrite(mode: RewriteMode)
}

// MARK: - Ribbon-specific types

public enum MarginPreset: String, Codable, Hashable {
    case normal, narrow, wide, veryWide
}

public enum Orientation: String, Codable, Hashable {
    case portrait, landscape
}
