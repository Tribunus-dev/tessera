# Phase 11 Integration Plan: 4-Agent Parallel Execution

## Branch Roster

| Agent | Worktree | Branch | Owns |
|---|---|---|---|
| GhostText | `../tessera-studio-phase11-ghosttext` | `phase11-ghosttext` | `TesseraGhostTextManager`, ghost text state in TesseraSTTextView |
| Streaming | `../tessera-studio-phase11-streaming` | `phase11-streaming` | `TesseraStreamingPipeline`, `GhostTextProvider` protocol |
| DiffOverlay | `../tessera-studio-phase11-diffoverlay` | `phase11-diffoverlay` | `TesseraDiffOverlayView`, `TesseraStreamingDiffEngine` |
| WritingTools | `../tessera-studio-phase11-writingtools` | `phase11-writingtools` | `TesseraWritingToolsCoordinator`, `NSServicesMenuRequestor` wiring |

## Shared Interface Contract

These types are defined by **Agent 2 (Streaming)** and consumed by Agents 1 and 3.
All agents read them from `TesseraCore/Editor/` or `TesseraCore/Engine/`.

### `GhostTextProvider` (Agent 2 defines, Agents 1+3 consume)
```swift
public protocol GhostTextProvider: AnyObject, @unchecked Sendable {
    /// Returns a non-streaming completion string for the current context.
    func completion(for prompt: String) async throws -> String
    /// Starts a streaming completion; onEach is called per token.
    func streamingCompletion(for prompt: String, onEach: @escaping @Sendable (String) -> Void) async throws -> String
    /// Cancels any in-flight streaming request.
    func cancelStreaming()
}
```

### `DiffProvider` (Agent 2 defines, Agent 3 consumes)
```swift
public protocol DiffProvider: AnyObject, @unchecked Sendable {
    /// Streams a rewritten version of `originalText`. `onEach` receives
    /// the partial rewritten text so far (incremental).
    func rewriteStreaming(originalText: String, onEach: @escaping @Sendable (String) -> Void) async throws -> String
    func cancelRewrite()
}
```

## What Each Agent Delivers

### Agent 1 — GhostText
**Worktree**: `/Users/user/Developer/GitHub/tessera-studio-phase11-ghosttext`
**File**: `Sources/TesseraCore/Editor/TesseraGhostTextManager.swift` (new)

Implements `GhostTextProvider` → `TesseraStreamingPipeline` wiring:
- `GhostTextState` struct: `range: NSRange`, `acceptedCount: Int`, `inFlightID: UUID?`, `text: String`
- `TesseraGhostTextManager`: owns debounce timer (300ms), cancellation UUID, and delegates to `GhostTextProvider`
- `GhostTextDisplayAttributes`: `foregroundColor = .tertiaryLabelColor`, base font inherit
- Methods: `triggerCompletion()`, `acceptFull()`, `acceptNextWord()`, `dismiss()`, `cancelAndDismiss()`
- **Key constraint**: all state mutations on `@MainActor`

Extension to `TesseraEditorView.swift`:
- Add `private var ghostTextState: GhostTextState?` to `TesseraSTTextView`
- Add `private var ghostTextManager: TesseraGhostTextManager?` to `TesseraSTTextView`
- Restructure `keyDown(with:)` — add ghost text branch at the top (before existing shortcuts):
  - `NSEvent.SpecialKey.tab.rawValue` → `ghostTextManager?.acceptFull()` + return
  - `Cmd+→` (`.rightArrow`, `.command` modifier) → `ghostTextManager?.acceptNextWord()` + return
  - `NSEvent.SpecialKey.escape.rawValue` → `ghostTextManager?.dismiss()` + return
  - Check divergence on every other character key → `ghostTextManager?.cancelAndDismiss()`
- Add private `setupGhostTextManager()` called from `didSet_textContentManager`
- After typing, if no selection and no ghost text active: start debounce timer → `ghostTextManager.triggerCompletion()`

### Agent 2 — Streaming
**Worktree**: `/Users/user/Developer/GitHub/tessera-studio-phase11-streaming`
**Files**:
- `Sources/TesseraCore/Editor/GhostTextProvider.swift` (new — shared protocol)
- `Sources/TesseraCore/Editor/DiffProvider.swift` (new — shared protocol)
- `Sources/TesseraCore/Engine/TesseraStreamingPipeline.swift` (new)

Implements both protocols against the existing `TesseraEngineBridge`:
- `TesseraStreamingPipeline`: `@MainActor` class, conforms to `GhostTextProvider` + `DiffProvider`
- Calls `TesseraEngineBridge.generate(prompt:maxTokens:)` → `AsyncThrowingStream<GeneratedToken, Error>`
- For ghost text: debounce is in Agent 1's manager; pipeline just streams tokens
- For diff: compute Myers-style diff between `originalText` and streaming partial on each token arrival
- Cancellation: store current `UUID`, compare on each token callback, skip if ID changed
- Granularity: word-level token accumulation (don't call `onEach` per character, per token is fine)

### Agent 3 — DiffOverlay
**Worktree**: `/Users/user/Developer/GitHub/tessera-studio-phase11-diffoverlay`
**Files**:
- `Sources/TesseraStudioMac/Views/Editor/TesseraDiffOverlayView.swift` (new)
- `Sources/TesseraStudioMac/Views/Editor/TesseraStreamingDiffView.swift` (new)

`TesseraDiffOverlayView`:
- SwiftUI `View` showing original text (normal) + streaming rewritten text (green/red diff)
- States: `.idle`, `.streaming`, `.diffComplete`, `.editable`
- Reads `DiffProvider` from injected `TesseraStreamingDiffView` coordinator
- Accept/Reject/Edit buttons below the selection range
- On accept: calls back to editor to apply replacement
- On reject: calls back to dismiss overlay

`TesseraStreamingDiffView` (the controller):
- `@MainActor` class bridging `DiffProvider` + SwiftUI overlay
- Creates `NSHostingView` positioned over the selected text rect
- Tracks `DiffOverlayState`: `originalRange: NSRange`, `rewrittenText: String`, `diffSegments: [DiffSegment]`
- `DiffSegment`: `.unchanged(String) | .added(String) | .deleted(String)`

Extension to `TesseraEditorView.swift`:
- Add `private var diffOverlayController: TesseraStreamingDiffView?` to `TesseraSTTextView`
- Add `public func triggerRewrite(mode: RewriteMode)` to `TesseraSTTextView` (called from toolbar)
- `RewriteMode`: `.friendly`, `.professional`, `.concise`, `.improve`
- In `handleViewCommand` in Coordinator: add `.aiRewrite(mode:)` case → calls `textView.triggerRewrite(mode:)` (line ~336 in current code)

Toolbar hook: `TesseraEditorToolbar` — add a rewrite button group (friendly/professional/concise/improve) that calls `.aiRewrite(mode:)` on the coordinator.

### Agent 4 — WritingTools
**Worktree**: `/Users/user/Developer/GitHub/tessera-studio-phase11-writingtools`
**Files**:
- `Sources/TesseraCore/Editor/TesseraWritingToolsCoordinator.swift` (new)
- `Sources/TesseraCore/Editor/TesseraWritingToolsCoordinatorDelegate.swift` (new)

`TesseraWritingToolsCoordinator`:
- `@MainActor` class conforming to `NSWritingToolsCoordinatorDelegate`
- `writingToolsCoordinator(_:requestsContextsFor:completion:)` → return `NSAttributedString` of current selection + surrounding paragraphs as `NSWritingToolsCoordinator.Context`
- `writingToolsCoordinator(_:replaceRange:inContext:proposedText:reason:animationParameters:completion:)` → apply replacement to `TesseraTextContentStorage` via `Mutation`
- `writingToolsCoordinator(_:prepareFor:textAnimation:forRange:in:completion:)` → hide range in text view
- `writingToolsCoordinator(_:finishTextAnimation:forRange:inContext:completion:)` → show range + cross-dissolve animation
- `writingToolsCoordinator(_:willChangeToState:completion:)` → log session lifecycle

Extension to `TesseraEditorView.swift`:
- Add `private var writingToolsCoordinator: TesseraWritingToolsCoordinator?` to `TesseraSTTextView`
- Add `setupWritingToolsCoordinator()` called from `didSet_textContentManager`
- Attach coordinator: `self.writingToolsCoordinator = TesseraWritingToolsCoordinator(textView: self, contentManager: ...)`
- Set `writingToolsCoordinator?.writingToolsBehavior = .complete` (full inline) for non-sensitive blocks

**Tier 2 shortcut** (minimal): `TesseraEditorView.swift` also needs `NSServicesMenuRequestor` — override `validRequestor(forSendType:returnType:)` and `writeSelection(to:type:)` + `readSelection(from:type:)` on `TesseraSTTextView`. This gives Writing Tools menu without the full coordinator.

## Integration Step (after all 4 agents land)

Julian runs this manually after all 4 agents complete:

1. Merge all 4 branches into `phase11-integration`:
   ```bash
   git checkout main && git merge phase11-ghosttext --no-ff -m "phase 11: ghost text shell"
   git merge phase11-streaming --no-ff -m "phase 11: streaming pipeline"
   git merge phase11-diffoverlay --no-ff -m "phase 11: streaming diff overlay"
   git merge phase11-writingtools --no-ff -m "phase 11: writing tools coordinator"
   ```

2. Resolve conflicts (expected: `TesseraEditorView.swift` — the extension sections for each agent are additive and should merge cleanly)

3. Build and fix any remaining type errors

4. Test: type in editor → ghost text appears → Tab accepts → Esc dismisses

## Files Reference (read-only, do not edit)

All agents read these files for API context:
- `TesseraStudioMac/Views/Editor/TesseraEditorView.swift` (TesseraSTTextView API)
- `TesseraCore/Editor/TesseraTextContentManager.swift` (text storage)
- `TesseraCore/Editor/IntTextLocation.swift` (NSTextLocation type)
- `TesseraCore/Engine/TesseraEngineBridge.swift` (generate API)
- `TesseraStudioMac/Views/Editor/TesseraEditorToolbar.swift` (toolbar hooks)

## Dependency Order for Reading

Agent 2 (Streaming) should start first so its protocols (`GhostTextProvider`, `DiffProvider`) are defined before Agents 1 and 3 reference them. Agents 1, 3, and 4 can run in parallel once Agent 2 has committed its protocol definitions.

However: since all worktrees are based on the same commit (no Agent 2 commits exist yet when agents start), Agents 1 and 3 should define stub protocols locally and use those stubs for compilation. The real protocols from Agent 2 will replace the stubs during the integration merge. Use this naming convention to avoid collision:
- Agent 1 stub: `protocol LocalGhostTextProvider`
- Agent 2 real: `protocol GhostTextProvider`
- During integration: Agent 2 wins; remove `LocalGhostTextProvider`
