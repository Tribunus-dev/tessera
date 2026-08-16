# P2-C findings - Track C3 (2.14 StarMathEditor - LaTeX-first over SwiftMath)

Track ownership: `Package.swift` (this wave's owner), SOLE owner of
`Editor/BlockRenderer.swift` and `Productivity/DocumentExporter.swift`,
new `Editor/StarMathEditor.swift`, new
`Productivity/ImportExport/EquationImportMapping.swift`, new
`Tests/.../BlockRendererEquationTests.swift`,
`Tests/.../DocumentExporterEquationTests.swift`,
`Tests/.../StarMathEditorTests.swift`,
`Tests/.../EquationImportMappingTests.swift`.

One row per blocker, scope note, or design decision worth flagging -
not necessarily bugs.

---

## Cross-track note: FieldController.swift/FieldControllerTests.swift are modified by another in-flight track this wave

`git status` at the time of this write shows `Productivity/Editor/
FieldController.swift` and its test file already modified by another
parallel agent (consistent with the SOTA report's own note that
`FieldKind` reserves `mergeField` as a later case, and with the new
untracked `MailMergeCoordinator.swift`/`MailMergeTools.swift`/
`MailMergeWizardView.swift` files - item 2.4). This track never edits
`FieldController.swift` (confirmed: only reads it and calls
`FieldController.refresh(_:in:clock:)`, its existing public API,
exactly as `FieldControllerTests.swift`'s own `.sequence` tests do). An
additive new `FieldKind` case does not change `.sequence(name:)`'s
existing behavior (Swift's enum-with-associated-values Codable
synthesis decodes each case independently by name), so
`StarMathEditorTests.swift`'s equation-numbering tests remain valid
regardless of that other track's landing order.

## Design decision: SwiftMath dependency coordinates + target placement

`https://github.com/mgriebling/SwiftMath.git`, pinned `from: "1.7.0"`
(latest tag at write time was 1.7.3; MIT license confirmed via the
repo's `LICENSE` file, "Copyright (c) 2023 Computer Inspirations").
Verified via GitHub, not guessed: the Package.swift/README/source were
fetched directly (`Sources/SwiftMath/MathRender/*.swift`) to confirm
the exact API surface used below. Added to the `TesseraCore` target,
not a UI-layer target, per item 1's own question - `BlockRenderer.swift`
and `DocumentExporter.swift` are both `TesseraCore` files shared by the
macOS AND iOS app surfaces (this target's own header comment), and both
need to rasterize a `.equation` block's LaTeX.

## Design decision: `MTMathImage.asImage()`, not `MTMathUILabel`, is the rendering entry point

The design contract's item 2 text says "SwiftMath's own
NSAttributedString/view-producing API." SwiftMath exposes BOTH:
`MTMathUILabel` (an `NSView`/`UIView` subclass, needs a live view
hierarchy / window to lay out) and `MTMathImage` (a plain value type
wrapping the SAME `MTTypesetter`/`MTMathListDisplay` layout engine,
with a headless `.asImage() -> (NSError?, MTImage?)` that draws
directly into an offscreen `NSImage`/`UIImage` via
`NSGraphicsContext`/`UIGraphicsImageRenderer` - no view, no window).
Chose `MTMathImage`: (a) it is directly testable in a plain `XCTestCase`
with no host window, which the "view-producing" `MTMathUILabel` path is
not; (b) `BlockRenderer`'s OWN established shape for graphical block
content is "wrap a raster image in an `NSTextAttachment`"
(`renderImage`, already in the file, for `.image` blocks) - so equation
rendering reuses that exact existing pattern rather than inventing a
second one; (c) the same headless entry point serves BOTH
`BlockRenderer.renderEquation` (per-block) AND `DocumentExporter`'s HTML
export AND `StarMathEditor`'s live preview identically, with no
view-hierarchy plumbing threaded through any of the three.

## Design decision: DocumentExporter's `.equation` HTML export embeds a base64 PNG, not MathML

`DocumentExporter`'s own header states the pipeline is DocumentAST ->
HTML -> `textutil -convert docx/odt`. `textutil` (macOS's built-in
HTML->RTF/DOCX/ODT converter) has no MathML support - an embedded
`<math>` element would simply be stripped or mangled on the way through,
so MathML is not a real export target for THIS pipeline (it would be
for a hypothetical native OOXML/ODF writer, which is not this file's
job). Renders the SAME `MTMathImage` output `BlockRenderer.renderLaTeX`
uses, into a `data:image/png;base64,...` `<img>` - the exact shape
`.image` blocks already export (`<img src="...">`), so it survives
`textutil` exactly as any other embedded picture does. Malformed/empty
LaTeX falls back to the OLD literal `$latex$`/`[Empty equation]`
placeholder text (never throws), matching `BlockRenderer.renderLaTeX`'s
own contract for the same inputs.

## Bug found + fixed during self-review: StarMath `over` operator precedence

An earlier draft of `EquationImportMapping.swift`'s parser bound `over`
at the top `Expr := Term ('over' Term)?` level (matching the Command
Reference's documented `{<?>} over {<?>}` SHAPE literally). This is
wrong precedence: for `"x = {a} over {b}"`, `Term` for the left side
already greedily concatenates "x", "=", AND "{a}" as three factors
BEFORE `Expr` ever sees "over", producing `\frac{x = a}{b}` instead of
the correct `x = \frac{a}{b}`. Caught by hand-tracing the quadratic-
formula fixture token-by-token before trusting the test (this codebase
has no `swift test` access for this agent to verify against - see
"Residual risk" below). Fixed by moving `over` into `tryParseFactor`'s
OWN postfix loop (same level as `^`/`_`), so it binds to the single
immediately-preceding `Factor`, not the whole accumulated `Term` -
matching real StarMath's actual precedence (`over` sits above the
addition level; `{a} over {b} + c` is `\frac{a}{b} + c`, not
`\frac{a}{b+c}`). Also fixed a related redundant-brace bug the same
trace surfaced: `tryParseAtom`'s `{...}` case was re-wrapping its
already-brace-needing callers' output in an EXTRA pair of braces
(`{a} over {b}` -> `\frac{{a}}{{b}}` - harmless to a LaTeX renderer, but
noise). Both are documented in `EquationImportMapping.swift`'s own
`tryParseFactor`/`tryParseAtom` doc comments now, not just here.

## Design decision: equation numbering convention (design contract's open question, resolved "join FieldController")

A numbered equation is a `.equation` block immediately followed by a
SIBLING `.field` block (same parent, next `children`/`rootChildren`
index) whose `FieldSpec.kind == .sequence(name: "equation")` -
`EquationNumbering.sequenceName`/`.numberingField()` in
`StarMathEditor.swift`. Chosen over an attribute-on-the-equation-block
approach because `.field` is already a full first-class sibling block
type in this codebase (same shape as `.footnote`/`.endnote`), so the
convention needs ZERO new storage or `FieldController.swift` changes -
`FieldController.refresh` numbers it exactly the way it already numbers
any other `.sequence(name:)` series, called from this file the same way
`FieldControllerTests.swift`'s own tests call it. Proof test:
`StarMathEditorTests.testMultipleNumberedEquationsResolveInDocumentOrderViaFieldController`
(3 equations, 3 sibling fields, resolves 1/2/3 in document order) +
`testEquationNumberingSeriesIsIndependentOfOtherSequenceSeries` (doesn't
share a counter with an unrelated `.sequence(name: "Figure")`).
INSERTING the equation+field pair into a live document (a document-
structure mutation, `Mutation.insertBlocksAfter`) is explicitly out of
`StarMathEditor.swift`'s scope - that surface edits ONE existing
equation's LaTeX, it does not insert blocks into the tree. A future
wave's "insert equation" command in the main document editor is the
natural owner of that pairing logic.

## Design decision: "unedited round-trip" mechanism for item 5 (import preservation)

`EquationImportMapping.equationBlock(fromStarMath:)`/`(fromOMML:)`
write THREE attribute keys: `attributes["latex"]` (canonical, the
converted LaTeX), `attributes["originalStarMath"]` /
`attributes["originalOMML"]` (the source verbatim, untouched by any
later edit), and `attributes["latexImportBaseline"]` (the LaTeX this
file itself produced AT IMPORT TIME - the dirty-check baseline).
`isUnedited(_:)` compares CURRENT `latex` against that baseline: equal
means a future exporter should write back the preserved original
byte-for-byte; different means the user edited the LaTeX through
`StarMathEditor` since import, so the exporter should fall back to a
fresh LaTeX-only re-serialization instead. This mirrors
`FieldSpec.dirty`'s own shape (a stored flag/baseline the CALLER reads,
not machinery this file keeps magically in sync) rather than inventing
a new pattern. `StarMathEquationMutation.committing` (the pure commit-
diff function `StarMathEditorStore.commit()` calls) deliberately leaves
all three original/baseline attributes untouched when it rewrites
`latex` - only a FUTURE export pass's own read of `isUnedited(_:)` is
what turns "the baseline no longer matches" into an actual behavior
change; nothing here needs to delete or rewrite the preserved original.

## Scope note (honesty, testing-doctrine.md rule 10): StarMath/OMML fixtures are hand-constructed, not captured from a real document

Neither this agent nor the sandbox has an actual `.fodt`/`.docx`
corpus with real StarMath-annotated or OMML equations to extract
fixtures from. The StarMath fixtures use syntax straight from the
LibreOffice Math "Command Reference" (Math Guide appendix A,
https://books.libreoffice.org/en/MG252/MG25206-CommandReference.html)
and its own `nroot`/`sum from/to` worked examples (fetched and quoted
in `EquationImportMapping.swift`'s header). The OMML fixtures are
constructed by hand from the ECMA-376/OOXML math schema (datypic.com's
schema reference pages for `m:oMath`, `m:rad`, `m:nary`, fetched and
cited in the same header) - realistic element/attribute shapes, not
captured from a real `.docx`. Both converters cover a representative
common subset, not the full grammar (see the file header's own
enumerated scope list: e.g. multi-token UNBRACED `sum from/to` limits
are not disambiguated - fixtures use explicit braces, which is itself
valid StarMath and is what LibreOffice's own save format always emits).
A future wave with real corpus access should re-verify against actual
extracted StarMath/OMML strings, per doctrine rule 10's "re-verification
happens by re-running them, not by trusting the comment" - this is a
constructed-fixture unit-test file, not one of doctrine's quarantined
empirical-probe files (it shells out to nothing), so it isn't gated,
but its fixture PROVENANCE is honestly a construction, not a capture.

## Residual risk: could not run `swift build`/`swift test` this wave (per the wave's explicit constraint)

Every fixture/expectation in this track's four new test files was
hand-traced against the actual implementation (token-by-token for the
StarMath parser fixtures, element-by-element for the OMML fixtures) to
catch the `over`-precedence bug above before it shipped as a false-
green test. That is NOT a substitute for the compiler and a real test
run. Specific residual risks the centralized build/test pass should
watch for:
- `StarMathEditorTests.testEverySymbolPaletteSnippetRendersWithoutProducingAnErrorIndicator`
  asserts every palette entry (`\sqrt[n]{}`, the `pmatrix` snippet,
  `\lim_{x \to 0}`, etc.) renders without SwiftMath's parser erroring.
  SwiftMath's own README lists matrices/roots/limits as supported
  features, but this was not verified by actually running SwiftMath -
  if any one snippet turns out unsupported by this specific SwiftMath
  version, per testing-doctrine's suspected-bug protocol this becomes
  either a catalog fix (swap the snippet) or an `XCTExpectFailure`
  finding, never a weakened assertion.
- `BlockRendererEquationTests`'s determinism test
  (`testRenderLaTeXIsDeterministicAcrossTwoIndependentPasses`) compares
  `NSImage.tiffRepresentation` byte-for-byte across two calls - this
  should be deterministic (same process, same font, same drawing code,
  no randomness in the render path), but was not empirically confirmed.
- The exact `NSError` `.localizedDescription` text SwiftMath produces
  for each malformed-LaTeX fixture was not verified (the tests only
  assert the message is NON-empty via the `[Equation error: ...]`
  wrapper's presence, never match its exact wording, so this should be
  robust regardless).

## wiringNotes confirmation: DocStore.setBody is the existing generic block-attribute-mutation path (read-only, not modified)

Confirmed by reading `DocStore.swift` (not modified): `setBody(_
body: DocumentAST, for docID: UUID) async throws -> Doc` already exists
and already appends exactly one `DocReceiptType.updateBody` receipt per
call. `StarMathEditorStore.commit()` uses it directly - no new
`DocStore` method, no new `Mutation` case, no new receipt type needed
for this item. One observation worth flagging: `setBody` itself has NO
dirty-check guard - every call persists and receipts unconditionally,
even if the passed-in body is byte-identical to what's already stored.
This is pre-existing behavior in a file outside this track's list, not
something this track fixes, but it means `StarMathEditorStore`'s OWN
`isDirty`/`StarMathEquationMutation.committing` no-op check (before
ever calling `setBody`) is load-bearing, not redundant - the store must
never call `setBody` speculatively "just in case," since `setBody` will
not protect it. If a future wave wants `setBody` itself to no-op on an
unchanged body (matching every other `DocStore` mutation method's own
"no-op = zero receipts" contract), that is a `DocStore.swift` change
outside this track's scope.

## Courtesy item note: BlockRenderer.swift's `.toc` case is track C1's, not touched here

Per this wave's explicit instruction, only `renderEquation` and its own
call site were touched in `BlockRenderer.swift`; the `.toc` case
(`renderTocPlaceholder`) was left exactly as the wave opener wrote it.
`git status` shows a NEW, untracked `Editor/TocController.swift` and
`Tests/.../TocControllerTests.swift` already present from track C1, so
that item appears to already be in progress by its owning track - no
spare-capacity pickup needed from this track.
