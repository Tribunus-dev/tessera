# P2-0 findings - Track B (Slides+Draw: animation/media storage,
# gesture layer, group/ungroup)

Track ownership: `SlideDeck.swift`, `SlideStore.swift`, `MediaBlock.swift`,
`DrawingStore.swift`, `TransformController.swift`,
`TesseraStudioMac/Views/Draw/*` (new), `TesseraStudioMac/Views/Slides/
MediaPlaybackView.swift` (new). Items 1-5 of the P2-0 wave brief (1.20
deck storage + mutations, 1.4 media write path + AVKit playback, Draw
canvas gesture layer, group/ungroup, comment lifecycle on SlideStore).

One row per suspected code bug found (not mine to fix) or scope note.

---

## Suspected code bug (not mine to fix - ReceiptUndoManager.swift is
## outside this track)

- **`ReceiptUndoManager.group(_:)`'s doc comment promises grouped-undo
  in one Cmd-Z; the implementation does not deliver it.** Verified at
  the point this track wired the first real caller
  (`DrawCanvasView.registerUndo`, item 3). `ReceiptUndoManager.swift`'s
  own doc comment on `group(_:)`: "lets the caller batch multiple
  receipts into a single undo unit... a single Cmd-Z undoes the whole
  instruction, not the last step." The implementation:
  ```swift
  public func group(_ receipts: [Receipt]) {
      for r in receipts { ...; undoStack.append(r) }
      redoStack.removeAll()
      pendingVoidTarget = nil
  }
  ```
  appends the receipts as N ORDINARY, INDISTINGUISHABLE entries onto
  `undoStack` - there is no group-boundary marker anywhere in `Receipt`
  or in the manager's private state. `undo()` pops exactly ONE entry
  per call (`let original = undoStack.removeLast()`). So a 3-receipt
  `group(_:)` call requires 3 separate `undo()` calls (3 Cmd-Z presses)
  to fully unwind, not the one the doc comment promises - the opposite
  of "one drag = one undo unit" for anything the group grew past a
  single receipt.
  **Why this surfaced here specifically:** `group(_:)` had exactly one
  caller before this wave (`ReceiptUndoManagerTests.swift`, verified by
  grep before starting item 3) and that test only checks the STACK
  CONTENTS after grouping (`snapshotUndoStack()` length/order), never
  drives `undo()` enough times to observe the one-call-per-receipt
  behavior - so the mismatch between the doc comment and the
  implementation was never exercised end-to-end. `DrawCanvasView`
  (this track's new file) is the first real, non-test caller.
  **Impact on this track's own code:** none directly - `DrawCanvasView
  .registerUndo` calls `group(_:)` exactly as documented (that is the
  correct, contract-faithful call per testing-doctrine's "the TEST [or
  here, the caller] is presumed right until the architect rules");
  `DrawingStore.setGeometries` (this wave's new batched method) is the
  actual persisted audit record regardless of how many Cmd-Z presses
  the local `ReceiptUndoManager` chain ends up needing, so no data is
  at risk. This only affects the FUTURE editor-level Cmd-Z wiring for
  Draw (see the scope note below) once someone builds it.
  **Not touched:** `ReceiptUndoManager.swift` is outside this track's
  file list (a shared cross-cutting undo primitive, plausibly Track D's
  or a future wave's territory). A fix would need either a real group
  boundary in `Receipt`/the undo stack (e.g. a `groupID: UUID?` field,
  or storing `[[Receipt]]` instead of `[Receipt]`) or `undo()` peeking
  ahead for same-caller-batch receipts - a design decision for whoever
  owns that file next, not a one-line fix.

## Scope notes (not bugs - contracts this track's file list could not
## reach, or deliberate scoping decisions within budget)

- **The Draw material has no app-shell navigation entry point at all.**
  Verified by grep before writing `DrawDetailView.swift`: no
  `DrawingsListView` exists anywhere (the sibling `DocsListView.swift`/
  `SlidesListView.swift` do), and `DrawingsViewModel` (which already
  existed before this wave) was never instantiated anywhere in
  `TesseraStudioMac` - it was dead code except for its own tests. This
  track's new `DrawDetailView`/`DrawCanvasView` are real, functioning
  views (per this file's own build), but nothing in the shipped app
  routes to them yet - there is no sidebar entry, no "New Drawing"
  action, nothing that instantiates a `DrawingsViewModel` and presents
  a `DrawDetailView` for a selected `Drawing`. This is app-shell-level
  wiring (a `DrawingsListView.swift` peer to `DocsListView.swift`, plus
  whatever top-level navigation file switches between materials) that
  is outside this track's file list. `DocsListView.swift`/
  `SlidesListView.swift` themselves are also never directly
  instantiated by name anywhere either (`grep "DocsListView()"` finds
  nothing) - the app's actual top-level navigation structure was not
  locatable within this track's files, so I cannot even name the exact
  file the wiring belongs in with confidence; flagging for whichever
  track owns the app shell.
- **Group-relative resize/rotate is not implemented - only translate.**
  Item 4's brief and `TransformController.swift`'s own doc comment
  scope "the group-recursion entry point" to "transforming a group
  applies THE DELTA to every member shape" (singular "delta" language,
  matching a plain move/drag). `TransformController.applyingGroupDelta`
  implements exactly that: a uniform world-space translation across
  every member. Resizing or rotating a GROUP as one rigid body (scaling
  every member's geometry relative to the group's combined bounding
  box, the way real drawing tools let you drag a group's own corner
  handle) is NOT implemented - `DrawCanvasView` only shows resize/
  rotate handles when exactly one shape is selected (a group selection
  can only be dragged/translated, never resized/rotated as a unit).
  This is a deliberate scoping decision within this item's stated
  contract ("applies the delta"), not a missed requirement, but the
  next Draw wave that deepens group UX should know the group-relative
  resize/rotate math does not exist yet.
- **`DrawCanvasView`'s Cmd-Z is not wired to an `EditorUndoCoordinator`-
  equivalent.** Per this file's own header comment: `registerUndo`
  produces a correctly-grouped, signed `Receipt` chain in the view's
  own `ReceiptUndoManager` instance, but nothing calls
  `undoManager.undo(...)`/`.redo(...)` yet, and nothing bridges the
  resulting inverse `Mutation`s back into `DrawingStore` the way
  `EditorUndoCoordinator`/`AppKitUndoManagerBridge` do for the Writer
  editor. `DrawingsViewModel`'s own pre-existing doc comment defers "a
  canvas-editing view-model (shape selection, drag state, inline text
  editing)" to "whatever canvas UI lands later" - this track's canvas
  IS that later UI for the gesture/receipt half; a `DrawUndoCoordinator`
  (or reusing/generalizing `EditorUndoCoordinator`) to wire the macOS
  Edit menu's Cmd-Z to it is a follow-up.
- **No pan/zoom on the Draw canvas.** `zoomScale` is a fixed `1.0`
  constant in `DrawCanvasView`; `SnapEngine`'s threshold math already
  takes `zoomScale` as a parameter specifically so wiring real zoom
  later is a call-site change, not a signature change (documented
  inline). `WorkflowCanvasView.swift` (a different material's canvas)
  already has a working zoom/pan pattern this could copy from.
  Multi-touch pinch-to-zoom, marquee (rubber-band) multi-select, and
  keyboard nudging are likewise not implemented - none were named in
  item 3's contract (DragGesture + TransformController + SnapEngine +
  ReceiptUndoManager, gesture-end commit).
- **Canvas rendering resolves `ShapeFill.colorHex`'s `.theme` case via
  `ShapeRenderer`'s own existing (pre-this-wave) fallback, not a live
  theme lookup.** `DrawCanvasView`'s render layer calls
  `ShapeRenderer().render(...)` directly (reusing its full fill/stroke/
  rotation/connector logic rather than re-implementing it in SwiftUI),
  so whatever `ShapeRenderer` already does for a `.theme`-referencing
  `ColorRef` is what paints - not a gap this track introduced, just
  noting the canvas view has no theme-catalog wiring of its own.
- **`removeAnimationEffect` is addressed by play-order index, not by
  an effect id.** Verified against `AnimationEffectList.swift`:
  `AnimationEffect`'s field list (`targetBlockID`, `presetID`,
  `trigger`, `durationMS`, `delayMS`) has no `id` field, and
  `targetBlockID` cannot stand in for one (a block can legitimately
  carry more than one effect). The task brief's own example signature
  (`removeAnimationEffect(slideID:effectID:)`) could not be built
  literally against the type as it exists; `removeAnimationEffect(at
  effectIndex:forSlideAt:for:)` is the closest faithful shape. Noted
  inline in `SlideStore.swift`'s doc comment on the method itself, not
  just here.

## Testing-doctrine gating note (rule 11, mirrors the Writer/Draw-P1
## precedent)

Neither `SlideStore` nor `DrawingStore` has a seam other than a live
`TesseraDataLayer` (no fake/stub/in-memory data layer exists anywhere
in this codebase - same situation `DrawingStoreTests.swift`'s own
header comment already documented before this wave, and
`p2-0-findings-c.md` documents independently for `DocStore`). Every new
store-level mutation this track added
(`setAnimations`/`removeAnimationEffect`/`attachMedia`/`removeMedia`/
`replyToComment`/`resolveComment`/`deleteComment` on `SlideStore`;
`setGeometries`/`group`/`ungroup` on `DrawingStore`) is gated behind
`TESSERA_DB_INTEGRATION=1` in `SlideStoreTests.swift` (new)/
`DrawingStoreTests.swift` (extended), mirroring `DrawingStoreTests
.swift`'s pre-existing `DrawTestDataLayer` helper exactly (a
`SlideTestDataLayer` equivalent was added to the new file). Ungated
shadows:
- `group`/`ungroup`'s decision logic is pulled into `DrawingStore
  .applyingGroup`/`.applyingUngroup` (kept `internal`, not `private`,
  the same reason `SlideStore.applyingLayout` already is internal per
  its own doc comment) and covered directly in `DrawingStoreTests
  .swift` with no data layer at all - also converts the 3 pre-existing
  `GroupUngroupContractStubTests.swift` `XCTSkip` stubs: the 2 store-
  level ones are superseded by the new gated `DrawingStoreTests.swift`
  coverage (removed from the stub file to avoid a second copy of the
  DB-gated gate helper drifting apart from the first), and the 3rd
  (TransformController recursion) is now a real, DB-free assertion in
  that same file since `applyingGroupDelta` is pure.
- `TransformController.applyingGroupDelta`'s math (the actual "group
  recurses" contract) is pure and has no DB dependency at all - full
  fixture + property coverage lives in `TransformControllerTests.swift`
  directly.
- `setAnimations`/`removeAnimationEffect`/`attachMedia`/`removeMedia`/
  the comment-lifecycle methods wrap pure `SlideDeck`/`SlideMeta`
  field writes (`meta.animations = ...`, `CommentThread.addingReply(_:)`
  /`.resolved()`, `SlideDeck.replacingCommentThread(_:)`/
  `.removingCommentThread(id:)`) that were ALREADY pre-landed and
  contract-tested in isolation before this wave (`Comments.swift`'s own
  helpers, `AnimationEffectBehaviorTests.swift`) - what this track adds
  on top is purely the receipts-law wiring (exactly one receipt per
  mutation, zero for a no-op), which only exists at the store level and
  has no further pure logic to extract into an ungated shadow beyond
  what already existed.
- `setGeometries`'s "batch instead of N calls" logic is a straight
  loop over the existing, already-tested pure `Drawing.updatingShape`/
  `.shape(id:)` - no new pure logic worth a separate ungated test
  beyond the gated receipts-count assertion in `DrawingStoreTests
  .swift`.

## What is verified by reading vs by test (`DrawCanvasView`/
## `DrawDetailView`/`MediaPlaybackView`, per this cluster's task brief)

- **By test:** every pure math function these views call
  (`TransformController.resize`/`.rotate`/`.applyingGroupDelta`,
  `SnapEngine.snap`/`.snapRotation`, `DrawingStore.setGeometries`/
  `.group`/`.ungroup`/`.applyingGroup`/`.applyingUngroup`,
  `SlideStore.attachMedia`/`.removeMedia`/animation/comment methods,
  `MediaBlock`'s round-trip + `Block.media` bridge).
- **By reading only (no SwiftUI/XCUITest harness exists in this
  target to drive it):** the `DragGesture` wiring itself (hit-testing,
  handle placement math -> `TransformController.position(of:in:)`
  reused for the exact same math the tests already cover, `NSEvent
  .modifierFlags` reads for Option/Shift, gesture-end commit
  filtering). Both new SwiftUI files (`DrawCanvasView.swift`,
  `DrawDetailView.swift`) and `MediaPlaybackView.swift` were
  type-checked in isolation (`swiftc -typecheck` against small
  standalone snippets exercising the specific APIs used - `GraphicsContext
  .withCGContext`, `Double`->`CGPoint`/`CGFloat` conversion,
  `VideoPlayer`, `accessibilityAddTraits` with an array literal,
  `NSEvent.modifierFlags.contains`) to catch signature-level mistakes
  before the wave's centralized build, since this track was instructed
  not to run `swift build` on the shared checkout directly.
