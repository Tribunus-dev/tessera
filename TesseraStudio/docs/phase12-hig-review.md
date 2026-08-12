# Phase 12 HIG Review — All Surfaces

**Date:** 2026-08-12
**Scope:** All Phase 12 editing surfaces (Notes, Docs, Calendar, Contacts, Reminders, Sheets, Slides, Code) + shared components
**Reference:** Apple HIG (skill: apple-hig) — §§1–4, §11–§13, §16

---

## Grand Summary

| Severity | Count |
|---|---|
| 🔴 must-fix | **26** |
| 🟡 should-fix | **18** |
| ⚪ nice-to-have | **12** |

**Cross-cutting priorities (fix once, benefit all surfaces):**

1. **`SurfaceLinkedEntityChip`** — hard-coded `.blue/.green/.yellow/.purple` icon colors → broken in Dark Mode + missing `accessibilityLabel` on the button. Fix the shared component → fixes 6 surfaces.
2. **`SurfaceTagBar`** — tag chip `Button` missing `accessibilityLabel("Remove tag \(tag)")`. Fix once → fixes DocDetailView.
3. **`SurfaceFocusStatusBar`** — Exit Focus button missing explicit `accessibilityLabel("Exit Focus mode")` + `accessibilityHint("Press Escape to exit focus mode")`. Fix once → fixes Notes, Docs.
4. **`TesseraEditorToolbar` `RibbonButton` / `RibbonToggleButton`** — no `accessibilityLabel` on any icon-only toolbar button. Fix once → fixes all toolbar users.
5. **Delete sheet reversed shortcuts** — `Cancel` has `.defaultAction`, Delete has `.cancelAction` in NoteDetailView, DocDetailView, SheetDetailView, SlideDeckDetailView. Swap both → fixes 4 surfaces.

---

## Notes + Docs Surfaces

### 🔴 Must-fix (12)

#### NoteDetailView

1. **Focus Mode toggle: keyboard shortcut mismatch** (`NoteDetailView.swift:113–127`)
   The `help("Toggle focus mode (Cmd-\\)")` tooltip promises ⌘\ but `.keyboardShortcut` is not applied to the button. VoiceOver users relying on the tooltip are misled.
   - **Fix:** Add `.keyboardShortcut("\\", modifiers: .command)` and wire ⌘\ in the host's `.commands` group.

2. **Tag-chip remove buttons missing `accessibilityLabel`** (`NoteDetailView.swift:155–170`)
   Each `#tagname ×` chip is a `Button` with no label. VoiceOver hears an unlabelled button.
   - **Fix:** `.accessibilityLabel("Remove tag \(tag)")` + `.accessibilityHint("Removes the tag '\(tag)' from this note")`.

3. **Pin toggle missing `accessibilityLabel`/`accessibilityValue`** (`NoteDetailView.swift:185–192`)
   - **Fix:** `.accessibilityLabel(viewModel.note.isPinned ? "Pinned" : "Pin note")` + `.accessibilityValue(viewModel.note.isPinned ? "Note is pinned" : "Note is not pinned")`.

4. **Archive toggle missing `accessibilityLabel`/`accessibilityValue`** (`NoteDetailView.swift:194–201`)
   - **Fix:** `.accessibilityLabel(viewModel.note.isArchived ? "Archived" : "Archive note")` + `.accessibilityValue(...)`.

5. **Link button missing `accessibilityLabel`/`accessibilityHint`** (`NoteDetailView.swift:203–206`)
   - **Fix:** `.accessibilityLabel("Link to another material")` + `.accessibilityHint("Opens a sheet to paste an entity UUID and create a link")`.

6. **Local `LinkedEntityChip` struct missing `accessibilityLabel`** (`NoteDetailView.swift:395–410`)
   The private `LinkedEntityChip` HStack should announce itself.
   - **Fix:** `.accessibilityElement(children: .combine).accessibilityLabel("Linked entity, ID \((String(id.uuidString.prefix(8))))")`.

#### NoteEditorView

7. **Exit Focus button in `focusStatusBar` missing `accessibilityLabel`** (`NoteEditorView.swift:102–113`)
   - **Fix:** See `SurfaceFocusStatusBar` shared fix below.

#### DocDetailView

8. **`SurfaceTagBar` tag chips missing `accessibilityLabel`** (`SurfaceTagBar.swift:30–46`)
   Affects DocDetailView directly.
   - **Fix:** Add `.accessibilityLabel("Remove tag \(tag)")` + `.accessibilityHint("Double-tap to remove the tag '\(tag)'")` to chip Button.

9. **Favorite toggle missing `accessibilityLabel`/`accessibilityValue`** (`DocDetailView.swift:271–275`)
   - **Fix:** `.accessibilityLabel(viewModel.doc.isFavorite ? "Favorited" : "Favorite")` + `.accessibilityValue(...)`.

10. **Archive toggle missing `accessibilityLabel`/`accessibilityValue`** (`DocDetailView.swift:277–281`)
    - **Fix:** Same pattern as NoteDetailView.

11. **Trash toggle missing `accessibilityLabel`/`accessibilityValue`** (`DocDetailView.swift:283–287`)
    - **Fix:** `.accessibilityLabel(viewModel.doc.isTrashed ? "In Trash" : "Move to Trash")` + `.accessibilityValue(...)`.

12. **Link button missing `accessibilityLabel`/`accessibilityHint`** (`DocDetailView.swift:289–292`)
    - **Fix:** `.accessibilityLabel("Link to another material")` + `.accessibilityHint("Opens a sheet to paste an entity UUID and create a link")`.

#### DocEditorView

13. **Exit Focus button (via `SurfaceFocusStatusBar`) missing explicit `accessibilityLabel`** (`DocEditorView.swift:103–113`)
    - **Fix:** See `SurfaceFocusStatusBar` shared fix below.

### 🟡 Should-fix (5)

14. **⌘E / ⌘R keyboard shortcut collisions** (`TesseraEditorToolbar.swift:293–294`)
    ⌘E is used by macOS for Edit > Services/Preferences (varies); ⌘R is the canonical Edit > Replace (Xcode, Safari, TextEdit). Align Center / Align Right should use Shift variants.
    - **Fix:** Remap to ⌘⇧C (Center) and ⌘⇧R (Right).

15. **Red error text is non-semantic** (`NoteDetailView.swift:215–219`)
    `.foregroundStyle(.red)` doesn't adapt to Increase Contrast. Replace with `.foregroundStyle(Color(.systemRed))` or a custom semantic `.error` color asset.

16. **Delete sheet shortcuts reversed** (`NoteDetailView.swift:277–283`, `DocDetailView.swift:348–350`)
    Cancel=`.defaultAction`, Delete=`.cancelAction` → inverted.
    - **Fix:** Swap: Cancel → `.cancelAction`, Delete → `.defaultAction`.

17. **Emoji icon in DocDetailView header needs accessibility treatment** (`DocDetailView.swift:231–233`)
    - **Fix:** `.accessibilityHidden(true)` if decorative, or `.accessibilityLabel("Document icon")` if semantic.

18. **Title TextField should have `.textFieldRole(.tile)`** (`NoteDetailView.swift:141–147`, `DocDetailView.swift:234–240`)
    - **Fix:** Add `.textFieldRole(.tile)` for explicit VoiceOver role.

### ⚪ Nice-to-have (4)

19. **Focus Mode button missing `accessibilityHint`** (`NoteDetailView.swift:113–127`)
    - **Fix:** `.accessibilityHint("Hides the toolbar and chrome for distraction-free writing. Press Escape to exit.")`.

20. **Exit Focus button tooltip redundant with shortcut** (`NoteEditorView.swift:112`)
    Verify `.onKeyPress(.escape)` exits regardless of keyboard focus state; update hint if edge cases exist.

21. **Focus status bar animation not interruptible** (`NoteEditorView.swift:52–53`)
    Already correct: `.onKeyPress` returns `.handled` synchronously. No change needed.

22. **`SurfaceMetadataRow` ForEach uses integer offset as stable identifier** (`SurfaceMetadataRow.swift:28`)
    `ForEach(Array(stats.enumerated()), id: \.offset)` — fragile if array reordered.
    - **Fix:** `ForEach(stats, id: \.label)` (label string is the natural key).

---

## Calendar + Contacts + Reminders Surfaces

### 🔴 Must-fix (5)

#### CalendarSurfaceView

23. **Quick-add TextField + Button missing `accessibilityLabel`** (`CalendarSurfaceView.swift:182–201`)
    Placeholder text is not exposed to VoiceOver. The "Add" button also has no label.
    - **Fix:** TextField: `.accessibilityLabel("Quick-add event")`. Button: `.accessibilityLabel("Add event")` + `.accessibilityHint("Creates an event from the text above.")`.

#### ContactsView

24. **`ContactRow` HStack missing `accessibilityLabel`** (`ContactsView.swift:201–232`)
    - **Fix:** `.accessibilityElement(children: .combine).accessibilityLabel(contact.accessibilityName)` on the root HStack.

25. **Reload toolbar button missing `accessibilityLabel`** (`ContactsView.swift:74`)
    Has `.help("Reload contacts")` but no `accessibilityLabel`.
    - **Fix:** `.accessibilityLabel("Reload contacts")`.

#### RemindersView

26. **`ReminderRow` missing `accessibilityLabel`/`accessibilityValue`** (`RemindersView.swift:241–271`)
    VoiceOver traverses text but the combined semantic (title + status + time) is not explicit.
    - **Fix:** `.accessibilityLabel("\(reminder.title), \(reminder.priority.shortLabel)")` + `.accessibilityValue("\(rowIcon) \(timeDescription)")`.

### 🟡 Should-fix (7)

27. **Event row buttons missing `accessibilityLabel`** (`CalendarSurfaceView.swift:125–144`)
    - **Fix:** `.accessibilityLabel("\(event.title), \(whenLabel(event))")` on each Button.

28. **DatePicker and "Today" button missing `accessibilityLabel`** (`CalendarSurfaceView.swift:77–109`)
    - **Fix:** DatePicker: `.accessibilityLabel("Selected date")`. Today button: `.accessibilityLabel("Go to today")` + `.accessibilityHint("Navigates to the current date.")`.

29. **`GraphNode.color(for:)` is not a semantic color** (`ContactsView.swift:209, 321`)
    Returns hardcoded/computed color — won't adapt to Dark Mode or Increase Contrast.
    - **Fix:** Use system semantic colors or define Color assets with light/dark variants.

30. **`.quaternary` fill is non-standard** (`ContactsView.swift:334`)
    `.quaternaryLabelColor` is a text color, not a fill. Use `Color(.controlBackgroundColor)` with opacity.

31. **VCardImportSheet buttons missing `accessibilityLabel`** (`ContactsView.swift:544–571`)
    - **Fix:** "Choose file…" → `.accessibilityLabel("Choose VCard file")`. Import → `.accessibilityLabel("Import selected VCard file")`.

32. **Reminder status/priority colors are non-semantic literals** (`RemindersView.swift:279–292`)
    `.green`, `.orange`, `.yellow`, `.red` don't adapt to Dark Mode / Increase Contrast.
    - **Fix:** Use system semantic colors with verified contrast ratios.

33. **"Open Settings" button missing `accessibilityLabel`/`accessibilityHint`** (`RemindersView.swift:216–222`)
    - **Fix:** `.accessibilityLabel("Open system settings")` + `.accessibilityHint("Opens macOS System Settings to the Notifications pane.")`.

### ⚪ Nice-to-have (5)

34. **Quick-add placeholder is a verbose example string** (`CalendarSurfaceView.swift:188`)
    Replace with a short prompt; move examples to `.help()` tooltip.

35. **ContactRow double padding** (`ContactsView.swift:230`)
    `List` already provides row padding; `.padding(.vertical, 2)` on the HStack may double it. Remove or reduce to `.padding(.vertical, 1)`.

36. **VCardImportSheet uses fixed frame** (`ContactsView.swift:576`)
    `.frame(width: 480, height: 200)` won't adapt to text scaling. Use a flexible layout.

37. **`SurfaceLinkedEntityChip` icon colors non-semantic** — see shared component fix below.

38. **`SurfaceFocusStatusBar` Exit button missing `accessibilityLabel`/`accessibilityHint`** — see shared component fix below.

---

## Sheets + Slides + Code Surfaces

### 🔴 Must-fix (9)

#### SheetDetailView

39. **Title TextField missing `accessibilityLabel`** (`SheetDetailView.swift:156`)
    - **Fix:** `.accessibilityLabel("Sheet title")`.

40. **Formula bar TextField missing `accessibilityLabel`** (`SheetDetailView.swift:247`)
    VoiceOver reads placeholder "Enter value…" — not a label.
    - **Fix:** `.accessibilityLabel("Cell formula for \(cellAddressLabel)")`.

41. **"Create 5 × 4 grid" button missing `accessibilityLabel`** (`SheetEditorView.swift:98`)
    - **Fix:** `.accessibilityLabel("Create a 5 by 4 grid")`.

#### SlideDeckDetailView

42. **Title TextField missing `accessibilityLabel`** (`SlideDeckDetailView.swift:166`)
    - **Fix:** `.accessibilityLabel("Slide deck title")`.

43. **`SlideThumbnailView` with `.onTapGesture` bypasses keyboard nav** (`SlideDeckDetailView.swift:254–257`)
    - **Fix:** Wrap in `Button { selectedSlideIndex = slide.index } label: { SlideThumbnailView(...) }`.

44. **"Add Slide" Menu button missing `accessibilityLabel`** (`SlideDeckDetailView.swift:237–244`)
    VoiceOver reads icon name.
    - **Fix:** `.accessibilityLabel("Add new slide")` on the Menu.

#### CodeSurfaceView

45. **Detail tab Picker missing `accessibilityLabel`** (`CodeSurfaceView.swift:62`)
    - **Fix:** `.accessibilityLabel("Detail panel tabs")`.

#### CodeDetailView

46. **Focus toggle button missing `accessibilityLabel`** (`CodeDetailView.swift:114–128`)
    - **Fix:** `.accessibilityLabel(isFocusMode ? "Exit Focus" : "Focus")`.

### 🟡 Should-fix (6)

47. **Delete sheet shortcuts reversed** (`SheetDetailView.swift:380–382`)
    - **Fix:** Swap: Cancel → `.cancelAction`, Delete → `.defaultAction`.

48. **Formula bar cell-address background low contrast** (`SheetDetailView.swift:230`)
    `Color(.quaternarySystemFill)` on `.caption` text may be too subtle.
    - **Fix:** Consider `Color(.tertiarySystemFill)` or verify contrast.

49. **Slide context menu label repetitive** (`SlideDeckDetailView.swift:275`)
    "Layout: \(layout.displayName)" appears twice (menu title + button). Simplify.

50. **Link button disabled state missing `accessibilityHint`** (`SlideDeckDetailView.swift:359`)
    - **Fix:** `.accessibilityHint("Enter a valid UUID to enable linking")`.

51. **CodeSurfaceView status text may render empty Text** (`CodeSurfaceView.swift:91–95`)
    - **Fix:** Guard with `if !viewModel.statusMessage.isEmpty`.

52. **`RibbonButton` / `RibbonToggleButton` — no `accessibilityLabel`** (`TesseraEditorToolbar.swift:555, 596`)
    All icon-only toolbar buttons are unnamed to VoiceOver.
    - **Fix:** Add `.accessibilityLabel(label)` (the label text is already present) to each button's root.

### ⚪ Nice-to-have (3)

53. **Delete sheet body uses technical jargon** (`SheetDetailView.swift:377`)
    "Hard delete removes the row" → "This permanently removes the sheet. The change history is preserved."

54. **Status bar error text uses hard-coded `.red`** (`CodeDetailView.swift:149`)
    Prefer `Color(.systemRed)` for semantic correctness.

55. **`SurfaceMetadataRow` error text uses `.red`** (`SurfaceMetadataRow.swift`)
    Same as above; migrate to `Color(.systemRed)`.

---

## Shared Components

### `SurfaceLinkedEntityChip`

**🔴 Must-fix: Hard-coded icon colors** (`SurfaceLinkedEntityChip.swift:78–86`)
```swift
// BEFORE
case CalendarLinkType.attendeeOf.rawValue: return .blue
case CalendarLinkType.prepDocument.rawValue: return .purple
case CalendarLinkType.prepTask.rawValue: return .green
case CalendarLinkType.reminderFor.rawValue: return .yellow
```
`.yellow` is invisible in dark mode. All four fail Dark Mode / Increase Contrast.
- **Fix (quick):** Replace `.yellow` → `.orange`, keep others. Add `.accessibilityLabel` (see below).
- **Fix (preferred):** Define semantic Color assets in asset catalog with light/dark variants.

**🔴 Must-fix: Button missing `accessibilityLabel`** (`SurfaceLinkedEntityChip.swift:38–65`)
- **Fix:** `.accessibilityLabel("Linked \(link.linkType.isEmpty ? "entity" : link.linkType): \(label)")` + `.accessibilityHint("Double-tap to navigate to this linked material")`.

---

### `SurfaceTagBar`

**🔴 Must-fix: Tag chip buttons missing `accessibilityLabel`** (`SurfaceTagBar.swift:30–46`)
- **Fix:** Add `.accessibilityLabel("Remove tag \(tag)")` + `.accessibilityHint("Double-tap to remove the tag '\(tag)'")` to the chip Button.

---

### `SurfaceFocusStatusBar`

**🔴 Must-fix: Exit Focus button missing explicit `accessibilityLabel`/`accessibilityHint`** (`SurfaceFocusStatusBar.swift:27–34`)
- **Fix:**
```swift
Button(action: onExit) {
    Label("Exit Focus", systemImage: "arrow.up.right.and.arrow.down.left.rectangle")
        .font(.caption)
}
.buttonStyle(.plain)
.foregroundStyle(.secondary)
.help("Exit focus mode (Escape)")
.accessibilityLabel("Exit Focus mode")
.accessibilityHint("Press Escape to exit focus mode.")
```
Fixes NoteEditorView, DocEditorView, NoteDetailView, DocDetailView.

---

### `TesseraEditorToolbar`

**🔴 Must-fix: `RibbonButton`/`RibbonToggleButton`/`StyleButton` missing `accessibilityLabel`** (`TesseraEditorToolbar.swift:547–580`)
- **Fix:** Add `.accessibilityLabel(shortcutHint)` to each button's root. For example:
```swift
Button(action: action) { Image(systemName: iconName) ... }
    .buttonStyle(.plain)
    .help(shortcutHint)
    .accessibilityLabel(label)  // ← add: the label is already in the view
```

**🔴 Must-fix: `RouteChip` hard-coded `Color.green`/`Color.blue`** (`TesseraEditorToolbar.swift:17`)
- **Fix:** Add `.accessibilityLabel("AI route: \(aiRoute == "local" ? "Granite running locally" : "Cloud endpoint")")` so color is not the only signal. Preferred: define semantic Color assets.

**🟡 Should-fix: `.buttonStyle(.plain)` on `RibbonTabButton` may suppress focus rings** (`TesseraEditorToolbar.swift:541`)
- **Fix:** Add `.focusable()` with a custom focus ring when `activeTab == tab`.

**🟡 Should-fix: `RibbonToggleButton` active indicator low contrast** (`TesseraEditorToolbar.swift:617, 621`)
- **Fix:** Verify `Color.accentColor.opacity(0.15)` meets 3:1 contrast ratio; consider higher opacity or fixed semantic indicator.

**🟡 Should-fix: AI Rewrite Menu missing `accessibilityLabel`** (`TesseraEditorToolbar.swift:321–340`)
- **Fix:** `.accessibilityLabel("AI Rewrite")` + `.accessibilityValue("\(RewriteMode.allCases.count) modes available")`.

**🟡 Should-fix: Track Changes badge white text on orange** (`TesseraEditorToolbar.swift`)
- **Fix:** Verify contrast at 8pt font size meets 4.5:1; consider `Color(.systemOrange)` with explicit dark-mode variant.

---

## Implementation Priority Order

### Phase 1: Shared components (fix once → benefits all surfaces)
1. `SurfaceLinkedEntityChip` — icon colors (dark mode) + `accessibilityLabel` on button
2. `SurfaceTagBar` — tag chip `accessibilityLabel`
3. `SurfaceFocusStatusBar` — Exit Focus button explicit `accessibilityLabel` + `accessibilityHint`
4. `TesseraEditorToolbar` — `RibbonButton`/`RibbonToggleButton`/`StyleButton` `accessibilityLabel`

### Phase 2: High-frequency surfaces (most visible)
5. NoteDetailView — tag chips, pin/archive/link toggles, delete sheet shortcuts, focus shortcut wiring
6. DocDetailView — tag chips, favorite/archive/trash/link toggles, delete sheet shortcuts
7. SheetDetailView — title/formula TextFields, delete sheet shortcuts

### Phase 3: Medium-frequency surfaces
8. CalendarSurfaceView — quick-add a11y, event row buttons, DatePicker/Today labels
9. ContactsView — ContactRow label, reload button, import sheet, non-semantic colors
10. RemindersView — ReminderRow label, status colors, settings button
11. SlideDeckDetailView — title TextField, thumbnail keyboard nav, add-slide label, delete shortcuts

### Phase 4: Nice-to-have
12. Keyboard shortcut collision: remap ⌘E/⌘R to Shift variants
13. Error text: migrate `.red` → `Color(.systemRed)` across all views
14. Misc: double padding, fixed frame, placeholder text, emoji treatment
