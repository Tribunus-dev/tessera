# Tessera Studio -- Agent-UX-Fatigue Comprehensive Report

**Generated:** 2026-08-12
**Source:** 6 parallel review agents using the `agent-ux-fatigue` skill against `/Users/user/Developer/GitHub/tessera/TesseraStudio/`
**Mode:** read-only, no Tessera Studio source files modified
**Conventions:** ASCII only (Tessera AGENTS.md), no versioned parallel implementations, sourced, opinionated

## Part 1: Executive Summary

Tessera Studio is a SwiftUI macOS + iOS agent product (Tessy + Sky personas, dual-agent controller, graph-driven `UnifiedChatController`, receipt chain, action verifier, autonomy spine, encryption / PleadTheFifth). Six review areas were dispatched in parallel: onboarding, chat + agent loop, proactive + notifications, approval + autonomy + off-ramp, verification + diff + error, anti-AI-slop craft.

The single highest-leverage finding across all six areas is the same diagnosis: **the agent infrastructure is more mature than the agent surface.** In four of six areas, the data is right, the model is right, the verifier is right -- the surface is the bug. The chat-default paradox (paradox 3) shows up in production as "the data has no render."

The single ship-first move is **onboarding starter prompts + firstGoal card** (review #1), because it is independent, ~2 days of work, attacks the highest-leverage stage (stage 2, 60 seconds to meaningful output), and the measurement telemetry hook already exists. The full prioritized sequence is in the implementation plan; the ship order is onboarding -> tier enum -> audit-log chip -> notification budget -> progress feed -> anti-AI-slop fold, with the seven out-of-scope follow-ups interleaved in later waves.

The total work is 15 implementation units across 5 waves (Wave 0 foundation, Waves 1-4 with 4 parallel agents each). Every finding is in the plan; nothing is deferred.

## Part 2: Cross-Cutting Findings

These are the patterns that showed up in more than one review.

### CC-1. "Data exists, surface is the bug" -- 4 of 6 areas

The same diagnosis appears in reviews #2, #3, #4, and #5: the agent infrastructure (verifier, approval engine, autonomy service, scheduler, receipt chain) holds the right data, but the surface that exposes it to the user is the AI-slop default.

Concrete instances:
- `TesseraDiffOverlayView` shows "Rewrite complete" prose; the audit log's HEAD (risk, tool, receipt id) is one drawer away (`ReceiptsDrawerView.swift:25`). Per review #5.
- `UnifiedChatController` already has live state (routing, tool calls, approval gates, hold queue, collab trace); `statusPill` is a one-line bar, not a render surface. Per review #2.
- The two push notifiers fire without a shared budget; the budget is the missing surface. Per review #3.
- The tier policy is implemented as code in 5 files but never named; the tier label is the missing surface. Per review #4.

This is the chat-default paradox (paradox 3) in production: chat hides verification, hides reversibility, hides audit. The fix is not a new model; it is a render surface for the data the model already has.

### CC-2. Time-limited undo is absent

`AppKitUndoManagerBridge.levelsOfUndo = 100` (`EditorUndoCoordinator.swift:102`) caps depth, not time. The skill calls for time-limited undo because after ~30s most users stop noticing the affordance. Tessera's undo is permanent. Per review #5. **Item 2C in the implementation plan.**

### CC-3. Uncertainty field is missing on `ToolResultPayload`

`ChatMessage.swift:29-39` defines `ToolResultPayload.success | output | error` but no `uncertainty`. The Tian Pan 2026-04-12 split (uncertain-and-told-you vs confident-and-wrong) needs a third value -- `uncertainty: Double?` or a categorical `confidenceBand: .low | .medium | .high`. Per review #5. **Item 2D in the implementation plan.**

### CC-4. No source citation on chat content

`ChatMessage.content` is free-form `String` (`ChatMessage.swift:43-67`). Adding `sources: [Citation]` would close the find-bar-vs-chat gap. Per review #5. **Item 3A in the implementation plan.**

### CC-5. The skill is not in the mavis default index

3 of 6 review agents had to find the skill at `/Users/user/.zcode/skills/agent-ux-fatigue/` manually. The other 3 found it. The skill should be in the mavis default skill index so future agents discover it without the search. **Item 0A in the implementation plan.**

### CC-6. Two parallel chat systems (legacy + new)

`TesseraDualAgentController` is the legacy chat system (admits the chat is decorative at `TesseraDualAgentController.swift:208-209`); `UnifiedChatController` is the new graph-driven one. The architect's own header comment names the issue (`UnifiedChatController.swift:9-10`). The dual system is a technical-debt artifact, not a user-facing problem -- the user only sees the new one -- but it doubles the maintenance surface for chat state. Per review #2.

### CC-7. No `force:` override on the notification budget (the anti-pattern by absence)

The two existing push notifiers have no shared budget. Adding a `TesseraNotificationBudget` actor with a `force:` override would re-introduce the soft-target anti-pattern. The fix is a hard cap with no override. Per review #3.

### CC-8. The verifier is the strongest piece of the codebase

The rule-based categorical risk classifier (`TesseraActionVerifier.swift:74-90`), the fail-closed semantics on its own error (`55-63`), the structured `PendingAction` (`6-14`), and the character-resolution `DiffSegment` (`TesseraDiffOverlayView.swift:10-30`) are explicit named-pattern implementations of the skill's verification paradox (paradox 1). They are not heuristics; they are pattern matches. The audit-log HEAD chip (item 1C) is the surface for the data these already produce.

### CC-9. The approval engine is the second strongest piece

Per review #4, the approval engine has 3 pattern shapes (deterministic), an asymmetric ratchet, RULES-not-ML irreversibility guard, denial circuit breaker, scoped YOLO, miscalibration regime-shift tightening, approver-training collapse-guard, tier-1/tier-2 escalation frame, `ConfirmationPanel` friction (paste-block + 5s unlock + 3/30s rate-limit), and approval receipts. The single missing piece is the surface: a named `TesseraTier` enum + `tier(for:)` computed property. **Item 1B in the implementation plan.**

### CC-10. The covert-trigger path is correctly silent

`ReportWindow.swift` is a pull menu item, not a surface ping. `PleadTheFifthTrigger` fires the trigger but does not surface the trigger itself. The skill's paradox 7 (proactive-agent paradox) warns against silent ambient agents being forgotten; the covert-trigger path avoids this by being opt-in (the user pulls the report when they want it). Per review #3.

## Part 3: The 6 Area Reviews (full)

### 3.1 Onboarding + First Task (review #1)

**Source:** `01-onboarding-first-task.md`, 10.6 KB.

**Stage:** stages 1, 2, 3 (Discovery, Onboarding, First task). Stage 2 dominant -- the activation moment.

**Dominant fatigue factor:** cognitive. The empty canvas imposes prompt-construction cost on a blank surface. Per Lau & Hartanto 2026 (n=717), 32% find prompt construction mentally taxing.

**Paradoxes loaded:** paradox 4 (empty-canvas, dominant) + paradox 2 (autonomy, latent) + paradox 3 (chat-default, latent).

**Healthy surfaces (do not touch):** the iOS `TabView` opens straight into five tabs with no landing hero (Terminal-Core family, per review #6); the 13-destination sidebar is already organized; `TesseraSettings` uses the form shape that the new onboarding should adopt.

**Issues (file:line):**
- `UnifiedChatDock.swift:91-98` "Ask Tessy or Sky" with no starter prompts.
- `TesseraStudioiOS/App/ContentView.swift:39-44` literal `ContentUnavailableView` ("The unified chat lands here").
- `OnboardingView.swift:46-220` 3-page brochure: education-as-text, not onboarding-as-context-gathering.
- `OnboardingView.swift:124-144` 4-row approval legend on page 3 -- a list, not a seed.
- `TesseraCore/Views/LibraryView.swift:62-68` empty-state placeholder.

**Move (2 stacked patterns):**
1. 3-5 destination-aware starter prompts keyed off the current sidebar `Destination`. Zero new plumbing -- tap fills `inputText` and triggers existing `send()` at `UnifiedChatDock.swift:170-175`.
2. Convert onboarding page 3 from the 4-row approval legend to a single typed-sentence "firstGoal" card that seeds `UnifiedChatController`.

**Trade-off:** starter prompts can go stale (the per-`Destination` mapping needs the same refresh cadence as the rest of the sidebar). Guardrail: 1-question "first suggested task felt relevant" pulse at week 4; trust score <60% means the prompts are stale.

**Why not the alternatives (5 bullets, evidence-based):**
- Not "coachmark tour" -- the rejected onboarding-as-education pattern.
- Not "better empty-state copy" -- still the empty-canvas paradox in a nicer font.
- Not "model-authored greeting" -- loads the verification cost (Lau & Hartanto 2026) into the first 60s.
- Not "what's new" sidebar tour -- competes with the 13-destination sidebar the team has already organized.
- Not "force-create-a-Workflow" -- trades the empty-canvas paradox for the autonomy paradox (paradox 2).

**Measurement architecture:**
- primary (leading-behavior): time-to-first-message, down >=30% by week 2. Wire 1 event in `TelemetryMonitor` (`ContentView.swift:32-34`).
- trust (leading-qualitative): "first suggested task felt relevant" pulse score, >=60% by week 4. Catches the failure mode (suggestions going stale).
- anti (leading-behavior): onboarding firstGoal skip rate, <25% by week 4. Catches the over-correction (asking too long, user dismisses).
- instrumentation cost: <=2 days. Data source already exists.

**One-sentence version (38 words):** Tessera's first 5 minutes are an "ask me anything" chat and a three-page brochure; ship 3-5 destination-aware starter prompts in the chat dock and convert page 3 of onboarding into one typed sentence that seeds the agent.

**How this generalizes:** the same move fixes the iOS chat placeholder at `TesseraStudioiOS/App/ContentView.swift:39-44` and the `LibraryView` empty state at `TesseraCore/Views/LibraryView.swift:62-68`; the `firstGoal` key is also the natural entry point for future proactive-mode opt-in (stage 5) and the pre-action limitation disclosure (pattern-catalog.md lines 338-347).

### 3.2 Chat Surface + Agent Loop (review #2)

**Source:** `02-chat-agent-loop.md`, 8.9 KB.

**Stage:** stage 4 (sustained use / agent loop) dominant; stages 5 + 7 as cross-stage hooks.

**Dominant fatigue factor:** cognitive (the 23-min Mark recovery cost compounds across the agent loop) + emotional (chat-first prose can feel like the agent is not on the user's side).

**Paradoxes loaded:** paradox 3 (chat-default, central) + paradox 1 (verification) + paradox 2 (autonomy, latent) + paradox 5 (off-ramp, latent).

**Healthy surfaces (do not touch):**
- Off-ramp: `cancel` + `hold` + iOS `HoldYourHorsesDialog_iOS` (`ChatPanelView_iOS.swift:280-323`).
- Persona: Tessy and Sky have coherent roles, tints, role hints, system-prompt fragments (`AgentPersona.swift:42-55`). Not the AI-slop baseline.
- Autonomy spine: per-task ratchet is landed per `docs/PROJECT-STATUS.md:574-588`.

**Issues (file:line):**
- `TesseraDualAgentController.swift:208-209` -- the legacy chat admits it is decorative.
- `UnifiedChatController.swift:9-10` -- the architect's own header comment names the issue.
- `UnifiedChatController.swift:23` -- `statusPill` is a one-line bar; live state has no surface.
- `UnifiedChatRow.swift:29` -- tool calls land as `ToolCallRecord` on chat rows; args/results not parsed structural data. Receipt chain only fires on document mutations.

**Move:** pull-to-open Progress Feed in the dock, rendering the live state already in `UnifiedChatController` (routing, tool calls, approval gates, hold queue, collab trace). **Pull, not push** -- the feed must not become a notification flood (proactive-agent paradox, `paradoxes-deep.md`).

**Trade-off:** the feed can become a notification flood if it is auto-pushed. Guardrail: pull-to-open affordance only; if the feed ever auto-pushes, it is a regression.

**Why not the alternatives (3 bullets):**
- Not "expand the chat thread" -- the chat-first surface is the paradox 3 failure mode in production; expanding it deepens the bug.
- Not "add a separate status bar" -- another bar is the "progress bar without a progress feed" anti-pattern (skill anti-pattern list).
- Not "show tool calls inline" -- a third surface type for the same data; the skill's position is fewer surfaces, more data density per surface.

**Measurement architecture:**
- primary (leading-behavior): % of sessions where the feed is opened at least once, target >=60% by week 4.
- trust (leading-qualitative): rep-reported "I can see what the agent is doing" score, up >=20% by week 4.
- anti (leading-behavior): % of feed events that arrive as a push notification, target <10% by week 4. Catches the proactive-agent paradox failure mode.

**One-sentence version (32 words):** Pull-to-open Progress Feed in the chat dock that renders the live state already in `UnifiedChatController` (routing, tool calls, approval gates); the feed is a surface, not a notification.

**How this generalizes:** the same pattern applies to the Graph view handoff (`ReceiptsCoordinator.swift:138-140`) -- the active node's HEAD chip belongs on the tool-call row, not in a side panel.

### 3.3 Proactive + Notifications (review #3)

**Source:** `03-proactive-notifications.md`, 11.9 KB.

**Stage:** stage 5 (proactive / ambient mode) + paradox 7 (proactive-agent paradox, both sides: loud-muted AND silent-forgotten).

**Dominant fatigue factor:** notification + emotional + behavioural.

**Paradoxes loaded:** paradox 7 (proactive-agent, central) + paradox 6 (XAI, latent) + paradox 2 (autonomy, latent).

**Healthy surfaces (do not touch):**
- `TelemetrySample` + `TelemetryMonitor` are local-only: no URLSession, in-memory ring buffer of 60 samples at `TelemetryDrawer.swift:17`; `telemetryEnabled` defaults to false at `TesseraSettings.swift:109`.
- `TesseraWorldSignalObserver.record` only called from the explicit `RecordOutcomeTool.execute` (build/test/commit/revert kinds at `TesseraWorldOutcomeContracts.swift:6-7`) -- NOT silent user-behaviour surveillance.
- Covert-trigger path is correctly silent (no surface ping; `ReportWindow.swift` is a pull menu item).
- The two push notifiers correctly implement the frontmost+surface-visible suppression rule (their own comments cite HIG 14.12).

**Issues (file:line):**
- Two push notifiers fire at `interruptionLevel = .active` with no shared notification budget.
- `TrainingNotifier:76-77` pings for `.dryRun` -- the un-actionable-in-15-30-min anti-pattern.
- `TesseraAdaptationScheduler:159-168` has no `onFinished` hook -- silent scheduler collapse failures never reach the user (paradox 7's silent-forgotten side).
- `TesseraAssessmentScheduler` same: no `onFinished` hook.

**Move:** one shared `TesseraNotificationBudget` actor (per-UTC-day counter, default cap 3, **no `force:` override**) called by the two existing push notifiers. Drop `.dryRun` from the postable set. **One new file (~80 LoC), two one-line call-site edits.** The existing `TesseraAdaptationScheduler:22` `adaptation-records.json` shape is the template for the new `tessera.notifications.log`.

**Trade-off:** the budget can starve a legitimate high-value notification. Guardrail: the budget is per-UTC-day with a single counter; high-value events that hit the cap are *deferred* to the next day, not dropped. The log file preserves the full record for post-hoc review.

**Why not the alternatives (4 bullets):**
- Not "per-event allowlist" -- the planner games any allowlist (skill: "the budget must be a hard cap, not a soft target").
- Not "force-override for high-value" -- the override is the soft-target anti-pattern in disguise.
- Not "drop the .dryRun notifications entirely" -- the dry-run notification is useful for development; the fix is to gate it behind a separate `devMode` flag, not to remove it.
- Not "use UNUserNotificationCenter throttling" -- macOS does not have UNUserNotificationCenter throttling for non-prompt notifications; the budget is the only mechanism that works.

**Measurement architecture:**
- primary (leading-behavior): # of push notifications fired per user per UTC day, target <=3.
- trust (leading-behavior): % of fired notifications acted on within 15 min (the "actionable" check), target >=50%.
- anti (leading-behavior): # of silent scheduler collapses where `onFinished` should have fired, target ==0 by week 2. Catches the silent-forgotten side.

**One-sentence version (35 words):** Wrap the two existing push notifiers in a shared `TesseraNotificationBudget` actor with a 3-per-UTC-day cap and no force override; add `onFinished` hooks to `TesseraAdaptationScheduler` and `TesseraAssessmentScheduler` so silent collapses surface.

**How this generalizes:** the same budget shape applies to any proactive surface (digest windows, learning nudges, the future proactive-mode opt-in entry point from review #1); the silent-collapse anti-metric is the universal health signal for any "background agent that should report when done."

### 3.4 Approval + Autonomy + Off-ramp (review #4)

**Source:** `04-approval-autonomy-offramp.md`, 8.1 KB.

**Stage:** stage 6 (off-ramp) dominant; stages 4 + 5 as cross-stage hooks.

**Dominant fatigue factor:** emotional + cognitive from confirmation fatigue (OWASP ASI09).

**Paradoxes loaded:** paradox 2 (autonomy, central) + paradox 5 (off-ramp paradox, central) + paradox 1 (verification, latent).

**Healthy surfaces (do not touch):**
- Action-class classifier: 3 pattern shapes, deterministic.
- Asymmetric ratchet (per-task ratchet, not global).
- RULES-not-ML irreversibility guard.
- Denial circuit breaker.
- Scoped YOLO.
- Miscalibration regime-shift tightening.
- Approver-training collapse-guard.
- Tier-1 / tier-2 escalation frame.
- `ConfirmationPanel` friction (paste-block + 5s unlock + 3/30s rate-limit).
- Approval receipts (already structured).

**Issues (file:line):**
- Tier policy implemented as code in 5 files but never named as `Tier 0/1/2/3`. The dimension that matters (reversibility + blast radius) is captured implicitly by `TesseraActionClass.isIrreversible` but not surfaced.
- `ApprovalSheet` does not show `actionClass` / risk / irreversibility.

**Move:** add a `TesseraTier` enum (`tier0 | tier1 | tier2 | tier3`) + `tier(for: TesseraActionClass)` computed property on `TesseraSafetyDecision`, surface the tier label on `ApprovalSheet`. **Rename + one computed property, no behavior change.**

**Trade-off:** tier boundary drift. The skill is explicit: "the drift direction is always toward more gates, not fewer." Guardrail: ship the tier policy as code in the same repo as the agent, with a test that asserts the drift direction (no Tier 2 -> Tier 1 promotions in a release without an explicit `TesseraTier.revoke` call).

**Why not the alternatives (4 bullets):**
- Not "global autonomy dial" -- the skill's position is per-task, not global.
- Not "blanket confirm every action" -- the OWASP ASI09 anti-pattern; this is what the tier policy is the fix for.
- Not "trust the existing isIrreversible flag" -- it is the right signal, but it is invisible to the user. The tier label is the surface.
- Not "ship the inline stop button now" -- it is the next wave (item 3C); the tier enum is the precursor because the stop button needs to know the tier.

**Measurement architecture:**
- primary (leading-behavior): % of actions that triggered an `ApprovalSheet` open where the user accepted without modification, target >=70% by week 4 (catches tier mis-calibration).
- trust (leading-behavior): approval reject rate on Tier 2/3 actions, target <20% by week 6 (anchored to skill anti-pattern: too high = mis-calibrated, too low = too permissive).
- anti (leading-behavior): % of actions that bypassed the gate (`.tier3 -> .autoApprove` or `.tier0 -> .askUser`), target <1% by week 4. Catches the tier-boundary drift failure mode. Computable from existing `approval-receipts.jsonl`.

**One-sentence version (38 words):** Add a `TesseraTier` enum and `tier(for:)` computed property to `TesseraSafetyDecision`; surface the tier label on `ApprovalSheet`; ship a test that asserts the tier boundaries do not drift.

**How this generalizes:** the same enum is the precursor for the inline-stop button (item 3C) and the Action Audit Log as a side panel (item 3D); both surfaces need to know the tier to render correctly.

### 3.5 Verification + Diff + Error (review #5)

**Source:** `05-verification-diff-error.md`, 9.7 KB.

**Stage:** stage 4 (sustained use) dominant; stage 7 (recovery from failure) hooks loaded but under-served.

**Dominant fatigue factor:** cognitive (verification cost). The user pays a navigation tax every time they want to confirm what the agent is doing.

**Paradoxes loaded:** paradox 1 (verification, central) + paradox 6 (XAI, loaded).

**Healthy surfaces (do not touch):**
- Rule-based categorical risk (`TesseraActionVerifier.swift:74-90`).
- Fail-closed on verifier's own error (`55-63`).
- Structured `PendingAction` (`6-14`).
- Character-resolution `DiffSegment` (`TesseraDiffOverlayView.swift:10-30`).
- Structured `Receipt.mutations` (`ReceiptExportService.swift:267`).
- `userConfirmed: true` export gate (`156-159`).
- Egress gate (`171-173`) is a hook, the user confirmation is the real rail.

**Issues (file:line):**
- `TesseraDiffOverlayView.swift:155` "Rewrite complete" prose; audit log's HEAD one drawer away.
- `AgentCursorOverlay.swift:29-57` shows WHERE, not WHAT.
- `FindReplaceBar.swift:74-80` is the right shape (count + current match inline) but is not the diff.
- `EditorUndoCoordinator.swift:102` undo caps depth, not time.
- `ToolResultPayload` (in `ChatMessage.swift:29-39`) has no `uncertainty` field.
- `ChatMessage.content` is free-form String, no `sources: [Citation]`.
- `ReceiptsCoordinator.refresh()` polls every 200ms (`ReceiptsCoordinator.swift:212`).

**Move:** inline the audit-log HEAD as a one-line chip on `TesseraDiffOverlayView` between the diff and the Accept/Reject controls:

```
risk: medium | tool: rewrite | 2.1s | receipt: a1b2...
```

Pull the latest `Receipt` from `ReceiptUndoManager`; route the receipt-id tap through the existing `ReceiptsCoordinatorBridge.openReceipt` (`ReceiptsCoordinator.swift:105-115`).

**Trade-off:** the chip can become a noise source on short rewrites. Guardrail: only show on `state == .diffComplete` or `.editable`; suppress on `.streaming` (the existing `TesseraDiffOverlayView.swift:147-162` branches by state). Cap field count to 5.

**Why not the alternatives (5 bullets):**
- Not "separate Verify tab" -- adds one more tap; verification cost = taps.
- Not "numeric confidence %" -- the skill anti-pattern (LLM confidence is miscalibrated). Use categorical risk.
- Not "tooltip on the agent cursor" -- two problems: the cursor does not carry a pending-mutation payload, and tooltips hide on blur.
- Not "auto-open the receipts drawer on Accept/Reject" -- invasive; the user just made a choice.
- Not "Why? button" -- forces a second tap. The chip IS the rationale, in structural form.

**Measurement architecture:**
- primary (leading-behavior): median time from `diffComplete` to `Accept` tap, target <3s. Lau & Hartanto 2026: longer verification windows correlate with approval-by-reflex.
- trust (leading-behavior): % of Accept taps where the user clicked the receipt-id chip, non-zero = chip is useful, near zero = decoration (Baldeo active-use signal).
- anti (leading-behavior): P95 character length of `VerifierDecision.rationale` (`TesseraActionVerifier.swift:22`), target <80 chars. Paradox 6 alarm.

**One-sentence version (35 words):** Inline the audit-log HEAD (risk, tool, receipt id) as a chip on `TesseraDiffOverlayView` between the diff and the controls; the user verifies in place, not by opening the drawer.

**How this generalizes:** the "inline the audit log head" pattern applies to any agentic surface where a structured data object (risk level, tool identity, receipt) is one navigation tap away from the user's accept/reject moment: replace the tap with a chip, and paradox 1 verification cost falls to zero. Same pattern will apply to the Graph view handoff (`ReceiptsCoordinator.swift:138-140`).

### 3.6 Anti-AI-slop craft audit (review #6)

**Source:** `06-anti-ai-slop-craft.md`, -- KB.

**Stage:** stage 1 (Discovery) and stage 2 (Onboarding) -- the surface that defines the first impression.

**Dominant fatigue factor:** emotional (cheap-feeling surface creates low-grade contempt that compounds).

**Paradoxes loaded:** paradox 4 (empty-canvas, latent) + paradox 3 (chat-default, latent) -- the welcomePage is the chat-default's onboarding cousin.

**Healthy surfaces (do not touch, named explicitly):**
- Fonts: zero custom faces, `Font.system(_:design:)` only, no font dep in `Package.swift`.
- Imagery: zero photo / hero / logo-wall / fake testimonials / fabricated stats.
- Icons: SF Symbols everywhere; the one emoji is user-authored document content (`DocDetailView.swift:232`), not chrome.
- Capsules: chip-only, never on hero cards.
- Shadows: capped at `radius < 10` with explicit color stops.
- Chat dock: `textFieldStyle(.plain)` over `.bar`.
- `TelemetryDrawer`: monospaced and dense (Data-Dense Pro family).
- iOS shell: opens straight into a five-tab `TabView` with no landing hero.
- `.regularMaterial`: 8 floating-UI sites, never as a hero backdrop.
- Banned copy ("elevate / seamless / unleash / next-gen / game-changer / delve / powered by AI / smart"): zero occurrences in the views. "Elevated" only appears as the name of a `TesseraPermissionProfile` case (domain, not copy).

**Borderline (documented, not banned):**
- `AgentPersona.swift:65` Sky tint is the violet family -- reads semantically as "cloud", used at 0.10-0.15 opacity on capsules, never as a hero wash.
- `LibraryView.swift:271` and `ReceiptRowView.swift:80` `.purple` for the agent actor.

**Recommended family:** Terminal-Core, with Data-Dense Pro as the accent on calibration / telemetry / runs surfaces. The product is already in this family; the onboarding is the only surface that stepped out of it.

**Issues (file:line):** all in `TesseraStudio/Sources/TesseraCore/Views/OnboardingView.swift:46-220`:
- `.purple` icon on welcomePage.
- `.largeTitle.bold()` headline.
- `.title3` subhead.
- Vertical four-row `feature()` list.
- Page dots.
- Primary CTA strip.
- Pastel-rainbow page tint rotation across `welcomePage` / `modelPage` / `agentPage`.

**Move:** delete `OnboardingView.welcomePage` and the `feature()` helper; fold the model-directory step and the agent-approval step into one screen with two sections in the same form shape as the existing macOS `SettingsView`. Drop the page dots, the page-turn animation, the page-tint rotation, and the `.largeTitle` headline. Reuse `PathField` verbatim. The four pipeline verbs (Calibrate / Evolve / Evaluate / Deploy) move to a single caption line under the directory field, separated by middle dots. **~200-300 LoC, 1-2 weeks.**

**Trade-off:** none material. The file has no business logic; it is a craft offender end-to-end. The risk is that the new form loses the approval-legend content from the old page 3 -- this is handled by the firstGoal card from review #1, which becomes the seed field in the form.

**Why not the alternatives (4 bullets):**
- Not "redesign the welcome page" -- the welcome page is the problem; a redesign is more work for the same anti-pattern.
- Not "swap Inter for a different font" -- the body is `Font.system(_:design:)`, not Inter. The issue is the structure, not the font.
- Not "remove just the .purple" -- the issue is the centered hero + feature-card pattern; the color is a symptom.
- Not "rewrite the copy" -- copy is healthy; the layout is the bug.

**Measurement architecture:**
- primary (leading-qualitative): first-impression rating from new users in the first 5 minutes (1-question in-app survey on first-run completion), target >=4/5.
- trust (leading-qualitative): "feels premium / feels like a tool" tag, target >=80% positive, n=10 session-replay annotation.
- anti (leading-behavior): bounce rate within 30 seconds of first open (close-app / Cmd-W within 30s of `TesseraStudioMacApp` finishing launch), target <10%.

**One-sentence version (28 words):** Tessera Studio is mostly a clean Terminal-Core product, but the first-run onboarding is a centered purple hero that imports every banned AI-slop pattern; delete the welcome page and fold the remaining setup into one form.

**How this generalizes:** the "delete + reuse form shape" pattern applies to any first-run surface that imported the SaaS default. The audit's value is the explicit "do not touch" list of healthy surfaces; future craft reviews should not re-investigate them.

## Part 4: Consolidated Healthy Surfaces (do not touch)

These are the surfaces explicitly named as healthy across the 6 reviews. They are listed so the implementation plan does not redo them.

### Off-ramp (paradox 5)
- `cancel` + `hold` + iOS `HoldYourHorsesDialog_iOS` (`ChatPanelView_iOS.swift:280-323`). Per review #2.

### Persona design
- Tessy and Sky: coherent roles, tints, role hints, system-prompt fragments (`AgentPersona.swift:42-55`). Per review #2.

### Autonomy spine
- Per-task ratchet landed per `docs/PROJECT-STATUS.md:574-588`. Per review #2.

### Verifier
- Rule-based categorical risk (`TesseraActionVerifier.swift:74-90`).
- Fail-closed on verifier's own error (`55-63`).
- Structured `PendingAction` (`6-14`). Per review #5.

### Diff
- Character-resolution `DiffSegment` (`TesseraDiffOverlayView.swift:10-30`). Per review #5.

### Receipts
- Structured `Receipt.mutations` (`ReceiptExportService.swift:267`).
- Markdown export surfaces the mutation list per receipt (`488-495`).
- Signed-JSON bundle surfaces the full chain (`436-453`).
- `userConfirmed: true` export gate (`156-159`).
- Egress gate (`171-173`) is a hook, the user confirmation is the real rail. Per review #5.

### Approval engine
- 3 pattern shapes (deterministic).
- Asymmetric ratchet.
- RULES-not-ML irreversibility guard.
- Denial circuit breaker (`TesseraDenialCircuitBreaker.swift`).
- Scoped YOLO.
- Miscalibration regime-shift tightening.
- Approver-training collapse-guard.
- Tier-1 / tier-2 escalation frame.
- `ConfirmationPanel` friction (paste-block + 5s unlock + 3/30s rate-limit).
- Approval receipts (already structured). Per review #4.

### Autonomy + escalation
- `TesseraAutonomyService` + `TesseraAutonomyContracts`.
- `TesseraEscalationService` + `TesseraEscalationContracts`. Per review #4.

### Telemetry
- Local-only: no URLSession, in-memory ring buffer of 60 samples (`TelemetryDrawer.swift:17`), `telemetryEnabled` defaults to false (`TesseraSettings.swift:109`). Per review #3.

### World-signal observation
- `TesseraWorldSignalObserver.record` only called from explicit `RecordOutcomeTool.execute` (build/test/commit/revert kinds at `TesseraWorldOutcomeContracts.swift:6-7`), not silent user-behaviour surveillance. Per review #3.

### Covert-trigger path
- Correctly silent (no surface ping; `ReportWindow.swift` is a pull menu item). Per review #3.

### Push notifiers
- The two push notifiers correctly implement the frontmost+surface-visible suppression rule (their own comments cite HIG 14.12). The fix in review #3 wraps the call in a budget; it does not change the suppression logic. Per review #3.

### Typography / icons / imagery (app-wide, per review #6)
- Fonts: zero custom faces, `Font.system(_:design:)` only, no font dep in `Package.swift`.
- Imagery: zero photo / hero / logo-wall / fake testimonials / fabricated stats.
- Icons: SF Symbols everywhere; the one emoji is user-authored document content (`DocDetailView.swift:232`), not chrome.
- Capsules: chip-only, never on hero cards.
- Shadows: capped at `radius < 10` with explicit color stops.
- Chat dock: `textFieldStyle(.plain)` over `.bar`.
- `TelemetryDrawer`: monospaced and dense (Data-Dense Pro family).
- iOS shell: opens straight into a five-tab `TabView` with no landing hero.
- `.regularMaterial`: 8 floating-UI sites, never as a hero backdrop.
- Banned copy: zero occurrences in the views.

### iOS navigation
- 5-tab `TabView` with no landing hero.
- 13-destination sidebar on macOS (already organized).

## Part 5: Out-of-Scope Follow-Ups (now in the implementation plan)

These were explicitly deferred in the 6 reviews but are now promoted to wave tasks in the implementation plan. No item is left in "deferred" status.

| ID | Item | Source | Wave | Status |
|---|---|---|---|---|
| 2C | Time-limited undo (`AppKitUndoManagerBridge` cap is depth, not time) | review #5 | 2 | promoted |
| 2D | `uncertainty: Double?` on `ToolResultPayload` for Tian Pan 2026-04-12 split | review #5 | 2 | promoted |
| 3A | `sources: [Citation]` on `ChatMessage` | review #5 | 3 | promoted |
| 3B | `ReceiptsCoordinator.refresh()` 200ms polling -> `AsyncStream` | review #5 | 3 | promoted |
| 3C | Inline-stop (paradox 5) | review #4 | 3 | promoted |
| 3D | Action Audit Log as a side panel | review #4 | 3 | promoted |
| 4A | Agent cursor WHAT-not-WHERE payload | review #5 | 4 | promoted |
| 4B | `ApprovalSheet` actionClass/risk/irrevisibility | review #4 | 4 | promoted |
| 4C | Documentation sync (docs/PROJECT-STATUS.md, AGENTS.md) | cross-cutting | 4 | promoted |
| 4D | Final integration test + handoff (cross-wave regression, measurement wiring) | cross-cutting | 4 | promoted |

## Part 6: Conflicts and Dependencies

### 6.1 Onboarding (#1) vs Anti-AI-slop (#6): same file, different moves

Both reviews touch `OnboardingView.swift` and recommend changes to the page-3 (approval legend / firstGoal card) step.

**Resolution:** ship #1 first (firstGoal card on page 3). Narrow #6 to delete only `welcomePage` and the page-turn chrome (page dots, page-tint rotation, `.largeTitle` headline, `feature()` helper), preserving the firstGoal card as the seed mechanism. The firstGoal card is the natural entry point for future proactive-mode opt-in (stage 5) and the pre-action limitation disclosure (skill pattern-catalog); the Settings-form-fold in #6 is the right shape for the model-directory and agent-approval steps.

**Dependency:** #6 (item 2B) depends on #1 (item 1A) -- 2B cannot start until 1A's firstGoal card is shipped.

### 6.2 Chat+loop (#2) and Verification+diff (#5): the data lives next to the surface

Both reviews identify the same data-availability-vs-surface problem from different angles. #2 wants the live-state rendered as a pull-feed; #5 wants the audit log's HEAD inlined as a chip on the diff. The two moves do not conflict -- they render different data on different surfaces -- but they should be designed together so the information architecture is consistent. **Design coordination:** items 1C (audit-log chip) and 2A (progress feed) share the same pull-feed style and chip vocabulary; the IA convention should be agreed before either ships.

### 6.3 Tier enum (#4) and the follow-ups (3C, 3D, 4B)

The `TesseraTier` enum (item 1B) is the precursor for three downstream items:
- 3C (inline-stop, paradox 5) needs to know the tier to render the stop affordance at the right weight.
- 3D (Action Audit Log as a side panel) needs the tier to label each entry.
- 4B (`ApprovalSheet` actionClass/risk/irrevisibility) needs the tier to set the affordance.

**Dependency:** 1B must ship before 3C, 3D, and 4B.

### 6.4 Notification budget (#3) and Progress Feed (#2)

The notification budget (item 1D) is the precursor for the Progress Feed (item 2A). If 2A ships without 1D, the feed can become a notification flood (paradox 7's failure mode). **Dependency:** 1D must ship before 2A.

### 6.5 Skill registration (Wave 0) and all reviews

The agent-ux-fatigue skill is not in the mavis default index. 3 of 6 review agents had to find it manually. The Wave 0 task (item 0A) registers the skill, so future reviews do not have this friction. **No dependency on other waves** -- Wave 0 is sequential and runs first.

## Part 7: Source Provenance

### Primary sources (peer-reviewed or first-party engineering)

- Lau, Hartanto et al. (2026). AI fatigue scale, *Computers in Human Behavior Reports* (n=717, alpha=.92). The 4-factor model. See `references/ai-fatigue-construct.md` in the skill.
- Baldeo (2026). Cognitive offload in high-use GenAI users, *Technology, Mind, and Behavior* (APA). Caveat: under community-pending review. The active-use vs passive-use finding.
- Acta Psychologica 2025. AI dependence, critical thinking, fatigue mediation.
- Microsoft Research. HAX Toolkit, 18 Guidelines for Human-AI Interaction (2019 CHI, validated).
- Gloria Mark et al. (2005, 2008). Interruption cost, CHI. The 23-min recovery number.
- OWASP Top 10 for Agentic Applications 2026, item ASI09 (confirmation fatigue as security vulnerability).
- Tian Pan (2026). Trust calibration curve; background agents and the notification budget.

### Engineering and product sources (design patterns, exemplars)

- Anthropic Frontend Aesthetics Cookbook and `frontend-design` skill.
- Smashing Magazine Designing for Agentic AI 2026-02.
- Zylos research notes (onboarding, ambient computing, GenUI, agentic UX).
- CSIRO Responsible AI Pattern Catalogue.
- Cursor 3, Devin, Claude Code, Replit, Lindy, ChatGPT Canvas, Anthropic Artifacts, Apple Intelligence, Microsoft Copilot, Granola, Notion AI as design exemplars (see `references/product-exemplars.md` in the skill).
- Human Clarity Institute (2025-11, n=503). 43% find verification of AI output mentally taxing; 32% find prompt construction mentally taxing.

### Single-source claims (flag with the user if the user leans on them)

- The 3-5 unsolicited AI notifications per day ceiling (Tian Pan).
- The 34% -> 67% Devin PR merge rate (Zylos attribution to Cognition).
- The Anthropic Claude Design 2026-04-17 launch and Figma stock -12% within 2 weeks (secondary press).

### Tessera-specific references (from the reviews)

- `docs/PROJECT-STATUS.md:574-588` -- autonomy spine status.
- `AGENTS.md`, `CLAUDE.md` -- project conventions.
- `TesseraStudio/Sources/TesseraCore/Agent/TesseraApprovalEngine.swift` -- approval engine.
- `TesseraStudio/Sources/TesseraCore/Agent/TesseraActionVerifier.swift` -- verifier.
- `TesseraStudio/Sources/TesseraCore/Agent/TesseraSafetyDecision.swift` -- risk classifier.
- `TesseraStudio/Sources/TesseraCore/Agent/TesseraActionClass.swift` -- action class.
- `TesseraStudio/Sources/TesseraCore/Agent/TesseraDenialCircuitBreaker.swift` -- denial circuit breaker.
- `TesseraStudio/Sources/TesseraCore/Agent/TesseraAgentLoop.swift` -- agent loop.
- `TesseraStudio/Sources/TesseraCore/Agent/UnifiedChatController.swift` -- new chat controller.
- `TesseraStudio/Sources/TesseraCore/Agent/TesseraDualAgentController.swift` -- legacy chat controller.
- `TesseraStudio/Sources/TesseraCore/Agent/ChatGraphBuilder.swift` -- chat graph builder.
- `TesseraStudio/Sources/TesseraCore/Agent/AgentPersona.swift` -- personas.
- `TesseraStudio/Sources/TesseraCore/Learning/TesseraAutonomyService.swift` -- autonomy service.
- `TesseraStudio/Sources/TesseraCore/Learning/TesseraAutonomyContracts.swift` -- autonomy contracts.
- `TesseraStudio/Sources/TesseraCore/Learning/TesseraEscalationService.swift` -- escalation.
- `TesseraStudio/Sources/TesseraCore/Learning/TesseraEscalationContracts.swift` -- escalation contracts.
- `TesseraStudio/Sources/TesseraCore/Learning/TesseraAdaptationScheduler.swift` -- adaptation scheduler.
- `TesseraStudio/Sources/TesseraCore/Learning/TesseraTrainingScheduler.swift` -- training scheduler.
- `TesseraStudio/Sources/TesseraCore/Learning/TesseraAssessmentScheduler.swift` -- assessment scheduler.
- `TesseraStudio/Sources/TesseraCore/Encryption/PleadTheFifthNotifications.swift` -- push notifier.
- `TesseraStudio/Sources/TesseraCore/Encryption/CovertTriggerMonitor.swift` -- covert trigger monitor.
- `TesseraStudio/Sources/TesseraCore/Encryption/PleadTheFifthExecutor.swift` -- trigger executor.
- `TesseraStudio/Sources/TesseraCore/Encryption/PleadTheFifthTrigger.swift` -- trigger.
- `TesseraStudio/Sources/TesseraCore/Models/TelemetrySample.swift` -- telemetry sample.
- `TesseraStudio/Sources/TesseraCore/Models/AnalyticsModels.swift` -- analytics models.
- `TesseraStudio/Sources/TesseraCore/Models/ChatMessage.swift` -- chat message model.
- `TesseraStudio/Sources/TesseraCore/Models/Conversation.swift` -- conversation model.
- `TesseraStudio/Sources/TesseraCore/Models/InterfaceLevel.swift` -- interface level.
- `TesseraStudio/Sources/TesseraCore/Models/QuantizationReceipt.swift` -- quantization receipt.
- `TesseraStudio/Sources/TesseraCore/Views/OnboardingView.swift` -- onboarding (the craft offender).
- `TesseraStudio/Sources/TesseraCore/Views/LibraryView.swift` -- library view.
- `TesseraStudio/Sources/TesseraStudioMac/App/ContentView.swift` -- macOS content view.
- `TesseraStudio/Sources/TesseraStudioMac/App/SidebarGroup.swift` -- sidebar group.
- `TesseraStudio/Sources/TesseraStudioMac/App/ProductivityBootstraps.swift` -- bootstraps.
- `TesseraStudio/Sources/TesseraStudioMac/App/ChatFocusCoordinator.swift` -- chat focus.
- `TesseraStudio/Sources/TesseraStudioMac/Views/Editor/TesseraDiffOverlayView.swift` -- diff overlay.
- `TesseraStudio/Sources/TesseraStudioMac/Views/Editor/AgentCursorOverlay.swift` -- agent cursor.
- `TesseraStudio/Sources/TesseraStudioMac/Views/Editor/FindReplaceBar.swift` -- find bar.
- `TesseraStudio/Sources/TesseraStudioMac/Views/Editor/EditorUndoCoordinator.swift` -- undo.
- `TesseraStudio/Sources/TesseraStudioMac/Encryption/ConfirmationPanel.swift` -- confirmation panel.
- `TesseraStudio/Sources/TesseraStudioMac/Encryption/PleadTheFifthMenuItem.swift` -- menu item.
- `TesseraStudio/Sources/TesseraStudioMac/Encryption/ReportWindow.swift` -- report window.
- `TesseraStudio/Sources/TesseraStudioiOS/App/ContentView.swift` -- iOS content view.
- `TesseraStudio/Sources/TesseraStudioiOS/Views/ChatPanel/ChatPanelView_iOS.swift` -- iOS chat panel.

## Part 8: File Index

| File | Size | Purpose |
|---|---|---|
| `00-prioritized-report.md` | 14.3 KB | Ship-first ranking + ship sequence |
| `comprehensive-report.md` | -- KB (this file) | Master consolidation |
| `implementation-plan.md` | -- KB | Wave-by-wave plan with 4 parallel agents per wave |
| `01-onboarding-first-task.md` | 10.6 KB | Review #1, onboarding + first task |
| `02-chat-agent-loop.md` | 8.9 KB | Review #2, chat + agent loop |
| `03-proactive-notifications.md` | 11.9 KB | Review #3, proactive + notifications |
| `04-approval-autonomy-offramp.md` | 8.1 KB | Review #4, approval + autonomy + off-ramp |
| `05-verification-diff-error.md` | 9.7 KB | Review #5, verification + diff + error |
| `06-anti-ai-slop-craft.md` | -- KB | Review #6, anti-AI-slop craft audit |

All files at: `/var/folders/72/cyz7gwcd5jsg_71j09s7pnmm0000gn/T/tessera-studio-review/`

The skill: `/Users/user/.zcode/skills/agent-ux-fatigue/`
