# P2-0 findings - Track C (Writer: note lifecycle, DocStore comment lifecycle)

Track ownership: `DocStore.swift`, `Editor/NoteController.swift` (new),
`TesseraStudioMac/Views/Docs/NotesSectionView.swift` (new),
`TesseraStudioMac/Views/Docs/DocDetailView.swift`. Items 1-3 of the P2-0
wave brief (footnote/endnote insert/delete lifecycle, endnote-section/
footnote-popover rendering, full DocStore comment lifecycle).

One row per suspected code bug found (not mine to fix) or scope note.

---

## Suspected code bug (not mine to fix - Block.swift is outside this track)

- **`DocumentAST.plainText()` (`Productivity/Block.swift` line ~740) leaks
  comment/reply text and pending track-change text into the agent chat
  context, unlike its own sibling `Doc.plainText(of:)`.**
  Verified at HEAD: `Block.swift`'s `DocumentAST.plainText()` is
  block-type-UNAWARE - it walks every block reachable from `rootChildren`
  and appends `block.content`'s joined text whenever it's non-empty, with
  no exclusion list at all. Its own doc comment says the opposite is the
  intent: "Used to build chat-prompt context sections so Tessy + Sky
  reason over the live document body **without seeing markup**."
  Compare `Doc.swift`'s `Doc.plainText(of:)` / `Doc.appendPlainText`
  (lines 174-223 of `Materials/Docs/Doc.swift`), which is the CORRECT
  version of the same idea: its switch statement explicitly excludes
  `.comment`, `.trackInsertion`, `.trackDeletion`, `.footnote`, `.endnote`
  (`case .toggle, .image, ..., .comment, .trackInsertion, .trackDeletion,
  .footnote, .endnote, .media: break`) - the same exclusion list
  `DocumentSearchIndex.appendEntries` deliberately mirrors for the same
  reason (its own file header: "mirrors `Doc.appendPlainText` exactly").
  `DocumentAST.plainText()` never got that treatment.
  **Confirmed live, not dead code:** `grep` for `.plainText()` call sites
  shows `DocsListView.swift:240`, `NotesView.swift:84`, and
  `SlidesListView.swift:247` all do
  `"<document>\n\(ast.plainText())\n</document>"` (or the `<note>`/
  `<slides>` equivalent) - this is exactly the chat-context-block
  construction the doc comment describes, and it is live for every
  material that has a `DocumentAST` body, not just Docs.
  **Why this matters for this track specifically:** `TesseraSTTextView
  .insertCommentBlock` (pre-existing, `TesseraEditorView.swift`) already
  inserted new root `.comment` blocks into `rootChildren` before this
  wave; my new `DocStore.addComment`/`.replyToComment` (item 3) use the
  identical tree shape (root `.comment` block in `rootChildren`, replies
  as its `children`) because that is the established, correct placement
  convention - I did not introduce the leak, but item 3 gives Docs a
  second, first-class way to create the exact block shape that triggers
  it, so it is more likely to be hit in practice now. A reviewer note
  left as a comment or a critique inside a comment thread ("this
  paragraph is wrong, rewrite it") would appear inline in the agent's
  `<document>` context as if it were the document's own prose; a pending
  `.trackDeletion` would appear as if it were still-live content even
  though the user marked it for removal.
  **Not touched:** `Block.swift` is outside this track's file list (owned
  by no P2-0 track this wave - it predates the wave). The fix is
  straightforward (port `Doc.appendPlainText`'s exclusion switch into
  `DocumentAST.plainText()`, or have `DocumentAST.plainText()` delegate to
  `Doc.plainText(of:)`'s logic directly) but is a cross-cutting change
  affecting Docs/Notes/Slides/Sheets chat context simultaneously, so it
  belongs to whichever track/gate owns `Block.swift` next.

## Scope notes (not bugs - contracts this track's file list could not reach)

- **The existing "New comment" UI flow still bypasses `DocStore` entirely.**
  `DocDetailView`'s `onInsertComment` calls
  `editorCoordinator.handleViewCommand(.insertComment)`, which routes to
  `TesseraSTTextView.insertCommentBlock` (`TesseraEditorView.swift`, not in
  this track's file list) - a pre-existing, purely in-memory mutation via
  `MutationEngine`/`Mutation.insertBlockAfter`, persisted only through the
  generic debounced `commitBody` -> `doc_body_changed` receipt. My new
  `DocStore.addComment`/`.replyToComment`/`.deleteComment` (item 3) are
  correct, tested, and emit the named receipts
  (`doc_comment_added`/`doc_comment_replied`/`doc_comment_deleted`), but
  nothing in the shipped UI calls them yet - only `resolveComment` was
  explicitly in scope for UI wiring per the wave brief, and that one now
  goes through `DocStore.resolveComment`. Wiring "New"/"Reply" to the new
  store methods needs either a `DocStore` reference threaded into
  `TesseraSTTextView` or a rework of `onInsertComment`'s callback shape in
  `TesseraEditorView.swift`/`TesseraEditorToolbar.swift` - both outside
  this track. Follow-up item for whichever track owns the editor surface
  next.
- **No UI trigger for `DocStore.insertNote`/`.deleteNote` (item 1) exists
  yet.** Item 2's brief scoped this track to RENDERING already-present
  footnotes/endnotes (`EndnotesSectionView`/`FootnoteReferencesStrip`,
  driven by `document.deriveNoteNumbering()` + `document.meta.notes`), not
  to adding an "Insert Footnote" toolbar command. Wiring that needs
  caret/selection state that only `TesseraEditorView`'s AppKit text view
  owns (not exposed through `TesseraEditorView.Coordinator`'s current
  public surface) - outside this track's files. The `DocStore` API and its
  `NoteController` decision logic are complete and fully tested
  (`NoteControllerTests.swift`, `DocStoreTests.swift`) and ready for a
  future editor-track wave to call.
- **Footnote "anchored near its reference mark" is approximated, not
  literal.** Per the design contract
  (`studio-expansion-design-refinement-2026-08-14.md`, item 1.2): "v1
  renders an endnotes section + popover; bottom-of-page placement waits
  for the paginator - TextKit 2 exclusion-path reservation is documented
  crash-prone and is explicitly not attempted." True glyph-level
  anchoring inside `TesseraTextContentManager`'s text flow needs that same
  paginator context and lives in files outside `Views/Docs/`.
  `FootnoteReferencesStrip` (this track's new file) instead renders a row
  of tappable markers directly under the editor body, in document
  reference order, each with a real popover showing the note's own
  content - the closest a file-scoped SwiftUI surface gets without that
  paginator work. Documented in the file's own header; not a stub, just a
  bounded interpretation of "at minimum a tappable/hoverable popover".

## Testing-doctrine gating note (rule 11, mirrors the writer-cluster precedent)

`DocStore` has no seam other than a live `TesseraDataLayer` (no fake/stub/
in-memory data layer exists anywhere in this codebase - same situation
`test-rewrite-findings-writer.md` already documented for the rest of
`DocStoreTests.swift`). The new `insertNote`/`deleteNote`/`addComment`/
`replyToComment`/`resolveComment`/`deleteComment` gated tests follow the
same `TESSERA_DB_INTEGRATION=1` gate as every other `DocStoreTests.swift`
method. Their ungated shadows:
- `insertNote`/`deleteNote`'s full decision logic lives in the new, pure
  `NoteController` (`Editor/NoteController.swift`) and is fully covered by
  `NoteControllerTests.swift` with no data layer at all.
- `addComment`/`deleteComment`'s block-tree surgery (`insertCommentRoot`/
  `removeCommentSubtree`) is `internal` (not `private`) on `DocStore`
  specifically so `DocStoreTests.swift` can exercise it directly via
  `@testable import` with no data layer - see that file's "Comments:
  ungated shadow of the block-tree helpers" section. `replyToComment`/
  `resolveComment`'s own decision logic (target-validity guards, the
  idempotence check) is a few lines inline in each method; given the
  method bodies are otherwise dominated by `loadOrFail`/`persist`/
  `appendReceipt` (which genuinely need the data layer), no further
  extraction was worth a second pure-logic type for two guard clauses -
  the gated tests exercise those guards directly by their observable
  effect (zero new receipts).
