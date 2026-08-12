# HIG Review: Capacity + Learning Dashboard (Tier 2, Agent C)

**Reviewer:** Agent C  
**Date:** 2026-08-12  
**Scope:** `CapacityView.swift`, `LearningDashboardView.swift`  
**Standard:** Apple Human Interface Guidelines (as encoded in `apple-hig` skill, refreshed 2026-08-08)  
**Relevant HIG sections:** §2.1 Color, §2.2 Typography, §3 Accessibility, §12.4 Accessibility (all platforms), §12.5 Visual quality

---

## Severity key

| Severity | Meaning |
|---|---|
| **must** | Violates a hard HIG rule; blocks App Store review or makes the UI inaccessible |
| **should** | Violates a strong HIG recommendation; fix before shipping |
| **nice** | Lint-level; improves quality but does not block |

---

## File 1: `CapacityView.swift`

### 1. Badge uses color as the sole signal — no text or icon pairing

- **Label:** Color-as-sole-signal on fit badges
- **Description:** The `badge(_:)` helper (line 128–135) renders a 12×12 filled `Circle` in green/amber/red. These colors convey three distinct states (green = good fit, amber = marginal, red = poor fit), but there is no accompanying text label, SF Symbol, or icon. People with red-green color blindness (affecting ~8% of males) cannot distinguish amber from green, and in low-light conditions the distinction is unreliable for everyone. HIG §2.1 explicitly forbids relying on color alone; §12.4 requires that "color is never the only signal — paired with shape, label, or icon."
- **Affected UI element:** `badge(fit.badge)` inside `modelFitSection` (line 112)
- **Current code location:** `CapacityView.swift:128–135`
- **Severity:** must
- **Fix:**
  ```swift
  // Option A — text label paired with color
  HStack(spacing: 6) {
      Circle().fill(color).frame(width: 12, height: 12)
      Text(kind.capitalized) // "Green", "Amber", "Red"
          .font(.caption).foregroundStyle(color)
  }

  // Option B — SF Symbol paired with color (preferred for compact rows)
  Image(systemName: iconName(for: kind))
      .foregroundStyle(color)
      .symbolRenderingMode(.hierarchical)

  private func iconName(for kind: String) -> String {
      switch kind {
      case "green":  return "checkmark.circle.fill"
      case "amber":  return "exclamationmark.triangle.fill"
      default:        return "xmark.circle.fill"
      }
  }
  ```

---

### 2. Hardware cards lack VoiceOver labels

- **Label:** Hardware card accessibility label missing
- **Description:** Each hardware card is built with a custom `card(_:systemImage:content:)` view (line 81–90). The card's content combines dynamic text (CPU model, RAM size, GPU name, bandwidth) that is meaningful to a sighted user. VoiceOver, however, will fall back to the best available text child — likely just the title "CPU" or "RAM" — and ignore the secondary details. The entire card should be wrapped in an accessibility element with a single composite label describing all information it contains. See HIG §12.4: "All interactive elements have `accessibilityLabel`."
- **Affected UI element:** All four hardware cards in `hardwareCards` (CPU, RAM, GPU, Bandwidth)
- **Current code location:** `CapacityView.swift:50–79` (callers); `CapacityView.swift:81–90` (definition)
- **Severity:** must
- **Fix:**
  ```swift
  // In card(...) definition, wrap the card in an accessibilityGroup:
  var cardBody: some View {
      VStack(alignment: .leading, spacing: 6) {
          Label(title, systemImage: systemImage).font(.headline)
          content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
  }

  return cardBody
      .accessibilityElement(children: .combine)
      .accessibilityLabel(accessibilityText(for: title, cap: cap, igpu: igpu))
  ```
  Each caller (`cpuCard`, `ramCard`, etc.) should pass enough context to construct a full label such as `"CPU: Apple Silicon, 12 cores, ARM64 instruction set"`.

---

### 3. Memory bar progress indicator lacks VoiceOver label

- **Label:** Memory bar accessibility value missing
- **Description:** The `memoryBar` view (line 92–100) renders a `ProgressView` showing RAM usage. VoiceOver will announce this as "progress indicator" with no indication of what is being measured, how full it is, or what the threshold means. A descriptive label and value must be provided via `accessibilityLabel`.
- **Affected UI element:** Memory progress bar
- **Current code location:** `CapacityView.swift:92–100`
- **Severity:** must
- **Fix:**
  ```swift
  ProgressView(value: frac)
      .tint(frac > 0.85 ? .red : .accentColor)
      .accessibilityLabel("Memory usage")
      .accessibilityValue("\(used / 1024) of \(cap.ramTotalMB / 1024) gigabytes used")
  ```

---

### 4. Model fit rows lack accessibility labels

- **Label:** Model fit row accessibility missing
- **Description:** The `ForEach(fits)` loop (line 110–124) renders each model fit as an `HStack` with a badge, model ID, size/quant/tok-s string, and an optional "won't fit" label. VoiceOver will read each row in an unpredictable order and may not associate the badge state with the model. Each row should be an accessibility element combining all related information into one label.
- **Affected UI element:** Each `ForEach` row in `modelFitSection`
- **Current code location:** `CapacityView.swift:110–124`
- **Severity:** must
- **Fix:**
  ```swift
  ForEach(fits) { fit in
      HStack {
          badge(fit.badge)
          // ...
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(fit.id), \(fit.sizeMB / 1024) gigabytes, \(fit.quant), estimated \(String(format: "%.1f", fit.estTokS)) tokens per second, fit badge: \(fit.badge)\(fit.fitsRAM ? "" : ", won't fit in RAM")")
  }
  ```

---

### 5. "Run bench" button lacks VoiceOver label

- **Label:** Run bench button accessibility label missing
- **Description:** The bench-run `Button` (line 157–162) has a label that shows either a `ProgressView` or the text "Run bench". VoiceOver will read "Run bench" correctly for the text state, but during `benchRunning == true`, VoiceOver only announces "button" with no indication of what is running or how long it might take. The button needs a stable `accessibilityLabel` that describes the action regardless of state.
- **Affected UI element:** "Run bench" button
- **Current code location:** `CapacityView.swift:157–162`
- **Severity:** must
- **Fix:**
  ```swift
  Button {
      runBench()
  } label: {
      if benchRunning { ProgressView().controlSize(.small) } else { Text("Run bench") }
  }
  .disabled(benchRunning)
  .accessibilityLabel(benchRunning ? "Running MoE A/B benchmark" : "Run MoE A/B benchmark")
  .accessibilityHint("Runs synthetic latency benchmarks for the selected Apex tier and writes results to a JSONL file")
  ```

---

### 6. Hard-coded `.red` color on progress bar — not semantic

- **Label:** Non-semantic hard-coded red on memory bar
- **Description:** `memoryBar` (line 98) uses `.tint(frac > 0.85 ? .red : .accentColor)`. The literal `.red` is a flat color value that does not adapt to Increase Contrast mode, Vibrant backgrounds, or dark mode in the same way system semantic colors do. HIG §2.1 and §12.4 require system semantic colors. `Color.red` is marginally acceptable on macOS (it maps to the system red) but the correct API for a semantic danger signal is `Color.accentColor` with a separate danger-level override, or a custom `Color` asset with light/dark/Increase Contrast variants. More critically, the memory bar has no accessible label explaining what the red color means.
- **Affected UI element:** Memory bar progress indicator tint
- **Current code location:** `CapacityView.swift:98`
- **Severity:** should
- **Fix:**
  ```swift
  ProgressView(value: frac)
      .tint(frac > 0.85 ? Color.red : Color.accentColor)
      .accessibilityLabel("Memory usage")
  ```
  Or define a semantic `MemoryBarDangerColor` in the asset catalog with light/dark/Increase Contrast variants.

---

### 7. Hardware cards not keyboard-navigable

- **Label:** Hardware cards lack keyboard focus
- **Description:** The four hardware cards are displayed in a `LazyVGrid` and are purely informational. However, there is no focusable behavior — they cannot be reached via Tab key in Full Keyboard Access mode. While cards that are purely decorative can be excluded from the focus ring, these cards display live hardware telemetry that a user may want to review alongside keyboard navigation. At minimum, the cards should be grouped into an `accessibilityElement(children: .combine)` so VoiceOver reads them as a unit, and any future interactive affordance (e.g., a click to expand details) must be keyboard-navigable. See HIG §3 and §12.4: "Full Keyboard Access navigates all controls."
- **Affected UI element:** Hardware cards grid
- **Current code location:** `CapacityView.swift:50–79`
- **Severity:** should
- **Fix:**
  Add `.accessibilityElement(children: .combine)` to the card view definition and ensure any future interactive overlay is keyboard-focusable with `.focusable()`.

---

### 8. Red `.foregroundStyle(.red)` for "won't fit" label not semantic

- **Label:** Non-semantic red foreground on "won't fit" label
- **Description:** Line 120 uses `.foregroundStyle(.red)` directly on the "won't fit" text. Same issue as violation 6 — not a semantic color, won't adapt to accessibility settings. HIG §2.1.
- **Affected UI element:** "won't fit" text label
- **Current code location:** `CapacityView.swift:120`
- **Severity:** should
- **Fix:** Replace with `Color.red` (system semantic) or a named semantic color:
  ```swift
  Text("won't fit")
      .font(.caption2)
      .foregroundStyle(Color.red)
  ```

---

### 9. `benchPath` result text lacks accessibility label

- **Label:** Bench result file path inaccessible
- **Description:** The `Text("Wrote: \(path.lastPathComponent)")` (line 165–167) is a status message displayed after a bench run. VoiceOver may read it out of context. It should carry a descriptive `accessibilityLabel` so screen readers can understand it as a confirmation message.
- **Affected UI element:** Bench write confirmation label
- **Current code location:** `CapacityView.swift:164–167`
- **Severity:** nice
- **Fix:**
  ```swift
  Text("Wrote: \(path.lastPathComponent)")
      .font(.caption2).foregroundStyle(.secondary)
      .accessibilityLabel("Results written to \(path.lastPathComponent)")
  ```

---

## File 2: `LearningDashboardView.swift`

### 10. `Section("...")` initializer — section headers not exposed to VoiceOver

- **Label:** List section headers not VoiceOver-accessible
- **Description:** `LearningDashboardView` uses `List { Section("...") { ... } }` with the `Section(String, content:)` initializer. On macOS, `Section` headers created with a string label are rendered as text in the list but are not independently accessible elements — VoiceOver reads the row content but the header label is only discoverable by navigating to the header region. For maximum accessibility, use `Section { header: some View; content }` with an explicit `header:` view that carries a proper `accessibilityAddTraits(.isHeader)`. See HIG §12.4 and §13.14 (Lists and Tables).
- **Affected UI element:** All six sections (Training, Capability, Adaptation, Teachers, Foraging, Curation)
- **Current code location:** `LearningDashboardView.swift:19, 37, 52, 64, 82, 91`
- **Severity:** should
- **Fix:**
  ```swift
  Section {
      // rows
  } header: {
      Text("Capability")
          .font(.headline)
          .foregroundStyle(.secondary)
          .accessibilityAddTraits(.isHeader)
  }
  ```

---

### 11. `teachersSection` — `ForEach` missing explicit `id:`

- **Label:** ForEach without explicit id risks identity instability
- **Description:** The `ForEach(teachers)` loop (line 69) relies on inferred `id:` from `Identifiable`. If `TesseraTeacherAssessment` gains additional non-`Identifiable` conformance or its `id` property changes, this will silently break at runtime. The explicit `id: \.teacherId` (or whatever the stable identifier is) is required. This is a correctness issue that also affects accessibility stability. See SwiftUI best practices and HIG §12.4 (VoiceOver reads depend on stable element identity).
- **Affected UI element:** Teachers section ForEach
- **Current code location:** `LearningDashboardView.swift:69`
- **Severity:** must
- **Fix:**
  ```swift
  ForEach(teachers, id: \.teacherId) { teacher in
  ```
  If `TesseraTeacherAssessment` conforms to `Identifiable`, verify the conformance is stable and document it; otherwise add an explicit `id:` parameter.

---

### 12. `capabilitySection` — `LabeledContent` axis values lack context labels

- **Label:** Capability score axis labels too terse for VoiceOver
- **Description:** The `LabeledContent(axis, value: ...)` loop (line 41) renders capability axis names and float scores. The `axis` string (e.g., "reasoning", "code") may be abbreviated or ambiguous without context. Each `LabeledContent` should carry a descriptive `accessibilityLabel` that names the axis and the value together, e.g., "Reasoning capability: 0.87 out of 1.0".
- **Affected UI element:** Capability axis rows in `capabilitySection`
- **Current code location:** `LearningDashboardView.swift:41`
- **Severity:** should
- **Fix:**
  ```swift
  ForEach(TesseraCapabilityScore.axisNames, id: \.self) { axis in
      let score = capability.score[axis] ?? 0
      LabeledContent(axis, value: String(format: "%.2f", score))
          .accessibilityLabel("\(axis) capability: \(String(format: "%.2f", score))")
  }
  ```

---

### 13. `teachersSection` — teacher row lacks composite accessibility label

- **Label:** Teacher row not combined into single accessibility element
- **Description:** Each teacher row (line 70–77) contains a `VStack` with four `LabeledContent` children. VoiceOver will read each child separately, potentially out of order, making it hard to understand which data belongs to which teacher. The entire row should be an accessibility element with a combined label.
- **Affected UI element:** Each teacher row in `teachersSection`
- **Current code location:** `LearningDashboardView.swift:70–77`
- **Severity:** should
- **Fix:**
  ```swift
  VStack(alignment: .leading, spacing: 4) {
      // existing content
  }
  .padding(.vertical, 2)
  .accessibilityElement(children: .combine)
  .accessibilityLabel("Teacher \(teacher.teacherId), world-gate pass \(String(format: "%.2f", teacher.worldGatePassFraction)), \(teacher.samples) samples, effective weight \(String(format: "%.2f", teacher.effectiveWeight))")
  ```

---

### 14. Empty state strings not marked as accessibility containers

- **Label:** Empty state text not semantically marked
- **Description:** Three empty-state `Text` views exist: `"No eval on record"` (line 47), `"No adaptation yet"` (line 59), `"No teacher assessments yet"` (line 67). These are informational messages shown when no data is present. They should be explicitly marked with `.accessibilityElement()` and `accessibilityLabel()` so VoiceOver knows they are status messages and not decorative text. Without this, VoiceOver may skip them or misread them.
- **Affected UI element:** Empty state text in `capabilitySection`, `adaptationSection`, `teachersSection`
- **Current code location:** `LearningDashboardView.swift:47, 59, 67`
- **Severity:** nice
- **Fix:**
  ```swift
  Text("No eval on record")
      .foregroundStyle(.secondary)
      .accessibilityElement()
      .accessibilityLabel("No capability evaluation on record")
  ```

---

### 15. "Refresh" button — redundant `accessibilityLabel`

- **Label:** Redundant accessibility label on Refresh button
- **Description:** The toolbar Refresh `Button` (line 29–32) sets `.accessibilityLabel("Refresh")`. This is redundant: the button's `label` view already contains `Text("Refresh")`, and SwiftUI derives the `accessibilityLabel` automatically from the label content. Setting it to the same string has no effect. More importantly, `.help("Refresh learning data")` is a tooltip, not an accessibility hint — these serve different purposes. The tooltip should describe what happens; the `accessibilityHint` describes how to interact. HIG §12.4.
- **Affected UI element:** Refresh toolbar button
- **Current code location:** `LearningDashboardView.swift:29–32`
- **Severity:** nice
- **Fix:**
  ```swift
  Button("Refresh", systemImage: "arrow.clockwise") { load() }
      .help("Refresh all learning data from TesseraLearningCenter")
      .accessibilityHint("Loads the latest capability eval, adaptation record, teacher assessments, foraging summary, and curation summary")
  ```

---

## Summary table

| # | Label | Severity | File | Lines |
|---|---|---|---|---|
| 1 | Color-as-sole-signal on fit badges | **must** | CapacityView.swift | 128–135 |
| 2 | Hardware card accessibility label missing | **must** | CapacityView.swift | 50–90 |
| 3 | Memory bar accessibility value missing | **must** | CapacityView.swift | 92–100 |
| 4 | Model fit row accessibility missing | **must** | CapacityView.swift | 110–124 |
| 5 | Run bench button accessibility label missing | **must** | CapacityView.swift | 157–162 |
| 6 | Non-semantic `.red` on memory bar tint | should | CapacityView.swift | 98 |
| 7 | Hardware cards not keyboard-navigable | should | CapacityView.swift | 50–79 |
| 8 | Non-semantic `.red` on "won't fit" label | should | CapacityView.swift | 120 |
| 9 | Bench result path lacks accessibility label | nice | CapacityView.swift | 164–167 |
| 10 | List section headers not VoiceOver-accessible | should | LearningDashboardView.swift | 19,37,52,64,82,91 |
| 11 | ForEach without explicit `id:` (teachers) | **must** | LearningDashboardView.swift | 69 |
| 12 | Capability axis labels too terse for VoiceOver | should | LearningDashboardView.swift | 41 |
| 13 | Teacher row not combined into accessibility element | should | LearningDashboardView.swift | 70–77 |
| 14 | Empty state text not marked as accessibility containers | nice | LearningDashboardView.swift | 47,59,67 |
| 15 | Redundant accessibilityLabel on Refresh button | nice | LearningDashboardView.swift | 29–32 |

**Total: 4 must / 7 should / 4 nice**

---

## Assumptions

- `TesseraModelFit` conforms to `Identifiable` and its `id` is stable.
- `TesseraTeacherAssessment.teacherId` is the intended stable identifier for the `ForEach` in violation 11.
- The app targets macOS 13+ (so `NavigationSplitView`, `Table`, and `LabeledContent` APIs are available).
- No custom `Color` assets are currently defined in the asset catalog (fix 6 and 8 will either use `Color.red` or add semantic assets).

## Blockers

None — all violations are fixable without API or architectural changes.

## Recommended commit grouping

```
HIG §12.4: must fixes — CapacityView accessibility sweep
  [Fixes violations 1–5]

HIG §2.1 + §12.4: should fixes — color semantics + keyboard nav
  [Fixes violations 6–8, 10, 12, 13]

HIG §12.4: nice fixes — empty states, result path, redundant label
  [Fixes violations 9, 11, 14, 15]
```
