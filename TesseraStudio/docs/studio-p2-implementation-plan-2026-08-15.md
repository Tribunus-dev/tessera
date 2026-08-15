# Studio P2 Implementation Plan (2026-08-15)

**Status:** RATIFIED - decision 17 approved by the architect 2026-08-15
(chat approval; recorded as §8 row 17 of the expansion plan). Execution
unblocked. Same modus operandi as P1: ratified per-item design contracts ->
wave briefs -> aggressive agent implementation with milestone commits and
minimal verification -> deferred post-claim audit before merge.
**Inputs:** `p1-post-claim-audit-2026-08-15.md` (defines Wave P2-0);
`.scratch/sota-p2-core-report.md` (new contracts for 2.1/2.2/2.5/2.6/2.7/
2.9/2.10/2.11 + wave partitioning); the already-ratified designs
(refinement doc §4-5 + plan §8 rows 12-16) for 2.3, 2.12, 2.13-2.21.
**Branch model:** continue on `scratch/studio-p1/agent-a` -> rename-free
sequel branches `scratch/studio-p2/wave-<X>` cut from the previous wave's
tip; nothing merges to main until the deferred gate passes over the whole
line.

## 1. Wave P2-0 - P1 gap closure (BLOCKING; nothing stacks on unwired features)

Source: audit §3. This wave has no new features; it makes the P1 claims
true at the lifecycle/UX layer and turns the corpus harness into the real
primary-metric source every later parity claim needs.

- 0.1 Integrity fixes FIRST (audit Class A): DrawingStore no-op-receipt
  fix; commit the TokenArray OFFSET/INDIRECT exclusion (HEAD wrong-answer
  bug); review sortRange hiddenRows semantics; then commit the dirty tree
  as scoped per-cluster gap-closure commits with honest bodies (the 1.6
  body states the original was non-persisting).
- 0.2 Corpus harness made REAL: fixture corpus per §6f targets (real DOCX/
  ODS/XLSX/PPTX/ODP/ODG files incl. tables, footnotes, charts, themes,
  masters, conditional formats) + import->export->score per feature axis +
  a scoreboard artifact the wave gate reads. (The audit found 6 toy
  fixtures and a loader that scores nothing.)
- 0.3 CalcBridgeFilter CSV -> fods migration (ratified in decision 12,
  never executed) + the 1.21 legacy-import @-prefixing that it unblocks.
- 0.4 Surface wiring: CF overlay -> sheet paint path; interactive
  validation -> editor entry path; filter hiddenRows -> grid view; Draw
  canvas gesture layer consuming TransformController + SnapEngine with
  one-drag-one-undo via ReceiptUndoManager.group (the contract clause with
  zero callers today).
- 0.5 Slides wiring: 1.20 deck storage + store mutations +
  slide_animation_* receipts (prerequisite for 2.1); ColorRef completion
  (StyleDefinition + ShapeFill); frameU geometry data for the 25 builtin
  layouts.
- 0.6 Writer/Draw lifecycle: 1.2 note insert/delete + receipts +
  endnote-section/popover rendering; group/ungroup (row 48) API + receipts
  + TransformController recursion; 1.4 media write path + receipt + AVKit
  playback view; comment reply/resolve/delete receipts.
- 0.7 Test-strength debt (audit Class C): independent 20-name OOXML
  transition totality pin; non-gpu fallback enforcement in validate();
  chart-matrix pixel assertions; TESSERA_DB_INTEGRATION=1 pass in every
  wave gate; transition catalog JSON-vs-Swift-literal decision recorded.

Agent split (4 agents, disjoint files): 0-A Calc (0.1 Calc parts, 0.3,
CF/validation/filter wiring), 0-B Slides (0.5, transition/test debt),
0-C Draw (0.1 Draw parts, gesture layer, group/ungroup, media), 0-D
Writer + harness (notes lifecycle, comments, 0.2 corpus, DB-gated CI
wiring). Exit gate: full suite + one DB-integration pass green; corpus
scoreboard produces numbers; audit Class A empty.

## 2. Waves P2-A..D - the feature waves

Full agent-level partitioning, file ownership, and sequencing rationale:
`.scratch/sota-p2-core-report.md` "Proposed P2 waves" (adopted as-is).
Summary:

| Wave | Items | Notes |
|---|---|---|
| P2-A Calc core | 2.2a pivot compute (A1), 2.7 subtotals (A2), 2.6 solver (A3), 2.8 stats tools + 2.9 reviewer panel (A4) | No new deps; pure Swift on landed infra |
| P2-B Slides/Draw deep | 2.1 SMIL tree + 2.10 custom shows (B1), 2.19 GPU transitions + 2.17 3D extrude (B2), 2.3 bezier (B3), 2.2b pivot I/O (B4) | Opener splits FlatODFReader/Writer into per-surface files |
| P2-C Writer + Draw finish | 2.5 ToC + 2.11 master docs (C1), 2.4 mail merge -> 2.21 wizard (C2), 2.14 StarMath (C3, Package.swift owner: SwiftMath), 2.12 Draw advanced + 2.18 morph (C4) | C consumes B's bezier |
| P2-D Enterprise/compliance | 2.13 macros (D1, opens PreservedParts), 2.15 forms (D2), 2.16 database (D3, Package.swift owner: GRDB+DuckDB), 2.20 tagged PDF (D4) | Heaviest deps + integration risks last; 2.20 preflights exporters that all exist by then |

Standing rules every wave inherits: one-commit wave opener pre-landing ALL
of the wave's additive receipt-enum cases + shared-model fields (the P1
prep-commit pattern that produced zero merge collisions); exactly one
Package.swift owner per wave; 3-4 agents max on disjoint file sets; single
build at a time; soffice semaphore <= 2 with isolated profiles; soffice
tests skip when absent.

## 3. Design contracts

Per-item contracts (file paths, evolves/peer relations, type sketches,
receipts, test contracts, effort):

- NEW this plan (in `.scratch/sota-p2-core-report.md`): 2.1 SMILAnimationTree
  (L), 2.2 PivotTableStore staged P2a/P2b (XL total), 2.5 ToC (M), 2.6
  Solver - native goal-seek + linear simplex, nonlinear engines punted
  (M), 2.7 Subtotals (M), 2.9 Reviewer panel - Writer-first scope note
  (S), 2.10 Custom shows (S), 2.11 Master documents - data-only manifest
  (S), 2.4 restatement.
- ALREADY RATIFIED (refinement doc §4-5, decisions 12-16): 2.3 bezier
  (P2), 2.12 Draw advanced, 2.13 macros, 2.14 equations, 2.15 forms, 2.16
  database, 2.17 3D extrude-only, 2.18 morph, 2.19 GPU transition tier,
  2.20 tagged PDF, 2.21 merge wizard.

Binding constraints repeated because every P2 wave touches them: nothing
_v2 (SheetPivotDefinition EVOLVES; AnimationEffectList becomes the tree's
projection, never a parallel type); every mutation = store + exactly one
receipt, and receipts fire ONLY on actual change (the audit's integrity
finding is now a standing rule with a name: no receipt without a
mutation); the 1.20 and new sheet-pivot-definition-p0 fixtures are never
edited; derived-never-stored (note numbers, toc collection, animation
grouping, pivot grids).

## 4. Measurement architecture (§6f applies to every item)

Primary = corpus-harness survival on the axes the item owns (the P2-0.2
scoreboard makes this real); trust = corpus import-failure/crash count
stays 0; anti = per-wave pick (recalc p95 for Calc items; render time for
slides/draw; binary size for dep-adding items D3/C3). Wave briefs state
the three numbers + week before implementation. Additionally per item:
the named test contracts in §3 are the claim-vs-evidence anchors the
deferred audit will check - a wave that lands code without its named
tests is PARTIAL by definition.

## 5. Execution mode (the P1 modus operandi, kept - with the two lessons)

Same architect-amended mode as P1 (plan §5d amendment): milestone commits
on the scratch branch pre-approved, minimal verification per milestone
(build + targeted tests), full suite + DB-integration pass at wave gates,
NO push/PR/merge; the verifier + post-claim audit gate runs before any
merge, and a fresh audit runs after EVERY wave (not one deferred audit
after four waves - the P1 lesson: gaps compound silently). Machine
constraints unchanged (16GB M1: <= 4 agents, one build at a time, soffice
<= 2, no simulator/installs). Second lesson now binding: commit bodies
must disclose non-persisting or partial states in the SUBJECT's own terms;
the audit treats an undisclosed no-op as an integrity finding, not a gap.

## 6. Decision 17 (for ratification - one yes/no/amend)

Ratify: (a) the eight new design contracts + 2.4 restatement in
`.scratch/sota-p2-core-report.md` as written, including 2.6 = native
Swift goal-seek + linear simplex with DEPS/SCO-class nonlinear solving
recorded out of scope, 2.9 = Writer-first with the Calc half satisfied by
the receipts drawer, and 2.11 = data-only assembly manifest (no live
subdocument editing, no .odm); (b) Wave P2-0 as a blocking gap-closure
wave inserted before feature waves, scoped by the audit's §3 list; (c)
the P2-A..D wave structure and standing rules of §2; (d) the "no receipt
without a mutation" standing rule; (e) per-wave audits replacing the
single deferred audit. On ratification this row is copied into the
expansion plan's §8 as decision 17 and the wave-0 prompt may launch.

## 7. Launch prompt template (per wave)

Each wave gets ONE prompt built from this template (fill the [WAVE]
blocks; wave 0's is ready first):

```
Implement Wave [X] of the Tessera Studio P2 plan. I am the architect;
this prompt carries my standing approvals for this session.
Read first, in order: AGENTS.md; TesseraStudio/docs/
studio-p2-implementation-plan-2026-08-15.md (sections 1-5);
TesseraStudio/docs/.scratch/sota-p2-core-report.md (your wave's design
contracts); TesseraStudio/docs/p1-post-claim-audit-2026-08-15.md
(sections 1-3, the standing integrity rules).
Work in /Users/user/Developer/GitHub/tessera-docwork. Branch: create
scratch/studio-p2/wave-[X] from [previous tip]. Wave opener commit
FIRST: [the wave's shared-enum cases + shared-model fields, one commit].
Then the agent split: [agent-by-agent item + owned-file list from plan
section 1 or 2 - no two agents touch the same file].
Orchestration: I explicitly opt in to multi-agent workflows (Workflow
tool). Max [3-4] concurrent agents; NEVER more than one swift build/test
at a time across all agents; soffice <= 2 with isolated profiles; no
simulator, no installs beyond this wave's declared Package.swift owner.
Commits: milestone commits pre-approved, one per deliverable slice,
subject "P2 [n]: <component> - <what landed>", body states verification
run AND any partial/non-persisting state explicitly - an undisclosed
no-op is an integrity violation, not a gap. Receipts fire only on actual
mutations. Never commit red. NO push, NO PR, NO merge.
Verification: build + targeted tests per milestone; at the wave gate run
the full suite + one TESSERA_DB_INTEGRATION=1 pass + the corpus
scoreboard, and post the three §4 metric numbers for each item.
Stop conditions: a slice that cannot go green in ~30 minutes is reverted
and logged as blocked with the reason; blocked items continue to the
next; do not stop to ask permission for anything covered above.
```

## 8. Sequence from here

1. Architect ratifies decision 17 (and answers nothing else - all other
   questions were settled in rows 12-16).
2. Launch Wave P2-0 with the filled template.
3. Per-wave: audit -> fix -> next wave prompt.
4. After P2-D's audit: the full verifier gate + P0-P2 claims pass over
   the whole branch line, then the merge decision - the human's, as
   always.
