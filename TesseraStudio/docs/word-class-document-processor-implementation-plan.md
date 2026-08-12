# Tessera Pages: Word-Class Document Processor
## Full Implementation Plan

---

## 1. Research Synthesis

### What Microsoft Word Actually Ships (2024)

**Document lifecycle:**
- Session recovery — auto-reopens unsaved documents after crash
- Auto-save with timestamped versions
- Document Recovery pane
- Export to DOCX, PDF, ODF 1.4, EPUB, RTF, TXT

**Ribbon tabs (standard Word layout):**
```
Home | Insert | Draw | Design | Layout | References | Mailings | Review | View
```

Each tab has named groups with 3–5 commands. Groups have separators. The first tab is always Home.

**Home tab groups:**
- Clipboard | Font | Paragraph | Styles | Editing

**Insert tab groups:**
- Pages | Tables | Illustrations | Links | Header & Footer | Text | Symbols

**Layout tab groups:**
- Page Setup | Page Background | Paragraph | Arrange

**Review tab groups:**
- Proofing | Comments | Tracking | Changes | Compare | Protect

**View tab groups:**
- Views | Zoom | Show | Panes | Window | Macros

**Real Word 2024 features:**
- Modern comments (blue dot for new, Like reaction, reply threads)
- Editing / Reviewing / Viewing mode switcher (not markup always-on)
- Delete all resolved comments at once
- Copilot AI: draft, summarize, rewrite, tone adjustment (cloud-only, $20/mo)
- Predictive text with Tab to accept (ghost text)
- Coaching with Copilot (grammar, clarity)
- ODF 1.4 import/export
- Session recovery after crash

**What Word users actually complain about (37+ real pain points):**
1. **Format drift** — documents formatted differently across devices/versions
2. **Slow with large files** — images, tables, tracked changes slow everything
3. **Image placement destroys layout** — single image disrupts whole page
4. **Table alignment is a nightmare** — inconsistent widths, row breaks
5. **Track Changes defaulting to markup** — forces users to toggle off
6. **Comment balloons outside the pane** — disorienting spatial layout
7. **Multi-level modal dialogs (Windows 95 era)** — can even resize some
8. **Ruler doesn't match print dimensions** — confusing measurements
9. **Font changes on paste or Enter** — no consistent default
10. **Tab stops per-line, not per-style** — no global control
11. **QAT (Quick Access Toolbar) removal** — Undo button gone breaks workflows
12. **Ribbon tabs non-searchable** — can't find "Bookmark" across 7 tabs
13. **Track Changes vs Markup confusion** — unclear when changes are tracked
14. **Styles sidebar goes blank** — ghost invisible entries

### Pages vs Word (competitive gap)

| Feature | Pages | Word | Tessera Status |
|---|---|---|---|
| Ribbon (true Office layout) | ❌ flat toolbar | ✅ | ⚠️ stubbed |
| Track Changes (default OFF) | ❌ none | ✅ | ⚠️ command exists |
| Comments with replies | ✅ | ✅ | ❌ |
| Table cell editing | ✅ decent | ❌ terrible | ❌ |
| Image wrapping | ✅ good | ❌ terrible | ❌ |
| Style system | ✅ basic | ✅ deep | ❌ |
| Headers/footers per section | ❌ | ✅ | ❌ |
| Cross-references | ❌ | ✅ | ❌ |
| Table of contents | ✅ | ✅ | ❌ |
| Mail merge | ❌ | ✅ | ❌ |
| Export to EPUB | ✅ | ❌ | ❌ |
| Local-first (no cloud) | ✅ | ❌ | ✅ |
| AI (on-device) | ✅ Apple Intelligence | ❌ cloud-only | ⚠️ opt-in |
| Keyboard shortcuts | ✅ | ✅ deep | ⚠️ partial |

### What "World-Class" Actually Means

From competitive analysis of Ulysses, Craft, Bear, Obsidian, and Apple Notes — the world-class document editors share:
1. **Friction-free capture** — zero setup to first word
2. **Typewriter mode** — current line stays centered vertically
3. **Syntax/draft/word count always visible** — status bar is a feature
4. **Style system that makes sense** — heading cascade, not 47 styles
5. **Local-first** — files are yours, no vendor lock-in
6. **Markdown compatibility** — notes export cleanly
7. **AI that stays local** — Apple Intelligence wins here over Copilot
8. **Focus mode that actually works** — chrome gone, word count visible
9. **Find & Replace that works** — including regex
10. **Undo that always works** — Ctrl+Z is sacred

---

## 2. Architecture

### Current State

```
TesseraEditorToolbar (ribbon)
  └─ Home | Insert | Layout | Review | View tabs
       └─ RibbonToggleButton, RibbonButton, StyleButton

TesseraEditorView (NSViewRepresentable)
  └─ TesseraSTTextView (STTextView subclass)
       └─ TesseraTextContentStorage (NSTextContentStorage)
            └─ TesseraTextContentManager (NSTextContentManager)
                 └─ TesseraTextContentManagerData (DocumentAST)
```

**What's wired:**
- Line Numbers toggle → STTextView.showsLineNumbers ✅
- Ruler toggle → NSRulerView on scrollView ✅
- Gridlines toggle → STTextView.showsInvisibleCharacters ✅
- Focus Mode → chrome fades, Escape exits ✅
- Track Changes button (inactive) ✅

**What's stubbed (commands fire, nothing happens):**
- Bold / Italic / Underline / Strikethrough / Code
- All alignment commands
- All list commands (bullet, numbered)
- All insert commands (table, image, code block, link, etc.)
- All layout commands (margins, orientation, columns)
- All review commands (comments, accept/reject)
- Heading styles (H1/H2/H3)
- Undo/Redo

### Architecture Decision: Where Mutations Flow

The mutation pipeline for text formatting:

```
Ribbon button tap
  → EditorCommand.emitted
  → DocDetailView.handleEditorCommand(command)
  → TesseraEditorView.Coordinator.handleViewCommand(command)
  → TesseraSTTextView.applyAttribute(attributedString)
  → NSText.didChangeNotification
  → Coordinator.textDidChange()
  → TextEditReducer.reduce()
  → EditorCoalescer.append()
  → Mutation applied to DocumentAST
  → viewModel.commitBody(ast)
```

The critical path: `handleViewCommand` must apply the text attribute directly to the STTextView's `NSAttributedString`, then the change notification propagates through the reducer → coalescer → AST pipeline. This is the same path that user typing already uses. The formatting mutations don't skip the pipeline — they flow through it.

### New Types Required

```swift
// Text attributes that can be applied via toolbar
struct TextAttributes: OptionSet {
    case bold
    case italic
    case underline
    case strikethrough
    case code
    case subscript
    case superscript
}

// Block/node types
enum BlockType {
    case paragraph
    case heading(Int level)  // 1-9
    case bulletList
    case numberedList
    case blockquote
    case codeBlock
    case table
    case image(url: URL)
    case horizontalRule
}

// Document styles (Word-style style sheet)
struct DocumentStyle: Identifiable {
    let id: UUID
    let name: String
    let basedOn: UUID?   // style inheritance
    let nextStyle: UUID?  // Enter creates next style
    var fontName: String
    var fontSize: CGFloat
    var fontWeight: FontWeight
    var fontColor: NSColor
    var paragraphSpacing: CGFloat
    var lineSpacing: CGFloat
    var headingNumbering: Int?  // for multi-level lists
}

// Table support
struct TesseraTable {
    var columns: [TableColumn]
    var rows: [[TableCell]]  // [row][column]
    var style: TableStyle
    struct TableColumn { var width: CGFloat? }
    struct TableCell { var content: NSAttributedString }
    struct TableStyle {
        var borderWidth: CGFloat
        var borderColor: NSColor
        var cellPadding: CGFloat
        var headerRow: Bool
    }
}
```

---

## 3. Implementation Phases

### Phase 1: Document Lifecycle (Foundation)

**Goal:** Never lose work. Auto-save, session recovery, version history.

**Implement:**
- [ ] Debounced auto-save: `Timer` debounce (2s after last edit), write to Postgres via `DocStore.commitBody`. Status bar shows "Saving…" → "Saved" with timestamp.
- [ ] Session recovery: On launch, check for dirty in-memory state in `NoteEditorViewModel`/`DocEditorViewModel`. If found (app crashed), prompt "Restore unsaved changes?" with preview.
- [ ] Version history: Store `doc.updatedAt` snapshots. Add `DocStore.loadVersions(docID)` returning `[(id: UUID, timestamp: Date, wordCount: Int)]`. Show in a side panel.
- [ ] Export panel: DOCX (via `textutil` or `DocXWriter`), PDF (via `NSPrintOperation`), ODF 1.4, RTF, TXT.
- [ ] Import DOCX/ODF: Use `NSAttributedString.DocumentType` for reading, map to `DocumentAST`.

**Pain points solved:** Word 2024's #1 feature is session recovery. This is table stakes.

---

### Phase 2: Text Formatting Pipeline (P0 — Everything Else Depends on This)

**Goal:** Bold, Italic, Underline, Strikethrough, Code fire and stick.

**Implement:**

**2a. Apply attributes to STTextView (view-level)**

STTextView's `textStorage` is a `TesseraTextContentStorage` → `NSMutableAttributedString`. Apply attributes:

```swift
extension TesseraSTTextView {
    func applyFormatting(_ attrs: TextAttributes, to range: NSRange) {
        let textStorage = (textContentManager as? NSTextContentStorage)?.textStorage ?? return
        textStorage.beginEditing()
        if attrs.contains(.bold) {
            textStorage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: range)
        }
        if attrs.contains(.italic) {
            textStorage.addAttribute(.font, value: NSFont.systemFont(ofSize: 14, weight: .regular).withTraits(.italicFontMask), range: range)
        }
        if attrs.contains(.underline) {
            textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        if attrs.contains(.strikethrough) {
            textStorage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        if attrs.contains(.code) {
            textStorage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: range)
            textStorage.addAttribute(.backgroundColor, value: NSColor.textBackgroundColor, range: range)
        }
        textStorage.endEditing()
        invalidateTextContainerOrigin()
    }
}
```

**2b. Wire EditorCommand to attributes**

```swift
case .toggleBold:
    guard let tv = textView as? TesseraSTTextView else { return }
    let range = tv.selectedRange()
    if range.length == 0 {
        // Toggle typing attributes (typing attributes are stored separately)
        tv.typingAttributes[.font] = currentBold ? regularFont : boldFont
    } else {
        MainActor.assumeIsolated {
            tv.applyFormatting(.bold, to: range)
        }
    }
    formattingState.isBold.toggle()
```

**2c. Read attributes on selection change (update FormattingState)**

STTextView has `NSTextViewTextDidChangeSelectionNotification`. In the coordinator:

```swift
@objc func selectionDidChange(_ note: Notification) {
    guard let tv = textView, let ts = tv.textContentManager as? NSTextContentStorage else { return }
    let range = tv.selectedRange()
    guard range.length > 0 else { return }
    let attrs = ts.textStorage?.attributes(at: range.location, effectiveRange: nil) ?? [:]
    var state = FormattingState()
    if let font = attrs[.font] as? NSFont {
        state.isBold = font.fontDescriptor.symbolicTraits.contains(.bold)
        state.isItalic = font.fontDescriptor.symbolicTraits.contains(.italic)
    }
    state.isUnderline = (attrs[.underlineStyle] as? Int) != nil
    state.isStrikethrough = (attrs[.strikethroughStyle] as? Int) != nil
    // Send to host to update toolbar
    onFormattingStateChanged?(state)
}
```

**2d. Font size (Ctrl+] / Ctrl+[)**

```swift
case .increaseFontSize:
    let range = tv.selectedRange()
    let currentFont = (ts.textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? NSFont.systemFont(ofSize: 14)
    let newSize = min(currentFont.pointSize + 1, 512)
    tv.applyAttribute(.font, value: NSFont.systemFont(ofSize: newSize), to: range)
```

**2e. Alignment**

```swift
case .alignLeft:
    MainActor.assumeIsolated {
        textView?.setAlignment(.left)
    }
```

**Deliverable:** Bold, Italic, Underline, Strikethrough, Code, Font size, Alignment all fire and persist. Toolbar buttons highlight correctly from selection.

---

### Phase 3: Lists and Paragraph Styles

**Goal:** Bullet lists, numbered lists, heading cascade (H1→H2→H3), paragraph spacing.

**Implement:**

**3a. Heading styles**

Add `BlockType.heading(Int)` handling in `TextEditReducer`. Headings render at decreasing font sizes (H1: 28pt bold, H2: 22pt semibold, H3: 18pt semibold). Add to `DocumentStyle` system.

**3b. List insertion**

```swift
case .toggleUnorderedList:
    // Check current block type at cursor
    // If already a bullet list: remove list marker
    // If paragraph: insert bullet character (\u{2022}) at line start, set list style
case .toggleOrderedList:
    // Insert numbering (\u{31}.\t) at line start
```

For proper rich text lists: add custom `NSTextList` with `markerFormat`. STTextView/NSTextView support `NSTextList`.

**3c. Style picker in Home tab**

`StyleButton` already exists. Wire `setBlockType(.heading)` to apply heading attributes + update `BlockType` in AST.

**3d. Quick Style application (Ctrl+Shift+N = Normal, Ctrl+Alt+1/2/3 = Heading)**

These are Word's most-used shortcuts. Implement in `DocEditorView` via `onKeyPress`:

```swift
.onKeyPress(.one, modifiers: [.command, .option]) {
    applyStyle(.heading(1)); return .handled
}
.onKeyPress(.two, modifiers: [.command, .option]) {
    applyStyle(.heading(2)); return .handled
}
.onKeyPress(.three, modifiers: [.command, .option]) {
    applyStyle(.heading(3)); return .handled
}
.onKeyPress(.n, modifiers: [.command, .shift]) {
    applyStyle(.paragraph); return .handled
}
```

**3e. Ctrl+B/I/U as direct attribute application (not via command routing)**

Direct override in `TesseraSTTextView`:

```swift
override func keyDown(with event: NSEvent) {
    if event.modifierFlags.contains(.command) {
        switch event.charactersIgnoringModifiers {
        case "b": applyFormatting(.bold, to: selectedRange()); return
        case "i": applyFormatting(.italic, to: selectedRange()); return
        case "u": applyFormatting(.underline, to: selectedRange()); return
        case "]": increaseFontSize(); return
        case "[": decreaseFontSize(); return
        default: break
        }
    }
    super.keyDown(with: event)
}
```

---

### Phase 4: Tables

**Goal:** Insert table, cell navigation (Tab/Shift+Tab), resize columns, apply borders.

**Implement:**

**4a. TesseraTableView (NSTableView subclass)**

Custom `NSTableView` embedded in `NSScrollView`, rendered inside a block.

```swift
public final class TesseraTableView: NSView {
    public var table: TesseraTable
    public var onEdit: (TesseraTable) -> Void
    // NSTableView with one column per table column
    // Custom NSTableCellView for inline editing
}
```

**4b. BlockType.table insertion**

```swift
case .insertTableCustom:
    // Show NSTableView picker: N cols × M rows
    // Insert as BlockType.table in DocumentAST
```

**4c. Tab/Shift+Tab cell navigation**

Override `controlTextDidChange` in cell view. On Tab: save current cell, move to next cell (or new row if at end). NSTableView already handles this with the right delegate.

**4d. Column resize**

`NSTableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle`. Add `NSTableColumn.resizingMask` for user drag.

**4e. Table borders**

Use `NSTableView.backgroundColor` + draw border in `draw(_:)`. Word-style borders (inside/outside/all/none).

**4f. Table → AST serialization**

Tables serialize to `DocumentAST` as `Block.node = .table(TesseraTable)`. When rendered, a `TesseraTableView` replaces the block in the scroll view.

**Pain points solved:** Users' #1 complaint about Word is table alignment. Our table uses native NSTableView which is inherently better-behaved than Word's OLE-based table model.

---

### Phase 5: Images and Media

**Goal:** Insert image with inline wrapping, resize handles, caption, border, alignment.

**Implement:**

**5a. Image insertion (drag-drop + File > Insert)**

- File picker: `NSOpenPanel` for images (PNG, JPEG, HEIC, GIF, WebP, TIFF, PDF)
- Read into `NSImage`, resize to max 2000px width, store in app data dir
- Insert as `BlockType.image(url:)` in AST
- Render as `NSImageView` with resize handles

**5b. Text wrapping (Word-style)**

NSTextView supports `NSTextAttachment` with `NSTextAttachmentCell`. Wrap image in `NSTextAttachment`:

```swift
let attachment = NSTextAttachment()
attachment.image = resizedImage
let attrStr = NSAttributedString(attachment: attachment)
```

Wrapping options (Word-style): In Line with Text, Square, Tight, Through, Top and Bottom, Behind Text.

**5c. Inline image resize**

`NSTextAttachment` image size controlled by `attachment.bounds`. Add resize handles (custom `NSView` overlay). Constrain to aspect ratio by default.

**5d. Image formatting panel**

Contextual tab: image border color, border width, crop, brightness/contrast (Core Image filters).

**5e. Caption**

Auto-generate "Figure N:" caption below image. Link to table of figures.

**Pain points solved:** Word's #3 user complaint — image placement destroys layout. Our text wrapping via NSTextAttachment is the correct TextKit 2 approach and won't corrupt the document.

---

### Phase 6: Page Layout

**Goal:** Margins, orientation, columns, headers/footers, page size.

**Implement:**

**6a. Page size and margins**

Store in `DocumentMetadata`:
```swift
struct DocumentMetadata {
    var pageWidth: CGFloat = 612   // 8.5" at 72dpi
    var pageHeight: CGFloat = 792  // 11" at 72dpi
    var leftMargin: CGFloat = 72   // 1"
    var rightMargin: CGFloat = 72
    var topMargin: CGFloat = 72
    var bottomMargin: CGFloat = 72
    var orientation: Orientation = .portrait
}
```

Layout tab buttons: setMargins(.narrow/.normal/.wide), setOrientation(.portrait/.landscape).

**6b. Multi-column layout**

Word supports 1, 2, 3 columns with optional line between. Implement via `NSTextColumn` in TextKit 2. `TesseraTextContentStorage` already supports multi-column via its `NSTextContainer` array. This is mostly configuration.

**6c. Headers and footers**

`TesseraTextContentStorage` needs a header/footer storage layer:

```swift
struct HeaderFooterContent {
    var headerFirst: NSAttributedString?
    var headerDefault: NSAttributedString?
    var footerDefault: NSAttributedString?
}
```

Rendered by `NSTextView`'s `headerView`/`footerView` (NSScrollView already supports these).

**6d. Section breaks**

`BlockType.sectionBreak(SectionBreakType)` where `type` is Next Page / Continuous / Even Page / Odd Page. Controls page layout per section.

---

### Phase 7: Collaboration — Comments and Track Changes

**Goal:** Modern comments (Word 2024 style), Track Changes off by default, Accept/Reject.

**Implement:**

**7a. Comments panel (right sidebar)**

`CommentsSidebarView`: shows comment threads anchored to document positions. Each comment:
```swift
struct Comment: Identifiable {
    let id: UUID
    let authorID: UUID
    let authorName: String
    let body: NSAttributedString
    let timestamp: Date
    var resolved: Bool
    var replies: [Comment]
    var anchorBlockID: UUID  // which block this is anchored to
}
```

Render comment marker in text as `CommentInlineMarker` (underline + color). Click marker → highlight comment in sidebar. Sidebar shows blue dot for new comments (Word 2024 style).

**7b. Track Changes (default OFF)**

`DocumentMetadata.trackChangesEnabled = false` (default). Review tab toggle. When on:
- Insertions: underlined in author color
- Deletions: shown in red strikethrough (deleted text kept but marked)
- Moves: double-underline

`DocumentAST` needs a `TrackedChange` type:
```swift
struct TrackedChange: Identifiable {
    let id: UUID
    let type: ChangeType  // .insertion/.deletion/.formatChange/.move
    let authorID: UUID
    let timestamp: Date
    let range: NSRange
    var accepted: Bool?
    var originalText: String?
}
```

**7c. Accept/Reject all**

`case .acceptChange` / `.rejectChange` in ribbon. Batch operations:
- Accept All: apply all insertions, remove all deletions, clear change list
- Reject All: apply all deletions, remove all insertions

**7d. Like reactions**

Add `var likedBy: [UUID]` to Comment. Like button in sidebar.

**Pain points solved:**
- Word complaint #1: "Word consistently opens with comments and markup displayed" → default OFF ✅
- Word complaint #6: "confusion between markup changes and tracked changes" → clear mode switcher (Editing / Reviewing / Viewing)

---

### Phase 8: Find & Replace

**Goal:** Ctrl+F, Ctrl+H, regex support.

**Implement:**

**8a. Find panel (floating)**

`NSSearchField` + results list. STTextView has `isIncrementalSearchingEnabled`. Wire:
```swift
case .showFind:
    // Show find panel
    NSPresentSearchSheet(in: textView.window) { ... }
```
`NSFindPanel` is the native macOS find panel. Use it.

**8b. Replace**

`NSFindPanel` already has replace UI. Wire `replaceAll` / `replace` / `replaceAndFind`.

**8c. Regex**

Add regex toggle in find panel. `NSRegularExpression` for matching. Highlight all matches in text view (temporary `NSBackgroundColorAttributeName`).

---

### Phase 9: Keyboard Shortcuts — The Full Set

**Goal:** Word's most-used shortcuts, all working.

**Critical shortcuts (Ctrl+Z/Y, Ctrl+B/I/U already covered):**

| Shortcut | Action | Implementation |
|---|---|---|
| Ctrl+Z | Undo | `textView.undoManager?.undo()` |
| Ctrl+Y / Ctrl+Shift+Z | Redo | `textView.undoManager?.redo()` |
| Ctrl+F | Find | `NSPresentSearchSheet` |
| Ctrl+H | Replace | `findPanel.replacementString = ...; show` |
| Ctrl+K | Insert hyperlink | Show link sheet |
| Ctrl+L | Align left | `setAlignment(.left)` |
| Ctrl+E | Align center | `setAlignment(.center)` |
| Ctrl+R | Align right | `setAlignment(.right)` |
| Ctrl+J | Justify | `setAlignment(.justified)` |
| Ctrl+] | Increase font size | `applyFontSize(delta: +1)` |
| Ctrl+[ | Decrease font size | `applyFontSize(delta: -1)` |
| Ctrl+Shift+> | Increase font size ×2 | `applyFontSize(delta: +2)` |
| Ctrl+Shift+< | Decrease font size ×2 | `applyFontSize(delta: -2)` |
| Ctrl+Shift+A | All caps | toggle case |
| Shift+F3 | Cycle case | lower → title → upper |
| Ctrl+Shift+L | Bullet list | `insertBullet()` |
| Ctrl+M | Increase indent | `setParagraphIndent(delta: +36)` |
| Ctrl+Shift+M | Decrease indent | `setParagraphIndent(delta: -36)` |
| Ctrl+Enter | Page break | `insertBlock(.pageBreak)` |
| Ctrl+Shift+Enter | Column break | `insertBlock(.columnBreak)` |
| F7 | Spell check | `NSSpellChecker.shared().checkSpelling(...)` |
| Alt+Shift+D | Insert date field | `insertField(.date)` |
| Alt+Shift+T | Insert time field | `insertField(.time)` |
| Ctrl+Alt+S | Split window | Not applicable (macOS multi-window) |
| Ctrl+Alt+P | Print Layout view | Not applicable (always print layout) |
| Ctrl+Alt+O | Outline view | Not applicable (no outline mode) |
| Ctrl+Alt+N | Draft view | Not applicable |

**Implementation approach:**

Override `keyDown(with:)` in `TesseraSTTextView`. For shortcuts that STTextView already handles (undo, redo, bold, italic, underline), let `super.keyDown(with:)` handle them. For ones STTextView doesn't handle (Ctrl+K, Ctrl+L, Ctrl+J, etc.), intercept and handle.

---

### Phase 10: Performance — Large Documents

**Goal:** 100+ page documents stay fast.

**Implement:**

**10a. Lazy block rendering**

`DocumentAST` is a tree of blocks. Only render blocks currently in the viewport + 2 screens of buffer. On scroll, load/unload block content.

**10b. Async image loading**

Images load on background queue, display placeholder (gray rect) until loaded.

**10c. Virtualized list for long documents**

`NSTextView` already handles this via `NSTextContainer` viewport management. Ensure `NSTextContainer.widthTracksTextView` is correct. For very long documents (>1000 blocks), consider a custom `NSLayoutManager` subclass that defers layout for off-screen text.

**10d. Debounced AST updates**

`TesseraTextContentManager` currently updates on every keystroke. Batch updates: only call `setDocument` on the storage after 500ms of inactivity or when the user pauses.

---

### Phase 11: AI Layer (Tessera-native)

**Goal:** On-device Granite-powered AI that enhances writing without being a cloud dependency.

**Implement:**

**11a. Writing suggestions (ghost text)**

As the user types, Granite generates a completion. Display in `NSTextView` as ghost text (`.foregroundColor: NSColor.textColor.withAlphaComponent(0.4)`). Tab to accept. Escape or continue typing to dismiss.

Implementation: debounce 300ms after last keystroke. Send last 2000 chars to Granite. Return top-1 completion. Render in text view by extending the attributed string's range with gray color. On Tab: delete ghost range, insert completion text.

**11b. Rewrite / Improve**

User selects text → ribbon Review tab shows "Improve" / "Shorten" / "Expand" / "Change Tone". Send selection + instruction to Granite. Replace selection with result.

**11c. Summarize**

Review tab: "Summarize" button. Send document to Granite, return 3-sentence summary. Show in sidebar.

**11d. Proofread**

`NSSpellChecker` + Granite for grammar. `NSSpellChecker.shared.checkGrammar(...)` gives spelling + grammar ranges. Granite improves grammar suggestions.

**11e. AI opt-in (already done in Phase 5)**

`aiEnabled` defaults to `false`. `aiRoute` defaults to `"local"`. Route chip shows Granite · Local or Cloud. No telemetry to cloud unless user opts in.

---

### Phase 12: Accessibility and Polish

**Goal:** Screen reader support, keyboard navigation, VoiceOver labels.

**Implement:**

- All ribbon buttons: `.accessibilityLabel()`, `.accessibilityHint()`
- Tables: `accessibilityRole = .table`, cells have row/column labels
- Comment markers: `accessibilityLabel = "Comment by [author]: [preview]"`
- Focus rings on all interactive elements
- Respect `NSAccentColor` for active state (already done)
- Dynamic Type support: scale font sizes based on `NSApplication.shared.preferredContentSizeCategory`
- Reduce Motion: disable all animations when `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`

---

## 4. Implementation Order (Prioritized)

```
Phase 2  ← P0 — everything else depends on the formatting pipeline
Phase 3  ← P0 — heading styles are the second thing users reach for
Phase 1  ← P1 — session recovery is table stakes
Phase 9  ← P1 — keyboard shortcuts make or break a word processor
Phase 8  ← P1 — Find & Replace is a daily-use feature
Phase 4  ← P2 — tables are complex but necessary for academic docs
Phase 5  ← P2 — images are common
Phase 6  ← P2 — headers/footers are needed for formal docs
Phase 7  ← P2 — comments need a sidebar + track changes off by default
Phase 11 ← P2 — AI is additive, not the core
Phase 10 ← P3 — large doc perf is a polish concern
Phase 12 ← P3 — accessibility is always last
```

---

## 5. Critical Design Decisions

**Decision 1: Format attributes vs AST blocks**

The `DocumentAST` stores structural blocks (heading, list, table, image, paragraph). Text formatting (bold, italic) is stored in the attributed string rendered by `TesseraTextContentStorage`. The AST's `InlineNode` array maps character ranges to inline styles. The attributed string IS the truth for inline formatting; the AST encodes it structurally for AI context.

**Decision 2: Styles are first-class**

Word's style system is the foundation of its document model. We add `DocumentStyle` as a named, inheritable style with font/size/spacing/paragraph attributes. The Styles pane shows all styles. User-defined styles persist to `DocumentMetadata.styles[]`.

**Decision 3: Track Changes default OFF**

This is a direct fix for the #1 Word complaint. `DocumentMetadata.trackChangesEnabled = false` is the default. The ribbon's Review tab shows the current state. Users who want track changes turn it on explicitly.

**Decision 4: Tables use NSTableView**

Not a custom grid. NSTableView's column resize, cell editing, and row/column management are all native. We wrap it in a `NSScrollView` and treat the whole table as one block in the AST.

**Decision 5: Comments live in the sidebar, not inline**

Word's inline comment balloons are its most-hated UI element (#4 user complaint). Tessera puts comments in a resizable right sidebar. Comment markers in the text are unobtrusive underlines. Click to select → sidebar highlights the thread.

**Decision 6: Auto-save is the only save model**

There is no explicit Save button. The status bar shows "Saved" with timestamp. Cmd+S does nothing visible except re-confirm save. This is how Apple Notes, Craft, and Bear work. It's the right model for local-first.
