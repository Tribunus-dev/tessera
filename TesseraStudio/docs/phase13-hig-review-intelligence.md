# HIG Review — Intelligence Hub (Tier 1, Agent C)

**Files reviewed:**
- `TesseraStudio/Sources/TesseraStudioMac/Views/Intelligence/IntelligenceView.swift`
- `TesseraStudio/Sources/TesseraStudioMac/Views/Intelligence/AdvancedSection.swift`
- `TesseraStudio/Sources/TesseraStudioMac/Views/Capacity/CapacityView.swift`
- `TesseraStudio/Sources/TesseraStudioMac/Views/LearningDashboardView.swift`

**Reviewer:** Agent C — Tier 1 sweep (scope: Intelligence hub + Capacity + Learning)
**HIG basis:** Apple Human Interface Guidelines (skill `apple-hig`, refreshed 2026-08-08), §§ 1–4, 12.1, 12.4, 12.5, 12.8
**macOS-specific notes:** Dynamic Type is not supported on macOS (§2.2); §12.4 accessibility applies fully; §12.2 macOS patterns apply.

---

## Violations

---

### V-01 — Color-as-sole-signal: model fit badges

| Field | Value |
|---|---|
| **Label** | Color-as-sole-signal: model fit badges |
| **Description** | `badge(kind)` renders a 12pt `Circle()` in green/orange/red with no label, no icon, no shape distinction. VoiceOver cannot perceive the meaning at all. This is the canonical anti-pattern in §2.1 and §3. |
| **Affected UI element** | Green/amber/red circular badge, each model-fit row |
| **Current code location** | `CapacityView.swift:128–135` (`badge(_:)` function) |
| **Severity** | **must** |
| **Fix** | Add `.accessibilityLabel(fit.badge == "green" ? "Fits" : fit.badge == "amber" ? "Marginal fit" : "Does not fit")` to the `Circle()` returned by `badge()`. Pass `fit` (or `kind`) into the function so the label is meaningful. |

---

### V-02 — Color-as-sole-signal: "won't fit" text

| Field | Value |
|---|---|
| **Label** | Color-as-sole-signal: "won't fit" text |
| **Description** | `Text("won't fit")` uses `.foregroundStyle(.red)` as its only signal. VoiceOver has no label; users with red-blind color vision see no difference from the body text. §2.1 and §3 require pairing color with shape, label, or icon. |
| **Affected UI element** | "won't fit" suffix text on non-RAM-fitting model rows |
| **Current code location** | `CapacityView.swift:119–121` |
| **Severity** | **must** |
| **Fix** | Add `.accessibilityLabel("Won't fit in RAM")` and consider an SF Symbol prefix (e.g. `exclamationmark.triangle.fill`) to add a shape/symbol cue alongside the red color. |

---

### V-03 — Color-as-sole-signal: memory bar

| Field | Value |
|---|---|
| **Label** | Color-as-sole-signal: memory bar |
| **Description** | `ProgressView(value: frac).tint(frac > 0.85 ? .red : .accentColor)` — when memory is high, the bar turns red with no supporting icon or text. The caption above gives context but §3 requires the signal itself to be redundant. |
| **Affected UI element** | RAM usage progress bar |
| **Current code location** | `CapacityView.swift:98` |
| **Severity** | **should** |
| **Fix** | Add an `if frac > 0.85` branch that inserts a small `Image(systemName: "exclamationmark.triangle.fill")` tinted `.red` in the `HStack` alongside the progress bar, so the warning is conveyed through symbol + color + text caption. |

---

### V-04 — Missing accessibility label: "Run bench" button

| Field | Value |
|---|---|
| **Label** | Missing accessibility label: "Run bench" button |
| **Description** | The `Button` has no explicit `accessibilityLabel`. When `benchRunning == true` the label becomes `ProgressView` — VoiceOver reads "Button" with no action name. §12.4: all interactive elements must have an accessibility label. |
| **Affected UI element** | MoE bench "Run bench" button |
| **Current code location** | `CapacityView.swift:157–162` |
| **Severity** | **must** |
| **Fix** | Add `.accessibilityLabel(benchRunning ? "Benchmark running" : "Run benchmark")` to the button. |

---

### V-05 — Missing accessibility label: APEX tier picker

| Field | Value |
|---|---|
| **Label** | Missing accessibility label: APEX tier picker |
| **Description** | `Picker("APEX tier", …)` uses `.labelsHidden()` and has no `.accessibilityLabel`. VoiceOver users cannot determine what the segmented control does or what the current selection is. §12.4. |
| **Affected UI element** | APEX quantization tier segmented picker |
| **Current code location** | `CapacityView.swift:146–151` |
| **Severity** | **must** |
| **Fix** | Add `.accessibilityLabel("APEX quantization tier: \(benchTier.label)")` to the picker. |

---

### V-06 — Missing accessibility label: theme tab picker

| Field | Value |
|---|---|
| **Label** | Missing accessibility label: theme tab picker |
| **Description** | `Picker("", selection: $theme)` uses `.labelsHidden()` with an empty label string. VoiceOver has no way to identify this segmented control. §12.4. |
| **Affected UI element** | Intelligence theme segmented control (Models & Hardware / Optimization / Performance & Quality / Agent & Autonomy) |
| **Current code location** | `IntelligenceView.swift:37–43` |
| **Severity** | **must** |
| **Fix** | Add `.accessibilityLabel("Intelligence theme")` to the picker. |

---

### V-07 — Missing accessibility label: interface level picker

| Field | Value |
|---|---|
| **Label** | Missing accessibility label: interface level picker |
| **Description** | `Picker("Level", …)` uses `.labelsHidden()` with the label "Level". VoiceOver has no label to announce this control's purpose. §12.4. |
| **Affected UI element** | Interface level segmented control (Standard / Advanced) |
| **Current code location** | `IntelligenceView.swift:45–52` |
| **Severity** | **must** |
| **Fix** | Add `.accessibilityLabel("Interface level: \(interfaceLevel.displayName)")` to the picker. |

---

### V-08 — Missing accessibility labels: persona cards

| Field | Value |
|---|---|
| **Label** | Missing accessibility labels: persona cards |
| **Description** | `personaRow()` builds a `VStack` with a `Label` (icon + name) and a `Text` (role hint). Neither the container nor the label has an accessibility label. VoiceOver reads the raw text but not a cohesive "Tessy, the primary persona" announcement. §12.4. |
| **Affected UI element** | Tessy and Sky persona rows in Agent & Autonomy theme |
| **Current code location** | `IntelligenceView.swift:153–160` (`personaRow(_:)`) |
| **Severity** | **should** |
| **Fix** | Add `.accessibilityLabel("\(persona.displayName), \(persona.roleHint)")` to the outer `VStack`. |

---

### V-09 — Missing accessibility labels: approval legend rows

| Field | Value |
|---|---|
| **Label** | Missing accessibility labels: approval legend rows |
| **Description** | `legendRow("Auto", "Tessy runs the action…")` and siblings compose two `Text` views. VoiceOver reads them as separate elements. The level name should be announced as a label before the description. §12.4. |
| **Affected UI element** | Auto / Notify / Prompt / Denied legend rows |
| **Current code location** | `IntelligenceView.swift:175–180` (`legendRow(_:_:)`) |
| **Severity** | **should** |
| **Fix** | Wrap the two `Text` views in an `HStack` with `.accessibilityElement(children: .combine)` so VoiceOver announces the full row as one unit: "Auto, Tessy runs the action without asking." |

---

### V-10 — Missing accessibility label: memory bar

| Field | Value |
|---|---|
| **Label** | Missing accessibility label: memory bar |
| **Description** | The `VStack` containing the memory caption and `ProgressView` has no accessibility label. VoiceOver announces the caption text but not a coherent "X percent memory used" fact. §12.4. |
| **Affected UI element** | Memory usage bar (label + progress indicator) |
| **Current code location** | `CapacityView.swift:92–100` |
| **Severity** | **should** |
| **Fix** | Add `.accessibilityLabel("Memory usage: \(Int(frac * 100)) percent, \(used / 1024) of \(cap.ramTotalMB / 1024) gigabytes")` to the outer `VStack`. |

---

### V-11 — Missing accessibility labels: hardware cards

| Field | Value |
|---|---|
| **Label** | Missing accessibility labels: hardware cards |
| **Description** | Each `card()` renders a `VStack` of `Label` + content. VoiceOver reads each text element in isolation without knowing which hardware component it belongs to. §12.4. |
| **Affected UI element** | CPU card, RAM card, GPU card (if present), Bandwidth card |
| **Current code location** | `CapacityView.swift:81–90` (`card` helper) |
| **Severity** | **should** |
| **Fix** | Add `.accessibilityElement(children: .combine)` to each card's `VStack` so the label and content are announced together. |

---

### V-12 — Redundant toolbar button accessibility label mismatch

| Field | Value |
|---|---|
| **Label** | Redundant accessibility label mismatch on Refresh button |
| **Description** | `LearningDashboardView` has `.accessibilityLabel("Refresh")` on a button whose visual label already reads "Refresh". This is redundant — the system auto-generates "Refresh button" from the `Text` child. The real concern is that the label doesn't describe the action's result. §12.4 writing guidance: labels should describe what the action does. |
| **Affected UI element** | Refresh toolbar button |
| **Current code location** | `LearningDashboardView.swift:29–31` |
| **Severity** | **nice** |
| **Fix** | Replace `.accessibilityLabel("Refresh")` with `.accessibilityLabel("Refresh learning data")` to describe the effect rather than the control. |

---

## Passed checks

| Check | Detail |
|---|---|
| System colors | No hard-coded hex values; `.foregroundStyle(.secondary)`, `.accentColor`, `.red` (violations above noted) are system semantic colors. |
| Typography hierarchy | Uses `.largeTitle`, `.title2`, `.headline`, `.body`, `.callout`, `.caption`, `.caption2` correctly; no custom font sizes. |
| SF Symbols | All icons from `systemImage`; no bitmap assets. |
| LazyVGrid | `hardwareCards` uses `LazyVGrid` for the hardware grid. ✅ |
| ScrollView + LazyVStack | Each theme uses `ScrollView { VStack }` — fine for a small number of sections. ✅ |
| `.regularMaterial` | `AgentAutonomyTheme.card` uses `.regularMaterial` correctly for the content layer. ✅ |
| Toolbar placement | `Refresh` is at `.secondaryAction` in `LearningDashboardView` — correct placement. ✅ |
| Navigation title | `IntelligenceView`, `CapacityView`, `LearningDashboardView` all carry `.navigationTitle`. ✅ |
| Section headers | `LearningDashboardView` uses `Section("…")` with `LabeledContent` for key/value pairs. ✅ |
| No emoji as icons | No emoji used as UI elements. ✅ |
| AdvancedSection | `AdvancedSection` correctly hides from `.standard` interface level, uses `DisclosureGroup`. ✅ |
| No custom appearance toggle | No app-specific Dark Mode override. ✅ |
| No stacked sheets | These views are embedded in a navigation split; no sheet stacking observed. ✅ |

---

## Summary

| Severity | Count |
|---|---|
| **must** | 6 (V-01, V-02, V-04, V-05, V-06, V-07) |
| **should** | 5 (V-03, V-08, V-09, V-10, V-11) |
| **nice** | 1 (V-12) |

**Primary theme:** The Intelligence hub surfaces a significant accessibility debt around VoiceOver. Three pickers use `.labelsHidden()` without a compensating `.accessibilityLabel`. Three status indicators (badges, "won't fit", memory bar) use color as the sole signal — the most impactful HIG violation in this review.

**Suggested fix order:**
1. V-01 + V-02 first — color-as-sole-signal is a **must** and affects every model-fit row.
2. V-04, V-05, V-06, V-07 — add `accessibilityLabel` to all interactive controls with hidden labels.
3. V-03 — add symbol redundancy to the memory bar warning.
4. V-08 through V-11 — sweep accessibility labels across informational elements.
5. V-12 — nice cleanup.

No layout, typography, or motion violations were found. The surface is otherwise clean.
