# Tessera Productivity — Docs Material Surface

> B1 of the 3-material B wave (Docs / Sheets / Slides). Docs is the
> Notion/Craft-style longform document surface — `entity_type='document'`
> `subtype='doc'` — stored as a `Doc` JSON blob in `graph_entities.body`.
> Companion to the productivity design spec §4 (Block AST), §5 (Mutation
> API), §9 (Editor), §10 (Import/Export), §12.1/12.12 (Materials).

---

## 1. Entity model

```swift
struct Doc: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var body: DocumentAST          // spec §4 block tree
    var coverImageURL: URL?        // banner in the detail view
    var iconEmoji: String?         // leading emoji (Notion-style)
    var isArchived: Bool
    var isTrashed: Bool            // soft delete; hard delete removes the row
    var isFavorite: Bool
    var tags: [String]             // normalized lowercase, deduped
    var linkedEntityIDs: [UUID]    // denormalized cache of entity_links
    var createdAt: Date
    var updatedAt: Date

    static let entityType = "document"
    static let subtype    = "doc"
}
```

* Helpers mirror `Note`: `displayTitle` (explicit title → first heading → "Untitled"),
  `snippet(maxLength:)`, `plainText(of:)`, `wordCount`, `readingTimeMinutes`
  (`ceil(words/250)`), `normalizeTags`, `firstHeadingText`.

* `jsonData()` / `from(jsonData:)` use sorted keys + ISO-8601 for
  deterministic bytes; `jsonDataString()` / `from(jsonDataString:)`
  bridge to the data layer's `String` body.

## 2. Storage

One `graph_entities` row per doc:

```
entity_type = 'document', subtype = 'doc', label = displayTitle,
body = Doc JSON, sourceURL = coverImageURL?.absoluteString
```

Migration `0010_docs.sql` — three partial indexes, all
`IF NOT EXISTS`, narrow `WHERE entity_type='document' AND subtype='doc'`:

* `idx_entities_doc_updated` on `(entity_type, updated_at DESC)` — the All list.
* `idx_entities_doc_favorite` with `AND (body->>'isFavorite')='true'` — Favorites.
* `idx_entities_doc_archived` with `AND (body->>'isArchived')='true'` — Archived.

`0011` / `0012` are reserved for Sheets / Slides (same shape, different
predicates) — verify the directory before choosing a number.

## 3. Mutations + receipt taxonomy

Every mutation goes through `TesseraDataLayer` only — no raw SQL outside
the migration. Each emits a signed receipt (`DocReceiptType`):

| Case | Receipt | Trigger |
|------|---------|---------|
| `upsert` | `doc_upsert` | create / full replace |
| `updateBody` | `doc_body_changed` | replace `DocumentAST` |
| `archive` / `unarchive` | `doc_archived` / `doc_unarchived` | archive toggle |
| `trash` / `restore` | `doc_trashed` / `doc_restored` | soft delete |
| `delete` | `doc_delete` | hard delete |
| `favorite` / `unfavorite` | `doc_favorited` / `doc_unfavorited` | star |
| `tagChange` / `tagAdded` / `tagRemoved` | `doc_tags_changed` / `doc_tag_added` / `doc_tag_removed` | tags |
| `link` / `unlink` | `doc_link_created` / `doc_link_deleted` | graph edges |
| `import` | `doc_imported` | importer path |

`DocStore` wraps the data layer (struct, no mutable state). `list(...)`
filters by `subtype='doc'` in memory because the data layer's
`listByEntityType` filters on `entity_type` only — the subtype split
(like Notes/Code) is the same pattern.

## 4. Editor mode

Docs use `EditorMode.document` — the full block palette (headings,
paragraphs, lists, tables, images, code blocks, callouts, dividers,
quotes, toggles, equations) with the complete formatting toolbar and
block-level animations. The platform view is `TesseraEditorView` via
`TesseraTextContentManager` / `STTextView`; Docs reuses the same editor
as every other material, only the mode differs (Notes uses `notes`).

`DocEditorView` is a thin wrapper that binds `DocEditorViewModel.document`
to the editor and routes coalesced commits through `commitBody`.

## 5. Import sources (and what is punted)

v1 importers (Python + Pandoc) already land formats as a `DocumentAST`
and call `DocStore.upsert` + `recordImport`:

* **python-docx** — `.docx` paragraphs/headings/lists/tables/images.
* **Pandoc** — swiss-army bridge for `.docx` fallback, `.md`, `.rst`, etc.
* **HTML via SwiftSoup** — cleaned HTML → block mapping (already a dep).
* **Plain markdown** — the same markdown path Notes uses.

Punted to v2: `.pptx` slide import as docs (Sheets/Slides own it),
PDF import with layout preservation, OCR, password-protected import,
real-time collaborative import, and C2PA signing of imported docs
(the C2PA manifest is a post-import step).

## 6. What this surface does NOT do

* No raw SQL, no raw Redis, no new receipt chain — reuse
  `TesseraDataLayer.appendReceipt` + `graph_receipts`.
* No new editor engine — reuse `TesseraTextContentManager`.
* No Sheets/Slides schema — those workers own `0011`/`0012`.
* No multi-user / real-time collaboration (v2).
