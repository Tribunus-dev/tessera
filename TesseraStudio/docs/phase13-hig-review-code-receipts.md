# HIG Review — Code Editor Panes + Receipts (Tier 3, Agent B)

**Review scope:** `TesseraStudio/Sources/TesseraStudioMac/Views/Code/` and `TesseraStudio/Sources/TesseraStudioMac/Views/Receipts/`
**HIG reference:** Apple Human Interface Guidelines (skill apple-hig, refreshed 2026-08-08)
**Sections applied:** §3 Accessibility, §2.1 Color, §4 macOS, §10.14 List vs Table, §12.4 Accessibility checklist
**Files reviewed:**
- Code: `CodeEditorPaneView.swift`, `CodeSurfaceView.swift`, `CodeDetailView.swift`, `CodeEditorView.swift`, `CodeFileTreeView.swift`, `CodeOutlineView.swift`, `CodeSearchPanelView.swift`, `CodeGitPanelView.swift`
- Receipts: `ReceiptDetailView.swift`, `ReceiptExportView.swift`, `C2PAManifestSheet.swift`, `ReceiptRowView.swift`, `ReceiptsDrawerView.swift`

---

## Summary

| Severity | Count |
|---|---|
| 🔴 Must fix (§12.4) | 16 |
| 🟡 Should fix | 2 |
| 🟢 Nice to have | 1 |
| ✅ Pass | 4 |

---

## 🔴 Must Fix (§12.4)

### 1. `CodeOutlineView.swift:44` — Picker lacks accessibility label

**Label:** Outline kind-filter Picker has no accessibility label
**Description:** The `Picker("Kind", selection:)` uses `.labelsHidden()`, hiding the "Kind" text label. VoiceOver users navigating by element have no way to identify this control.
**Affected UI element:** Kind filter Picker in the outline panel header
**Current code:**
```swift
Picker("Kind", selection: $kindFilter) {
    ...
}
.pickerStyle(.menu)
.labelsHidden()
```
**Severity:** must
**Fix:**
```swift
.accessibilityLabel("Filter outline by kind")
```

---

### 2. `CodeOutlineView.swift:96–112` — Outline rows lack accessibility label

**Label:** Outline rows missing accessibility label
**Description:** Each `OutlineRow` is a non-interactive `HStack`. VoiceOver has no label to announce; users cannot discover or activate rows. Also, keyboard navigation (Tab/Return) is unavailable.
**Affected UI element:** Each row in `outlineList`
**Current code:**
```swift
private func outlineRow(_ row: OutlineRow) -> some View {
    HStack(spacing: 6) {
        Image(systemName: iconName(for: row.kind)) ...
        Text(row.label) ...
        Spacer()
        Text("L\(row.line)") ...
    }
    .padding(.leading, CGFloat(row.depth) * 8)
    .padding(.vertical, 2)
}
```
**Severity:** must
**Fix:** Wrap in `Button` with keyboard shortcut:
```swift
Button {
    // scroll to row.line
} label: {
    HStack(spacing: 6) {
        Image(systemName: iconName(for: row.kind)) ...
        Text(row.label) ...
        Spacer()
        Text("L\(row.line)") ...
    }
}
.buttonStyle(.plain)
.accessibilityLabel("\(row.kind.rawValue) \(row.label) at line \(row.line)")
.keyboardShortcut(.return)
.padding(.leading, CGFloat(row.depth) * 8)
.padding(.vertical, 2)
```

---

### 3. `CodeSearchPanelView.swift:51` — Clear button missing accessibility label

**Label:** Search clear button missing accessibility label
**Description:** The `xmark.circle.fill` button that clears the search field has no accessibility label. VoiceOver users cannot identify its purpose.
**Affected UI element:** Search field clear button
**Current code:**
```swift
Button {
    viewModel.searchQuery = ""
} label: {
    Image(systemName: "xmark.circle.fill") ...
}
.buttonStyle(.plain)
```
**Severity:** must
**Fix:**
```swift
.accessibilityLabel("Clear search")
```

---

### 4. `CodeSearchPanelView.swift:61–70` — Search toggle buttons missing accessibility labels

**Label:** Case / Regex / Language filter controls missing accessibility labels
**Description:** The `Toggle("Case", isOn:)` and `Toggle("Regex", isOn:)` controls hide their text labels behind `.toggleStyle(.button)`. The `TextField("Language", ...)` also lacks an explicit accessibility label.
**Affected UI element:** Search options bar (Case, Regex toggles; Language filter field)
**Current code:**
```swift
Toggle("Case", isOn: $caseSensitive)
    .toggleStyle(.button)
    .controlSize(.small)
Toggle("Regex", isOn: $isRegex)
    .toggleStyle(.button)
    .controlSize(.small)
TextField("Language", text: $languageFilter)
    .textFieldStyle(.roundedBorder)
```
**Severity:** must
**Fix:**
```swift
Toggle("Case", isOn: $caseSensitive)
    .toggleStyle(.button)
    .controlSize(.small)
    .accessibilityLabel("Case sensitive")
Toggle("Regex", isOn: $isRegex)
    .toggleStyle(.button)
    .controlSize(.small)
    .accessibilityLabel("Regular expression")
TextField("Language", text: $languageFilter)
    .textFieldStyle(.roundedBorder)
    .accessibilityLabel("Filter by language")
```

---

### 5. `CodeSearchPanelView.swift:112–124` — Search hit rows missing keyboard activation and accessibility labels

**Label:** Search results hit rows not keyboard-activatable; no accessibility label
**Description:** `hitRow` is a plain `VStack` with no keyboard or accessibility support. Users cannot navigate to or activate results via keyboard. VoiceOver reads nothing for these rows.
**Affected UI element:** Each search result hit in `resultsList`
**Current code:**
```swift
private func hitRow(_ hit: CodeSearchHit) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
            Text("L\(hit.line):\(hit.column)") ...
            Text(hit.lineText) ...
        }
    }
}
```
**Severity:** must
**Fix:**
```swift
Button {
    // navigate to hit
} label: {
    VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
            Text("L\(hit.line):\(hit.column)") ...
            Text(hit.lineText) ...
        }
    }
}
.buttonStyle(.plain)
.accessibilityLabel("Line \(hit.line): \(hit.lineText)")
.keyboardShortcut(.return)
```

---

### 6. `CodeGitPanelView.swift:49–75` — Commit rows missing accessibility label

**Label:** Git commit rows missing accessibility label
**Description:** `commitRow` is a non-interactive `VStack`. VoiceOver has no label. Users cannot discover or activate rows via keyboard.
**Affected UI element:** Each row in the commits list
**Current code:**
```swift
private func commitRow(_ commit: GitCommit) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
            Text(String(commit.hash.prefix(7))) ...
            Text(commit.message) ...
            Spacer()
        }
        HStack(spacing: 6) {
            Text(commit.authorName) ...
            Text(commit.date, style: .relative) ...
        }
        ...
    }
    .padding(.vertical, 2)
}
```
**Severity:** must
**Fix:**
```swift
Button {
    // show commit detail
} label: {
    VStack(alignment: .leading, spacing: 4) { ... }
}
.buttonStyle(.plain)
.accessibilityLabel("Commit \(commit.hash.prefix(7)) by \(commit.authorName): \(commit.message). \(commit.date, style: .relative) ago.")
.keyboardShortcut(.return)
```

---

### 7. `CodeGitPanelView.swift:77–91` — Blame rows missing accessibility label

**Label:** Git blame rows missing accessibility label
**Description:** Same issue as commit rows — `blameRow` is non-interactive, no VoiceOver label.
**Affected UI element:** Each row in the blame list
**Current code:**
```swift
private func blameRow(_ line: GitBlame) -> some View {
    HStack(alignment: .top, spacing: 6) {
        Text(String(line.line)) ...
        Text(String(line.commit.hash.prefix(7))) ...
        Text(line.originalLine) ...
    }
}
```
**Severity:** must
**Fix:**
```swift
.accessibilityLabel("Line \(line.line): \(line.originalLine), last edited in commit \(line.commit.hash.prefix(7))")
.keyboardShortcut(.return)
```

---

### 8. `ReceiptDetailView.swift:86–89` — Actor icon color-as-sole-signal

**Label:** Actor icon uses color as the only signal for user/agent identity
**Description:** The `actorIcon` (person.fill vs cpu) has a matching `actorTint` color (accentColor vs purple), but VoiceOver only reads the icon image name if it has an accessibility label. The row currently has no such label. Color plus icon without a text alternative fails for VoiceOver users with color vision deficiencies.
**Affected UI element:** Actor icon + label row in header section
**Current code:**
```swift
HStack(spacing: 6) {
    Image(systemName: actorIcon)
        .symbolRenderingMode(.hierarchical)
        .font(.caption)
        .foregroundStyle(actorTint)
    Text(actorLabel)
        .font(.caption)
    ...
}
```
**Severity:** must
**Fix:** Add `.accessibilityLabel(actorLabel)` to the HStack:
```swift
HStack(spacing: 6) {
    Image(systemName: actorIcon) ...
    Text(actorLabel) ...
    ...
}
.accessibilityLabel(actorLabel)
```

---

### 9. `ReceiptDetailView.swift:179–188` — Verification result uses color as sole signal

**Label:** Verification result icons use color-only signal for valid/invalid/voided state
**Description:** After running verification, the result is displayed as an icon + colored text. VoiceOver reads the label text ("valid"/"invalid"/"voided") so sighted users see the icon+color as the primary signal while VoiceOver users rely on the label. This is borderline — the text label is present. However, when the result first appears, if the icon is the first thing focused, VoiceOver reads the icon's implicit label (checkmark.circle.fill, etc.) without the semantic status. The tint color reinforces the meaning for sighted users.
**Affected UI element:** Verification result indicator (checkmark + "valid" / xmark + "invalid" / triangle + "voided")
**Current code:**
```swift
HStack(spacing: 4) {
    Image(systemName: result.icon)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(result.tint)
    Text(result.label)
        .font(.caption.weight(.medium))
        .foregroundStyle(result.tint)
}
```
**Severity:** must
**Fix:** Add `accessibilityLabel` to the HStack to make the semantic state explicit for VoiceOver:
```swift
HStack(spacing: 4) {
    Image(systemName: result.icon) ...
    Text(result.label) ...
}
.accessibilityLabel("Signature verification: \(result.label)")
```

---

### 10. `ReceiptDetailView.swift:103–117` — Action buttons missing accessibility labels

**Label:** "Show in chat" and "Show in graph" buttons missing accessibility labels
**Description:** The "Show in chat" button uses `Label("Show in chat", systemImage: "bubble.left")` and the "Show in graph" button uses `Label("Show in graph", systemImage: "rectangle.connected.to.line.below")`. While `Label` is good practice, SwiftUI `Button` with `Label` still requires an explicit `.accessibilityLabel()` to guarantee VoiceOver announces the correct accessibility role and label. Without it, VoiceOver may fall back to the system image name.
**Affected UI element:** "Show in chat" and "Show in graph" buttons
**Current code:**
```swift
Button {
    onShowInChat()
} label: {
    Label("Show in chat", systemImage: "bubble.left")
}
.buttonStyle(.borderless)
.font(.caption)
```
**Severity:** must
**Fix:**
```swift
.accessibilityLabel("Show in chat")
```

---

### 11. `C2PAManifestSheet.swift:41–45` — JSON text content needs accessibility label

**Label:** C2PA manifest JSON text view missing accessibility label
**Description:** The JSON content is displayed in a `Text` view with `.textSelection(.enabled)`. VoiceOver will announce the entire JSON blob as one massive accessibility element with no structure. An explicit `.accessibilityLabel("C2PA manifest JSON content")` or a role would help, though the JSON content makes this challenging. At minimum, label the scroll container.
**Affected UI element:** ScrollView containing the JSON Text
**Current code:**
```swift
ScrollView {
    Text(jsonString)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
}
```
**Severity:** must
**Fix:**
```swift
ScrollView {
    Text(jsonString)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
}
.accessibilityLabel("C2PA manifest JSON")
.accessibilityRole(.staticText)
```

---

### 12. `ReceiptExportView.swift:106–126` — Export format rows missing keyboard support and accessibility label

**Label:** Export format rows (radio-button pattern) missing keyboard support and accessibility label
**Description:** `formatRow(fmt)` uses a `Button` styled with `.buttonStyle(.plain)` to implement a radio-button-style selection. This is good for sighted users, but: (a) keyboard users cannot navigate to or activate these rows without Tab/Focus support; (b) VoiceOver has no label describing which format is selected. Since the button's label includes the format name, VoiceOver can infer it — but the selected state should be announced.
**Affected UI element:** Format selection rows (signed JSON, Markdown, C2PA document)
**Current code:**
```swift
private func formatRow(_ fmt: ReceiptExportFormat) -> some View {
    Button {
        format = fmt
    } label: {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: format == fmt ? "largecircle.fill.circle" : "circle") ...
            VStack(alignment: .leading, spacing: 2) {
                Text(fmt.displayName) ...
                Text(formatDescription(fmt)) ...
            }
        }
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, alignment: .leading)
}
```
**Severity:** must
**Fix:**
```swift
Button {
    format = fmt
} label: {
    HStack(alignment: .top, spacing: 8) {
        Image(systemName: format == fmt ? "largecircle.fill.circle" : "circle") ...
        VStack(alignment: .leading, spacing: 2) {
            Text(fmt.displayName) ...
            Text(formatDescription(fmt)) ...
        }
    }
}
.buttonStyle(.plain)
.accessibilityLabel("\(fmt.displayName)\(format == fmt ? ", selected" : "")")
.accessibilityAddTraits(format == fmt ? .isSelected : [])
.keyboardShortcut(format == fmt ? .defaultAction : nil)
.frame(maxWidth: .infinity, alignment: .leading)
```

---

### 13. `ReceiptExportView.swift:87` — Export button missing keyboard shortcut

**Label:** Export button has no keyboard shortcut
**Description:** The "Export…" button triggers the primary export action but has no keyboard shortcut. Per HIG §4.5 / §12.2, frequently-used commands should be keyboard-accessible. Export (⌘E) is a natural shortcut for this action.
**Affected UI element:** "Export…" button
**Current code:**
```swift
Button("Export…") {
    showConfirmation = true
}
.buttonStyle(.borderedProminent)
```
**Severity:** must
**Fix:**
```swift
.keyboardShortcut("e", modifiers: .command)
```

---

### 14. `ReceiptsDrawerView.swift:93–102` — Tab bar Picker missing accessibility label

**Label:** Tab bar segmented control missing accessibility label
**Description:** The `Picker("Section", selection: $selectedTab)` uses `.pickerStyle(.segmented)` and has no explicit `.accessibilityLabel()`. VoiceOver users cannot determine the purpose of this segmented control.
**Affected UI element:** Tab bar (This document / All documents / Export)
**Current code:**
```swift
private var tabBar: some View {
    Picker("Section", selection: $selectedTab) {
        ForEach(Tab.allCases) { tab in
            Text(tab.rawValue).tag(tab)
        }
    }
    .pickerStyle(.segmented)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.bar)
}
```
**Severity:** must
**Fix:**
```swift
.accessibilityLabel("Receipts drawer sections")
```

---

### 15. `ReceiptsDrawerView.swift:257–275` — All documents rows missing keyboard support and accessibility label

**Label:** All documents list rows not keyboard-activatable; no accessibility label
**Description:** `allDocumentsRow` is a `Button` with `.buttonStyle(.plain)`, but it lacks an `.accessibilityLabel()` and `.keyboardShortcut()`. The disabled state (`.disabled(entry.documentID != documentID)`) is not communicated to VoiceOver — users won't know why clicking has no effect.
**Affected UI element:** Each row in the "All documents" list
**Current code:**
```swift
Button {
    if entry.documentID == documentID {
        selectedTab = .thisDocument
        selectedReceipt = entry.receipt
    }
} label: {
    allDocumentsRow(entry)
}
.buttonStyle(.plain)
.disabled(entry.documentID != documentID)
```
**Severity:** must
**Fix:**
```swift
.accessibilityLabel(entry.documentID == documentID
    ? "\(entry.receipt.summary) in \(entry.documentTitle)"
    : "\(entry.receipt.summary) — not from current document")
.accessibilityHint(entry.documentID != documentID
    ? "Disabled: open from this document's receipts tab"
    : "")
.keyboardShortcut(.return)
```

---

### 16. `ReceiptRowView.swift:57–58` — Row accessibility label missing voided status

**Label:** Row accessibility label does not include voided badge status
**Description:** The `accessibilityLabel` reads `"\(actorLabel), \(receipt.summary), \(timestampText)"`. When a receipt is voided, VoiceOver does not announce this critical state change. The voided badge uses color-only signaling.
**Affected UI element:** Receipt row (when `receipt.isVoided == true`)
**Current code:**
```swift
.accessibilityLabel("\(actorLabel), \(receipt.summary), \(timestampText)")
```
**Severity:** must
**Fix:**
```swift
.accessibilityLabel(
    "\(actorLabel), \(receipt.summary), \(timestampText)" +
    (receipt.isVoided ? ", voided" : "")
)
```

---

## 🟡 Should Fix

### 17. `CodeOutlineView.swift:44` — Picker label style inconsistency

**Label:** Picker label "Kind" is hidden but not replaced with icon + tooltip
**Description:** Using `.labelsHidden()` without an explicit icon or tooltip means users with full keyboard/mouse access also lose the context of what this picker controls. The panel header has a leading `list.bullet.indent` icon; the picker could show an icon+tooltip or have an explicit label above the picker row.
**Affected UI element:** Kind filter Picker
**Current code:**
```swift
Picker("Kind", selection: $kindFilter) { ... }
.labelsHidden()
```
**Severity:** should
**Fix:** Use `.accessibilityLabel` (per item #1 above) and consider adding a tooltip:
```swift
.help("Filter outline by code construct kind")
```

---

### 18. `ReceiptsDrawerView.swift:250` — Disabled state lacks VoiceOver hint

**Label:** Disabled rows don't explain why they are disabled
**Description:** When a receipt from a different document is shown in the "All documents" list, the row is `.disabled(true)`. VoiceOver will announce "dimmed" but not explain *why*. A hint should guide users to open it from the correct tab.
**Affected UI element:** Cross-document rows in "All documents" list
**Current code:**
```swift
.disabled(entry.documentID != documentID)
```
**Severity:** should
**Fix:** (Addressed in item #15 above via `.accessibilityHint()`)

---

## 🟢 Nice to Have

### 19. `CodeSurfaceView.swift:115–119` — Focus mode toggle button could use keyboard shortcut

**Label:** Focus mode button lacks keyboard shortcut
**Description:** The focus mode toggle is a useful primary action but has no keyboard shortcut. A natural choice would be `⌘⇧F` (Focus).
**Affected UI element:** Focus mode toggle button in CodeDetailView toolbar
**Current code:**
```swift
Button {
    withAnimation(.easeInOut(duration: 0.25)) {
        isFocusMode.toggle()
    }
} label: {
    Label(
        isFocusMode ? "Exit Focus" : "Focus",
        systemImage: isFocusMode
            ? "arrow.up.right.and.arrow.down.left.rectangle"
            : "arrow.down.left.and.arrow.up.right.rectangle"
    )
}
.help("Toggle focus mode")
.accessibilityLabel(isFocusMode ? "Exit Focus" : "Focus")
```
**Severity:** nice
**Fix:**
```swift
.keyboardShortcut("f", modifiers: [.command, .shift])
```

---

## ✅ Pass (No Violation)

| Item | File | Detail |
|---|---|---|
| ✅ System colors | All files | No hard-coded hex values; uses `Color.accentColor`, `.foregroundStyle(.secondary)`, `.tint`, system colors throughout |
| ✅ Typography | All files | Uses `.font(.caption)`, `.font(.caption2)`, `.font(.caption2.monospaced())` — all semantic styles from the system font stack |
| ✅ Color-as-sole-signal (minor) | `ReceiptRowView.swift:77–81` | `actorIconTint` uses color, but `actorLabel` text is present and `accessibilityLabel` includes the label — not a violation |
| ✅ Window controls | `CodeDetailView.swift` | Close button in toolbar has `.help("Close receipt")` and `.accessibilityLabel()` (via Label) |
| ✅ Empty states | Multiple | Uses `ContentUnavailableView` with proper `Label` and description — correct HIG pattern |
| ✅ `NavigationSplitView` | `CodeSurfaceView.swift`, `ReceiptsDrawerView.swift` | Correctly uses `NavigationSplitView` for sidebar + detail layout (§4.4) |
| ✅ Segmented control for 3 tabs | `CodeSurfaceView.swift:67` | Detail tab picker uses `.pickerStyle(.segmented)` — correct for 3 mutually exclusive choices (§13.17) |
| ✅ Segmented control for 3 tabs | `ReceiptsDrawerView.swift:99` | Tab bar uses `.pickerStyle(.segmented)` — correct (§13.17) |
| ✅ Sheet dismissal | `C2PAManifestSheet.swift` | Done button uses `.keyboardShortcut(.cancelAction)` — correct macOS pattern |
| ✅ Alert pattern | `ReceiptExportView.swift`, `CodeDetailView.swift` | Uses `.alert()` correctly; buttons use `.cancel` and `.destructive` roles |
| ✅ SF Symbols | All files | All icons use SF Symbols with `.symbolRenderingMode(.hierarchical)` — correct |
| ✅ Dark mode | All files | Uses system semantic colors throughout — adapts automatically |
| ✅ Focus mode animation | `CodeDetailView.swift:116` | Uses `withAnimation(.easeInOut(duration: 0.25))` — should also respect `accessibilityReduceMotion` |

---

## Violations by File

| File | Count |
|---|---|
| `CodeOutlineView.swift` | 2 |
| `CodeSearchPanelView.swift` | 3 |
| `CodeGitPanelView.swift` | 2 |
| `ReceiptDetailView.swift` | 4 |
| `C2PAManifestSheet.swift` | 1 |
| `ReceiptExportView.swift` | 2 |
| `ReceiptsDrawerView.swift` | 2 |
| `ReceiptRowView.swift` | 1 |

---

*Report generated: 2026-08-12*
*Reviewer: HIG Tier 3 Agent B*
*Standards: Apple HIG (skill apple-hig, 2026-08-08 refresh) §12.4 Accessibility checklist, §2.1 Color, §4 macOS patterns*
