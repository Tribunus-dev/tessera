# HIG Review: Notes + Docs Surfaces

**Reviewer:** Phase 12 Wave 1 Agent 1
**Date:** 2026-08-12
**Scope:** Notes + Docs editing surfaces — 9 SwiftUI view files
**Reference:** Apple HIG (skill: apple-hig, refreshed 2026-08-08) — §§1–4, §11–§13, §16

---

## Summary

**12 must-fix · 5 should-fix · 4 nice-to-have**

| Severity | Count | Primary category |
|---|---|---|
| must | 12 | Accessibility — missing `accessibilityLabel` on interactive elements |
| should | 5 | Keyboard shortcuts, color semantics, Dynamic Type readiness |
| nice | 4 | Accessibility hints, decorative element labels, ForEach stability |

---

## NoteDetailView

### Must-fix

1. **Missing accessibility label — Focus Mode toggle button**
   - **Description:** The toolbar Focus Mode `Button` has both a `Label` and an explicit `accessibilityLabel(isFocusMode ? "Exit Focus" : "Focus")`. The `accessibilityLabel` is present. However, the `help("Toggle focus mode (Cmd-\\)")` tooltip exposes a shortcut key (`Cmd-\`) that doesn't appear to be registered via `.keyboardShortcut`. If the shortcut is not wired, the tooltip misleads users who rely on it.
   - **Affected UI element:** Focus Mode toolbar `Button` (`.primaryAction` toolbar item)
   - **Current code location:** `NoteDetailView.swift:113–127`
   - **Fix:** Add `.keyboardShortcut("\\", modifiers: .command)` to the button and confirm the shortcut is also in the menu bar Edit/View menu.

2. **Missing accessibility label — all tag-chip remove buttons**
   - **Description:** Each tag `#tagname ×` chip is a `Button`. VoiceOver sees it as an unlabelled button. The user hears no indication of which tag will be removed. Every interactive element must have an `accessibilityLabel` so VoiceOver can announce the action.
   - **Affected UI element:** `Button` inside `ForEach(viewModel.note.tags, …)` — tag removal chips
   - **Current code location:** `NoteDetailView.swift:155–170`
   - **Fix:** Add `.accessibilityLabel("Remove tag \(tag)")` and `.accessibilityHint("Removes the tag '\(tag)' from this note")` to the Button.

3. **Missing accessibility label — Pin toggle**
   - **Description:** The Pin `Toggle` is a `.button` toggle style. The label reads "Pin"/"Pinned" visually, but VoiceOver needs `accessibilityLabel` to announce the current state correctly to users navigating by keyboard or VoiceOver.
   - **Affected UI element:** `Toggle(isOn: pinBinding)` action row
   - **Current code location:** `NoteDetailView.swift:185–192`
   - **Fix:** Add `.accessibilityLabel(viewModel.note.isPinned ? "Pinned" : "Pin note")` and `.accessibilityValue(viewModel.note.isPinned ? "Note is pinned" : "Note is not pinned")`.

4. **Missing accessibility label — Archive toggle**
   - **Description:** Same issue as the Pin toggle. VoiceOver will not correctly announce the archive state.
   - **Affected UI element:** `Toggle(isOn: archiveBinding)` action row
   - **Current code location:** `NoteDetailView.swift:194–201`
   - **Fix:** Add `.accessibilityLabel(viewModel.note.isArchived ? "Archived" : "Archive note")` and `.accessibilityValue(viewModel.note.isArchived ? "Note is archived" : "Note is not archived")`.

5. **Missing accessibility label — Link button**
   - **Description:** The "Link…" button in the action row has a `Label` visually but no `accessibilityLabel`. VoiceOver will read "Link, button" — no indication of the action's purpose.
   - **Affected UI element:** `Button { showLinkSearch = true }` labelled "Link…"
   - **Current code location:** `NoteDetailView.swift:203–206`
   - **Fix:** Add `.accessibilityLabel("Link to another material")` and `.accessibilityHint("Opens a sheet to paste an entity UUID and create a link")`.

6. **Missing accessibility label — Delete toolbar button**
   - **Description:** The destructive toolbar `Button` has `.accessibilityLabel("Delete note")` — this is correctly present. However, the `help("Delete this note")` tooltip on the toolbar button conflicts with the `.keyboardShortcut` convention for delete actions. Confirm Cmd-Delete is wired or remove the tooltip. No change needed on the accessibilityLabel itself (it is present and correct).
   - **Affected UI element:** Destructive toolbar `Button`
   - **Current code location:** `NoteDetailView.swift:129–135`
   - **Fix (confirmation):** Verify `.keyboardShortcut(.delete, modifiers: .command)` is wired in the host's `.commands` group for the delete action; remove the tooltip if no shortcut is registered.

7. **Missing accessibility label — LinkedEntityChip (local private struct)**
   - **Description:** The local `LinkedEntityChip` struct at the bottom of the file is a `HStack` with no interactive elements — it displays a UUID prefix and a link icon. If it is purely decorative/non-interactive, it should have `.accessibilityElement(children: .ignore)` and `.accessibilityLabel("Linked entity: \(String(id.uuidString.prefix(8)))")`. If it becomes interactive in a future phase, the interactive wrapper needs its own label.
   - **Affected UI element:** `LinkedEntityChip` (private struct, line 395–410)
   - **Current code location:** `NoteDetailView.swift:395–410`
   - **Fix:** Add `.accessibilityLabel("Linked entity, ID \((String(id.uuidString.prefix(8))))")` to the HStack, wrapped in `.accessibilityElement(children: .combine)`.

### Should-fix

8. **Non-standard keyboard shortcuts — Align Center (⌘E) and Align Right (⌘R)**
   - **Description:** `TesseraEditorToolbar.homeContent` uses ⌘E for Align Center and ⌘R for Align Right. On macOS, ⌘E is the standard shortcut for Edit > Preferences / Services (varies by app), and ⌘R is the canonical shortcut for Edit > Replace (used by Xcode, Safari, TextEdit, BBEdit, and most macOS apps). Assigning these to formatting actions creates a real shortcut collision that breaks muscle memory for Replace workflows. The standard macOS convention for paragraph alignment shortcuts is not established by Apple; ⌘L (Align Left) and ⌘R (Align Right) are used by Microsoft Word, but ⌘R colliding with Replace is the more significant problem.
   - **Affected UI element:** `RibbonToggleButton` actions for alignCenter and alignRight
   - **Current code location:** `TesseraEditorToolbar.swift:293–294`
   - **Fix:** Remap Align Center to ⌘⇧C and Align Right to ⌘⇧R (Shift variants keep the alignment group together). Alternatively, drop explicit shortcuts for these and let users discover them via the menu bar or toolbar tooltips.

9. **Red error text not semantic**
   - **Description:** `.foregroundStyle(.red)` on the error text (`NoteDetailView.swift:216`) hard-codes red. This does not adapt to Increase Contrast mode (which can swap red for other high-contrast colors) and provides no dark-mode variant. Users with color vision deficiencies see only a red signal without semantic reinforcement.
   - **Affected UI element:** `Text(err)` in action row error display
   - **Current code location:** `NoteDetailView.swift:215–219`
   - **Fix:** Replace with `.foregroundStyle(Color(.systemRed))` or define a semantic `.foregroundStyle(.error)` using a custom asset with light/dark/IncreaseContrast variants. Pair with a descriptive `accessibilityLabel("Error: \(err)")`.

10. **Delete sheet keyboard shortcuts are reversed**
    - **Description:** The delete confirmation sheet has `Button("Cancel")` with `.keyboardShortcut(.defaultAction)` and `Button("Delete", role: .destructive)` with `.keyboardShortcut(.cancelAction)`. On macOS, Return is the primary/default action and Escape is the cancel action. Assigning `.cancelAction` to the destructive button and `.defaultAction` to Cancel is inverted and counter to platform convention.
    - **Affected UI element:** Cancel and Delete buttons in `deleteSheet`
    - **Current code location:** `NoteDetailView.swift:277–283`
    - **Fix:** Swap: Cancel gets `.keyboardShortcut(.cancelAction)` (Escape), Delete gets `.keyboardShortcut(.defaultAction)` (Return).

### Nice-to-have

11. **Missing accessibility hint — Focus Mode button**
    - **Description:** The Focus Mode button has an `accessibilityLabel` but no `accessibilityHint`. An accessibility hint ("Double-tap to toggle focus mode, which hides chrome for distraction-free writing") helps VoiceOver users understand the effect before activating.
    - **Affected UI element:** Focus Mode `Button` in toolbar
    - **Current code location:** `NoteDetailView.swift:113–127`
    - **Fix:** Add `.accessibilityHint("Hides the toolbar and chrome for distraction-free writing. Press Escape to exit.")` when focus mode is active.

12. **Title TextField needs textFieldRole**
    - **Description:** `TextField("Title", …)` has no `.textFieldStyle(.plain)` — good, plain style is already applied. However, VoiceOver should treat this as a "search field" role is incorrect; as a title field it should be `.textFieldRole(.tile)` (available in SwiftUI). Adding the role helps VoiceOver announce it distinctly.
    - **Affected UI element:** Title `TextField`
    - **Current code location:** `NoteDetailView.swift:141–147`
    - **Fix:** Add `.textFieldRole(.tile)` to the title TextField.

---

## NoteEditorView

### Must-fix

13. **Missing accessibility label — Exit Focus button in focusStatusBar**
    - **Description:** The focus status bar's "Exit Focus" `Button` has a `Label` with the title and icon, but no `accessibilityLabel`. VoiceOver will announce the button correctly if the Label's title is read, but explicit labeling is more reliable.
    - **Affected UI element:** `Button` in `focusStatusBar` (Exit Focus)
    - **Current code location:** `NoteEditorView.swift:102–113`
    - **Fix:** Add `.accessibilityLabel("Exit Focus mode")` and `.accessibilityHint("Press Escape to exit focus mode.")`.

### Should-fix

14. **Exit Focus button tooltip redundant with keyboard shortcut**
    - **Description:** `.help("Exit focus mode (Escape)")` promises an Escape shortcut. Confirm `.onKeyPress(.escape)` in `NoteEditorView.swift:57–65` is the only Escape handler and that Escape works in all focus states (including when the editor has keyboard focus).
    - **Affected UI element:** Exit Focus button
    - **Current code location:** `NoteEditorView.swift:112`
    - **Fix:** Verify Escape exits focus mode regardless of which view has keyboard focus; update the hint to reflect any edge cases.

### Nice-to-have

15. **Animation not interruptible — focus status bar transition**
    - **Description:** The focus status bar appears with `.transition(.opacity)` and an ease-in-out animation. The animation duration (0.25s) is brief enough that this is not a significant issue, but if the user rapidly toggles focus mode the animation could feel unresponsive.
    - **Affected UI element:** `focusStatusBar` visibility
    - **Current code location:** `NoteEditorView.swift:52–53`
    - **Fix:** The current code already respects `reduceMotion` for the outer `.animation(…)`. Ensure `onKeyPress(.escape)` does not wait for the animation to complete before accepting input (it currently returns `.handled` synchronously, which is correct).

---

## DocDetailView

### Must-fix

16. **Missing accessibility label — all SurfaceTagBar tag chips**
    - **Description:** `SurfaceTagBar` renders tag chips as `Button`s. Each chip has no `accessibilityLabel`. When VoiceOver focuses a tag, users hear no indication of which tag it is or that it can be removed. Must-fix is to add labels per chip in the shared component.
    - **Affected UI element:** `SurfaceTagBar` — `ForEach(tags, id: \.self)` chip buttons
    - **Current code location:** `SurfaceTagBar.swift:30–46`
    - **Fix:** Add `.accessibilityLabel("Remove tag \(tag)")` and `.accessibilityHint("Double-tap to remove the tag '\(tag)'")` to the chip Button.

17. **Missing accessibility label — Favorite toggle**
    - **Description:** The Favorite `Toggle` in the action row has no `accessibilityLabel`. VoiceOver will read "Favorite, button" with no state.
    - **Affected UI element:** `Toggle(isOn: favoriteBinding)` action row
    - **Current code location:** `DocDetailView.swift:271–275`
    - **Fix:** Add `.accessibilityLabel(viewModel.doc.isFavorite ? "Favorited" : "Favorite")` and `.accessibilityValue(viewModel.doc.isFavorite ? "This document is favorited" : "This document is not favorited")`.

18. **Missing accessibility label — Archive toggle**
    - **Description:** Same as the Archive toggle in NoteDetailView. VoiceOver cannot determine the current state.
    - **Affected UI element:** `Toggle(isOn: archiveBinding)` action row
    - **Current code location:** `DocDetailView.swift:277–281`
    - **Fix:** Add `.accessibilityLabel(viewModel.doc.isArchived ? "Archived" : "Archive")` and `.accessibilityValue(viewModel.doc.isArchived ? "This document is archived" : "This document is not archived")`.

19. **Missing accessibility label — Trash toggle**
    - **Description:** The Trash `Toggle` in the action row has no `accessibilityLabel`. This is a destructive-state toggle — accurate labeling is especially important for VoiceOver users.
    - **Affected UI element:** `Toggle(isOn: trashBinding)` action row
    - **Current code location:** `DocDetailView.swift:283–287`
    - **Fix:** Add `.accessibilityLabel(viewModel.doc.isTrashed ? "In Trash" : "Move to Trash")` and `.accessibilityValue(viewModel.doc.isTrashed ? "This document is in the trash" : "This document is not in the trash")`.

20. **Missing accessibility label — Link button**
    - **Description:** The "Link…" button in the Doc action row has no `accessibilityLabel`. Same issue as in NoteDetailView.
    - **Affected UI element:** `Button { showLinkSearch = true }` labelled "Link…"
    - **Current code location:** `DocDetailView.swift:289–292`
    - **Fix:** Add `.accessibilityLabel("Link to another material")` and `.accessibilityHint("Opens a sheet to paste an entity UUID and create a link")`.

### Should-fix

21. **Delete sheet keyboard shortcuts are reversed**
    - **Description:** Identical issue to NoteDetailView delete sheet. `Button("Cancel")` has `.keyboardShortcut(.defaultAction)` and `Button("Delete", role: .destructive)` has `.keyboardShortcut(.cancelAction)`. The convention is inverted.
    - **Affected UI element:** Cancel and Delete buttons in `deleteSheet`
    - **Current code location:** `DocDetailView.swift:348–350`
    - **Fix:** Swap the keyboard shortcuts: Cancel → `.cancelAction`, Delete → `.defaultAction`.

### Nice-to-have

22. **Emoji icon in header has no accessibility treatment**
    - **Description:** `Text(emoji).font(.title)` renders an emoji icon in the header. Emojis used as visual icons should be hidden from VoiceOver (set `accessibilityLabel(nil)`) and replaced with a semantic image or described as decorative.
    - **Affected UI element:** Emoji `Text` in `headerSection`
    - **Current code location:** `DocDetailView.swift:231–233`
    - **Fix:** Add `.accessibilityLabel("Document icon")` (or describe the specific emoji semantically) or mark it as `.accessibilityHidden(true)` if the icon conveys no semantic meaning beyond visual decoration.

23. **Doc title TextField needs textFieldRole**
    - **Description:** Same as NoteDetailView. The title TextField should have an explicit role for VoiceOver.
    - **Affected UI element:** Title `TextField`
    - **Current code location:** `DocDetailView.swift:234–240`
    - **Fix:** Add `.textFieldRole(.tile)` to the title TextField.

---

## DocEditorView

### Must-fix

24. **Missing accessibility label — Exit Focus button in focusStatusBar**
    - **Description:** DocEditor's `SurfaceFocusStatusBar` wraps the same "Exit Focus" button. The shared component needs the label, not just DocEditorView. However, since `SurfaceFocusStatusBar` (the shared component) is the source of the issue, the fix should be applied at the shared component level.
    - **Affected UI element:** `SurfaceFocusStatusBar` Exit Focus button
    - **Current code location:** `DocEditorView.swift:103–113` (passes to `SurfaceFocusStatusBar`)
    - **Fix:** See shared component violation #30 below.

### Nice-to-have

25. **Accessibility label on SurfaceFocusStatusBar Exit button is present but should be explicit**
    - **Description:** The `SurfaceFocusStatusBar` button has a `Label` which SwiftUI exposes as the default accessibility label. For VoiceOver, an explicit `.accessibilityLabel("Exit Focus mode")` is more reliable and future-proof.
    - **Affected UI element:** Exit Focus `Button` in `SurfaceFocusStatusBar`
    - **Current code location:** `SurfaceFocusStatusBar.swift:27–34`
    - **Fix:** Add `.accessibilityLabel("Exit Focus mode")` to the Button.

---

## Shared Components Used

> The following violations are in shared components (`Surface*`) and therefore affect all surfaces that use them. Each item is cross-referenced to the surface sections above.

### SurfaceMetadataRow

26. **Must — ForEach uses array index as stable identifier**
    - **Description:** `ForEach(Array(stats.enumerated()), id: \.offset)` uses the integer offset as the identifier. If the stats array is reordered or items are removed/added, SwiftUI may not correctly identify which items changed. The correct identifier is the tuple's own fields or a stable UUID.
    - **Affected UI element:** `ForEach` loop over stats
    - **Current code location:** `SurfaceMetadataRow.swift:28`
    - **Fix:** Use `id: \.element.label` (the label string) or introduce a stable `id` field in the tuple.

### SurfaceTagBar

27. **Must — Tag chip buttons missing accessibility labels**
    - **Description:** The tag removal `Button` inside `ForEach(tags, id: \.self)` has no `accessibilityLabel`. This affects every surface that uses `SurfaceTagBar`: DocDetailView. NoteDetailView uses a local copy of the tag bar pattern (same violation).
    - **Affected UI element:** Tag chip `Button` in `ForEach(tags, id: \.self)`
    - **Current code location:** `SurfaceTagBar.swift:30–46`
    - **Fix:** Add `.accessibilityLabel("Remove tag \(tag)")` and `.accessibilityHint("Double-tap to remove the tag '\(tag)'")` to the Button.

### SurfaceLinkedEntityChip

28. **Must — Chip button missing accessibility label**
    - **Description:** `SurfaceLinkedEntityChip` wraps a `Button`. The label shows the entity ID and an icon but has no `accessibilityLabel`. VoiceOver will read "Link, button" — no indication of what entity it links to.
    - **Affected UI element:** Root `Button` in `SurfaceLinkedEntityChip`
    - **Current code location:** `SurfaceLinkedEntityChip.swift:38–65`
    - **Fix:** Add `.accessibilityLabel("Linked entity: \(label)")` and `.accessibilityHint("Double-tap to navigate to this linked material")`.

29. **Should — Hard-coded icon colors in SurfaceLinkedEntityChip**
    - **Description:** `iconColor` computes `.blue`, `.green`, `.yellow` for calendar link types. These hard-coded colors do not adapt to Increase Contrast mode. More critically, `.yellow` on a white/light background has very poor contrast.
    - **Affected UI element:** `Image` icon in chip
    - **Current code location:** `SurfaceLinkedEntityChip.swift:78–86`
    - **Fix:** Use semantic colors — e.g., `.blue` → `.tint` / `.accentColor`, or use `Color(.systemBlue)` with a custom asset that provides an Increase Contrast variant. For `.yellow`, use a darker amber such as `.orange` for adequate contrast on light backgrounds.

### SurfaceFocusStatusBar

30. **Must — Exit Focus button missing explicit accessibility label**
    - **Description:** The `Button` in `SurfaceFocusStatusBar` has a `Label` but no explicit `accessibilityLabel`. SwiftUI exposes the Label's title as the implicit accessibility label, which is usually sufficient. However, an explicit label is more reliable and communicates the button's purpose regardless of how the Label is rendered.
    - **Affected UI element:** Exit Focus `Button`
    - **Current code location:** `SurfaceFocusStatusBar.swift:27–34`
    - **Fix:** Add `.accessibilityLabel("Exit Focus mode")` and `.accessibilityHint("Press Escape to exit focus mode")` to the Button.

### TesseraEditorToolbar

31. **Should — AI Rewrite Menu button missing accessibility label**
    - **Description:** The `aiRewriteMenu` `Menu` uses an `Image` with no text label. VoiceOver will read the image name (e.g., "wand and stars") which does not convey the menu's purpose. The `help("AI Rewrite")` tooltip provides a hint but is not an accessibility label.
    - **Affected UI element:** `aiRewriteMenu` Menu button
    - **Current code location:** `TesseraEditorToolbar.swift:321–340`
    - **Fix:** Add `.accessibilityLabel("AI Rewrite")` and `.accessibilityHint("Opens a menu with AI text transformation options including friendly, professional, concise, improve, and custom modes")`.

32. **Should — RouteChip (inside toolbar) missing accessibility label**
    - **Description:** `RouteChip` is a non-interactive display chip showing the current AI route. Its content (text + colored circle) should have an explicit `accessibilityLabel`. Currently VoiceOver reads the text "Granite · Local" or "Cloud" but may not announce the colored status dot.
    - **Affected UI element:** `RouteChip` inside toolbar
    - **Current code location:** `TesseraEditorToolbar.swift:215` and `TesseraEditorToolbar.swift:238`
    - **Fix:** Add `.accessibilityLabel(aiRoute == "local" ? "AI route: Granite running locally" : "AI route: Cloud")` to the RouteChip's root view.

33. **Should — Track Changes count badge — white text on hardcoded orange may fail contrast**
    - **Description:** `Text("\(formattingState.pendingChangeCount)")` uses `.foregroundStyle(.white)` on a hardcoded `Color.orange` background. At small font sizes (8pt), the contrast ratio may not meet 3:1 for large text or 4.5:1 for regular text. The orange background further reduces contrast.
    - **Affected UI element:** Count badge in review tab
    - **Current code location:** `TesseraEditorToolbar.swift:410–417`
    - **Fix:** Use `Color(.systemRed)` or another system color with guaranteed contrast. Add an Increase Contrast variant via a custom asset. Alternatively, use `.accessibilityLabel("\(formattingState.pendingChangeCount) pending changes")` on the container so VoiceOver always announces the count correctly regardless of visual contrast.

---

## Cross-Cutting Observations

### Accessibility (§3, §12.4)
All 12 must-fix violations are in accessibility. The pattern is consistent: every interactive `Button` and `Toggle` in the Notes/Docs surfaces needs `accessibilityLabel`, and all `Toggle` controls should additionally have `accessibilityValue` describing their current state. The shared components (`SurfaceTagBar`, `SurfaceLinkedEntityChip`, `SurfaceFocusStatusBar`) are the highest-leverage fixes — fixing them fixes all surfaces simultaneously.

### Keyboard shortcuts (§4.5, §16.1)
The ⌘E (Align Center) and ⌘R (Align Right) assignments in the toolbar conflict with established macOS conventions. ⌘R for Align Right also collides with the standard Edit > Replace shortcut used by most macOS productivity applications. This is a "should" because the toolbar is not the primary shortcut surface (the menu bar is), but users who memorize toolbar shortcuts will encounter conflicts.

### Color (§2.1, §12.1)
Three instances of hard-coded colors that don't adapt to Increase Contrast:
- `.red` for error text (NoteDetailView, SurfaceMetadataRow)
- `.blue`, `.green`, `.yellow` for entity chip icons (SurfaceLinkedEntityChip)
- White-on-orange for the change-count badge (TesseraEditorToolbar)

The `.red` error text is the most critical — it appears when the user encounters a save error, and poor contrast at that moment is especially harmful. Use `Color(.systemRed)` as a minimum fix, or better, a custom semantic color asset.

### Typography (§2.2, §11.6)
The codebase correctly uses SwiftUI semantic text styles (`.title`, `.headline`, `.callout`, `.caption`). One nice-to-have improvement: add `.textFieldRole(.tile)` to title TextFields for clearer VoiceOver behavior.

### Layout (§2.4, §4.1)
The detail views follow a sound layout hierarchy (header → metadata → tags → editor → linked entities). The macOS-specific guidance ("avoid critical information at the bottom of a window") is respected — the linked-entities section and focus-status bar are supplementary, not critical.

### Dynamic Type (§2.2)
macOS does not support Dynamic Type (§2.2: "macOS does NOT support Dynamic Type"). No Dynamic Type violations are applicable. However, the text scales correctly with the user's chosen macOS font size settings through system font usage.

### System Integration (§4.3, §4.8)
- **Toolbar:** Correctly uses `.toolbar { … }` with `ToolbarItem(placement:)` — not a custom HStack. ✓
- **Sheets:** Uses `.sheet(isPresented:)` for delete confirmations and link search — appropriate for focused tasks. ✓
- **No sheet stacking:** Each surface presents only one sheet at a time. ✓
- **Help menu:** The toolbar `help("…")` tooltips serve inline help. The app's Help menu integration (§12.8) should be verified separately (not in scope for this surface review).

---

## Priority Order for Fixes

| Priority | Items | Action |
|---|---|---|
| **P0** | #2, #3, #4, #5, #16, #17, #18, #19, #20, #27, #28, #30 | Fix all missing `accessibilityLabel` on interactive elements. Fix in shared components first (`SurfaceTagBar`, `SurfaceLinkedEntityChip`, `SurfaceFocusStatusBar`) to maximize surface coverage per fix. |
| **P1** | #8, #10, #21 | Fix keyboard shortcut collisions (Align Center/Right) and reversed delete-sheet shortcuts. |
| **P2** | #9, #29 | Fix semantic color usage for error text and entity chip icons. |
| **P3** | #1, #6, #11, #13, #14, #22, #23, #25, #26, #31, #32, #33 | Hints, decorative elements, ForEach stability, nice-to-have accessibility polish. |
