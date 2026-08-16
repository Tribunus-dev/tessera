# P2-B findings - Track B1 (2.1 SMILAnimationTree + 2.10 Custom shows)

Track ownership: `SlideDeck.swift` (sole owner this wave), `SlideStore.swift`,
`SlideReceiptType.swift`, new `SMILAnimationTree.swift`, `LOBridgeDeckIO.swift`
(fodp SMIL tree + custom-show I/O), new test files
`SMILAnimationTreeTests.swift`,
`SlideDeckAnimationTreeAndCustomShowTests.swift`,
`SlideStoreAnimationTreeAndCustomShowTests.swift`,
`LOBridgeDeckIOSMILAndCustomShowTests.swift`, plus one enabled test in
`AnimationEffectListP1FixtureTests.swift` (T4's file from a prior wave -
the ONE pre-authorized exception, per that file's own header comment
and this wave's own item list).

One row per design decision or scope note worth flagging - not
necessarily bugs. No `swift build`/`swift test` was run against this
(per this wave's dispatch brief - a centralized pass runs after all 4
tracks land); every claim below is backed by manual tracing, not a
compiler run. Flagging that plainly rather than silently implying more
confidence than a build actually gives.

---

## Design decision: `excl` is preserved via a flagged `.par`, not a 5th `SMILNode` case

The design contract's own words: "excl: parse-and-preserve as flagged
par." `SMILNode` has exactly 4 cases (`par`/`seq`/`iterate`/`behavior`)
per the type sketch given verbatim in the wave brief - there is no
5th case for SMIL's "exclusive" time container. Adding one would also
force the doctrine-pinned "9 SMIL node types" independent-oracle guard
(testing-doctrine.md rule 7) to either grow past 9 or leave `excl`
without a `nodeType` at all, either of which felt like a bigger
departure from the literal type sketch than the contract's own "flagged
par" phrasing implies.

Resolution: `SMILTimingProps.exclMarkerPresetClass` (`"tessera:excl-
container"`) is a reserved sentinel. `LOBridgeDeckIO`'s importer stamps
it onto a `.par` node's `presetClass` when the source element was
literally `anim:excl` (not `anim:par`); the exporter checks for the
sentinel and writes `anim:excl` back out (stripping the sentinel from
`presentation:preset-class` first, so it never round-trips into a real
preset-class value). `SMILTimingProps` already had a free `presetClass:
String?` slot in the contract's own field list, so this reuses existing
capacity rather than adding a field. `excl` is rare in real PowerPoint/
Impress content (interactive media triggers mostly) and no test-list
item asked for more than parse-and-preserve, so this got one guard test
(`testExclMarkerPresetClassIsDistinctFromAnyRealPresetClass`) rather
than a full fixture - flagging for architect ratification since it's a
real judgment call, not a documented mechanism.

## Design decision: animation-target addressing is 4 positions per slide, not per-block

`LOBridgeDeckIO`'s EXISTING per-slide content export (`collectSlideContent`
/ the frame-building loop in `mapToFlatODFTree`, present before this
wave) aggregates every body paragraph into ONE `draw:frame` and
discards individual paragraph-block identity entirely - a pre-existing
property of that path, not something this wave introduced. Since SMIL
`smil:targetElement` needs SOME stable id to reference, and the export
path had no per-block id scheme at all before this wave, I added one:
`animationFrameID(forRootSlideID:position:)` addresses exactly 4
positions per slide (whole-slide, title, aggregated body, Nth image),
matching the 4 kinds of frame the export path already produces.

Consequence: an `AnimationTarget.blockID` naming one specific body
paragraph among several on the same slide is NOT separately addressable
through fodp I/O today - it resolves to the same "body" frame id every
other paragraph on that slide would. This is a real, load-bearing
limitation for a genuinely per-paragraph `iterate` build (the design
contract's own example use case for `iterate`), and it inherits
directly from the pre-existing content-export granularity rather than
from anything added this wave. Fixing it properly means giving the
general slide-content export path (not just the animation code) real
per-block `xml:id`s, which is a broader change than this track's file
list supports touching safely in a shared checkout. In-memory
`SMILAnimationTree`/`AnimationTarget` values themselves have NO such
limitation (full `blockID` + `paragraphIndex` addressing, as the type
sketch specifies) - only the fodp *wire* round trip is narrowed. Tests
in this wave stay within the 4-position granularity (title/body/image
targets, never two distinct body paragraphs on one slide) so nothing
is silently asserting a stronger guarantee than the code gives.

## Design decision: `smil:begin` wire encoding is this bridge's own, not verified against real soffice

Per testing-doctrine.md rule 10 (empirical probes are quarantined and
labeled): the 5 `SMILCondition` cases needed SOME `smil:begin` string
encoding, and I chose one informed by real SMIL/ODF syntax
(`"indefinite"`, `"<id>.click"`, offset suffixes) but not identical to
it in every particular (e.g. `"after-previous;0.5s"` rather than a
sync-base-id-relative form like `"prev.end+0.5s"`), specifically so
this bridge's own reader is guaranteed to invert its own writer without
needing a live `soffice` round trip to verify. This is explicitly
DIFFERENT from `resolveTransitionCatalogID(forPage:root:)`, which
documents exactly when it does and does not trust a real ODF value
(P1, already soffice-verified elsewhere in this file). The hand-authored
fodp fixture test (`testFodpFixtureWithOnClick...`) exercises this
bridge's OWN reader against hand-built `FlatODFElement` trees using this
same encoding - it proves internal consistency, not fidelity to a real
Impress-exported `.fodp`. If a later wave gets a real soffice-exported
animation fixture, re-verifying this encoding against it (and adjusting
if real Impress output differs) is exactly the kind of gated/quarantined
probe rule 10 describes - flagging it here so that work isn't lost.

## Design decision: `SMILBehavior.animateEffect` names ODF's `anim:transitionFilter`

The type sketch's case list says `animateEffect` (not `transitionFilter`
or `animEffect`), matching neither ODF's nor OOXML's own element name
verbatim. Per the sota report, ODF's actual preset-driven entrance/exit/
emphasis behavior element is `anim:transitionFilter`
(`smil:type`/`smil:subtype`/`smil:direction`); OOXML's equivalent is
`p:animEffect`. Since the contract's case name doesn't literally match
either wire format, I picked ODF's `anim:transitionFilter` as the fodp
mapping (this bridge routes exclusively through fods, never OOXML
directly, per decision 12) and documented the naming choice in
`SMILBehavior`'s own doc comment. If `animateEffect` was actually meant
to name a DIFFERENT ODF/OOXML element I'm not aware of, the fix is a
one-line rename of the `mapBehavior`/`mapBehaviorElement` case strings -
no data-model change needed.

## Scope note: `SlideStore` gained exactly 2 new mutation methods for 2.1, not more

The wave brief says "SlideStore gains a mutation method using this" -
singular. I read that as naming `setAnimationTree` as the one REQUIRED
method, and additionally added `clearAnimationTree` (reusing the
EXISTING `.removeAnimationEffect` receipt, per the brief's own
constraint on which 2 receipt types the tree may reuse) since "remove
every effect at once" is a natural, low-risk counterpart to
`removeAnimationEffect`'s single-index removal and exercises the
`.removeAnimationEffect` reuse the brief explicitly calls out. No other
tree-shaped mutation (e.g. editing a single behavior node in place) was
added - the P1 precedent (`setAnimations` replaces the whole list;
there is no single-effect "update" method either) suggested whole-value
replacement is this codebase's established granularity for animation
mutations, and I matched it rather than inventing a finer-grained API
the design contract doesn't ask for.

## Scope note: custom shows have no agent-tool wiring in this track

The sota report's 2.10 section names an agent tool, `deck_custom_show_set`
(tier1). This track's file list is data-model + store + fodp I/O only
(`SlideDeck.swift`/`SlideStore.swift`/`SlideReceiptType.swift`/
`LOBridgeDeckIO.swift`) - no `Tools/` file is listed, and the wave
brief's own summary line says "data only, no UI" without mentioning the
tool surface. Not wired here; `SlideStore.defineCustomShow`/
`updateCustomShow`/`removeCustomShow` are the ready-to-wrap surface
whenever an agent-tools pass picks this up.

## Verification caveat

Every claim in this track (including the pinned-fixture round trip,
the property test, and the fodp fixture parse) was checked by manual
symbolic tracing through the actual code paths, NOT by running `swift
build`/`swift test` - the wave's dispatch brief explicitly withholds
build/test access from individual tracks this wave (4 agents share one
checkout; a centralized pass runs after all land). The pinned-fixture
trace in particular (`animation-effect-list-p1.json`'s 5 effects / 3
click groups, walked by hand through `init(flat:)` then `flattened()`)
reproduced the original array element-for-element, which is the
strongest evidence available pre-build that the core totality/left-
inverse contract holds - but it is not a substitute for the centralized
`swift build && swift test` pass actually compiling and running this
code.
