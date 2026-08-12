# Phase 13 HIG Review — All Remaining Surfaces

**Date:** 2026-08-12
**Scope:** All non-Phase-12 surfaces (app shell, Settings, Intelligence hub, Email, Tasks, Onboarding, Capacity, Learning, DualAgent, Workflow editor, Graph, Code panes, Receipts, VersionHistory, Comments, FindReplace, list shells)
**Reference:** Apple HIG (skill: apple-hig) — §§1–4, §11–§13, §16

---

## Grand Summary

| Severity | Count |
|---|---|
| 🔴 must-fix | **~60+** |
| 🟡 should-fix | **~40** |
| ⚪ nice-to-have | **~20** |
| 🟠 structural | **1** |

> **Note on counting:** SettingsView's V-01 is one violation covering ~50 controls — counted as 1 must-fix in this table, but the implementation workload is the largest single item in Phase 13.

### Cross-cutting priorities (fix once, benefit many)

1. **`Toggle.labelsHidden()` without re-attached label** — SettingsView (50+ toggles), WorkflowParameterPanelView (boolean params), CapacityView (APEX tier picker), IntelligenceView (theme picker, interface level picker), CodeSearchPanelView (Case/Regex toggles). Every use of `.labelsHidden()` needs a compensating `.accessibilityLabel`.
2. **Color-as-sole-signal** — CapacityView (fit badges, "won't fit" text, memory bar), TasksView (priority icons, overdue dates), CommentsSidebarView (track changes), FindReplaceBar (no-results counter), VersionHistorySheet (selection highlight).
3. **`.onTapGesture` for navigation instead of `Button`/`NavigationLink`** — ChatHistoryDrawer, CommentsSidebarView, CodeOutlineView, CodeSearchPanelView, CodeGitPanelView, VersionHistorySheet. All bypass VoiceOver activation.
4. **Hard-coded `.red/.green/.orange/.yellow`** — non-semantic colors that break Dark Mode / Increase Contrast across Capacity, Settings, Comments, Email, Tasks, FindReplace.
5. **`⌘⌥I` keyboard shortcut collision** — WorkflowMenuActions overrides system "Show Window Info". Fix to `⌘⇧I`.

---

## Tier 1 — Critical

### 1. App Shell + Menus

**9 must / 9 should / 3 nice**

Key violations:
- Sidebar `Label` items have no explicit `accessibilityLabel` — VoiceOver reads raw enum names without group context (`ContentView.swift:134`)
- Chat toolbar button: `help` + `accessibilityHint` identical strings (violates HIG tooltip/hint distinction)
- `personaChip` font size 9pt — below macOS 10pt minimum (`UnifiedChatDock.swift:78`)
- Chat history search TextField missing `accessibilityLabel` (`ChatHistoryDrawer.swift:120`)
- Chat history list rows use `.onTapGesture` — VoiceOver cannot activate them (`ChatHistoryDrawer.swift:144`)
- TelemetryDrawer section collapse buttons all unnamed (`TelemetryDrawer.swift:163`)
- Onboarding feature rows fragmented VoiceOver read (icon + two texts separately) (`OnboardingView.swift:59–62`)
- Onboarding approval rows fragmented VoiceOver read (`OnboardingView.swift:136–139`)
- Onboarding model directory TextField missing `accessibilityLabel` (`OnboardingView.swift:85`)
- **`⌘⌥I` collides with system Show Window Info** (`WorkflowMenuActions.swift:157`) — fix to `⌘⇧I`

### 2. Settings Window

**1 violation covering ~50 controls must / 4 should / 2 nice**

- **V-01 (must):** Every `Toggle`, `Picker`, `Stepper`, `TextField`, `SecureField`, `PathField`, `Button` in all 6 tabs lacks `accessibilityLabel`. This is the single largest accessibility fix in Phase 13. See the per-control table in `phase13-hig-review-settings.md`.
- **V-03 (must):** Permissions tab window height 460pt too short for its content — forces scrolling at default size.
- **V-04 (must):** `PathField`'s inner `TextField` has no `accessibilityLabel`.
- **V-05 (must):** DisclosureGroup label inside HStack lacks combined `accessibilityLabel`.
- V-02: `.pickerStyle(.inline)` should be `.menu` or `.segmented`.
- V-06: Badge backgrounds use `.opacity()` — won't adapt to Increase Contrast.
- V-07: "Un-revoke" label awkward — change to "Restore".
- V-08: Covert trigger Cancel button lacks `.keyboardShortcut(.cancelAction)`.
- V-09: `.system(.body, design: .monospaced)` → `.monospacedBody`.

### 3. Intelligence Hub + Capacity + Learning

**12 must / 8 should / 2 nice**

- Model fit badges: 12pt colored circles with no label — **color as sole signal** (`CapacityView.swift:128–135`)
- "won't fit" text: `.red` alone — **color as sole signal** (`CapacityView.swift:119–121`)
- APEX tier picker uses `.labelsHidden()` without `accessibilityLabel` (`CapacityView.swift:146–151`)
- Intelligence theme picker uses `.labelsHidden()` without `accessibilityLabel` (`IntelligenceView.swift:37–43`)
- Interface level picker uses `.labelsHidden()` without `accessibilityLabel` (`IntelligenceView.swift:45–52`)
- "Run bench" button missing `accessibilityLabel` (`CapacityView.swift:157–162`)
- Hardware cards: no `accessibilityLabel` on card body (`CapacityView.swift:81–90`)
- Memory bar: `ProgressView` with no `accessibilityValue` (`CapacityView.swift:98`)
- Model fit rows: `ForEach` rows not wrapped as combined accessibility element (`CapacityView.swift:110–124`)
- LearningDashboard `ForEach(teachers)` missing explicit `id:` — identity instability (`LearningDashboardView.swift:69`)
- Memory bar: hard-coded `.red` not semantic (`CapacityView.swift:98`)
- Approval legend rows: VoiceOver reads two texts separately (`IntelligenceView.swift:175–180`)

---

## Tier 2 — High Priority

### 4. Email + Onboarding

**7 must / 5 should / 6 nice**

- EmailRow: no `accessibilityLabel` on entire row (`EmailView.swift:625`)
- Star/attachment icons: no labels (`EmailView.swift:630, 658, 664, 670`)
- Attachment rows: no labels (`EmailView.swift:841`)
- Composer To/Cc/Subject fields: no labels (`EmailView.swift:953`)
- "Starred" sidebar tag hardcoded to `.inbox` — functional + a11y bug (`EmailView.swift:344`)
- Enter key returns `.ignored` instead of opening email (`EmailView.swift:332`)
- Approval level rows: green color alone as signal (`OnboardingView.swift:158`)
- Feature rows: fragmented VoiceOver read (`OnboardingView.swift:59–62`)
- Approval rows: fragmented VoiceOver read (`OnboardingView.swift:136–139`)
- Empty state hint: raw keyboard glyphs not localized/accessible (`EmailView.swift:453`)

### 5. Tasks + DualAgent

**6 must / 6 should / 0 nice**

- Priority icons: color alone (blue/orange/red) — **color as sole signal** (`TasksView.swift:400–406`)
- Overdue dates: `.red` alone — **color as sole signal** (`TasksView.swift:376–384`)
- NLU TextField: no `accessibilityLabel` (`TasksView.swift:155`)
- Priority Picker in TaskDetailView: no `accessibilityLabel` (`TasksView.swift:507`)
- DatePicker in TaskDetailView: no `accessibilityLabel` (`TasksView.swift:521`)
- Linked entity labels: raw UUID strings exposed (`TasksView.swift:545`)
- DualAgent send button: label "Send" not descriptive
- DualAgent clear button: no `accessibilityLabel`
- DualAgent participant chips: no `accessibilityLabel`
- DualAgent status pill: lacks role prefix

### 6. Capacity + Learning

(merged with Tier 1 Intelligence — see section 3 above)

---

## Tier 3 — Secondary Surfaces

### 7. Workflow Editor + Graph

**5 must / 7 should / 3 nice + 1 structural**

- WorkflowParameterPanelView Toggle: `.labelsHidden()` strips label, no re-attachment (`WorkflowParameterPanelView.swift:99`)
- WorkflowCanvasView: Canvas itself has no `accessibilityLabel` (`WorkflowCanvasView.swift:54`)
- Grid background Canvas: needs `accessibilityHidden(true)` (`WorkflowCanvasView.swift:164`)
- Connection error banner: text has no `accessibilityLabel` (`WorkflowsView.swift:588`)
- Palette entry rows: missing `accessibilityLabel` (`WorkflowPaletteView.swift:50`)
- **Structural limitation:** GraphView `ForceDirectedGraph` is Canvas-rendered — fundamentally inaccessible to VoiceOver. Cannot be fixed with `accessibilityLabel` additions. Requires an invisible parallel accessibility tree or keyboard-navigable alternative surface. (`GraphView.swift:99`)
- Graph refresh/simulation toolbar buttons: missing `accessibilityLabel` (`GraphView.swift:254–270`)
- Graph filter buttons: missing `accessibilityLabel` (`GraphView.swift:209`)
- Graph detail panel "Open" button: missing `accessibilityLabel` (`GraphView.swift:315`)

### 8. Code Panes + Receipts

**16 must / 2 should / 1 nice**

- CodeOutlineView kind-filter Picker: `.labelsHidden()` without label (`CodeOutlineView.swift:44`)
- CodeOutlineView outline rows: non-interactive, no label, no keyboard nav (`CodeOutlineView.swift:96`)
- CodeSearchPanelView clear button: missing `accessibilityLabel` (`CodeSearchPanelView.swift:51`)
- CodeSearchPanelView Case/Regex/Language toggles: all missing labels (`CodeSearchPanelView.swift:61–70`)
- CodeSearchPanelView hit rows: no label, no keyboard activation (`CodeSearchPanelView.swift:112`)
- CodeGitPanelView commit rows: no label, no keyboard activation (`CodeGitPanelView.swift:49`)
- CodeGitPanelView blame rows: no label (`CodeGitPanelView.swift:77`)
- ReceiptDetailView actor icon: color as sole signal (`ReceiptDetailView.swift:86`)
- ReceiptDetailView verification result: color as sole signal (`ReceiptDetailView.swift:179`)
- ReceiptDetailView action buttons: missing `accessibilityLabel` (`ReceiptDetailView.swift:103`)
- C2PAManifestSheet JSON: missing `accessibilityLabel` on scroll container (`C2PAManifestSheet.swift:41`)
- ReceiptExportView format rows: no keyboard support, no `accessibilityLabel`, no selected state (`ReceiptExportView.swift:106`)
- ReceiptExportView Export button: missing `⌘E` keyboard shortcut (`ReceiptExportView.swift:87`)
- ReceiptsDrawerView tab picker: missing `accessibilityLabel` (`ReceiptsDrawerView.swift:93`)
- ReceiptsDrawerView all-documents rows: no label, no keyboard, disabled state unexplained (`ReceiptsDrawerView.swift:257`)
- ReceiptRowView: voided status not in accessibility label (`ReceiptRowView.swift:57`)

### 9. Secondary Surfaces (VersionHistory + Comments + FindReplace + List Shells)

**8 must / 12 should / 6 nice**

**VersionHistorySheet:**
- Selection uses color alone — **color as sole signal** (`VersionHistorySheet.swift:157`)
- Receipt row button: missing `accessibilityLabel` (`VersionHistorySheet.swift:124`)
- Receipt ID 10pt font at minimum edge; no `accessibilityLabel` (`VersionHistorySheet.swift:252`)
- Sheet title uses `.headline` instead of `.title3` (typography)

**CommentsSidebarView:**
- Close button: icon-only, no label (`CommentsSidebarView.swift:95`)
- Track changes: insertions/deletions use color alone — **color as sole signal** (`CommentsSidebarView.swift:301–319`)
- Deletion text `.red` on red background — contrast failure (`CommentsSidebarView.swift:318`)
- Comment action buttons: missing `accessibilityLabel` (`CommentsSidebarView.swift:254`)
- `.onTapGesture` on CommentThreadCard — not keyboard-activatable (`CommentsSidebarView.swift:228`)

**FindReplaceBar:**
- Dismiss button: icon-only, no label (`FindReplaceBar.swift:169`)
- Case/whole-word/regex toggles: no `accessibilityLabel` (`FindReplaceBar.swift:102`)
- "No results" shown in red alone — **color as sole signal** (`FindReplaceBar.swift:74`)
- **Functional bug:** `FindReplaceCoordinator` `isCaseSensitive`/`isWholeWord`/`isRegex` always return `false` — toggles have no effect (`FindReplaceBar.swift:271`)
- No Escape key to dismiss (`FindReplaceBar.swift:45`)

**List Shells (Notes + Docs + Sheets + Slides):**
- All 4 TagChipsView tag filter buttons: no `accessibilityLabel` (`NotesView.swift:387`, `DocsListView.swift:349`, `SheetsListView.swift:283`, `SlidesListView.swift:304`)
- DocsListView emoji icon in row: no text alternative (`DocsListView.swift:254`)
- SheetsListView: `.caption2` (9pt) tag text — below minimum (`SheetsListView.swift:264`)
- SheetsListView: hardcoded light-mode foreground on active chip
- DocsListView `DocTagPill`: hardcoded `.opacity(0.15)` — won't adapt to Increase Contrast

---

## Implementation Priority Order

### Phase 1: Cross-cutting shared patterns (fix once → benefit many)
1. **All `.labelsHidden()` without `accessibilityLabel`** — sweep the entire codebase; apply `.accessibilityLabel()` to every Toggler/Picker with hidden label
2. **All color-as-sole-signal indicators** — fit badges, "won't fit", priority icons, overdue dates, track changes, match counter
3. **All `.onTapGesture` for row activation** — replace with `Button` wrappers or `NavigationLink` across ChatHistoryDrawer, CommentsSidebarView, CodeOutlineView, CodeSearchPanelView, CodeGitPanelView, VersionHistorySheet
4. **Fix `⌘⌥I` → `⌘⇧I` in WorkflowMenuActions**

### Phase 2: Settings window (largest single surface)
5. **SettingsView V-01**: Add `accessibilityLabel` to all ~50 interactive controls
6. **SettingsView V-03**: Increase Permissions tab window height to 540pt
7. **SettingsView V-04/05**: PathField inner TextField + DisclosureGroup HStack labels

### Phase 3: High-frequency surfaces
8. **ContentView**: Sidebar labels, chat toolbar, TelemetryDrawer section collapse
9. **EmailView**: EmailRow, composer fields, smart folder fix
10. **TasksView**: Priority icons, NLU TextField, TaskDetailView fields
11. **CapacityView**: Fit badges, hardware cards, memory bar, Run bench button

### Phase 4: Secondary surfaces
12. **WorkflowParameterPanelView**: Toggle label re-attachment
13. **GraphView**: Parallel accessibility tree (structural — requires design decision)
14. **CommentsSidebarView**: Close button, track changes color signals
15. **FindReplaceBar**: All toggles labeled + wire coordinator options + Escape key
16. **All 4 list shells**: Tag filter buttons labeled + dark mode color fixes
17. **Receipt surfaces**: Action buttons, format picker, export shortcut
18. **Code panes**: Outline rows, search panel, git panel keyboard navigation
