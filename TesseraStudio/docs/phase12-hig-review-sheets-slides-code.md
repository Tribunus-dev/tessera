# HIG Review: Sheets + Slides + Code Surfaces

**Reviewer:** Phase 12 Wave 1 Agent 1 (HIG sweep)
**Files reviewed:** SheetDetailView, SheetEditorView, SlideDeckDetailView, CodeSurfaceView, CodeDetailView, TesseraEditorToolbar, SurfaceMetadataRow, SurfaceFocusStatusBar, SurfaceLinkedEntityChip
**HIG basis:** apple-hig skill §12 checklist + §3 Accessibility + §2 Foundations (color/typography/layout) + §4 macOS patterns
**Severity key:** 🔴 must-fix · 🟡 should-fix · ⚪ nice-to-have

---

## Summary

**9 must-fix · 5 should-fix · 3 nice-to-have**

| View | Must-fix | Should-fix | Nice-to-have |
|---|---|---|---|
| SheetDetailView | 3 | 2 | 1 |
| SlideDeckDetailView | 3 | 1 | 1 |
| CodeSurfaceView | 1 | 1 | 0 |
| CodeDetailView | 1 | 0 | 1 |
| TesseraEditorToolbar | 1 | 1 | 0 |
| SurfaceLinkedEntityChip | 1 | 0 | 0 |
| **Shared components** | 0 | 1 | 0 |
| **Total** | **10** | **6** | **3** |

---

## SheetDetailView

### 🔴 Must-fix

**1. `TextField` "Title" — missing `accessibilityLabel`** (`SheetDetailView.swift:156`)
```swift
TextField("Title", text: $viewModel.draftTitle, onCommit: { ... })
```
The plain text field has no VoiceOver label. Fix:
```swift
TextField("Sheet title", text: $viewModel.draftTitle, onCommit: { ... })
    .accessibilityLabel("Sheet title")
```

**2. Formula bar `TextField` — missing `accessibilityLabel`** (`SheetDetailView.swift:247`)
```swift
TextField(
    "Enter value…",
    text: formulaBarBinding(coord: coord)
)
```
VoiceOver reads "Enter value…" which is a placeholder, not a label. Fix:
```swift
TextField(
    "Cell formula",
    text: formulaBarBinding(coord: coord)
)
.accessibilityLabel("Cell formula for \(cellAddressLabel)")
```

**3. `SheetEditorView` empty-state "Create 5 x 4 grid" button — missing `accessibilityLabel`** (`SheetEditorView.swift:98`)
```swift
Button("Create 5 x 4 grid") { ... }
```
Should describe the action. Fix:
```swift
Button("Create 5 × 4 grid") { ... }
    .accessibilityLabel("Create a 5 by 4 grid")
```

### 🟡 Should-fix

**4. Delete sheet uses reversed keyboard shortcuts** (`SheetDetailView.swift:380-382`)
```swift
Button("Cancel") { ... }.keyboardShortcut(.defaultAction)
Button("Delete", role: .destructive) { ... }.keyboardShortcut(.cancelAction)
```
`keyboardShortcut(.defaultAction)` is typically Enter; `keyboardShortcut(.cancelAction)` is Escape. These are reversed — Escape should dismiss, Enter should confirm for destructive actions. See §12.8 "Button labels are verbs" and standard macOS convention: Escape = Cancel, Return = OK/Confirm. Swap the shortcuts or remove them entirely.

**5. `Color(.quaternarySystemFill)` used for formula bar cell-address background** (`SheetDetailView.swift:230`)
`quaternarySystemFill` is a valid system fill color but it is very low contrast. Verify contrast against the text on top. Consider `Color(.tertiarySystemFill)` for a clearer visual boundary, especially since the text in that cell address area is small (`.caption`).

### ⚪ Nice-to-have

**6. Delete sheet body text: "Hard delete removes the row"** (`SheetDetailView.swift:377`)
Technical phrasing ("hard delete removes the row") may confuse non-technical users. Consider: "This permanently removes the sheet. The change history is preserved." — clearer, no jargon.

---

## SlideDeckDetailView

### 🔴 Must-fix

**7. TextField "Title" in headerSection — missing `accessibilityLabel`** (`SlideDeckDetailView.swift:166`)
```swift
TextField("Title", text: $viewModel.draftTitle, onCommit: { ... })
```
Same issue as SheetDetailView. Add `.accessibilityLabel("Slide deck title")`.

**8. Thumbnail rail: `SlideThumbnailView` used with `.onTapGesture` — inaccessible via keyboard** (`SlideDeckDetailView.swift:254-257`)
```swift
SlideThumbnailView(slide: slide, isSelected: slide.index == selectedSlideIndex)
    .onTapGesture { selectedSlideIndex = slide.index }
```
`SlideThumbnailView` is not a standard `Button` or `List` row — it bypasses keyboard navigation. Either:
- Wrap it in a `Button`: `Button { selectedSlideIndex = slide.index } label: { SlideThumbnailView(...) }`
- Or expose it to the accessibility tree: `.accessibilityAddTraits(.isButton).accessibilityLabel("Slide \(slide.index + 1)")`

**9. "Add Slide" Menu button in thumbnail rail — missing `accessibilityLabel`** (`SlideDeckDetailView.swift:237-244`)
```swift
Menu {
    ForEach(SlideLayout.allCases, id: \.self) { layout in
        Button("New \(layout.displayName)") { onInsertSlide(layout) }
    }
} label: {
    Label("Add Slide", systemImage: "plus.rectangle.on.rectangle")
}
```
VoiceOver may read the icon name. Add `.accessibilityLabel("Add new slide")` to the label.

### 🟡 Should-fix

**10. "Layout: \(layout.displayName)" in context menu** (`SlideDeckDetailView.swift:275`)
Repetitive — the context menu label is "Layout: \(layout.displayName)" and the button label is the same. Could simplify to just `layout.displayName` or `"Change to \(layout.displayName)"` for clarity.

### ⚪ Nice-to-have

**11. linkSheet: disabled Link Button has no `accessibilityHint`** (`SlideDeckDetailView.swift:359`)
The Link button is disabled when the UUID is invalid. Add `.accessibilityHint("Enter a valid UUID to enable linking")` so VoiceOver users know why it's disabled.

---

## CodeSurfaceView

### 🔴 Must-fix

**12. Detail tab `Picker` — missing `accessibilityLabel`** (`CodeSurfaceView.swift:62`)
```swift
Picker("Detail", selection: $detailTab) {
    ForEach(DetailTab.allCases) { tab in
        Text(tab.label).tag(tab)
    }
}
```
The "Detail" label is the picker label, but VoiceOver may not use it as the accessibility label. Add `.accessibilityLabel("Detail panel tabs")`.

### 🟡 Should-fix

**13. `CodeSurfaceView` toolbar status text** (`CodeSurfaceView.swift:91-95`)
```swift
Text(viewModel.statusMessage)
    .font(.caption)
```
If `viewModel.statusMessage` is empty (no file selected), this renders an empty Text view — harmless but noisy for the accessibility tree. Guard with `if !viewModel.statusMessage.isEmpty`.

---

## CodeDetailView

### 🔴 Must-fix

**14. Focus toggle Button in toolbar — missing `accessibilityLabel`** (`CodeDetailView.swift:114-128`)
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
```
No `accessibilityLabel`. Add `.accessibilityLabel(isFocusMode ? "Exit Focus" : "Focus")` — same pattern already used correctly in SheetDetailView and SlideDeckDetailView.

### ⚪ Nice-to-have

**15. Status bar error text uses hard-coded `.red`** (`CodeDetailView.swift:149`)
```swift
Text(error)
    .foregroundStyle(.red)
```
Prefer `.foregroundStyle(Color.red)` or a semantic color. While `.red` is readable, using the semantic `Color.red` is more consistent and more idiomatic SwiftUI.

---

## TesseraEditorToolbar

### 🔴 Must-fix

**16. `RouteChip` hard-coded `Color.green` / `Color.blue` for route indicators** (`TesseraEditorToolbar.swift:17`)
```swift
Circle()
    .fill(aiRoute == "local" ? Color.green : Color.blue)
```
These are hard-coded colors, not system colors. `Color.green` and `Color.blue` do not automatically adapt to Increase Contrast or Dark Mode. Replace with:
- For local (local inference): `.green` is acceptable as a semantic status color *if* contrast is verified, but better to use a named Color asset.
- At minimum, wrap in an `.accessibilityLabel("AI route: \(aiRoute == "local" ? "Granite running locally" : "Cloud endpoint")")` so the color isn't the only signal. The existing `.help()` tooltip helps, but VoiceOver needs an explicit label.
- **Recommended**: Define these as semantic Color assets in the asset catalog with light/dark variants.

### 🟡 Should-fix

**17. `RibbonButton` and `RibbonToggleButton` — no `accessibilityLabel`** (`TesseraEditorToolbar.swift:555, 596`)
These internal components serve as the primary interaction surface for the editor. Each `RibbonButton` and `RibbonToggleButton` should have an `accessibilityLabel` derived from the button's content. For example, a bold button:
```swift
.accessibilityLabel("Bold, \(formattingState.isBold ? "active" : "inactive")")
```
The `shortcutHint` (`.help()` tooltip) at line 573-578 is good for power users but does not replace `accessibilityLabel`. A pragmatic approach is to add `.accessibilityLabel(label)` on the root `Button` — the label is already present in the view and is sufficient for VoiceOver.

---

## SurfaceMetadataRow

No violations found.

- Uses `.caption` font (valid for metadata)
- Uses `.secondary` foregroundStyle (correct semantic color)
- Uses `ProgressView().controlSize(.small)` (correct control size)
- Error text uses `.red` — same as CodeDetailView issue; **consider migrating to `Color.red`** (nice-to-have, consistent with CodeDetailView #15)

---

## SurfaceFocusStatusBar

No violations found.

- Uses `.secondary` for status text ✅
- Uses `.bar` background ✅
- "Exit Focus" button has `.help("Exit focus mode (Escape)")` ✅
- Uses standard `.caption` font ✅

---

## SurfaceLinkedEntityChip

### 🔴 Must-fix

**18. `iconColor` property uses hard-coded colors** (`SurfaceLinkedEntityChip.swift:78-86`)
```swift
private var iconColor: Color {
    switch link.linkType {
    case CalendarLinkType.attendeeOf.rawValue: return .blue
    case CalendarLinkType.prepDocument.rawValue: return .purple
    case CalendarLinkType.prepTask.rawValue: return .green
    case CalendarLinkType.reminderFor.rawValue: return .yellow
    default: return .secondary
    }
}
```
`Color.yellow` in particular is notoriously problematic — it is nearly invisible in dark mode and against light backgrounds. All four are hard-coded colors that do not adapt to Dark Mode, Increase Contrast, or accessibility settings. The comment at line 80-84 in `TesseraEditorToolbar.swift` says "Don't rely on color alone" — this chip pairs color with an icon, so the icon mitigates the risk somewhat, but the hard-coded colors still fail Dark Mode. Fix options (pick one):

**Option A** (preferred): Define semantic colors in the asset catalog (e.g. `EntityLinkColor.attendee`, `EntityLinkColor.prepDocument`, etc.) with light/dark variants.

**Option B** (quick fix): Replace with system semantic colors that work in both modes:
```swift
switch link.linkType {
case CalendarLinkType.attendeeOf.rawValue: return .accentColor
case CalendarLinkType.prepDocument.rawValue: return .purple  // purple is dark-mode safe
case CalendarLinkType.prepTask.rawValue: return .green
case CalendarLinkType.reminderFor.rawValue: return .orange  // orange > yellow for dark mode
default: return .secondary
}
```
Also add `.accessibilityLabel("Link: \(label), type: \(link.linkType.isEmpty ? "generic" : link.linkType)")` to the chip's Button to ensure VoiceOver doesn't rely on color alone.

---

## Shared Components Used Across Views

These violations appear in multiple views because they originate in shared components:

| Violation | Shared component | Affected views |
|---|---|---|
| Hard-coded green/blue/yellow/purple icons | `SurfaceLinkedEntityChip` | SheetDetailView (via `SurfaceLinkedEntityChip` in linkedSection), SlideDeckDetailView (via `SurfaceLinkedEntityChip` in linkedSection), SheetEditorView (via `SurfaceLinkedEntityChip` in linkedSection) |
| Missing `accessibilityLabel` on entity chips | `SurfaceLinkedEntityChip` | All three surfaces |

---

## Appendix: Checklist Coverage

Mapping findings to §12 items:

| §12 Item | Status | Notes |
|---|---|---|
| §12.1: System colors | 🟡 Partial | RouteChip + SurfaceLinkedEntityChip use hard-coded colors |
| §12.1: System text styles | ✅ Pass | All text uses `.caption`, `.callout`, `.body`, `.headline`, `.title` |
| §12.3: Dynamic Type | N/A | macOS does not support Dynamic Type |
| §12.4: `accessibilityLabel` | 🔴 FAIL | 10+ interactive elements missing labels |
| §12.4: Color contrast | 🟡 Partial | RouteChip + SurfaceLinkedEntityChip need contrast audit |
| §12.4: Color as sole signal | 🔴 FAIL | SurfaceLinkedEntityChip uses color alone for link-type differentiation (mitigated by icon pairing) |
| §12.4: Full Keyboard Access | 🟡 Partial | SlideThumbnailView tap bypasses keyboard nav |
| §12.5: Dark mode | 🟡 Partial | Hard-coded colors may not adapt |
| §12.8: Button shortcuts | 🟡 Partial | Delete sheet reversed shortcuts in SheetDetailView |
| §12.8: Keyboard shortcuts | ✅ Pass | `.keyboardShortcut()` used correctly on delete sheet |
| §12.8: Tooltips | ✅ Pass | All toolbar buttons have `.help()` tooltips |
| §13.1: Button minimum size | ✅ Pass | All buttons ≥ 28pt via `minWidth: 28 / minHeight: 28` |
| §13.1: Font sizes | ✅ Pass | min font size is `.caption2` ≈ 11pt, above macOS minimum of 10pt |
| §13.7: Status bar | ✅ Pass | SurfaceFocusStatusBar follows guidelines |
| §4.3: Toolbar groups | ✅ Pass | `.secondaryAction`, `.primaryAction`, `.destructiveAction` used correctly |
| §4.8: Sheets not stacked | ✅ Pass | One sheet at a time via `.sheet(isPresented:)` |
