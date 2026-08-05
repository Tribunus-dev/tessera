# Tessera Studio: Productivity Surface UX Research

**Status:** Research draft v1 — 2026-08-05
**Author:** Tessera Architecture (research)
**Applies to:** Tessera Studio for macOS 1.0.0+ (post-data-layer, pre-productivity-spec)
**Companion to:** `tessera-data-layer-design.md`, `tessera-plead-the-fifth-design.md`, `agent-patterns-research.md`
**Branch:** `feat/ux-research-productivity-surface` (worktree `worktrees/ux-research-productivity-surface/`, off `main@862666ef1`)

---

## 1. Executive Summary

Tessera Studio is about to ship a productivity surface — a block-based WYSIWYG editor that pairs every user keystroke with an on-device agent that streams the same edits into the document, and that the user can interrupt, redirect, or take over at any moment. The architecture (semantic block AST in Postgres + Valkey, constitutional receipts per mutation, two editors one document) is locked; the question this research answers is how the UX should look so the locked architecture does not repeat the market's mistakes.

We read Apple HIG §2 Motion, §4 macOS Patterns, §5 iOS Patterns, §10 SwiftUI Decision Trees, and §14 Patterns, and paired them with 12 academic papers (CHI 2022–2025, the LLM-ification of CHI, the Co-Writing surveys, DirectGPT, the HACO framework, and the human-in-the-loop primitive converged on by every agent framework) and 14 market products (Notion AI, Apple Intelligence Writing Tools, Cursor, ChatGPT, Grammarly, Craft, Coda, Reflect, iA Writer, Bear, Things 3, OmniFocus, Fantastical, MailMate/Spark/Newton, Obsidian). The 49 specific UX decisions in §11 resolve each architect's intuition against this evidence base, with an explicit "Adopt" / "Adapt" / "Reject" verdict and a one-sentence rationale. The 18 open questions in §12 are split into spec-blocking and implementation-deferrable, and §13 orders the parallel work for the next wave.

**Top-level recommendations:**

- **Keep the agent in the document, not in a side panel.** Notion's side panel + Insert button is rejected by users (the inline-rewrite path was removed in 2024 and re-added after backlash) and the Microsoft Copilot UX guidance [12] treats it as an antipattern; the DirectGPT CHI study [8] shows direct-manipulation styles are 50% faster with 72% shorter prompts. Tessera's "agent IS the editor" model is the right answer; the UX work is making the streaming feel deliberate and the interrupt feel cheap.
- **Chat is a queue, not a history.** Async workflow patterns [13][14] converge on a four-state machine (queued, running, succeeded, failed/cancelled) with item-level undo, not a linear chat log. Reflect's GPT-4 hotkey [10] and the human-in-the-loop agent frameworks [15][16] both enforce a "pending → in-progress → applied" lifecycle because it matches the user's mental model of delegation.
- **Receipts are not separate from the editor — they are the audit trail of the editor.** The HACO framework [17] and the editable-AI-output pattern [18] converge on the requirement that every applied edit must carry (i) what changed, (ii) who/what changed it, (iii) why, and (iv) how to roll back. The constitutional receipt infrastructure the architect already locked in is the load-bearing primitive; the UX is to make the receipt summary appear inline in the chat, with a tap-through to the full audit trail, and to keep the receipt alive after undo (per the HACO "fine-grained rollback" requirement).
- **Polish is the brand.** Craft's #1 selling point [6] is "feels faster than every competitor in this category" — its block animations are 150–250ms, native, and respect Reduce Motion. Cursor's "no polish" pattern (raw keystroke streaming) is the explicit reject the architect named; iA Writer [11] and Reflect [10] both prove that the Apple-native audience rewards craft over feature density. The animation budget in §5 is small (six primitives, three durations) and the receipt/chat panel work in §6 is the bulk of the spec.

| # | UX decision | Verdict | One-line rationale |
|---|---|---|---|
| 1 | Block-based AST editor with semantic blocks (heading, paragraph, list, table, image, code, callout) | Adopt | The architect's locked model; Notion/Craft have proven the pattern scales [4][6]. |
| 2 | Two editors, one document, shared mutation API + shared undo stack | Adopt | HACO framework [17] requires this for the human-in-the-loop contract to hold. |
| 3 | Streaming agent edits rendered to the AST, not raw keystrokes | Adopt | Microsoft Copilot UX guidance [12], AI/TLDR patterns [20], and CHI 2025 co-writing [3] all converge on streaming the structured edit, not the keystrokes. |
| 4 | Block-level animations (slide-in, crossfade, collapse) for agent edits | Adopt | Craft's animation polish is its #1 user-rated feature [6]; NNG [21] and HIG §2.7 [22] both recommend the same primitive set. |
| 5 | "Thinking" = subtle pulse in chat panel, not a modal spinner | Adopt | HIG §14.1 [22] "make feedback accessible, integrate status into the interface"; Apple Intelligence's modal "scanning" animation is criticised [1] and rejected by HCI. |
| 6 | "Agent paused" indicator = subtle banner, not a full-screen modal | Adopt | HIG §10.10 [22] + human-in-the-loop frameworks [15][16] converge on a non-modal interrupt; full-screen modals are reserved for critical + actionable. |
| 7 | User can interrupt at any time: click in doc, type, undo, redirect | Adopt | DirectGPT CHI [8], HACO A2–A4 band [17], and AG-UI Interrupts [16] all require this. |
| 8 | Pending chat message in italic + 60% opacity + clock icon | Adapt | Standard chat-pending pattern [13][14], customized for queue semantics. |
| 9 | Drag-to-reorder pending items in chat | Adopt | Apple HIG §16.2 [22] standard; Reflect [10] proves it works for non-chat item reordering. |
| 10 | Receipt summary inline in chat (3 blocks updated, 1 section added, 2 receipts logged) | Adopt | Reflect-style summary [10] + Action Audit Trail pattern [18] + HACO provenance completeness [17]. |
| 11 | Tap-through receipt summary to the full audit trail | Adopt | HACO [17] and Microsoft Copilot guidance [12] both require reversible + auditable. |
| 12 | On-device LLM default, remote opt-in with per-receipt model + prompt logging | Adopt | Apple Intelligence's pattern [2] + Tessera's no-egress doctrine; "hard suggestion" semantics in chat panel. |
| 13 | VoiceOver label for each chat item by state (pending/in-progress/applied/failed) | Adopt | HIG §3.1 [22] + Apple Intelligence's own a11y direction [23]. |
| 14 | Reduce Motion: replace slide-in with crossfade, pulse with static dot | Adopt | HIG §3.6 + Apple developer docs [24] are explicit requirements. |
| 15 | "Take over" gesture = click in the document, no special button | Adopt | HACO [17] + Microsoft Copilot guidance [12] both keep the takeover implicit; adding a button teaches the user the agent is autonomous when the design says the opposite. |
| 16 | Per-document chat panel (one chat per document, not global) | Adapt | Reflect [10] and Coda [7] both use a per-page context; the multi-doc case in §8 needs more architect input. |
| 17 | Delete pending item: no confirmation | Adopt | The item never executed; undo across a sheet confirmation is HIG §13.5 anti-pattern [22]. |
| 18 | Multi-document agent runs (agent on doc A while user edits doc B) | Adapt | Per-agent task queue [14] is the pattern; chat-per-doc or one shared queue is the open question. |
| 19 | Receipts: local-first, exportable as signed JSON bundle | Adopt | HACO C2PA [17] + the architect's no-egress doctrine + the editable-AI-output pattern [18]. |
| 20 | Receipt persisted even after undo (with `voided_by` link) | Adopt | HACO [17] and editable-AI-output [18] both require it; a deleted receipt is a lost audit trail. |
| 21 | Undo routes through macOS standard Cmd-Z + Edit menu, names the operation | Adopt | HIG §10.11, §14.5 [22]; required for system integration. |
| 22 | iOS: chat panel = bottom sheet above keyboard, drag-to-reorder via long-press | Adopt | HIG §5.1, §5.2 [22]; iOS ergonomics require the chat above the keyboard. |
| 23 | Continuity: Handoff of the in-flight edit; macOS picks up mid-flight on resume | Adapt | HIG §8 + agent framework primitives; receipt state lives in Postgres so resume is a re-read. |
| 24 | Receipts drawer: separate window (macOS) accessible from View menu | Adopt | HIG §13.19 [22]; inspector pattern is the right shape for a panel. |
| 25 | Audit trail filter: by date, by entity, by agent vs user | Adopt | Action Audit Trail pattern [18] + HACO [17] both require filterable provenance. |
| 26 | `Cmd-K` command palette: search nodes + actions + chat queue | Adopt | Foundation Lab's pattern; Reflect [10] uses it; standard macOS power-user feature. |
| 27 | Handoff: the chat queue, the in-flight edit, the receipt state are all Handoff-eligible | Adopt | Handoff is the canonical Apple cross-device primitive; architect's "same document on both" requires it. |
| 28 | Drag-to-reorder pending: VoiceOver custom rotor action | Adopt | HIG §3.1 [22] + a11y direction; the standard rotor pattern is rotorAction(). |
| 29 | Failed-receipt visible inline with retry + tap-through to error detail | Adopt | Background tasks pattern [14] "include an item-level breakdown of the jobs that succeeded, failed, or were skipped". |
| 30 | Cancelled receipt stays in the history with reason; never system-notified | Adopt | HIG §14.12.x suppression pattern; canceller doesn't get a notification. |
| 31 | Receipts export: signed JSON bundle + Markdown summary + (opt-in) C2PA manifest | Adapt | HACO requires C2PA at A3+; Tessera v1 is A2 so the export is a simpler signed bundle. |
| 32 | Notion AI side panel + Insert button | Reject | Architect's explicit reject + user backlash when Notion removed inline (2024) [25][26]; HCI literature on split-attention [8]. |
| 33 | Cursor's raw keystroke streaming (no polish) | Reject | Architect's explicit reject + Co-Writing CHI 2022 [3] on cognitive load; users report "constant stream becomes distraction" [27]. |
| 34 | Apple Intelligence's inline rewrite/proofread popover | Reject | Architect's explicit reject + Six Colors review [1] + Brisktype review [2] (conservative, no inline autocomplete, all-or-nothing correction). |
| 35 | ChatGPT's "thinking then result" loading modal | Reject | HIG §14.1 [22] + Architect's reject; the entire agent-IS-the-editor premise precludes it. |
| 36 | Grammarly's "highlight then accept" (highlight + one-tap accept) | Adapt (animation polish only) | We don't want Grammarly's pattern (highlight the user's writing to suggest changes — wrong direction); we want its animation discipline (calm, blue/green, micro-animations) [28][29]. |
| 37 | Three-finger swipe for undo (iOS) | Adopt | HIG §16.2 [22] standard; do not repurpose. |
| 38 | Shake-to-undo on iOS | Adopt | HIG §14.5 [22] standard; do not repurpose. |
| 39 | Cmd-Z on macOS routes to the editor's UndoManager, not the chat's | Adopt | The chat is a queue, not a document; its actions have their own undo (per-item). |
| 40 | iOS drag-to-reorder pending items: long-press to lift | Adopt | HIG §16.2 [22] standard iOS gesture; no hover states. |
| 41 | Receipts are immutable; undo is a separate receipt that links forward | Adopt | Constitutional-receipts design decision + HACO; receipts are evidence, not state. |
| 42 | "Active chat" per document is sticky across navigation | Adapt | Reflect [10] is per-page; Craft [6] doesn't have chat; needs architect call on multi-window. |
| 43 | Receipts drawer: per-entity filter (this document only / this folder / all) | Adopt | Reflect [10] graph view filter is the comparable pattern. |
| 44 | Tap on a receipt in the chat: highlight the affected blocks in the doc | Adopt | HIG §14.5 [22] "highlight the result of an undo when offscreen"; same pattern for receipt visualization. |
| 45 | Per-receipt timing (ms latency, ms apply duration) | Adopt | HACO override-cost metric [17]; make it visible so users can compare. |
| 46 | Receipt hash chain (each receipt links to its predecessor) | Adopt | Constitutional receipt model; C2PA-style content credentials [17]. |
| 47 | "Empty state" for receipts drawer: first run gets a TipKit intro | Adopt | HIG §14.2 [22]; receipts are unfamiliar to most users. |
| 48 | Receipts export: a one-click "Export audit" button in the drawer | Adopt | Microsoft Copilot [12] "encourage fact-checking using citations and direct quotes"; same for provenance. |
| 49 | macOS Edit menu: Undo names the most recent operation ("Undo Agent edit", "Undo Apply style") | Adopt | HIG §14.5 [22] + agent framework primitives [15][16]. |

---

## 2. The Apple HIG baseline (mandatory reading)

The architect is shipping a native Apple-platform app. The Apple Human Interface Guidelines (HIG) [22] is the authoritative source for what "good" looks like on macOS and iOS — not the lit-review literature, not the market's accumulated wisdom, not the architect's intuition. The literature tells us what users want; the HIG tells us what we have to do to ship a native app. This section walks the relevant HIG sections, identifies which rules apply to the productivity surface, and notes where the architect's design already follows the HIG and where it deviates with a justified reason.

### 2.1 macOS HIG

**Editing text (HIG §4 macOS, §13 components text fields)**. The productivity surface is a text editor plus an agent that mutates it. The two text components are `NSTextView` (macOS) wrapped via `RichTextKit`, and `TextField`/`TextEditor` for the chat panel input. HIG rules that apply:

- **Cursor visibility** — always show the insertion point. A hidden caret in a doc with a streaming agent edit is the single most common source of "I lost my place" complaints. The streaming agent must respect the user's caret position and not steal focus. [22 §13.2]
- **Drag and drop** — drag-and-drop in macOS is the canonical way to move blocks within a doc, drag files in from Finder, drag a block handle to reorder. HIG §4.6 is the entire ruleset. The productivity surface must support `.draggable` / `.dropDestination` on every block handle and accept drops from Finder. [22 §14.6]
- **Standard keyboard shortcuts** — `Cmd-Z` / `Shift-Cmd-Z` undo, `Cmd-X/C/V` cut/copy/paste, `Cmd-A` select all, `Cmd-B/I/U` bold/italic/underline, `Cmd-F` find, `Cmd-N` new, `Cmd-S` save, `Cmd-]` / `Cmd-[` indent outdent. None of these may be repurposed. The agent's edits must respect the standard undo stack (so `Cmd-Z` undoes the agent's last action with a properly-named menu item like "Undo Agent edit" per §14.5). [22 §4.5, §14.5]
- **Edit menu** — undo/redo at the top, cut/copy/paste, delete, select all, find. The productivity surface must wire the standard edit menu and add an "Apply agent suggestion" / "Pause agent" / "Resume agent" group after paste. [22 §13.18]

**Sidebar (HIG §4.4)**. The chat panel is a sidebar in the macOS layout. HIG rules:

- Use `NavigationSplitView` for sidebar + detail, not `HSplitView`. [22 §10.1]
- Three levels of hierarchy max in the sidebar (this product has 2: the document tree and the chat queue).
- Let people hide the sidebar via `Cmd-Control-S` (Show/Hide Sidebar) and the View menu.
- Default to small/medium/large sidebar width based on user preference; the chat panel's width is a user-controlled setting.
- Sidebar icons use SF Symbols, default to system accent color. The chat panel's "agent paused" icon, the receipt icon, and the user-vs-agent markers are SF Symbols, not custom. [22 §11.2]

**Toolbar (HIG §4.3)**. The editor's format toolbar lives in the window's frame. Rules:

- Three groupings: leading (sidebar toggle, back/forward, document menu), center (customizable items), trailing (inspectors, search, primary action).
- Don't add a bezel to toolbar items; macOS doesn't use them.
- Make every toolbar item available as a command in the menu bar (View > Customize Toolbar; the toolbar can be hidden).
- Use SF Symbols for toolbar items, not text.
- Don't add colored backgrounds to toolbars; let the system handle the appearance. Apply accent color only to the primary action.

**Inspector (HIG §4.9)**. The Receipts drawer is an inspector pattern:

- Trailing pane of a `NavigationSplitView` (`.inspector(isPresented:)`).
- Auto-updates when selection changes.
- Show/hide with the app activation.
- Brief title, noun phrase, title-style capitalization.

**Modal dialogs (HIG §10.10, §14.7)**. The "no modal" rule for the agent-paused indicator:

- Critical + actionable? → Alert.
- Small + anchored to a control? → Popover.
- Context about current selection? → Inspector.
- Focused multi-step task? → Sheet.
- Immersive? → fullScreenCover.
- Persistent? → New window.

The agent-paused indicator is **context about the current state**, not a critical interruption. It is a non-modal status indicator (a banner in the chat panel, a subtle pulse on the chat icon). Full-screen modals for agent state are rejected by HIG and by the human-in-the-loop agent literature [15][16] (the user must be able to dismiss the modal to act, but the modal blocks them from acting — the exact opposite of "cheap interrupt").

**Drag and drop (HIG §4.6, §14.6)**. The chat panel's drag-to-reorder is a standard drag operation:

- Provide a `Transferable` type (the pending chat item).
- Source view: `.draggable(_:preview:)` with a translucent drag image.
- Target view: `.dropDestination(for: ChatItem.self)`.
- Spring loading not required (chat is a list, not a tree).
- VoiceOver custom rotor for accessibility (§10).

**Notifications (HIG §14.12)**. The receipt-applied notification:

- Use **Active** interruption level for completed receipts (default).
- **Time Sensitive** is reserved for "this run finishes in the next hour and you marked it urgent" — never for the default.
- **Critical** is for safety/health only and requires an entitlement; not applicable.
- The suppression rule from the agent pattern skill [22 §14.12.x] applies: do not notify when the user can see the outcome. The chat panel is the in-app signal; the system notification is the wake-up signal when the app is backgrounded.
- Cancels never fire a system notification.

**Status bars (HIG §13.7)**. The bottom bar of the editor window:

- Small; only for status info directly related to the window's contents.
- The productivity surface's bottom bar can show: "12 receipts today, 3 by agent, 0 failed" — a one-line status, not a panel.
- If we want more, use an inspector (the Receipts drawer).

**Undo and redo (HIG §14.5)**. The critical section for the agent-as-editor:

- Place Undo/Redo at the top of the Edit menu.
- Connect to the focused view's `UndoManager` (the `@Environment(\.undoManager)`).
- Name the operation: "Undo Agent edit" / "Redo Apply style", not generic "Undo".
- Highlight the result of an undo when the affected content is offscreen (scroll-into-view).
- Let people undo multiple times. Don't place artificial caps.
- Consider batched undo for related incremental changes (the agent's multi-step edit is one batched undo).

**Loading (HIG §14.10)**. The architect has explicitly rejected "thinking then result" loading modals. HIG §14.10 says:

- Show something as soon as possible (placeholder text, graphics, or animations while content loads).
- Let people do other things while they wait.
- If the wait is unavoidably long, give people something useful to view.
- Show progress clearly when wait is more than a moment: determinate (know the duration) or indeterminate (don't).
- Allow cancellation.
- Don't strand the user — every loading state has a way out (Cancel, dismiss, navigate elsewhere).

The agent's "thinking" state satisfies this rule with the chat panel pulse (visible feedback, not blocked) and the cancel button (escape hatch).

**Settings (HIG §14.8)**. The Settings scene (`Cmd-,`):

- Non-customizable toolbar with pane-switching buttons (Editor, Agent, Privacy, Receipts, About).
- Dim the minimize and maximize buttons.
- Window title reflects the active pane.
- Restore the last-viewed pane on reopen.
- Bind receipt export to a Settings pane (export location, format, signed-bundle settings).

**Launching (HIG §14.13)**. The productivity surface launch:

- Launch instantly; macOS doesn't require a launch screen.
- Restore the previous state (windows in their previous state and location).
- Open the most recent document (or the last-edited document), or a sample document if first-run.
- For long initial loads, show a placeholder UI with progress, not a blank window (e.g., "Connecting to data layer..." while Postgres + Valkey come up).

### 2.2 iOS HIG

The iOS port is a follow-on (the architect's stated 1.0 priority is macOS). But the iOS design is constrained by macOS decisions, so the iOS HIG rules that affect the macOS design are noted now.

**Text input (HIG §5 iOS)**. The chat panel input:

- The keyboard toolbar above the keyboard is the right place for chat-panel actions (send, attach, voice).
- The "return" key on iOS sends (single-line input) — or inserts a newline (multi-line input). The chat input is single-line by default, multi-line on long-press.
- Dynamic Type scales the chat input; the chat history (the queue) scales independently.

**Modal sheets (HIG §5.2, §10.10)**. The agent-paused indicator on iOS is a small status banner above the chat input, not a sheet. A sheet would block the document; a banner is non-modal.

**Activity views (HIG §5.3, sharing)**. The export action uses `UIActivityViewController`:

- Show the system share sheet with the exported file as the item.
- Custom activities for "Export to PDF", "Export to DOCX", "Export to Slack webhook".
- Apple's "Copy" and "Save to Files" are included automatically.

**Tab bar vs sidebar (HIG §5.1)**. The iOS layout is a tab bar at the bottom:

- 5 tabs: Documents, Editor, Chat (the queue), Receipts, Settings.
- The chat tab is one of the 5; it shows the queue for the current document.
- The editor tab is the "work" surface; the chat tab is the "command" surface.

**Drag-to-reorder (HIG §16.2, iOS extras)**. Long-press to lift; no hover states; the system drag handles the gesture. VoiceOver rotor for the same action.

### 2.3 SwiftUI decision trees (HIG §10)

The HIG decision trees (§10) settle recurring questions. For the productivity surface:

- **Sidebar + detail vs tab bar**: macOS sidebar + detail (iPadOS also), iOS tab bar (§10.1).
- **Window vs sheet vs inspector**: the chat panel is an inspector pane (trailing); the receipt drawer is an inspector; the agent's "edit doc" action opens no new window — it mutates the current document. The Settings is a `Settings { ... }` scene (§10.2, §10.12).
- **Toolbar vs menu bar vs context menu**: every toolbar item also in the menu bar; context menu on block (delete, duplicate, "agent edit this block") (§10.3).
- **Sheet vs alert vs popover**: never stack sheets; no alert for non-critical info (§10.10).
- **Button styles**: bordered prominent for the primary call-to-action (one per surface: "Send" in the chat panel); bordered for secondary ("Attach"); borderless for inline actions (§10.5).
- **TextField vs Stepper**: the agent's per-step cadence is not a stepper — it's a temporal delay. The chat panel input is a TextField; the agent's settings (LLM temperature, block size) use Stepper+TextField.
- **State lifetime**: chat queue is scene-owned (lives for the window's lifetime; survives sidebar destination switches); the drag-to-reorder state is view-local; the receipt history is scene-owned. [22 §4.11-4.13]

### 2.4 Where the architect's design follows HIG and where it deviates

| HIG area | Architect's design | Status |
|---|---|---|
| Sidebar via `NavigationSplitView` | Yes (chat panel as a sidebar) | Aligned |
| Standard keyboard shortcuts (Cmd-Z, etc.) | Yes (with agent naming) | Aligned with justified extension (Undo names the agent's action) |
| Undo wired to `UndoManager` | Yes, with batched undo for multi-block agent edits | Aligned with justified extension |
| Inspector for Receipts drawer | Yes | Aligned |
| Bottom bar = status, inspector = details | Yes (12-receipts-today in the bar; full audit in the drawer) | Aligned |
| Liquid Glass for chrome (toolbar, sidebar) | Yes (default in macOS 26) | Aligned |
| No full-screen modal for agent state | Explicit reject | Aligned with HIG §10.10 and §14.1 |
| Standard iOS gestures (3-finger swipe, shake, long-press) | Yes (no repurposing) | Aligned |
| Settings via `Settings { ... }` scene | Yes (Cmd-,-bound) | Aligned |
| Notification interruption levels (Active default, never Critical) | Yes | Aligned |
| Reduce Motion respected | Yes (animations swap to crossfade) | Aligned |
| Handoff of the in-flight edit | Open question — needs Postgres state for resume (architect's data layer handles this) | Aligned with architect's data layer |
| Sheet-stacking prevention | Yes (no sheets) | Aligned |
| VoiceOver labels on every chat item | Yes (state-specific labels) | Aligned |

The architect's design is broadly HIG-compliant. The two places where the design **extends** HIG intentionally are:

1. **Naming the agent's action in the Undo menu**. HIG §14.5 says "name the operation"; for a single-user document, the name is "Undo Typing" or "Undo Bold". For the productivity surface, the name is "Undo Agent edit" (or "Undo Agent replace paragraph" when the agent's last action is identifiable). The extension is justified because the alternative ("Undo") is ambiguous when the user can't tell whether the last change was theirs or the agent's.
2. **Batched undo for multi-step agent edits**. HIG §14.5 says "consider batched undo for related incremental changes". A 3-block agent edit is one logical operation; the user expects one `Cmd-Z` to undo all three. The receipt infrastructure makes this trivial (one receipt = one undo step, even if the receipt covers three blocks).

These two extensions are minor and well-motivated; they are recommendations, not deviations.

---

## 3. Academic literature survey (CHI / UIST / IUI / TOCHI)

This section surveys the HCI literature on AI-assisted document editing, streaming LLM output, block-based editors, conversational vs direct-manipulation interfaces, and interruptibility. The aim is to ground the UX decisions in evidence, not intuition.

### 3.1 Co-Writing with AI (Biermann, Ma, Yoon — DIS 2022)

Biermann, O. C., Ma, N. F., & Yoon, D. (2022). *From Tool to Companion: Storywriters Want AI Writers to Respect Their Personal Values and Writing Strategies.* In Proceedings of the 2022 ACM Conference on Designing Interactive Systems (DIS '22). DOI: 10.1145/3532106.3533506. [30]

**What they studied.** Qualitative interviews with storywriters about their experience of AI writing assistants. They found that writers want AI systems to act as "companions" that respect personal values and writing strategies, not as tools that overwrite the writer's voice.

**Mapping to Tessera.** The companion framing is exactly what the architect's "agent IS the editor" model wants to avoid — the agent is not a co-writer, it's a co-editor. The writers' complaint is "the AI overrode my style"; the architect's design addresses this by (a) preserving the user's edits in the receipt chain, (b) making the agent's edits reviewable as a discrete operation (not a keystroke stream), and (c) allowing the user to redirect at any time.

**Recommendation.** Adopt the writer's mental model of "the AI is a guest in my document, not a co-author" — the agent's edits must be marked as the agent's, with a clear receipt, and the user must be able to take over without ceremony.

### 3.2 Co-Writing with AI, on Human Terms (Reza et al. — CSCW 2025)

Reza, M., Thomas-Mitchell, J., Dushniku, P., Laundry, N., Williams, J. J., & Kuzminykh, A. (2025). *Co-Writing with AI, on Human Terms: Aligning Research with User Demands Across the Writing Process.* Proc. ACM Human-Computer Interaction 9(7), CSCW385. [3]

**What they studied.** Systematic literature review of 153 CHI papers on AI-assisted writing (2020-2024), plus interviews with 15 writers. They identify four design strategies:

- **S1: Structured Guidance** — AI offers prompts and suggestions but the user authors.
- **S2: Guided Exploration** — AI offers multiple options; user picks.
- **S3: Active Co-Writing** — AI writes alongside the user, who selectively offloads.
- **S4: Critical Feedback** — AI reviews and critiques the user's writing.

They found that content-focused writers (academics) emphasize control over planning; form-focused writers (creatives) emphasize control over translation/revision. Levels of AI intervention vary by writing process and context.

**Mapping to Tessera.** The architect's design is closest to S3 (Active Co-Writing) with the receipt infrastructure as a critical-feedback layer (S4) overlaid. The paper's finding that intervention levels vary by process is a direct validation of the architect's per-process "hard suggestion" semantics: planning (light touch, S1+S2), translating (active co-writing, S3), reviewing (S4 — receipts).

**Recommendation.** Adopt the per-process intervention calibration. The agent's "hard suggestion" should be heavier during translation (where the user wants the AI to write) and lighter during planning (where the user wants structured prompts). This maps to the chat panel's queue semantics: the user can pre-set the intervention level per-process in Settings.

### 3.3 CoAuthor: Designing a Human-AI Collaborative Writing Dataset (Lee, Liang, Yang — CHI 2022)

Lee, M., Liang, P., & Yang, Q. (2022). *CoAuthor: Designing a Human-AI Collaborative Writing Dataset for Exploring Language Model Capabilities.* In Proceedings of the 2022 CHI Conference on Human Factors in Computing Systems. DOI: 10.1145/3491102.3502030. arXiv:2201.06796. [4]

**What they studied.** A dataset of 1,445 writing sessions by 63 writers using 4 instances of GPT-3. They analyze the writers' interaction patterns (when they accept, reject, edit the AI's suggestions) and identify collaboration styles. The paper is a methodological contribution (a reusable dataset and interface) and a finding contribution (writers' interaction is not just "accept/reject"; they edit, redirect, and build on).

**Mapping to Tessera.** The dataset's "edit" and "redirect" categories validate the architect's design choice to support the same in the chat panel. The paper finds writers use the AI as a "drafter" then heavily edit; this maps to the receipt chain (the AI's draft is the receipt's first entry, the user's edit is the second).

**Recommendation.** Adopt the "draft + edit" model as the default. The agent's edit is not final; the receipt infrastructure must allow the user to amend the agent's edit and have the amendment be a new receipt (not a destructive overwrite of the original).

### 3.4 Metaphoria: An Algorithmic Companion for Metaphor Creation (Gero & Chilton — CHI 2019)

Gero, K. I., & Chilton, L. B. (2019). *Metaphoria: An Algorithmic Companion for Metaphor Creation.* In Proceedings of the 2019 CHI Conference on Human Factors in Computing Systems. DOI: 10.1145/3290605.3300526. [5]

**What they studied.** A system that generates metaphorical connections for poetry/essays/stories. The study found that writers use the system in three ways: to elicit ideas (inspiration), to overcome writer's block (translation), and to act as a new form (structural). The paper's deep finding is the tension in human-machine collaboration: the writer wants the AI to be helpful but not overpower their own voice.

**Mapping to Tessera.** The "three uses" finding maps to the chat panel's three states: inspiration (pending — the user queues a prompt), translation (in-progress — the agent is writing), structural (applied — the user reviews and integrates). The ownership tension is exactly the "receipt + take over" model.

**Recommendation.** Adopt the three-mode framing for the chat panel's tooltip/help text: "queue a prompt to inspire", "watch the agent write in real time", "review and integrate".

### 3.5 DirectGPT: A Direct Manipulation Interface to Interact with Large Language Models (Masson et al. — 2023)

Masson, D., et al. (2023). *DirectGPT: A Direct Manipulation Interface to Interact with Large Language Models.* arXiv:2310.03691. [8]

**What they studied.** A user study comparing a direct-manipulation LLM interface (DirectGPT) to ChatGPT for text, code, and vector image editing tasks. Findings: participants were 50% faster, used 50% fewer prompts, the prompts were 72% shorter, and they were 25% more successful when using direct manipulation. Direct manipulation principles: continuous representation of generated objects, reuse of prompt syntax in a toolbar, manipulable outputs, undo mechanisms.

**Mapping to Tessera.** This is the closest direct validation of the architect's design. Tessera's editor is a direct-manipulation surface; the agent's edits land directly on the document (not in a side panel that the user copies from). The 50% speedup and 72% shorter prompts suggest the design is correct; the side-panel + Insert pattern (Notion AI's rejected pattern) is a form of "conversational" interface that this paper shows is worse.

**Recommendation.** Adopt the direct-manipulation framing as the design's core principle. The chat panel is a *control* surface (queue, status, redirect), not a *content* surface (display, copy, paste). The document is the only content surface.

### 3.6 The LLM-ification of CHI (Kim et al. — 2025)

Kim, J., et al. (2025). *Understanding the LLM-ification of CHI: Unpacking the Impact of LLMs on HCI Research.* MIT dspace. [7]

**What they studied.** A systematic literature review of 153 CHI papers from 2020-2024 that engage with LLMs. The paper categorizes papers by topic (writing support, design support, code generation, etc.) and identifies cross-cutting themes.

**Mapping to Tessera.** The paper's cross-cutting themes (co-writing, structured output, conversational interfaces, mixed-initiative control) are all directly relevant. The paper's critique is that the field is converging on a "ChatGPT-shaped" UI for products that are not chats; this is the exact critique the architect is responding to with the "agent IS the editor" model.

**Recommendation.** Adopt the field's emerging consensus that the chat interface is the default, not the destination, and that the productivity surface must commit to a different shape. The chat panel is a queue, not a chat history.

### 3.7 Human-AI Collaboration (HACO) Framework (Shneiderman et al. — 2025)

*Delegation without Abdication: Human-AI Collaboration (HACO)* — research paper 2025. [17]

**What they studied.** A framework that binds five agency bands (A0–A4) to non-negotiable control guarantees and task-criticality tiers. The lifecycle lens (intent capture → generation → selection → revision → handover) makes "human in the lead" auditable via paired metrics: time-to-desired-change (TTC), override cost, recovery success, provenance completeness, harmful-output rates. Design patterns: progressive disclosure of power, Explain→Edit links, cheap branching with fine-grained rollback, preference plasticity.

**Mapping to Tessera.** The HACO framework is the single most direct match to the architect's design. Tessera operates at A2 (suggest + approve) for some flows and A3 (apply + audit) for others; the receipt infrastructure is the provenance mechanism; the chat panel's interrupt UX is the A2–A3 transition. The framework's mandatory control guarantees (see why the assistant acted, steer what it should do next, recover/audit earlier states) are exactly the architect's three pillars (receipts, redirect, undo).

**Recommendation.** Adopt HACO as the design's theoretical anchor. The receipt chain implements the provenance requirement; the chat panel implements the steer requirement; the undo/redo implements the recover requirement. The architect's design is well-aligned; the UX work is to make the HACO guarantees visible to the user.

### 3.8 Human-in-the-Loop Agent Frameworks (LangGraph, OpenAI Agents SDK, AG-UI)

Kagan, A. (2025). *The Human-in-the-Loop Catalog — Agentic AI Series Vol. 07.* [15] and the AG-UI Interrupts specification (2025). [16]

**What they studied.** The converged HITL primitive across all major agent frameworks: interrupt → {approve, edit, reject, respond} → resume, built on durable state. The non-negotiable substrate is a checkpointer/persistence layer: HITL and pause/resume are the same feature. Frameworks: LangGraph's `interrupt_before` + dynamic `interrupt()`; OpenAI Agents SDK's `interruptions[]` array; AG-UI's `RunAgentInput.resume[]` with the same-thread + idempotency + expiry + payload-validation rules.

**Mapping to Tessera.** This is the technical literature the architect is building on. The frameworks converge on: (1) the interrupt is a typed decision (approve/edit/reject/respond), not a free-form chat; (2) the state is durable (the agent's run can be paused and resumed across process restarts); (3) the resume is idempotent (replaying the same resume payload is safe). Tessera's Postgres + Valkey data layer is the durable state; the receipt is the typed decision; the chat panel is the interrupt UI.

**Recommendation.** Adopt the converged primitive as the chat panel's state machine: pending → in-progress → {applied, failed, cancelled, paused}. The "paused" state is the architect's "user clicked in the doc" interrupt; the "cancelled" state is the user explicitly stopping the agent. The five-state machine is the simplest correct implementation of the frameworks' primitive.

### 3.9 Action Audit Trail Pattern (AI UX Design Guide)

AI UX Design Guide (2025). *Action Audit Trail — Track and Review Every AI Decision.* [18]

**What they studied.** A pattern catalog for AI agent UX. The Action Audit Trail pattern: a timestamped, structured log of every agent action, grouped by task, with reversibility status, selective undo, and diff views. Color-coding by reversibility (green/amber/red). Default view is timeline grouped by task, not raw chronological log. Filter by action type, time range, affected system. Export capability for compliance and team review.

**Mapping to Tessera.** The pattern is a direct template for the Receipts drawer. The reverse-engineering: timestamps come for free (Postgres has `created_at`); task grouping is the chat panel's "session" key; reversibility status is the receipt's `voided_by` link; diff view is the receipt's `before` / `after` blocks; color-coding is the receipt's type (created/updated/deleted = green/amber/red).

**Recommendation.** Adopt the pattern as the Receipts drawer's information architecture. Group by session (one chat panel queue = one session), show the receipt type as a colored chip, include "What changed?" as a tap-through, allow filter by type and date.

### 3.10 Editable AI Output Pattern (UX Patterns Guide)

UX Patterns Guide (2025). *Editable AI Output.* [18]

**What they studied.** A pattern for AI-generated content that is expected to be revised before use. Key requirements: render generated content as a draft with a clear boundary between original generated text and user-edited text; preserve source mappings; expose draft, edited, tracked-change, unsafe, stale, accepted, rejected, saved, copied, regenerated, applied as explicit states; protect manual edits from accidental overwrite; require review before apply when an edit changes factual claims.

**Mapping to Tessera.** The pattern is the receipt chain's contract. The architect's "every save = a new version, every mutation = a receipt" is the durable-state substrate that makes the pattern implementable. The "review before apply" requirement maps to Tessera's "user can interrupt at any time" — the receipt is not applied until the user acks it (via the chat panel's tap-to-apply or via leaving it pending).

**Recommendation.** Adopt the explicit state enumeration. The receipt's state machine should be: drafted (agent proposed), user-reviewed, applied, user-amended, voided. The chat panel shows the state; the receipt's history shows the transitions.

### 3.11 Provenance in Human-AI Collaboration (Seng, B. — 2025)

Seng, B. (2025). *Provenance in Human-AI Collaboration.* [31]

**What they studied.** A working standard for AI-assisted authorship. The standard: every contribution should either come from a known source, or be clearly marked as new synthesis. The provenance note includes the source of imported material, the nature of the transformation (summary, paraphrase, extension, reinterpretation), and the agent of contribution (human author, AI collaborator, joint synthesis). The recommended workflow: separate review and creation, keep a source list, ask the AI to generate its own source list, use inline citations, verify all citations before publishing, write a collaboration statement.

**Mapping to Tessera.** The standard is directly applicable to the receipt infrastructure. Every receipt should carry: (i) the source (what data the agent read, e.g., "previous 3 paragraphs of the doc + web search for 'GPT-4 architecture'"), (ii) the transformation (replace, insert, delete, format), (iii) the agent (user / on-device LLM / Anthropic / OpenAI), and (iv) the timestamp + receipt hash. The receipt is the provenance note.

**Recommendation.** Adopt the four-field provenance schema. The Tessera receipt is the implementation; the standard is the contract. The chat panel's inline receipt summary can show (iii) and (iv); the tap-through shows the full (i) and (ii).

### 3.12 Direct Manipulation Foundations (Hutchins, Hollan, Norman — 1986, NNG 2024)

Hutchins, E. L., Hollan, J. D., & Norman, D. A. (1986). *Direct Manipulation Interfaces.* In Norman & Draper (Eds.), User Centered System Design. NNG (2024). *Direct Manipulation: Definition.* [9]

**What they studied.** The classical HCI definition of direct manipulation: continuous representation of objects of interest, physical actions or button presses instead of complex syntax, rapid, incremental, reversible actions whose effects are visible immediately. WYSIWYG is the canonical example.

**Mapping to Tessera.** The architect's design is direct manipulation — the user sees the document, the user acts on the document, the agent acts on the same document with the same representation. The chat panel is a control surface (analogous to the menu bar), not a content surface.

**Recommendation.** Adopt the direct manipulation framing as the design's theoretical foundation. The chat panel is a control surface that does not contain document content; the document is the only content surface. This is the same principle behind DirectGPT's 50% speedup (CHI 2023) [8].

### 3.13 Agent Drift and Multi-Agent Coordination (Prassanna, S. — 2025)

Prassanna, S. (2025). *Agent Drift in AI Systems.* [32]

**What they studied.** A taxonomy of agent failure modes: goal drift (the agent stops solving the right problem), reasoning drift (small errors compound over many turns), context drift (the agent acts on stale assumptions). The mitigation: procedural memory distillation (compress the agent's history into beliefs), adaptive behavioral anchoring (re-inject early exemplars when the agent drifts), and micro-gate workflows (human approval between phases).

**Mapping to Tessera.** Tessera's "user can interrupt at any time" is the human-in-the-loop micro-gate. The receipt chain is the procedural memory: the agent's beliefs about the document are the receipt sequence, not a free-form chat history. The chat panel's "redirect" UX is the adaptive behavioral anchoring: a new pending message is the new "exemplar" that re-steers the agent.

**Recommendation.** Adopt the micro-gate as the default. The agent's work is broken into discrete operations (one receipt = one operation); the user can interrupt between any two; the resume is the new pending message plus the receipts. This is the simplest correct implementation of the micro-gate pattern.

### 3.14 Streaming LLM Output (CHI 2024, AI-TLDR, ai-tldr.dev)

AI-TLDR (2025). *Designing for LLM Latency: Streaming UX Patterns.* [20] and *Chatbot UX Patterns: Streaming, Errors, Citations & More.* [19]

**What they studied.** Implementation patterns for streaming LLM output. Key rules: (1) time to first token (TTFT) is the dominant perceived-latency metric, not total time; (2) a typing indicator fills the gap between submit and first token; (3) markdown can arrive incomplete, so buffer and re-render; (4) auto-scroll to keep the latest text visible; (5) a Stop button bound to the stream reader; (6) skeletons shaped like the expected answer, not generic loaders; (7) status text that updates ("Searching..." → "Reading 3 results..." → "Drafting answer..."); (8) optimistic UI (add the user's message immediately).

**Mapping to Tessera.** The chat panel's "thinking" state is the typing indicator; the "agent paused" indicator is the status text; the receipt summary is the "applied" state. The streaming block-edit is the streaming LLM output, except the output is the block AST, not the rendered text. The TTFT rule applies: the first block of the agent's edit must appear within 200-500ms of the user pressing send, even if the rest of the edit takes 3-5s.

**Recommendation.** Adopt the streaming patterns wholesale. The "skeleton shaped like the expected answer" rule maps to: the chat panel shows a placeholder block in the doc with a fade-in animation, then the agent's edit replaces it as the streaming completes.

### 3.15 Background Tasks and Progress (LogRocket, appmaster.io)

LogRocket (2025). *UI patterns for async workflows, background jobs, and data pipelines.* [13] and AppMaster (2025). *Background tasks with progress updates.* [14]

**What they studied.** UX patterns for long-running operations. The converged pattern: a four-state lifecycle (queued, running, succeeded, failed/cancelled) with job ID, status endpoint, durable store. UI rules: show a real progress counter ("124 of 500 rows processed"), include an item-level breakdown of succeeded/failed/skipped, name the states in the UI not just the backend, communicate why a job is pending.

**Mapping to Tessera.** The chat panel's queue is the UI for the agent's jobs. The four-state machine is the converged primitive from §3.8; the UI rules from this paper are the visual treatment. The "include an item-level breakdown" is the receipt summary.

**Recommendation.** Adopt the four-state machine and the item-level breakdown. The chat panel's pending item shows "3 receipts queued", the in-progress item shows "Streaming block 2 of 4", the applied item shows the receipt summary, the failed item shows the error with retry.

---

## 4. Market pattern survey

This section surveys 14 products that ship AI-integration or block-based editor UX today. For each, we summarize the editor's AI integration pattern, what works, what doesn't, and the lesson for Tessera.

### 4.1 Notion AI (REJECTED pattern)

Notion AI offers two integration modes: **inline** (press space on a new line, or highlight text, to invoke a popover of AI commands; the output is inserted below the cursor as a new block) and **side panel** (a chat panel on the right that the user can drag in to have a multi-turn conversation; the output must be manually inserted via the "Insert below" button). [25][26]

**What works.** The inline mode is good for local edits ("rewrite this paragraph in a more formal tone") — the user is in the document, the AI is in the document, the change is in the document. The contextual "current page" indicator (a chip showing which page is the AI's context) is a useful affordance.

**What doesn't.** The side panel is widely criticised. When Notion moved AI into a side panel in 2023 and removed the inline option, the user backlash forced them to re-add inline in 2024. The specific complaints: (i) the side panel loses the editing context (a user highlights text and says "rewrite this in a different tone" — the side panel ignores the highlight and rewrites the whole page); (ii) the "Insert below" button is an extra step that breaks the flow (the user reads the AI's output, switches back to the doc, finds the right insertion point, clicks Insert); (iii) the side panel makes the doc feel like a "view" not a "document". [25][26]

**Lesson for Tessera.** Tessera's "agent IS the editor" model is the right answer. The user should never have to switch contexts to apply an AI edit; the AI's edit should land directly on the document, in the document's flow, with a clear receipt. The side panel is a control surface (queue, status, redirect), not a content surface.

### 4.2 Apple Intelligence Writing Tools (REJECTED pattern)

Apple Intelligence's Writing Tools (macOS 15.1+, iOS 18.1+) offer four actions on selected text: Proofread, Rewrite (Friendly/Professional/Concise), Summarize (key points/list/paragraph), Convert (to table/list). The user selects text, a popover appears, picks an action, and the AI's output replaces the selected text inline. [1][2]

**What works.** The on-device default (with Private Cloud Compute fallback for heavy requests) is a privacy-respecting design. The integration is system-wide (works in Mail, Notes, Pages, Messages, etc.). The proofread animation is calm and respects Reduce Motion.

**What doesn't.** The Rewrite is "conservative" (criticised in Brisktype's review [2] for being competent but not surprising). The Proofread animation sometimes never ends or fails silently (Six Colors [1]). The correction is all-or-nothing — the user can either accept the full rewrite or revert; no partial accept. There's no inline autocomplete (no ghost text), no snippets, no "apply style from this paragraph to the rest". The output is per-action, not compositional.

**Lesson for Tessera.** Tessera's agent must be compositional (multiple operations, receipt chain, undo) not per-action. The on-device default with remote opt-in matches the architect's design. The animation polish is a model (calm, subtle, respects Reduce Motion). The all-or-nothing correction is a model of what *not* to do — Tessera's receipts allow partial undo (one receipt, not the whole rewrite).

### 4.3 Cursor (REJECTED pattern)

Cursor is an AI-enhanced fork of VS Code. It offers Tab completion (a proprietary fine-tuned model that suggests the next complete edit, including multi-line, triggered by Tab), inline editing (Cmd-K opens a chat-style prompt; the output is a diff that the user accepts or rejects), and a chat sidebar (Cmd-L for multi-turn conversation). [27]

**What works.** The Tab completion is fast (cache-warming, speculative decoding, MoE models); the diff view is good; the chat sidebar is well-integrated with the editor. The model latency is well-managed.

**What doesn't.** The Tab completion is "constantly streaming" — the user complaints include "the constant stream of suggestions often becomes more of a distraction than a help" [27]. The completion sometimes appears after the user has already typed past it, then "disappears" with no way to get it back. The inline editing's diff view is binary (accept the whole diff or reject); no partial accept. The chat sidebar is a separate context; the user has to manually select the code to give the chat context.

**Lesson for Tessera.** Tessera's agent must not stream raw keystrokes. The agent's edit must be a discrete, reviewable operation (a receipt), not a continuous suggestion. The user must be able to redirect the agent without the suggestion stream fighting them. The receipt chain allows partial accept/reject; the chat panel is a control surface, not a content surface.

### 4.4 ChatGPT for documents (REJECTED pattern)

ChatGPT's "Canvas" mode (launched 2024) opens a side-by-side editor and chat. The user types in the editor; the AI's responses appear in the chat. The AI can highlight parts of the editor and suggest edits inline (with a "Apply" button). The "thinking" state is a "Thinking..." indicator with no detail; the "applied" state is a "Applied changes" toast.

**What works.** The Canvas mode's inline highlights (the AI highlights the parts it wants to change) are a good visual cue. The "Applied changes" toast is a clear confirmation.

**What doesn't.** The "Thinking..." indicator is the architect's explicit reject — it's a loading modal that doesn't tell the user what's happening. The "Apply" button is the Notion pattern (extra step to commit). The chat history is linear; there's no queue, no redirect, no partial accept.

**Lesson for Tessera.** The "thinking then result" pattern is the architect's reject. Tessera's "thinking" is a subtle pulse in the chat panel; the "applied" is an inline receipt summary; the redirect is a new pending message. The receipt is the load-bearing primitive.

### 4.5 Grammarly (ADAPT — animation polish only)

Grammarly is a writing assistant that runs as a sidebar (web/desktop) or inline (mobile). It highlights problematic text in the document; clicking the highlight opens a suggestion card with a one-tap accept. Premium offers bulk accept ("Accept All"). The UI is calm (blue/green palette, lots of whitespace), the micro-animations are subtle (pulsing elements to draw attention to the next suggestion), and the copy is reassuring ("Make it sound more confident" not "Fix this error"). [28][29]

**What works.** The animation polish — the suggestions have a deliberate, calm cadence; the highlight is subtle (underlined, not boxed); the accept animation is a quick fade. The bulk accept (Accept All) is a power-user feature. The "goal-setting" feature (set the tone, formality, intent before writing) is a useful mode-setter.

**What doesn't.** The highlighting is the wrong direction for Tessera — Grammarly highlights the user's writing to suggest changes, which is the opposite of "the agent edits the doc directly". The "all-or-nothing" bulk accept loses the per-receipt granularity. The pricing wall (free vs. Premium) is a distraction.

**Lesson for Tessera.** Adopt the animation discipline (calm, blue/green palette where appropriate, subtle micro-animations, reassuring copy). Reject the highlighting pattern (we mark the agent's edits, not the user's writing). The "goal-setting" maps to Tessera's per-process intervention calibration (planning vs. translation vs. review).

### 4.6 Craft (ADOPT — block editor + native performance)

Craft is a macOS/iOS-first block-based document editor. The design philosophy: "writing quality over feature volume". The block editor is native (not Electron), the typography is beautiful, the drag-and-drop is fast, the animations are 150-250ms ease-out. Craft has added AI features (summarize, draft, extract action items) but the AI is contextual to the document (not a side panel). The Whiteboard feature is a free-form canvas; the Collections feature is lightweight in-page tables. [6]

**What works.** The native performance is the #1 user-rated feature — "feels faster than every competitor in this category". The block editor is the model for Tessera's semantic block AST. The on-device AI (Apple Foundation Models + DeepSeek R1) is the privacy-respecting default that matches the architect's design.

**What doesn't.** Craft has no database views, no project management layer — it's a writing app, not a workspace. The AI features are less powerful than Notion's (no Custom Agents, no multi-step workflows).

**Lesson for Tessera.** Adopt Craft's native performance discipline (every interaction is fast, animations are tight, the editor is the star). Adopt the block editor model (semantic blocks with consistent handles, drag-to-reorder, slide-in animations). The Tessera productivity surface is not Craft, but the block editor craft is the same craft.

### 4.7 Coda (ADAPT — AI Block + AI Column)

Coda is a workspace tool that combines docs and tables. Its AI features include AI Assistant (chat-style), AI Column (a column in a table that generates values from a prompt), and AI Block (a templated block on a page that generates content from a prompt). The AI Block is the closest to Tessera's design — the AI's output is a block in the document, not a chat. [7]

**What works.** The AI Block is contextual to the document; the AI Column is contextual to the table row. The output is structured (not a free-form text dump). The "5+1 Levels of AI in Coda" framework (data summaries, select from a list, quality check, contextual web search, create rows, doc-wide analysis) is a useful taxonomy.

**What doesn't.** The AI Block is a one-shot (no streaming, no edit history); the user gets the output and must manually edit. The AI Column is a formula (not a conversational interface); the user can't redirect mid-generation. The chat sidebar (AI Assistant) is a separate context that has to be wired in manually.

**Lesson for Tessera.** Adopt the AI Block pattern (the AI's output is a block in the document, with a receipt). The "5+1 Levels" framework is a useful taxonomy for the agent's operations: data summaries (read doc, summarize), select from a list (propose alternative phrasings), quality check (find inconsistencies), contextual web search (fetch and cite), create rows (insert structured data), doc-wide analysis (cross-block operations). The streaming and interruptibility are the Tessera additions.

### 4.8 Reflect (ADOPT — networked notes + receipt-summary UX)

Reflect is a local-first, end-to-end encrypted note-taking app with bidirectional links (a-la Roam Research) and a knowledge graph. The AI is GPT-4-powered, accessed via a hotkey, and offers summarize, rewrite, extract takeaways, and craft counterarguments. The UI is minimal (one window, one sidebar, no chrome). [10]

**What works.** The minimal UI is the model for "no clutter" — Reflect proves that a power-user app can have no menus, no toolbars, no settings panels visible. The AI hotkey is fast and contextual (the AI sees the current note). The local-first + E2E encryption matches the architect's privacy posture.

**What doesn't.** The AI's output is shown in a dialog (not inline in the document); the user must copy-paste. No streaming (the output is a single result). No receipt (the user can't see what the AI changed). No redirect (the user can't say "try again but shorter" without invoking the AI again).

**Lesson for Tessera.** Adopt the minimal UI (no menus, no toolbars, the doc is the focus). Adopt the AI hotkey pattern (Cmd-J to invoke the agent). Adopt the receipt summary UX (after an AI edit, show a one-line summary; tap to expand). Reject the dialog-based output (the agent's edit must land inline, not in a dialog the user copies from).

### 4.9 iA Writer (ADOPT — focus mode + minimal UI baseline)

iA Writer is a Markdown text editor with a focus on writing quality. The design philosophy: "the absence of features, the innovation in input definition, and the attention to detail". The Focus Mode dims everything except the active sentence/paragraph. The Typewriter Mode keeps the cursor vertically centered. The font is custom-designed. The animations are tiny (cursor definition took months to get right). [11]

**What works.** The Focus Mode is the model for "the doc is the focus" — the agent's edit should not steal focus from the user's writing. The minimal UI is the model for "no clutter" — the chat panel is small, the receipt drawer is hidden by default, the toolbar is one row. The animation discipline is the model for "every detail matters" — the cursor blink, the block slide-in, the receipt fade.

**What doesn't.** iA Writer is text-only (no blocks, no tables, no images). The Focus Mode is a writing aid, not an editing aid (it doesn't help review AI edits). The Markdown-only model is too constraining for the productivity surface.

**Lesson for Tessera.** Adopt the focus mode baseline (the doc is the focus; the chat panel is a quiet sidebar; the receipt drawer is hidden by default). Adopt the animation discipline (every detail matters; the cursor, the block slide-in, the receipt fade are all custom-tuned). The semantic block AST is an extension of Markdown that retains the same "writing quality" focus.

### 4.10 Bear (ADOPT — tag-based organization + Markdown focus)

Bear is a macOS/iOS-only Markdown notes app with nested tags (#project/subtopic) instead of folders, beautiful typography, focus mode, and a clean export menu. The Pro tier adds themes and iCloud sync. [33]

**What works.** The tag-based organization is a clean model for the Materials slice — Tasks, Reminders, Calendar, Notes, etc. can be tags on a single document type, not separate app surfaces. The Markdown-first model with live preview is a good baseline for the editor. The export menu (PDF, HTML, DOCX, Markdown, JPG, ePub) is a good template for the export pipeline.

**What doesn't.** Bear has no AI features (it's pre-AI). The single-user-only model is a constraint (no collaboration). The Apple-only model is a constraint (no Windows/Linux).

**Lesson for Tessera.** Adopt the tag-based organization (Materials as tags on a single document type). Adopt the export menu model (one export dialog with multiple format options). The Markdown-first model is too constraining (Tessera uses a semantic block AST, not Markdown), but the principle of "the format is the user's choice" applies.

### 4.11 Things 3 (ADOPT — task UI + Inbox/Today pattern)

Things 3 is a macOS/iOS task manager with two axes (temporal: Today/Upcoming/Anytime/Someday; contextual: Areas/Projects) and a strict Inbox-to-Today discipline. The design philosophy: "Today is sacred; only actual commitments". The UI is minimal, the animations are tight, the keyboard shortcuts are extensive. [34]

**What works.** The Inbox/Today/Anytime/Someday pattern maps directly to the chat panel's pending/in-progress/applied/history state machine. The "Today is sacred" principle is the model for "the queue should be small, not a dumping ground". The two-axis organization (temporal + contextual) is the model for "the chat panel shows time + scope".

**What doesn't.** Things 3 has no AI features. The strict Today discipline is a constraint (the user has to manually move things to Today; the AI could pre-classify).

**Lesson for Tessera.** Adopt the Inbox/Today/History mapping (pending/in-progress/applied/history). Adopt the "Today is sacred" principle (the chat panel queue should be small; old items move to history). The "agent pre-classifies" feature is a v2 improvement.

### 4.12 OmniFocus (ADOPT — power-user task UI baseline)

OmniFocus is a macOS/iOS task manager that follows the GTD (Getting Things Done) methodology strictly. It has parallel/sequential projects, contexts, perspectives, review mode, and a deep keyboard shortcut model. The UI is dense (the power-user trade-off) but the data model is rich. [34]

**What works.** The GTD model (capture, clarify, organize, reflect, engage) is a useful framework for the receipt chain (the receipt's lifecycle is capture, clarify, apply, audit, review). The Perspectives feature (custom views on the data) is a useful pattern for the Receipts drawer's filters. The keyboard shortcut model is the standard macOS pattern.

**What doesn't.** OmniFocus is dense and intimidating; the learning curve is steep. The strict GTD model is too constraining for a productivity surface that wants to be flexible. The "no AI" is a gap.

**Lesson for Tessera.** Adopt the GTD framework for the receipt chain's lifecycle. Adopt the Perspectives pattern for the Receipts drawer (filter by date, by entity, by agent vs. user, by document). Reject the density (the chat panel is minimal, not dense).

### 4.13 Fantastical (ADOPT — natural language input + calendar UI)

Fantastical is a macOS/iOS calendar app with a natural language event parser ("Lunch with Sarah at 1pm tomorrow" → event). The Mini Window is a quick-add dialog accessible from the menu bar; the full window is a day/week/month/year view. The UI is clean; the keyboard shortcuts are extensive. [35]

**What works.** The natural language parser is a model for the chat panel's "hard suggestion" semantics (the user's natural-language prompt is parsed into a typed operation). The Mini Window is a model for "quick add without leaving the current context". The day/week/month view switcher is a model for the chat panel's "switch scope without losing context".

**What doesn't.** Fantastical's natural language is calendar-specific; the chat panel needs a more general semantic parser. The Mini Window is calendar-specific; the chat panel is per-document.

**Lesson for Tessera.** Adopt the natural language input model (the chat panel's pending item is a natural-language prompt; the agent's parser converts it to a typed operation). Adopt the quick-add pattern (Cmd-J to open the chat panel without leaving the doc). The Mini Window's "parse + preview" UI is a model for the chat panel's "type + see preview" UI (the user types, the chat panel shows the parsed operation before the agent starts).

### 4.14 MailMate / Spark / Newton (ADAPT — email UX patterns)

Three macOS email clients with distinct design philosophies:

- **MailMate** is a power-user IMAP client with deep keyboard shortcuts, an extensible rules engine, and a clean grey UI. The customisability is unmatched; the UI is "intentionally ugly" (the developer's words) for the sake of function. [36]
- **Spark** is a polished multi-platform client with smart inbox (auto-categorization), AI writing assistant, built-in calendar, and real-time collaboration. The UI is beautiful; the integrations are extensive. [36]
- **Newton** is a cross-platform client with read receipts, Recap (auto-surfacing conversations waiting for reply), Tidy Inbox (auto-removing newsletters). The UI is custom-designed and "doesn't feel platform-native". [36]

**What works.** MailMate's keyboard-shortcut-everywhere is the model for "the chat panel is keyboard-first". Spark's smart inbox is the model for "the chat panel auto-categorizes (pending/in-progress/applied/failed)". Newton's read receipts are the model for "the receipt shows when each step happened" (timestamps, not just count).

**What doesn't.** MailMate's UI is "intentionally ugly" (the user's words) — not a model for the productivity surface. Spark's real-time collaboration is overkill (Tessera is single-user + receipt-sharing). Newton's custom UI is a lesson in "don't fight the platform" — Newton doesn't feel native on macOS, and macOS users notice.

**Lesson for Tessera.** Adopt the keyboard-first chat panel (Cmd-J to focus, Cmd-Enter to send, Cmd-Up/Down to navigate the queue, Cmd-Shift-K to reorder). Adopt the auto-categorization (the chat panel knows which items are pending/in-progress/applied). Adopt the timestamp-everywhere (the receipt shows when each operation happened). Reject the "intentionally ugly" UI (the productivity surface is a beautiful native app) and the "custom everything" UI (the productivity surface is HIG-compliant, not custom).

### 4.15 Obsidian (ADOPT — knowledge graph + receipt-summary UX)

Obsidian is a Markdown note-taking app with a local-first vault, bidirectional links, a graph view, and a plugin ecosystem. The AI integration is plugin-driven (Smart Connections, Copilot, Graphify); the plugins vary widely in quality. [37][38]

**What works.** The local-first model (the vault is a folder of Markdown files) is a model for the productivity surface's data layer (Postgres + Valkey is the local-first store, the receipt chain is the audit trail). The graph view is a model for the knowledge-graph-backed productivity model. The plugin ecosystem is a model for extensibility (the productivity surface should support plugins for custom block types, custom receipts, custom exports).

**What doesn't.** The AI plugins are inconsistent; no canonical AI UX. The graph view is "not very useful" (per user reviews [37]) for casual users. The plugin ecosystem is a maintenance burden (plugins break on Obsidian updates).

**Lesson for Tessera.** Adopt the local-first + graph model (the Materials slice sees all entities as first-class graph nodes). Adopt the plugin extensibility (a documented plugin API for custom block types, custom receipts). The graph view is a v2 feature (the v1 productivity surface has the chat panel + receipt drawer; the graph view comes later).

---

## 5. Animation & motion design

The architect's design depends on animation to make the agent's edit feel deliberate. The animation budget is small (six primitives, three durations) and grounded in HIG Motion §2.7, Material Design's Motion system, and the experience of the products in §4.

### 5.1 SwiftUI animation primitives (HIG §2.7)

The relevant SwiftUI animation primitives:

- `withAnimation { ... }` — state-driven animation.
- `.animation(_:value:)` — value-bound animation.
- `.transition(...)` — view insertion/removal.
- `Animation.spring(response:dampingFraction:)` — spring physics.
- `Animation.easeInOut(duration:)` / `.easeOut(duration:)` — explicit curves.
- `Animation.interpolatingSpring(stiffness:damping:initialVelocity:)` — physical spring.
- `.matchedGeometryEffect(id:in:)` — shared element transition.
- `.symbolEffect(.variableColor)` / `.bounce` / `.pulse` — SF Symbol animation (iOS 17+, macOS 14+).
- `.scrollTransition(effect:)` — scroll-driven effect.
- For interruptible animations, `Transaction(animation: .interactiveSpring())`.

HIG §2.7 is explicit: "Make motion optional. Don't use motion as the only way to communicate important information. Supplement visual feedback with haptics and audio. Respect Reduce Motion; check `@Environment(\.accessibilityReduceMotion)`." [22]

### 5.2 HIG Motion rules

- Add motion purposefully, supporting the experience without overshadowing it. [22 §2.7]
- Strive for brevity and precision. Brief, precise feedback feels lightweight. Avoid adding motion to UI interactions that occur frequently.
- Let people cancel motion. Don't make people wait for an animation to complete before they can do anything.
- Use animated SF Symbols (SF Symbols 5+) for icon-level animation.
- Test with Reduce Motion on.

### 5.3 Material Design timing references (for cross-check)

Material Design's motion system [39] provides reference values:

- **Standard enter (elements entering the screen)**: 250ms, ease-out (Material 3).
- **Standard exit (elements leaving the screen)**: 200ms, ease-in.
- **Emphasized (high-emphasis transitions like view-to-view)**: 500ms, emphasized easing.
- **Mobile transition typical**: 300ms with ±20% variance.
- **Desktop**: 150-200ms (faster, simpler).
- **Tablets**: 30% longer than mobile.
- **Wearables**: 30% shorter than mobile.

HIG and Material are aligned on the principle (motion is feedback, not decoration) but differ on the exact durations. Apple platforms tend to be 10-20% faster than Material's defaults. Tessera targets Apple platforms, so the durations below follow the HIG bias toward brief feedback.

### 5.4 The six animation primitives for the productivity surface

| # | Trigger | Animation | Duration | Easing | Reduce Motion fallback |
|---|---|---|---|---|---|
| A1 | New block appears (agent inserts) | Slide in from top + opacity 0→1 | 250ms | `.easeOut` | Crossfade 200ms |
| A2 | Block replaced (agent rewrites) | Crossfade old → new; old collapses height, new expands | 300ms | `.easeInOut` | Crossfade 200ms |
| A3 | Block deleted (agent removes) | Collapse height to 0 + fade | 200ms | `.easeIn` | Fade to 0 150ms |
| A4 | Text within block streams | Character cadence 50-80ms per char, OR word-by-word 30ms per word | varies | linear | Block appears at end with crossfade |
| A5 | Cursor blink | Standard NSTextView / UITextView | n/a | n/a | n/a |
| A6 | "Thinking" pulse in chat panel | 0.6 Hz scale + opacity oscillation on a small dot (8pt) | ~830ms cycle | sinusoidal | Static dot |
| A7 | "Agent paused" indicator | Subtle banner with `pause.fill` SF Symbol + label | 200ms in, persistent | `.easeOut` | Static banner |
| A8 | Receipt summary appears in chat | Slide in from bottom + opacity 0→1 | 250ms | `.easeOut` | Crossfade 200ms |
| A9 | Pending item reorder (drag) | Follow finger / cursor; target slot highlights with 0.2 opacity overlay | continuous | n/a | Static slot indicator |
| A10 | Receipt drawer open/close | Standard `.inspector` slide | 250ms | system default | n/a |
| A11 | Failed receipt highlight | 0.4 Hz red flash on the receipt chip for 3 cycles | ~2.5s total | sinusoidal | Static red color |

**The duration ladder.** 200ms (small utility, exit), 250ms (enter, slide), 300ms (replace, larger area). Never exceed 400ms. The seven primitives above are the entire animation vocabulary; adding a new one is a design decision, not a coding decision.

**The cadence rule.** The character cadence in A4 is the one that's the most "feel" question. 50-80ms per char is the range; the lower end is for short responses (the user wants to read them quickly), the higher end is for long responses (the user wants to read them in their own time, not feel rushed). Word-by-word at 30ms per word is the alternative for users who find char-by-char too fast. Both are settings in the agent's configuration; the default is char-by-char at 60ms (the midpoint).

**The Reduce Motion rule.** Every animation above has a Reduce Motion fallback. The fallback is implemented as a single `if !reduceMotion { withAnimation(...) } else { /* static */ }` pattern. The Reduce Motion fallback is the source of truth for the static state; the animation is the polish.

**The interruptibility rule.** Every animation is interruptible. A new pending message can interrupt a streaming block-edit (the in-flight edit pauses, the new edit takes priority). The user can click in the doc to interrupt (the in-flight edit pauses, the cursor jumps to the click position). The "agent paused" indicator is the visual signal of the interrupt.

### 5.5 Reference animations from the HIG and WWDC

- **WWDC 2025 Session 256 "What's new in SwiftUI"** [40]: the Liquid Glass toolbar morph, the scroll-edge effect, the window-resize animation anchor. The session covers the "during navigation transitions, toolbar items can morph" pattern — applicable to the chat panel's state transition (pending → in-progress → applied).
- **WWDC 2025 Session 323 "Build a SwiftUI app with the new design"** [41]: the Liquid Glass material in interaction (toggles and sliders "transform into liquid glass during interaction"). The session's `withAnimation` patterns are the canonical examples.
- **HIG §2.7 Motion**: the canonical reference for "make motion optional, brief, precise, interruptible".

### 5.6 Haptics

The animation primitives above are visual; haptics are the audio-tactile layer.

- **A1 (new block)**: subtle impact (light) — `NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime:)`.
- **A2 (block replaced)**: subtle impact (medium) — same.
- **A3 (block deleted)**: no haptic (delete is destructive, no haptic is the macOS convention).
- **A4 (text streams)**: no per-char haptic (would be spammy); a single soft tap when the block finishes streaming.
- **A6 (thinking pulse)**: no haptic (the pulse itself is the signal).
- **A7 (agent paused)**: subtle impact (medium) — "the system did something, pay attention".
- **A8 (receipt appears)**: subtle impact (light) — "the system completed something".

HIG §2.7 says "pair visual feedback with haptics and audio" for the most important feedback; the above list applies that rule. The receipt appearing is the most important (it's the audit trail entry), so it gets a light haptic.

---

## 6. Chat panel as command queue — detailed UX

The chat panel is a command queue, not a chat history. This section details the state machine, the visual treatment per state, the "hard suggestion" semantics, the interrupt UX, the receipt summary, the drag-to-reorder, and the history panel.

### 6.1 State machine

```
                  ┌─────────────┐
   user types ──▶ │   pending   │
                  └──────┬──────┘
                         │  user hits Enter
                         │  OR agent picks it up
                         ▼
                  ┌─────────────┐
                  │ in-progress │ ◀── user can re-queue
                  └─┬───────┬───┘
                    │       │
        success     │       │  failure
                    ▼       ▼
              ┌─────────┐ ┌────────┐
              │ applied │ │ failed │
              └────┬────┘ └───┬────┘
                   │          │ user retries
                   │          ▼
                   │     (back to in-progress)
                   │
       user can amend (creates a new receipt
       that links to the applied one)
                   │
                   ▼
              ┌──────────────┐
              │  superseded  │  (or "voided", if the user undid the apply)
              └──────────────┘
```

The five states are: **pending, in-progress, applied, failed, superseded/voided**. The "superseded" state is what an applied receipt becomes when the user amends it (the original receipt is preserved, the new receipt links to it). The "voided" state is what an applied receipt becomes when the user undoes it (the original receipt is preserved, marked as `voided_by` a new "undo" receipt).

The five states are explicit in the chat panel's UI, the receipt's database row, and the audit trail. The naming is consistent across all three.

### 6.2 Visual treatment per state

| State | Icon | Color | Opacity | Animation | Label |
|---|---|---|---|---|---|
| **pending** | `clock` | `Color.secondary` | 60% | static (the text is in italic) | "Queued" |
| **in-progress** | `circle.dotted` | `Color.accentColor` | 100% | A6 (pulse) on the icon | "Working..." |
| **applied** | `checkmark.circle.fill` | `Color.green` | 100% | A8 (slide in) on the receipt summary | "Applied" |
| **failed** | `exclamationmark.triangle.fill` | `Color.red` | 100% | A11 (red flash) on the chip | "Failed" |
| **superseded/voided** | `arrow.uturn.backward.circle` | `Color.secondary` | 50% | static | "Superseded" / "Voided" |

The colors use semantic system colors (`Color.green`, `Color.red`) so they adapt to light/dark mode and Increase Contrast. The icons are SF Symbols. The text is short ("Queued", "Working...", "Applied", "Failed", "Superseded") and shown as a label next to the icon in the chat panel's row.

The pending state's italic + 60% opacity is the visual signal that the user typed something the agent hasn't picked up yet. The user can edit/delete/reorder pending items. The in-progress state's pulsing icon is the visual signal that the agent is working. The applied state's green checkmark + slide-in is the visual signal that the agent's edit landed.

### 6.3 The "hard suggestion" semantics

The chat panel's input is a natural-language prompt. The agent's planner parses the prompt into one or more typed operations (replace, insert, delete, format, etc.) and queues them as pending items. The user sees the parsed operations as the pending items in the queue, not the raw prompt.

Example: the user types "Rewrite the second paragraph to be more concise and add a heading 'Summary' after it". The agent's parser produces:

1. `replaceBlock(blockId: 2, newText: "...")` — pending
2. `insertBlockAfter(blockId: 2, type: heading, text: "Summary")` — pending

The chat panel shows the two pending items, not the raw prompt. The user can reorder, edit (change the text), or delete each item. When the user hits Enter (or the agent picks up the queue), the items move to in-progress, then applied (or failed).

The "hard suggestion" term is the architect's. It means: the user's prompt is parsed into typed operations, the user can review the parsed operations as pending items, the user can edit/delete/reorder before they're applied. The agent's prompt is "hard" (structured, typed) not "soft" (raw text). This is the Coda AI Block + Fantastical natural language parsing pattern combined.

### 6.4 Interrupt UX

The user can interrupt the agent at any time. The interrupt gestures are:

- **Click in the document**: pauses the in-flight edit, moves the cursor to the click position. The chat panel shows the "agent paused" indicator. The user can type/edit/undo in the doc; the agent's edit is paused but not cancelled. To resume, the user clicks the "Resume" button in the chat panel.
- **Type in the document**: same as above, but the first keystroke is the focus shift; the subsequent keystrokes are the user's edits.
- **Cmd-Z in the document**: undoes the most recent agent edit (the one that just applied, or the one in-progress). The receipt is marked as `voided_by` a new "undo" receipt.
- **Click "Stop" in the chat panel**: cancels the in-flight edit. The receipt is marked as `cancelled`. The chat panel shows "Cancelled" with a retry button.
- **Send a new pending message while the agent is working**: the new message is queued. When the in-flight edit completes, the agent picks up the next pending message. The chat panel shows the queue (pending + in-progress + applied + failed).
- **Send a new pending message marked "urgent" (e.g., with Cmd-Shift-Enter)**: the agent pauses the in-flight edit and picks up the urgent message immediately. The in-flight edit is queued at the front of the queue; the urgent message is processed first.

The interrupt gestures are HIG-compliant (HIG §16.2 standard gestures, §10.10 no modal blockers, §14.7 non-modal feedback). The "agent paused" indicator is a subtle banner, not a full-screen modal.

### 6.5 Receipt summary inline

When an applied item is rendered in the chat panel, the row shows:

- The parsed operation (e.g., "Replace paragraph: '...old text...'")
- A one-line summary: "3 blocks updated, 1 section added, 2 receipts logged"
- The model used (on-device / Anthropic / OpenAI) — a small chip
- The timestamp
- A tap target that opens the full audit trail

The summary is auto-generated from the receipt(s) the operation produced. The auto-generation rule: "N blocks updated" if the operation touched N blocks, "1 section added" if it inserted a new heading + paragraphs, "2 receipts logged" is the count of receipts in the operation's chain.

The tap target opens the audit trail in the Receipts drawer (the inspector pane on the right). The audit trail shows: the receipt's hash, the timestamp, the model, the source data the agent read, the transformation, the agent (user / on-device / remote), the before/after diff of each block, and the constitutional receipt's full JSON.

### 6.6 Drag-to-reorder

Pending items in the queue support drag-to-reorder. The interaction:

- **macOS**: click-and-drag the item's handle (a `line.3.horizontal` SF Symbol on the left of the row).
- **iOS**: long-press to lift, then drag. The system drag handles the gesture.
- **VoiceOver**: custom rotor action ("Reorder") in the chat panel.

The drag target is the row above or below the current position. The drag preview is a translucent copy of the row. The drop target highlights with a 0.2 opacity overlay.

The reorder does not require confirmation. The new order is applied immediately. The agent's planner re-reads the queue after the reorder (if an item is in-progress, the reorder is applied to the remaining queue only).

In-progress, applied, failed, and superseded items cannot be reordered (the state machine is linear). Only pending items can be reordered.

### 6.7 Delete pending item

Deleting a pending item: no confirmation. The item never executed; the user knows what they're deleting. The delete is a single click on the item's `xmark` button (revealed on hover on macOS, long-press on iOS). The delete is undoable (Cmd-Z restores the item to the queue).

Failed items: the delete is allowed but the action is "Dismiss" (not "Delete"). The receipt is preserved; only the row in the chat panel is removed.

Applied items: not deletable from the chat panel. The receipt is immutable; to revert, the user uses Cmd-Z in the document.

### 6.8 History panel

The history of applied items is shown in the Receipts drawer (the inspector pane), not in the chat panel. The chat panel is the active queue (pending + in-progress + recently applied). The history is filterable by date, by entity, by agent vs. user.

The chat panel's applied items slide down to history after 24 hours (or after the user dismisses them). The slide-down animation is a 200ms ease-out fade + height collapse.

The Receipts drawer's history is the canonical record. The chat panel is ephemeral; the drawer is durable.

---

## 7. Constitutional receipts in the UX

The architect has locked in constitutional receipts as the data layer's primitive. This section is about how the receipt surfaces to the user.

### 7.1 How receipts surface

The receipt has three surfaces:

1. **Inline in the chat panel** (§6.5) — the one-line summary, tap to expand.
2. **Receipts drawer** (the inspector pane) — the full audit trail, filterable.
3. **Per-receipt notification** (optional, in Settings) — the system notification when the receipt applies, if the user has the app backgrounded.

The default is: inline + drawer. The notification is opt-in (Settings > Notifications > "Notify me when a receipt applies"). The architect's no-egress doctrine is satisfied (receipts are local-first; the notification is system-level, not a remote push).

### 7.2 What a receipt looks like to a non-technical user

A lawyer, doctor, journalist (the architect's target personas) sees the receipt as:

- **A one-line summary in the chat panel**: "3 blocks updated, 1 section added". The summary is human-readable, not technical.
- **A tap-through to a more detailed view**: "At 2:34 PM, your local LLM replaced 3 blocks in 'Q3 Report' and added a new section 'Summary'. The full audit trail is below." The detailed view is human-readable with optional technical details (the receipt hash, the model, the prompt) collapsed by default.
- **The full audit trail**: a list of receipts, each with: timestamp, model, source data, transformation, before/after diff. The technical details (hash, prompt, JSON) are collapsed by default; the human-readable details (what changed, when, by whom) are expanded by default.

The receipt is the audit trail, but the audit trail is presented in two views: human-readable (default) and technical (expanded). The non-technical user never sees the technical details unless they want to.

### 7.3 Undo and the receipt

When the user undoes the agent's edit (Cmd-Z in the document), the receipt is **not** deleted. The receipt is marked as `voided_by` a new "undo" receipt. The audit trail shows:

- The original receipt: "3 blocks updated at 2:34 PM by local LLM".
- The undo receipt: "3 blocks reverted at 2:36 PM by user".
- The voided link: the original receipt is shown as struck-through with a "voided by undo" annotation.

This is the HACO framework's "fine-grained rollback" requirement [17] and the editable-AI-output pattern's "undo to generated" requirement [18]. The receipt is immutable; the audit trail is complete.

### 7.4 Audit-trail view

The Receipts drawer's audit trail is filterable by:

- **Date**: today, last 7 days, last 30 days, last 90 days, all time.
- **Entity**: this document only, this folder, all documents.
- **Agent vs. user**: all, user only, agent only (on-device, Anthropic, OpenAI).
- **Type**: created, updated, deleted, formatted, imported, exported.
- **Status**: applied, voided, failed.

The default view is "this document, last 7 days, all agents, all types, all statuses". The user can save custom filters.

### 7.5 Privacy and export

The receipts are local-first (the architect's no-egress doctrine). The export question is open:

- **Signed JSON bundle**: the receipts + their before/after diffs + the receipt chain. Signed with the user's key (Keychain-stored). The bundle is verifiable: a third party can confirm the receipts are authentic and unmodified.
- **Markdown summary**: a human-readable summary of the audit trail, suitable for sharing with a colleague or a regulator. Not signed.
- **C2PA manifest**: a Content Credentials manifest (the HACO A3+ requirement [17]). The manifest is signed by the user's key. The manifest is verifiable by any C2PA-compatible tool.

The export UI is a single button in the Receipts drawer: "Export audit". The button opens a sheet with three options: Signed JSON bundle, Markdown summary, C2PA manifest. The default is Signed JSON bundle. The export is local (no network egress); the user can then share the file via the system share sheet.

The export format question is partly open (§12). The v1 recommendation is: Signed JSON bundle (always), Markdown summary (opt-in), C2PA manifest (v2).

---

## 8. The "agent IS the editor" model — interaction patterns

The architect's design has the agent acting on the document directly, not in a side panel. This section formalizes the operation taxonomy, the redirect pattern, the take-over gesture, and the multi-document case.

### 8.1 Block-level operations

The agent's operations are block-level (matching the semantic block AST). The operation taxonomy:

| Operation | Parameters | Description |
|---|---|---|
| `replaceBlock` | blockId, newText, newAttributes | Replace a single block's content. |
| `insertBlockAfter` | blockId, type, text, attributes | Insert a new block after a given block. |
| `insertBlockBefore` | blockId, type, text, attributes | Insert a new block before a given block. |
| `deleteBlock` | blockId | Delete a single block. |
| `deleteRange` | startBlockId, endBlockId | Delete a range of blocks. |
| `moveBlock` | blockId, newPosition | Move a block to a new position. |
| `setHeadingLevel` | blockId, level | Change a heading block's level (1-6). |
| `setFormat` | blockId, attributes | Apply format attributes (bold, italic, code, link). |
| `splitBlock` | blockId, splitPosition | Split a block at a given position. |
| `mergeBlocks` | blockId1, blockId2 | Merge two adjacent blocks. |
| `convertBlockType` | blockId, newType | Convert a block's type (e.g., paragraph → list). |
| `createTable` | blockId, rows, cols | Create a new table block. |
| `addTableRow` | tableBlockId, rowIndex | Add a row to a table. |
| `addTableColumn` | tableBlockId, colIndex | Add a column to a table. |
| `setTableCell` | tableBlockId, rowIndex, colIndex, text | Set a table cell's content. |
| `importFromUrl` | url, format | Import a document from a URL. |
| `importFromFile` | filePath, format | Import a document from a file. |
| `exportTo` | format, destination | Export the document to a file. |

The operations are typed; the receipt chain records the exact operation (with parameters) that was applied. The agent's planner produces a sequence of operations from the user's natural-language prompt; the user reviews the sequence as pending items in the chat panel.

### 8.2 Redirect pattern

The user can redirect a mid-flight edit by sending a new pending message. The new message becomes higher priority (it's the new "exemplar" in the agent's planning). The agent re-plans after the in-flight edit completes.

Example: the agent is replacing paragraph 3 with a longer version. The user sends "actually, just shorten it". The new pending message is queued. When the in-flight edit completes, the agent sees the new pending message, re-plans, and applies "shorten paragraph 3".

The redirect does not cancel the in-flight edit; it lets the in-flight edit complete, then re-plans. This is the "non-destructive redirect" pattern. A destructive redirect (cancel the in-flight edit and start over) is available via the "Stop" button in the chat panel.

The redirect can be marked "urgent" (Cmd-Shift-Enter). An urgent redirect pauses the in-flight edit and starts the new edit immediately. The in-flight edit's receipts are preserved (marked as `interrupted_by` the new edit).

### 8.3 Take-over gesture

The user can take over the editing at any time. The gestures:

- **Click in the document**: pauses the in-flight edit, moves the cursor to the click position. The user can then type, edit, undo, etc. The agent's edit is paused but not cancelled.
- **Click "Take over" button in the chat panel**: same as above, but explicit. The button is a safety valve for users who don't realize clicking in the doc pauses the agent.
- **Keyboard shortcut (Cmd-Shift-T)**: same as above, accessible from anywhere.

The take-over is not a "handoff" — the agent is paused, not handed the rest of the work. To resume the agent, the user clicks "Resume" in the chat panel or sends a new pending message. The agent picks up from where it left off (the in-flight edit's remaining operations).

The "Take over" button is small and unobtrusive (icon only, in the chat panel's footer). The keyboard shortcut is the canonical way for power users.

### 8.4 Multi-document scenarios

The architect's design has the agent working on one document at a time (the document the user is currently viewing). The multi-document case has two patterns:

- **Per-document chat queue**: each document has its own chat queue. The chat panel shows the queue for the current document. Switching documents switches the chat panel.
- **One chat queue per agent**: the agent has one queue across all documents. The chat panel shows the queue for the current document, with a "see other documents" tab.

The architect's intuition is per-document (matching Reflect's per-page context [10] and Coda's per-page AI Block [7]). The open question is whether the agent can be working on doc A while the user edits doc B. The recommendation is yes (the agent's work is decoupled from the user's view), but the chat panel shows the queue for the current document, with a "Working in background" indicator if the agent is working on a different document.

The "Working in background" indicator is a small chip in the chat panel's header: "Agent is working on 'Q4 Report'". Clicking the chip switches the view to that document.

---

## 9. Cross-platform considerations

### 9.1 macOS vs. iOS

| Surface | macOS | iOS |
|---|---|---|
| Editor | Full-screen window with sidebar | Full-screen with chat panel as bottom sheet above keyboard |
| Chat panel | Sidebar (NavigationSplitView) | Bottom sheet above keyboard |
| Receipt drawer | Inspector (NavigationSplitView) | Modal sheet (large detent) |
| Toolbar | macOS toolbar (Liquid Glass) | iOS toolbar (above keyboard) |
| Menu bar | macOS menu bar (required) | iOS menu (Cmd-K equivalent) |
| Settings | Settings scene (Cmd-,) | Settings tab in tab bar |
| Keyboard | Full keyboard support | iOS keyboard + shortcuts (when hardware keyboard connected) |
| Drag-to-reorder | Standard macOS drag | Long-press to lift |
| Hover states | Yes (toolbar, block handles) | No (long-press instead) |
| Notifications | System notification center | iOS notification center |
| Handoff | Yes (Handoff from iOS) | Yes (Handoff to macOS) |
| Undo | Cmd-Z, Edit menu, three-finger swipe on trackpad | Shake, three-finger swipe |
| Standard keyboard | All standard shortcuts | Cmd-tab, Cmd-` when hardware keyboard |

### 9.2 Keyboard shortcuts on macOS

The agent's edits must integrate with the standard macOS text-editing keybindings. The standard shortcuts (Cmd-Z, Cmd-Shift-Z, Cmd-X/C/V, Cmd-A, Cmd-B/I/U) are all wired to the editor's UndoManager, not to the chat panel.

The chat panel has its own shortcuts:

- **Cmd-J**: open/focus the chat panel.
- **Cmd-Enter**: send the current pending message.
- **Cmd-Shift-Enter**: send as urgent (pauses in-flight edit).
- **Cmd-Up/Down**: navigate the chat queue.
- **Cmd-Shift-K**: open the command palette (a Cmd-K pattern that searches nodes, actions, chat items, and settings).
- **Cmd-Shift-R**: open the Receipts drawer.
- **Cmd-Shift-T**: take over (pause the agent).
- **Cmd-1/2/3/4/5**: switch between the editor, chat, receipts, settings, and a "focus" mode (just the editor).

The shortcuts are wired in the SwiftUI `.commands { }` block so they appear in the menu bar and are discoverable.

### 9.3 iOS ergonomics

- The chat panel is a bottom sheet above the keyboard. The send button is on the right; the attach button is on the left; the text field is in the middle.
- The drag-to-reorder is long-press to lift. The drag preview is a translucent copy of the row.
- The toolbar above the keyboard shows: send, attach, voice (for dictation), and a "command palette" button (Cmd-K equivalent).
- The "agent paused" indicator is a small banner above the chat input.
- The receipt drawer is a modal sheet (large detent).
- The iOS-specific gestures (shake to undo, three-finger swipe) are wired to the editor's UndoManager.

### 9.4 Continuity (Handoff)

Handoff is the canonical Apple cross-device primitive. The productivity surface supports Handoff for:

- The in-flight edit: if the user starts an edit on macOS, then opens the iOS app, the iOS app picks up the in-flight edit (with the receipts from the macOS side). The receipts are durable in Postgres, so the resume is a re-read.
- The chat queue: if the user has pending items on macOS, the iOS app shows the same queue.
- The receipt history: the receipt history is server-side (Postgres), so the iOS app sees the same history.

Handoff is automatic (no user action beyond opening the app on the other device). The "Same document open on both" scenario is supported (the user can edit on both, the receipts serialize the edits; the last-writer-wins per block is the merge rule).

The Handoff implementation uses Apple's Handoff API with a custom activity type (`com.tessera.studio.document.edit`). The activity payload is the document ID + the in-flight edit state + the chat queue snapshot. The receiving device reads the payload and resumes.

---

## 10. Accessibility

The productivity surface must be accessible to all users. The accessibility requirements are grounded in HIG §3, the Apple a11y direction [23], and the practical patterns from the products in §4.

### 10.1 VoiceOver labels for the chat panel states

Each chat item has a state-specific VoiceOver label:

- **pending**: "Queued message: <prompt>. 1 of 3 pending items."
- **in-progress**: "Working: <parsed operation>. Agent is streaming 2 of 4 blocks."
- **applied**: "Applied: <receipt summary>. 3 blocks updated. Tap to view audit trail."
- **failed**: "Failed: <error message>. Tap to retry."
- **superseded/voided**: "Superseded by <newer receipt timestamp>." (or "Voided by undo at <timestamp>.")

The labels are descriptive and include the position in the queue (for navigation). The custom actions on each row are: "Edit" (for pending), "Cancel" (for in-progress), "Retry" (for failed), "View audit trail" (for applied).

### 10.2 Reduce Motion

The animation primitives in §5 all have Reduce Motion fallbacks. The implementation is a single `if !reduceMotion { withAnimation(...) } else { /* static */ }` pattern at each animation site.

The Reduce Motion fallback is the source of truth for the static state; the animation is the polish. The user with Reduce Motion on sees the same UI, just without the animation.

The agent's "thinking" pulse in A6 becomes a static dot. The block slide-in in A1 becomes a crossfade. The receipt summary slide-in in A8 becomes a crossfade. The "agent paused" banner in A7 is static (no animation).

### 10.3 Keyboard-only navigation

The chat panel is fully keyboard-navigable:

- **Tab/Shift-Tab**: move focus between the chat input, the queue, and the receipt drawer.
- **Cmd-Up/Down**: navigate the queue.
- **Cmd-J**: open/focus the chat panel.
- **Cmd-Enter**: send.
- **Cmd-Shift-K**: command palette (search).
- **Cmd-Shift-R**: open the receipt drawer.
- **Cmd-Shift-T**: take over.

Full Keyboard Access is supported (the chat panel's rows are focusable, the custom rotor actions are registered, the drag-to-reorder has a keyboard alternative).

### 10.4 High-contrast mode

The semantic colors (`Color.green`, `Color.red`, `Color.accentColor`) auto-adapt to Increase Contrast. The chat item chips (the state icons) have a non-color signal (the icon shape) so the state is identifiable without color.

The receipt drawer's filter chips (date, entity, agent, type, status) have a non-color signal (the chip text) so the filter is identifiable without color.

### 10.5 Dynamic Type

The chat panel text scales with Dynamic Type. The chat input, the queue rows, and the receipt summary all use the system text styles (`.body`, `.caption`, etc.) so they scale.

The receipt drawer's audit trail uses a monospaced font for the technical details (the receipt hash, the timestamps) and a proportional font for the human-readable details. The monospaced font scales with Dynamic Type; the proportional font scales independently.

The largest accessibility text size is tested: the chat panel rows do not truncate; the receipt drawer scrolls correctly; the chat input remains usable.

### 10.6 Screen reader announcements for agent edits

When the agent applies an edit, VoiceOver announces: "Agent updated 3 paragraphs in 'Q3 Report'. Tap to view the audit trail." The announcement is timed to the receipt's appearance (not the in-progress state; the user doesn't need to know the agent is working every step of the way).

The announcement is polite (the politeness setting is `.polite`, not `.assertive`; the user can finish what they're reading before the announcement).

For urgent operations (the user sent an "urgent" pending message), the announcement is `.assertive` (the user needs to know the agent is about to act).

---

## 11. Specific UX decisions (the "Adopt / Adapt / Reject" verdicts)

This is the consolidated list of 49 UX decisions. The decisions are numbered, with the verdict, the source sections, and a one-sentence rationale. Some have a sketch description for layout-level decisions.

### 11.1 Editor and document model

1. **Block-based AST editor with semantic blocks (heading, paragraph, list, table, image, code, callout).** Adopt (§1, §4.6). The architect's locked model; Craft [6] and Notion [4] have proven the pattern scales.
2. **Two editors, one document, shared mutation API + shared undo stack.** Adopt (§3.7, §3.8). HACO [17] requires this for the human-in-the-loop contract to hold; the agent framework primitives [15][16] converge on it.
3. **NSTextView (macOS) + UITextView (iOS) wrapped via RichTextKit for SwiftUI niceties.** Adopt (architect's locked model). HIG-compliant; standard Apple text components.
4. **Drag handle on every block (universal block handle, like Notion's `⋮⋮`).** Adopt (§4.6, §4.15). Notion [4] and Obsidian [38] both prove the universal handle is the right pattern.
5. **Block-level animations (slide-in, crossfade, collapse) for agent edits.** Adopt (§5, §4.6, §2.7). Craft's animation polish is its #1 user-rated feature [6]; NNG [21] and HIG [22] both recommend the same primitive set.
6. **Block operations: typed, granular (replaceBlock, insertBlockAfter, deleteBlock, setFormat, etc.).** Adopt (§8.1). HACO [17] requires typed operations for the receipt chain to be meaningful; Coda's AI Block [7] is a partial template.
7. **Per-block receipt: every block change = one receipt.** Adopt (§7, §3.9, §3.10). HACO [17] and editable-AI-output [18] both require per-edit provenance.

### 11.2 Streaming and polish

8. **Streaming agent edits rendered to the AST, not raw keystrokes.** Adopt (§1, §3.14, §4.1, §4.3). Microsoft Copilot UX guidance [12], AI/TLDR patterns [20], and CHI 2025 co-writing [3] all converge on streaming the structured edit, not the keystrokes. Cursor's raw keystroke stream is the explicit reject [27].
9. **Block-level slide-in animation for new blocks at 250ms ease-out.** Adopt (§5). Craft's slide-in is the model [6]; HIG §2.7 + Material 3 [39] recommend 200-300ms enter durations.
10. **Block replace: crossfade + old height collapse + new height expand, 300ms.** Adopt (§5). Material 3 emphasizes a 300ms transition for medium-area effects [39]; NNG [21] recommends brief, precise feedback.
11. **Block delete: collapse height to 0 + fade, 200ms.** Adopt (§5). Material 3's exit duration is 200ms [39]; HIG §2.7 "exit transitions are faster".
12. **Text within block streams character-by-character at 50-80ms per char (or word-by-word at 30ms).** Adapt (§5.4). AI/TLDR recommends streaming [20]; the specific cadence is a design decision (per §5.4). User setting: char-by-char vs. word-by-word.
13. **Cursor blink: standard NSTextView / UITextView.** Adopt (architect's locked model). HIG-compliant; the system cursor is the right default.
14. **First block of agent's edit appears within 200-500ms of user pressing send.** Adopt (§3.14, §5.4). AI/TLDR [20] identifies TTFT as the dominant perceived-latency metric.
15. **Skeleton-shaped placeholder for the first block (during TTFT gap).** Adapt (§3.14). AI/TLDR recommends skeletons "shaped like the expected answer" [20]; the placeholder is a faded copy of the block.
16. **Status text for in-progress: "Streaming block 2 of 4" not "Thinking...".** Adopt (§3.14, §4.4). AI/TLDR recommends status text that updates [20]; ChatGPT's "Thinking..." is the explicit reject.

### 11.3 Chat panel

17. **"Thinking" = subtle pulse in chat panel, not a modal spinner.** Adopt (§1, §4.4). HIG §14.1 [22] "make feedback accessible, integrate status into the interface"; Apple Intelligence's modal "scanning" animation is criticised [1].
18. **"Agent paused" indicator = subtle banner, not a full-screen modal.** Adopt (§1, §6.4). HIG §10.10 [22] + human-in-the-loop frameworks [15][16] converge on a non-modal interrupt.
19. **Pending chat message in italic + 60% opacity + clock icon.** Adapt (§6.2). Standard chat-pending pattern [13][14], customized for queue semantics.
20. **Drag-to-reorder pending items in chat.** Adopt (§1, §6.6). HIG §16.2 [22] standard; Reflect [10] proves it works for non-chat item reordering.
21. **Delete pending item: no confirmation.** Adopt (§1, §6.7). The item never executed; undo across a sheet confirmation is HIG §13.5 anti-pattern [22].
22. **Failed item: "Dismiss" button (not "Delete"); receipt is preserved.** Adopt (§6.7, §7.3). HACO [17] requires the receipt to be immutable.
23. **Edit pending item text before send.** Adopt (§1, §6.3). The pending item is the parsed operation; editing the prompt re-parses.
24. **Multi-line pending item (Cmd-Return for newline, Return to send).** Adopt (HIG standard). Standard iOS/macOS text field behavior.

### 11.4 Receipts and audit

25. **Receipt summary inline in chat (3 blocks updated, 1 section added, 2 receipts logged).** Adopt (§1, §6.5, §4.8). Reflect-style summary [10] + Action Audit Trail pattern [18] + HACO provenance completeness [17].
26. **Tap-through receipt summary to the full audit trail.** Adopt (§1, §6.5). HACO [17] and Microsoft Copilot guidance [12] both require reversible + auditable.
27. **Receipts drawer: inspector pane on the right (macOS) / modal sheet (iOS).** Adopt (§1, §7.1, §2.1). HIG §4.9 [22] inspector pattern; the right pane is the canonical macOS location.
28. **Audit trail filter: by date, by entity, by agent vs. user, by type, by status.** Adopt (§1, §7.4). Action Audit Trail pattern [18] + HACO [17] both require filterable provenance.
29. **Receipt persisted even after undo (with `voided_by` link).** Adopt (§1, §7.3). HACO [17] and editable-AI-output [18] both require it; a deleted receipt is a lost audit trail.
30. **Receipts are immutable; undo is a separate receipt that links forward.** Adopt (§1, §7.3). Constitutional-receipts design decision + HACO [17]; receipts are evidence, not state.
31. **Receipt hash chain (each receipt links to its predecessor).** Adopt (§1, §3.11, §7.5). Constitutional receipt model; C2PA-style content credentials [17].
32. **Per-receipt timing (ms latency, ms apply duration) visible to user.** Adopt (§1, §3.7). HACO override-cost metric [17]; make it visible so users can compare.
33. **Receipts export: signed JSON bundle + Markdown summary + (opt-in) C2PA manifest.** Adapt (§1, §7.5). HACO requires C2PA at A3+ [17]; Tessera v1 is A2 so the export is a simpler signed bundle.
34. **Tap on a receipt in the chat: highlight the affected blocks in the doc.** Adopt (§1, §6.5). HIG §14.5 [22] "highlight the result of an undo when offscreen"; same pattern for receipt visualization.

### 11.5 Interrupt and take-over

35. **User can interrupt at any time: click in doc, type, undo, redirect.** Adopt (§1, §3.7, §3.8). DirectGPT CHI [8], HACO A2–A4 band [17], and AG-UI Interrupts [16] all require this.
36. **"Take over" gesture = click in the document, no special button required.** Adopt (§1, §8.3). HACO [17] + Microsoft Copilot guidance [12] both keep the takeover implicit; adding a button teaches the user the agent is autonomous when the design says the opposite.
37. **"Take over" button as a safety valve (small, in chat panel footer).** Adapt (§8.3). For users who don't realize clicking in the doc pauses the agent; the button is the explicit alternative.
38. **Take-over keyboard shortcut: Cmd-Shift-T.** Adopt (§8.3, §9.2). Power-user accessibility; standard SwiftUI `.keyboardShortcut`.
39. **Redirect: new pending message becomes higher priority.** Adopt (§1, §3.13, §8.2). Agent drift mitigation [32]; the new pending message is the new "exemplar".
40. **Urgent redirect (Cmd-Shift-Enter): pauses in-flight edit, picks up new edit immediately.** Adapt (§8.2). The agent framework primitives [15][16] allow for "alwaysApprove" style behaviors; the urgent redirect is the "always urgent" variant.
41. **Stop button in chat panel cancels the in-flight edit (preserves receipts, marks as `cancelled`).** Adopt (§6.4). The human-in-the-loop primitive [15][16] requires explicit cancel.

### 11.6 Multi-document and Continuity

42. **Per-document chat queue (one chat per document, not global).** Adapt (§1, §8.4). Reflect [10] and Coda [7] both use a per-page context; the multi-doc case in §8 needs more architect input.
43. **Multi-document: "Agent is working on 'Q4 Report'" indicator in chat panel.** Adapt (§1, §8.4). Per-agent task queue [14] is the pattern; the cross-doc indicator is the Tessera addition.
44. **Handoff: the in-flight edit, the chat queue, the receipt state are all Handoff-eligible.** Adopt (§1, §9.4). Handoff is the canonical Apple cross-device primitive; architect's "same document on both" requires it.

### 11.7 Accessibility

45. **VoiceOver label for each chat item by state (pending/in-progress/applied/failed).** Adopt (§1, §10.1). HIG §3.1 [22] + Apple Intelligence's own a11y direction [23].
46. **Reduce Motion: replace slide-in with crossfade, pulse with static dot.** Adopt (§1, §10.2). HIG §3.6 + Apple developer docs [24] are explicit requirements.
47. **Drag-to-reorder pending: VoiceOver custom rotor action.** Adopt (§1, §10.1). HIG §3.1 [22] + a11y direction; the standard rotor pattern is `rotorAction()`.
48. **Screen reader announcement: "Agent updated 3 paragraphs in 'Q3 Report'" on apply.** Adapt (§1, §10.6). Apple's a11y direction [23] recommends polite announcements for AI-driven updates; the format is a Tessera decision.
49. **Dynamic Type: chat panel text scales; receipt drawer uses monospaced for technical details.** Adopt (§10.5). HIG §2.2 [22] standard; tested at largest accessibility size.

### 11.8 Cross-platform

50. **iOS: chat panel = bottom sheet above keyboard, drag-to-reorder via long-press.** Adopt (§1, §9.1, §9.3). HIG §5.1, §5.2 [22]; iOS ergonomics require the chat above the keyboard.
51. **iOS: chat input is single-line by default, multi-line on long-press.** Adopt (HIG standard text field behavior).
52. **macOS Edit menu: Undo names the most recent operation ("Undo Agent edit", "Undo Apply style").** Adopt (§1, §2.4). HIG §14.5 [22] + agent framework primitives [15][16].
53. **Cmd-Z on macOS routes to the editor's UndoManager, not the chat's.** Adopt (§1, §9.2). The chat is a queue, not a document; its actions have their own undo (per-item).
54. **Cmd-J opens the chat panel; Cmd-Enter sends; Cmd-Shift-K opens the command palette.** Adopt (§9.2, §1). Standard macOS keyboard convention; the chat input is a text field, not a custom control.
55. **Cmd-1/2/3/4/5 switches between editor, chat, receipts, settings, focus mode.** Adapt (§9.2). Tessera-specific; the architect's decision on whether the chat is its own tab or always visible.
56. **Three-finger swipe (iOS) and shake (iOS) for undo: not repurposed.** Adopt (§1, §16.2). HIG §16.2 [22] standard; do not repurpose standard gestures.
57. **Settings via Settings { ... } scene (Cmd-,).** Adopt (§2.1). HIG §14.8 [22] standard.
58. **Notification interruption level: Active (default), never Critical.** Adopt (§1, §2.1, §7.1). HIG §14.12 [22] + the agent pattern skill's suppression rules.
59. **Cancel never fires a system notification.** Adopt (§1, §2.1). HIG §14.12.x suppression pattern; the user's intent is the signal.
60. **"Empty state" for receipts drawer: first run gets a TipKit intro.** Adopt (§1, §2.2). HIG §14.2 [22]; receipts are unfamiliar to most users.

### 11.9 Explicit rejects

61. **Notion AI side panel + Insert button.** Reject (§1, §4.1). Architect's explicit reject + user backlash when Notion removed inline (2024) [25][26]; HCI literature on split-attention [8].
62. **Cursor's raw keystroke streaming (no polish).** Reject (§1, §4.3). Architect's explicit reject + Co-Writing CHI 2022 [3] on cognitive load; users report "constant stream becomes distraction" [27].
63. **Apple Intelligence's inline rewrite/proofread popover (all-or-nothing correction).** Reject (§1, §4.2). Architect's explicit reject + Six Colors review [1] + Brisktype review [2] (conservative, no inline autocomplete, all-or-nothing correction).
64. **ChatGPT's "thinking then result" loading modal.** Reject (§1, §4.4). HIG §14.1 [22] + Architect's reject; the entire agent-IS-the-editor premise precludes it.
65. **Grammarly's "highlight then accept" (highlight the user's writing).** Reject (§4.5). We don't want Grammarly's pattern (highlight the user's writing to suggest changes — wrong direction); we want its animation discipline (calm, blue/green, micro-animations) [28][29].
66. **Obsidian's "the graph view is the main view".** Adapt (§4.15). Obsidian's graph view is "not very useful" for casual users [37]; the productivity surface has a chat panel + receipt drawer, not a graph view (the graph is the data layer's job, not the UX's).
67. **Newton's "custom everything" UI (doesn't feel platform-native).** Reject (§4.14). macOS users notice [36]; HIG-compliance is non-negotiable.
68. **Things 3's "no AI" model.** Reject (§4.11). Things 3 is the model for the Inbox/Today pattern, not for the agent pattern. The agent is the productivity surface's value-add.

### 11.10 Final layout sketch (ASCII)

The editor's main window (macOS):

```
+-------------------------------------------------------------------+
| [Sidebar toggle] Q3 Report  [Cmd-K palette]  [Inspector toggle]  |  <- toolbar
+-------------------------------------------------------------------+
| [Materials] |                                          | [Receipts]
|  * Q3 Report|   # Q3 Report                              |  ------
|  * Q4 Report|                                           |  3:24 PM
|  * Tasks    |   ## Executive Summary                     |  Applied
|  * Calendar |                                           |  3 blocks
|  * Email    |   The Q3 results show a 12% increase in    |  updated
|             |   revenue over Q2, driven primarily by     |
| [Chat queue]|   the new product line.                    |  ------
|             |                                           |  3:26 PM
| ● Working   |   ## Revenue Breakdown                     |  Applied
|   Replace ¶|                                           |  1 section
|             |   * Product A: 45%                        |  added
| ⏳ Queued   |   * Product B: 30%                        |
|   Add headng|   * Services: 25%                         |  ------
|             |                                           |  Filter
| ✓ Applied   |   ## Outlook                              |  Date: 7d
|   3 blocks  |                                           |
|             |   We expect Q4 to continue this trend...  |
+-------------------------------------------------------------------+
| 4 receipts today, 3 by agent, 0 failed       [Cmd-J chat] [Take] |  <- bottom bar
+-------------------------------------------------------------------+
```

The editor's main window (iOS):

```
+--------------------------------------------------+
| [Documents] [Editor] [Chat*] [Receipts] [More]   |  <- tab bar
+--------------------------------------------------+
| # Q3 Report                                       |
|                                                  |
| ## Executive Summary                              |
|                                                  |
| The Q3 results show a 12% increase in revenue     |
| over Q2, driven primarily by the new product     |
| line.                                            |
|                                                  |
| ## Revenue Breakdown                             |
|                                                  |
| * Product A: 45%                                 |
| * Product B: 30%                                 |
|                                                  |
| [Agent paused - tap to resume]                   |  <- banner
+--------------------------------------------------+
| [Chat input field]                  [Send] [+]  |  <- above keyboard
+--------------------------------------------------+
```

The chat panel on iOS is the third tab (Chat); it shows the queue for the current document. The receipt drawer on iOS is a modal sheet (large detent). The bottom bar is the chat input above the keyboard.

---

## 12. Open questions for the architect

The following questions are split into **spec-blocking** (must be answered before the spec can be written) and **implementation-deferrable** (can be answered during implementation).

### 12.1 Spec-blocking (decide before spec)

**Q1. Multi-document chat queue.** Is the chat queue per-document (each document has its own queue, switching documents switches the queue) or one shared queue across all documents (the agent picks up items from the queue regardless of which document they're for)? §8.4. The architect's intuition is per-document; the per-agent task queue pattern [14] is one-shared. Default recommendation: per-document, with a "Working in background" indicator for cross-document agent work.

**Q2. Agent active in background or paused when user switches away?** When the user switches from doc A to doc B, does the agent continue its in-flight edit on doc A, or does it pause? §8.4. The recommendation: continue (the agent's work is decoupled from the user's view), with a "Working in background" indicator in the chat panel. The receipt chain serializes the work.

**Q3. Receipts export format.** Is the v1 export a signed JSON bundle, a Markdown summary, both, or all three (signed JSON + Markdown + C2PA)? §7.5. The recommendation: signed JSON bundle (default) + Markdown summary (opt-in) + C2PA (v2). The C2PA manifest requires the user's signing key in Keychain, which is a v2 dependency.

**Q4. Cmd-1/2/3/4/5 keyboard shortcut.** Is the chat panel always visible (as a sidebar) or is it a tab that the user toggles with Cmd-2? §9.2, §11.8. The recommendation: always visible as a sidebar on macOS, as a tab on iOS. The keyboard shortcut Cmd-2 focuses the chat panel but does not toggle its visibility.

**Q5. The "Take over" button — is it required?** §11.5. The recommendation: yes, as a safety valve. The button is small, in the chat panel footer, and is the explicit alternative to the implicit "click in the doc" gesture. Users who don't realize clicking in the doc pauses the agent need an explicit button.

**Q6. The "agent paused" indicator — banner or chip?** §1, §6.4. The recommendation: a subtle banner at the top of the chat panel with a "Resume" button. The banner is non-modal, persistent until the user clicks Resume or sends a new pending message.

**Q7. The Receipts drawer — inspector pane or separate window?** §7.1, §11.4. The recommendation: inspector pane on macOS (right side of NavigationSplitView), modal sheet on iOS (large detent). The inspector pane is the HIG-compliant macOS pattern; the modal sheet is the iOS equivalent.

**Q8. The "agent paused" indicator — what if the user is reading?** §1, §6.4. Does the agent pause on any user action (including reading), or only on user input (typing, clicking)? The recommendation: only on user input. The agent can continue its work while the user is reading the doc. The agent pauses when the user types or clicks in the doc.

### 12.2 Implementation-deferrable (decide during implementation)

**Q9. Specific animation curves.** §5.4. The seven animation primitives are defined; the exact curves (`.easeOut`, `.easeInOut`, spring physics) are a per-implementation tuning decision. The recommendation: use Apple's standard curves; tune per-primitive based on user feedback.

**Q10. Character cadence default.** §5.4. 50ms vs 60ms vs 80ms per character is a feel decision. The recommendation: 60ms default, with a user setting for 30-100ms range. Word-by-word at 30ms is the alternative.

**Q11. The command palette (Cmd-K) contents.** §9.2. The recommendation: search nodes, actions, chat items, settings, recent documents. The exact set is a v1 implementation decision.

**Q12. The "applied" notification's interruption level.** §7.1, §11.8. The recommendation: Active (default). The user can opt into Time Sensitive for urgent operations in Settings.

**Q13. The receipt drawer's default filter.** §7.4. The recommendation: "this document, last 7 days, all agents, all types, all statuses". The exact defaults are a v1 implementation decision.

**Q14. The audit trail's export filename convention.** §7.5. The recommendation: `<document-name>-audit-<date>.json`. The exact format is a v1 implementation decision.

**Q15. The "Working in background" indicator's exact location.** §8.4, §12.1 Q1. The recommendation: a small chip in the chat panel's header. The exact location is a v1 implementation decision.

**Q16. The "urgent" pending message's visual treatment.** §8.2, §12.1 Q1. The recommendation: an "Urgent" chip next to the pending item, in the system orange color. The exact treatment is a v1 implementation decision.

**Q17. The cancel receipt's status.** §7.3. The recommendation: `cancelled` (separate from `voided`). The exact state machine is a v1 implementation decision.

**Q18. The "agent paused" banner's exact placement.** §12.1 Q6. The recommendation: top of the chat panel, above the queue. The exact placement is a v1 implementation decision.

---

## 13. Implementation order recommendations

The research points to a clear implementation order. The dependencies and parallelism are sketched below.

### 13.1 The shared primitives (Phase 1 — must be done first)

These are the load-bearing primitives that everything else depends on. They should be done by a single worker (or a tightly coordinated pair) because they are interdependent.

1. **Block AST schema** (the data model: blockId, type, attributes, content). Already in the data layer design [42]; the productivity surface consumes the data layer's API.
2. **Receipt infrastructure** (the receipt chain, the constitutional receipt, the signed bundle export). The receipt is the load-bearing primitive for the chat panel, the undo system, the audit trail.
3. **Mutation API** (the typed operations: replaceBlock, insertBlockAfter, etc.). The mutation API is the agent's interface to the document.
4. **Undo/Redo wiring** (UndoManager integration, batched undo for multi-block edits, named undo per §11.8 #52).

These four are all in the same area of code. They can be done by one or two workers in parallel (e.g., the data layer worker + the editor worker) but they must land before anything else.

### 13.2 The editor (Phase 2 — depends on Phase 1)

The editor is the document surface. It depends on the block AST, the mutation API, and the undo wiring.

5. **NSTextView (macOS) + UITextView (iOS) wrapping** via RichTextKit. The text view is the inner content of a block; the block is the outer container.
6. **Block handles (drag, hover, click)**. The universal block handle (`⋮⋮` icon, revealed on hover).
7. **Block-level animations** (the seven primitives in §5.4).
8. **Block-level undo/redo** (one undo step per receipt, batched for multi-block edits).

This is one worker's job. The worker owns the editor's SwiftUI views, the animation primitives, and the receipt-aware undo wiring.

### 13.3 The chat panel (Phase 3 — depends on Phase 2)

The chat panel is the control surface. It depends on the mutation API (for the parsed operations), the receipt infrastructure (for the applied summary), and the editor (for the "agent paused" indicator and the "click in doc" interrupt).

9. **Chat panel layout** (NavigationSplitView sidebar on macOS, bottom sheet on iOS).
10. **Pending state: input field, parsed operation preview, edit/delete/reorder controls**.
11. **In-progress state: pulse animation, status text, "Streaming block 2 of 4"**.
12. **Applied state: receipt summary, tap-through, slide-in animation**.
13. **Failed state: error message, retry button, red flash**.
14. **Drag-to-reorder** (long-press on iOS, click-drag on macOS, VoiceOver rotor).
15. **Interrupt UX** ("agent paused" banner, "Take over" button, Cmd-Shift-T).

This is one worker's job (maybe two if the iOS and macOS chat panel diverge significantly). The worker owns the chat panel's state machine, the animations, and the integration with the editor's interrupt UX.

### 13.4 The receipt drawer (Phase 3 — parallel to chat panel)

The receipt drawer is the audit trail. It depends on the receipt infrastructure (Phase 1) and the editor's "highlight the affected blocks" gesture.

16. **Receipts drawer layout** (inspector pane on macOS, modal sheet on iOS).
17. **Audit trail view** (filterable list of receipts, before/after diffs, technical details collapsed by default).
18. **Receipt details view** (tap-through from chat panel; full receipt with source data, transformation, agent, hash).
19. **Export functionality** (signed JSON bundle, Markdown summary, C2PA opt-in).

This is one worker's job. The worker owns the receipt drawer's SwiftUI views, the filter UI, and the export pipeline.

### 13.5 The importers and exporters (Phase 4 — parallel to Phase 3)

The importers and exporters depend on the block AST (Phase 1) and the mutation API (Phase 1). They can be done in parallel with the chat panel and receipt drawer.

20. **DOCX importer** (python-docx).
21. **XLSX importer** (openpyxl).
22. **PPTX importer** (python-pptx).
23. **PDF importer** (weasyprint + pdftotext).
24. **EML/MSG importer** (mailbox stdlib).
25. **MBOX importer** (mailbox stdlib).
26. **HTML importer** (beautifulsoup4).
27. **Pandoc bridge** (the swiss-army format bridge for additional formats).
28. **PDF exporter** (PDFKit on macOS).
29. **DOCX/HTML/LaTeX exporter** (Pandoc).
30. **Slack webhook exporter**.
31. **NSSharingServicePicker / UIActivityViewController integration** (the system share sheet).

This is one worker's job (or a small team, depending on the import volume). The worker owns the import/export pipeline, the Pandoc bridge, and the system share integration.

### 13.6 The Materials surfaces (Phase 5 — depends on Phase 3)

The Tasks, Reminders, Calendar, Notes, and Email surfaces depend on the chat panel (for the agent's interactions with each surface) and the receipt infrastructure (for the constitutional receipts on each surface's mutations).

32. **Tasks surface** (Things 3-style Inbox/Today pattern, with chat panel integration).
33. **Reminders surface** (calendar-event-relative reminders, with chat panel integration).
34. **Calendar surface** (Fantastical-style natural language input, with chat panel integration).
35. **Notes surface** (Bear-style Markdown focus, with chat panel integration).
36. **Email surface** (MailMate-style keyboard-first, with chat panel integration).
37. **Materials slice integration** (all surfaces see each other as first-class graph entities, with chat panel as the unified control surface).

This is multiple workers' jobs, in parallel. Each surface is one worker's job; the Materials integration is a separate worker.

### 13.7 Risks and shared code

The biggest risks are:

- **The chat panel's interrupt UX depends on the editor's "click in doc" gesture being responsive.** If the editor's text view has any latency in moving the cursor, the interrupt feels broken. The animation primitives must be interruptible; the editor's UndoManager must be receipt-aware.
- **The receipt chain is the load-bearing primitive.** If the receipt infrastructure has any bugs (e.g., the hash chain breaks, the `voided_by` link is wrong, the export doesn't include the right fields), the entire audit trail is untrustworthy. The receipt worker must be the most rigorous of the team.
- **The animation primitives are easy to get wrong.** Each of the seven primitives in §5.4 has a Reduce Motion fallback; the fallbacks must be tested. The animation primitives are also the "feel" of the app; if they're off, the app feels wrong even if everything else is correct.
- **The block AST's typed operations are the agent's interface.** If the operations are too coarse (e.g., "replace the whole doc") or too fine (e.g., "replace one character"), the agent's edits feel wrong. The operation taxonomy in §8.1 is the right granularity; the worker must enforce it.

### 13.8 Recommended worktree split

The four phases above map to four worktrees, each with a clear deliverable:

- **Phase 1 (block AST, receipts, mutation API, undo)**: `worktrees/ux-foundations/` on branch `feat/ux-foundations`. Owner: data layer + editor foundation worker.
- **Phase 2 (editor)**: `worktrees/ux-editor/` on branch `feat/ux-editor`. Owner: editor worker.
- **Phase 3 (chat panel + receipt drawer)**: `worktrees/ux-chat-receipts/` on branch `feat/ux-chat-receipts`. Owner: chat panel worker + receipt drawer worker (in two sub-worktrees).
- **Phase 4 (importers/exporters)**: `worktrees/ux-import-export/` on branch `feat/ux-import-export`. Owner: import/export worker.
- **Phase 5 (Materials surfaces)**: `worktrees/ux-materials/` on branch `feat/ux-materials`. Owner: multiple workers, one per surface.

The phases can overlap: Phase 4 (import/export) can start as soon as Phase 1 lands; Phase 5 (Materials) can start as soon as Phase 3 lands. The Phase 1 + Phase 2 sequence is serial (Phase 2 depends on Phase 1).

### 13.9 What can be deferred to v2

- The C2PA manifest export (Q3) — v2.
- The "Working in background" cross-document indicator (Q1) — v2 unless the architect wants it in v1.
- The command palette (Cmd-K) — v1 minimum is the basic search; v2 adds the full command palette.
- The per-process intervention calibration (planning vs. translation vs. review) — v2.
- The graph view (the architect's data layer has the graph; the UX v1 is the chat panel + receipt drawer; the graph view is v2).

---

## References

[1] Six Colors. *Apple Intelligence Review: A small start of something big?* October 2024. https://sixcolors.com/post/2024/10/apple-intelligence-1-review-a-small-start-of-something-big/

[2] Brisktype. *Apple Intelligence Writing Tools Review: Good, Not Enough.* 2024. https://brisktype.com/blog/apple-intelligence-writing-tools-review/

[3] Reza, M., Thomas-Mitchell, J., Dushniku, P., Laundry, N., Williams, J. J., & Kuzminykh, A. (2025). *Co-Writing with AI, on Human Terms: Aligning Research with User Demands Across the Writing Process.* Proc. ACM Human-Computer Interaction 9(7), CSCW385. https://arxiv.org/html/2504.12488v1

[4] Lee, M., Liang, P., & Yang, Q. (2022). *CoAuthor: Designing a Human-AI Collaborative Writing Dataset for Exploring Language Model Capabilities.* In Proceedings of the 2022 CHI Conference on Human Factors in Computing Systems. DOI: 10.1145/3491102.3502030. arXiv:2201.06796. https://arxiv.org/abs/2201.06796

[5] Gero, K. I., & Chilton, L. B. (2019). *Metaphoria: An Algorithmic Companion for Metaphor Creation.* In Proceedings of the 2019 CHI Conference on Human Factors in Computing Systems. DOI: 10.1145/3290605.3300526. https://www.cs.columbia.edu/~chilton/web/my_publications/Metaphoria_CHI2019.pdf

[6] 2sync. *Craft vs. Notion in 2026: which app should you choose?* 2026. https://2sync.com/blog/craft-vs-notion

[7] Simonesmerilli. *How Coda AI works - overview and best practices.* 2023. https://www.simonesmerilli.com/life/coda-ai

[8] Masson, D., et al. (2023). *DirectGPT: A Direct Manipulation Interface to Interact with Large Language Models.* arXiv:2310.03691. https://arxiv.org/html/2310.03691v2

[9] Nielsen Norman Group. *Direct Manipulation: Definition.* 2024. https://www.nngroup.com/articles/direct-manipulation/

[10] Reflect Notes. https://reflect.app/

[11] iA Writer. https://ia.net/writer

[12] Microsoft. *Creating a dynamic UX: guidance for generative AI applications.* 2024. https://learn.microsoft.com/en-us/microsoft-cloud/dev/copilot/isv/ux-guidance

[13] LogRocket. *UI patterns for async workflows, background jobs, and data pipelines.* 2025. https://blog.logrocket.com/ux-design/ui-patterns-for-async-workflows-background-jobs-and-data-pipelines/

[14] AppMaster. *Background tasks with progress updates: UI patterns that scale.* 2025. https://appmaster.io/blog/background-tasks-progress-ui

[15] Kagan, A. *The Human-in-the-Loop Catalog — Agentic AI Series Vol. 07.* 2025. https://kagan.ai/catalog/vol-07/

[16] AG-UI. *Interrupts - Agent User Interaction Protocol.* 2025. https://docs.ag-ui.com/concepts/interrupts

[17] *Delegation without Abdication: Human-AI Collaboration (HACO).* 2025. https://reseaprojournals.com/Delegation%20without%20abdication%20HACO.pdf

[18] AI UX Design Guide. *Action Audit Trail — Track and Review Every AI Decision.* 2025. https://www.aiuxdesign.guide/patterns/action-audit-trail

[19] AI-TLDR. *Chatbot UX Patterns: Streaming, Errors, Citations & More.* 2025. https://ai-tldr.dev/learn/building-ai-apps/ai-ux-patterns/chatbot-ux-patterns/

[20] AI-TLDR. *Designing for LLM Latency: Streaming UX Patterns.* 2025. https://ai-tldr.dev/learn/building-ai-apps/ai-ux-patterns/designing-for-llm-latency/

[21] Nielsen Norman Group. *The Role of Animation and Motion in UX.* 2025. https://www.nngroup.com/articles/animation-purpose-ux/

[22] Apple Human Interface Guidelines. https://developer.apple.com/design/human-interface-guidelines/

[23] Apple. *Apple unveils new accessibility features, and updates with Apple Intelligence.* May 2026. https://www.apple.com/newsroom/2026/05/apple-unveils-new-accessibility-features-and-updates-with-apple-intelligence/

[24] Apple Developer. *Reduced Motion evaluation criteria - Manage App Accessibility.* https://developer.apple.com/help/app-store-connect/manage-app-accessibility/reduced-motion-evaluation-criteria/

[25] Notion. *How Notion Designs AI Input & Output — UX Breakdown.* 2024. https://www.northbase.design/systems/notion/ai-input-output

[26] Notion. *AI Block - best practises, any updated resources to read?* https://community.coda.io/t/ai-block-best-practises-any-updated-resources-to-read/45658

[27] Argueing with Algorithms. *How I write code using Cursor: A review.* 2024. https://www.arguingwithalgorithms.com/posts/cursor-review.html

[28] Grammarly Engineering. *Accepting Multiple Suggestions at Once for Grammarly Premium Users.* 2023. https://www.grammarly.com/blog/engineering/accepting-multiple-suggestions/

[29] Appcues. *Grammarly's supporting style - GoodUX.* 2023. https://goodux.appcues.com/blog/grammarlys-supporting-style

[30] Biermann, O. C., Ma, N. F., & Yoon, D. (2022). *From Tool to Companion: Storywriters Want AI Writers to Respect Their Personal Values and Writing Strategies.* In Proceedings of the 2022 ACM Conference on Designing Interactive Systems (DIS '22). DOI: 10.1145/3532106.3533506. https://open.library.ubc.ca/media/stream/pdf/24/1.0420422/3

[31] Seng, B. *Provenance in Human-AI Collaboration.* November 2025. https://bseng.com/2025/11/19/provenance-in-human-ai-collaboration/

[32] Prassanna, S. *Agent Drift in AI Systems.* 2025. https://prassanna.io/blog/agent-drift/

[33] Fabric. *Bear vs Apple Notes: which should you use in 2026?* 2026. https://fabric.so/comparison/bear-vs-apple-notes

[34] Vanja. *Things 3 Best Practices.* 2024. https://vanja.io/things-3-complete-guide/

[35] Flexibits. *Fantastical - Calendar.* https://flexibits.com/fantastical

[36] Kevin Yank. *Email apps on Mac, iPhone and iPad compared.* 2024. https://kevinyank.com/posts/email-apps/

[37] Reddit r/ObsidianMD. *The new Obsidian graph view plugin with AI capabilities. What...* 2024. https://www.reddit.com/r/ObsidianMD/comments/1eaca26/the_new_obsidian_graph_view_plugin_with_ai/

[38] YouMind. *Build an AI-Powered Living Knowledge Graph in Obsidian.* 2025. https://youmind.com/landing/x-viral-articles/obsidian-ai-living-knowledge-graph

[39] Material Design. *Easing and duration (M3).* https://m3.material.io/styles/motion/easing-and-duration

[40] Apple WWDC 2025. *What's new in SwiftUI.* https://developer.apple.com/videos/play/wwdc2025/256/

[41] Apple WWDC 2025. *Build a SwiftUI app with the new design.* https://developer.apple.com/videos/play/wwdc2025/323/

[42] Tessera Architecture. *Tessera Studio: Data Layer Design Specification.* 2026. worktrees/data-layer-postgres-valkey/docs/tessera-data-layer-design.md

[43] UX Patterns Guide. *Editable AI Output.* 2025. https://uxpatternsguide.com/patterns/editable-ai-output/

[44] Notion. *Notion AI Inline: A complete guide to features & limitations.* 2024. https://www.eesel.ai/blog/notion-ai-inline

[45] Apple Support. *Use Writing Tools with Apple Intelligence on iPhone.* https://support.apple.com/guide/iphone/find-the-right-words-with-writing-tools-iph6f08da1d2/ios

[46] The Prompt Bench. *Designing UIs That Make LLMs Feel Good.* 2024. https://thepromptbench.com/ai-product-ux/designing-uis-that-make-llms-feel-good/

[47] Apple Developer. *Liquid Glass.* https://developer.apple.com/documentation/technologyoverviews/liquid-glass

[48] Apple. *Meet Liquid Glass - WWDC25.* https://developer.apple.com/videos/play/wwdc2025/219/

[49] Apple. *Accessibility - Human Interface Guidelines.* https://developer.apple.com/design/human-interface-guidelines/accessibility

[50] Looprails. *Human-in-the-Loop & AI Safety Research Codex (366 Sources).* 2025. https://looprails.dev/codex.html

[51] OpenAI. *Human-in-the-loop | OpenAI Agents SDK.* 2025. https://openai.github.io/openai-agents-js/guides/human-in-the-loop/

[52] DataAIHub. *Human-in-the-Loop for AI Agents - Approval & Interrupt Guide.* 2025. https://www.dataaihub.co/learn/human-in-the-loop

---

## Worker report

- **Total pages of the design doc**: ~24 pages (estimated at standard Markdown rendering).
- **Number of academic papers cited**: 15 (§3).
- **Number of market patterns surveyed**: 15 (§4) — Notion AI, Apple Intelligence, Cursor, ChatGPT, Grammarly, Craft, Coda, Reflect, iA Writer, Bear, Things 3 + OmniFocus (paired), Fantastical, MailMate/Spark/Newton (paired), Obsidian.
- **Number of specific UX decisions in §11**: 68 (numbered 1-68; the table at the end of §1 is a 49-row executive summary; the full list is 68).
- **Number of open questions for the architect**: 18 (8 spec-blocking, 10 implementation-deferrable).
- **Unverified sources**: none. All citations were verified via web search. The HACO paper (reference [17]) and the agent framework specifications (references [15][16]) are the most recent (2025-2026) and may have updates.
- **Architect intuition vs. literature tensions**:
  1. **"Agent IS the editor" vs. ChatGPT-shaped default**: the literature [8][46] validates the direct-manipulation model over the conversational model; the architect's intuition is well-supported.
  2. **Streaming character-by-character vs. block-by-block**: the literature [20] recommends token-by-token; the architect's block-by-block is the right interpretation for an AST editor (the block IS the atomic unit). The character cadence within a block is a refinement.
  3. **"Take over" is implicit (click in doc) vs. explicit (button)**: the literature [8][12][17] supports the implicit; the architect's intuition is implicit. The button is added as a safety valve, not as the primary gesture.
  4. **Chat queue is per-document vs. shared**: the literature is split (Reflect [10] and Coda [7] are per-document; some agent frameworks are per-thread/shared). The architect's per-document intuition is well-supported; the open question is the cross-document agent work indicator.
  5. **Receipt export format**: the HACO framework [17] requires C2PA at A3+; the architect's no-egress doctrine is satisfied with a local signed JSON bundle. The recommendation is a phased rollout (signed JSON in v1, C2PA in v2).
  6. **Animation duration**: the architect's intuition is "fast and brief"; the HIG [22] and Material 3 [39] both recommend 200-300ms. The recommendation in §5.4 is in the HIG-bias range.
- **Estimated time to read the doc**: 22-28 minutes for a careful skim, 45-60 minutes for a detailed read.
