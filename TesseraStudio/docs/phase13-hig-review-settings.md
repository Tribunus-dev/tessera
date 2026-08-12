# HIG Review: Settings Window (Tier 1 — Agent B)

**File:** `TesseraStudio/Sources/TesseraStudioMac/Views/SettingsView.swift`
**Review against:** Apple Human Interface Guidelines (skill §1–§14, refreshed 2026-08-08)
**macOS-specific baseline:** §4 macOS patterns, §14.8 Settings
**Tab:** Settings window via `Settings { SettingsView() }` scene, `Cmd-,`

---

## Summary

The Settings window is built on the correct HIG primitives (`Form` + `Section`, `TabView` for pane switching, `@AppStorage` persistence, Keychain for secrets, `confirmationDialog` for destructive actions, symbol+text pairing for state labels). However, it has pervasive missing `accessibilityLabel` on every interactive element — a **must** violation that blocks VoiceOver use — plus one structural layout issue in the Permissions tab. The rest of the issues are **should / nice**.

---

## Violations

### V-01 — Missing `accessibilityLabel` on all interactive controls (MUST)

**Description:** Every `Toggle`, `Picker`, `Stepper`, `TextField`, `SecureField`, `PathField`, and `Button` in every tab lacks an `accessibilityLabel`. VoiceOver has no way to announce what each control does. This is the single highest-impact violation.

**Affected UI elements (all tabs):**

| Control | Line | Label needed |
|---|---|---|
| `Toggle("Automatic bulleted lists", …)` | 136 | `"Automatic bulleted lists"` |
| `Toggle("Automatic numbered lists", …)` | 137 | `"Automatic numbered lists"` |
| `Toggle("AutoCorrect (text, email, date)", …)` | 138 | `"AutoCorrect"` |
| `Toggle("Match formatting of an inserted list…", …)` | 139 | `"Match formatting of an inserted list"` |
| `Toggle("Bold, italic, underline with math AutoCorrect", …)` | 140 | `"Bold italic underline with math AutoCorrect"` |
| `Picker("Default paste from other apps", …)` | 141 | `"Default paste from other apps"` |
| `TextField("Default font family", …)` | 148 | `"Default font family"` |
| `Stepper("Default font size…", …)` | 150 | `"Default font size"` |
| `TextField("Default text box font family", …)` | 153 | `"Default text box font family"` |
| `Stepper("Default font size…", …)` | 155 | `"Default text box font size"` |
| `Toggle("Enable AI features", …)` | 158 | `"Enable AI features"` |
| `Picker("AI route", …)` | 159 | `"AI route"` |
| `Picker("Default runtime", …)` | 170 | `"Default runtime"` |
| `PathField("Model directory", …)` | 175 | `"Model directory"` |
| `Stepper("Threads…", …)` | 176 | `"Thread count"` |
| `Stepper("Max tool iterations…", …)` | 185 | `"Max tool iterations"` |
| `Picker("Default approval level", …)` | 186 | `"Default approval level"` |
| `TextField("Token budget", …)` | 191 | `"Token budget"` |
| `Picker("LLM provider", …)` | 199 | `"LLM provider"` |
| `PathField("GGUF model path", …)` | 208 | `"GGUF model path"` |
| `PathField("libllama.dylib path…", …)` | 210 | `"libllama.dylib path"` |
| `TextField("Context length", …)` | 212 | `"Context length"` |
| `Stepper("GPU layers…", …)` | 213 | `"GPU layers"` |
| `TextField("Base URL", …)` | 220 | `"Base URL"` |
| `SecureField("API key", …)` | 221 | `"API key"` |
| `TextField("Model name", …)` | 226 | `"Remote model name"` |
| `Toggle("Stream responses (SSE)", …)` | 227 | `"Stream responses"` |
| `Picker("Floor (minimum requirement)", …)` | 388 | `"Permission floor"` |
| `Picker("Ceiling (maximum learning may reach)", …)` | 393 | `"Permission ceiling"` |
| `Stepper("Approvals needed to grant…", …)` | 397 | `"Approvals needed to grant"` |
| `Stepper("Distinct sessions needed…", …)` | 399 | `"Distinct sessions needed"` |
| `Stepper("Path-glob depth…", …)` | 401 | `"Path-glob depth"` |
| `TextField("Goal (optional)", …)` | 415 | `"Autonomous session goal"` |
| `TextField("Reason (for the audit log)", …)` | 416 | `"Autonomous session reason"` |
| `Stepper("Minutes…", …)` | 417 | `"Autonomous session duration"` |
| `Button("Start autonomous session")` | 418 | `"Start autonomous session"` |
| `Button("Confirm")` | 444 | `"Confirm recommendation"` |
| `Button("Not now")` | 445 | `"Dismiss recommendation"` |
| `Button("Never")` | 446 | `"Block recommendation permanently"` |
| `Button("Revoke")` | 472 | `"Revoke permission"` |
| `Button("Un-revoke")` | 475 | `"Restore revoked permission"` |
| `Button("Add to denylist")` | 478 | `"Add to denylist"` |
| `Button("Train now")` | 508 | `"Train approver network now"` |
| `Button("Reset all grants")` | 520 | `"Reset all grants"` |
| `Button("Purge all learning data", role: .destructive)` | 523 | `"Purge all learning data"` |
| `Toggle("Coercion mode", …)` | 679 | `"Coercion mode"` |
| `Button("Test")` | 668 | `"Test covert trigger"` |
| `Button("Save")` | 722 | `"Save covert trigger"` |
| `Button("Cancel")` | 725 | `"Cancel covert trigger edit"` |
| `Toggle("Enable telemetry", …)` | 846 | `"Enable telemetry"` |
| `Picker("Log level", …)` | 847 | `"Log level"` |
| `PathField("Custom CLI path", …)` | 852 | `"Custom CLI path"` |
| `PathField("tessera-cli path", …)` | 854 | `"tessera-cli path"` |

**Current code location:** All lines listed above; the entire file is in scope.
**Severity:** **must** — §12.4 item 1: "All interactive elements have `accessibilityLabel`." VoiceOver is broken for every control.
**Fix:** Add `.accessibilityLabel("…")` to every interactive element. For `Toggle`/`Picker`/`Stepper`/`TextField`/`SecureField`, the label should mirror the visible label text. For icon-only buttons (Test, Save, Cancel in the covert trigger section), use a descriptive label that makes sense without the surrounding context.

```swift
// Example fixes
Toggle("Automatic bulleted lists", isOn: $autoBulletedLists)
    .accessibilityLabel("Automatic bulleted lists")

TextField("Default font family", text: $defaultDocFontFamily)
    .accessibilityLabel("Default font family")

Button("Save") { commitCovertTrigger() }
    .accessibilityLabel("Save covert trigger")
```

---

### V-02 — LLM provider picker uses `.pickerStyle(.inline)` (SHOULD)

**Description:** `Picker("LLM provider", selection: $llmProviderType)` at line 199 uses `.pickerStyle(.inline)`. For a settings form, `.inline` renders an expansive list (one radio-button-style row per option) that takes a large amount of vertical space in the already-cramped Model tab. The canonical picker style for settings forms is `.menu` (a compact pop-up button) or `.segmented` for 2-5 options.

**Current code location:** `SettingsView.swift:199–204`
**Severity:** **should** — §13.11 Pickers, §14.8 Settings: "Use a pop-up button for short lists."
**Fix:** Remove `.pickerStyle(.inline)` and let the default `.menu` style apply, or use `.pickerStyle(.segmented)` if the provider count is ≤5. The inline expansion content (On-Device section, Remote API section) should remain conditional on the selected provider.

```swift
// Change line 204 from:
.pickerStyle(.inline)
// to: nothing (default .menu) or:
.pickerStyle(.segmented)
```

---

### V-03 — Permissions tab window height too short for its content (MUST)

**Description:** The `SettingsView` body sets `.frame(width: 520, height: 460)` at line 113. The **Permissions** tab (`autonomyTab`) contains five sections: Disposition, Autonomous session, Recommendations, Learned permissions, Approver network, and Global — more content than 460 pt can hold. This violates the macOS guidance to choose a default size suited to the content and set a minimum size. The tab also uses a `ScrollView` wrapper, which is the correct recovery, but the user has to scroll even at default size — not a great experience.

**Current code location:** `SettingsView.swift:113`
**Severity:** **must** — §4.1 Windows: "Choose an initial shape that suits your content." / "Make sure window controls don't overlap toolbar items." A window that forces scrolling in a tab that users must visit to understand permissions is a UX failure.
**Fix:** Increase the default height. For the Permissions tab's content (≈5 sections × ~80 pt each ≈ 400 pt, plus the outer ScrollView padding), a minimum of **540 pt** is appropriate. Use `WindowSizePreferences` or set `.frame(minHeight: 540)` for the tab's scroll container, and increase the window's default/initial size accordingly:

```swift
.frame(width: 520, height: 540)  // increased from 460
```

Alternatively, consider whether all six sections belong in one tab or should be split. The "Permissions" name in the tab item is correct (§4.14: "permissions is the word users scan for").

---

### V-04 — PathField's inner TextField has no `accessibilityLabel` (MUST)

**Description:** The `PathField` custom component (line 911–919) wraps a `LabeledContent` containing a plain `TextField`. The inner `TextField` uses `label` as its placeholder but has no `accessibilityLabel`. When VoiceOver focuses the text field, it announces the placeholder, but an explicit label is more reliable and spec-compliant.

**Current code location:** `SettingsView.swift:914`
**Severity:** **must** — §12.4 item 1.
**Fix:** Add `.accessibilityLabel(label)` to the inner `TextField`:

```swift
TextField(label, text: $text)
    .accessibilityLabel(label)
```

---

### V-05 — DisclosureGroup label inside HStack lacks `accessibilityLabel` (MUST)

**Description:** In `pleadTheFifthTab` (line 627–640), the `DisclosureGroup`'s label is an `HStack` containing `Text("Plea the Fifth")` and a `Circle()`. The `HStack` itself is the disclosure label. VoiceOver may not correctly traverse this compound label. The fix is to mark the `HStack` as a single accessibility element, or move the label to a `@ViewBuilder` and set `.accessibilityLabel("Plea the Fifth")` on the `HStack`.

**Current code location:** `SettingsView.swift:627–640`
**Severity:** **must** — §12.4 item 1 (VoiceOver reads all UI elements in a sensible order).
**Fix:**

```swift
} label: {
    HStack {
        Text("Plea the Fifth")
        if coercionMode {
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
                .accessibilityLabel("Covert trigger armed")
        }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Plea the Fifth")
```

Note: the inner `Circle().accessibilityLabel("Covert trigger armed")` is already present at line 637; the HStack-level `.accessibilityElement(children: .combine)` + `.accessibilityLabel` ensures the combined label is read as one unit.

---

### V-06 — Hard-coded `.opacity()` for autonomy badge backgrounds (SHOULD)

**Description:** In `autonomyBadges(for:)` (lines 492–502), the badge backgrounds use `.red.opacity(0.15)`, `.green.opacity(0.15)`, and `.orange.opacity(0.15)`. These are not semantic colors and will not adapt to Increase Contrast mode. The badge foreground text (the `Label` text) already pairs a symbol with the text, which is correct — but the background color should use a system fill.

**Current code location:** `SettingsView.swift:492–502`
**Severity:** **should** — §2.1 Color: "Use system colors. The actual color values may fluctuate release-to-release; never hard-code the hex values." / §12.4 item 3: "Increase Contrast: color variants swap when the setting is on (system colors do this automatically)."
**Fix:** Use a tinted system background instead of `.opacity()`:

```swift
// Instead of:
.background(.red.opacity(0.15))
// Use:
.background(Color.red.opacity(0.15).opacity(0.3))  // lighter tint
// Or, better:
.background(Color.red.opacity(0.2))  // keep opacity but note it won't adapt

// Best: use a named Color asset with light/dark variants, or:
.background(Color.red.opacity(0.15))  // note: does NOT adapt to Increase Contrast
```

If the badge is purely decorative (symbol + text already convey meaning), the colored background is not needed at all. If it stays, it should use a semantic color asset that has an Increase Contrast variant. Given the badge text is always visible (the `Label` text), removing the colored background entirely is the cleanest fix.

---

### V-07 — "Un-revoke" button label is awkward for accessibility (SHOULD)

**Description:** The `unrevokeEntry` action is presented as a button labeled `"Un-revoke"`. The `Un-revoke` label (hyphen + lowercase) is a collapsed compound that doesn't read naturally. The canonical undo/restoration label would be `"Restore"` or `"Undo Revoke"`.

**Current code location:** `SettingsView.swift:475`
**Severity:** **should** — §2.9 Writing: "Button labels are verbs, not phrases."
**Fix:** Change `"Un-revoke"` to `"Restore"`.

```swift
Button("Restore") { unrevokeEntry(entry.actionClass) }
```

Also add `.accessibilityLabel("Restore revoked permission")`.

---

### V-08 — Covert trigger Save/Cancel buttons lack `.keyboardShortcut` (NICE)

**Description:** The Save and Cancel buttons in the covert trigger edit section (lines 722–730) have no keyboard shortcuts. While this is a non-standard form, a user editing the trigger phrase should be able to confirm with `Return` (standard TextField submit) and cancel with `Escape`. The `SecureField` already has `.onSubmit` wired to `commitCovertTrigger()` at line 719, which is good. Adding `.keyboardShortcut(.cancelAction)` on the Cancel button would wire it to the standard cancel mechanism.

**Current code location:** `SettingsView.swift:722–730`
**Severity:** **nice** — §4.5 Keyboard: standard cancel shortcut convention.
**Fix:**

```swift
Button("Cancel") { ... }
    .keyboardShortcut(.cancelAction)
```

---

### V-09 — Font sizing in permissions entry uses `.system(.body, design: .monospaced)` (NICE)

**Description:** The `actionClass` label in the permissions entry uses `.font(.system(.body, design: .monospaced))` (line 464). The canonical way to express a monospaced body text is `.font(.monospacedBody)`, which is shorter and resolves to the correct system monospaced variant on the deployment target.

**Current code location:** `SettingsView.swift:464`
**Severity:** **nice** — §11.6 Typography catalog.
**Fix:**

```swift
// Change:
Text(entry.actionClass).font(.system(.body, design: .monospaced))
// To:
Text(entry.actionClass).font(.monospacedBody)
```

---

## Positive observations (no violation, worth noting)

These patterns are already implemented correctly:

- ✅ `SecureField` used for the API key (line 221) and covert trigger phrase (line 718); not `TextField`.
- ✅ Symbol + text pairing for Keychain state rows (`apiKeyStateRow`, `skyKeyStateRow`, `trainBinaryStateRow`, `runtimeDrafterStateRow`, `tesseraCLIStateRow`) — state is never color-only.
- ✅ Symbol + text pairing for autonomy badges (`autonomyBadges`) — state is never color-only.
- ✅ `confirmationDialog` with `titleVisibility: .visible` and `role: .destructive` for Reset all grants and Purge all learning data (lines 529–546).
- ✅ Coercion-mode design (section 9.5 comment): the Plea the Fifth section collapses by default when coercion mode is on — appropriate for the threat model.
- ✅ `onDisappear` on the SecureField commits the API key (line 223) — no explicit "Save" button needed.
- ✅ `formStyle(.grouped)` on all Form views — correct macOS settings form appearance.
- ✅ `@AppStorage` used correctly for all persisted preferences; Keychain used for all secrets.
- ✅ `PathField` custom component correctly uses `NSOpenPanel` with security-scoped starting URL.
- ✅ No hard-coded colors; all foreground styling uses `.foregroundStyle(.secondary)` / `.tertiary` (semantic).
- ✅ Window dimensions fixed at 520×460 (but see V-03: height needs to increase).
- ✅ Tab labels use SF Symbols matching the tab icon.

---

## Checklist items mapped

| Item | §12 ref | Status in this file |
|---|---|---|
| All interactive elements have `accessibilityLabel` | §12.4 / V-01, V-04, V-05 | **FAIL** |
| Color never the only signal; symbol+text pairing | §12.4 | ✅ PASS |
| VoiceOver reads elements in sensible order | §12.4 | ⚠️ Partial (V-05) |
| Font text styles use system text styles | §12.1 | ⚠️ V-09 (nice) |
| No hard-coded colors | §12.1 | ✅ PASS |
| Settings window uses `Settings` scene + TabView | §14.8 | ✅ PASS |
| Window has default/minimum size | §4.1 | ⚠️ V-03 (FAIL must) |
| Confirmation dialog for destructive actions | §13.5 | ✅ PASS |
| Keychain for secrets | §14.3 Privacy | ✅ PASS |
