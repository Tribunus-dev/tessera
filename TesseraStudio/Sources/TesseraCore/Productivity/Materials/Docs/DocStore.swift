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
    @discardableResult
    public func upsert(_ doc: Doc) async throws -> Doc {
        var stored = doc
        stored.updatedAt = Date()
        let body = try stored.jsonDataString()
        let label = stored.displayTitle
        _ = try await dataLayer.upsertEntity(
            GraphEntityUpsert(
                id: stored.id,
                entityType: Doc.entityType,
                subtype: Doc.subtype,
                label: label,
                body: body,
                sourceURL: stored.coverImageURL?.absoluteString,
                embedding: nil
            )
        )
        try await appendReceipt(
            entityID: stored.id,
            receiptType: DocReceiptType.upsert.rawValue,
            payload: [
                "title": .string(label),
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
        _ = try await upsert(doc)
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

    // MARK: - Archive / Trash / Favorite

    public func archive(_ docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        let wasArchived = doc.isArchived
        if !wasArchived {
            doc.isArchived = true
            doc.updatedAt = Date()
            _ = try await upsert(doc)
        }
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.archive.rawValue,
            payload: ["wasAlreadyArchived": .bool(wasArchived)]
        )
        return doc
    }

    public func unarchive(_ docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        let wasArchived = doc.isArchived
        if wasArchived {
            doc.isArchived = false
            doc.updatedAt = Date()
            _ = try await upsert(doc)
        }
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.unarchive.rawValue,
            payload: ["wasArchived": .bool(wasArchived)]
        )
        return doc
    }

    /// Move to trash (soft delete). Idempotent.
    public func trash(_ docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        let wasTrashed = doc.isTrashed
        if !wasTrashed {
            doc.isTrashed = true
            doc.updatedAt = Date()
            _ = try await upsert(doc)
        }
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.trash.rawValue,
            payload: ["wasAlreadyTrashed": .bool(wasTrashed)]
        )
        return doc
    }

    /// Restore from trash. Idempotent.
    public func restore(_ docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        let wasTrashed = doc.isTrashed
        if wasTrashed {
            doc.isTrashed = false
            doc.updatedAt = Date()
            _ = try await upsert(doc)
        }
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.restore.rawValue,
            payload: ["wasTrashed": .bool(wasTrashed)]
        )
        return doc
    }

    public func favorite(_ docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        let wasFavorite = doc.isFavorite
        if !wasFavorite {
            doc.isFavorite = true
            doc.updatedAt = Date()
            _ = try await upsert(doc)
        }
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.favorite.rawValue,
            payload: ["wasAlreadyFavorite": .bool(wasFavorite)]
        )
        return doc
    }

    public func unfavorite(_ docID: UUID) async throws -> Doc {
        var doc = try await loadOrFail(id: docID)
        let wasFavorite = doc.isFavorite
        if wasFavorite {
            doc.isFavorite = false
            doc.updatedAt = Date()
            _ = try await upsert(doc)
        }
        try await appendReceipt(
            entityID: docID,
            receiptType: DocReceiptType.unfavorite.rawValue,
            payload: ["wasFavorite": .bool(wasFavorite)]
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
        _ = try await upsert(doc)
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
        _ = try await upsert(doc)
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
        _ = try await upsert(doc)
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
}

// MARK: - DocStoreError

public enum DocStoreError: Error, Sendable, Equatable {
    case docNotFound(id: UUID)
    case invalidBody(reason: String)
}
