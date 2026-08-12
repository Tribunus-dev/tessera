# HIG Review: Calendar + Contacts + Reminders Surfaces

## Summary

**5 must-fix · 7 should-fix · 5 nice-to-have**

| Surface / Component | Must-fix | Should-fix | Nice-to-have |
|---|---|---|---|
| `CalendarSurfaceView` | 1 | 1 | 1 |
| `ContactsView` | 2 | 2 | 2 |
| `RemindersView` | 1 | 1 | 0 |
| `TesseraEditorToolbar` | 1 | 1 | 1 |
| `SurfaceLinkedEntityChip` | 0 | 1 | 1 |
| `SurfaceFocusStatusBar` | 0 | 1 | 0 |

---

## CalendarSurfaceView

### Must-fix

1. **Missing accessibilityLabel on TextField + Button in `quickAddBar`** (`CalendarSurfaceView.swift:182–201`)

   The `TextField` has no `accessibilityLabel`; its placeholder text is a long example string ("\"Lunch with John tomorrow…\"") — placeholder text is **not** exposed to VoiceOver. The companion "Add" `Button` also lacks `accessibilityLabel` and `accessibilityHint`.

   ```swift
   // BEFORE — no a11y
   TextField(
       "\"Lunch with John tomorrow at noon\", ...",
       text: $model.quickAddText
   )
   Button("Add") { ... }

   // AFTER
   TextField(
       "Quick-add event",
       text: $model.quickAddText
   )
   .accessibilityLabel("Quick-add event")
   Button("Add") { ... }
       .accessibilityLabel("Add event")
       .accessibilityHint("Creates an event from the text above.")
   ```

   Ref: HIG §3 — every interactive element needs an accessible name.

### Should-fix

2. **Missing accessibilityLabel on event row buttons in `upcomingList`** (`CalendarSurfaceView.swift:125–144`)

   Each `Button` in the upcoming list shows `event.title` visually but VoiceOver has no explicit label. The button's inner `HStack` content is traversed as a fallback but is fragile.

   ```swift
   Button { ... } label: {
       HStack(spacing: 6) { ... }
   }
   .accessibilityLabel("\(event.title), \(whenLabel(event))")
   ```

   Ref: HIG §3.

3. **Missing accessibilityLabel on sidebar `DatePicker` and "Today" `Button`** (`CalendarSurfaceView.swift:77–109`)

   The `DatePicker` shows the label "Date" as a visible string but has no `accessibilityLabel`. The "Today" button has no `accessibilityLabel` or `accessibilityHint`.

   ```swift
   DatePicker("Date", selection: ...)
       .accessibilityLabel("Selected date")

   Button("Today") { model.goToToday() }
       .accessibilityLabel("Go to today")
       .accessibilityHint("Navigates to the current date.")
   ```

   Ref: HIG §3.

### Nice-to-have

4. **Placeholder text in quick-add bar is an example string, not a prompt** (`CalendarSurfaceView.swift:188`)

   The placeholder shows a literal natural-language example rather than a descriptive prompt. This is visible text that doubles as the placeholder, making it verbose for repeated use. Use a shorter prompt and provide the examples elsewhere (e.g. in a `help` tooltip).

   Ref: HIG §2.9 Writing / §13.2 Text fields.

---

## ContactsView

### Must-fix

5. **Missing accessibilityLabel on `ContactRow` buttons** (`ContactsView.swift:201–232`)

   The `ContactRow` wraps an `HStack` in a button-like row but exposes no `accessibilityLabel`. VoiceOver will traverse the inner text but the row has no accessible name.

   ```swift
   HStack(alignment: .center, spacing: 10) { ... }
       .accessibilityElement(children: .combine)
       .accessibilityLabel(contact.accessibilityName) // add computed property
   ```

   Ref: HIG §3.

6. **Missing accessibilityLabel on `ContactDetailView` export button** (`ContactsView.swift:281–287`)

   The export toolbar button has `Label("Export as VCard", systemImage: ...)` and `.accessibilityLabel("Export as VCard")` which is correct — but the same pattern is missing on the reload toolbar button in `ContactsView` itself: it has `.help("Reload contacts")` but no `.accessibilityLabel` (line 74).

   ```swift
   Button { ... } label: {
       Image(systemName: "arrow.clockwise") ...
   }
   .help("Reload contacts")
   .accessibilityLabel("Reload contacts") // ← add
   ```

   Ref: HIG §3.

### Should-fix

7. **`GraphNode.color(for:)` is not a semantic color** (`ContactsView.swift:209, 321`)

   `foregroundStyle(GraphNode.color(for: "contact"))` returns a hardcoded or computed color — not a `Color` from the semantic system palette. This means it may not adapt to Dark Mode, Increase Contrast, or the user's accent color. Use a system semantic color, or if brand color is intentional, ensure a Dark Mode variant.

   Ref: HIG §2.1 Color / §3 Accessibility contrast.

8. **`.quaternary` material on subtype badge is non-standard** (`ContactsView.swift:334`)

   `Color(.quaternaryLabelColor)` is documented in HIG §2.1 but `.background(.quaternary, in: Capsule())` is a **fill** usage — `.quaternaryLabelColor` is a label/text color, not a fill. Use `Color(.controlBackgroundColor)` with an appropriate opacity, or `Color(.separatorColor)` for a subtle background.

   Ref: HIG §2.1 Color.

9. **Missing `accessibilityLabel` on `VCardImportSheet` "Choose file" and "Import" buttons** (`ContactsView.swift:544–571`)

   ```swift
   Button("Choose file…") { ... }
       .accessibilityLabel("Choose VCard file")

   Button("Import") { ... }
       .accessibilityLabel("Import selected VCard file")
   ```

   Ref: HIG §3.

### Nice-to-have

10. **Double padding in `ContactRow`** (`ContactsView.swift:230`)

    `ContactRow` adds `.padding(.vertical, 2)` to the outer `HStack`, but `List` already provides row padding. This can create double vertical padding. Remove or reduce to `.padding(.vertical, 1)`.

    Ref: HIG §2.4 Layout.

11. **`VCardImportSheet` uses fixed frame size** (`ContactsView.swift:576`)

    `.frame(width: 480, height: 200)` is a fixed frame that won't adapt to Dynamic Type text scaling (macOS base 13 pt / minimum 10 pt). Use a flexible layout or at minimum a minimum size.

    Ref: HIG §2.4 Layout adaptability.

---

## RemindersView

### Must-fix

12. **Missing accessibilityLabel on `ReminderRow`** (`RemindersView.swift:241–271`)

    The `ReminderRow` has no `accessibilityLabel` or `accessibilityValue`. VoiceOver traverses the inner text but the combined semantic meaning (title + status + time) is not explicit.

    ```swift
    var body: some View {
        HStack(...) {
            ...
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(accessibilityValue)
    }

    // Suggested computed properties:
    // accessibilityName: "\(reminder.title), \(reminder.priority.shortLabel)"
    // accessibilityValue: "\(rowIcon) \(timeDescription)"
    ```

    Ref: HIG §3.

### Should-fix

13. **Status/priority colors use literal non-semantic colors** (`RemindersView.swift:279–292`)

    `rowColor` and `priorityColor` return literal `Color.green`, `.orange`, `.yellow`, `.red`. These are not system semantic colors and may fail contrast checks in Dark Mode or Increase Contrast.

    This is partially mitigated by the icon + text on the same row (icon-only color deficiency is the anti-pattern), but the colors still need semantic replacements:

    ```swift
    // Replace:
    private var rowColor: Color {
        if reminder.isAcknowledged() { return .green }
        if reminder.isSnoozed() { return .orange }
        return .yellow
    }

    // With semantic system colors or defined tokens:
    private var rowColor: Color {
        if reminder.isAcknowledged() { return .green } // → system teal or accent
        if reminder.isSnoozed() { return .orange }    // → system orange
        return .yellow                                 // → system accent or blue
    }
    ```

    Ref: HIG §2.1 Color — use system colors or ensure dark/contrast variants exist.

### Nice-to-have

14. **`notificationsDisabledBanner` Button "Open Settings" missing `accessibilityLabel`** (`RemindersView.swift:216–222`)

    The button shows "Open Settings" text but should also carry an explicit `accessibilityLabel` and `accessibilityHint`:

    ```swift
    Button("Open Settings") { ... }
        .accessibilityLabel("Open system settings")
        .accessibilityHint("Opens macOS System Settings to the Notifications pane.")
    ```

    Ref: HIG §3.

---

## TesseraEditorToolbar

### Must-fix

15. **All `RibbonButton` instances missing `accessibilityLabel`** (`TesseraEditorToolbar.swift:547–580`)

    `RibbonButton` has a `.help(shortcutHint)` for the tooltip but no `accessibilityLabel`. VoiceOver users will hear the label text but not the shortcut hint, and icon-only buttons (no label) will be unnamed.

    ```swift
    var body: some View {
        Button(action: action) { ... }
        .buttonStyle(.plain)
        .help(shortcutHint)
        .accessibilityLabel(shortcutHint) // e.g. "Bold (⌘B)"
    }
    ```

    Same applies to `RibbonToggleButton` and `StyleButton`.

    Ref: HIG §3.

### Should-fix

16. **`.buttonStyle(.plain)` on `RibbonTabButton` may suppress focus rings** (`TesseraEditorToolbar.swift:541`)

    macOS focus rings are suppressed by `.buttonStyle(.plain)`. Add an explicit focus ring or ensure `.focusable()` is set with a custom focus style when `activeTab == tab`:

    ```swift
    .buttonStyle(.plain)
    .focusable()
    .background {
        if activeTab == tab {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor, lineWidth: 2)
        }
    }
    ```

    Ref: HIG §3 Mobility / §16.1 Keyboards.

17. **`RibbonToggleButton` uses `.accentColor` for active indicator** (`TesseraEditorToolbar.swift:617, 621`)

    `Color.accentColor.opacity(0.15)` and `.accentColor.opacity(0.3)` are acceptable accent usages, but verify they meet 3:1 contrast ratio for non-text elements. The accent color can be customized by the user in macOS System Settings → Appearance; a low-opacity accent on white may fail contrast at small sizes (the active indicator is ~2–4 px wide). Consider `Color.accentColor` at a higher opacity or a fixed semantic indicator color.

    Ref: HIG §3 Accessibility contrast / §2.1 Color.

### Nice-to-have

18. **`aiRewriteMenu` "AI Rewrite" button lacks `accessibilityLabel`** (`TesseraEditorToolbar.swift:321–340`)

    The menu button shows an icon-only label. Add:

    ```swift
    .help("AI Rewrite")
    .accessibilityLabel("AI Rewrite")
    .accessibilityValue("\(RewriteMode.allCases.count) modes available")
    ```

    Ref: HIG §3.

---

## Shared Components Used

### SurfaceLinkedEntityChip

**Should-fix:**

19. **Icon colors are non-semantic literals** (`SurfaceLinkedEntityChip.swift:78–86`)

    ```swift
    private var iconColor: Color {
        case CalendarLinkType.attendeeOf.rawValue: return .blue
        case CalendarLinkType.prepDocument.rawValue: return .purple
        case CalendarLinkType.prepTask.rawValue: return .green
        case CalendarLinkType.reminderFor.rawValue: return .yellow
        default: return .secondary
    }
    ```

    `.blue`, `.purple`, `.green`, `.yellow` are not system semantic colors. The icon color conveys link-type meaning alongside the `linkType` text badge, which mitigates the pure-color-dependency concern — but the colors still need Dark Mode variants or system color equivalents.

    Ref: HIG §2.1 Color — inclusive color: don't rely on color alone (partially satisfied: text badge exists), but ensure Dark Mode correctness.

**Nice-to-have:**

20. **`SurfaceLinkedEntityChip` Button has no explicit `accessibilityLabel`** (`SurfaceLinkedEntityChip.swift:38–64`)

    The chip is a `.plain` button showing `label` + icon. Add:

    ```swift
    .accessibilityLabel("Linked \(link.linkType.isEmpty ? "entity" : link.linkType): \(label)")
    ```

    Ref: HIG §3.

---

### SurfaceFocusStatusBar

**Should-fix:**

21. **"Exit Focus" Button uses `.buttonStyle(.plain)` with no `accessibilityLabel`** (`SurfaceFocusStatusBar.swift:27–33`)

    ```swift
    Button(action: onExit) {
        Label("Exit Focus", systemImage: "arrow.up.right.and.arrow.down.left.rectangle")
            .font(.caption)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help("Exit focus mode (Escape)")
    ```

    The button shows a `Label` visually but has no `accessibilityLabel` — VoiceOver will use the `Label`'s text "Exit Focus" as the default, which is acceptable, but the `.help` tooltip hint is not exposed to VoiceOver. Add:

    ```swift
    .accessibilityLabel("Exit Focus")
    .accessibilityHint("Press Escape to exit focus mode.")
    ```

    Ref: HIG §3.

---

## Additional Observations

- **NavigationSplitView** is used correctly in all three surfaces. Column widths are specified. This is the correct macOS pattern.

- **`.searchable(text:)`** in `ContactsView` uses the correct SwiftUI API with a prompt string.

- **Toolbar placement** uses `.primaryAction` and `.secondaryAction` which are correct placements.

- **`ContentUnavailableView`** is used consistently for empty/loading/error states — this is the correct HIG pattern.

- **`VCardImportSheet`** does not use a `.toolbar` with a `cancellationAction` close button. Instead it uses `Button("Cancel")` inline. This works but diverges from the standard macOS sheet pattern of using `ToolbarItem(placement: .cancellationAction)`. The sheet presentation (`.sheet(isPresented:)`) is correct.

- **No Dynamic Type issues** — macOS does not support Dynamic Type (HIG §2.2), so text scaling tests are not required. However, fixed-frame components (e.g. the VCard sheet) should prefer flexible layouts.

- **No Reduce Motion violations** detected — no custom animations present in these surfaces.

- **`@Environment(\.accessibilityReduceMotion)`** is not currently checked in any of these views; not required as no custom animations exist yet.
