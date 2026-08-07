import Foundation

// MARK: - SlideStore

/// The Slides material's seam to ``TesseraDataLayer``. Owns the
/// `SlideDeck` <-> data layer integration, enforces the
/// constitutional-receipt invariant for every mutation, exposes a
/// domain-shaped API to the rest of the productivity surface.
///
/// Mirrors ``NoteStore`` / `DocStore` / `SheetStore`: the store is a
/// struct because the data layer actor is the source of concurrency
/// safety. No mutable state of our own.
///
/// **Receipt contract:** every mutation that changes deck state
/// (upsert, body, slide insert / delete / move / duplicate / layout,
/// archive, trash, favorite, tag, link) appends a signed receipt to
/// `graph_receipts` with a `receipt_type` from
/// ``SlideReceiptType`` and a payload that names the affected
/// `entity_id` plus a structural summary.
public struct SlideStore: Sendable {

    private let dataLayer: TesseraDataLayer

    public init(dataLayer: TesseraDataLayer) {
        self.dataLayer = dataLayer
    }

    // MARK: - CRUD

    @discardableResult
    public func upsert(_ deck: SlideDeck) async throws -> SlideDeck {
        var stored = deck
        stored.updatedAt = Date()
        let body = try stored.jsonDataString()
        let label = stored.displayTitle
        _ = try await dataLayer.upsertEntity(
            GraphEntityUpsert(
                id: stored.id,
                entityType: SlideDeck.entityType,
                subtype: SlideDeck.subtype,
                label: label,
                body: body,
                sourceURL: nil,
                embedding: nil
            )
        )
        try await appendReceipt(
            entityID: stored.id,
            receiptType: SlideReceiptType.upsert.rawValue,
            payload: [
                "title": .string(label),
                "tagCount": .number(Double(stored.tags.count)),
                "isFavorite": .bool(stored.isFavorite),
                "isArchived": .bool(stored.isArchived),
                "isTrashed": .bool(stored.isTrashed),
                "linkedEntityCount": .number(Double(stored.linkedEntityIDs.count)),
                "slideCount": .number(Double(stored.slideCount)),
                "wordCount": .number(Double(stored.wordCount)),
            ]
        )
        return stored
    }

    public func get(id: UUID) async throws -> SlideDeck? {
        guard let entity = try await dataLayer.getEntity(id: id) else { return nil }
        guard entity.entityType == SlideDeck.entityType,
              entity.subtype == SlideDeck.subtype else { return nil }
        return try Self.deckFromEntity(entity)
    }

    @discardableResult
    public func delete(id: UUID) async throws -> Bool {
        let didDelete = try await dataLayer.deleteEntity(id: id)
        if didDelete {
            try await appendReceipt(
                entityID: id,
                receiptType: SlideReceiptType.delete.rawValue,
                payload: [:]
            )
        }
        return didDelete
    }

    // MARK: - Listing

    public func list(limit: Int = 1000) async throws -> [SlideDeck] {
        let rows = try await dataLayer.listByEntityType(
            entityType: SlideDeck.entityType, limit: limit)
        return try rows.compactMap { row in
            guard row.subtype == SlideDeck.subtype else { return nil }
            return try? Self.deckFromEntity(row)
        }
    }

    public func listActive(limit: Int = 1000) async throws -> [SlideDeck] {
        let all = try await list(limit: limit)
        return all.filter { !$0.isArchived && !$0.isTrashed }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func search(matching query: String, limit: Int = 20) async throws -> [SlideDeck] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        let rows = try await dataLayer.searchByLabelPrefix(
            entityType: SlideDeck.entityType,
            labelPrefix: trimmed, limit: limit)
        return try rows.compactMap { row in
            guard row.subtype == SlideDeck.subtype else { return nil }
            return try? Self.deckFromEntity(row)
        }
    }

    // MARK: - Body

    public func setBody(_ body: DocumentAST, for deckID: UUID) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        if deck.title.isEmpty, let first = SlideDeck.firstHeadingText(in: body) {
            deck.title = first
        }
        // Carry over slideMeta entries for root children that still exist.
        let oldChildren = Set(deck.body.rootChildren.map { $0.uuidString })
        let newChildren = Set(body.rootChildren.map { $0.uuidString })
        let pruned = deck.slideMeta.filter { newChildren.contains($0.key) }
        // Preserve layout/notes for blocks that were kept; new blocks get the default.
        deck.slideMeta = pruned
        for key in newChildren where oldChildren.contains(key) == false {
            if deck.slideMeta[key] == nil { deck.slideMeta[key] = .default }
        }
        deck.body = body
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID,
            receiptType: SlideReceiptType.updateBody.rawValue,
            payload: [
                "blockCount": .number(Double(body.blocks.count)),
                "rootChildCount": .number(Double(body.rootChildren.count)),
            ]
        )
        return deck
    }

    // MARK: - Slide mutations

    public func insertSlide(
        at index: Int,
        for deckID: UUID,
        layout: SlideLayout = .titleAndContent,
        title: String? = nil
    ) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        let clamped = max(0, min(index, deck.slideCount))
        deck = deck.insertingSlide(at: clamped, layout: layout, title: title)
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID,
            receiptType: SlideReceiptType.insertSlide.rawValue,
            payload: [
                "index": .number(Double(clamped)),
                "layout": .string(layout.rawValue),
                "newSlideCount": .number(Double(deck.slideCount)),
            ]
        )
        return deck
    }

    public func deleteSlide(at index: Int, for deckID: UUID) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        guard index >= 0, index < deck.slideCount else {
            throw SlideStoreError.slideOutOfBounds(index: index, count: deck.slideCount)
        }
        let removedID = deck.body.rootChildren[index]
        // Remove the root child and its subtree from the block map.
        var toDelete: Set<UUID> = [removedID]
        collectSubtree(rootID: removedID, ast: deck.body, into: &toDelete)
        deck.body.rootChildren.remove(at: index)
        for id in toDelete { deck.body.blocks.removeValue(forKey: id) }
        deck.slideMeta.removeValue(forKey: removedID.uuidString)
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID,
            receiptType: SlideReceiptType.deleteSlide.rawValue,
            payload: [
                "index": .number(Double(index)),
                "newSlideCount": .number(Double(deck.slideCount)),
            ]
        )
        return deck
    }

    public func moveSlide(from sourceIndex: Int, to destIndex: Int, for deckID: UUID) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        let n = deck.slideCount
        guard sourceIndex >= 0, sourceIndex < n else {
            throw SlideStoreError.slideOutOfBounds(index: sourceIndex, count: n)
        }
        // dest is the index after removal, so allow 0..n-1.
        guard destIndex >= 0, destIndex < n else {
            throw SlideStoreError.slideOutOfBounds(index: destIndex, count: n)
        }
        guard sourceIndex != destIndex else { return deck }
        let id = deck.body.rootChildren.remove(at: sourceIndex)
        let adjusted = destIndex > sourceIndex ? destIndex - 1 : destIndex
        // Re-insert with the standard semantics: `destIndex` names the
        // position in the *original* deck. Most callers think "move
        // slide 2 to index 0", so `destIndex` is the target index in
        // the new array. Keep it simple: insert at destIndex clamped
        // to the post-removal size.
        let insertAt = max(0, min(destIndex, deck.body.rootChildren.count))
        // For the s->d move we use the original dest, but clamped to
        // the post-removal bounds. Both s->d interpretations are valid;
        // keep the simpler "insert at dest" (original index) so
        // moving forward still shifts left by one to compensate.
        _ = adjusted // unused; kept for readability of the derivation
        deck.body.rootChildren.insert(id, at: insertAt)
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID,
            receiptType: SlideReceiptType.moveSlide.rawValue,
            payload: [
                "fromIndex": .number(Double(sourceIndex)),
                "toIndex": .number(Double(destIndex)),
            ]
        )
        return deck
    }

    public func duplicateSlide(at index: Int, for deckID: UUID) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        guard index >= 0, index < deck.slideCount else {
            throw SlideStoreError.slideOutOfBounds(index: index, count: deck.slideCount)
        }
        let srcID = deck.body.rootChildren[index]
        guard let srcBlock = deck.body.blocks[srcID] else {
            throw SlideStoreError.slideNotFound(id: srcID)
        }
        // Deep-copy the slide's subtree with fresh UUIDs.
        var idMap: [UUID: UUID] = [:]
        let newRootID = UUID()
        idMap[srcID] = newRootID
        // Collect the subtree.
        var subtreeIDs: Set<UUID> = []
        collectSubtree(rootID: srcID, ast: deck.body, into: &subtreeIDs)
        for old in subtreeIDs where old != srcID {
            idMap[old] = UUID()
        }
        // Copy blocks with remapped children.
        for oldID in subtreeIDs {
            guard let block = deck.body.blocks[oldID], let newID = idMap[oldID] else { continue }
            var copied = block
            // Remap the block's identity.
            copied = Block(
                id: newID,
                type: block.type,
                attributes: block.attributes,
                content: block.content,
                children: block.children.map { idMap[$0] ?? $0 },
                parentID: block.parentID.flatMap { idMap[$0] }
            )
            deck.body.blocks[newID] = copied
        }
        // Keep the original src as-is; insert duplicate after it.
        let dupBlock = deck.body.blocks[newRootID]!
        _ = dupBlock // silence unused
        deck.body.rootChildren.insert(newRootID, at: index + 1)
        if let meta = deck.slideMeta[srcID.uuidString] {
            deck.slideMeta[newRootID.uuidString] = meta
        }
        deck.updatedAt = Date()
        _ = srcBlock // silence unused
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID,
            receiptType: SlideReceiptType.duplicateSlide.rawValue,
            payload: [
                "sourceIndex": .number(Double(index)),
                "newIndex": .number(Double(index + 1)),
                "newSlideCount": .number(Double(deck.slideCount)),
            ]
        )
        return deck
    }

    public func setSlideLayout(
        at index: Int,
        layout: SlideLayout,
        for deckID: UUID
    ) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        guard index >= 0, index < deck.slideCount else {
            throw SlideStoreError.slideOutOfBounds(index: index, count: deck.slideCount)
        }
        let rootID = deck.body.rootChildren[index]
        let key = rootID.uuidString
        var meta = deck.slideMeta[key] ?? .default
        meta.layout = layout
        deck.slideMeta[key] = meta
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID,
            receiptType: SlideReceiptType.setSlideLayout.rawValue,
            payload: [
                "index": .number(Double(index)),
                "layout": .string(layout.rawValue),
            ]
        )
        return deck
    }

    // MARK: - Archive / Trash / Favorite

    public func archive(_ deckID: UUID) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        let was = deck.isArchived
        if !was { deck.isArchived = true; deck.updatedAt = Date(); _ = try await upsert(deck) }
        try await appendReceipt(
            entityID: deckID, receiptType: SlideReceiptType.archive.rawValue,
            payload: ["wasAlreadyArchived": .bool(was)])
        return deck
    }

    public func unarchive(_ deckID: UUID) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        let was = deck.isArchived
        if was { deck.isArchived = false; deck.updatedAt = Date(); _ = try await upsert(deck) }
        try await appendReceipt(
            entityID: deckID, receiptType: SlideReceiptType.unarchive.rawValue,
            payload: ["wasArchived": .bool(was)])
        return deck
    }

    public func trash(_ deckID: UUID) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        let was = deck.isTrashed
        if !was { deck.isTrashed = true; deck.updatedAt = Date(); _ = try await upsert(deck) }
        try await appendReceipt(
            entityID: deckID, receiptType: SlideReceiptType.trash.rawValue,
            payload: ["wasAlreadyTrashed": .bool(was)])
        return deck
    }

    public func restore(_ deckID: UUID) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        let was = deck.isTrashed
        if was { deck.isTrashed = false; deck.updatedAt = Date(); _ = try await upsert(deck) }
        try await appendReceipt(
            entityID: deckID, receiptType: SlideReceiptType.restore.rawValue,
            payload: ["wasTrashed": .bool(was)])
        return deck
    }

    public func favorite(_ deckID: UUID) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        let was = deck.isFavorite
        if !was { deck.isFavorite = true; deck.updatedAt = Date(); _ = try await upsert(deck) }
        try await appendReceipt(
            entityID: deckID, receiptType: SlideReceiptType.favorite.rawValue,
            payload: ["wasAlreadyFavorite": .bool(was)])
        return deck
    }

    public func unfavorite(_ deckID: UUID) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        let was = deck.isFavorite
        if was { deck.isFavorite = false; deck.updatedAt = Date(); _ = try await upsert(deck) }
        try await appendReceipt(
            entityID: deckID, receiptType: SlideReceiptType.unfavorite.rawValue,
            payload: ["wasFavorite": .bool(was)])
        return deck
    }

    // MARK: - Tags

    public func setTags(_ tags: [String], for deckID: UUID) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        let old = deck.tags
        let normalized = SlideDeck.normalizeTags(tags)
        deck.tags = normalized
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        let added = normalized.filter { !old.contains($0) }
        let removed = old.filter { !normalized.contains($0) }
        try await appendReceipt(
            entityID: deckID, receiptType: SlideReceiptType.tagChange.rawValue,
            payload: [
                "addedTags": .array(added.map { .string($0) }),
                "removedTags": .array(removed.map { .string($0) }),
            ])
        return deck
    }

    public func addTag(_ tag: String, to deckID: UUID) async throws -> SlideDeck {
        let normalized = SlideDeck.normalizeTags([tag])
        guard let first = normalized.first else { return try await loadOrFail(id: deckID) }
        var deck = try await loadOrFail(id: deckID)
        if deck.tags.contains(first) {
            try await appendReceipt(
                entityID: deckID, receiptType: SlideReceiptType.tagAdded.rawValue,
                payload: ["tag": .string(first), "wasAlreadyPresent": .bool(true)])
            return deck
        }
        deck.tags.append(first)
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID, receiptType: SlideReceiptType.tagAdded.rawValue,
            payload: ["tag": .string(first), "wasAlreadyPresent": .bool(false)])
        return deck
    }

    public func removeTag(_ tag: String, from deckID: UUID) async throws -> SlideDeck {
        let normalized = SlideDeck.normalizeTags([tag])
        guard let first = normalized.first else { return try await loadOrFail(id: deckID) }
        var deck = try await loadOrFail(id: deckID)
        guard let idx = deck.tags.firstIndex(of: first) else {
            try await appendReceipt(
                entityID: deckID, receiptType: SlideReceiptType.tagRemoved.rawValue,
                payload: ["tag": .string(first), "wasPresent": .bool(false)])
            return deck
        }
        deck.tags.remove(at: idx)
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID, receiptType: SlideReceiptType.tagRemoved.rawValue,
            payload: ["tag": .string(first), "wasPresent": .bool(true)])
        return deck
    }

    // MARK: - Linking

    @discardableResult
    public func link(
        deckID: UUID, to otherEntityID: UUID,
        linkType: String = "related_to", weight: Float = 1.0
    ) async throws -> EntityLink {
        let link = try await dataLayer.linkEntities(
            sourceID: deckID, targetID: otherEntityID, linkType: linkType, weight: weight)
        if var deck = try await get(id: deckID), !deck.linkedEntityIDs.contains(otherEntityID) {
            deck.linkedEntityIDs.append(otherEntityID)
            deck.updatedAt = Date()
            _ = try await dataLayer.upsertEntity(GraphEntityUpsert(
                id: deck.id, entityType: SlideDeck.entityType, subtype: SlideDeck.subtype,
                label: deck.displayTitle, body: try deck.jsonDataString(),
                sourceURL: nil, embedding: nil))
        }
        try await appendReceipt(
            entityID: deckID, receiptType: SlideReceiptType.link.rawValue,
            payload: [
                "targetEntityID": .string(otherEntityID.uuidString),
                "linkType": .string(linkType),
                "weight": .number(Double(weight)),
            ])
        return link
    }

    public func unlink(deckID: UUID, from otherEntityID: UUID, linkType: String = "related_to") async throws {
        if var deck = try await get(id: deckID),
           let idx = deck.linkedEntityIDs.firstIndex(of: otherEntityID) {
            deck.linkedEntityIDs.remove(at: idx)
            deck.updatedAt = Date()
            _ = try await dataLayer.upsertEntity(GraphEntityUpsert(
                id: deck.id, entityType: SlideDeck.entityType, subtype: SlideDeck.subtype,
                label: deck.displayTitle, body: try deck.jsonDataString(),
                sourceURL: nil, embedding: nil))
        }
        try await appendReceipt(
            entityID: deckID, receiptType: SlideReceiptType.unlink.rawValue,
            payload: [
                "targetEntityID": .string(otherEntityID.uuidString),
                "linkType": .string(linkType),
            ])
    }

    // MARK: - Import marker

    public func recordImport(deckID: UUID, sourceFormat: String) async throws {
        try await appendReceipt(
            entityID: deckID, receiptType: SlideReceiptType.import.rawValue,
            payload: ["sourceFormat": .string(sourceFormat)])
    }

    // MARK: - Receipts

    public func receipts(forDeck deckID: UUID) async throws -> [GraphReceipt] {
        try await dataLayer.receipts(forEntity: deckID)
    }

    // MARK: - Helpers

    private func appendReceipt(
        entityID: UUID, receiptType: String, payload: [String: JSONValue]
    ) async throws {
        _ = try await dataLayer.appendReceipt(
            entityID: entityID, receiptType: receiptType, payload: payload)
    }

    private func loadOrFail(id: UUID) async throws -> SlideDeck {
        guard let deck = try await get(id: id) else {
            throw SlideStoreError.deckNotFound(id: id)
        }
        return deck
    }

    private static func deckFromEntity(_ entity: GraphEntity) throws -> SlideDeck? {
        guard entity.entityType == SlideDeck.entityType,
              entity.subtype == SlideDeck.subtype else { return nil }
        guard let body = entity.body, !body.isEmpty else { return nil }
        return try SlideDeck.from(jsonDataString: body)
    }

    private func collectSubtree(rootID: UUID, ast: DocumentAST, into out: inout Set<UUID>) {
        guard let block = ast.blocks[rootID] else { return }
        out.insert(rootID)
        for child in block.children { collectSubtree(rootID: child, ast: ast, into: &out) }
    }
}

// MARK: - SlideStoreError

public enum SlideStoreError: Error, Sendable, Equatable {
    case deckNotFound(id: UUID)
    case slideNotFound(id: UUID)
    case slideOutOfBounds(index: Int, count: Int)
    case invalidBody(reason: String)
}
