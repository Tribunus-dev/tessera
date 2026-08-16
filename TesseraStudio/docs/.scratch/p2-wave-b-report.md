# Wave P2-B report (2026-08-15) - Slides/Draw deep + pivot I/O

**Scope:** SMIL animation tree full evolution (2.1) + custom shows
(2.10); GPU transitions (2.19) + Draw 3D extrusion (2.17); bezier path
editing (2.3); pivot table P2b (2.2b) + two P2-0 gap items (CF
aggregate-cache wiring, the `@` implicit-intersection operator). Branch
`scratch/studio-p2/wave-b`, 6 commits (`9132bfee8` wave opener through
`6d6e27426`), starting tip `5a2f66882` (the P2-A gate). 4-agent Workflow
dispatch (B1-B4) on disjoint files, followed by a centralized
DrawingStore wiring pass (withheld from B2/B3 the same way SheetStore
was withheld in Wave P2-A) and verification.

## 1. Per-item verdicts

| Item | Track | Verdict | Note |
|---|---|---|---|
| 2.1 SMILAnimationTree | B1 | DONE | Full type sketch, total `init(flat:)`, `flattened()` verified as left inverse against the real pinned P1 fixture |
| 2.10 Custom shows | B1 | DONE | Data-only, prune-on-read semantics |
| fodp I/O for both | B1 | PARTIAL | Animation-target addressing narrowed to 4 positions/slide - inherits a pre-existing granularity limit in this file's export path, not a regression |
| 2.19 GPU transitions | B2 | DONE | All 10 real `.gpu` catalog presets render (7 CoreImage, 3 CATransform3D); honest fallback preserves presetId for anything else |
| 2.17 Draw 3D extrusion | B2 | DONE | Extrude-only via SceneKit, exactly the ratified minimal scope |
| 2.3 BezierPathController | B3 | DONE | Full edit state machine, real CGPath rendering, real ODF draw:path I/O verified against live soffice |
| 2.2b pivot P2b (6 sub-parts) | B4 | 5 DONE, 1 PARTIAL | fods encode is real+tested but has no live export-path caller yet (CalcBridgeFilter still exports via CSV) |
| CF aggregate-cache wiring (gap a) | B4 | DONE | top10/aboveAverage/uniqueValues/duplicateValues now paint for real |
| `@` implicit-intersection operator (gap b) | B4 | DONE | Full Lexer->Parser->Evaluator path + legacy-import marking wired into CalcBridgeFilter |
| DrawingStore.setExtrusion/.setPath | wiring | DONE | Both with explicit no-op guards (not the unguarded `mutatingShape` helper) |

## 2. Bugs found and fixed during centralized verification

Given this wave's 4 agents collectively could not run `swift build` even once (shared checkout, by design), the FIRST real build over ~9,000 lines of new/changed code across SMIL trees, GPU renderers, SceneKit extrusion, a bezier edit state machine, and a formula-language operator addition surfaced remarkably little:

1. **`ShapeExtrusionRenderer.swift` redeclared `PlatformColor`** - a `private` typealias colliding with the existing PUBLIC one in `Editor/BlockRenderer.swift` (module-wide visible, so both were in the redeclaration site's lookup scope). Removed the redundant local one.
2. **`ShapeExtrusionSceneView.swift` used a bare `Shape` type**, ambiguous between SwiftUI's own `Shape` protocol and TesseraCore's `Shape` struct once both modules are imported in the same file. Qualified as `TesseraCore.Shape` at each use site.

That's the entire fix list. Both were mechanical, neither touched any test assertion or design decision - a strong signal for how disciplined the 4 tracks' manual verification (hand-tracing, `swiftc -parse`, and in B3's case, standalone script reproductions run against a real local soffice binary) actually was.

Two agents also caught real bugs in their OWN work before it ever shipped, worth noting since they're the kind of thing that would have been much more expensive to find later:
- B2 found and fixed a geometry bug in `turningHelix`'s foreshortening math (`max(cos,...)` instead of `abs(cos,...)`) while writing its own tests.
- B4 found and fixed three of its own test-authoring bugs (a header-row-count off-by-one, an ASCII text-sort-order assumption, a missed subtotal-gating interaction) during self-review.

## 3. Known gaps (real, documented, not hidden)

- **fods pivot round-trip is decode-only in the live path.** Encode is a real, tested pure function with no caller - `CalcBridgeFilter.exportWorkbook` still exports via CSV. Wiring it in needs a full `Sheet -> fods` serializer, which doesn't exist yet (the same blocker class 1.21's `@`-prefixing was in, before this wave's own gap-b work unblocked THAT one in a different file).
- **SMIL animation-target addressing through fodp is narrowed to 4 positions per slide**, not the type's own full blockID+paragraphIndex model - inherited from `LOBridgeDeckIO`'s general content-export granularity, not introduced this wave.
- **GPU transition playback has no presenter-mode host to wire into** - `GPUTransitionPlaybackView` is a complete, tested, standalone view; nothing in the app has a slideshow/presenter surface yet.
- **3D extrusion preview is not wired into `DrawDetailView`/`DrawCanvasView`** - presentation-layer-only per this slice's own scope; `ShapeExtrusionSceneView` is a real, tested, standalone preview.
- **Reference (show-data-as) pivot modes**: only the 4 needing no base-field/base-item shipped (`.normal`/3 percent-of variants); difference-from/running-total/rank/index deferred - genuinely under-specified in the design contract (names the LO field, not a mode list).
- **`.compact` pivot layout is a table-wide mode**, read off `rowFields.first` - does not reproduce Excel's per-level "outer group gets its own dedicated row" nuance.
- **`TokenArray.swift`'s RPN evaluation path does not get position-aware `@` reduction** - only the AST-walking Evaluator path does; out of this wave's file scope.
- Several design-judgment calls were made where no doc answered the question (ShapePath's local-vs-canvas coordinate space, pivot reference-mode vocabulary, `.compact`'s scope, fods attribute spelling with no real soffice-authored pivot sample to check against) - all implemented, tested, and recorded in each track's findings file for architect ratification, not silently guessed.

## 4. Gate

- **Default suite:** 2157 tests, 215 skipped, **0 failures**, ~32s.
- **`TESSERA_DB_INTEGRATION=1`:** 2157 tests, 1 skipped, **0 failures**, ~38s.
- **`TESSERA_CORPUS_HARNESS=1` (its own explicit pass):** 1 test, **0 failures**, ~209s. Scoreboard regenerated, numbers unchanged from Wave P2-A - this wave's Draw/Slides bridge changes (ODGBridgeFilter, LOBridgeDeckIO) aren't exercised by the corpus's current fixture set's scored axes.
- **Audit Class A (correctness/integrity):** empty. Both new DrawingStore methods carry proper no-op guards from the start (no repeat of the historical "DrawingStore no-op-receipt defect" this doctrine document itself is named after).

## 5. Sequence from here

Per the plan: commit this report (done, same commit as this file), then
cut `scratch/studio-p2/wave-c` from this tip for Wave P2-C (ToC + master
documents, mail merge + wizard, StarMath equations, Draw advanced +
morph).

**Note:** per the architect's explicit instruction, this wave's tip
merges to `main` immediately after this report, ahead of Waves P2-C/D -
see the merge commit for the human sign-off this represents.
