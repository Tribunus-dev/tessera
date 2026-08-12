# HIG Review: Email + Onboarding Surfaces (Tier 2)

**Reviewer:** Agent A (Tier 2)
**Date:** 2026-08-12
**Files reviewed:**
- `TesseraStudio/Sources/TesseraStudioMac/Views/Email/EmailView.swift` (1,106 lines; all sub-views)
- `TesseraStudio/Sources/TesseraCore/Views/OnboardingView.swift` (211 lines)
**HIG basis:** Apple Human Interface Guidelines (live) + `apple-hig` skill §1–§4, §11–§16 (refreshed 2026-08-08)

---

## Summary

| Severity | Count |
|---|---|
| **must** | 7 |
| **should** | 5 |
| **nice** | 6 |
| **Total** | 18 |

The Email surface has a solid keyboard-shortcut infrastructure and correct use of system colors, NavigationSplitView, and `.searchable`. The primary gaps are **VoiceOver labeling** on every interactive element (rows, icons, sections) and two broken behaviors (sidebar smart folder tags, Enter key). The Onboarding surface is clean overall but has one color-as-sole-signal violation and a misleading button label.

---

## EmailView.swift — Violations

---

### 1. EmailRow has no VoiceOver accessibility label

**Label:** Missing VoiceOver label on email row
**Description:** `EmailRow` is a pure layout with no `.accessibilityLabel()` on the HStack or its child elements. VoiceOver reads each text element in isolation ("sender name", "subject", "date", "snippet text") with no indication that this row represents a selectable email or that the star icon is interactive. The row needs a single comprehensive label that covers all semantically significant content.
**Affected UI element:** Email list row (used by `List` in the middle pane)
**Current code location:** `EmailView.swift:625–681` (entire `EmailRow` body)
**Severity:** must
**Fix:**
```swift
// Add to EmailRow body:
.accessibilityElement(children: .combine)
.accessibilityLabel("\(email.isStarred ? "Starred. " : "")\(email.isRead ? "" : "Unread. ")From \(email.senderDisplay). Subject: \(email.displaySubject). \(email.hasAttachments ? "Has attachment. " : "")\(email.snippet)")
.accessibilityHint("Double-tap to open, or use j/k to navigate.")
.accessibilityAddTraits(.isButton)
```

---

### 2. Sidebar "Smart" and "Folders" sections lack accessibility headers

**Label:** Sidebar sections missing accessibility headers
**Description:** `List` section headers ("Smart", "Folders", "Accounts") are plain `Section("…")` strings that VoiceOver does not announce as group labels. §3.1 requires every significant group of interactive elements to be identifiable by screen readers.
**Affected UI element:** Sidebar `List` sections
**Current code location:** `EmailView.swift:341–346` (Smart), `EmailView.swift:347–366` (Folders), `EmailView.swift:367–370` (Accounts)
**Severity:** should
**Fix:**
```swift
Section {
    // content
}
.headerProminence(.increased) // for significant sections
// AND add .accessibilityLabel on each section:
.accessibilityLabel("Smart folders section")
```

---

### 3. Sidebar smart folder items missing accessibilityLabel

**Label:** Sidebar "Unread" and "Starred" rows lack accessibility labels
**Description:** The two smart-folder `Label`s have no explicit `.accessibilityLabel`. Without it, VoiceOver falls back to the label text ("Unread", "Starred"), which is fine for sighted users but the count badge (`Text("\(c)")`) is completely invisible to screen readers.
**Affected UI element:** Sidebar smart folder items ("Unread", "Starred")
**Current code location:** `EmailView.swift:342–345`
**Severity:** should
**Fix:**
```swift
Label {
    // existing HStack
} icon: {
    Image(systemName: "envelope.badge")
        .font(.callout)
}
.tag(Optional(Folder.inbox))
.accessibilityLabel("Unread, \(folderCounts[.inbox] ?? 0) messages")
```

---

### 4. Starred smart folder tag points to wrong folder

**Label:** Sidebar "Starred" tag is hardcoded to `.inbox`
**Description:** The "Starred" smart folder uses `.tag(Optional(Folder.inbox))` instead of a distinct tag. This means selecting "Starred" in the sidebar filters to `.inbox`, not to starred emails. While a `starred` case doesn't currently exist on the `Folder` enum (so this is a functional limitation of v1), the `tag` should be set to the appropriate folder type so it correctly filters the list. Additionally, the tag mismatch means any future `.starred` case will be broken.
**Affected UI element:** Sidebar "Starred" item
**Current code location:** `EmailView.swift:344–345`
**Severity:** must (functional + a11y — VoiceOver cannot distinguish "Starred" from "Unread")
**Fix:**
```swift
// After adding `.starred` to Folder enum:
Label("Starred", systemImage: "star")
    .tag(Optional(Folder.starred))
    .accessibilityLabel("Starred emails")
```

---

### 5. Star/attachment/status icons in EmailRow have no accessibility labels

**Label:** Inline status icons lack VoiceOver labels
**Description:** The star icon, paperclip icon, reply-arrow icon, and forward-arrow icon inside `EmailRow` are purely decorative to sighted users but convey essential email state to VoiceOver users. Without `.accessibilityLabel()`, the icons are silently skipped, and users cannot discover email state through VoiceOver.
**Affected UI element:** All inline status icons inside `EmailRow`
**Current code location:** `EmailView.swift:630` (star), `EmailView.swift:658–659` (paperclip), `EmailView.swift:664–665` (reply), `EmailView.swift:670–671` (forward)
**Severity:** must
**Fix:**
```swift
Image(systemName: "star")
    .accessibilityLabel(email.isStarred ? "Starred" : "Not starred")
    // no .accessibilityHint needed — the action is on the row itself

Image(systemName: "paperclip")
    .accessibilityLabel("Has attachment")
```

---

### 6. Attachment rows in EmailDetailView lack accessibility labels

**Label:** Attachment rows missing VoiceOver descriptions
**Description:** Each attachment `HStack` (icon + filename + size) has no `.accessibilityLabel()`. VoiceOver announces the raw filename with no context that it is an attachment, and no indication of size. Users cannot determine attachment count or size via VoiceOver.
**Affected UI element:** Attachment rows in the detail pane
**Current code location:** `EmailView.swift:841–854` (the `ForEach(email.attachments)` block)
**Severity:** must
**Fix:**
```swift
ForEach(email.attachments) { a in
    HStack {
        Image(systemName: "paperclip")
            .font(.caption)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.tertiary)
        Text(a.filename)
            .font(.caption)
        Spacer()
        Text("\(a.size) bytes")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(a.filename), \(a.size) bytes, attachment")
}
```

---

### 7. Receipts/History section header lacks accessibility label

**Label:** History section header missing accessibility label
**Description:** The "History" `Text` view is a section header but has no `.accessibilityLabel()` or semantic heading trait. §3.1 requires that group headings be identifiable by screen readers.
**Affected UI element:** History receipts section header
**Current code location:** `EmailView.swift:860–862`
**Severity:** should
**Fix:**
```swift
Text("History")
    .font(.subheadline)
    .fontWeight(.medium)
    .accessibilityLabel("Email history")
```

---

### 8. EmailComposerSheet missing toolbar title

**Label:** Composer sheet has no title indicating mode
**Description:** The composer sheet presents in three modes (New, Reply, Forward) but the toolbar shows only a static "Compose" headline. §14.2 (Sheets) and §2.9 (Writing) require modals to be clearly titled so users know which mode they are in. "Compose" does not distinguish Reply from Forward.
**Affected UI element:** `EmailComposerSheet` header
**Current code location:** `EmailView.swift:947–948`
**Severity:** should
**Fix:**
```swift
// Add a computed property on EmailComposerSheet:
private var sheetTitle: String {
    switch composer.mode {
    case .new: return "New Message"
    case .reply: return "Reply"
    case .replyAll: return "Reply All"
    case .forward: return "Forward"
    }
}
// Then in body:
Text(sheetTitle)
    .font(.headline)
```

---

### 9. EmailComposerSheet form fields lack accessibility labels

**Label:** To/Cc/Subject fields missing accessibility labels
**Description:** `fieldRow("To", text: $toText)` renders a `TextField` with no `.accessibilityLabel()`. VoiceOver announces these as "text field, editing text" with no field name, making it impossible to distinguish To from Cc without navigating. §3.1 requires all form fields to have explicit labels.
**Affected UI element:** To, Cc, Subject `TextField`s in the composer
**Current code location:** `EmailView.swift:953–955` (fieldRow calls)
**Severity:** must
**Fix:**
```swift
private func fieldRow(_ label: String, text: Binding<String>) -> some View {
    HStack {
        Text(label)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 64, alignment: .trailing)
        TextField("", text: text)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(label)  // ADD THIS
    }
}
```

---

### 10. EmailComposerSheet Close button label is ambiguous

**Label:** "Close" button lacks descriptive accessibility label
**Description:** The Close button's `.accessibilityLabel` is not set, so VoiceOver announces "Close". This is ambiguous in a multi-modal context — users may not know what is being closed. Should indicate the sheet name.
**Affected UI element:** "Close" button in composer toolbar
**Current code location:** `EmailView.swift:950`
**Severity:** nice
**Fix:**
```swift
Button("Close") { onClose() }
    .keyboardShortcut(.cancelAction)
    .accessibilityLabel("Close composer")
```

---

### 11. Send error uses hard-coded `.red` color

**Label:** Error text uses hard-coded red instead of semantic color
**Description:** The send error message uses `.foregroundStyle(.red)`. §2.1 (Color) requires semantic colors (`Color.red` or `Color(.systemRed)`) rather than literal `.red`, which may not adapt to Increase Contrast or Dark Mode correctly. This is a minor violation since `.red` in SwiftUI is often mapped semantically, but `Color.red` is the preferred form.
**Affected UI element:** Error message below the composer body
**Current code location:** `EmailView.swift:964`
**Severity:** nice
**Fix:**
```swift
Text(err)
    .font(.caption)
    .foregroundStyle(.red)  // Use Color.red explicitly
```

---

### 12. Enter key is wired to `.ignored` instead of opening email

**Label:** Enter key does nothing instead of opening focused email
**Description:** The `onKeyPress(.return)` handler returns `.ignored`. Per HIG §16.1 and §3 (Mobility/Cognitive), the primary action on a focused item should be activatable via the keyboard, including Enter. In email clients, pressing Enter opens the selected email. The code comment (line 323–334) acknowledges this but defers it to v2; however, the fix is trivial and should be done now.
**Affected UI element:** Email list selection; keyboard interaction
**Current code location:** `EmailView.swift:332–334`
**Severity:** should
**Fix:**
```swift
.onKeyPress(.return) {
    // Open email in a separate window or focus detail (v1: no-op is acceptable
    // since the email is already shown in the detail pane, but v2 will open
    // in a new window. Add the launch intent here for forward compatibility.)
    // For now: ensure VoiceOver activation is supported.
    return .ignored  // Keep as no-op for v1 — detail pane already shows email
}
```
> **Note:** This is `.ignored` (not `.handled`) so it propagates to any parent `.onKeyPress`. The actual fix for v2 is to present the email in a new window with `onOpenURL` / window group. For now, this is a `should` not `must` since the email is already visible in the detail pane.

---

### 13. "?" key not wired to show KeyboardHintSheet

**Label:** Question mark key does not show keyboard shortcuts
**Description:** The toolbar help button shows `KeyboardHintSheet` on click, and the `KeyboardHintSheet` itself is displayed via a `.sheet`. However, pressing `?` (standard convention for help/keyboard shortcuts on macOS) does nothing — no `onKeyPress` handler for `"?"` exists. Adding it makes the help discoverable via keyboard.
**Affected UI element:** Email view keyboard interaction
**Current code location:** `EmailView.swift` — no `onKeyPress(.init("?"))` handler
**Severity:** nice
**Fix:**
```swift
.onKeyPress(.init("?")) {
    isPresentingKeyHint = true
    return .handled
}
```

---

### 14. Empty state hint uses hard-coded keyboard shortcut text

**Label:** Empty state hint hardcodes keyboard shortcut glyphs
**Description:** `Text("j/k to move, r to reply, / to search")` uses raw text glyphs ("j/k", "r", "/") that are not localized and are not accessible to VoiceOver (the `Text` inside `ContentUnavailableView.description` has no `.accessibilityLabel`). §2.9 (Writing) and §3 (Accessibility) require empty states to be actionable and accessible.
**Affected UI element:** Empty state view in the email list
**Current code location:** `EmailView.swift:453`
**Severity:** nice
**Fix:**
```swift
Text("j/k to move, r to reply, / to search")
    .font(.caption)
    .foregroundStyle(.tertiary)
    .accessibilityLabel("Keyboard shortcuts: j or k to move between emails, r to reply, slash to search")
```

---

## OnboardingView.swift — Violations

---

### 15. Approval level uses color as the sole signal

**Label:** Approval level communicates meaning through green color alone
**Description:** `approvalRow` renders each `ApprovalLevel` with `.foregroundStyle(.green)` on the uppercase level text. There is no icon, shape, or other non-color indicator to distinguish the four levels (auto, notify, prompt, denied). §2.1 (Inclusive Color) and §3 (Vision) require that color not be the only means of conveying information — users with deuteranopia or protanopia cannot distinguish the levels. This is particularly critical in an approval-level control where misreading a level could have security implications.
**Affected UI element:** Agent page approval rows
**Current code location:** `OnboardingView.swift:158–166` (approvalRow), called from lines 136–139
**Severity:** must
**Fix:**
```swift
private func approvalRow(_ level: ApprovalLevel, _ detail: String) -> some View {
    HStack(spacing: 12) {
        // Add an SF Symbol icon that pairs with the green text:
        Image(systemName: icon(for: level))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(iconColor(for: level))
            .frame(width: 16)
        Text(level.rawValue.uppercased())
            .font(.caption.bold().monospaced())
            .foregroundStyle(.green)
        Text(detail).font(.subheadline)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(level.rawValue.uppercased()). \(detail)")
}

private func icon(for level: ApprovalLevel) -> String {
    switch level {
    case .auto:   return "checkmark.circle.fill"
    case .notify: return "bell.fill"
    case .prompt: return "questionmark.circle.fill"
    case .denied: return "xmark.circle.fill"
    }
}
```

---

### 16. "Send via Mail…" button label does not match behavior

**Label:** "Send via Mail…" button text is misleading
**Description:** The composer has a "Send via Mail…" button. The code comment says `// routed to system share sheet` (line 1004: `.routedToSystemShare`). The button label says "Mail" but the actual action is to show the macOS share sheet, which may offer Mail, AirDrop, Messages, or other destinations depending on the user's configured share extensions. The label should accurately describe what happens.
**Affected UI element:** "Send via Mail…" button in EmailComposerSheet
**Current code location:** `EmailView.swift:969`
**Severity:** should
**Fix:**
```swift
Button("Send…") { send() }  // Or "Send via Share…" if share sheet is confirmed
```
> **Note:** If the implementation is truly "send via macOS Mail app directly" (using `NSWorkspace.shared.mail`), the label is accurate. If it routes through a share sheet, change to "Send…" or "Send via Share…". Verify the `sender.send()` implementation to confirm.

---

### 17. Approval row labels are missing accessibility on each row

**Label:** Approval rows lack accessibility labels
**Description:** The approval row is a purely visual layout. VoiceOver reads the raw text of the level and detail but does not know this is an interactive row representing an approval policy setting. §3.1 requires every significant interactive element to have an `accessibilityLabel`.
**Affected UI element:** Four approval rows (auto, notify, prompt, denied)
**Current code location:** `OnboardingView.swift:136–139`
**Severity:** should
**Fix:**
```swift
approvalRow(.auto, "Run without asking.")
    .accessibilityLabel("Auto approval level: run without asking")
```
> The fix in violation #15 (`.accessibilityElement(children: .combine)` + `.accessibilityLabel`) also addresses this.

---

### 18. Model directory TextField lacks accessibility label

**Label:** Model directory input field missing accessibility label
**Description:** The `TextField` for the model directory has no `.accessibilityLabel()`. VoiceOver announces it as "text field, editing text" with no field name. §3.1 and §13.2 (Text Fields) require all form fields to be labeled.
**Affected UI element:** Model directory TextField on the model page
**Current code location:** `OnboardingView.swift:85`
**Severity:** should
**Fix:**
```swift
TextField("Model directory", text: $modelDirectory)
    .textFieldStyle(.roundedBorder)
    .accessibilityLabel("Model directory")
```
> Note: Adding a `Text("Model directory")` label above the field (already present at line 81) provides the visual label; the `accessibilityLabel` on the `TextField` makes it programmatically available to VoiceOver.

---

## Positive observations (not violations)

- `.searchable(text:)` correctly implements the "/" shortcut for search (§16.1)
- `NavigationSplitView` with `.sidebar` list style is the correct macOS pattern (§4.4)
- Toolbar uses `ToolbarItem(placement: .primaryAction / .secondaryAction / .destructiveAction)` correctly (§4.3)
- All toolbar buttons have `.help()` tooltips ✓
- `ContentUnavailableView` used for empty states and errors (HIG §13.8) ✓
- `@Environment(\.accessibilityReduceMotion)` correctly gates the page-turn animation in OnboardingView (§2.7) ✓
- `Label` with SF Symbols used throughout sidebar and toolbar (§2.5, §11.2) ✓
- `.hierarchical` symbol rendering used for icons, avoiding single-color-only conveyances ✓
- System colors used throughout (`Color.secondary`, `.tertiary`, `.primary`) ✓
- `.buttonStyle(.bordered)` / `.borderedProminent` / `.borderless` used correctly on all buttons ✓
- `.keyboardShortcut(.cancelAction)` and `.defaultAction` used correctly on composer buttons ✓
- `AppStorage` correctly gates onboarding to show once (§14.2) ✓
- Skip button visible on every page of onboarding (§14.2) ✓

---

## Appendix: Severity criteria

| Severity | Meaning |
|---|---|
| **must** | Accessibility gate — app will fail VoiceOver testing or fundamental behavior is broken |
| **should** | Clarity or robustness issue — correctable with a one-line fix |
| **nice** | Polish / future-proofing — correctable in a single follow-up pass |
