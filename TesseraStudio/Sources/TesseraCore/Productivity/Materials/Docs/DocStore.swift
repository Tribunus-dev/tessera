import Foundation

// MARK: - DocStore

/// The Docs material's seam to ``TesseraDataLayer``. Owns the
/// `Doc` <-> data layer integration, enforces the constitutional-
/// receipt invariant for every mutation, exposes a domain-shaped
/// API to the rest of the productivity surface.
///
/// Mirrors ``NoteStore`` / ``EmailStore`` / ``ProductivityTaskStore``:
/// the store is a struct because the data layer actor is the source
/// of concurrency safety. No mutable state of our own.
///
/// **Receipt contract:** every mutation that changes doc state
/// (upsert, body, archive, trash, favorite, tag, link) appends a
/// signed receipt to `graph_receipts` with a `receipt_type` from
/// ``DocReceiptType`` and a payload that names the affected
/// `entity_id` plus a structural summary.
public struct DocStore: Sendable {

    private let dataLayer: TesseraDataLayer
    /// Optional bridge to the Python format subprocess.
    /// ``importFromFile`` uses this to convert external formats
    /// (DOCX, XLSX, HTML, …) to Block AST. Lazily constructed
    /// so tests can run without a Python subprocess.
    private let _formatBridge: TesseraFormatBridge?

    public init(dataLayer: TesseraDataLayer, formatBridge: TesseraFormatBridge? = nil) {
        self.dataLayer = dataLayer
        self._formatBridge = formatBridge
    }

    /// The format bridge actor. Lazily created.
    private var formatBridge: TesseraFormatBridge {
        _formatBridge ?? TesseraFormatBridge()
    }

    // MARK: - CRUD

    /// Persist a document. If the id already exists the row is
    /// updated in place; otherwise a new row is inserted. Always
    /// appends a `doc_upsert` receipt.
    ///
    /// This is the PUBLIC "save + receipt" entry point - the right call
    /// when a caller outside this store wants to persist a doc and have
    /// that persist itself be the auditable event. Every mutation method
    /// BELOW this one persists through ``persist(_:)`` instead: each of
    /// them already appends its own specific receipt (`doc_body_changed`,
    /// `doc_revision_accepted`, `doc_archived`, ...), so routing through
    /// this method too would append a second, redundant `doc_upsert`
    /// receipt for the same single user action - noise in the audit
    /// trail, not a second real event.
    @discardableResult
    public func upsert(_ doc: Doc) async throws -> Doc {
        let stored = try await persist(doc)
        try await appendReceipt(
            entityID: stored.id,
            receiptType: DocReceiptType.upsert.rawValue,
            payload: [
                "title": .string(stored.displayTitle),
                "tagCount": .number(Double(stored.tags.count)),
                "isFavorite": .bool(stored.isFavorite),
                "isArchived": .bool(stored.isArchived),
                "isTrashed": .bool(stored.isTrashed),
                "linkedEntityCount": .number(Double(stored.linkedEntityIDs.count)),
                "wordCount": .number(Double(stored.wordCount)),
            ]
        )
        return stored
    }

    /// Write `doc`'s current state to the data layer without appending
    /// any receipt - the persistence primitive every mutation method in
    /// this file uses. See ``upsert(_:)``'s doc comment for why this is
    /// a separate, receipt-less method rather than every mutation
    /// calling `upsert` directly.
    private func persist(_ doc: Doc) async throws -> Doc {
        var stored = doc
        stored.updatedAt = Date()
        let body = try stored.jsonDataString()
        _ = try await dataLayer.upsertEntity(
            GraphEntityUpsert(
                id: stored.id,
                entityType: Doc.entityType,
                subtype: Doc.subtype,
                label: stored.displayTitle,
                body: body,
                sourceURL: stored.coverImageURL?.absoluteString,
                embedding: nil
            )
        )
        return stored
    }

    /// Fetch one doc by id. Returns nil when no
    /// `graph_entity` row with `entity_type='document'` and
    /// `subtype='doc'` matches.
    public func get(id: UUID) async throws -> Doc? {
        guard let entity = try await dataLayer.getEntity(id: id) else {
            return nil
        }
        guard entity.entityType == Doc.entityType,
              entity.subtype == Doc.subtype else {
            return nil
        }
        return try Self.docFromEntity(entity)
    }

    /// Hard-delete a doc by id. Returns true when a row was
    /// removed. The receipt chain is preserved (receipts are
    /// append-only); only the entity row is removed.
    @discardableResult
    public func delete(id: UUID) async throws -> Bool {
        let didDelete = try await dataLayer.deleteEntity(id: id)
        if didDelete {
            try await appendReceipt(
                entityID: id,
                receiptType: DocReceiptType.delete.rawValue,
                payload: [:]
            )
        }
        return didDelete
    }

    // MARK: - Listing

    /// Every doc, newest updated first. The data layer's
    /// `listByEntityType` orders by `updated_at DESC`.
    public func list(limit: Int = 1000) async throws -> [Doc] {
        let rows = try await dataLayer.listByEntityType(
            entityType: Doc.entityType,
            limit: limit
        )
        // Filter to subtype='doc' in memory (the data layer
        // lists by entity_type only; Docs is one subtype of
        // 'document' — the other subtypes are 'sheet' / 'slide' /
        // 'email' which live in other stores).
        return try rows.compactMap { row in
            guard row.subtype == Doc.subtype else { return nil }
            return try? Self.docFromEntity(row)
        }
    }

    /// Docs that are not archived and not trashed. The default
    /// "All" view.
    public func listActive(limit: Int = 1000) async throws -> [Doc] {
        let all = try await list(limit: limit)
        return all.filter { !$0.isArchived && !$0.isTrashed }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Search docs whose display title matches `query` (case-
    /// insensitive prefix over `label`).
    public func search(matching query: String, limit: Int = 20) async throws -> [Doc] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        let rows = try await dataLayer.searchByLabelPrefix(
            entityType: Doc.entityType,
            labelPrefix: trimmed,
            limit: limit
        )
        return try rows.compactMap { row in
            guard row.subtype == Doc.subtype else { return nil }
            return try? Self.docFromEntity(row)
        }
    }

    // MARK: - Body

    /// Replace the body AST. Bumps `updatedAt` and emits a
    /// `doc_body_changed` receipt.
    public func setBody(_ body: DocumentAST, for docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        if doc.title.isEmpty, let first = Doc.firstHeadingText(in: body) {
            doc.title = first
        }
        doc.body = body
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.updateBody.rawValue,
            payload: [
                "blockCount": .number(Double(body.blocks.count)),
                "rootChildCount": .number(Double(body.rootChildren.count)),
            ]
        )
        return doc
    }

    // MARK: - Revisions

    /// Accept a track-changes revision: every `.trackInsertion`/
    /// `.trackDeletion` block sharing `revisionID` resolves per
    /// `RevisionController.accept` (insertions become plain content,
    /// deletions are removed). Persists the resulting body and
    /// appends the `doc_revision_accepted` receipt `RevisionResolution`
    /// already carries - built by `RevisionController`, not
    /// reconstructed here.
    ///
    /// An unknown/already-resolved `revisionID` resolves to an empty
    /// group (`resolution.isEmpty`, the AST unchanged) - matching
    /// `FieldController`'s "only emit when something actually
    /// changed" precedent, this is a no-op through: no upsert, no
    /// receipt, the loaded doc is returned as-is.
    public func acceptRevision(_ revisionID: UUID, for docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        let (ast, resolution) = RevisionController.accept(revisionID: revisionID, in: doc.body)
        guard !resolution.isEmpty else { return doc }
        doc.body = ast
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(
            entityID: docID,
            receiptType: resolution.receiptType,
            payload: resolution.payload
        )
        return doc
    }

    /// Reject a track-changes revision: the inverse of
    /// `acceptRevision` - insertions are removed, deletions become
    /// plain content (`RevisionController.reject`). See
    /// `acceptRevision`'s doc comment for the no-op case.
    public func rejectRevision(_ revisionID: UUID, for docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        let (ast, resolution) = RevisionController.reject(revisionID: revisionID, in: doc.body)
        guard !resolution.isEmpty else { return doc }
        doc.body = ast
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(
            entityID: docID,
            receiptType: resolution.receiptType,
            payload: resolution.payload
        )
        return doc
    }

    // MARK: - Search

    /// Runs `DocumentSearchIndex.replacingAll` against the doc's body and
    /// persists the result. A query that matches nothing is a no-op - no
    /// upsert, no receipt - matching `acceptRevision`/`rejectRevision`'s
    /// "only emit when something actually changed" precedent.
    public func findAndReplace(
        _ query: String,
        with replacement: String,
        options: DocumentSearchIndex.SearchOptions = .init(),
        for docID: UUID
    ) async throws -> (doc: Doc, replacedCount: Int) {
        var doc = try await loadOrFail(id: docID)
        let (ast, replacedCount, receiptPayload) = DocumentSearchIndex.replacingAll(
            query, with: replacement, in: doc.body, options: options
        )
        guard replacedCount > 0 else { return (doc, 0) }
        doc.body = ast
        doc.updatedAt = Date()
        _ = try await persist(doc)
        // receiptPayload's own "receiptType" field is DocumentSearchIndex's
        // pre-DocReceiptType placeholder literal - redundant now that the
        // real enum case is the receipt's actual receipt_type, so it is
        // dropped rather than persisted twice.
        var payload = receiptPayload
        payload.removeValue(forKey: "receiptType")
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.findReplace.rawValue,
            payload: payload
        )
        return (doc, replacedCount)
    }

    // MARK: - Styles

    /// Define (or replace, by matching `id`) a style in
    /// `doc.body.meta.styles` - the "plain dictionary write"
    /// `StyleRegistry`'s own file header describes (no
    /// `StyleRegistry.definingStyle` exists; this is the one seam that
    /// both writes `DocumentMeta.styles` and appends the receipt,
    /// mirroring `MasterPageStore.defineMasterPage`).
    public func defineStyle(_ style: StyleDefinition, for docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        let replacedPrevious = doc.body.meta.styles[style.id] != nil
        doc.body.meta.styles[style.id] = style
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.defineStyle.rawValue,
            payload: [
                "styleID": .string(style.id.uuidString),
                "name": .string(style.name),
                "family": .string(style.family.rawValue),
                "replacedPrevious": .bool(replacedPrevious),
            ]
        )
        return doc
    }

    /// Remove a style. `StyleRegistry.deletingStyle` already rebinds any
    /// child whose `basedOn` pointed at `styleID` to the deleted style's
    /// own parent before returning; this method assigns that result
    /// straight back to `doc.body.meta.styles` rather than re-deriving
    /// the rebind itself. A no-op (no upsert, no receipt) if `styleID`
    /// isn't defined, matching `deletingStyle`'s own no-op-on-missing-id
    /// behavior.
    public func deleteStyle(_ styleID: UUID, for docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        guard doc.body.meta.styles[styleID] != nil else { return doc }
        doc.body.meta.styles = StyleRegistry.deletingStyle(styleID, from: doc.body.meta.styles)
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.deleteStyle.rawValue,
            payload: ["styleID": .string(styleID.uuidString)]
        )
        return doc
    }

    // MARK: - Fields

    /// Re-resolve every `.field` block in the doc's body via
    /// `FieldController.refresh`, writing back only the blocks whose
    /// resolved `Block` actually differs from the one passed in - a
    /// plain `!=` check, which `refresh`'s own idempotence under a
    /// fixed `clock` is what makes that check sufficient (see
    /// `FieldController.swift`'s file header). A doc where nothing
    /// changed - no `.field` blocks, every field already resolved
    /// under this `clock`, or every field is layout-sensitive and so
    /// stays untouched per `FieldController`'s documented P1
    /// limitation - is a no-op through: no upsert, no receipt,
    /// matching `acceptRevision`/`findAndReplace`/`deleteStyle`'s
    /// "only emit when something actually changed" precedent in this
    /// same store.
    public func refreshFields(
        for docID: UUID,
        clock: @escaping () -> Date = Date.init
    ) async throws -> (doc: Doc, refreshedCount: Int) {
        var doc = try await loadOrFail(id: docID)
        let fieldBlockIDs = doc.body.blocks.compactMap { id, block in block.type == .field ? id : nil }
        var changedCount = 0
        for id in fieldBlockIDs {
            guard let block = doc.body.blocks[id] else { continue }
            let refreshed = FieldController.refresh(block, in: doc.body, clock: clock)
            guard refreshed != block else { continue }
            doc.body.blocks[id] = refreshed
            changedCount += 1
        }
        guard changedCount > 0 else { return (doc, 0) }
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.fieldsRefreshed.rawValue,
            payload: ["refreshedCount": .number(Double(changedCount))]
        )
        return (doc, changedCount)
    }

    // MARK: - Table of Contents

    /// Regenerate a `.toc` block's entry children via
    /// `TocController.regenerate` - see that file's header for the full
    /// collection algorithm. A no-op (no persist, no receipt) when
    /// `tocBlockID` isn't a `.toc` block with a `TocSpec`, or when
    /// regeneration finds nothing changed - matching `refreshFields`/
    /// `deleteStyle`'s "only emit when something actually changed"
    /// precedent in this store.
    public func regenerateToc(for docID: UUID, tocBlockID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        let (ast, result) = TocController.regenerate(tocBlockID, in: doc.body)
        guard result.changed else { return doc }
        doc.body = ast
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(
            entityID: docID,
            receiptType: result.receiptType,
            payload: result.payload
        )
        return doc
    }

    // MARK: - Master Documents

    /// Apply a new `MasterDocSpec` (2.11) to a master document,
    /// mirroring `spec.parts` into `linkedEntityIDs` - see
    /// `MasterDocController` for the full design. A no-op (no persist,
    /// no receipt) when `spec` is identical to what was already stored,
    /// matching `refreshFields`/`deleteStyle`'s "only emit when
    /// something actually changed" precedent in this store.
    public func setMasterDocSpec(_ spec: MasterDocSpec, for docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        let result = MasterDocController.applyingSpec(spec, over: doc.masterDocSpec, docID: docID)
        guard result.changed else { return doc }
        let previousParts = doc.masterDocSpec?.parts ?? []
        doc.masterDocSpec = spec
        doc.linkedEntityIDs = MasterDocController.mirroringParts(spec.parts, previousParts: previousParts, into: doc.linkedEntityIDs)
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(
            entityID: docID,
            receiptType: result.receiptType,
            payload: result.payload
        )
        return doc
    }

    // MARK: - Mail Merge

    /// Record that a mail-merge run completed (2.4) - the merge
    /// OPERATION's own audit entry, distinct from each output
    /// document's own `doc_upsert` receipt (already emitted by the
    /// ordinary `upsert` path when `MailMergeCoordinator` persists each
    /// merged doc). Unlike every other mutation in this store, this
    /// method has no "did anything change" guard: the contract here is
    /// "the run happened", not "some stored state changed" - it always
    /// appends exactly one receipt for a completed run.
    public func recordMailMerge(sourceHash: String, recordCount: Int, for templateDocID: UUID) async throws {
        try await appendReceipt(
            entityID: templateDocID,
            receiptType: DocReceiptType.runMailMerge.rawValue,
            payload: [
                "sourceHash": .string(sourceHash),
                "recordCount": .number(Double(recordCount)),
            ]
        )
    }

    // MARK: - Macros

    /// Translate one or more VBA module outlines to stored playbook
    /// artifacts (2.13) via `MacroCompatLayer.translate`, merging into
    /// `doc.macroPlaybooks` by `sourceModuleName` (replacing any prior
    /// entry for the same module, leaving every other module's entry
    /// untouched) rather than replacing the whole array - so a partial
    /// re-translate of one module doesn't discard another module's
    /// already-translated result. No "did anything change" guard: like
    /// `recordMailMerge`, this method's contract is "the run happened"
    /// - a translate call always appends exactly one receipt, even if
    /// its output happens to equal a prior translation byte-for-byte.
    public func translateMacro(for docID: UUID, outlines: [VBAModuleOutline]) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        let translated = MacroCompatLayer.translate(outlines)
        var byName = Dictionary(uniqueKeysWithValues: doc.macroPlaybooks.map { ($0.sourceModuleName, $0) })
        for playbook in translated {
            byName[playbook.sourceModuleName] = playbook
        }
        doc.macroPlaybooks = doc.macroPlaybooks.map { byName[$0.sourceModuleName] ?? $0 }
        for playbook in translated where !doc.macroPlaybooks.contains(where: { $0.sourceModuleName == playbook.sourceModuleName }) {
            doc.macroPlaybooks.append(playbook)
        }
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.translateMacro.rawValue,
            payload: [
                "moduleNames": .array(translated.map { .string($0.sourceModuleName) }),
                "moduleCount": .number(Double(translated.count)),
            ]
        )
        return doc
    }

    // MARK: - Forms

    /// Fill a content-control form field (2.15) via `FormController.fill`.
    /// A no-op (no persist, no receipt) when the target block has no
    /// content control, is locked, or `value` fails the control's own
    /// per-kind validation (e.g. a `dropDownList` value not present in
    /// `listItems`) - `FormController.fill` returns the block unchanged
    /// in every one of those cases, so a plain `!=` check catches them
    /// all, matching `refreshFields`/`regenerateToc`'s "only emit when
    /// something actually changed" precedent in this store. Stays
    /// tier1 even on a protected fill-in-only document per the
    /// architect's ratified default - the protection check itself
    /// (gating every OTHER write) is future-wave scope, not added here.
    public func fillForm(blockID: UUID, value: String, for docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        guard let block = doc.body.blocks[blockID] else {
            throw DocStoreError.blockNotFound(id: blockID)
        }
        let before = block.contentControl.map { FormController.resolvedValue(for: $0, hostBlock: block) ?? "" } ?? ""
        let filled = FormController.fill(block, in: doc.body, value: value)
        guard filled != block else { return doc }
        doc.body.blocks[blockID] = filled
        doc.updatedAt = Date()
        _ = try await persist(doc)
        let control = filled.contentControl!
        let after = FormController.resolvedValue(for: control, hostBlock: filled) ?? ""
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.fillForm.rawValue,
            payload: [
                "blockID": .string(blockID.uuidString),
                "tag": .string(control.tag),
                "before": .string(before),
                "after": .string(after),
            ]
        )
        return doc
    }

    // MARK: - Footnotes / Endnotes (P2-0 item 1: insert/delete lifecycle)

    /// Insert a new footnote/endnote body block anchored at a UTF-16 text
    /// offset inside `anchorBlockID`'s own `content` - see
    /// `NoteController.insertNote` for the marker-splicing mechanics and
    /// why the new note body is written to `doc.body.meta.notes`, never
    /// `doc.body.blocks`. A no-op (no persist, no receipt) when `kind`
    /// isn't `.footnote`/`.endnote`, `anchorBlockID` doesn't exist in the
    /// doc's body, or `offset` falls outside the anchor's own content
    /// length - an invalid anchor, matching `acceptRevision`/
    /// `findAndReplace`/`deleteStyle`'s "only emit when something
    /// actually changed" precedent in this store. Numbering is never
    /// persisted here (derived-never-stored law) -
    /// `DocumentAST.deriveNoteNumbering()` re-derives it on read.
    public func insertNote(
        kind: BlockType,
        anchorBlockID: UUID,
        at offset: Int,
        text: String,
        for docID: UUID
    ) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        guard let (ast, outcome) = NoteController.insertNote(
            kind: kind, anchorBlockID: anchorBlockID, at: offset, noteText: text, in: doc.body
        ) else { return doc }
        doc.body = ast
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(entityID: docID, receiptType: outcome.receiptType, payload: outcome.payload)
        return doc
    }

    /// Delete a footnote/endnote body block and strip every in-text
    /// reference to it - see `NoteController.deleteNote`. A no-op (no
    /// persist, no receipt) when `noteID` isn't registered in
    /// `doc.body.meta.notes`.
    public func deleteNote(_ noteID: UUID, for docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        guard let (ast, outcome) = NoteController.deleteNote(noteID: noteID, in: doc.body) else { return doc }
        doc.body = ast
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(entityID: docID, receiptType: outcome.receiptType, payload: outcome.payload)
        return doc
    }

    // MARK: - Archive / Trash / Favorite

    public func archive(_ docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        guard !doc.isArchived else { return doc }
        doc.isArchived = true
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.archive.rawValue,
            payload: ["wasAlreadyArchived": .bool(false)]
        )
        return doc
    }

    public func unarchive(_ docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        guard doc.isArchived else { return doc }
        doc.isArchived = false
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.unarchive.rawValue,
            payload: ["wasArchived": .bool(true)]
        )
        return doc
    }

    /// Move to trash (soft delete). Idempotent - a no-op (no persist, no
    /// receipt) if the doc is already trashed.
    public func trash(_ docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        guard !doc.isTrashed else { return doc }
        doc.isTrashed = true
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.trash.rawValue,
            payload: ["wasAlreadyTrashed": .bool(false)]
        )
        return doc
    }

    /// Restore from trash. Idempotent - a no-op (no persist, no receipt)
    /// if the doc was never trashed.
    public func restore(_ docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        guard doc.isTrashed else { return doc }
        doc.isTrashed = false
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.restore.rawValue,
            payload: ["wasTrashed": .bool(true)]
        )
        return doc
    }

    public func favorite(_ docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        guard !doc.isFavorite else { return doc }
        doc.isFavorite = true
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.favorite.rawValue,
            payload: ["wasAlreadyFavorite": .bool(false)]
        )
        return doc
    }

    public func unfavorite(_ docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        guard doc.isFavorite else { return doc }
        doc.isFavorite = false
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.unfavorite.rawValue,
            payload: ["wasFavorite": .bool(true)]
        )
        return doc
    }

    // MARK: - Tags

    public func setTags(_ tags: [String], for docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        let oldTags = doc.tags
        let normalized = Doc.normalizeTags(tags)
        doc.tags = normalized
        doc.updatedAt = Date()
        _ = try await persist(doc)
        let added = normalized.filter { !oldTags.contains($0) }
        let removed = oldTags.filter { !normalized.contains($0) }
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.tagChange.rawValue,
            payload: [
                "addedTags": .array(added.map { .string($0) }),
                "removedTags": .array(removed.map { .string($0) }),
            ]
        )
        return doc
    }

    public func addTag(_ tag: String, to docID: UUID) async throws -> Doc {
        let normalized = Doc.normalizeTags([tag])
        guard let first = normalized.first else { return try await loadOrFail(id: docID) }
        var doc = try await loadOrFail(id: docID)
        if doc.tags.contains(first) {
            try await appendReceipt(
                entityID: docID,
                receiptType: DocReceiptType.tagAdded.rawValue,
                payload: ["tag": .string(first), "wasAlreadyPresent": .bool(true)]
            )
            return doc
        }
        doc.tags.append(first)
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.tagAdded.rawValue,
            payload: ["tag": .string(first), "wasAlreadyPresent": .bool(false)]
        )
        return doc
    }

    public func removeTag(_ tag: String, from docID: UUID) async throws -> Doc {
        let normalized = Doc.normalizeTags([tag])
        guard let first = normalized.first else { return try await loadOrFail(id: docID) }
        var doc = try await loadOrFail(id: docID)
        guard let index = doc.tags.firstIndex(of: first) else {
            try await appendReceipt(
                entityID: docID,
                receiptType: DocReceiptType.tagRemoved.rawValue,
                payload: ["tag": .string(first), "wasPresent": .bool(false)]
            )
            return doc
        }
        doc.tags.remove(at: index)
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.tagRemoved.rawValue,
            payload: ["tag": .string(first), "wasPresent": .bool(true)]
        )
        return doc
    }

    // MARK: - Linking

    /// Link a doc to another graph entity. Creates an
    /// `entity_link` row AND appends a receipt.
    @discardableResult
    public func link(
        docID: UUID,
        to otherEntityID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0
    ) async throws -> EntityLink {
        let link = try await dataLayer.linkEntities(
            sourceID: docID,
            targetID: otherEntityID,
            linkType: linkType,
            weight: weight
        )
        if var doc = try await get(id: docID),
           !doc.linkedEntityIDs.contains(otherEntityID) {
            doc.linkedEntityIDs.append(otherEntityID)
            doc.updatedAt = Date()
            _ = try await dataLayer.upsertEntity(
                GraphEntityUpsert(
                    id: doc.id,
                    entityType: Doc.entityType,
                    subtype: Doc.subtype,
                    label: doc.displayTitle,
                    body: try doc.jsonDataString(),
                    sourceURL: doc.coverImageURL?.absoluteString,
                    embedding: nil
                )
            )
        }
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.link.rawValue,
            payload: [
                "targetEntityID": .string(otherEntityID.uuidString),
                "linkType": .string(linkType),
                "weight": .number(Double(weight)),
            ]
        )
        return link
    }

    /// Remove a link (receipt-only in v1; the link row stays
    /// until the follow-up migration adds row deletion).
    public func unlink(
        docID: UUID,
        from otherEntityID: UUID,
        linkType: String = "related_to"
    ) async throws {
        if var doc = try await get(id: docID),
           let idx = doc.linkedEntityIDs.firstIndex(of: otherEntityID) {
            doc.linkedEntityIDs.remove(at: idx)
            doc.updatedAt = Date()
            _ = try await dataLayer.upsertEntity(
                GraphEntityUpsert(
                    id: doc.id,
                    entityType: Doc.entityType,
                    subtype: Doc.subtype,
                    label: doc.displayTitle,
                    body: try doc.jsonDataString(),
                    sourceURL: doc.coverImageURL?.absoluteString,
                    embedding: nil
                )
            )
        }
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.unlink.rawValue,
            payload: [
                "targetEntityID": .string(otherEntityID.uuidString),
                "linkType": .string(linkType),
            ]
        )
    }

    // MARK: - Comments (P2-0 item 3: full lifecycle, block-tree based)
    //
    // Doc's comment model is block-tree based (`BlockType.comment`
    // blocks - see `Comments.swift`'s `CommentStore.threads(from:)`, which
    // already knows how to walk root-vs-reply blocks), NOT the flat
    // `CommentThread`-array model `Sheet`/`SlideDeck` use - the
    // pre-landed `Comments.swift` helpers (`addingReply`/`.resolved`/
    // `replacingCommentThread`) do not apply here. These methods
    // manipulate `doc.body`'s block tree directly, mirroring the shape
    // `TesseraSTTextView.insertCommentBlock` already established for a
    // NEW thread's root block: inserted into `rootChildren`, right after
    // the anchor block's own root-level position.

    /// Start a new comment thread: inserts a new root `.comment` block
    /// into `doc.body.rootChildren`, right after `anchorBlockID`'s own
    /// root-level position (appended at the end of `rootChildren` when
    /// `anchorBlockID` isn't itself a root child - e.g. nested inside a
    /// list/table - the same fallback `TesseraSTTextView
    /// .insertCommentBlock` uses). A no-op (no persist, no receipt) when
    /// `anchorBlockID` isn't in the document - an invalid anchor.
    public func addComment(
        anchorBlockID: UUID,
        anchorRangeStart: Int,
        anchorRangeEnd: Int,
        author: String,
        text: String,
        for docID: UUID
    ) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        guard doc.body.contains(anchorBlockID) else { return doc }

        let commentID = UUID()
        let commentBlock = Block(
            id: commentID,
            type: .comment,
            attributes: [
                "anchorBlockID": .string(anchorBlockID.uuidString),
                "anchorRangeStart": .number(Double(anchorRangeStart)),
                "anchorRangeEnd": .number(Double(anchorRangeEnd)),
                "author": .string(author),
                "timestamp": .number(Date().timeIntervalSince1970),
                "resolved": .bool(false),
            ],
            content: [InlineRun(text: text)]
        )
        var ast = doc.body
        Self.insertCommentRoot(commentBlock, after: anchorBlockID, in: &ast)
        doc.body = ast
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.addComment.rawValue,
            payload: [
                "commentID": .string(commentID.uuidString),
                "anchorBlockID": .string(anchorBlockID.uuidString),
                "author": .string(author),
            ]
        )
        return doc
    }

    /// Append a reply to an existing comment thread: a new `.comment`
    /// block added to `threadID`'s own `children`. A no-op (no persist,
    /// no receipt) when `threadID` isn't a genuine thread ROOT - it must
    /// be a `.comment` block with `parentID == nil` (every thread root
    /// this store creates lives in `rootChildren`, per `addComment`
    /// above); a reply target that is itself a reply is rejected rather
    /// than silently nesting a reply-of-reply, which `CommentStore
    /// .threads(from:)` has no way to surface (it only walks a root's
    /// OWN direct children for messages).
    public func replyToComment(
        threadID: UUID,
        author: String,
        text: String,
        for docID: UUID
    ) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        guard let root = doc.body.blocks[threadID], root.type == .comment, root.parentID == nil else { return doc }

        let replyID = UUID()
        let replyBlock = Block(
            id: replyID,
            type: .comment,
            attributes: [
                "author": .string(author),
                "timestamp": .number(Date().timeIntervalSince1970),
            ],
            content: [InlineRun(text: text)],
            parentID: threadID
        )
        var ast = doc.body
        ast.blocks[replyID] = replyBlock
        ast.blocks[threadID]?.children.append(replyID)
        doc.body = ast
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.commentReplied.rawValue,
            payload: [
                "threadID": .string(threadID.uuidString),
                "replyID": .string(replyID.uuidString),
                "author": .string(author),
            ]
        )
        return doc
    }

    /// Mark a comment thread resolved: sets the root block's
    /// `attributes["resolved"]` to `true`. A no-op (no persist, no
    /// receipt) when `threadID` isn't a `.comment` block, or is already
    /// resolved - matching `archive`/`trash`/`favorite`'s idempotence
    /// precedent in this same store.
    public func resolveComment(_ threadID: UUID, for docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        guard var root = doc.body.blocks[threadID], root.type == .comment else { return doc }
        guard root.attributes["resolved"]?.boolValue != true else { return doc }

        root.attributes["resolved"] = .bool(true)
        var ast = doc.body
        ast.blocks[threadID] = root
        doc.body = ast
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.commentResolved.rawValue,
            payload: ["threadID": .string(threadID.uuidString)]
        )
        return doc
    }

    /// Delete a comment thread: removes the root `.comment` block and its
    /// whole subtree (every reply, recursively) - see
    /// `removeCommentSubtree`. A no-op (no persist, no receipt) when
    /// `threadID` isn't a `.comment` block. Deleting a REPLY block's own
    /// id (rather than a thread root) is accepted too: it removes just
    /// that reply (and anything nested under it), the same "gone means
    /// gone" subtree removal, scoped to whatever block id was passed.
    public func deleteComment(_ threadID: UUID, for docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        guard doc.body.blocks[threadID]?.type == .comment else { return doc }

        var ast = doc.body
        let removedCount = Self.removeCommentSubtree(threadID, in: &ast)
        doc.body = ast
        doc.updatedAt = Date()
        _ = try await persist(doc)
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.commentDeleted.rawValue,
            payload: [
                "threadID": .string(threadID.uuidString),
                "blocksRemoved": .number(Double(removedCount)),
            ]
        )
        return doc
    }

    // MARK: - Comments: block-tree helpers
    //
    // `internal` (not `private`) so DocStoreTests can exercise this pure
    // tree-surgery logic directly, without a live data layer - the
    // ungated shadow of the gated `addComment`/`deleteComment` contract
    // (testing-doctrine.md rule 11), mirroring how RevisionController/
    // FieldController/StyleRegistry each carry their own DB-free coverage
    // for the decision logic DocStore's gated tests exercise end-to-end.

    /// Insert `block` into `ast.rootChildren` immediately after
    /// `anchorBlockID`'s own root-level position - falls back to the end
    /// of `rootChildren` when `anchorBlockID` isn't itself a root child.
    /// Forces `block.parentID = nil` (a thread root always lives at the
    /// document root, never nested) regardless of what the caller passed.
    static func insertCommentRoot(_ block: Block, after anchorBlockID: UUID, in ast: inout DocumentAST) {
        var toInsert = block
        toInsert.parentID = nil
        ast.blocks[toInsert.id] = toInsert
        if let idx = ast.rootChildren.firstIndex(of: anchorBlockID) {
            ast.rootChildren.insert(toInsert.id, at: idx + 1)
        } else {
            ast.rootChildren.append(toInsert.id)
        }
    }

    /// Removes `blockID` and every block reachable from it via
    /// `children`, recursively, then unlinks `blockID` from its parent's
    /// `children` (or `rootChildren` when it was a root) - the same
    /// "gone means gone" shape as `RevisionController.removeSubtree`.
    /// Returns the count of blocks removed (the target block plus every
    /// descendant).
    @discardableResult
    static func removeCommentSubtree(_ blockID: UUID, in ast: inout DocumentAST) -> Int {
        guard let removed = ast.blocks.removeValue(forKey: blockID) else { return 0 }
        var count = 1
        for child in removed.children {
            count += removeCommentSubtree(child, in: &ast)
        }
        if let parentID = removed.parentID {
            ast.blocks[parentID]?.children.removeAll { $0 == blockID }
        } else {
            ast.rootChildren.removeAll { $0 == blockID }
        }
        return count
    }

    // MARK: - Hybrid search (subtype-filtered)

    /// Hybrid search for docs: delegates to the data layer's RRF
    /// and filters to subtype='doc' in Swift. The data layer's
    /// hybrid_search already returns subtype so the filter is
    /// cheap and reversible.
    public func hybridSearch(
        anchor: UUID,
        queryText: String? = nil,
        queryEmbedding: [Float]? = nil,
        maxDepth: Int = 3
    ) async throws -> [HybridSearchResult] {
        let results = try await dataLayer.hybridSearch(
            anchor: anchor,
            queryText: queryText,
            queryEmbedding: queryEmbedding,
            maxDepth: maxDepth
        )
        return results.filter { $0.entityType == Doc.entityType && $0.subtype == Doc.subtype }
    }

    // MARK: - Import marker

    /// Record that a doc was imported from an external format.
    /// The payload records the source format.
    public func recordImport(docID: UUID, sourceFormat: String) async throws {
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.import.rawValue,
            payload: ["sourceFormat": .string(sourceFormat)]
        )
    }

    // MARK: - File import

    /// Import a file's bytes into a new doc. The bridge converts
    /// the external format to a Block AST; the doc is persisted
    /// via ``upsert`` and a ``DocReceiptType.import`` receipt
    /// is appended to the chain.
    ///
    /// - Parameters:
    ///   - data: the raw file bytes
    ///   - format: the source format (e.g. `"docx"`, `"html"`)
    ///   - title: optional display title; defaults to the first
    ///     heading text in the AST, or `"Imported Document"` if
    ///     the AST has no headings
    /// - Returns: the newly-created doc
    public func importFromFile(
        data: Data,
        format: String,
        title: String? = nil
    ) async throws -> Doc {
        // 1. Convert to Block AST via the Python bridge
        let astData = try await formatBridge.importFile(data: data, format: format)
        let ast = try DocumentAST.from(jsonData: astData)

        // 2. Create the doc
        let resolvedTitle: String
        if let title, !title.isEmpty {
            resolvedTitle = title
        } else if let firstHeading = Doc.firstHeadingText(in: ast) {
            resolvedTitle = firstHeading
        } else {
            resolvedTitle = "Imported Document"
        }

        let doc = Doc(
            id: UUID(),
            title: resolvedTitle,
            body: ast,
            createdAt: Date(),
            updatedAt: Date()
        )

        // 3. Persist
        let stored = try await upsert(doc)

        // 4. Record the import receipt
        try await recordImport(docID: stored.id, sourceFormat: format)

        return stored
    }

    // MARK: - Receipts

    public func receipts(forDoc docID: UUID) async throws -> [GraphReceipt] {
        try await dataLayer.receipts(forEntity: docID)
    }

    /// Return the receipt chain for a document, oldest first.
    /// Decodes each row's payload into a typed ``Receipt``.
    public func history(of docID: UUID, limit: Int = 100) async throws -> [Receipt] {
        let chain = try await dataLayer.receiptChain(documentID: docID, limit: limit)
        return chain.compactMap { Self.decodeReceipt(from: $0.receipt) }
    }

    // MARK: - Helpers

    private func appendReceipt(
        entityID: UUID,
        receiptType: String,
        payload: [String: JSONValue]
    ) async throws {
        _ = try await dataLayer.appendReceipt(
            entityID: entityID,
            receiptType: receiptType,
            payload: payload
        )
    }

    private func loadOrFail(id: UUID) async throws -> Doc {
        guard let doc = try await get(id: id) else {
            throw DocStoreError.docNotFound(id: id)
        }
        return doc
    }

    private static func docFromEntity(_ entity: GraphEntity) throws -> Doc? {
        guard entity.entityType == Doc.entityType,
              entity.subtype == Doc.subtype else { return nil }
        guard let body = entity.body, !body.isEmpty else { return nil }
        return try Doc.from(jsonDataString: body)
    }

    // MARK: - JSON helpers (for history decoding)

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Decode a typed ``Receipt`` from a ``GraphReceipt`` row.
    private static func decodeReceipt(from row: GraphReceipt) -> Receipt? {
        guard let data = try? jsonEncoder.encode(row.payload),
              let receipt = try? jsonDecoder.decode(Receipt.self, from: data) else {
            return nil
        }
        return receipt
    }
}

// MARK: - DocStoreError

public enum DocStoreError: Error, Sendable, Equatable {
    case docNotFound(id: UUID)
    case invalidBody(reason: String)
    /// A block id passed to a block-scoped mutation (e.g. `fillForm`)
    /// doesn't exist in the target doc's current body.
    case blockNotFound(id: UUID)
}
