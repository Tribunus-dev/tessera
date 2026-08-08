# Phase 2 — Editor for the Tessera productivity surface

## Context

Tessera Studio is a privacy-first macOS + iOS app. Phase 1 of the productivity surface is on `feat/prod-foundations` (committed, tests pass). It shipped the Block AST, Mutation API, Receipt infrastructure (with ed25519 signing tied to `TesseraKeychainVolume`), ReceiptUndoManager, two-cursor data model, chat queue data model, and `DocumentStore`. Read the design doc at `docs/tessera-productivity-foundations-design.md` for the Phase 1 architecture.

The full productivity spec is at `docs/tessera-productivity-design.md` (1115 lines, on branch `feat/productivity-spec`). Sections §9 (Editor wrapping) and §8 (Animation primitives) are the canonical source for this work. **Read them first.**

Your job is Phase 2: the actual editor — the SwiftUI view that wraps the platform-native text view, backed by the Phase 1 AST. The view layer uses `STTextView` (krzyzanowskim) as the base, with a custom `TesseraTextContentManager : NSTextContentManager` that produces `TesseraTextElement : NSTextElement` per block. The agent's edits and the user's edits both go through the same `Mutation` API from Phase 1.

## Working environment

- Main checkout: `/Users/user/Developer/GitHub/tessera`
- Branch off `feat/prod-foundations` (the Phase 1 branch) — `git fetch . && git worktree add worktrees/prod-editor -b feat/prod-editor feat/prod-foundations`. Your branch depends on Phase 1.
- New code goes under `TesseraStudio/Sources/TesseraStudioMac/Views/Editor/` (new directory) and `TesseraStudio/Sources/TesseraCore/Editor/` (new directory, for shared editor primitives)
- Tests under `TesseraStudio/Tests/TesseraCoreTests/Editor/`
- Per AGENTS.md: no push, no PR. Use `Assisted-by: MiniMax` (NOT `Co-authored-by`).

## Phase 2 deliverables

### 1. TesseraTextContentManager : NSTextContentManager (TextKit 2)

The custom `NSTextContentManager` subclass that backs the editor. It produces `TesseraTextElement : NSTextElement` instances, one per Block in the AST.

```swift
public final class TesseraTextContentManager: NSTextContentManager, NSTextContentManagerDelegate {
    public init(document: DocumentAST)

    public var document: DocumentAST { get }
    public func applyMutation(_ mutation: Mutation) throws
    public func applyMutations(_ mutations: [Mutation]) throws

    public func textContentManager(_ textContentManager: NSTextContentManager,
                                   textElementAt location: NSTextLocation) -> NSTextElement?
    public func textContentManager(_ textContentManager: NSTextContentManager,
                                   shouldEnumerate textElement: NSTextElement,
                                   options: NSTextContentManager.EnumerationOptions = []) -> Bool
}
```

Maps each `Block` to a `TesseraTextElement`. Container blocks nest. For inline annotations, the element exposes the attributed string with the annotations.

**Tests:** content manager produces one element per block; container blocks nest; mutation apply updates the manager; empty document produces zero elements; 1000+ blocks enumerate in < 50ms.

### 2. TesseraTextElement : NSTextElement

```swift
public final class TesseraTextElement: NSTextElement {
    public let blockID: UUID
    public let blockType: BlockType
    public let attributedString: NSAttributedString
    public let elementRange: NSTextRange
    public init(block: Block, range: NSTextRange)
}
```

Per-block-type rendering (paragraph/listItem/quote/callout/tableCell → inline runs; heading → font/weight by level; codeBlock → monospaced with Splash highlighting; image → NSTextAttachment; etc.).

**Tests:** each block type produces a valid NSAttributedString; inline annotations render correctly; code blocks highlight per language; image blocks produce NSTextAttachment.

### 3. STTextView integration

```swift
public final class TesseraEditorView: NSViewRepresentable {
    public init(document: DocumentAST, binding: Binding<DocumentAST>)
    public func makeNSView(context: Context) -> STTextView
    public func updateNSView(_ nsView: STTextView, context: Context)
}
```

STTextView (krzyzanowskim) as the base — TextKit 2, line numbers, find, multi-cursor. iOS uses STTextView's iOS implementation with UIViewRepresentable.

**Tests:** view constructs; update propagates; line numbers appear; find bar opens on Cmd-F.

### 4. Two-cursor model (per architect direction)

```swift
public struct EditorCursorState {
    public var userCursor: NSTextLocation?
    public var agentCursor: NSTextLocation?
    public var userSelection: NSTextRange?
    public var agentSelection: NSTextRange?
}
```

User cursor = standard system caret. Agent cursor = small robot icon, subtle blue background, 530ms blink when active. Both can coexist; user can move independently.

**Tests:** user can move independently; agent cursor doesn't move user cursor; both cursors can be in the same paragraph.

### 5. User edits as Mutation (per architect direction)

User typing/formatting/paste must be expressed as a `Mutation` (not raw attributed string). A "text view did change" handler converts edits to `Mutation` operations, dispatched via the Phase 1 `MutationEngine`. A coalescing window (1.5s default, 0.5-5.0s user setting) groups a burst into one batched mutation. The user edit is also enqueued in the chat queue as a `ChatQueueItem` with `sourceMutation` set.

**Tests:** typing produces coalesced mutations; formatting produces setInlineAnnotation; paste produces setBlockContent; 10 keystrokes in 1s = 1 mutation; the chat queue gets the corresponding item.

### 6. RichTextKit integration

```swift
public struct TesseraEditorToolbar: View {
    public init(editor: TesseraEditorView, formattingState: Binding<FormattingState>)
    public var body: some View  // RichTextKit toolbar + custom block-type buttons
}
```

Bold/italic/underline/strikethrough (RichTextKit), heading level picker (custom), bullet/numbered list, link insertion, color picker, custom: Insert table/image/code block/callout. All actions go through the Mutation API.

**Tests:** toolbar actions produce correct mutations; state reflects selection formatting.

### 7. Animation primitives (7 from spec §8)

| Primitive | Trigger | Duration | Easing | Reduce Motion fallback |
|---|---|---|---|---|
| Block slide-in | New block created | 250ms | .easeOut | Crossfade only |
| Block replace | Block replaced | 300ms | .easeInOut | Crossfade only |
| Block delete collapse | Block deleted | 200ms | .easeIn | Instant removal |
| Text appear | Agent's text inside a block | 60ms/char (default) | .linear | Whole text at once |
| Cursor blink | Text view focus | 530ms cycle | N/A | Static caret |
| Thinking pulse | Agent in tool-call/retrieval | 1000ms cycle | spring (0.5, 0.7) | Static dot |
| Agent paused banner | "Hold your horses" pause | 200ms | .easeOut | Instant appearance |

All interruptible. SwiftUI withAnimation. Text cadence via async stream.

**Tests:** each has correct duration; Reduce Motion switches to fallback; animations interruptible; cadence respects user setting.

### 8. Code block syntax highlighting (Splash)

Add `https://github.com/JohnSundell/Splash` to `TesseraStudio/Package.swift`. For `.codeBlock` blocks, if `attributes.language` is set, run Splash's highlighter and apply the resulting styles. Languages: Swift, Python, JavaScript/TypeScript, SQL, JSON, YAML, Markdown, Shell, Rust, Go.

**Tests:** each language highlights; unknown language falls back to monospaced; colors consistent with theme.

### 9. Receipt-aware undo (consume Phase 1's ReceiptUndoManager)

Cmd-Z pops the top receipt, computes the inverse, applies via MutationEngine, the new "undo" receipt's ID is set as the original's `voidedBy`. Cmd-Shift-Z redoes. Wire to the standard macOS Edit menu via NSResponder.undoManager; the menu shows the receipt's `summary` as the action name.

**Tests:** Cmd-Z undoes; menu shows summary; voided receipts don't appear as candidates.

### 10. Editor surface in the Materials slice

The same `TesseraEditorView` is the canvas for Documents, Notes, and Code. Per-surface configuration. Phase 5 wires the per-surface wrappers.

**Tests:** same view works for Documents/Notes/Code (parameterized by `EditorMode`).

### 11. Library survey

| Need | Library | Decision |
|---|---|---|
| Modern TextKit 2 view | `STTextView` (krzyzanowskim) | **Adopt** — base for ALL editor surfaces |
| SwiftUI toolbar | `RichTextKit` (Daniel Saidi) | **Adopt** — composes with STTextView |
| AST-backed NSTextContentManager | none | **Build** |
| Syntax highlighting | `Splash` (JohnSundell) | **Adopt** |
| Markdown rendering (Notes) | `MarkdownUI` (gonzalezreal) | **Adopt** for Notes |

Document any deviation in the design doc §11.

### 12. Design doc

Write `docs/tessera-productivity-editor-design.md` (same shape as the other specs). Sections: 1) Problem, 2) Why this design, 3) Editor architecture diagram, 4) TesseraTextContentManager + TesseraTextElement, 5) STTextView integration, 6) Two-cursor implementation, 7) User edits as Mutation, 8) RichTextKit toolbar, 9) Animation primitives, 10) Code block syntax highlighting, 11) Receipt-aware undo consumption, 12) Test strategy, 13) Out of scope.

## Hard constraints

- One text view engine for ALL editor surfaces (Documents/Notes/Code). Per-surface differences are configuration, not different code paths.
- TesseraTextContentManager is the single source of truth.
- All edits (user + agent) go through the Phase 1 Mutation API.
- 619 existing tests stay green.
- Per AGENTS.md: `Assisted-by: MiniMax`, no push, no PR.

## Out of scope

- Phase 3: chat panel UI, receipt drawer UI, "Hold your horses" dialog
- Phase 4: importers/exporters
- Phase 5: per-Materials-surface wrappers
- Phase 6: Contacts + Graph viz
- LSP integration (v2), real-time collaboration (v2), terminal integration (v2)

## Worker report

Files touched (with line counts); new tests (with pass/fail); library survey decisions; performance numbers (enumeration time for 1000+ blocks); punts; "how to use" snippet; screenshot/ASCII sketch of the editor with two cursors.

Branch: `feat/prod-editor`. Worktree: `worktrees/prod-editor/`. No push, no PR.
