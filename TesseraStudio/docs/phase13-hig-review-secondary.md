# HIG Review: Secondary Surfaces — Tier 3

**Reviewer:** Agent C (Worker)
**Date:** 2026-08-12
**Scope:** VersionHistorySheet, CommentsSidebarView, FindReplaceBar, NotesView, DocsListView, SheetsListView, SlidesListView
**HIG source:** apple-hig skill (refs: foundations.md §§2–3, platforms.md §§4.1–4.6, inputs.md §16.1)
**Live HIG:** https://developer.apple.com/design/human-interface-guidelines/

---

## Severity legend

| Rating | Meaning |
|--------|---------|
| **must** | Violates a hard HIG rule; blocks App Store / causes immediate accessibility failure |
| **should** | Violates a strong HIG guideline; meaningful improvement with moderate effort |
| **nice** | Polish, consistency, or minor a11y gap; defer until must/should items are cleared |

---

## 1. VersionHistorySheet

**File:** `Views/Docs/VersionHistorySheet.swift`

### 1.1 — Icon-only dismiss button with no accessibility label
- **Label:** VHS-01: Unlabeled close button
- **Description:** The Done button at line 59 uses the text label `"Done"` — it is not icon-only. The close affordance is fine. However, the `receiptRow` Button (line 124) used for each version entry is a plain button with no `.accessibilityLabel()` describing which version it represents (e.g., "Version: {summary} by {actor} on {date}").
- **Affected UI element:** `receiptRow` Button, line 124–161
- **Current code location:** `VersionHistorySheet.swift:124`
- **Severity:** should
- **Fix:**
  ```swift
  .accessibilityLabel("\(receipt.summary), \(actorLabel(receipt.actor)), \(formattedDate(receipt.timestamp))")
  .accessibilityAddTraits(.isButton)
  ```

### 1.2 — Selection indicated by color alone
- **Label:** VHS-02: Color-as-sole-signal for selection
- **Description:** Selected receipt row is indicated solely by `Color.accentColor.opacity(0.08)` background (line 157). There is no label, border, or other distinguishing characteristic. Color-blind users cannot perceive this. HIG §2.1 requires pairing color with at least one additional visual signal.
- **Affected UI element:** Selected receipt row background, `receiptRow`, line 157
- **Current code location:** `VersionHistorySheet.swift:157`
- **Severity:** must
- **Fix:** Add a leading accent bar or a visible border. For example, replace the circle indicator with a filled accent bar:
  ```swift
  Rectangle()
      .fill(selectedReceipt?.id == receipt.id ? Color.accentColor : Color.clear)
      .frame(width: 3)
  ```
  And keep the accent-opacity background as a secondary signal.

### 1.3 — Receipt ID monospaced text below minimum font size
- **Label:** VHS-03: 10pt receipt ID text
- **Description:** `receipt.id.uuidString.prefix(8)` is displayed at `.font(.system(size: 10, design: .monospaced))` (line 252). macOS minimum readable text is 10pt (HIG §2.2); this meets the floor but is at the very edge. More importantly, the value displayed (`uuid.prefix(8) + "…"`) has no `accessibilityLabel()` and VoiceOver users hear "button, 8 characters" — meaningless.
- **Affected UI element:** Receipt ID truncated display, `signatureSection`, line 251–252
- **Current code location:** `VersionHistorySheet.swift:251–252`
- **Severity:** should
- **Fix:** Increase to 11pt minimum and add an `accessibilityLabel`:
  ```swift
  Text(receipt.id.uuidString.prefix(8) + "…")
      .font(.system(size: 11, design: .monospaced))
      .accessibilityLabel("Receipt ID: \(receipt.id.uuidString)")
  ```

### 1.4 — Sheet title uses `.headline` instead of `.title3`
- **Label:** VHS-04: Sheet header uses wrong typographic weight
- **Description:** The sheet header title "Version History" uses `.font(.headline)` (line 57). For a sheet or window title, HIG §2.2 recommends `.title3` (or `.title` for prominent headers). `.headline` is for important content within content, not top-level labels.
- **Affected UI element:** Sheet header title, line 56–57
- **Current code location:** `VersionHistorySheet.swift:56–57`
- **Severity:** nice
- **Fix:** Change to `.font(.title3)`.

### 1.5 — No keyboard navigation between receipt rows
- **Label:** VHS-05: No keyboard navigation in receipt list
- **Description:** The receipt list uses `LazyVStack` with `Button` rows but has no keyboard support. Users cannot tab to a receipt row or use arrow keys to navigate the list. This is a Full Keyboard Access gap (HIG §16.1).
- **Affected UI element:** `receiptList`, line 112–121
- **Current code location:** `VersionHistorySheet.swift:112–121`
- **Severity:** should
- **Fix:** Wrap in a `List` (which handles keyboard navigation natively) or add explicit `.focusSection()` and keyboard handlers. Prefer `List` for row selection patterns.

---

## 2. CommentsSidebarView

**File:** `Views/Editor/CommentsSidebarView.swift`

### 2.1 — Icon-only close button with no accessibility label
- **Label:** CS-01: Unlabeled close button
- **Description:** The dismiss `Button` at line 95–101 uses only `Image(systemName: "xmark")` with no label or hint. VoiceOver users hear "xmark, button" — no action context.
- **Affected UI element:** Close button in `headerBar`, line 95–101
- **Current code location:** `CommentsSidebarView.swift:95–101`
- **Severity:** must
- **Fix:**
  ```swift
  Button { onDismiss() } label: {
      Image(systemName: "xmark")
  }
  .buttonStyle(.plain)
  .accessibilityLabel("Close review panel")
  .help("Close review panel")
  ```

### 2.2 — Track changes color-as-sole-signal for insertion/deletion
- **Label:** CS-02: Color-as-sole-signal for track changes
- **Description:** Insertions are indicated by `.green` icons and backgrounds; deletions by `.red`. No additional visual signal (icon shape, label text, pattern) distinguishes them. This fails inclusive color requirements (HIG §2.1). Red/green color blindness affects ~8% of males.
- **Affected UI element:** `TrackChangeCard` icon + text color, lines 301–302, 318–319
- **Current code location:** `CommentsSidebarView.swift:301–302, 318–319`
- **Severity:** must
- **Fix:** Use distinct SF Symbols alongside color:
  ```swift
  Image(systemName: change.type == .insertion ? "plus.circle.fill" : "minus.circle.fill")
      .foregroundStyle(change.type == .insertion ? .green : .red)
  // Add a text label for screen readers:
  .accessibilityLabel(change.type == .insertion ? "Insertion" : "Deletion")
  ```
  For the text style, add an icon prefix or use strikethrough (already present) as a semantic signal — but strikethrough alone is not sufficient either.

### 2.3 — Deletion text on red background: poor contrast
- **Label:** CS-03: Low contrast deletion text on colored background
- **Description:** Deletion text at line 319 uses `.foregroundStyle(.red)` on a `Color.red.opacity(0.08)` background (line 325). Even at 8% opacity, solid red text on a red-tinted background reduces contrast for users with color vision deficiencies. Combined with VHS-02, this compound color-only approach is doubly problematic.
- **Affected UI element:** Deletion text in `TrackChangeCard`, line 318–326
- **Current code location:** `CommentsSidebarView.swift:318–326`
- **Severity:** must
- **Fix:** Use `.red` only for the background tint (not foreground text), or switch deletion text to `.primary` while keeping the background tint and strikethrough as signals.

### 2.4 — Comment action buttons without accessibility labels
- **Label:** CS-04: Unlabeled action buttons
- **Description:** "Go to", "Reply", and "Resolve" buttons (lines 254–262) have no `.accessibilityLabel()`. VoiceOver reads them as their text content, which is marginally acceptable, but "Go to" is ambiguous — users won't know what it goes to.
- **Affected UI element:** Action buttons in `CommentThreadCard`, lines 254–262
- **Current code location:** `CommentsSidebarView.swift:254–262`
- **Severity:** should
- **Fix:**
  ```swift
  Button("Go to", action: onNavigate)
      .accessibilityLabel("Go to comment location")
      .controlSize(.small)
  Button("Reply", action: onReply)
      .accessibilityLabel("Reply to comment")
      .controlSize(.small)
  ```

### 2.5 — CommentThreadCard uses `.onTapGesture` without keyboard support
- **Label:** CS-05: Non-keyboard-navigable tap target
- **Description:** `CommentThreadCard` expands/collapses via `.contentShape(Rectangle()).onTapGesture(perform: onSelect)` (line 228). This is not keyboard-accessible — VoiceOver users cannot expand a comment thread. The card has no `.focusable()` modifier.
- **Affected UI element:** `CommentThreadCard` selection, line 227–228
- **Current code location:** `CommentsSidebarView.swift:227–228`
- **Severity:** should
- **Fix:** Either wrap the header in a `Button` (which already handles keyboard) or add `.focusable()` with a keyboard handler:
  ```swift
  .focusable()
  .onKeyPress(.space) { onSelect(); return .handled }
  ```

### 2.6 — "Resolved" label uses icon-only signal
- **Label:** CS-06: Icon-only "Resolved" label
- **Description:** The resolved state at line 222–225 uses `Label("Resolved", systemImage: "checkmark.circle.fill")`. The icon alone is 9pt (`font(.system(size: 9))`), which is below the macOS minimum. VoiceOver will announce "checkmark circle filled, Resolved" — the text label is present so this is accessible, but the 9pt font is too small.
- **Affected UI element:** Resolved badge in `CommentThreadCard`, lines 221–225
- **Current code location:** `CommentsSidebarView.swift:221–225`
- **Severity:** nice
- **Fix:** Increase font size to 11pt minimum.

### 2.7 — Thread message timestamps at 9pt
- **Label:** CS-07: 9pt timestamps below minimum
- **Description:** Timestamps in expanded messages use `font(.system(size: 9))` (lines 239–240). This is below the 11pt macOS minimum (HIG §2.2).
- **Affected UI element:** Timestamp text in `CommentThreadCard` expanded messages, line 239–241
- **Current code location:** `CommentsSidebarView.swift:239–241`
- **Severity:** should
- **Fix:** Change to `.caption` (adapts with system) or explicitly `.system(size: 11)`.

---

## 3. FindReplaceBar

**File:** `Views/Editor/FindReplaceBar.swift`

### 3.1 — Icon-only dismiss button without accessibility label
- **Label:** FRB-01: Unlabeled close button
- **Description:** The dismiss button at line 169–174 uses only `Image(systemName: "xmark")`. No VoiceOver label.
- **Affected UI element:** Dismiss button, lines 169–174
- **Current code location:** `FindReplaceBar.swift:169–174`
- **Severity:** must
- **Fix:** Add `.accessibilityLabel("Close find bar")`.

### 3.2 — Toggle buttons without accessibility labels
- **Label:** FRB-02: Unlabeled option toggle buttons
- **Description:** The `Aa`, `text.alignleft`, and `.*` toggle buttons (lines 102–125) have only a visual label and a `.help()` tooltip. They have no `.accessibilityLabel()`. VoiceOver users hear the SF Symbol name — meaningless.
- **Affected UI element:** Case sensitive, whole word, and regex toggles, lines 102–125
- **Current code location:** `FindReplaceBar.swift:102–125`
- **Severity:** must
- **Fix:**
  ```swift
  Toggle(isOn: $isCaseSensitive) {
      Text("Aa")
          .font(.system(size: 10, weight: .bold))
  }
  .toggleStyle(.button)
  .buttonStyle(.plain)
  .accessibilityLabel("Case sensitive")
  .accessibilityValue(isCaseSensitive ? "On" : "Off")
  .help("Case sensitive")
  ```
  (Repeat pattern for whole word and regex toggles.)

### 3.3 — Color-as-sole-signal for "No results" state
- **Label:** FRB-03: Red text as sole signal for no results
- **Description:** The match counter at line 74–78 turns red (`.red`) when `matchCount == 0`. This is color-only signaling. Color-blind users see no difference.
- **Affected UI element:** Match counter, lines 74–78
- **Current code location:** `FindReplaceBar.swift:74–78`
- **Severity:** must
- **Fix:** Use a semantic text change alongside color:
  ```swift
  Text(matchCount > 0 ? "\(currentMatch)/\(matchCount)" : "No matches")
      .font(.system(size: 10))
      .foregroundStyle(matchCount > 0 ? Color.secondary : Color.red)
      .accessibilityLabel(matchCount > 0 ? "\(currentMatch) of \(matchCount) matches" : "No matches found")
  ```

### 3.4 — FindReplaceCoordinator: dead stub private computed properties
- **Label:** FRB-04: Coordinator search options always return false
- **Description:** Lines 271–281 define `isCaseSensitive`, `isWholeWord`, and `isRegex` as always-returning-`false`. These are dead code — the actual state lives on `FindReplaceBar` as `@State` variables (lines 18–20), never wired to the coordinator. The toggles are visually interactive but have no effect on search behavior.
- **Affected UI element:** `FindReplaceCoordinator`, lines 271–281
- **Current code location:** `FindReplaceBar.swift:271–281`
- **Severity:** must (functional bug)
- **Fix:** Either wire the coordinator to a shared `@Published` property on the coordinator and expose it, or remove the dead computed properties and the `searchOptions()` method (which is also dead). The bar needs a binding to the coordinator's options or a callback to update them.

### 3.5 — No Escape key to dismiss the find bar
- **Label:** FRB-05: No Escape key dismiss
- **Description:** The find bar has no keyboard shortcut to close it. Standard macOS behavior (and HIG §16.1 canonical shortcuts) is that Escape closes a find bar. The `onDismiss` callback exists but is not wired to any key press.
- **Affected UI element:** Entire `FindReplaceBar`, no keyboard handler for Escape
- **Current code location:** `FindReplaceBar.swift:45–190`
- **Severity:** should
- **Fix:** In the host view, add a `.keyboardShortcut(.escape)` to a hidden close button, or use a focused value to intercept Escape while the bar is visible:
  ```swift
  .focusedValue($.findBarVisible) { /* ... */ }
  ```
  Or at minimum, add a comment documenting that the host must wire Escape.

### 3.6 — Text fields missing accessibility labels
- **Label:** FRB-06: Unlabeled text fields
- **Description:** The find and replace `TextField`s (lines 52, 133) have placeholder text but no `.accessibilityLabel()`. VoiceOver reads "Find, text field, blank" and "Replace, text field, blank" — marginally acceptable via placeholder, but not robust.
- **Affected UI element:** Find and Replace text fields, lines 52, 133
- **Current code location:** `FindReplaceBar.swift:52, 133`
- **Severity:** nice
- **Fix:**
  ```swift
  TextField("Find", text: $findText)
      .textFieldStyle(.plain)
      .accessibilityLabel("Find text")
  TextField("Replace", text: $replaceText)
      .textFieldStyle(.plain)
      .accessibilityLabel("Replace with text")
  ```

### 3.7 — Search field auto-triggers on every keystroke
- **Label:** FRB-07: Auto-search on every character change
- **Description:** Line 58–61: `onChange(of: findText) { _, _ in onFindNext() }` fires a search on every keystroke. For large documents, this can cause performance issues. HIG §14.16 (searching) does not mandate incremental search; standard practice is to debounce.
- **Affected UI element:** Find text field, `onChange` handler, line 58–61
- **Current code location:** `FindReplaceBar.swift:58–61`
- **Severity:** nice
- **Fix:** Debounce the search:
  ```swift
  .onChange(of: findText) { _, newValue in
      Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(250))
          guard newValue == findText else { return }
          onFindNext()
      }
  }
  ```

---

## 4. List Shells (NotesView, DocsListView, SheetsListView, SlidesListView)

**Files:**
- `Views/Notes/NotesView.swift`
- `Views/Docs/DocsListView.swift`
- `Views/Sheets/SheetsListView.swift`
- `Views/Slides/SlidesListView.swift`

All four list shells share the same composite surface pattern (NavigationSplitView with sidebar + list + detail) and many violations are shared. Cross-cutting issues are listed here; per-file deviations follow.

---

### 4.1 — Tag chip buttons without accessibility labels

**Applies to:** All four files

- **Label:** LST-01: Unlabeled tag filter buttons
- **Description:** In `TagChipsView` (NotesView), `DocsTagChipsView` (DocsListView), `SheetsTagChipsView` (SheetsListView), and `SlidesTagChipsView` (SlidesListView), each tag `Button` has no `.accessibilityLabel()`. VoiceOver reads them as "button, button, button…" — the tag text is visually on the pill but not announced.
- **Affected UI elements:**
  - `TagChipsView` line 387–397 (`NotesView.swift`)
  - `DocsTagChipsView` line 349–356 (`DocsListView.swift`)
  - `SheetsTagChipsView` line 283–293 (`SheetsListView.swift`)
  - `SlidesTagChipsView` line 304–315 (`SlidesListView.swift`)
- **Severity:** must
- **Fix (apply to each):**
  ```swift
  Button {
      activeTag = (activeTag == tag) ? nil : tag
  } label: {
      TagPill(text: tag, isCompact: true)
          .opacity(activeTag == nil || activeTag == tag ? 1.0 : 0.4)
  }
  .buttonStyle(.plain)
  .accessibilityLabel("Filter by \(tag)")
  .accessibilityAddTraits(activeTag == tag ? .isSelected : [])
  ```

**Note:** `NotesView`'s `TagChipsView` already has `accessibilityLabel` at line 395 but no `.accessibilityAddTraits`. The other three views are missing both.

---

### 4.2 — Emoji in row titles without text alternative

**Applies to:** DocsListView

- **Label:** LST-02: Emoji-only doc icon without text alternative
- **Description:** `DocRowView` (line 254–257) displays an emoji as the doc icon: `Text(emoji).font(.caption)`. If a VoiceOver user navigates to this row, the emoji is announced as-is (often incorrectly). No `accessibilityLabel()` on the emoji Text.
- **Affected UI element:** `DocRowView` emoji display, line 254–257
- **Current code location:** `DocsListView.swift:254–257`
- **Severity:** should
- **Fix:**
  ```swift
  if let emoji = row.iconEmoji, !emoji.isEmpty {
      Text(emoji)
          .font(.caption)
          .accessibilityLabel("Icon: \(emoji)")
  }
  ```

---

### 4.3 — Stale comment in WrappingHStack about v1

**Applies to:** DocsListView

- **Label:** LST-03: Stale v1 comment in WrappingHStack
- **Description:** `WrappingHStack` at line 369–377 contains a comment "v1 keeps this as a vertical stack of HStackes would be over-engineered; a single HStack with .lineLimit is good enough for the tag counts we see in practice. The production swap is to import Notes/FlowLayout." This is an implementation note that should not ship to users.
- **Affected UI element:** `WrappingHStack` comment, lines 369–377
- **Current code location:** `DocsListView.swift:369–377`
- **Severity:** nice
- **Fix:** Remove the stale comment. Either implement a proper wrapping layout or import `FlowLayout`.

---

### 4.4 — Inconsistent tag pill styling across surfaces

**Applies to:** All four files

- **Label:** LST-04: Inconsistent tag pill design
- **Description:** Each list view defines its own tag pill:
  - **NotesView:** `TagPill` — `.background(.quaternary, in: Capsule())`, `foregroundStyle(.tint)`
  - **DocsListView:** `DocTagPill` — `Capsule().fill(Color.accentColor.opacity(0.15))`, `foregroundStyle(Color.accentColor)`
  - **SheetsListView:** Inline pill — `Color(.quaternaryLabelColor).opacity(0.18)` with hardcoded white/black text
  - **SlidesListView:** Inline pill — `Color.accentColor.opacity(0.15)` with `Color.accentColor` text
- The Docs and Sheets implementations hardcode light-mode assumptions (white foreground on accent). HIG §2.8 (dark mode) requires all custom colors to have dark-mode variants.
- **Affected UI elements:**
  - `TagPill`, NotesView.swift:358–372
  - `DocTagPill`, DocsListView.swift:321–335
  - Inline pills, SheetsListView.swift:264–267
  - Inline pills, SlidesListView.swift:307–311
- **Severity:** should
- **Fix:** Unify on `TagPill` (NotesView) as the canonical implementation — it uses `.tint` and `.quaternary` which adapt correctly in dark mode. Import it into the other three views and delete the local variants.

---

### 4.5 — SheetsListView: `.font(.caption2)` below minimum size

**Applies to:** SheetsListView

- **Label:** LST-05: 9pt tag text in SheetsListView
- **Description:** `SheetRowView` at line 264 uses `Text("#\(tag)").font(.caption2)` — `.caption2` can render as small as 9pt on some system configurations, below the 11pt macOS minimum.
- **Affected UI element:** Tag text in `SheetRowView`, line 264
- **Current code location:** `SheetsListView.swift:264`
- **Severity:** should
- **Fix:** Change to `.caption` (minimum 11pt).

---

### 4.6 — SheetsListView: hardcoded light-mode foreground for active tag chip

**Applies to:** SheetsListView

- **Label:** LST-06: Hardcoded white foreground in tag chip
- **Description:** `SheetsTagChipsView` at line 290 uses `foregroundStyle(activeTag == tag ? Color.white : Color.primary)`. `Color.white` is a hardcoded light-mode value — in dark mode, white text on a colored (accent) background may fail WCAG contrast or look wrong. Should use `Color.white.opacity(0.9)` or prefer semantic color tokens.
- **Affected UI element:** Active tag chip foreground, line 290
- **Current code location:** `SheetsListView.swift:290`
- **Severity:** should
- **Fix:**
  ```swift
  .foregroundStyle(activeTag == tag ? Color.white : Color.primary)
  // Replace with:
  .foregroundStyle(activeTag == tag ? Color.white : Color.accentColor)
  ```
  Or better, adopt the `TagPill` approach which uses `.tint`.

---

### 4.7 — DocRowView emoji at `.caption` size

**Applies to:** DocsListView

- **Label:** LST-07: 12pt emoji may be below visual threshold
- **Description:** The emoji in `DocRowView` (line 256) uses `.font(.caption)` (13pt default, 12pt at some scale factors). Emoji at 12pt can be hard to read. HIG §2.5 (icons) recommends ensuring icons are legible at their display size. This is marginal.
- **Affected UI element:** Doc emoji display, line 256
- **Current code location:** `DocsListView.swift:256`
- **Severity:** nice
- **Fix:** Increase to `.body` or wrap in a fixed-size container to ensure consistent legibility.

---

## Summary Table

| ID | Surface | Category | Severity | Fix scope |
|----|---------|----------|----------|-----------|
| VHS-01 | VersionHistory | Accessibility | should | Single file |
| VHS-02 | VersionHistory | Color-as-sole-signal | **must** | Single file |
| VHS-03 | VersionHistory | Typography + a11y | should | Single file |
| VHS-04 | VersionHistory | Typography | nice | Single file |
| VHS-05 | VersionHistory | Keyboard nav | should | Single file |
| CS-01 | CommentsSidebar | Accessibility | **must** | Single file |
| CS-02 | CommentsSidebar | Color-as-sole-signal | **must** | Single file |
| CS-03 | CommentsSidebar | Color/contrast | **must** | Single file |
| CS-04 | CommentsSidebar | Accessibility | should | Single file |
| CS-05 | CommentsSidebar | Keyboard nav | should | Single file |
| CS-06 | CommentsSidebar | Typography | nice | Single file |
| CS-07 | CommentsSidebar | Typography | should | Single file |
| FRB-01 | FindReplace | Accessibility | **must** | Single file |
| FRB-02 | FindReplace | Accessibility | **must** | Single file |
| FRB-03 | FindReplace | Color-as-sole-signal | **must** | Single file |
| FRB-04 | FindReplace | Functional bug | **must** | Single file |
| FRB-05 | FindReplace | Keyboard nav | should | Single file |
| FRB-06 | FindReplace | Accessibility | nice | Single file |
| FRB-07 | FindReplace | UX / perf | nice | Single file |
| LST-01 | List shells | Accessibility | **must** | 4 files |
| LST-02 | List shells | Accessibility | should | 1 file |
| LST-03 | List shells | Code cleanliness | nice | 1 file |
| LST-04 | List shells | Dark mode + consistency | should | 4 files |
| LST-05 | List shells | Typography | should | 1 file |
| LST-06 | List shells | Color/contrast | should | 1 file |
| LST-07 | List shells | Typography | nice | 1 file |

**Total: 26 findings. 8 must-fix, 12 should-fix, 6 nice.**

---

## Critical Path (must-fix)

The following 8 items must be addressed before shipping:

1. **VHS-02** — Color-as-sole-signal for receipt selection → add accent bar or border
2. **CS-01** — Unlabeled close button in CommentsSidebar → add `.accessibilityLabel("Close review panel")`
3. **CS-02** — Color-as-sole-signal for track changes → add `.accessibilityLabel` to icons
4. **CS-03** — Low-contrast deletion text → use `.primary` text color on red background
5. **FRB-01** — Unlabeled close button in FindReplaceBar → add `.accessibilityLabel("Close find bar")`
6. **FRB-02** — Unlabeled option toggles → add `accessibilityLabel` and `accessibilityValue` to all three
7. **FRB-03** — Red text as sole signal for "no results" → add `accessibilityLabel` + semantic text change
8. **FRB-04** — Dead stub computed properties → wire coordinator to bar state or remove dead code
9. **LST-01** — Unlabeled tag filter buttons → add `accessibilityLabel` to all tag buttons in 4 files
