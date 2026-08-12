# Phase 13 HIG Review — Workflow Editor + Graph (Tier 3)

**Date:** 2026-08-12
**Scope:** `WorkflowsView.swift`, `WorkflowNodeView.swift`, `WorkflowCanvasView.swift`, `WorkflowParameterPanelView.swift`, `WorkflowMenuActions.swift`, `WorkflowPaletteView.swift`, `GraphWindowView.swift`, `GraphView.swift`
**Reference:** Apple HIG (skill: apple-hig) — §§1–4, §11–§13, §16

---

## Grand Summary

| Severity | Count |
|---|---|
| 🔴 must-fix | **5** |
| 🟡 should-fix | **7** |
| ⚪ nice-to-have | **3** |
| 🟠 structural | **1** |

**Cross-cutting priorities:**

1. **`Toggle` in parameter panel** — `labelsHidden()` strips VoiceOver labels. No re-attached label unlike the `TextField` two lines below it. Every boolean parameter is completely unlabelled.
2. **Canvas `WorkflowCanvasView` has no `accessibilityLabel`** — the entire canvas (nodes, edges, grid) is invisible to VoiceOver. Nodes inside the canvas have individual labels, but VoiceOver cannot navigate the canvas or discover nodes within it.
3. **Graph `ForceDirectedGraph` canvas is fundamentally inaccessible** — this is a structural limitation, not a simple missing label. Canvas-rendered charts/nodes are outside VoiceOver's reach. Requires a parallel keyboard-navigable tree or invisible accessibility layer.
4. **`connectionErrorBanner` text lacks `accessibilityLabel`** — VoiceOver users cannot read the error message. The banner is announcement-only.
5. **Palette entry rows missing `accessibilityLabel`** — List rows contain `VStack` of `Text` elements but no explicit row-level label; VoiceOver may only announce the row index.

---

## WorkflowParameterPanelView.swift

### 🔴 Must-fix

#### 1. `Toggle` field has no `accessibilityLabel`

- **Description:** The `Toggle` uses `.labelsHidden()` for layout, which strips the VoiceOver label. The comment at line 74–76 acknowledges this problem for all fields and re-attaches the label, but it is only applied to the `.field()` call site, which is a single `View` returned from a `@ViewBuilder`. For `Toggle` (the `case "boolean"` branch), there is no re-attached label. Every boolean parameter is completely unlabelled for VoiceOver.
- **Affected UI element:** Boolean parameter `Toggle` in the inspector panel
- **Current code location:** `WorkflowParameterPanelView.swift:99–101`
- **Severity:** must
- **Fix:**
  ```swift
  case "boolean":
      Toggle("", isOn: bindingForBool(key: key))
          .labelsHidden()
          .accessibilityLabel(propLabel(key))
          .accessibilityHint(prop.description ?? "")
  ```

---

## WorkflowCanvasView.swift

### 🔴 Must-fix

#### 2. Canvas view itself has no `accessibilityLabel` or keyboard navigation

- **Description:** `WorkflowCanvasView` is a pure `Canvas` + `GeometryReader`. It has `.focusable()` + `.focused()` in the parent (`WorkflowsView`) for arrow-key nudging, but the canvas itself has no `accessibilityLabel`, no `accessibilityHint`, and no keyboard navigation path for VoiceOver users to discover or interact with individual nodes. While nodes inside the canvas have individual labels (set on `WorkflowNodeView`), VoiceOver cannot navigate into the canvas hierarchy to reach them. The canvas element itself is opaque to the accessibility tree.
- **Affected UI element:** The canvas background/viewport
- **Current code location:** `WorkflowCanvasView.swift:54–118`
- **Severity:** must
- **Fix:** Add an `accessibilityLabel` describing the canvas purpose. Also add a hidden accessibility child representation (see "Structural limitations" section below):
  ```swift
  .accessibilityLabel("Workflow canvas. \(workflow.nodes.count) nodes, \(workflow.edges.count) connections.")
  .accessibilityHint("Use Tab to move focus into nodes when available. Arrow keys nudge the selected node.")
  ```

#### 3. Grid background `Canvas` has no `accessibilityLabel`

- **Description:** The `gridBackground` `Canvas` renders decorative lines. Like all `Canvas` elements, it has no accessibility tree representation. It needs `accessibilityLabel("Workflow canvas grid")` and `accessibilityHidden(true)` so it does not appear as an unlabelled graphic in the accessibility tree.
- **Affected UI element:** Grid background `Canvas`
- **Current code location:** `WorkflowCanvasView.swift:164–183`
- **Severity:** must
- **Fix:**
  ```swift
  .accessibilityHidden(true)
  ```

---

## WorkflowsView.swift

### 🟡 Should-fix

#### 4. `connectionErrorBanner` message text lacks `accessibilityLabel`

- **Description:** The `connectionErrorBanner` renders a `Text(message)` that carries the error message, but neither the text nor any parent has an `accessibilityLabel`. VoiceOver will not announce the error message to users — it is announcement-only.
- **Affected UI element:** Connection error banner message
- **Current code location:** `WorkflowsView.swift:588`
- **Severity:** should
- **Fix:**
  ```swift
  Text(message)
      .font(.callout)
      .lineLimit(2)
      .truncationMode(.tail)
      .accessibilityLabel("Connection error: \(message)")
  ```

#### 5. "Dismiss" button in error banner lacks `accessibilityLabel`

- **Description:** The banner's dismiss button uses a bare `"Dismiss"` label with `.buttonStyle(.borderless)`. No `accessibilityLabel` or `accessibilityHint` is attached. VoiceOver will announce "Dismiss button" with no context.
- **Affected UI element:** Dismiss button in the connection error banner
- **Current code location:** `WorkflowsView.swift:593`
- **Severity:** should
- **Fix:**
  ```swift
  Button("Dismiss") { connectionError = nil }
      .buttonStyle(.borderless)
      .keyboardShortcut(.cancelAction)
      .accessibilityLabel("Dismiss error message")
  ```

#### 6. `accessibilityLabel` on toolbar Cancel button in run progress sheet

- **Description:** The Cancel button in the run progress sheet has an `accessibilityHint` but no `accessibilityLabel`. Without a label, VoiceOver announces only "button" — the hint is only read on a second interaction.
- **Affected UI element:** Cancel button in run progress sheet
- **Current code location:** `WorkflowsView.swift:397`
- **Severity:** should
- **Fix:**
  ```swift
  Button("Cancel", role: .cancel) { editor.cancelRun(task) }
      .accessibilityLabel("Cancel workflow run")
      .accessibilityHint("Stop the workflow run")
  ```

#### 7. Run event rows lack explicit `accessibilityLabel`

- **Description:** The `runEventRow` uses `Image(systemName:)` + `Text` for log severity icons and messages. The icons are hierarchical symbols so they add meaning through color, but each row has no `accessibilityLabel`. VoiceOver may read the text but the log level (debug/info/warn/error) conveyed by the icon + color is not announced. The overall run log sheet should have an `accessibilityLabel("Run progress log")` on the scroll container.
- **Affected UI element:** Run progress log rows
- **Current code location:** `WorkflowsView.swift:456–516`
- **Severity:** should
- **Fix:** Add `accessibilityLabel` to the outermost `HStack` in each `runEventRow` case, e.g.:
  ```swift
  case .started(let name, let total):
      HStack {
          Image(systemName: "play.circle.fill") ...
          Text("Started \"\(name)\" — \(total) nodes")
      }
      .accessibilityLabel("Workflow started: \(name), \(total) nodes")
  ```

---

## WorkflowNodeView.swift

### 🟡 Should-fix

#### 8. Header icon is not marked `accessibilityHidden(true)`

- **Description:** The node header's `Image(systemName: "square.dashed")` is purely decorative (it marks the node header). It is not marked `accessibilityHidden(true)`. VoiceOver may attempt to announce it, producing confusing output like "square dashed" before the node name.
- **Affected UI element:** Node header icon
- **Current code location:** `WorkflowNodeView.swift:108`
- **Severity:** should
- **Fix:** The fix in §9 below covers this, but it can also be applied directly:
  ```swift
  Image(systemName: "square.dashed")
      .font(.callout)
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(.secondary)
      .accessibilityHidden(true)
  ```

---

## WorkflowPaletteView.swift

### 🟡 Should-fix

#### 9. Palette entry rows missing explicit `accessibilityLabel`

- **Description:** The palette `List` rows are `VStack`s of `Text` elements (displayName, typeId, summary). SwiftUI synthesizes an accessibility label from the first `Text` by default, so displayName is likely announced — but the `VStack` as a container has no explicit `accessibilityLabel`. The `List` itself has a correct label ("Node palette"), but each row should have an explicit row-level label that includes both the display name and type id.
- **Affected UI element:** Palette entry rows in the node palette `List`
- **Current code location:** `WorkflowPaletteView.swift:50–68`
- **Severity:** should
- **Fix:**
  ```swift
  .accessibilityLabel("\(entry.displayName), \(entry.typeId)")
  .accessibilityHint("Drag onto the canvas to add this node")
  ```

---

## GraphWindowView.swift + GraphView.swift (TesseraCore)

### 🟠 Structural Limitation — Graph canvas is inaccessible to VoiceOver

#### 10. `ForceDirectedGraph` (Canvas-rendered) has no VoiceOver path

- **Description:** `GraphView` renders the force-directed graph via Grape's `ForceDirectedGraph` component, which is backed by Swift Charts' `Chart` / `Canvas` infrastructure. `Canvas`-rendered graphics are fundamentally opaque to VoiceOver — there is no accessibility tree for content inside a `Canvas`. Adding `accessibilityLabel` to the canvas element makes it announceable but not navigable. Individual nodes (displayed via `NodeMark`) and edges (via `LinkMark`) cannot be reached by VoiceOver navigation.

  This is **not fixable with `accessibilityLabel` additions**. It requires a design decision:

  - **Option A (recommended):** Render an invisible parallel accessibility tree (a `List` or `VStack`) with the same data, hidden visually (`opacity(0)`) but present in the accessibility tree. VoiceOver users navigate the tree; sighted users interact with the canvas. The tree is kept in sync with the graph via the view model.

  - **Option B:** Provide a keyboard-navigable alternative surface (e.g., a sortable table view of nodes and their connections) that is fully accessible, and let users choose between the visual graph and the list view.

  - **Option C:** Accept the limitation and document it in the app's accessibility statement. This is the weakest option and only appropriate if the graph is supplementary rather than a primary interaction surface.

- **Affected UI element:** Force-directed graph canvas (`ForceDirectedGraph` / `NodeMark` / `LinkMark`)
- **Current code location:** `TesseraStudio/Sources/TesseraCore/Productivity/Graph/GraphView.swift:99–116`
- **Severity:** structural (not a simple `accessibilityLabel` fix)
- **Fix (Option A skeleton):**
  ```swift
  // Hidden parallel accessibility tree
  VStack(alignment: .leading, spacing: 0) {
      ForEach(viewModel.visibleNodes) { node in
          Text(node.label)
              .font(.body)
              .opacity(0)  // invisible to sighted users
              .accessibilityLabel(nodeLabel(node))
      }
  }
  .accessibilityHidden(false)  // present in accessibility tree
  ```
  The invisible tree must be kept in sync with `viewModel.visibleNodes` and provide full node + edge navigation for VoiceOver.

### 🟡 Should-fix

#### 11. Graph refresh toolbar button lacks `accessibilityLabel`

- **Description:** The toolbar refresh button has `help("Reload graph")` but no `accessibilityLabel`. VoiceOver users hear an unlabelled button. The `pause/play` simulation toggle has the same issue.
- **Affected UI element:** Toolbar reload button and simulation toggle button
- **Current code location:** `TesseraStudio/Sources/TesseraCore/Productivity/Graph/GraphView.swift:254–270`
- **Severity:** should
- **Fix:**
  ```swift
  Button {
      Task { await viewModel.load() }
  } label: {
      Image(systemName: "arrow.clockwise")
          ...
  }
  .help("Reload graph")
  .accessibilityLabel("Reload graph")

  Button {
      graphStates.isRunning.toggle()
  } label: {
      Image(systemName: graphStates.isRunning ? "pause.fill" : "play.fill")
          ...
  }
  .help(graphStates.isRunning ? "Pause simulation" : "Resume simulation")
  .accessibilityLabel(graphStates.isRunning ? "Pause graph simulation" : "Resume graph simulation")
  ```

#### 12. Graph filter buttons lack `accessibilityLabel`

- **Description:** The sidebar `ForEach(typeChips)` renders `Button`s with `Label(type, systemImage: icon)`. Each button has only `foregroundStyle` for selection state. No `accessibilityLabel` is attached, so VoiceOver announces the raw `type` string (e.g., "doc") without context about whether it is selected or a filter toggle.
- **Affected UI element:** Sidebar entity-type filter buttons
- **Current code location:** `TesseraStudio/Sources/TesseraCore/Productivity/Graph/GraphView.swift:209–219`
- **Severity:** should
- **Fix:**
  ```swift
  Button {
      viewModel.toggleType(type)
  } label: {
      Label(type, systemImage: icon)
          .foregroundStyle(
              viewModel.typeFilter.contains(type) ? Color.accentColor : .primary
          )
  }
  .buttonStyle(.plain)
  .accessibilityLabel("\(type) filter, \(viewModel.typeFilter.contains(type) ? "selected" : "not selected")")
  ```

#### 13. Graph detail panel "Open" button lacks `accessibilityLabel`

- **Description:** The "Open in X" button in `GraphDetailPanel` uses a `Label` with a dynamic system image but has no `accessibilityLabel`. VoiceOver will announce it as "Open in X" if the `Label` is read, but the context of which surface it opens is not explicit for every node type.
- **Affected UI element:** "Open in X" button in graph detail panel
- **Current code location:** `TesseraStudio/Sources/TesseraCore/Productivity/Graph/GraphView.swift:315–321`
- **Severity:** should
- **Fix:**
  ```swift
  Button {
      viewModel.open(node)
  } label: {
      Label(openLabel(for: node), systemImage: "arrow.up.forward.square")
  }
  .buttonStyle(.bordered)
  .controlSize(.small)
  .accessibilityLabel(openLabel(for: node))
  ```

#### 14. `GraphSidebar` Section headers lack `accessibilityAddTraits(.isHeader)`

- **Description:** `GraphSidebar` uses `Section("Visibility")`, `Section("Filter by type")`, and `Section("Stats")`. SwiftUI `Section` does not automatically add the `isHeader` accessibility trait to its header text. VoiceOver users navigating the sidebar may not hear "heading" when reaching these sections.
- **Affected UI element:** Sidebar section headers
- **Current code location:** `TesseraStudio/Sources/TesseraCore/Productivity/Graph/GraphView.swift:197–240`
- **Severity:** should
- **Fix:** Add `.accessibilityAddTraits(.isHeader)` to each section header, or use the `.headerProminence(.increased)` modifier which implicitly adds the trait.

---

## NumericParameterField.swift (WorkflowParameterPanelView.swift)

### ⚪ Nice-to-have

#### 15. Stepper and text field lack `accessibilityHint`

- **Description:** The `Stepper` uses `labelsHidden()` and the `TextField` uses a bare placeholder `""`. Neither has an explicit `accessibilityHint` explaining how to interact with them. The parent `fieldRow` does attach a label, but the hint describing the interaction method is missing.
- **Affected UI element:** Numeric parameter stepper and text field
- **Current code location:** `WorkflowParameterPanelView.swift:206–215` (stepper) and `WorkflowParameterPanelView.swift:218–241` (textField)
- **Severity:** nice
- **Fix:**
  ```swift
  Stepper("", value: stepperValue(in: bounds), step: 1)
      .labelsHidden()
      .accessibilityHint("Adjust value using the stepper or type a number")

  TextField("", text: $text)
      .textFieldStyle(.roundedBorder)
      .accessibilityHint("Type a number. Press Tab to confirm.")
  ```

---

## WorkflowNodeView.swift

### ⚪ Nice-to-have

#### 16. Node `accessibilityHint` does not mention keyboard navigation

- **Description:** The `accessibilityHint` on `WorkflowNodeView` ("Drag to move. Use the action menu to delete.") describes mouse drag and the action menu but does not mention that arrow keys nudge the selected node (a feature already implemented in `WorkflowsView`).
- **Affected UI element:** Workflow node
- **Current code location:** `WorkflowNodeView.swift:102`
- **Severity:** nice
- **Fix:**
  ```swift
  .accessibilityHint("Drag to move. Press arrow keys to nudge. Use the action menu to delete.")
  ```

---

## WorkflowPaletteView.swift

### ⚪ Nice-to-have

#### 17. "Nodes" header text lacks `accessibilityAddTraits(.isHeader)`

- **Description:** The palette section header uses a plain `Text("Nodes")` with `.accessibilityAddTraits(.isHeader)` — this is actually already correct (line 25), but the trait is added to the `Text` wrapper. If the view structure changes, the trait may be lost. Verify it survives any future refactor.
- **Affected UI element:** "Nodes" section header
- **Current code location:** `WorkflowPaletteView.swift:20–25`
- **Status:** Already correctly implemented. No change needed. Listed for verification only.

---

## Appendix: What Is Already Good

The following were verified as HIG-compliant and require no changes:

- **Toolbar buttons** in `WorkflowsView`: All have `accessibilityLabel` + `accessibilityHint` + `help` — ✅
- **Run `ProgressView`**: Has `accessibilityLabel("Workflow running")` — ✅
- **Reduce Motion**: `@Environment(\.accessibilityReduceMotion)` used correctly in `WorkflowsView` to suppress animations — ✅
- **Node ports** (`WorkflowPortView`): Comprehensive `accessibilityLabel` with port type, direction, and drag state; `accessibilityHint` on each port — ✅
- **Node accessibility element**: `children: .contain`, explicit label, hint, and `.isButton` trait — ✅
- **Canvas zoom controls**: All three buttons have `accessibilityLabel`; zoom percentage has its own label — ✅
- **Keyboard nudge**: Arrow key nudge (1pt / 10pt with Shift) correctly implemented with `.onKeyPress` — ✅
- **Alert for unsaved changes**: Correctly uses `role: .destructive` on Discard and `role: .cancel` on Cancel — ✅
- **Sheet dismiss**: `keyboardShortcut(.cancelAction)` on the Close button in run progress sheet — ✅
- **NavigationSplitView inspector**: Correctly uses `.inspector(isPresented:)` as the HIG-compliant pattern for a supplementary detail panel — ✅
- **Zoom controls background**: Uses `.thinMaterial` with `RoundedRectangle` — ✅
- **Log severity colors**: All log levels use symbol + text + color (not color-only) — ✅
- **Run outcome icons**: Symbol + text for success/failure/cancelled — ✅
- **`ContentUnavailableView`**: Used for empty palette, empty parameter panel, empty graph — ✅
- **`searchable(text:)`**: System search field used throughout (palette, graph) — ✅
- **`labelsHidden()` on Picker in `GraphSidebar`**: Section header provides context; this is an acceptable pattern — ✅

---

*Review conducted against Apple HIG (skill: apple-hig), §§1–4, §11–§13, §16. Last refresh: 2026-08-08.*
