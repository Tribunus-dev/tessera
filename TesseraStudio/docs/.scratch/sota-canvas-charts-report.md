# SOTA evidence: Draw canvas + charts (P1 1.3/1.7/1.15/1.16/1.17/1.19; P2 2.3/2.12/2.17/2.18)

Prepared 2026-08-14 by the refinement-pass research agent (canvas + charts).
Evidence input to `../studio-expansion-design-refinement-2026-08-14.md`. Peer of
`lo-{writer,calc,impress}-report.md`. ASCII throughout.

## Local evidence (what P0 already defines)

All paths under `TesseraStudio/` on main.

- `Sources/TesseraCore/Productivity/Shape.swift`
  - :20-28 `ShapeKind` = rect/ellipse/line/arrow/polygon/star/freeform; the
    header comment (:17-19) already reserves ".connector" for P1 and ".bezier"
    for P2.
  - :42-86 `ShapeGeometry`: plain-Double x/y/width/height, `rotation` in
    degrees clockwise about the anchor (:47), `anchorX/anchorY` optional pivot
    in LOCAL unrotated coords, nil = center (:49-57), `frame: CGRect` and
    `anchorPoint` computed bridges (:77-85). Persisted model is
    CoreGraphics-free.
  - :96-121 `ShapeFill` (hex + opacity) and `ShapeStroke`
    (hex/width/dashPattern). No gradient, no flip flags, no path data.
  - :129-139 `ShapeText` wraps `[InlineRun]` - same inline model as Block.
  - :145-181 `Shape`: id/kind/geometry/fill/stroke/text/`zIndex` (Int, "not
    necessarily contiguous or unique" :152-155)/`parentGroupID` (:156-160).
- `Materials/Draw/Drawing.swift` :47-62 fields incl. `body: DocumentAST`,
  `canvasSize` (800x600 default), `canvasBackground`, `gridEnabled` (bool
  only - no spacing field yet); :30-42 shapes persist as `.shape` blocks via
  `attributes["shape"]` JSON bridge; layers + groups explicitly deferred to
  P1 (:39-42); :117-119 array order == paint order once `applyingZOrder` has
  run; :165-173 `applyingZOrder` rewrites rootChildren to match renumbered
  zIndex.
- `Materials/Draw/ShapeZOrder.swift` :45-70 - pure `apply(move,to:in:)`,
  dense renumber 0..n-1 every call.
- `Materials/Draw/ShapeRenderer.swift` :30-64 stateless per-shape
  `render(_:in:)`; :78-84 rotation = translate/rotate/translate about
  anchorPoint; :122-137 `path(for:)` switch - freeform currently renders its
  bounding rect as an "honest placeholder" for P2 BezierPathController
  (:130-135); text-on-shape intentionally NOT drawn, routed to the
  BlockRenderer text stack later (:60-63); :188-202 arrowhead.
- `Materials/Draw/ShapeCatalog.swift` :35-108 - per-kind defaults +
  `makeShape(kind:at:zIndex:)`; zIndex is caller's job.
- `Materials/Draw/DrawingStore.swift` :14-16 receipt contract; :264-294
  per-field setters; :299-315 shared load-mutate-upsert-receipt plumbing.
  Every mutation is one full-entity upsert + one receipt; no batch method yet.
- `Materials/Draw/DrawingReceiptType.swift` :21-62 - 20 cases;
  group/ungroup/setLayer/export/import/diff deliberately absent until P1
  (:16-20).
- `Productivity/Block.swift` :78-86 `.shape` / `.shapeGroup` (children =
  ordered member IDs, no stored geometry).
- `Editor/BlockRenderer.swift` :17-31 - pure Block -> NSAttributedString,
  stateless, platform-agnostic via PlatformFontResolver.
- `Materials/Slides/SlideLayoutSpec.swift` - SlideLayoutPlaceholder is a
  blockType tree with NO geometry yet.
- `Productivity/ReceiptUndoManager.swift` :12-21 - "one undo unit = one
  receipt"; `group(_:)` batches multiple receipts into a single undo unit.
  The landed answer to gesture-level undo batching.
- `docs/agent-tools-surface.md` :206-223 - `drawing_set_geometry` named "the
  TransformController consumer" (:208); `drawing_group`/`drawing_set_layer`
  marked P1 (:213-215); `drawing_export` formats odg/svg/pdf/png/jpg (:221).

## SOTA findings

Canvas editors
- tldraw: data/behavior split - shape records are immutable data; one
  `ShapeUtil` class per kind supplies geometry, rendering, interaction; every
  shape shares TLBaseShape (id, x/y, rotation, z index, parent, lock,
  opacity + typed props). Geometry2d backs hit-testing and snapping.
  https://tldraw.dev/sdk-features/shapes https://tldraw.dev/sdk-features/geometry
- tldraw snapping: three mechanisms - bounds snapping (edges + centers +
  corners), gap snapping (center-in-gap, duplicate-gap, matching adjacent
  gaps), handle snapping. Threshold is SCREEN-space: 8 screen px divided by
  zoom. Indicators: alignment lines through matched points; gap indicators
  with measurement ticks. https://tldraw.dev/sdk-features/snapping
- tldraw tools: interaction is a StateNode hierarchy (root -> tool -> child
  states; select = idle/pointing/brushing/translating/resizing...).
  https://tldraw.dev/sdk-features/tools
- tldraw license: source-available with watermark, paid business license to
  remove; PATTERNS only for Tessera, no code.
  https://tldraw.dev/community/license
- Excalidraw: scene = flat element array; per-element version + random
  versionNonce for deterministic conflict resolution at merge (exists to
  serve P2P sync).
  https://plus.excalidraw.com/blog/building-excalidraw-p2p-collaboration-feature
- Figma vector networks: vertices may join ANY number of edges (paths cap at
  2); superset of paths; needs face/region fill detection and decomposition
  back to paths for SVG export.
  https://www.figma.com/blog/introducing-vector-networks/
  https://alexharri.com/blog/vector-networks

Transform handles
- Resizing a rotated shape: unrotate the pointer into local space, resize
  there, then recompute origin so the fixed point (opposite handle) keeps its
  canvas position. https://shihn.ca/posts/2020/resizing-rotated-elements/
- Opposite-handle-as-anchor and drag-past-opposite = flip are the established
  conventions. https://paint.net/doc/latest/ShapeTools.html
  https://konvajs.org/docs/select_and_transform/Basic_demo.html

Connectors
- libavoid: orthogonal visibility graph + A*, optimal in bends + length;
  incremental; a full C++ library.
  https://www.adaptagrams.org/documentation/libavoid.html
- Simple elbow routing (3-5 segments from escape stubs) is the office-suite
  behavior.
  https://medium.com/swlh/routing-orthogonal-diagram-connectors-in-javascript-191dc2c5ff70
- OOXML: connectors are `p:cxnSp` with `a:stCxn id/idx` / `a:endCxn` - shape
  id + connection-site index. http://officeopenxml.com/drwCxnSp.php
- ODF: `draw:glue-point` with id, position, `draw:escape-direction`; each LO
  shape has 4 default glue points + user-defined ones.
  http://www.datypic.com/sc/odf/e-draw_glue-point.html

Charts
- Vega-Lite: mark + encoding channels with scales/axes/legends INFERRED by
  default rules. Adopt the defaults philosophy, not the model.
  https://vega.github.io/vega-lite/
- OOXML chart: `c:chartSpace > c:chart > c:plotArea` holding typed chart
  groups (c:barChart, c:lineChart...) each with c:ser (series with c:cat +
  c:val caches) plus c:catAx/c:valAx. A series-list model, not a grammar.
  https://www.datypic.com/sc/ooxml/e-draw-chart_plotArea-1.html
- The "14 LO chart types" (Calc Guide 25.2 ch.7 gallery): Column, Bar, Pie
  (incl donut/exploded), Of-Pie, Area, Line, XY(Scatter), Bubble, Net, Stock
  (4 variants), Column-and-Line, Pivot charts, Box plots (stacked-column
  technique), Sparklines.
  https://books.libreoffice.org/en/CG252/CG25207-GalleryOfChartTypes.html
- Axis ticks: d3 - tick step is a power of 10 times 1, 2, or 5; nice()
  extends the domain to those boundaries. https://d3js.org/d3-array/ticks
- Frequency: column/bar, line, pie dominate office charts; the rest are a
  long tail.
  https://www.dummies.com/article/technology/software/microsoft-products/excel/10-excel-chart-types-and-when-to-use-them-2-203150/

Morph / 3D
- PowerPoint Morph: automatic matching of objects in common across
  consecutive slides, overridable by renaming both objects with the same
  `!!Name`; unmatched objects crossfade.
  https://support.microsoft.com/en-us/office/morph-transition-tips-and-tricks-bc7f48ff-f152-4ee8-9081-d3121788024f
- Keynote Magic Move: animates the delta of matched objects (copy/duplicate
  identity); text matching By Object / By Word / By Character.
  https://support.apple.com/guide/keynote/add-transitions-tanff5ae749e/mac
- LO Draw 3D (fucon3d.cxx scope): "To 3D" = extrusion; "To 3D Rotation
  Object" = lathe; plus a primitives toolbar in a lit scene tilted 20 deg.
  https://books.libreoffice.org/en/DG75/DG7507-3DObjects.html
- SceneKit SCNShape: builds a 3D mesh by extruding an NSBezierPath with
  extrusionDepth + chamfer - OS-native extrusion, no mesh code. No lathe
  equivalent. https://developer.apple.com/documentation/scenekit/scnshape

## Design recommendations

### 1.15 LayerStore
- Files: `Materials/Draw/LayerStore.swift` (new: `DrawLayer` value type +
  pure ops, peer of ShapeZOrder); `Drawing.swift` evolves (`layers:
  [DrawLayer]` default [] = one implicit layer, old JSON decodes);
  `Shape.swift` evolves (`layerID: UUID?`, nil = default layer);
  `DrawingStore.swift` evolves (persist + receipt wrappers);
  `DrawingReceiptType.swift` evolves (add layerAdded/layerDeleted/
  layerUpdated/layersReordered/shapeSetLayer).
- Layer model: ordered named bands - `DrawLayer {id, name, isVisible,
  isLocked, isPrintable}`, band order = array position. Deliberately STRONGER
  than LO (where layers are attribute filters that do not affect stacking):
  every modern tool treats layer order as paint order; ODG round-trip
  survives because ODF stores layer membership and document order separately
  - export writes shapes in effective paint order.
- zIndex interplay: effective paint order = stable sort by (band position,
  zIndex). ShapeZOrder.apply gains nothing; callers filter the layer subset,
  apply, splice back (`Drawing.applyingZOrder` becomes layer-scoped). zIndex
  stays dense per layer. Renderer skips hidden layers; hit-testing skips
  locked layers (view-model concern).
- NOT a second data-layer seam: DrawingStore remains the only writer;
  LayerStore is the pure logic it calls (the ShapeZOrder precedent).
- Test contract: paint order is (band position, zIndex); hiding a layer
  removes its shapes from the render list without mutating zIndex; every
  layer mutation emits exactly one receipt.
- Phase: P1.

### 1.17 SnapEngine
- File: `Materials/Draw/SnapEngine.swift`, pure + stateless, peer of
  ShapeZOrder. No receipts - snapping adjusts a PROPOSED geometry before
  TransformController commits.
- Inputs: `SnapContext {targets, canvas, gridSpacing?, zoomScale}` built once
  per gesture-begin from visible, unlocked, non-selected shapes (target =
  rotated-AABB minX/midX/maxX + minY/midY/maxY, plus page edges + center);
  per move: `snap(proposed) -> SnapResult`.
- Output: `SnapResult {dx, dy, guides: [SnapGuide]}` with SnapGuide =
  .alignment(axis, position, throughPoints) | .gap(axis, between) |
  .grid(point). Engine emits guide DATA only; the canvas view draws them.
  Axes resolve independently; nearest candidate under threshold wins per
  axis.
- Threshold model: screen-space constant divided by zoom - `threshold = 8.0 /
  zoomScale` in canvas points (tldraw's exact model). Rotation snapping (for
  TransformController): multiples of 15 deg within a 5-deg window.
- Scope order: (a) grid + page + edge/center object snap first; (b)
  gap/equal-spacing guides second - the most complex third, additive to the
  same SnapResult shape.
- Perf bound: per-axis sorted target arrays built at gesture start (prune to
  viewport + margin, cap ~256 targets); each move is binary search; <= 1 ms
  per move at 1k shapes, no per-event allocation.
- Test contract: a proposed frame within threshold of a target edge/center
  returns an adjustment landing EXACTLY on the target plus the matching
  guide; outside threshold returns identity and no guides.
- Phase: P1.

### 1.16 TransformController
- File: `Materials/Draw/TransformController.swift` - pure geometry math + a
  small gesture-session struct; peer of SnapEngine; consumed by the canvas
  view model and `drawing_set_geometry`.
- Handle set: 8 resize handles + 1 dedicated rotation handle above top-center
  (LO/PowerPoint convention). Handles render in screen space.
- Anchor math: resize anchor = opposite handle; Option = center anchor;
  Shift = aspect lock. Rotated shapes use the shihn.ca method:
  inverse-rotate the pointer about the pivot into local space, resize
  locally, then solve x/y so the anchor's WORLD position is unchanged.
  Critical rule: transient gesture anchors are NEVER written into
  `ShapeGeometry.anchorX/anchorY` - the stored anchor stays the ROTATION
  pivot contract (Shape.swift:49-57); gesture fixed-points are ephemeral.
- Flip: evolve ShapeGeometry with `flipH: Bool = false, flipV: Bool = false`
  (defaulted, old JSON decodes). Render order = flip about local center,
  THEN rotation about anchor - matching OOXML a:xfrm (flipH/flipV + rot) and
  ODF, so round-trip is field-for-field. Dragging past the opposite handle
  sets the flip flag and keeps width/height non-negative.
- Multi-select: capture member geometries in selection-box-normalized coords
  at gesture start; map back per-axis on box change; group transform
  recurses to shapeGroup children. Multi-rotate: rotate member centers about
  the selection pivot and add the delta to each member's rotation.
  Non-uniform scale of a rotated member applies to its frame without skew -
  the LO/PowerPoint approximation; no skew field.
- Undo/receipt batching: live drag mutates a preview copy - ZERO store
  writes per move event. On gesture end, commit once: single shape -> one
  setGeometry receipt; multi-select -> per-shape receipts wrapped in
  `ReceiptUndoManager.group(_:)` so one Cmd-Z reverts the gesture. No new
  receipt vocabulary needed.
- Test contract: resizing a rotated shape about the opposite corner keeps
  that corner's world position fixed to 1e-9; one full drag session = one
  undo unit.
- Phase: P1.

### 1.19a Connector ShapeKind
- Files: `Shape.swift` evolves - `ShapeKind.connector` + optional field
  `connector: ConnectorInfo?`; new `Materials/Draw/ConnectorRouter.swift`,
  peer of ShapeRenderer; `ShapeRenderer.path(for:)` gains the `.connector`
  arm; DrawingReceiptType evolves (connectorAttached/connectorDetached).
- Data model: `ConnectorInfo {start: ConnectorEnd, end: ConnectorEnd, style:
  .straight | .elbow | .curved}`; `ConnectorEnd {attachedShapeID: UUID?,
  gluePointID: Int?}` - unattached endpoints use the geometry frame's corner
  pair (the `.line` convention). A typed field, not an attributes blob.
- Glue points: computed defaults, not stored - 4 compass midpoints indexed
  0-3 (LO's default set) with kind-derived escape directions. (shapeID,
  gluePointID) maps 1:1 onto OOXML stCxn id/idx AND ODF glue-point ids, so
  both round-trips are direct. Custom user glue points = P2 (`gluePoints:
  [GluePoint]` evolution; normalized local coords).
- Routing: deterministic escape-stub elbow router at P1 - exit perpendicular
  from each glue point by a 16 pt stub, then a 3-5 segment Manhattan route,
  detouring around ONLY the two attached shapes' AABBs (office connectors do
  not avoid unrelated obstacles). The route is DERIVED at render time from
  the attached shapes' current frames - never persisted. libavoid-class
  global avoidance stays behind the ConnectorRouter seam as a P2+ upgrade.
- Test contract: an elbow route exits along each glue point's escape
  direction, contains only axis-aligned segments, and never crosses either
  attached shape's frame.
- Phase: P1 (custom glue points + avoidance upgrades P2).

### 1.19b ShapeText editing contract
- Files: canvas edit mode in the Draw editor view; `ShapeRenderer.swift`
  evolves to draw static shape text; NO new core type.
- Static rendering: ShapeText.runs -> transient Block(.paragraph, content:
  runs) -> BlockRenderer -> attributed string -> CTFramesetter into an inset
  text rect, drawn inside render(_:in:) after fill/stroke (context already
  carries the shape's rotation). One text stack, ever
  (ShapeRenderer.swift:60-63's promise).
- Edit mode: double-click enters `editingText(shapeID)` in the select-tool
  state machine (tldraw StateNode pattern). First-responder handoff: overlay
  a platform NSTextView/UITextView positioned over the text rect with
  zoom+rotation applied via layer transform; Esc/click-away resigns and
  returns to idle-selected. The overlay edits an attributed string produced
  by BlockRenderer and maps back to [InlineRun] on end.
- Commit granularity: one DrawingStore.setText on end-editing = one receipt
  = one undo unit.
- Bullets inside shape text: P2 (2.12). Direction on file: ShapeText evolves
  to carry paragraph structure (paragraphs: [[InlineRun]] + per-paragraph
  list style) - an evolution, never a second text type.
- Test contract: runs -> attributed string -> runs round-trips annotation
  boundaries losslessly; one edit session emits exactly one receipt.
- Phase: P1 (bullets P2).

### 1.3 ChartSpec + ChartRenderer
- Files: `Productivity/ChartSpec.swift` (new value type, peer of Shape);
  `Views/Renderers/ChartRenderer.swift` (peer of the other Views/Renderers);
  `Block.swift` evolves - `.chart` case with attributes["chart"] JSON bridge
  + a Block.chart accessor, mirroring the landed attributes["shape"] bridge.
- Model choice: a series-typed spec (ECharts/OOXML-shaped), NOT a
  mark/encoding grammar. OOXML c:plotArea is a list of typed chart groups
  each holding c:ser + axis ids; ODF chart is the same shape. A
  Vega-Lite-style grammar forces lossy inference in BOTH round-trip
  directions. What we take from Vega-Lite is the defaults philosophy: an
  incomplete spec renders - axes, legend (auto when series > 1), palette,
  and nice scales are inferred.
- Sketch (JSON stored in the block attribute):
```
ChartSpec {
  kind: column|bar|line|area|pie|scatter|bubble|net|stock|columnLine
  stacking: none|stacked|percent
  variants: pieInnerRatio (donut), explodedOffsets,
    lineMarkers: pointsOnly|pointsAndLines|linesOnly,
    stockVariant: 1|2|3|4, ofPie: none|bar|pie
  categories: [String]?
  series: [ {name, values:[Double?], role: value|open|high|low|close|
             volume|size|x, axis: primary|secondary, colorHex?} ]
  axes: { category: AxisSpec?, value: AxisSpec?, secondary: AxisSpec? }
  legend: { position: none|right|bottom|top|left }
  title?, subtitle?
  style: { palette:[hex], gridlines: Bool, fontSize }
}
AxisSpec { title?, min?, max?, tickCount?, logarithmic: Bool, labelFormat? }
// labelFormat = a NumberFormatEngine format code
```
- The 14 LO types map onto ~10 renderer kinds + spec combos: Column/Bar =
  one cartesian path with an orientation flag; Pie/Donut/Exploded = .pie +
  variants; Of-Pie = .pie + ofPie; Line/Area/XY = marker/fill/axis flags;
  Bubble = .scatter + size role; Net = polar transform of line/area; Stock =
  OHLC glyph pass + stockVariant; Column-and-Line = two series groups +
  secondary axis. The remaining 3 of 14 are NOT renderer kinds: Pivot chart
  = a PivotTableStore-fed data source producing an ordinary spec; Box plot =
  LO builds it as a stacked-column technique; Sparkline = a Sheets-surface
  preset of this same renderer (no axes/legend, cell-sized). That is the
  honest reconciliation of "full 14-type parity" with one renderer.
- Staging: P1a = column, bar, line, area, pie/donut, scatter - the dominant
  families, exercising the entire shared core (category+value scales,
  d3-style 1-2-5 nice()/ticks(), legend, palette, stacking). P1b = bubble,
  net, stock, column-and-line, of-pie (+ sparkline preset). Cut-line
  rationale: each P1b member adds exactly one orthogonal mechanism on top of
  an unchanged P1a core - deferring them delays no architecture, only leaf
  drawing code.
- Ticks: d3's algorithm verbatim (step = 10^k x {1,2,5}; nice() extends the
  domain to step boundaries).
- Test contract: every (kind x stacking x variant) combination renders into
  an offscreen CGContext without a fallback path; ticks(min,max,count)
  yields 1-2-5 steps covering the niced domain.
- Phase: P1 (P1a then P1b inside the wave).

### 1.7 SlideDeckRenderer
- Files: `Materials/Slides/SlideDeckRenderer.swift` (evolves BlockRenderer -
  mode-aware, not a parallel text stack) + DeckExportCoordinator;
  `SlideLayoutSpec.swift` evolves - SlideLayoutPlaceholder gains an optional
  normalized frame (`frameU: {x,y,w,h} in 0..1`), with the 4 built-in specs
  growing default frames. (Composes with the picker refinement's idx/name
  addition - one evolution, two new optional fields.)
- Approach: per slide, one CGContext pass - (1) resolve layout to
  placeholder frames; (2) text-bearing blocks -> BlockRenderer
  (EditorMode.slideCanvas styling) -> CTFramesetter into placeholder rects;
  (3) free .shape/.shapeGroup blocks -> ShapeRenderer in zIndex order; (4)
  .chart blocks -> ChartRenderer. One CGContext substrate serves the
  on-screen canvas, PNG/JPG export, and PDF.
- Test contract: a title+content slide renders deterministically into a
  fixed-size bitmap with text inside placeholder frames and shapes in z
  order.
- Phase: P1.

### 2.3 BezierPathController
- Files: `Materials/Draw/BezierPathController.swift` (peer of
  ShapeRenderer); `Shape.swift` evolves - `path: ShapePath?` +
  `ShapeKind.bezier`; `ShapeRenderer.path(for:)` replaces the freeform
  bounding-rect placeholder by reading ShapePath.
- Model choice: classic subpath model - `ShapePath {subpaths: [Subpath]}`,
  `Subpath {segments: [move|line|quad|cubic], closed: Bool}`, points in
  shape-local coords so all TransformController math applies unchanged. NOT
  Figma vector networks: ODG round-trip is binding, and ODF
  draw:path/enhanced geometry and OOXML custGeom are both path-command
  formats - a network model makes every export a lossy decomposition. The
  one network-era UX worth adopting is path-compatible anyway: the bend tool
  (drag a segment to curve it).
- Edit-mode state machine: `PathEditState = idle | draggingAnchor(i) |
  draggingControl(i, in|out) | pen(appending) | bend(segment) | marquee`.
  Node conversions corner <-> smooth <-> symmetric. One receipt per
  completed operation (new `drawing_shape_path_changed` case).
- Test contract: insert/delete/convert keep the emitted CGPath continuous;
  ShapePath round-trips through SVG path-data serialization losslessly.
- Phase: P2.

### 2.18 Draw morph - minimal viable design (recommend: build)
- Files: `Materials/Slides/MorphTransition.swift` (peer of the P1
  AnimationEffectList; at P2 it rides the SMIL tree as a transition node) +
  a small ShapeInterpolator.
- Matching: by `Shape.id` first - Tessera has what PowerPoint lacks: stable
  UUIDs on every shape. Design decision to record: slide-duplication flows
  MUST preserve shape ids so morph pairing is automatic (Keynote's
  copy-identity model). Fallback pass: same kind + nearest geometry.
  Unmatched shapes crossfade (PowerPoint's own fallback). NO `!!`-name
  convention: it exists only because PowerPoint's UI lacked exposed
  identity.
- Interpolation: pure `interpolate(_ a: Shape, _ b: Shape, t: Double) ->
  Shape` - lerp x/y/w/h, shortest-arc lerp rotation, RGB-lerp fill/stroke
  hex, opacity lerp. The player renders interpolated values through the
  existing ShapeRenderer each frame - morph costs one pure function. Text
  morphs by crossfade only; kind-mismatched or path-mismatched pairs
  crossfade rather than vertex-morph (vertex correspondence is the genuinely
  hard problem; PowerPoint punts it the same way).
- Verdict: minimal-viable morph is cheap BECAUSE Shape is a value type -
  recommend building at P2 as scoped, not re-punting.
- Test contract: morphPairs matches by id then kind; interpolate(a,b,0) == a
  and interpolate(a,b,1) == b field-for-field.
- Phase: P2.

### 2.17 Draw 3D - minimal viable design (recommend: extrude-only via SceneKit)
- Files: `Materials/Draw/ShapeExtrusion.swift` (value type: depth,
  chamferRadius, materialHex, sceneTiltX/Y defaulting to LO's 20-deg
  presentation tilt) as an optional `Shape.extrusion` evolution; a
  Shape3DSnapshotter in the view layer wrapping SCNShape + SCNRenderer.
- Scope: LO's fucon3d surface = extrude + lathe + primitives toolbar.
  Credible minimal 3D = EXTRUDE ONLY: SCNShape natively turns the outline
  into an extruded, chamfered mesh - zero mesh code - and an offscreen
  SCNRenderer snapshot composites into the CGContext at the shape's frame,
  preserving the one-substrate rule. Lathe has NO SceneKit equivalent
  (custom surface-of-revolution mesh = a real subsystem); the
  primitives/lighting/texture UI is a second inspector surface; both stay
  out.
- Recommendation, evidence-backed: ship extrude-only at P2 IF 2.17 must
  ship; otherwise re-punting remains defensible - the original punt
  rationale still holds, ODF dr3d:scene round-trip would be P3 at best (P2
  extrusions export rasterized - an honest, recordable limitation), and
  2D-gradient faking is rejected outright. Extrude-only is the only middle
  ground both credible and small; anything more re-opens the punt.
- Test contract: a fixed camera + fixed extrusion renders a deterministic
  offscreen snapshot composited at the shape's frame.
- Phase: P2, explicitly severable.

### 2.12 Draw advanced (context)
Annotations, measure/dimension lines, Draw tables, shape-text bullets -
measure lines become a `ShapeKind.dimension` peer of connector (two anchor
points + auto label using the connector's stub math); Draw tables reuse
`.table` blocks positioned via `.frame`; bullets per 1.19b. No new
subsystems. Phase: P2.

## What NOT to adopt

- tldraw CODE or SDK: source-available with watermark/business-fee licensing
  - and React/DOM besides. Patterns only: per-kind util, StateNode
  interaction states, the 8px-screen-space snap threshold, the three-way
  snap taxonomy.
- Figma vector networks: lossy against ODF/OOXML/SVG path formats that are
  the binding round-trip targets; adopt classic subpaths.
- libavoid-style global obstacle avoidance at P1: office-suite connectors do
  not avoid unrelated shapes; multi-KLoC dependency deferred behind the
  ConnectorRouter seam.
- Vega-Lite (or any mark/encoding grammar) as the STORED chart model:
  two-way lossy against c:ser-shaped office formats; only its defaults
  philosophy carries over.
- Excalidraw's version/versionNonce sync machinery: solves P2P merge;
  Tessera's receipt chain is already the mutation log and local-first story.
- Swift Charts (re-affirming decision 6): cannot draw into arbitrary
  CGContexts, which the PDF/PNG/slide pipeline requires.
- Store writes per drag move event: violates one-gesture-one-undo and floods
  receipts; commit once per gesture.
- Writing transient resize anchors into ShapeGeometry.anchorX/anchorY: the
  stored anchor is the ROTATION pivot contract; gesture fixed-points are
  ephemeral math.
- PowerPoint's `!!` name-matching for morph: a workaround for missing
  identity; Shape.id UUIDs are strictly better.
- 2D-gradient "fake 3D": neither credible nor round-trippable;
  extrude-via-SceneKit or keep the punt.
- Canvas-space snap thresholds: unusable across zoom levels; screen-space
  divided by zoom is the evidenced standard.
