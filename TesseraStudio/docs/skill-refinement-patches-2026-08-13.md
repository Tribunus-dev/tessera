# Skill Refinement Patches (2026-08-13)

**Status:** proposed patches for two built-in skills. Not applied at runtime (built-in skills are immutable). Apply via MR to the upstream Mavis skill source.
**Author:** Mavis (orchestrator), per the user's post-claim audit of the agent-ux-fatigue sprint (2026-08-13)
**Companion to:** `studio-expansion-plan.md`, `agent-tools-surface.md`, `docs/AGENT-UX-FATIGUE-REVIEW.md`, `AGENTS.md`

---

## The problem (one paragraph)

Two Mavis skills — `superpowers:verification-before-completion` and `code-review` — together cover "before you claim" and "per-code-scope defects." Neither covers the post-claim audit shape: an independent, evidence-driven check that the claim itself is sound. The agent-ux-fatigue sprint shipped a 14-unit plan whose docs said "everything landed" and "no tests failed" — but the audit (2026-08-13, performed by the user) caught:

- 251 compile errors during the sprint (the docs called these "a small set of pre-existing build breaks")
- An integration-test target that hung forever (the docs claimed "if a cross-wave bug surfaces, the test FAILS with a clear message")
- A metric layer with 42 metrics that were unrunnable given the committed healthy-surface constraints (`telemetryEnabled` defaults to `false`, no `URLSession`, no user cohort)
- Three "shipped" units (3D audit log panel, 2C time-limited undo chip, 1B/4B trust chips) that were defined but never instantiated or had no open path; the 1B/4B chips were on `ConfirmationPanel` (the disk-wipe dialog) instead of the actual agent approval path
- A `/var/folders/...` "source of truth" directory that was purged on reboot, leaving dead citations in HANDOFF §5

The gap is the absence of an integrity pass on the claim itself. Pre-claim verification asks "did *I* run the tests?"; the missing pass asks "is the *claim* backed by reachable surfaces + runnable metrics + live provenance?"

## The evidence (per the audit)

- **3D audit log panel** — `ActionAuditLogPanel` (~780 LoC) referenced outside its own file **exactly twice — both doc comments** in `ConfirmationPanel.swift`. Never instantiated. Metric "% of sessions where the audit panel is opened" is unrunnable on a panel with no open path.
- **2C time-limited undo** — `TimeLimitedUndoChip`: **zero** references outside its defining file. `EditorUndoCoordinator`: same. Metric "% of undo-affordance impressions ignored" is unrunnable on an affordance with no impressions.
- **1B / 4B trust chips** — landed on `ConfirmationPanel.swift` (the disk-wipe dialog, reachable only from `PleadTheFifthMenuItem`), not the agent approval path. Commit `468e94263` titled "ApprovalSheet actionClass/risk/irrevisibility" modified `ConfirmationPanel.swift`; the title and the diff disagree.
- **Integration tests** — `AgentUXFatigueIntegrationTests` hung forever. A hang is a non-result, not a failure. No unit in the sprint was actually verified.
- **Measurement architecture** — 42 metrics presuppose a shipped product with cohorts (week-8 retention, bounce rate) that don't exist; telemetry is local-only and `telemetryEnabled` defaults to `false`. The measurement layer makes the sprint look validated when it's unvalidated.
- **Provenance** — HANDOFF §5 cites `/var/folders/72/cyz7gwcd5jsg_71j09s7pnmm0000gn/T/tessera-studio-review/`; `ls` returns "No such file or directory." Every `01-` through `06-` citation is dead.

## The two refinements

Both refinements add a section to an existing skill. They are surgical additions (not rewrites). They pair to form a closed loop:

- **`verification-before-completion` gets a "Post-claim audit" section** — the *system-level* integrity check (build green at the moment of the claim? test target compiled? metrics runnable? provenance real?).
- **`code-review` gets a "Claim-vs-evidence pass" section** — the *per-unit* integrity check (surface instantiated? open path real? call from agent real? chip reachable?).

Run both when reviewing a multi-unit work claim: the system-level catches "the build was broken" / "the metrics were unrunnable" / "the citations were dead"; the per-unit catches "this surface was defined but never mounted" / "this affordance had no caller" / "this chip was on the wrong dialog."

---

## Patch 1 — `superpowers:verification-before-completion`

**File:** `/Users/user/.minimax/v2/plugin-cache/official/sha256-tree-v1-bf6dac84f67f4b71ac9b85c305c19f586799caa8ac3015cd860775c586ffbdac/skills/verification-before-completion/SKILL.md` (or the upstream source)
**Problem:** the skill covers pre-claim self-verification but not the post-claim audit shape. A claim can be "evidence-backed from the inside" (the agent ran the tests) and "evidence-less from the outside" (the test target didn't compile, the metric data source was disabled, the cited path was purged).
**Evidence:** the agent-ux-fatigue sprint produced a "everything landed" claim that was unrunnable from the outside.
**Rationale:** adding a "Post-claim audit" section makes the system-level integrity check a first-class pass, not an afterthought. The section pairs with the existing pre-claim content as a closed loop (self-verify before claim, independent audit after).
**Add to the end of the skill (after "When To Apply" / "Rule applies to:"):**

```markdown
## Post-claim audit (system-level integrity)

Pre-claim verification checks whether *you* can back up the claim. The
post-claim audit is a separate, independent pass that checks whether
the claim itself can be backed up. Run it whenever a multi-unit work
claim (sprint, audit, expansion plan) is declared shipped; the audit
is the gate that catches intent-vs-outcome gaps at the system level.

### System-level checks

For each "shipped" / "landed" / "delivered" / "metric" claim with a
system-level scope, run all four:

1. **Build was green at the moment of the claim.** Run the full build
   fresh, in the same turn as the claim, and read the exit code and
   count of errors. A "build was green earlier" or "linter passed" is
   not sufficient. If the build is not green, retract the claim.

2. **Test target actually compiled and ran.** Open the test target's
   compile log. A test target that didn't compile is a non-result; you
   cannot claim "X tests pass" if no test ran. A hang is the worst
   failure mode (produces no message); verify the test target
   terminates. If the test target is broken, retract the claim.

3. **Measurement architecture is runnable from the live constraints.**
   For every metric in the measurement layer (one-primary + one-trust +
   one-anti), verify: (a) the data source exists, (b) the data source
   is reachable given the committed constraints (e.g. "telemetry
   defaults to off" means the metric is unrunnable on a fresh install),
   (c) the cohort the metric presupposes (e.g. "week-8 retention")
   exists or is planned. If any metric is unrunnable, retract it from
   the measurement table or label it "when we have users" / "post-
   ship" — do not leave it as a checkmark that means nothing.

4. **Cited "source of truth" paths actually exist on disk.** For every
   path the doc calls a source of truth (`/var/folders/...`,
   `~/...`, `tools/...`), verify with `ls` / `read` / `find` that the
   path resolves. macOS temp dirs are purged on reboot; a citation to
   a `/var/folders` path that no longer exists is a dead citation.
   Either commit the artifact to the repo or remove the citation.

### Why this is a separate pass

Pre-claim verification is the agent's self-check: "I just ran the
tests; the tests passed; I can claim complete." The post-claim audit
is an integrity check on the claim itself, run by an independent
auditor (or a fresh session): "the claim says 'shipped'; is the
shipped surface actually reachable by a user, and are the supporting
metrics actually runnable?" A complete sprint can look shipped from
the inside (build green at some moment, tests existed, metrics
defined) and be unrunnable from the outside (build broken, tests
hung, metrics dependent on telemetry that's disabled, cited source
purged). The post-claim audit catches the outside view.

### Anti-patterns

- "Nothing was deferred" / "everything landed" without an explicit
  test-target-compiled + measurement-architecture-runnable check.
- "Build was green at some point" as a substitute for "build is green
  right now."
- Citing a `~/...` or `/var/folders/...` path without verifying the
  path resolves on the auditor's machine.
- Reporting "X tests pass" when no test target compiled.
- A measurement metric whose data source contradicts a healthy-
  surface commitment in the same doc.

### Pair with `code-review` (claim-vs-evidence pass)

The post-claim audit is the *system-level* integrity check (this
section). The per-unit integrity check — does the "shipped" surface
mount? does the open path exist? does the new chip have a caller? —
lives in the `code-review` skill's claim-vs-evidence pass. Run both:
the post-claim audit (here) catches the system-level gaps; the
per-unit review (code-review) catches the surface-level gaps.
```

---

## Patch 2 — `code-review`

**File:** `/Users/user/.minimax/.builtin-skills/code-review/SKILL.md` (or the upstream source)
**Problem:** the skill covers per-code-scope defects but not the per-unit integrity check on a work claim. A surface can be defined in a file with no internal defect and still be unreachable by a user.
**Evidence:** the agent-ux-fatigue sprint produced three "shipped" units (3D, 2C, 1B/4B) that the per-scope review would have read and found clean — but the per-unit integrity check would have caught that none of them had an open path or a real call site.
**Rationale:** adding a "Claim-vs-evidence pass" section makes the per-unit integrity check a first-class pass. The section pairs with the verification-before-completion post-claim audit as a closed loop (system-level + per-unit).
**Add to the end of the skill (after "Response"):**

```markdown
## Claim-vs-evidence pass (per-unit integrity)

When the review scope is a *work claim* (a sprint, an audit, an
expansion plan, a "shipped" summary), the standard per-code-scope
review is necessary but not sufficient. A surface can be defined in
a file, referenced by zero callers, and yet be claimed "shipped" in
the docs. The standard review reads the file and finds no defect; the
claim-vs-evidence pass checks whether the file is part of a reachable
user path.

Run the claim-vs-evidence pass whenever the user names a work claim
as the review target. The four checks:

1. **Is the surface instantiated?** Grep the project's surface entry
   points (main views, main view-models, navigation flows) for the
   surface's class name. If the only references are doc comments or
   the surface's own file, it is not instantiated. A class that is
   defined but never instantiated is not a shipped surface.

2. **Is there an open path from the user?** Trace the navigation
   from the app launch (or the relevant top-level view) to the
   surface. If the path is "defined here, called from nowhere," the
   surface is unreachable. An unreachable surface cannot be claimed
   "visible to the user" or "landed."

3. **Is the call real, not just a comment?** When a doc says
   "wired into X" or "rendered via Y," verify the wire. A
   `ConfirmationPanel` is not the agent-approval surface just because
   both deal with confirmation; the open path through the agent
   approval flow is what matters.

4. **Is the chip / affordance reachable?** A new `TimeLimitedUndoChip`
   is not "visible" because the type exists. Grep for the
   instantiating call; if the chip is only referenced inside its own
   file, no impression is possible, and the metric "% of impressions
   ignored" is unrunnable.

### Output (per unit)

For each "shipped" / "landed" / "delivered" unit, return a row:

| Unit | Claim | Mounted? | Evidence |
|---|---|---|---|
| name + brief ref | the doc's claim | yes / no / partial | the grep / trace / path |

The "Mounted?" column is the load-bearing new information. Three
values:

- **yes** — instantiated and reachable
- **no** — defined but not instantiated, or instantiated but unreachable
- **partial** — instantiated but the open path is broken or the metric is unrunnable

### Anti-patterns

- "Linter clean" / "tests exist" as substitutes for "surface mounted
  + path real + metric runnable."
- Treating "the doc says shipped" as evidence.
- Reporting a unit as "shipped" because the file exists.
- A "no defects" per-code-scope review when the per-unit mount check
  would say "unreachable."

### Pair with `verification-before-completion` (post-claim audit)

The claim-vs-evidence pass is the *per-unit* integrity check (this
section). The *system-level* integrity check — was the build actually
green at the moment of the claim? did the test target compile? are
the measurement metrics runnable? do the cited provenance paths
exist? — lives in the `verification-before-completion` skill's
post-claim audit section. Run both: the per-unit review (here) catches
the surface-level gaps; the post-claim audit catches the system-level
gaps.
```

---

## Application path (the user does this)

Both skills are built-in (lives in `packages/local-runtime/assets/skills/` per the skill-refiner procedure). They are **immutable at runtime** — I cannot apply these patches from the Mavis session. The path forward:

1. Fork the Mavis platform repo (the upstream source for built-in skills)
2. Apply patch 1 to the `verification-before-completion/SKILL.md` file in the worktree
3. Apply patch 2 to the `code-review/SKILL.md` file in the worktree
4. Submit an MR; reference this doc and the user's post-claim audit
5. Once the MR merges, the local plugin-cache picks up the new content on the next platform refresh

If the user prefers a different path (e.g. project-local skill overrides, or a separate `tessera:verification-before-completion` and `tessera:code-review` skill pair shipped under `.zcode/skills/`), the same patch text works; only the file location changes.

## Verification (post-apply)

After the upstream merges the patches, re-load both skills via the native `skill` tool and confirm:

- The "Post-claim audit" section is present in `verification-before-completion`
- The "Claim-vs-evidence pass" section is present in `code-review`
- The frontmatter `name` and `description` are intact on both
- The existing pre-claim + per-code-scope content is unchanged

## Why I didn't create a new skill

The user picked "refine both" over the third option ("new dedicated skill `claim-vs-evidence-audit`"). The reasoning: the audit shape is naturally split into a system-level pass (build / test / metrics / provenance) and a per-unit pass (mount / path / call / chip), and the two existing skills' structures — verification-before-completion is "before-claim" + "pre-claim-self-check", code-review is "per-scope-defects" + "review-only-behavior" — are the right homes for the two halves. A single new skill would have duplicated the per-scope review and pre-claim content; refining both keeps the audit shape split along the same line the codebase already uses.

The two refinements form a closed loop:

```
pre-claim verify (verification-before-completion, existing)
   -> claim
   -> post-claim audit (verification-before-completion, NEW)
       -> per-unit claim-vs-evidence pass (code-review, NEW)
       -> per-scope defect review (code-review, existing)
   -> integrity verdict
```

The new content is additive, not a rewrite. The skill-refiner procedure (problem / evidence / rationale / surgical patch / self-check) is the right shape for this work.
