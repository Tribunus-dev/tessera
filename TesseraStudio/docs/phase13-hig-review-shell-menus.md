# Phase 13 HIG Review — App Shell + Menus (Tier 1)

**Date:** 2026-08-12
**Scope:** `ContentView.swift`, `TesseraStudioMacApp.swift`, `UnifiedChatDock.swift`, `ChatHistoryDrawer.swift`, `TelemetryDrawer.swift`, `OnboardingView.swift`, `WorkflowMenuActions.swift`
**Reference:** Apple HIG (skill: apple-hig) — §§1–4, §11–§13, §16

---

## Grand Summary

| Severity | Count |
|---|---|
| 🔴 must-fix | **9** |
| 🟡 should-fix | **9** |
| ⚪ nice-to-have | **3** |

**Cross-cutting priorities (fix once, benefit all surfaces):**

1. **Sidebar `Label` items** — `ForEach` renders `Label`s without explicit `accessibilityLabel`. Every sidebar item in every destination is unreadable to VoiceOver. Fix at the `Label` call site in `ContentView.swift:134`.
2. **`personaChip` hardcoded font size 9pt** — below macOS minimum (10pt). Fix in `UnifiedChatDock.swift:78`.
3. **No `accessibilityLabel` on TelemetryDrawer section collapse buttons** — every section header button is unannounced to VoiceOver. Fix once in `TelemetryDrawer.swift:163`.
4. **Keyboard shortcut collision** — `Cmd+Option+I` for inspector toggle collides with system `Show Window Info`. Fix to `Cmd+Shift+I` or `Cmd+\\`.
5. **No label on model directory `TextField`** — OnboardingView has a bare `TextField` with only a caption above it. Fix with `.accessibilityLabel("Model directory path")`.

---

## ContentView.swift

### 🔴 Must-fix

#### 1. Sidebar items lack explicit `accessibilityLabel`

- **Description:** The sidebar's `ForEach` renders `Label(dest.rawValue, systemImage: dest.icon)` for every navigation destination. SwiftUI's `Label` synthesizes an `accessibilityLabel` from `dest.rawValue`, but the group (`SidebarGroup.allCases` / `group.rawValue`) is not included. VoiceOver users navigating the sidebar hear only the item name (e.g. "Workflows") with no context about which group it belongs to or that it is a navigation item.
- **Affected UI element:** Sidebar `List` rows, all sidebar destinations
- **Current code location:** `ContentView.swift:134`
- **Severity:** must
- **Fix:**
  ```swift
  Label {
      Text(dest.rawValue)
          .accessibilityLabel("\(dest.rawValue), \(group.rawValue) section")
  } icon: {
      Image(systemName: dest.icon)
  }
  .tag(dest)
  ```
  Or add `.accessibilityLabel("\(group.rawValue), \(dest.rawValue)")` to the existing `Label`.

#### 2. Chat dock toolbar button missing `accessibilityLabel`

- **Description:** The toolbar Chat toggle button has `.help(...)` and `.accessibilityHint(...)` but no `accessibilityLabel`. VoiceOver users hear an unlabelled button.
- **Affected UI element:** Toolbar `Button("Chat", systemImage: "sidebar.right")`
- **Current code location:** `ContentView.swift:150–157`
- **Severity:** must
- **Fix:**
  ```swift
  Button(chatDockVisible ? "Hide Chat" : "Show Chat", systemImage: "sidebar.right") {
      withAnimation(reduceMotion ? nil : .default) { chatDockVisible.toggle() }
  }
  .help(chatDockVisible ? "Hide the Tessy + Sky chat dock" : "Show the Tessy + Sky chat dock")
  .accessibilityLabel(chatDockVisible ? "Hide chat dock" : "Show chat dock")
  .accessibilityHint("Shows or hides the persistent chat dock")
  .keyboardShortcut("\\", modifiers: .command)
  ```

#### 3. History toolbar button: identical tooltip and accessibility hint

- **Description:** `.help("Show or hide the chat history drawer")` and `.accessibilityHint("Shows or hides the chat history drawer")` are identical strings. HIG §14.12 says tooltips should begin with a verb; accessibility hints should describe the outcome. They must differ.
- **Affected UI element:** Toolbar `Button("History", systemImage: "sidebar.left")`
- **Current code location:** `ContentView.swift:144–149`
- **Severity:** must
- **Fix:**
  ```swift
  .help(showHistory ? "Hide chat history" : "Show chat history")
  .accessibilityLabel(showHistory ? "Hide chat history" : "Show chat history")
  .accessibilityHint("Opens or closes the chat history drawer on the left edge")
  ```

### 🟡 Should-fix

#### 4. PNG export hardcodes white background (dark mode breakage)

- **Description:** The PNG export branch renders `.background(.white)`. This produces a white image regardless of the system appearance. On dark mode, a white screenshot of a dark-themed chat transcript is visually jarring.
- **Affected UI element:** `exportConversation` PNG branch
- **Current code location:** `ContentView.swift:272`
- **Severity:** should
- **Fix:**
  ```swift
  .background(Color(nsColor: .textBackgroundColor))
  ```

#### 5. No `accessibilityLabel` on TelemetryDrawer in detail column

- **Description:** The `TelemetryDrawer` is placed in the detail column without an explicit wrapper label. VoiceOver enters the detail region and encounters unnamed content.
- **Affected UI element:** `TelemetryDrawer` in `detail` computed property
- **Current code location:** `ContentView.swift:165`
- **Severity:** should
- **Fix:** Add `.accessibilityLabel("Telemetry drawer")` to the `TelemetryDrawer` or wrap the `VStack` in an accessibility element.

#### 6. History drawer uses custom leading overlay instead of sidebar toggle

- **Description:** `ContentView.swift:72–76` uses a manual `.overlay(alignment: .leading)` with `.transition(.move(edge: .leading))` for the history drawer. This is redundant with NavigationSplitView's built-in sidebar toggle. The built-in toggle is accessible by default (VoiceOver + menu bar), animates correctly, and integrates with `View > Hide Sidebar`. The custom overlay adds a second, differently-behaved sidebar-like pane.
- **Affected UI element:** `historyDrawer` overlay
- **Current code location:** `ContentView.swift:72–76, 231–240`
- **Severity:** should
- **Fix:** Consider integrating `ChatHistoryDrawer` into the NavigationSplitView sidebar column as a collapsible section (e.g., under a "History" group in the sidebar List), which would unify the show/hide mechanism with the sidebar toggle. If the leading drawer pattern is architecturally required, ensure the History toolbar button's `help` and `accessibilityLabel` are updated to reflect "left edge drawer" not "sidebar".

---

## UnifiedChatDock.swift

### 🔴 Must-fix

#### 7. `personaChip` hardcoded font size 9pt (below macOS minimum 10pt)

- **Description:** `Text(persona.roleHint).font(.system(size: 9))` uses a hardcoded 9pt font. The macOS minimum text size is 10pt (§2.2 / §11.6). At 9pt, text may be illegible for users with visual impairments and fails the HIG minimum.
- **Affected UI element:** `personaChip` role hint text
- **Current code location:** `UnifiedChatDock.swift:78`
- **Severity:** must
- **Fix:**
  ```swift
  Text(persona.roleHint)
      .font(.caption2)
      .foregroundStyle(.secondary)
      .lineLimit(1)
  ```

### 🟡 Should-fix

#### 8. TextField `accessibilityLabel("Message")` is insufficient

- **Description:** `.accessibilityLabel("Message")` on the chat input `TextField` is too generic. VoiceOver users hear "Message text field" with no indication of the mention syntax, persona routing, or expected input.
- **Affected UI element:** Chat input `TextField`
- **Current code location:** `UnifiedChatDock.swift:149`
- **Severity:** should
- **Fix:**
  ```swift
  .accessibilityLabel("Ask Tessy or Sky. Use @tessy, @sky, or @both to route.")
  ```

#### 9. Hold-mode button help text is a full sentence (exceeds 75-char guideline)

- **Description:** `.help("Hold your horses - queue new prompts without running")` is 51 characters — within guideline. The alternate state `.help("Resume - drain queued prompts")` is 32 characters. Both are acceptable but the leading state could be tightened.
- **Affected UI element:** Hold-mode pause/resume `Button`
- **Current code location:** `UnifiedChatDock.swift:143`
- **Severity:** nice-to-have
- **Fix (optional):**
  ```swift
  .help(controller.holdMode.isPaused ? "Resume — drain queued prompts" : "Pause — queue new prompts")
  ```

#### 10. Send button tooltip and accessibility label both "Send"

- **Description:** `.accessibilityLabel("Send")` and `.help("Send")` are identical. HIG says tooltips should describe the action from the user's perspective; they should differ.
- **Affected UI element:** Send `Button`
- **Current code location:** `UnifiedChatDock.swift:151–157`
- **Severity:** should
- **Fix:**
  ```swift
  .accessibilityLabel("Send message")
  .help("Send your message to Tessy and Sky")
  ```

---

## ChatHistoryDrawer.swift

### 🔴 Must-fix

#### 11. Search field missing `accessibilityLabel`

- **Description:** The `TextField` has `.textFieldStyle(.roundedBorder)` with placeholder text "Search title, model, tool" but no `accessibilityLabel`. Placeholder text is not reliably announced by VoiceOver.
- **Affected UI element:** Search `TextField`
- **Current code location:** `ChatHistoryDrawer.swift:120–121`
- **Severity:** must
- **Fix:**
  ```swift
  TextField("Search title, model, tool", text: $searchText)
      .textFieldStyle(.roundedBorder)
      .accessibilityLabel("Search conversations by title, model, or tool")
  ```

#### 12. List rows: `.onTapGesture` on non-interactive content

- **Description:** Each list row uses `.contentShape(Rectangle()).onTapGesture { onRestore(convo) }`. VoiceOver users navigating the list hear the row text but cannot activate it — VoiceOver's list activation action (Enter/Space) does not fire `onTapGesture`. The correct SwiftUI pattern for selectable list rows is `NavigationLink` or `List` with `selection` binding.
- **Affected UI element:** `List` rows in `ChatHistoryDrawer`
- **Current code location:** `ChatHistoryDrawer.swift:144–145`
- **Severity:** must
- **Fix:** Replace the `onTapGesture` pattern with a selection binding:
  ```swift
  List(selection: $selectedConversation) {
      // ...
  }
  // and add:
  @State private var selectedConversation: Conversation?
  // then handle selection via .onChange or NavigationLink:
  NavigationLink(value: convo) { row(convo) }
  ```

### 🟡 Should-fix

#### 13. Empty state `ContentUnavailableView` missing `accessibilityLabel`

- **Description:** `ContentUnavailableView` synthesizes an `accessibilityLabel` from its title, but the title "No Conversations" does not explain what to do. VoiceOver users hear an empty state with no guidance.
- **Affected UI element:** `ContentUnavailableView("No Conversations", ...)`
- **Current code location:** `ChatHistoryDrawer.swift:136–140`
- **Severity:** should
- **Fix:**
  ```swift
  .accessibilityLabel("No conversations yet. Chat with Tessy or Sky to start a new conversation.")
  ```

#### 14. Row `.onTapGesture` vs `swipeActions` interaction conflict

- **Description:** `swipeActions` and `.onTapGesture` coexist on the same row view. When VoiceOver is off, tap-to-restore and swipe-to-delete both work. With VoiceOver, the swipe actions remain accessible but `onTapGesture` is not activated by VoiceOver's standard Enter/Space. See violation #12.
- **Affected UI element:** List row in `ChatHistoryDrawer`
- **Current code location:** `ChatHistoryDrawer.swift:144–158`
- **Severity:** should
- **Fix:** Covered by fixing #12 above.

---

## TelemetryDrawer.swift

### 🔴 Must-fix

#### 15. Section collapse buttons missing `accessibilityLabel`

- **Description:** Each `section(...)` renders a `Button` with a `chevron.right` / `chevron.down` icon as the only accessible content. VoiceOver users hear "chevron right" with no indication that the button expands or collapses the section. The chevron rotation is also animated but VoiceOver is not notified of the state change.
- **Affected UI element:** All `section(...)` header buttons
- **Current code location:** `TelemetryDrawer.swift:163–174`
- **Severity:** must
- **Fix:**
  ```swift
  Button(action: { toggle(category) }) {
      HStack {
          Label(category.rawValue, systemImage: category.icon)
              .font(.caption.bold())
          Spacer()
          Image(systemName: "chevron.right")
              .symbolRenderingMode(.hierarchical)
              .font(.caption2)
              .rotationEffect(.degrees(isCollapsed ? 0 : 90))
              .foregroundStyle(.tertiary)
      }
  }
  .buttonStyle(.plain)
  .accessibilityLabel("\(category.rawValue), \(isCollapsed ? "collapsed" : "expanded")")
  .accessibilityHint("Double tap to \(isCollapsed ? "expand" : "collapse") this section")
  .accessibilityAddTraits(.isButton)
  ```

### 🟡 Should-fix

#### 16. Sparkline `.accessibilityHidden(true)`: confirm adjacent label is announced

- **Description:** The `Sparkline` chart is marked `accessibilityHidden(true)` with the note that "the current-value text next to it carries the number for VoiceOver." This is correct if the `currentValue` text is in the same accessibility group. Verify that the enclosing `HStack` is announced as a single unit.
- **Affected UI element:** `Sparkline` chart
- **Current code location:** `TelemetryDrawer.swift:220`
- **Severity:** should
- **Fix:** Add `.accessibilityElement(children: .combine)` to the enclosing `HStack` in the `section` layout so VoiceOver announces the label + value together.

#### 17. Handle button: separate `.accessibilityLabel` vs tooltip

- **Description:** The handle button has `.accessibilityLabel(isExpanded ? "Hide telemetry" : "Show telemetry")` but the `.help(...)` is missing. The chevron icon has `.accessibilityHidden(true)` which is correct.
- **Affected UI element:** `handle` button
- **Current code location:** `TelemetryDrawer.swift:88–118`
- **Severity:** nice-to-have
- **Fix:** Add `.help(isExpanded ? "Collapse telemetry drawer" : "Expand telemetry drawer")`.

---

## OnboardingView.swift

### 🔴 Must-fix

#### 18. Feature rows missing `accessibilityLabel`

- **Description:** `OnboardingView.swift:145–156` renders feature rows with `HStack { Image(...); VStack { Text; Text } }`. Each row is a static information display — no interactive elements. VoiceOver navigates the `Image` (announces the SF Symbol name) and the two `Text` views separately, producing a fragmented read ("square grid 3x3, Calibrate, Per-tensor imatrix..."). Users miss the icon-meaning association.
- **Affected UI element:** `feature(...)` rows in `welcomePage`
- **Current code location:** `OnboardingView.swift:59–62, 145–156`
- **Severity:** must
- **Fix:**
  ```swift
  .accessibilityLabel("\(title): \(detail)")
  ```
  Apply to the returned `HStack` in `feature(...)`.

#### 19. Approval level rows missing `accessibilityLabel`

- **Description:** `approvalRow(.auto, "Run without asking.")` renders four rows in `agentPage`. VoiceOver reads each as three separate elements. The uppercase badge text and the description are disassociated.
- **Affected UI element:** `approvalRow(...)` rows in `agentPage`
- **Current code location:** `OnboardingView.swift:136–139, 158–166`
- **Severity:** must
- **Fix:** Add `.accessibilityLabel("\(level.rawValue.uppercased()): \(detail)")` to the returned `HStack` in `approvalRow(...)`.

#### 20. Model directory TextField missing `accessibilityLabel`

- **Description:** The `TextField` for model directory has a caption label above it ("Model directory") but no programmatic `accessibilityLabel`. VoiceOver users hear only "text field" with no prompt.
- **Affected UI element:** `TextField` for model directory path
- **Current code location:** `OnboardingView.swift:85`
- **Severity:** must
- **Fix:**
  ```swift
  TextField("~/Models/tessera", text: $modelDirectory)
      .textFieldStyle(.roundedBorder)
      .accessibilityLabel("Model directory path")
  ```

### 🟡 Should-fix

#### 21. Page dots lack `accessibilityLabel` and `.isSelected` trait

- **Description:** `pageDots` renders three `Circle`s with no `accessibilityLabel`. VoiceOver cannot determine which page is current. The current dot is colored differently (`.primary` vs `.quaternary`) but VoiceOver has no way to read this.
- **Affected UI element:** `pageDots` indicators
- **Current code location:** `OnboardingView.swift:168–176`
- **Severity:** should
- **Fix:**
  ```swift
  ForEach(0..<pageCount, id: \.self) { index in
      Circle()
          .foregroundStyle(index == page ? .primary : .quaternary)
          .frame(width: 8, height: 8)
          .accessibilityLabel("Page \(index + 1) of \(pageCount)")
          .accessibilityAddTraits(index == page ? .isSelected : [])
  }
  ```

#### 22. Browse button redundant `accessibilityLabel`

- **Description:** `.accessibilityLabel("Browse for the model directory")` on the Browse button restates the button label ("Browse…"). This is redundant. The button's label is already announced; the extra label adds noise.
- **Affected UI element:** Browse `Button`
- **Current code location:** `OnboardingView.swift:89`
- **Severity:** should
- **Fix:** Remove `.accessibilityLabel`. Rely on the button's text label. Optionally add `.accessibilityHint("Opens a folder picker to select the model directory")`.

---

## TesseraStudioMacApp.swift + WorkflowMenuActions.swift

### 🔴 Must-fix

#### 23. Inspector keyboard shortcut collides with system `Show Window Info`

- **Description:** `ViewMenuItems.swift:157` uses `.keyboardShortcut("i", modifiers: [.command, .option])` (⌘⌥I) for the inspector toggle. On macOS, ⌘⌥I is the standard shortcut for **Show Window Info** (equivalent to Get Info on the focused window). This shortcut is used by Finder, Safari, Xcode, and most first-party apps. Overriding it with app-specific behavior causes user confusion and potential keyboard shortcut conflicts.
- **Affected UI element:** View menu "Show/Hide Inspector" command
- **Current code location:** `WorkflowMenuActions.swift:157`
- **Severity:** must
- **Fix:** Change to `.keyboardShortcut("i", modifiers: [.command, .shift])` (⌘⇧I) or `keyboardShortcut("i", modifiers: [.command, .control])` (⌃⌘I). The HIG preference is Command-first, then Shift for related variants; Option is the third choice and should be avoided when it collides with system shortcuts.

### 🟡 Should-fix

#### 24. Help menu items: `Release Notes` URL points to a release page

- **Description:** `HelpMenuItems` opens `https://github.com/tessera/tessera/releases` for "Release Notes". On GitHub, this is a paginated list of releases, not a per-version notes page. The HIG §14.12 "Offering Help" says help content should be specific and actionable. If the intent is per-version notes, link directly to the latest release or a `RELEASES.md` file.
- **Affected UI element:** Help menu "Release Notes" item
- **Current code location:** `WorkflowMenuActions.swift:124–127`
- **Severity:** should
- **Fix:** Change URL to the latest release page directly:
  ```swift
  private let releaseNotesURL = URL(string: "https://github.com/tessera/tessera/releases/latest")
  ```
  Or link to a local `RELEASES.md` if bundled in the app.

#### 25. Help menu items: "Open Sample Workflows" opens a GitHub URL

- **Description:** "Open Sample Workflows" opens `https://github.com/tessera/tessera/tree/main/TesseraStudio/Examples`. This requires network access and GitHub authentication to browse code. The HIG §14.12 says help should be available offline and actionable. Opening a GitHub URL is indirect and requires the user to navigate the tree.
- **Affected UI element:** Help menu "Open Sample Workflows" item
- **Current code location:** `WorkflowMenuActions.swift:129–132`
- **Severity:** should
- **Fix:** Either bundle sample workflows in the app bundle (`.menuOpenSampleWorkflows()` opens a file picker for bundled `.tessera` JSON files) or link to a local documentation page bundled with the app.

#### 26. Settings keyboard shortcut is implicit (system-provided ⌘,)

- **Description:** The `Settings { SettingsView() }` scene is correctly wired via SwiftUI's `Settings` scene API, which auto-binds to ⌘, with the App menu label "Settings…". This is correct HIG behavior and no fix is needed. Listed here for completeness.
- **Affected UI element:** App > Settings menu item
- **Current code location:** `TesseraStudioMacApp.swift:99–101`
- **Severity:** ⚪ informational — no fix needed

---

## Violations by Reference (§12 Checklist)

| # | §12 Item | File(s) |
|---|---|---|
| 1 | §12.4: All interactive elements have accessibilityLabel | ContentView.swift:134, UnifiedChatDock.swift:149 |
| 2 | §12.4: Full Keyboard Access navigates all controls | ChatHistoryDrawer.swift:144–145 |
| 3 | §12.4: VoiceOver reads all UI in sensible order | TelemetryDrawer.swift:163–174, OnboardingView.swift:59–62, 136–139 |
| 4 | §12.4: Color never only signal | TelemetryDrawer.swift uses system colors — compliant |
| 5 | §12.4: Color contrast meets 4.5:1 | All system text styles — compliant |
| 6 | §12.2: Every toolbar item in menu bar | ContentView.swift:143–158 — History/Chat toolbar buttons need explicit labels |
| 7 | §12.2: Standard keyboard shortcuts work | WorkflowMenuActions.swift:157 — ⌘⌥I collision |
| 8 | §12.2: Help menu wired with app-specific help | WorkflowMenuActions.swift:111–133 — URLs need review |
| 9 | §12.2: App uses system menu bar order | TesseraStudioMacApp.swift:56–97 — compliant |
| 10 | §12.2: Window has min/max size | ContentView.swift:71 — compliant |
| 11 | §12.2: Sidebar uses NavigationSplitView | ContentView.swift:64–68 — compliant |
| 12 | §12.2: View menu has Show/Hide Sidebar, Toolbar | SwiftUI NavigationSplitView defaults — compliant |
| 13 | §12.2: Multi-window support | WindowGroup in TesseraStudioMacApp.swift:39 — compliant |
| 14 | §12.1: No hard-coded color values | ContentView.swift:272 — .white hardcoded |
| 15 | §12.1: All text uses system text styles | UnifiedChatDock.swift:78 — font(size: 9) hardcoded |
| 16 | §12.8: Tooltips begin with a verb, ≤75 chars | ContentView.swift:144, 154; UnifiedChatDock.swift:143 |
| 17 | §12.8: Error messages specific and actionable | No error messages in shell — compliant |
| 18 | §12.8: Button labels are verbs | All button labels — compliant |
| 19 | §12.5: Light + dark mode both tested | Partially — PNG export uses hardcoded .white |
| 20 | §12.6: Animations respect Reduce Motion | All `.withAnimation(reduceMotion ? nil : ...)` — compliant |

---

## Prior-Phase Findings (resolved)

The following items were flagged in earlier phases and are confirmed resolved:

- ✅ Sidebar uses `NavigationSplitView` (§4.4) — `ContentView.swift:64`
- ✅ `.keyboardShortcut("\\", modifiers: .command)` on Chat dock toggle — `ContentView.swift:156`
- ✅ `.sheet(item: $exportItem)` for export flow — `ContentView.swift:78`
- ✅ `.inspector(isPresented: $chatDockVisible)` for chat dock — `ContentView.swift:171`
- ✅ `@Environment(\.accessibilityReduceMotion)` respected in all animations
- ✅ TelemetryDrawer handle: `.accessibilityLabel` + `.accessibilityValue` — `TelemetryDrawer.swift:114–117`
- ✅ Help menu via `CommandGroup(replacing: .help)` — `TesseraStudioMacApp.swift:80–82`
- ✅ Settings via `Settings { ... }` scene — `TesseraStudioMacApp.swift:99–101`
- ✅ `@SceneStorage` for per-window state restoration — `ContentView.swift:20–21`
- ✅ `Sparkline` marked `.accessibilityHidden(true)` with adjacent value label — `TelemetryDrawer.swift:220`

---

## Recommended Commit Tags

Based on §12.9 decomposition:

```
HIG 3.1-3.4: shell accessibility — sidebar labels, TelemetryDrawer, OnboardingView
HIG 2.7, 3.5: keyboard shortcuts — ⌘⌥I → ⌘⇧I inspector toggle
HIG 1.1, 5.1: dark mode + color — PNG export .white → system color
HIG 1.4, 3.2: text sizing — font(size: 9) → .caption2
HIG 12.8: help text — tooltip/hint deduplication
```
