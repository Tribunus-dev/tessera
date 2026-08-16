# P2-C findings - Track C1 (2.5 ToC + 2.11 Master documents)

Track ownership: new `Editor/TocController.swift`, new
`Productivity/Materials/Docs/MasterDocSpec.swift`, new
`TocControllerTests.swift` / `MasterDocSpecTests.swift`. One line edit
outside that list: `StyleRegistry.swift`'s `chain(from:in:)` widened
from `private` to internal (see its own entry below).

One row per blocker, scope note, or design decision worth flagging -
not necessarily bugs.

---

## Cross-track note: Doc.swift/DocStore.swift/BlockRenderer.swift are shared with other in-flight tracks this wave

While working, `git status` showed `FieldController.swift`,
`Package.swift`, and the whole `Materials/Draw/` cluster already
modified/untracked by other parallel agents (2.4 MailMergeCoordinator
adding `FieldKind.mergeField`; a Draw track adding `ShapeMorphEngine`/
`DrawTable`/etc). None of that overlaps this track's two files. Noting
it here only so the centralized pass knows this findings file's
"absent-spec Doc decode" proxy test (below) was written against
`Doc.swift` UNCHANGED by this track, not stale relative to some other
track's edits to it - as far as this agent could see, no other track
touched `Doc.swift` either, so the field addition wiringNotes calls for
is still fully open.

## Design decision: `StyleRegistry.chain(from:in:)` widened from `private` to internal

Item 1's own instruction ("find StyleRegistry.swift's existing
style-chain-resolution method and reuse it, don't reimplement style
inheritance") names a method that was `private`, hence uncallable from
a different file. Rather than duplicate the `basedOn` walk + cycle
guard in `TocController.swift` (exactly the reimplementation the
instruction says not to do), widened `chain(from:in:)`'s access level
by one word (`private static func` -> `static func`) with no other
change. `StyleRegistry.swift` is not in this track's file list, but is
also not one of the two files this wave's brief calls out as withheld
for collision risk (`DocStore.swift`/`BlockRenderer.swift`), and no
other track's diff touched it as of this write. If the architect wants
this reverted, `TocController.headingFamilyLevel` is the only caller -
reimplementing the walk locally there is a small, isolated change.

## Design decision: "Heading N" name-matching convention for heading-family styles

No `StyleDefinition` field carries a heading level (`StyleProperties`
has no `outlineLevel`/`level` field at all - confirmed by reading the
full type). The design contract's own SOTA evidence line for 2.5 cites
Word's `\t "Style,Level"` switch, which maps a style to a level BY
NAME - and this codebase already has a "Heading N" naming convention in
the wild (`StyleRegistryTests.swift` line ~222, `DocStoreTests.swift`
line ~186 both construct `StyleDefinition(name: "Heading 1", ...)`).
`TocController.headingLevel(fromStyleName:)` parses this convention
(case-insensitive `"heading "` prefix + integer suffix). This is a
NAMING convention, not a stored field - if the architect wants a real
`StyleDefinition.headingLevel: Int?` field instead, that's a
`StyleRegistry.swift` change outside this track's file list this wave.

## Design decision: `extraStyles` (\t) bypasses the `[fromLevel, toLevel]` range filter; `.heading`/style-chain/outline-level sources do not

The design contract names `extraStyles` as a field but does not spell
out whether its entries are bounded by `fromLevel`/`toLevel`. Word's own
documented `\t` switch semantics are additive (entries assigned via
`\t` appear regardless of `\o`'s range - that is the switch's whole
point: pulling in a caption/non-heading style at a chosen level). This
track's `TocController.candidateLevel` implements it that way -
`extraStyles` checked FIRST and returned immediately, before the range
check applies to every other source. Test:
`testExtraStylesOverrideBypassesFromToLevelRange`. If the architect
wants `extraStyles` bounded too, it's a two-line change (move the
range check to wrap that branch as well).

## Design decision: a renamed heading's cached ToC label counts as a real regenerate change

`TocRegenerationResult.changed` is defined structurally on `TocEntry`
(`targetBlockID`/`level`/`pageText`/`pageDirty`) per the design
contract's own field list - but a ToC entry's DISPLAY TEXT (a snapshot
of the target heading's own text) lives in the entry block's `content`,
not in `TocEntry` itself (matching `FieldSpec`/`Block.field`'s "cached
resolved text lives in `content`" split). A first implementation that
compared only `[TocEntry]` missed this: renaming a heading with no
other change would leave `changed == false` and silently keep the STALE
label forever, which is a `derived-never-stored` violation the moment
only the label needed re-deriving. Fixed by also comparing each
existing entry's cached `content` text against the freshly-collected
heading text (`newTexts != priorTexts` alongside `newEntries !=
priorEntries`). Test:
`testRenamingAHeadingUpdatesTheEntrysCachedLabelOnNextRegenerate`.
Recording this because it was a real bug caught during self-review, not
because the contract left it ambiguous - the contract's own idempotence
line ("second call with no document change: entries unchanged") implies
the converse (a real document change, including a rename, must NOT be a
no-op), which the first draft violated.

## Design decision: `partBreak` materialized as a tagged `.divider`, not a `.section`

`.section` (`DocumentMeta.sections`/`SectionStore`) is this codebase's
real page/section-break primitive, but wiring a full `DocumentSection`
registry entry per part boundary is a heavier mechanism than an
"effort S, data-only" assembly item calls for, and the design
contract's own item-6 line names concatenation-with-breaks without
specifying the break's block representation. Used the existing
`.divider` primitive (contributes no `plainText`, already renders as
`<hr>` everywhere) tagged `attributes["partBreak"] = spec.partBreak.rawValue`
so the break KIND survives even though `.divider` itself carries no
page/section semantics of its own. A future pass can upgrade this to a
real `.section` without changing `MasterDocController`'s public
surface (`assemble`'s signature/return shape is unaffected either way).

## Design decision: style-registry merge does not rewrite a KEPT part style's `basedOn`/`next` across a dropped sibling

`mergeStyleRegistries` remaps every BLOCK's `styleRef` that pointed at
a dropped (name-colliding) part style, to the surviving style's id -
tested (`testAssembleMergesStyleRegistriesMasterWinsOnNameCollisionAndRemapsPartStyleRefs`).
It does NOT also rewrite a DIFFERENT, kept part style's own `basedOn`
(or `next`) when that ancestor happened to be the one dropped in the
same merge - e.g. part style A ("Body Text", unique name, kept) with
`basedOn` pointing at part style B ("Heading 1", same name as master's
own "Heading 1", dropped) would leave A's `basedOn` dangling at B's now
-orphaned id rather than repointing it at master's surviving "Heading
1". `StyleRegistry.resolve`'s own `chain(from:in:)` is fail-soft on a
dangling `basedOn` (documented: treated as "no further ancestors", not
an error), so this degrades A's OWN inheritance silently rather than
crashing - a real but non-catastrophic gap. No test in this wave's
required list (item 7) exercises this combination. Flagging for a
future pass rather than expanding scope here.

## Design decision: `continuousNumbering` scoped to `.field(.sequence(name:))` only, not footnote/endnote numbering

The design contract's item 6 says "re-derive note/sequence numbering
... call it, don't reimplement," naming both together. They are not
symmetric under this architecture, though: `DocumentAST.deriveNoteNumbering()`
is a PURE function with no persisted state and no "per part" concept -
once assembly concatenates every part into ONE merged `DocumentAST`
(which happens unconditionally, regardless of `continuousNumbering`), a
consumer calling `deriveNoteNumbering()` on the result always gets
continuous 1..n footnote/endnote numbers spanning every part. There is
no assembly-time action that could make note numbering "restart per
part" within a single merged AST short of NOT merging into one AST
(which would violate the "one merged Doc, no live transclusion"
directive item 6 itself gives). `.sequence` fields are different: they
carry STORED/cached resolved text, so `continuousNumbering` has a real,
testable effect there (re-run `FieldController.refresh` over the merged
AST vs. leave each part's independently-cached content alone). Tested:
`testContinuousNumberingRederivesSequenceAcrossPartBoundaries` (also
exercises the `continuousNumbering == false` branch inline, though only
the `true` case is in item 7's required list). Recording this since the
contract's wording could be read as promising note-numbering also
becomes an `if/else` on the flag, which it structurally cannot under a
single-merged-AST design without contradicting the item's own
recommendation.

## Scope note: item 7's "absent-spec Doc decodes unchanged" test is a proxy, not a real `Doc` test

`Doc.swift` is explicitly not in this track's file list this wave (item
5's own text: "whoever wires it into Doc.swift as a new field is the
centralized pass"). `MasterDocSpecTests.testMasterDocSpecDecodesAsAbsentOptionalFieldForBackwardCompat`
therefore exercises a LOCAL `DocLikeContainer` struct (`{title: String,
masterDocSpec: MasterDocSpec?}`) rather than the real `Doc` type,
proving the exact decode contract (`decodeIfPresent`-shaped, absent key
-> `nil`, no custom Codable plumbing needed since `MasterDocSpec` has no
UUID-keyed dictionary requiring the `[String:V]` bridge
`DocumentMeta`'s registries need). Once the centralized pass adds
`Doc.masterDocSpec: MasterDocSpec?`, this proxy test's assertion
transfers directly - `Doc`'s own `Codable` synthesis needs no changes
beyond declaring the field, by the same reasoning. Flagging so this
isn't silently over-claimed as "tests the real Doc type."

## Design note (not implemented - no I/O files in this track's list): ToC export/import wire shape

Recorded per item 2/3's instruction ("record the exact serialization
shape needed... a DESIGN NOTE for a future wave's I/O work, not
something you implement"):

- **Export**: a real ODF `text:table-of-content` +
  `text:table-of-content-source` pair (carrying `TocSpec.fromLevel`/
  `.toLevel` as `text:outline-level`, `.extraStyles` as
  `text:index-source-style` child elements keyed by style NAME - the
  fods writer will need to resolve `TocSpec.extraStyles`'s UUID keys
  back to style names via `DocumentMeta.styles` at write time -
  `.hyperlink` as the source's hyperlink flag) OR a Word
  `{ TOC \o "from-to" \h \z \u \t "Style,Level" }` field, so LO/Word
  recompute the TOC themselves on open (plan 4a stance). The entry
  paragraphs themselves (`.toc`'s `children`) should serialize as
  ordinary `text:p`/`text:index-body` content so a reader with fields
  disabled still sees SOMETHING, matching how `DocumentExporter`
  already treats the HTML `<nav class="toc">` case (real content, not
  just a field code).
- **Import**: populate a fresh `.toc` block's `children` directly from
  LO's own RESOLVED TOC paragraph text on read (bypassing
  `TocController.regenerate` entirely for that first population, since
  the source document's own pagination is real and `regenerate` would
  otherwise blank every `pageText` back to `""`/`pageDirty: true`) and
  parse the field's own `\o`/`\h`/`\u`/`\t` switches (or the ODF
  source's equivalent attributes) back into a `TocSpec` so a SUBSEQUENT
  in-app `regenerate` call keeps the same range/behavior.
