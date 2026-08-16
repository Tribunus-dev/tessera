# P2-B track B3 findings - 2.3 BezierPathController

Track: B3 (2.3 BezierPathController: BezierPathController.swift,
ShapePath.swift evolution, ShapeRenderer.swift `.bezier` case,
ODGBridgeFilter.swift `.bezier` draw:path I/O). Findings file per the
wave brief's per-track convention (not shared with other tracks' files
this wave).

No `XCTExpectFailure` findings in this file - every test written this
session is contract-true AND passes against the code written alongside
it (verified via standalone Swift-script reproductions of the exact
algorithms, run against real data including a real `soffice` conversion
- see item 3 below - since this session may not run `swift build`/
`swift test` on the shared checkout). The entries below are
DESIGN-JUDGMENT-CALL records per doctrine's "derive a stub, record it,
test against it" rule, submitted for architect ratification, not
suspected-bug reports.

## 1. `ShapePath` coordinate space: shape-LOCAL, not canvas-absolute

**The situation.** Neither the wave opener's `ShapePath.swift` nor
`Shape.swift`'s `path` field doc comment states outright whether a
`ShapePathPoint` is in the shape's own local (0...width, 0...height)
frame or in canvas-absolute (`ShapeGeometry.x`/`.y`-offset) coordinates.
Two clues point in different directions on a first read:
`ShapePath.swift`'s header cross-references `ShapeGeometry`'s "unrotated
0...width/0...height" language, which `ShapeGeometry.anchorPoint`'s own
doc comment explicitly glosses as "not canvas coordinates" (LOCAL); but
`ShapeKind.bezier`'s doc comment says `Shape.geometry`'s x/y/width/
height "carries the path's bounding box," which read literally (`geometry
== boundingBox(path)`) would imply the points are ALREADY
canvas-absolute.

**The call: LOCAL.** Three independent reasons converged on this:

1. **Every other `*Path` function in `ShapeRenderer.swift`** builds an
   absolute-canvas-space `CGPath` by explicitly ADDING `g.x`/`g.y` to a
   locally-computed shape (`regularStarPath`'s
   `center = CGPoint(x: g.x + g.width / 2, ...)`), and `render(_:in:)`
   establishes NO shape-local CTM translate anywhere - `applyFlip`/
   `applyRotation` only rotate/mirror around a pivot, they never
   `translateBy(x: g.x, y: g.y)`. A `.bezier` renderer using
   canvas-absolute points would be the only kind that needed no
   `+ g.x`/`+ g.y` step, breaking the file's one established pattern.
2. **A LOCAL model needs zero rewriting on move/resize.** Canvas-absolute
   points would mean `TransformController.resize`/`.applyingGroupDelta`
   (which today only ever touch `ShapeGeometry.x`/`.y`/`.width`/
   `.height`) would ALSO need to rewrite every point of every affected
   `.bezier` shape's path on every drag frame - a large, invasive,
   cross-cutting change nothing in this item's contract or the P1
   `TransformController`/`SnapEngine` precedent hints is needed.
3. **ODF's own `draw:path` convention matches LOCAL directly.** A real
   `svg:d`'s coordinates are relative to that element's own `svg:viewBox`,
   never the page - confirmed empirically (see item 3). A LOCAL
   `ShapePath` maps onto that with NO offset arithmetic in
   `ODGBridgeFilter`'s export/import; canvas-absolute would need an
   extra denormalize-then-renormalize step on every round trip. Given
   this type's own header names "binding round-trip targets" as the
   entire reason for the classic-subpath-model choice, the option that
   round-trips for free is very likely the intended one.

**Implementation:** `ShapeRenderer`'s new `bezierPath(_:origin:)` adds
`shape.geometry.x`/`.y` to every local point before handing the `CGPath`
to `context.addPath`. `ODGBridgeFilter`'s `.bezier` export writes
`svg:viewBox="0 0 <geometry.width> <geometry.height>"` and passes
`shape.path`'s points straight through as `svg:d` (viewBox extents equal
the LOCAL point space 1:1, by construction, so no rescale is needed on
export); import rescales FROM whatever `svg:viewBox` a real file
declares back INTO that same local space via the new
`ShapePath.rescaled(from:to:)`.

Requesting ratification: if a canvas-absolute model was actually
intended, the fix is confined to `ShapeRenderer.bezierPath` (drop the
`origin` offset) plus `ODGBridgeFilter`'s two call sites (denormalize/
renormalize around `shape.geometry.x/.y` there instead) -
`BezierPathController` and `ShapePath`'s own codec are coordinate-space-
agnostic and would not need to change either way.

## 2. `kindIsFillable` reviewed, not changed - open subpaths already fill correctly

Per this track's own instruction ("revisit kindIsFillable if a bezier
subpath being OPEN vs CLOSED should affect fillability... your call").
Reviewed and left the opener's blanket "`.bezier` is fillable"
unchanged, with the reasoning recorded as a doc comment at the call
site (`ShapeRenderer.kindIsFillable`) and re-summarized here:

SVG's own painting model fills an open subpath by treating it as
IMPLICITLY closed for the fill computation only, never for stroking.
CoreGraphics' `context.fillPath()` already applies this exact rule to
any `CGPath` containing open subpaths (the same PDF/PostScript imaging-
model convention SVG's spec follows) - and `bezierPath(_:origin:)` only
calls `.closeSubpath()` when `subpath.closed == true`, so
`context.strokePath()` correctly never draws a phantom closing edge for
an open subpath. The SVG/ODF-correct behavior falls out of the existing
fill/stroke split for free; gating fillability on a subpath's own
`closed` flag at the whole-KIND level would be both unnecessary and
wrong (a `.bezier` can mix open and closed subpaths in one shape).
Verified with a real offscreen-bitmap render test
(`ShapeRendererTests.testBezierShapeWithAnOpenSubpathStillFillsViaCoreGraphicsImplicitClose`).

## 3. Empirical soffice probe findings (`draw:path`, item 2.3's own I/O work)

Probed 2026-08-15 against LibreOffice 26.2.5.2
(cd7284b4cbbfeb507e630c1aac019f4157393acb) - hand-authored fodg fixtures
with a `draw:path` element, converted fodg->odg->fodg through this
machine's real `soffice`, diffed the re-exported element; additionally
re-verified against a full `ODGBridgeFilter`-shaped Drawing->export->
import round trip via a standalone script reproducing the actual
`ShapePath`/`ODGBridgeFilter` algorithms (this session may not run
`swift build`/`swift test` directly - see the wave brief's constraints).
Both the pure-pair tests (`ODGBridgeFilterTests.swift`, no soffice) and
the live probe (`ODGBezierPathWireFormatProbeTests.swift`) encode these
findings as pinned assertions, not just prose:

1. **`svg:d` accepts hand-authored absolute M/L/Q/C freely.** A
   hand-written `svg:d="M0 0 L400 0 L400 300 Z"` (or with `Q`/`C`)
   imports into real soffice correctly - confirms this bridge's
   encoder does not need to mimic soffice's own terser relative-command
   style to be readable by a real ODF processor.
2. **Quadratic curves are promoted to cubic on soffice's own re-export.**
   soffice's internal path model only stores cubic beziers; a `.quad`
   command survives a round trip as an EQUIVALENT `.cubic` (verified via
   the standard degree-elevation control points: for
   `Q 20,15 40,0` from `(0,0)`, soffice's own re-export produces cubic
   control points at exactly 1/3 and 2/3 of the way along the quad's own
   control-point-elevation formula). Accepted, documented loss (like
   `lineAttributes`'s own documented height loss) - the PURE
   `ShapePath.pathData`/`parsingPathData(_:)` codec is NOT lossy for
   `.quad`; only a real external soffice round trip is.
3. **A closed, curve-free `.bezier` is demoted to `draw:polygon` on
   export.** soffice's own internal PolyPolygon model simplifies a
   straight-line-only closed outline; the element comes back as
   `draw:polygon` (with `draw:points`), not `draw:path`. The
   `"ts-kind:bezier"` `draw:name` marker survives on EITHER element, so
   `ODGBridgeFilter.shapePath(for:boxGeometry:)` reads whichever the
   shape actually landed on rather than assuming `draw:path`.
4. **`draw:id` is dropped for any shape nothing else in the document
   references** - confirmed for a plain, isolated `draw:rect` too, so
   this is NOT specific to `.bezier`: soffice only preserves an ODF
   `draw:id` when something else in the same document actually
   references it (a `draw:connector`'s `draw:start-shape`/`draw:end-
   shape`, per the existing connector probe's own shapes, which ARE
   referenced). `ODGBridgeFilter`'s import already handles a missing/
   unrecognized `draw:id` by minting a fresh `UUID`
   (`uuid(fromDrawID:)`'s existing fallback), so this does not break
   re-import - it just means an UNREFERENCED shape's own Tessera-side
   identity does not survive a real ODG round trip, for every shape
   kind, not only `.bezier`. Flagging for awareness since
   `ODGBridgeFilter.swift`'s own header comment currently claims
   `draw:id` has "no risk of being silently dropped by a real ODF
   processor" - true only when something references the shape; worth a
   header-comment amendment in a future pass, out of this track's own
   file list to touch today.
5. **Foreign (non-Tessera) `draw:path` elements now structurally infer
   `.bezier`.** Added `case "draw:path": return .bezier` to
   `shapeKind(for:)`'s structural fallback (previously any `draw:path`
   without this bridge's own marker was silently skipped, same as an
   unrecognized `draw:custom-shape`) - matches the existing
   `.rect`/`.ellipse`/`.line`/`.polygon`/`.connector` structural-recovery
   precedent for every other native ODF primitive.

## 4. `BezierPathController`'s bend-tool math: cubic, not quad, with an exact zero-offset identity

The design contract names only "converting a straight line segment into
a smooth curve by dragging" - not which curve TYPE the bend tool
produces. Chose CUBIC (both `ShapePathSegment.quad` and `.cubic` were
available): control points at exactly 1/3 and 2/3 along the original
straight line, each displaced by the drag `offset`. This has an exact,
testable property backing the choice (pinned in
`BezierPathControllerTests.testBendWithZeroOffsetProducesACubicThatStillTracesTheStraightLine`):
a cubic bezier whose two control points sit ON the straight line at the
1/3/2/3 parametric marks traces that EXACT straight line, so
`offset == .zero` is a real identity, not an approximation - the bend
tool reads as "still a straight line" until the user actually drags.
