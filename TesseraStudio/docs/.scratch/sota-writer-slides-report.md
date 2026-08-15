# SOTA evidence: Writer + Slides design definitions (P1 1.1/1.2/1.5/1.6/1.9/1.14, rows 9/10/31/34)

Prepared 2026-08-14 by the refinement-pass research agent (Writer + Slides).
Evidence input to `../studio-expansion-design-refinement-2026-08-14.md`. Peer of
`lo-{writer,calc,impress}-report.md`.

## Local evidence

Base: `TesseraStudio/` on main.

**Sources/TesseraCore/Productivity/Block.swift** (512 lines)
- BlockType enum, 20 cases: lines 22-99. Relevant: `.comment` 67-71 (attrs
  anchorBlockID, anchorRangeStart/End, author, timestamp; children = replies),
  `.trackInsertion` 72-74, `.trackDeletion` 75-77 (author + timestamp attrs;
  changed text in `content`), `.section` 87-92 (sectionRef into
  DocumentMeta.sections), `.frame` 93-98, `.shape` 78-81, `.shapeGroup` 82-86.
- InlineRun.Annotation: 112-122 - bold/italic/underline/strikethrough/code/
  sub/superscript/link(URL)/color(hex:). Tagged-JSON Codable.
- Block struct: 146-169 - `attributes: [String: AnyCodable]`,
  `content: [InlineRun]`, `children: [UUID]`, `parentID`.
- Typed-attribute bridge pattern (the precedent every new payload copies):
  `Block.shape` 191-207 and `Block.frame` 217-234 - nested JSON object under
  one attribute key; the value type's own Codable is the wire truth.
- DocumentPageLayout: 239-290; `headerBlockID` 256, `footerBlockID` 258
  (out-of-flow blocks registered in meta - the precedent for footnote bodies).
- DocumentMeta: 295-309 (pageLayout + `sections: [UUID: DocumentSection]` -
  the precedent for a registry living in meta).
- DocumentAST: 355-461; canonical JSON `jsonData()` 472-476 (sortedKeys);
  `contentHash()` 488-494 (sha256; receipts/C2PA depend on byte-stable
  encoding - any new meta field must encode deterministically); `plainText()`
  500-511 (depth-first text join - the coordinate system find/replace shares).

**Sources/TesseraCore/Productivity/Comments.swift** (215 lines)
- CommentThread 8-44 (anchorBlockID + char range + author + createdAt +
  messages + isResolved); CommentMessage 49-61.
- CommentStore 67-157: `threads(from:)` 70-146 derives threads from `.comment`
  blocks (pure projection, no mutation seam); `pendingChangeCount` 154-156.
- TrackChange 162-215: read-only projection of track blocks (id = block UUID,
  type ins/del, author, createdAt, text, anchorBlockID); `from(document:)`
  185-214. No accept/reject, no grouping, no receipts - exactly the gap
  RevisionController fills.

**Sources/TesseraCore/Productivity/Materials/Slides/MasterPageStore.swift** (135)
- Struct-not-actor store, peer of SlideStore (header 5-17); receipt contract:
  every mutation appends a signed receipt with a SlideReceiptType (14-17).
  `defineMasterPage` 30-46, `undefineMasterPage` 52-64,
  `setMasterPage(forSlideAt:)` 69-93 (writes `SlideMeta.masterPageID`),
  `appendReceipt` 129-134. The template for every new store below.

**Sources/TesseraCore/Productivity/Materials/Slides/SlideLayoutSpec.swift** (103)
- SlideLayoutPlaceholder 10-18 (blockType + children; NO idx/name yet -
  placeholder identity is positional). SlideLayoutSpec 43-103; builtins 58-92;
  doc note 34-42: `SlideDeck.insertingSlide` switch intentionally unchanged
  until the P1 picker becomes the first consumer of `placeholders`.

**Sources/TesseraCore/Productivity/Materials/Slides/SlideReceiptType.swift**
- Receipt vocabulary 10-57, incl. `slide_layout_changed` 24,
  `slide_master_page_defined` 26, `slide_master_page_undefined` 28,
  `slide_master_page_assigned` 30. New receipt types follow this pattern.

**docs/word-class-document-processor-implementation-plan.md** (772) - Writer plan
- Phase 3 (lists + paragraph styles): 330-393. Heading cascade 334-336,
  NSTextList lists 338-349, style picker 351-353, shortcuts 355-372. Its
  `DocumentStyle` sketch 180-192 already has basedOn/nextStyle but uses AppKit
  types (NSColor/CGFloat) - a view-model, not a Codable AST type. Decision 2
  ("styles are first-class", persist to DocumentMetadata.styles[]) 754-757.
- Phase 7 (comments + track changes): 531-588. Comment sketch 541-551;
  `TrackedChange` sketch 564-573 is NSRange-based - predates and conflicts
  with the shipped block-based substrate; accept/reject-all 575-581; Decision
  3 (track default OFF) 759-761.
- Phase 8 (find/replace): 592-614 - NSFindPanel + NSRegularExpression, purely
  view-level over the text view. Priority list puts Phase 8 at P1 (735-737).

**docs/studio-expansion-plan.md**
- Row 9 style registry gap 199; row 10 list levels 200; row 31 cell comments
  221; row 34 find/replace ("no DocumentSearchIndex") 224. Bridge stance 333:
  "Layout-sensitive features: ToC, page-number fields, cross-references,
  index | LO computes them. We serialize the resolved text." P1 table rows
  1.1/1.2/1.5/1.6/1.9/1.14; flat-AnimationEffectList interim 6b.1; decision 5
  (full picker UI, LO 25+ AutoLayouts from sd/source/core/sdpage.cxx:1397);
  decision 7 (list becomes serialization of tree).

## SOTA findings per topic

### 1. Styles (OOXML / LO / modern editors)
- `w:style` carries type (paragraph|character|table|numbering), basedOn
  (inheritance parent), next (style for the following paragraph), link (pairs
  a paragraph style with a character style), uiPriority (gallery sort),
  qFormat (quick-style gallery membership).
  https://www.datypic.com/sc/ooxml/e-w_style-1.html
- Inheritance: properties merge down the basedOn chain; the leaf style
  overrides ancestors property-by-property.
  https://learn.microsoft.com/en-us/archive/blogs/openspecification/openxml-styles-101-creating-custom-styles-and-understanding-style-inheritance
- Effective-format resolution order (ECMA-376 17.7.2): docDefaults -> table
  style -> numbering style -> paragraph style -> character style -> direct
  formatting; each later layer overrides the earlier.
- Style housekeeping at scale (latentStyles, lsdException, gallery management)
  is deep and Word-specific.
  https://www.brandwares.com/bestpractices/2015/12/xml-hacking-managing-styles/
- LO families: paragraph/character/frame/page/list (page + frame families have
  no OOXML analogue; row 9 already scopes Tessera to para/char/page/list/table).
- Modern simplification: Google Docs ships a fixed catalog (Normal text,
  Title, Subtitle, Heading 1-6) with "Update style to match" and
  save-as-default - no user-defined named styles at all.
  https://bazroberts.com/2016/04/19/google-docs-paragraph-styles-headings/
  Notion has no named styles - block types + inline annotations only. The
  winning simplification: small named set, customizable, inheritance invisible
  to users.

### 2. Track changes
- OOXML wraps run content: `w:ins` / `w:del` (CT_RunTrackChange) with w:id,
  w:author, w:date; deleted text becomes `w:delText` inside `w:del`.
  https://www.datypic.com/sc/ooxml/e-w_ins-5.html
- `w:rPrChange` stores the PREVIOUS run properties for a tracked formatting
  change. http://www.datypic.com/sc/ooxml/e-w_rPrChange-2.html
- Moves are paired regions: `w:moveFrom` (behaves like del) + `w:moveTo`
  (behaves like ins), correlated by move-range names/ids; rejecting one side
  must reject the pair.
  https://c-rex.net/samples/ooxml/e1/part4/OOXML_P4_DOCX_moveFrom_topic_ID0EPJCW.html
- Accept semantics: accept ins = keep content, strip marker; accept del =
  remove content. Reject is the mirror. Nested case (B deletes text A
  inserted -> del nested inside ins): accepting the del removes the text
  regardless of the ins; rejecting the del re-exposes the still-pending ins -
  resolve innermost-first is always safe. Per-author batch accept/reject is
  the standard operation shape. https://github.com/AnsonLai/docx-redline-js
- Google Docs suggesting mode: content carries suggestedInsertionIds /
  suggestedDeletionIds (a range can belong to several suggestions); reads
  offer SUGGESTIONS_INLINE / PREVIEW_INLINE / PREVIEW_WITHOUT_SUGGESTIONS;
  writes can run with WriteControl SUGGEST mode. Key insight: suggestion ID is
  first-class and separate from content identity.
  https://developers.google.com/workspace/docs/api/how-tos/suggestions

### 3. Fields
- Two encodings: `w:fldSimple` (instruction as one attribute wrapping the
  cached result run) vs the complex `w:fldChar` triple begin/separate/end with
  `w:instrText`; `dirty` flags force recompute.
  https://learn.microsoft.com/zh-cn/previous-versions/office/cc841420(v=office.14)
- Switches: `\* MERGEFORMAT` preserves the previous result's direct formatting
  on update; `\@` date-time and `\#` numeric picture switches.
  https://bettersolutions.com/word/fields/formatting.htm
- Update triggers in Word: F9 manual; print-preview/repagination updates
  PAGE-class fields; header/footer fields update on layout, not with body F9.
  PAGE/NUMPAGES effectively belong to the paginator, not the field engine.
  https://support.microsoft.com/en-us/office/update-fields-7339a049-cb0d-4d5a-8679-97c20c643d4e
- Classification that matters: layout-resolved (PAGE, NUMPAGES) vs
  index-resolved (REF, SEQ - need a bookmark/sequence index, order-dependent
  but not layout-dependent) vs context-resolved (DATE, TIME, AUTHOR, TITLE,
  DOCPROPERTY - cheap recompute any time).

### 4. Footnote/endnote
- OOXML: footnotes live in a separate part (footnotes.xml, own story), body
  carries only a `w:footnoteReference w:id` run; the part also holds special
  separator/continuationSeparator footnotes; endnotes identical in
  endnotes.xml. https://ooxml.info/docs/11/11.3/11.3.7/
- Numbering is derived from reference order, never stored.
- TextKit 2: viewport-based fragment layout is good at per-fragment geometry,
  but exclusion paths are documented crash-prone with the sample viewport code
  - bottom-of-page reservation via exclusion paths is not v1 material.
  https://developer.apple.com/forums/thread/736772
  https://shadowfacts.net/2022/textkit-2/
- Practical v1 used by pageless editors (Google Docs pageless, Craft): render
  notes as an endnote list + inline popover on the reference; true
  bottom-of-page placement arrives only with a paginator.

### 5. Theme
- `a:theme/a:themeElements` = clrScheme (12 slots: dk1, lt1, dk2, lt2,
  accent1-6, hlink, folHlink) + fontScheme (majorFont/minorFont) + fmtScheme
  (fill/line/effect/bgFill style lists).
  https://datypic.com/sc/ooxml/e-a_theme.html
- Slides map slots through `p:clrMap`; docs consume theme via styles (rPr
  themeColor + tint/shade), not literal hex.
- LO state: document themes landed in 7.6 (2023) - a theme = name + 12-color
  set, Writer/Calc/Impress pickers, OOXML+ODF round-trip; fmtScheme largely
  not surfaced.
  https://help.libreoffice.org/latest/en-US/text/shared/01/themescolordialog.html
- Takeaway: 12-slot color model + major/minor fonts is the interoperable core;
  fmtScheme is skippable at P1.

### 6. Masters / layouts / placeholders
- Chain: slide -> slideLayout -> slideMaster. A layout placeholder inherits
  from the master placeholder of the same `type`; a slide placeholder inherits
  from the layout placeholder with the same `idx`. Position, size, fill, font
  all inherit.
  https://python-pptx.readthedocs.io/en/latest/dev/analysis/placeholders/layout-placeholders.html
- ISO 29500 deliberately does NOT specify the inheritance model; idx-matching
  is PowerPoint behavior documented in MS-OI29500.
  https://learn.microsoft.com/en-us/openspecs/office_standards/ms-oi29500/3ec954b2-37a6-41da-8973-04a592c91fb2
- PowerPoint re-layout behavior: content never deleted on layout switch -
  unmatched content stays as orphaned shapes.
- LO: fixed AutoLayout catalog (~25+, sd/source/core/sdpage.cxx:1397).

### 7. Transitions
- OOXML `p:transition` = choice of 20 effect children: blinds, checker,
  circle, comb, cover, cut, diamond, dissolve, fade, newsflash, plus, pull,
  push, random, randomBar, split, strips, wedge, wheel, wipe, zoom; attrs spd,
  advClick, advTm; modern additions (flash, ripple, glitter, honeycomb,
  vortex, ...) live in p14 extensions.
  https://www.datypic.com/sc/ooxml/e-p_transition-1.html
- LO Impress preset vocabulary (~34): 2D - Wipe, Wheel, Uncover, Bars,
  Checkers, Shape, Box, Wedge, Venetian, Fade, Cut, Cover, Dissolve, Comb,
  Push, Split, Diagonal; 3D/GL - Tiles, Cube, Circles, Helix, Fall, Turn
  Around, Iris, Turn Down, Rochade, 3D Venetian, Static, Fine Dissolve,
  Vortex, Ripple, Glitter, Honeycomb, Newsflash.
  https://books.libreoffice.org/en/IG70/IG7009-SlideShowsPhotoAlbums.html
- Feasibility split: opacity/offset/scale/mask tweens are cheap
  SwiftUI/CoreAnimation; per-pixel dissolve and all 3D/GL presets need
  shaders - exactly the promoted 2.19 item.

### 8. Animations (SMIL)
- `p:timing` is a SMIL-ish time-node tree: tnLst -> par (tmRoot) -> seq
  (mainSeq) -> one par PER CLICK GROUP -> inner pars holding behaviors; effect
  nodeTypes are clickEffect / withEffect / afterEffect; behaviors are anim,
  animEffect, animMotion, animClr, animScale/animRot, set, each with cBhvr.
  https://learn.microsoft.com/en-us/office/open-xml/presentation/working-with-animation
- The flat-list <-> tree mapping is therefore canonical: mainSeq = ordered
  click groups; a group = one onClick effect + its withPrevious/afterPrevious
  followers. A flat list with {order, trigger} is exactly a pre-order
  serialization of that two-level tree - what the P1 contract must pin.

### 9. Find/replace in structured editors
- prosemirror-search: SearchQuery {search, caseSensitive, regexp, wholeWord,
  replace, literal}; findNext/findPrev return {from,to,match} in document
  positions; batch replace applies back-to-front or maps positions through
  the transaction mapping. https://github.com/ProseMirror/prosemirror-search
- Core lesson: the document has its own position arithmetic; plain string
  search cannot run over serialized text without an explicit text<->position
  map; searches run per textblock, cross-block regex is a deliberate opt-in.
  https://discuss.prosemirror.net/t/how-to-implement-a-search-and-replace-plugin/5385

### 10. Comments
- Excel threaded comments: separate threadedComments part + persons.xml
  identity part; the legacy comments part is kept with a plain-text
  placeholder for old clients (dual-write compat model).
  https://learn.microsoft.com/en-us/openspecs/office_standards/ms-xlsx/66e1875d-c60a-48eb-bf88-41066d45fea8
- PowerPoint modern comments: new `p188:cm` list part with GUID id + authorId
  + created, whole-slide or shape anchors, replies nested.
  https://support.microsoft.com/en-us/office/what-it-admins-need-to-know-about-modern-comments-in-powerpoint-485c8f8d-f3ee-4211-9fdd-3bc2d868c679
- Takeaway: one internal thread model with a polymorphic anchor;
  format-specific dual parts are an export concern only.

## Design recommendations

(Everything below evolves or peers existing types - nothing is a _v2.)

### 1. StyleRegistry (row 9)
- File: `Sources/TesseraCore/Productivity/StyleRegistry.swift`; registry
  stored in `DocumentMeta.styles`, same pattern as `DocumentMeta.sections`.
- Relationship: evolves `Block.attributes["style"]` (string label today) into
  a ref into the registry; supersedes the word-class plan's AppKit-typed
  DocumentStyle sketch (180-192) - Phase 3 must not ship a second style type.
- Sketch:
```swift
public struct StyleDefinition: Codable, Sendable, Hashable, Identifiable {
    public enum Family: String, Codable { case paragraph, character, list, table, page }
    public let id: UUID
    public var name: String
    public var family: Family
    public var basedOn: UUID?          // OOXML basedOn
    public var next: UUID?             // OOXML next (paragraph family only)
    public var props: StyleProperties  // fontName/size/weight, colorRef, spacing, alignment, listLevelDefs
}
// DocumentMeta gains: public var styles: [UUID: StyleDefinition]
// Block.attributes["styleRef"] = .string(uuid); legacy "style" string kept readable on import
```
- Resolution: one `StyleResolver.effectiveProps(block:registry:)` applying
  docDefaults -> paragraph chain -> character chain -> run annotations (a
  4-layer subset of OOXML's 6; no table/numbering layers at P1). basedOn
  chains merge leaf-wins, cycle-guarded.
- Receipts: `doc_style_defined/updated/deleted/applied` (payload: styleID,
  name, affected block count), MasterPageStore-shaped.
- Test contract: resolving a 3-deep basedOn chain equals OOXML leaf-override
  semantics on a fixture; deleting a style rebinds users to basedOn parent.
- Phase: P1. OWNERSHIP: expansion owns the registry model + receipts;
  word-class Phase 3 owns applying styles in the editor as a consumer.

### 2. RevisionController (1.14)
- File: `Sources/TesseraCore/Productivity/Editor/RevisionController.swift`.
- Relationship: evolves `.trackInsertion`/`.trackDeletion` + the read-only
  TrackChange projection by adding lifecycle; Comments.swift stays the
  projection home.
- Revision identity: the track block's UUID is the revision ID; add
  `attributes["revisionID"]` only to GROUP multi-block revisions (a move =
  ins block + del block sharing revisionID - the moveFrom/moveTo pairing
  without new block types).
- Semantics: accept ins = splice content into anchor position, remove block;
  reject ins = remove block; accept del = remove block; reject del = splice
  content back. Nested/grouped: resolve innermost-first; revisionID-grouped
  blocks resolve atomically or not at all.
- Receipts: `doc_revision_accepted` / `doc_revision_rejected` {revisionID,
  kind, author, textSha}; batch ops emit one receipt per revision plus a
  `doc_revisions_resolved` summary. Undo re-creates the track block with the
  SAME id and emits its own receipt (receipts are append-only).
- Test contract: on a fixture with B-deletes-inside-A-inserts, accept-all and
  per-revision resolution in any order produce the same final contentHash;
  accept-then-undo restores the prior contentHash.
- Phase: P1. Word-class Phase 7's NSRange TrackedChange sketch is superseded
  by the block substrate; Phase 7 keeps the Review-tab UX and default-OFF.

### 3. BlockType.field + FieldController (1.1)
- Payload (Block.shape bridge pattern): `attributes["field"]` holds a Codable
  FieldSpec; `content` holds the cached RESOLVED text as normal runs so
  plainText()/export/agent context see real text - this makes the native
  model compatible with the plan's "LO computes layout-sensitive fields, we
  serialize resolved text" stance: the serialized form IS the resolved text;
  the spec is the recompute recipe.
```swift
public struct FieldSpec: Codable, Sendable, Hashable {
    public enum Kind: Codable, Hashable {
        case page, numPages                                  // layout-resolved
        case ref(bookmark: String), sequence(name: String)   // index-resolved
        case date(format: String?), time(format: String?)    // context-resolved
        case author, title, docProperty(key: String)
    }
    public var kind: Kind
    public var dirty: Bool          // OOXML fldChar dirty analogue
}
```
- FieldController: catalog + `refresh(_:context:)`. Context fields refresh on
  edit-commit + document-open; index fields when the bookmark/sequence index
  changes; layout fields ONLY when a FieldResolutionContext
  (paginator-provided pageNumber(of:), pageCount) exists - absent a native
  paginator they stay dirty with last-known text, and LO-bridge export
  resolves them (division of labor unchanged). No MERGEFORMAT: run
  annotations survive because refresh rewrites text only.
- Receipts: `doc_field_inserted` {kind}, `doc_fields_refreshed` {count,
  kinds} - refresh is a real AST mutation and must be receipted or
  contentHash drifts silently.
- Test contract: refreshing date/time under an injected fixed clock is
  idempotent (second refresh = no receipt, no hash change); PAGE without
  context stays dirty and keeps cached text.
- Phase: P1 (page/numPages live rendering completes at the P2 paginator).

### 4. Footnote / endnote (1.2)
- Files: `.footnote` + `.endnote` BlockType cases;
  `Productivity/FootnoteStore.swift` (projection, CommentStore-shaped).
- Model (OOXML separate-story, adapted): the note body is a block whose
  children are ordinary content blocks, registered out-of-flow in
  `DocumentMeta.notes: [UUID]` exactly like headerBlockID/footerBlockID. The
  in-text reference = `InlineRun.Annotation.noteRef(UUID)` (one additive enum
  case; tagged-JSON encoding keeps old docs decoding). Numbering is DERIVED
  from depth-first reference order, never stored (OOXML rule).
- v1 layout WITHOUT pagination: endnotes section after the last block +
  popover at the reference; bottom-of-page placement is paginator work (P2) -
  do not attempt TextKit 2 exclusion-path reservation (crash evidence above).
  Endnote/footnote distinction is metadata from day one so P2 needs no schema
  change.
- Receipts: `doc_note_inserted` / `doc_note_deleted` {noteID, placement};
  deleting a note deletes its reference annotation in the same receipted
  mutation (no orphans).
- Test contract: insert/delete/reorder of references re-derives 1..n numbering
  with no stored numbers; docs with notes round-trip jsonData(); old fixture
  docs still decode.
- Phase: P1.

### 5. Theme + ThemeStore (1.5)
- Files: `Materials/Slides/Theme.swift` + `ThemeStore.swift` (path fixed by
  the plan; type is surface-neutral so Docs consume it too).
- Model: OOXML 12-slot vocabulary verbatim + major/minor fonts; skip
  fmtScheme (LO 7.6 shipped exactly this subset and it round-trips).
```swift
public enum ThemeSlot: String, Codable, CaseIterable {
    case dk1, lt1, dk2, lt2, accent1, accent2, accent3, accent4, accent5, accent6, hlink, folHlink
}
public struct Theme: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID; public var name: String
    public var colors: [ThemeSlot: String]        // hex
    public var majorFont: String; public var minorFont: String
}
public enum ColorRef: Codable, Hashable {
    case literal(hex: String)
    case theme(ThemeSlot, tint: Double? = nil)
}
```
- Who references slots: StyleDefinition.props.colorRef, master backgrounds,
  and Shape fills adopt ColorRef. InlineRun.Annotation.color(hex:) stays
  literal at P1. Theme swap recolors via styles/masters without touching
  block bodies.
- ThemeStore: MasterPageStore-shaped; defineTheme, assignTheme(to:) on decks
  and docs. Receipts: `theme_defined`, `theme_assigned` {themeID, name}.
- Test contract: assigning a different theme changes resolved colors while
  every block body's jsonData() is byte-identical.
- Phase: P1.

### 6. MasterPageLayoutPicker (1.9)
- Catalog: extend SlideLayoutSpec.builtins with the LO AutoLayout set (~25)
  as data, not enum cases - the "first consumer" SlideLayoutSpec 34-42 was
  waiting for; SlideDeck.insertingSlide finally reads placeholders.
- Add `idx: Int?` (and optional `name`) to SlideLayoutPlaceholder - the OOXML
  lesson: placeholder identity must be explicit (idx), not positional, or
  re-binding is unstable across layout edits. Additive Codable field.
- Data flow: picker selection -> ONE receipted mutation
  `SlideStore.applyLayout(spec:toSlideAt:)`: (1) match existing top-level
  blocks to new placeholders by idx when present, else by BlockType in order;
  (2) unmatched existing blocks are NEVER deleted - appended after
  placeholder blocks (PowerPoint orphan rule); (3) unfilled placeholders
  created empty. Master assignment stays the separate existing setMasterPage
  receipt.
- Receipts: extend SlideReceiptType with `slide_layout_applied`
  {layoutSpecID, rebound, orphaned}.
- Test contract: applying every catalog layout to every fixture slide
  preserves the full block-ID set (zero content loss); applying the same
  layout twice is idempotent (no second receipt).
- Phase: P1.

### 7. TransitionSpec + TransitionStore (1.6)
- Files: `Materials/Slides/TransitionSpec.swift`, `TransitionStore.swift`,
  catalog resource `TransitionCatalog.json`.
- Preset vocabulary: OOXML's 20 as canonical IDs + LO extras, ~34 total.
```swift
public struct TransitionSpec: Codable, Sendable, Hashable, Identifiable {
    public var id: String            // "fade", "push", "cube", ...
    public var name: String
    public var direction: String?    // l/r/u/d/in/out where applicable
    public var durationMS: Int
    public var engine: Engine        // .tween | .mask | .gpu
    public var fallbackID: String?   // REQUIRED when engine == .gpu
}
```
- Engine mapping: tween = fade, cut, cover, uncover(pull), push, wipe, split,
  zoom(box); mask = circle, diamond, plus, wedge, blinds(venetian), checker,
  comb, strips, randomBar, bars, shape, diagonal, wheel; gpu =
  dissolve(per-pixel), fineDissolve, cube, tiles, circles3d, helix, fall,
  turnAround, iris, turnDown, rochade, venetian3d, static, vortex, ripple,
  glitter, honeycomb, newsflash -> these ship in the catalog now but render
  their declared fallback until 2.19 lands; the spec is the contract 2.19
  fills in. (2.19's renderTier coreImage/metalShader distinction is an
  implementation detail INSIDE the gpu engine tier - one vocabulary.)
- TransitionStore: MasterPageStore-shaped; setTransition(_:forSlideAt:)
  writing SlideMeta.transition; receipt `slide_transition_assigned`
  {presetID, durationMS}.
- Test contract: catalog decodes; IDs unique; every gpu entry has a
  resolvable non-gpu fallbackID; every OOXML p:transition child name maps to
  exactly one catalog ID (import totality).
- Phase: P1 (catalog + tween/mask engines); gpu renderers P2 (2.19).

### 8. AnimationEffectList (P1 interim) -> SMILAnimationTree (P2)
- Schema (flat, per slide):
```swift
public struct AnimationEffect: Codable, Sendable, Hashable, Identifiable {
    public enum Trigger: String, Codable { case onClick, withPrevious, afterPrevious }
    public let id: UUID
    public var targetBlockID: UUID
    public var presetID: String
    public var trigger: Trigger
    public var durationMS: Int
    public var delayMS: Int
}
public struct AnimationEffectList: Codable, Sendable, Hashable { public var effects: [AnimationEffect] }
```
- Serialization contract (provable tree projection): the list is the
  pre-order flattening of mainSeq = [clickGroup], clickGroup = par(one
  onClick effect + following withPrevious/afterPrevious effects) - exactly
  PowerPoint's mainSeq/clickEffect/withEffect/afterEffect structure. Grouping
  is DERIVED from trigger order (index i starts a group iff trigger ==
  .onClick or i == 0), so no tree-only state exists at P1 and the P2 tree
  constructor `SMILAnimationTree(flat:)` is total; `tree.flattened()` is its
  left inverse.
- P1 contract test (required): commit fixture
  `Tests/.../Fixtures/animation-effect-list-p1.json` (multiple click groups,
  all three triggers, nonzero delays). Test 1 (P1): fixture decodes and
  canonical re-encode is byte-identical. Test 2 (written at P1, asserting the
  P2 name): `SMILAnimationTree(flat: decoded).flattened() == decoded` -
  checked in disabled/pending at P1, turned on at P2; the fixture file itself
  must never be edited at P2 (load-compat is the contract).
- Receipts: `slide_animation_added/removed/reordered` {effectID,
  targetBlockID, presetID}.
- Phase: list P1; tree P2 (2.1). The list file is NOT deleted at P2 - it
  becomes the serialization type.

### 9. DocumentSearchIndex + find/replace (row 34)
- File: `Productivity/DocumentSearchIndex.swift` (model layer; UI in editor).
- Shape (prosemirror-search lessons): index built over depth-first blocks,
  concatenating run text per block with "\n" joins - deliberately the SAME
  coordinate text as plainText() so agent-reported match positions and editor
  positions agree.
```swift
public struct DocumentSearchIndex: Sendable {
    public struct Match: Hashable { public let blockID: UUID; public let range: Range<Int>; public let runIndex: Int }
    public init(document: DocumentAST)
    public func find(_ query: SearchQuery) -> [Match]
}
```
- Matching runs per-block by default; explicit `crossBlock: Bool` searches
  the joined text. Replace-all applies back-to-front per block, emits ONE
  mutation + receipt `doc_find_replace` {pattern, replacementSha, matchCount}
  - one receipt per user action, not per match. Serves both the find UI and
  agent tools.
- Test contract: find offsets composed with plainText() reproduce the matched
  substrings exactly; replace-all of adjacent matches equals sequential
  single replaces.
- Phase: P1.

### 10. Comment anchors (row 31)
- File: extend `Productivity/Comments.swift` - reuse CommentThread/
  CommentMessage; do NOT fork per surface.
```swift
public enum CommentAnchor: Codable, Sendable, Hashable {
    case textRange(blockID: UUID, start: Int, end: Int)   // today's shape
    case block(UUID)                                      // whole block / shape
    case cell(sheetID: UUID, row: Int, col: Int)
    case slide(slideBlockID: UUID)
}
```
- CommentThread gains `anchor: CommentAnchor` with a decode fallback mapping
  legacy anchorBlockID+range fields into `.textRange` (old docs load
  unchanged). Sheet/Slide threads persist inside their own entity bodies
  (SheetMeta/SlideMeta comments arrays), not as `.comment` blocks; CommentStore
  grows `threads(fromSheet:)` / `threads(fromDeck:)` projections.
- Receipts: `sheet_comment_added` / `slide_comment_added` (+resolved/deleted)
  in each surface's receipt enum, payload {threadID, anchor}.
- Test contract: legacy comment fixture decodes to `.textRange`; cell comment
  survives row/col insertions via anchor remap in the same mutation.
- Phase: P1.

### OWNERSHIP verdicts (the four unowned rows)

| Row | Capability | Owner | Boundary |
|---|---|---|---|
| 9 | Style registry | Expansion plan (StyleRegistry model, receipts, resolver) | word-class Phase 3 consumes it for picker/shortcuts/rendering; its own DocumentStyle sketch is superseded - Phase 3 must not define a second style type |
| 10 | List levels + outline | word-class Phase 3 (behavior: Enter/Tab level logic, glyph rendering) | level/numbering DATA lives in `.list`/`.listItem` attributes + list-family StyleDefinitions in the expansion's registry; Phase 3's literal-bullet-character approach is dropped in favor of attributes |
| 31 | Cell/slide comments | Expansion plan (CommentAnchor + surface stores) | word-class Phase 7 keeps Doc comment UX on the shared Comments.swift types |
| 34 | Find/replace | Expansion plan (DocumentSearchIndex + agent tool + replace mutation/receipt) | word-class Phase 8 keeps the find/replace UI but is repointed to the index; its NSFindPanel/raw-NSRegularExpression approach is retired |

## What NOT to adopt

- Word's full styles.xml machinery: latentStyles/lsdException, w:link paired
  styles, uiPriority/qFormat gallery metadata, toggle-property XOR rules,
  table+numbering resolution layers. Keep basedOn + next + 5 families.
- fldChar begin/separate/end complex fields in the AST: one FieldSpec payload
  + cached result; the triple-run encoding exists only at the bridge
  boundary. Also skip MERGEFORMAT semantics.
- moveFrom/moveTo as new block types: model moves as revisionID-paired
  ins+del. New BlockType cases are forever; pairing metadata is not.
- Google-Docs-style per-property suggestion masks: formatting-change tracking
  (rPrChange analogue) is dropped at P1 entirely; only content revisions are
  tracked. Cheap to add later, expensive to carry now.
- NSFindPanel as the search engine: view-level text search cannot serve agent
  tools, cross-surface search, or receipts. Retired, per row 34 verdict.
- TextKit 2 exclusion-path bottom-of-page footnotes at P1: documented crashes
  with viewport layout and presumes a paginator Tessera does not have.
- fmtScheme (fills/lines/effects) in Theme: LO 7.6 proved the 12-color +
  2-font subset is the interoperable core.
- A non-OOXML color-slot vocabulary (design-token names, Material-style
  roles): 12 slots with OOXML names or theme round-trip dies at the bridge.
- Faking GPU transitions with 2D tweens silently: gpu-engine presets must
  declare fallbackID and render the fallback honestly until 2.19.
- SMIL containers at P1 (iterate, animMotion paths, audio/command nodes,
  event conditions): the flat list's trigger triple is the entire P1
  vocabulary.
- Excel's dual-part comment compat model as internal storage: one
  CommentThread model; dual-part is an export shim in the bridge filters.
- Per-run theme color annotations at P1: InlineRun.Annotation gains only
  noteRef; theme refs stay in styles/masters/shape fills so theme swaps never
  rewrite block bodies.
- Stored footnote numbers or stored animation click-groups: both are
  derivable (reference order; trigger order) - storing them creates a second
  source of truth the receipts/contentHash pipeline would have to police.
