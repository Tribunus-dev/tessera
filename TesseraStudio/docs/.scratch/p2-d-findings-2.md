# P2-D track D2 findings - 2.15 Forms / ContentControl

Track: D2 (2.15). Files owned this wave: `Productivity/ContentControl.swift`,
`Productivity/Materials/Docs/FormController.swift`, `Tools/DocTools.swift`,
`Productivity/Block.swift` (contentControl bridge only), plus new tests for
all four. `DocStore.swift` and `TesseraToolRegistry.swift` were withheld -
see the "wiringNotes" section of this track's structured result for the
exact integration points a future wave/pass needs.

None of the design contract's own "OPEN QUESTION" lines apply to this
track directly (2.15's only open question - protection semantics - was
already ratified studio-expansion-plan.md section 8 row 16: "recommended
yes" adopted). Everything below is a judgment call this track made
because the contract's text did not spell out the exact mechanism, not a
re-litigation of anything already settled.

## 1. `ContentControl.value: String?` - a field not literally named in
   the design contract's own field list

sota-enterprise-report.md's 2.15 design position gives the field list as
"kind, tag, title, placeholder, listItems, locks, binding" - no `value`.
But the SAME design position's FormController line requires one:
"checkBox/dropDownList writes a value into the ContentControl's own
state" - state has to live somewhere, and `ContentControl` is the only
persistent home for it (the alternative - a parallel `[UUID: String]`
map keyed by block id living in `DocumentMeta` - would duplicate the
`sections`/`notes`/`styles` registry pattern for no benefit, since a
content control's value has no reason to be looked up independently of
its own control).

Decision: added `value: String?` to `ContentControl`, read/written only
for `.comboBox`/`.dropDownList`/`.datePicker`/`.checkBox`/`.picture`
(the state kinds); `.plainText`/`.richText` never touch it (their value
lives in the host block's own `content`, per the SAME design line read
literally). See `ContentControl.swift`'s own header for the full
rationale written into the type itself.

Ratification ask: none really needed (this is filling a gap the
contract's own later sentence implies, not overriding anything), but
flagging in case the architect wants a differently-shaped state store
(e.g. richer per-kind typed state) before this ships more broadly.

## 2. `Block.contentControlEligibleTypes` - the exact 6-type host list

The design contract's own text: content controls attach to "existing
block cases" PLURAL - a paragraph, a table cell, a list item, etc. -
and explicitly deviates from every other Block attribute bridge (which
all gate to exactly one `BlockType`). The exact eligible set was left to
this track's judgment.

Decision: `{.paragraph, .heading, .listItem, .tableCell, .quote,
.callout}` - every block type whose own `content: [InlineRun]` is
ordinary prose a `w:sdt` could legitimately wrap, matching DOCX's real
host set. Excluded, with reasons:
- Structural/container-only types (`.list`, `.table`, `.toggle`,
  `.section`, `.frame`, `.shapeGroup`) - a control would have to live on
  one of their CHILDREN, never the container.
- Types that already own a single-purpose `attributes["<key>"]` payload
  of their own (`.shape`, `.chart`, `.media`, `.field`, `.toc`,
  `.equation`) - a real `w:sdt` never wraps a graphic frame/OLE
  object/field/TOC/equation this way either.
- Non-editable/derived/out-of-flow kinds (`.divider`, `.image`,
  `.codeBlock`, `.comment`, `.trackInsertion`, `.trackDeletion`,
  `.footnote`, `.endnote`).

Full reasoning is written into `Block.swift`'s own `contentControl`/
`contentControlEligibleTypes` doc comments (the load-bearing copy);
this entry is the pointer for architect review. `BlockTests.swift`
already pins `BlockType.allCases` at exactly 25 entries (unrelated to
this track, pre-existing); `ContentControlTests.swift` independently
pins this 6-type eligible set (doctrine rule 7) so a case added to
`BlockType` without updating the eligible-type set is caught the moment
it silently falls into the "ineligible by default" bucket rather than a
reviewed decision either way.

Ratification ask: the exact 6-type list is the one part of this track
most likely to want architect input (e.g. should `.quote`/`.callout`
really be eligible? both are defensible either way). Flagging for
review, not blocking - `formFields`/`fill`/the tools all compose cleanly
on top of whatever the final set is, since nothing else hardcodes it
independently.

## 3. `FormController.fill` per-kind validation rules

Not named by the design contract's own numbered items (which only give
`fill(_:in:value:) -> Block`'s signature and the content-vs-state
split). Decisions, each documented in `FormController.swift`'s own file
header:
- `.dropDownList`: exact case-sensitive membership in `listItems`;
  anything else is a no-op. `.comboBox`: free entry always accepted
  (the real OOXML distinction between the two kinds).
- `.checkBox`: exactly the literal strings `"true"`/`"false"`
  (case-sensitive); no tri-state.
- `.datePicker`/`.picture`: any string accepted verbatim - no date
  parsing, no path/URL validation. Deliberately minimal; the design
  contract's own field list carries no format constraint for either.
- `ContentControl.locks.contentLocked == true` gates ALL seven kinds,
  not just the text ones - a locked control cannot have its content OR
  its state value changed. This is the PER-CONTROL `w:sdtPr/w:lock`
  flag, a real DOCX concept `FormController` has enough context to
  honor directly - NOT the document-level "protected fill-in-forms-only"
  flag (see item 4 below), which is a `Doc`-wide concern this file never
  sees.

Ratification ask: none blocking - these are conservative, reversible
choices (a stricter validation can always be loosened later without a
migration, since it only affects which `fill` calls succeed, not what
gets stored on success).

## 4. Data-binding XPath subset + "which custom-XML part wins"

Per the design contract's own instruction ("implement a MINIMAL XPath
subset ... document exactly what subset you support and why"), the
supported grammar is documented in full in `FormBindingResolver`'s own
doc comment (`FormController.swift`): absolute paths only, bare
QName-shaped element-name steps, at most one `[@attr='value']`
predicate per step (attribute-equality only, no functions/position()/
multiple predicates), and an optional final `@attr` step to select an
attribute instead of element text. No `//`, no wildcards, no axes.

One thing NOT named by the design contract at all: `ContentControl`
carries no `storeItemId`/`w:storeItemID` field, so when a `Doc`'s
`PreservedParts` happens to carry MORE THAN ONE `customXml/*.xml` part
that could each independently resolve the same control's `binding`
XPath, `FormBindingResolver.resolve(_:in:)` tries every `customXml/*`
part and returns the first that resolves successfully - "first" being
Swift `Dictionary` iteration order, which is UNSPECIFIED. A real DOCX
resolves this unambiguously via `w:storeItemID` -> `customXml/
itemPropsN.xml` -> the specific part. This is a real, documented scope
gap (not a silent one - `FormController.swift`'s own header calls it out
under "Data binding / XPath resolution"), and it is the design
contract's OWN P3 punt trigger for this item ("interactive fill UI and
binding resolution can slip").

Ratification ask: if a real-world corpus document turns up with
multiple custom-XML parts bound to different controls via distinct
`storeItemID`s, this WILL need a `storeItemId` field added to
`ContentControl` plus `itemPropsN.xml` parsing to resolve it correctly -
flagging now so it is not rediscovered cold in a later wave. Additive
only (a new optional field), no migration needed if/when this happens.

## 5. `DocToolContext` - closure-seam design (not really a judgment
   call, but the reason `DocTools.swift` has no `DocStore` import)

`DocStore.swift` is withheld from this track this wave and has no
`fillForm`/loader method yet. `DocToolContext` follows the EXACT shape
`SheetToolContext`/`MailMergeToolContext` already establish for this
situation: two installable closures (`DocLoader`, `FormFiller`) that
whoever wires the real `DocStore` method installs once it exists. See
the structured result's `wiringNotes` for the exact method shape this
seam is meant to wrap. This is not a design deviation - it is the
codebase's own established pattern, applied here because the alternative
(importing a `DocStore` type that does not yet have the method this
file needs) is not available this wave.

## 6. Protection semantics (item 4) - `TesseraSafetyCheck` case name
   correction

The design contract's own prose says "every OTHER `doc_*` write ...
returns `.denied`". The ACTUAL `TesseraSafetyCheck` enum
(`Agent/TesseraSafetyDecision.swift`) has no `.denied` case - its three
cases are `.autoApprove` / `.askUser` / `.reject`. (`ApprovalLevel` -  a
DIFFERENT enum - does have a `.denied` case, but that gates a TOOL
being disabled outright, not a single call being denied by document
state.) The design contract's prose is using "denied" as a plain English
word, not literally naming the case; the correct target for a future
"protected fill-in-forms-only" check is `TesseraSafetyCheck.reject`.
Recorded in the structured result's `wiringNotes` with the corrected
name so a future implementer does not go looking for a nonexistent
`.denied` case.

## Test provenance note

`FormControllerTests.swift`'s two custom-XML fixtures (`employeeFixture`,
`fieldListFixture`) are HAND-BUILT for this test file, shaped after the
VSTO "bind content controls to custom XML parts" walkthrough cited in
`ContentControl.swift`'s own header (the same source
sota-enterprise-report.md's 2.15 evidence section cites) - they are NOT
extracted from a real produced `.docx`'s `customXml/itemN.xml` part.
Stated here per this wave's "document their provenance honestly"
instruction.
