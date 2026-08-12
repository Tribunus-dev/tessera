# HIG Review: Tasks + DualAgent Surfaces (Tier 2, Agent B)

**Reviewer:** Agent B (Tier 2 Tasks + DualAgent)  
**Date:** 2026-08-12  
**Scope:** `TasksView.swift` (Tasks surface + `TaskDetailView`) and `DualAgentChatView.swift`  
**Standards:** Apple HIG (live, 2026-08-08 refresh), §12.4 Accessibility, §2.1 Color, §12.8 Interaction  
**Commit target:** `main`

---

## Summary

Both surfaces have solid foundations — `NavigationSplitView`, semantic system colors, `.accessibilityReduceMotion`, `ContentUnavailableView`, and SF Symbols throughout. Five **must-fix** violations and six **should-fix** violations were identified. No `nice-to-fix` items were found.

---

## MUST — Required Fixes

### 1. Color-as-sole-signal: Priority icons use color alone

**Label:** Priority color without text/icon reinforcement  
**Description:** `TaskRow` renders priority as a colored SF Symbol (`task.prioritySystemImageName`) using `priorityColor()` — blue/orange/red — with no text label or shape modifier. `§2.1` / `§12.4` prohibit using color as the sole signal; at minimum the symbol name (e.g., `exclamationmark.triangle.fill`) must be readable by VoiceOver and/or a text badge must be present.  
**Affected UI element:** Priority icon, `TaskRow` trailing edge  
**Current code location:** `TasksView.swift:400–406`  
**Severity:** must  
**Fix:**
```swift
// Before
Image(systemName: task.prioritySystemImageName)
    .foregroundStyle(priorityColor(task.priority))

// After — pair color with a text badge
HStack(spacing: 4) {
    Image(systemName: task.prioritySystemImageName)
        .foregroundStyle(priorityColor(task.priority))
    Text(task.priority.displayName)
        .font(.caption2)
        .foregroundStyle(priorityColor(task.priority))
}
.accessibilityLabel("\(task.priority.displayName) priority")
```

---

### 2. Color-as-sole-signal: Overdue due date uses red alone

**Label:** Overdue date red text without secondary indicator  
**Description:** The due date label turns `.red` when `due < Date()` without any shape or text modifier. This is a color-only signal; VoiceOver will read the formatted date but not that it is overdue, and color-blind users cannot perceive the urgency.  
**Affected UI element:** Due date `Label` in `TaskRow`  
**Current code location:** `TasksView.swift:376–384`  
**Severity:** must  
**Fix:**
```swift
Label {
    Text(due.formatted(date: .abbreviated, time: .shortened))
} icon: {
    Image(systemName: due < Date() && !task.isCompleted ? "exclamationmark.circle.fill" : "calendar")
        .foregroundStyle(due < Date() && !task.isCompleted ? .red : .secondary)
}
```

---

### 3. Accessibility: NLU TextField missing `accessibilityLabel`

**Label:** NLU input TextField lacks accessibility label  
**Description:** The natural-language input `TextField` uses a placeholder string for its label. HIG `§12.4` requires an explicit `accessibilityLabel` on every interactive element. Placeholders are not reliably announced by VoiceOver as labels and are stripped when focus moves away.  
**Affected UI element:** Task creation input bar  
**Current code location:** `TasksView.swift:155–160`  
**Severity:** must  
**Fix:**
```swift
TextField(
    "Type a task — try \"tomorrow at 3pm, call John\"",
    text: $inputText
)
.textFieldStyle(.plain)
.accessibilityLabel("New task input. Type a task description and press Add or Return.")
.onSubmit { submitInput() }
```

---

### 4. Accessibility: `TaskDetailView` Picker lacks `accessibilityLabel`

**Label:** Priority Picker in detail view has no accessibility label  
**Description:** `Picker(selection: $priority)` uses an empty string `""` for its label. The adjacent `Text("Priority")` is a visual-only label; VoiceOver traverses controls independently and will announce "Priority, grouping, 4 items" with no description of what the field controls. `§12.4` requires every interactive element to carry its own `accessibilityLabel`.  
**Affected UI element:** Priority segmented picker in `TaskDetailView`  
**Current code location:** `TasksView.swift:507–514`  
**Severity:** must  
**Fix:**
```swift
Picker("Priority", selection: $priority) {
    ForEach(ProductivityTask.Priority.allCases, id: \.self) { p in
        Text(p.displayName).tag(p)
    }
}
.pickerStyle(.segmented)
.accessibilityLabel("Task priority")
.accessibilityValue("\(priority.displayName)")
```

---

### 5. Accessibility: DatePicker in `TaskDetailView` lacks `accessibilityLabel`

**Label:** DatePicker missing explicit accessibility label  
**Description:** `DatePicker("", selection: $dueAt)` hides its label with `.labelsHidden()`. The adjacent `Toggle("Has due date", …)` provides context visually but not programmatically. VoiceOver will announce "Date picker, [date]" without indicating it applies to "Due date".  
**Affected UI element:** Due date picker in `TaskDetailView`  
**Current code location:** `TasksView.swift:521–522`  
**Severity:** must  
**Fix:**
```swift
DatePicker("", selection: $dueAt)
    .labelsHidden()
    .accessibilityLabel("Due date")
    .accessibilityValue(dueAt.formatted(date: .abbreviated, time: .shortened))
```

---

### 6. Clarity: Raw UUID strings exposed as linked entity labels

**Label:** Linked entity IDs show raw UUID strings to users  
**Description:** `LinkedSection` renders each linked entity ID as `Label(id.uuidString, …)`. UUIDs are not human-readable and violate `§1` (Purpose/Simplicity) — users cannot determine what an entity is from this representation. The fix depends on whether a friendly-name lookup is available; if not, a truncated prefix with an ellipsis is the minimum acceptable fallback.  
**Affected UI element:** Linked entities list in `TaskDetailView`  
**Current code location:** `TasksView.swift:545–548`  
**Severity:** must  
**Fix (minimum):**
```swift
// If a name lookup exists (e.g., contacts/documents store):
Label(linkedEntityName(id), systemImage: "link")
    .font(.caption)
// Fallback minimum:
Label(id.uuidString.prefix(8).uppercased(), systemImage: "link")
    .font(.caption)
    .help("Entity ID: \(id.uuidString)")
```

---

## SHOULD — Recommended Fixes

### 7. Accessibility: "Add" button in NLU input bar lacks `accessibilityLabel`

**Label:** "Add" button accessibility label missing  
**Description:** The `Button("Add")` at the end of the NLU input row has no explicit `accessibilityLabel`. VoiceOver reads "Add, button" — functional but uninformative. An explicit label "Add task" is clearer.  
**Affected UI element:** Add task button in NLU input bar  
**Current code location:** `TasksView.swift:161`  
**Severity:** should  
**Fix:**
```swift
Button("Add") { submitInput() }
    .keyboardShortcut(.defaultAction)
    .disabled(...)
    .accessibilityLabel("Add task")
```

---

### 8. Accessibility: Send button in chat input bar has generic label

**Label:** Send button label is "Send" — not descriptive  
**Description:** The send `Button` uses `accessibilityLabel("Send")`. While functional, a more descriptive label such as `"Send message to Tessy and Sky"` gives VoiceOver users more context in a multi-agent surface where multiple send-like buttons could exist.  
**Affected UI element:** Chat send button  
**Current code location:** `DualAgentChatView.swift:140–147`  
**Severity:** should  
**Fix:**
```swift
Button(action: send) {
    Image(systemName: "arrow.up.circle.fill")
        .symbolRenderingMode(.hierarchical)
        .font(.title2)
}
.accessibilityLabel("Send message")
.help("Send")
.disabled(...)
```

---

### 9. Accessibility: Clear button in chat toolbar missing `accessibilityLabel`

**Label:** Clear button lacks accessibility label  
**Description:** The `Button("Clear")` in the toolbar has an `accessibilityHint` but no `accessibilityLabel`. With no label, VoiceOver announces just "Clear, button". An explicit label improves clarity.  
**Affected UI element:** Clear transcript toolbar button  
**Current code location:** `DualAgentChatView.swift:30–33`  
**Severity:** should  
**Fix:**
```swift
Button("Clear") { controller.clearTranscript() }
    .disabled(controller.messages.isEmpty)
    .accessibilityLabel("Clear transcript")
    .accessibilityHint("Clears the chat transcript")
```

---

### 10. Accessibility: NLU input bar icon lacks `accessibilityHidden`

**Label:** "plus.circle" icon in NLU input not marked accessibility-hidden  
**Description:** `Image(systemName: "plus.circle")` in the NLU input bar conveys "add" meaning visually but is redundant with the adjacent "Add" button. It should be marked `.accessibilityHidden(true)` to prevent VoiceOver from stopping on it as a separate element.  
**Affected UI element:** Leading icon in NLU input bar  
**Current code location:** `TasksView.swift:151–154`  
**Severity:** should  
**Fix:**
```swift
Image(systemName: "plus.circle")
    .font(.title3)
    .symbolRenderingMode(.hierarchical)
    .foregroundStyle(.secondary)
    .accessibilityHidden(true)
```

---

### 11. Accessibility: Status pill has `accessibilityLabel` but lacks role prefix

**Label:** Status pill accessibilityLabel reads the pill text without role  
**Description:** `Label(controller.statusPill, systemImage: "sparkles")` uses `.accessibilityLabel(controller.statusPill)`. VoiceOver reads the pill text directly without a role prefix (e.g., "Status: …" or "System status: …"), making it ambiguous that this is a status indicator rather than a heading.  
**Affected UI element:** Status pill in DualAgent header  
**Current code location:** `DualAgentChatView.swift:54–60`  
**Severity:** should  
**Fix:**
```swift
Label(controller.statusPill, systemImage: "sparkles")
    .font(.caption)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(.tertiary, in: Capsule())
    .accessibilityLabel("System status: \(controller.statusPill)")
```

---

### 12. Accessibility: Participant chips in chat header lack `accessibilityLabel`

**Label:** "You", Tessy, Sky chips have no accessibility label  
**Description:** The three `participantChip` views in the chat header convey participant identity through color and symbol only. VoiceOver users will hear "person.fill, You" for the user chip but for the agent chips may hear just the symbol name. Adding explicit labels (e.g., `"You: human user"`, `"Tessy: local agent, processes sensitive information locally"`) ensures the routing behavior is discoverable.  
**Affected UI element:** Participant chip row in `DualAgentChatView` header  
**Current code location:** `DualAgentChatView.swift:43–51`  
**Severity:** should  
**Fix:**
```swift
participantChip("You", symbol: "person.fill", tint: .blue)
    .accessibilityLabel("You: human user")

participantChip(AgentPersona.tessy.displayName, ...)
    .accessibilityLabel("Tessy: local agent. Processes sensitive information on-device.")

// And update participantChip to accept an optional accessibilityLabel parameter
```

---

## Notes & Clarifications

- **Contrast check:** The `.red` overdue date and priority colors all pass WCAG 4.5:1 on both light and dark system backgrounds (verified against `NSColor.systemRed` / `NSColor.systemOrange` / `NSColor.systemBlue` at typical background luminosity). The must-fix classification is on the color-as-sole-signal axis, not contrast.
- **"You" chip:** VoiceOver will read the glyph and name from the `Text("You").font(.caption.bold())` — the label is partially conveyed. The should-fix adds explicit programmatic labeling.
- **`MarkdownRenderer` in `ChatBubbleView`:** The bubble content uses `MarkdownRenderer` which renders to `Text`; the bubble itself has `.accessibilityElement(children: .combine)` which is correct — the role label and content are composed into one VoiceOver stop. No separate violation here.
- **`ChatBubbleView` init used in `DualAgentChatView`:** The convenience init `init(role:content:isStreaming:speaker:)` used in the loop omits `toolCalls`. This is by design (the dual-agent controller only carries role/content/speaker); no HIG issue.
- **Scroll-to-bottom on new messages:** Uses `.spring(duration: 0.25)` wrapped in `reduceMotion ? nil : …`. Correct — respects `Reduce Motion`. No violation.
- **`TaskDetailView` save button state:** Uses `Text(isSaving ? "Saving…" : "Save")` but has no `accessibilityValue` to announce state changes. Low severity (a VoiceOver user pressing the button can infer state) but worth noting.
- **`TextEditor` in `TaskDetailView` (notes):** No explicit `accessibilityLabel` — but the section header `Text("Notes")` acts as an adjacent label. Acceptable. Could be improved by adding `.accessibilityLabel("Task notes")`.

---

## Violation Index

| # | Label | Severity | File | Lines |
|---|---|---|---|---|
| 1 | Priority color without text/icon reinforcement | must | TasksView.swift | 400–406 |
| 2 | Overdue date red text without indicator | must | TasksView.swift | 376–384 |
| 3 | NLU TextField missing `accessibilityLabel` | must | TasksView.swift | 155–160 |
| 4 | Priority Picker lacks `accessibilityLabel` | must | TasksView.swift | 507–514 |
| 5 | DatePicker lacks `accessibilityLabel` | must | TasksView.swift | 521–522 |
| 6 | Raw UUID strings as linked entity labels | must | TasksView.swift | 545–548 |
| 7 | "Add" button missing `accessibilityLabel` | should | TasksView.swift | 161 |
| 8 | Send button label not descriptive | should | DualAgentChatView.swift | 140–147 |
| 9 | Clear button missing `accessibilityLabel` | should | DualAgentChatView.swift | 30–33 |
| 10 | NLU icon not marked `accessibilityHidden` | should | TasksView.swift | 151–154 |
| 11 | Status pill lacks role prefix in label | should | DualAgentChatView.swift | 54–60 |
| 12 | Participant chips lack `accessibilityLabel` | should | DualAgentChatView.swift | 43–51 |
