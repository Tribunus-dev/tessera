# Tessera Productivity — Slides Material Surface

> B3 of the 3-material B wave (Docs / Sheets / Slides). Slides is the
> Keynote/pptx-style presentation surface —
> `entity_type='document'` `subtype='slide'` — stored as a `SlideDeck`
> JSON blob in `graph_entities.body`. Companion to the productivity
> design spec §4 (Block AST), §5 (Mutation API), §9 (Editor), §10
> (Import/Export), §12.1/12.12 (Materials). The Docs and Sheets
> surfaces (`0010_docs.sql`, `0011_sheets.sql`) are the sibling
> materials; Slides closes the wave.

---

## 1. Entity model

```swift
struct SlideDeck: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var body: DocumentAST          // canonical block tree (spec §4)
    var slideMeta: [String: SlideMeta] // per-slide layout + speaker notes
    var isArchived: Bool
    var isTrashed: Bool            // soft delete; hard delete removes the row
    var isFavorite: Bool
    var tags: [String]             // normalized lowercase, deduped
    var linkedEntityIDs: [UUID]    // denormalized cache of entity_links
    var createdAt: Date
    var updatedAt: Date

    static let entityType = "document"
    static let subtype    = "slide"
}

struct Slide: Codable, Sendable, Identifiable, Hashable {
    let id: UUID                   // the deck's root block UUID for this slide
    var title: String              // first heading in the slice, or "Slide N"
    var body: DocumentAST          // single-root slice for the canvas
    var index: Int                 // 0-based position in the deck
    var layout: SlideLayout        // title / titleAndContent / image / blank
    var notes: String              // speaker notes for this slide
    var thumbnailHint: String?     // first image source URL in the slice
}

enum SlideLayout: String, Codable, CaseIterable {
    case title, titleAndContent, image, blank
}

struct SlideMeta: Codable, Sendable, Hashable {
    var layout: SlideLayout
    var notes: String
}
```

* Helpers mirror Notes/Docs/Sheets: `displayTitle` (explicit title ->
  first heading -> "Untitled"), `snippet(maxLength:)`,
  `plainText(of:)`, `wordCount`, `normalizeTags`, `firstHeadingText`.
  Plus `slideCount` (`body.rootChildren.count`), `slides` (`[Slide]`
  views), `slide(at:)` / `slide(id:)`, `makeBlank(title:)`,
  `insertingSlide(at:layout:title:)` (pure function; the store's
  `insertSlide` + `duplicateSlide` add the receipt + persistence).

* `jsonData()` / `from(jsonData:)` use sorted keys + ISO-8601 for
  deterministic bytes; `jsonDataString()` / `from(jsonDataString:)`
  bridge to the data layer's `String` body.

* **Deck as DocumentAST.** A deck is a `DocumentAST` whose
  `rootChildren` are slides. In v1 each root child is one slide; a
  `toggle` block groups a heading + paragraph + image for the common
  `titleAndContent` layout (per the productivity spec §4's block
  vocabulary). Every new root block is a new slide. This is the
  simplest mapping that stays valid when the user edits the deck
  through `TesseraEditorView` — the editor already understands the
  full block palette, so a deck body *is* a document body with slide
  semantics layered on top.

* **Slide as logical slice.** The slide is not a separate row — it
  is a projection. `SlideDeck.slides` builds `[Slide]` on demand:
  each `Slide.body` is a single-root AST containing only the deck's
  root block at that index plus its nested children. The slide's
  `layout` and `notes` come from `slideMeta[rootID]`. This avoids
  a second table and keeps deck operations (reorder, duplicate)
  as array operations on `rootChildren`.

## 2. Storage

One `graph_entities` row per deck:

```
entity_type = 'document', subtype = 'slide', label = displayTitle,
body = SlideDeck JSON, sourceURL = nil
```

Migration `0012_slides.sql` — three partial indexes, all
`IF NOT EXISTS`, narrow `WHERE entity_type='document' AND
subtype='slide'`:

* `idx_entities_slide_updated` on `(entity_type, updated_at DESC)` — All.
* `idx_entities_slide_favorite` with `AND (body->>'isFavorite')='true'`.
* `idx_entities_slide_archived` with `AND (body->>'isArchived')='true'`.

`0010` / `0011` are Docs / Sheets; `0012` is reserved for this file
— `ls tools/tessera/db/migrations/` before choosing the number.

## 3. Mutations + receipt taxonomy

Every mutation goes through `TesseraDataLayer` only — no raw SQL
outside the migration. Each emits a signed receipt
(`SlideReceiptType`):

| Case | Receipt | Trigger |
|------|---------|---------|
| `upsert` | `slide_upsert` | create / full replace |
| `updateBody` | `slide_body_changed` | replace `DocumentAST` |
| `insertSlide` | `slide_inserted` | insert at index + layout |
| `deleteSlide` | `slide_deleted` | delete at index |
| `moveSlide` | `slide_moved` | move from -> to |
| `duplicateSlide` | `slide_duplicated` | duplicate at index |
| `setSlideLayout` | `slide_layout_changed` | change layout at index |
| `archive` / `unarchive` | `slide_archived` / `slide_unarchived` | archive toggle |
| `trash` / `restore` | `slide_trashed` / `slide_restored` | soft delete |
| `delete` | `slide_delete` | hard delete |
| `favorite` / `unfavorite` | `slide_favorited` / `slide_unfavorited` | star |
| `tagChange` / `tagAdded` / `tagRemoved` | `slide_tags_changed` / `slide_tag_added` / `slide_tag_removed` | tags |
| `link` / `unlink` | `slide_link_created` / `slide_link_deleted` | graph edges |
| `import` | `slide_imported` | importer path |

`SlideStore` wraps the data layer (struct, no mutable state).
`list(...)` filters by `subtype='slide'` in memory because the data
layer's `listByEntityType` filters on `entity_type` only — the same
pattern as Docs/Sheets (and Notes/Code).

Slide-specific mutations (`insertSlide`, `deleteSlide`, `moveSlide`,
`duplicateSlide`, `setSlideLayout`) all: load the deck, apply the
array / id-map operation, upsert the deck, append the receipt. The
duplicate path deep-copies the slide's block subtree with fresh UUIDs
(`idMap: [UUID: UUID]`) and carries `slideMeta` for the source slide.

## 4. Editor mode + canvas

Slides reuse the existing `TesseraEditorView` / block palette but
surface a presentation-specific canvas:

* **SlideCanvasView** — 16:9 centered card with a shadow + rounded
  border; the slide's blocks render inside (heading sizing, paragraph
  body, image framing, list bullets, quote indentation, code mono).
  Read-only in v1; the deferred inline `TesseraEditorView` for a
  selected slide slice will land with the editor milestone.

* **SlideThumbnailView** — 120x68 miniature in the horizontal rail;
  shows the slide title + a snippet preview + an image badge when the
  slide contains an image. Used in both the Mac and iOS thumb rails.

* **Thumbnail rail** — horizontal `ScrollView` above the canvas;
  tapping a thumb selects the slide; a context menu offers Duplicate,
  Delete, and Layout choices. The Mac detail also exposes a "Add
  Slide" menu with the four layouts.

* **Deck-wide editing.** `SlideDeckEditorViewModel.commitBody(_:)` is
  the bulk path (the same as Docs — replace the whole `DocumentAST`);
  `commitSlideBody(_:slideIndex:)` replaces one slide slice in place
  while remapping `slideMeta` when the root id changes.

* **Swipe between slides** on iOS: a horizontal `DragGesture` with a
  30pt threshold maps to index +/- 1.

## 5. Import / export

v1 importers + exporters (Python + Pandoc + PDFKit) already land
formats as a `DocumentAST` and call `SlideStore.upsert` +
`recordImport`:

* **python-pptx** — `.pptx` slides -> deck: one root block per
  PowerPoint slide. Text frames map to heading/paragraph blocks;
  image shapes map to image blocks; `toggle` grouping is used for
  the title + content pattern. Speaker notes (`slide.notes_slide`)
  map to `SlideMeta.notes`. `SlideMeta.layout` is derived from the
  PowerPoint slide layout id (`Title Slide` -> `.title`, `Title and
  Content` -> `.titleAndContent`, `Picture with Caption` -> `.image`).

* **PDF (PDFKit / PDFMiner)** — `.pdf` pages -> deck: one slide per
  page (image snapshot + OCR text as a paragraph). No layout hint;
  all pages map to `.blank` with the image + text. Speaker notes are
  empty; page number is the implicit slide title until the user
  renames.

* **Export** — `DocumentAST` -> pptx via `python-pptx` (each root
  child becomes one PowerPoint slide; `SlideMeta.layout` selects the
  slide layout), and single-slide export via PDFKit (render the
  `SlideCanvasView` to a `CGPDFContext` or invoke headless Chromium
  for the 16:9 card). Export is a follow-up helper function that
  consumes a `SlideDeck` — the export path does not add receipt types
  beyond `slide_upsert`.

## 6. What is punted

* **Master layouts** — the pptx master/slide-master/theme layer. v1
  stores a four-value `SlideLayout` hint per slide; the full
  Keynote/PowerPoint master hierarchy is a v2 design. Callers that
  need a custom theme apply it at export time via `python-pptx`.

* **Animations and transitions** — pptx animation timelines, Keynote
  Build/Transition presets. The `DocumentAST` has no temporal
  dimension; a slide's content is static. Animated decks import as
  the final frame state.

* **Speaker notes sync** — `SlideMeta.notes` is persisted and shown
  in the detail view, but there is no live two-way sync with
  PowerPoint's notes pane beyond the import path. Notes are edited
  per-slide in the Notes section; the "Export notes to pptx notes"
  path is a follow-up.

* **Slide sorter + outline views** — the vertical outline strip and
  the grid-of-thumbnails sorter are Natural extensions but not in the
  B-wave's "final piece" scope; the horizontal rail + swipe are the
  v1 affordance.

* **Embedded video / audio / chart shapes** — importer drops them;
  the slide renders as text + image only. The `image` block type is
  the slide's image primitive; video/audio are future block types.
