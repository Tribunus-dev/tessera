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
        // Fire-and-forget material receipt: failure does not block the upsert.
        Task {
            try? await dataLayer.appendMaterialReceipt(
                entityID: stored.id,
                receiptType: SlideReceiptPayload.receiptType,
                payload: [
                    "entityID": .string(stored.id.uuidString),
                    "action": .string("create"),
                    "deckID": .string(stored.id.uuidString),
                ]
            )
        }
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
            // Fire-and-forget material receipt: failure does not block the deletion.
            Task {
                try? await dataLayer.appendMaterialReceipt(
                    entityID: id,
                    receiptType: SlideReceiptPayload.receiptType,
                    payload: [
                        "entityID": .string(id.uuidString),
                        "action": .string("delete"),
                        "deckID": .string(id.uuidString),
                    ]
                )
            }
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

    /// Applies one of `SlideLayout`'s 4 compact cases. Delegates to the
    /// ``SlideLayoutSpec``-based overload via ``SlideLayoutSpec/default(for:)``
    /// so both paths share the same idx-then-type block-matching logic
    /// (P1 1.9) - kept as its own overload because `SlidesViewModel`
    /// and the agent tools surface still pass the compact enum, not a
    /// full spec.
    public func setSlideLayout(
        at index: Int,
        layout: SlideLayout,
        for deckID: UUID
    ) async throws -> SlideDeck {
        try await setSlideLayout(at: index, spec: SlideLayoutSpec.default(for: layout), for: deckID)
    }

    /// Applies an arbitrary catalog entry (P1 1.9: any of
    /// ``SlideLayoutSpec/builtins``, not just the 4 `SlideLayout`
    /// cases) - the mutation `MasterPageLayoutPicker` calls. Rearranges
    /// the slide's blocks to the spec's placeholder shape via
    /// ``applyingLayout(_:atSlideIndex:to:)`` (idx-then-type matching,
    /// PowerPoint orphan rule - see that function), then reuses the
    /// SAME `SlideReceiptType.setSlideLayout` receipt as the compact-enum
    /// overload: one receipt for the whole operation, however many
    /// blocks it touches.
    ///
    /// When `spec.id` names one of the 4 `SlideLayout` cases,
    /// `SlideMeta.layout` is updated to match (preserves existing
    /// chrome/rendering behavior for those 4). For a catalog-only spec
    /// with no `SlideLayout` equivalent, `SlideMeta.layout` is left as
    /// whatever it already was - `SlideMeta` has no field yet for an
    /// arbitrary spec id; the block arrangement itself is the source of
    /// truth for those until a future item adds one.
    @discardableResult
    public func setSlideLayout(
        at index: Int,
        spec: SlideLayoutSpec,
        for deckID: UUID
    ) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        guard index >= 0, index < deck.slideCount else {
            throw SlideStoreError.slideOutOfBounds(index: index, count: deck.slideCount)
        }
        deck = Self.applyingLayout(spec, atSlideIndex: index, to: deck)
        if let matchedLayout = SlideLayout.allCases.first(where: { $0.rawValue == spec.id }) {
            let key = deck.body.rootChildren[index].uuidString
            var meta = deck.slideMeta[key] ?? .default
            meta.layout = matchedLayout
            deck.slideMeta[key] = meta
        }
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID,
            receiptType: SlideReceiptType.setSlideLayout.rawValue,
            payload: [
                "index": .number(Double(index)),
                "layout": .string(spec.id),
            ]
        )
        return deck
    }

    // MARK: - Animations (P2-0, prerequisite for P2's SMILAnimationTree)

    /// Replaces the slide's flat animation effect list wholesale
    /// (mirrors `setTags`'s "set the whole list" shape rather than a
    /// single-effect append, since `AnimationEffectList` has no id per
    /// entry to append/replace against - see ``removeAnimationEffect
    /// (at:forSlideAt:for:)`` for why removal is index-addressed for
    /// the same reason). Identical-value set (comparing against
    /// ``SlideMeta/effectiveAnimations``, so setting `[]` when the
    /// slide already has no animations is ALSO a no-op, not just an
    /// exact-array match against a possibly-nil stored value) is a
    /// no-op: zero receipts, zero persistence (receipts law).
    @discardableResult
    public func setAnimations(
        _ effects: AnimationEffectList, forSlideAt index: Int, for deckID: UUID
    ) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        guard index >= 0, index < deck.slideCount else {
            throw SlideStoreError.slideOutOfBounds(index: index, count: deck.slideCount)
        }
        let key = deck.body.rootChildren[index].uuidString
        var meta = deck.slideMeta[key] ?? .default
        guard meta.effectiveAnimations != effects else { return deck }
        meta.animations = effects
        deck.slideMeta[key] = meta
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID,
            receiptType: SlideReceiptType.setAnimationEffects.rawValue,
            payload: [
                "index": .number(Double(index)),
                "effectCount": .number(Double(effects.count)),
            ]
        )
        return deck
    }

    /// Removes one effect from a slide's animation list, addressed by
    /// its position in play order. `AnimationEffect` carries no `id`
    /// field (`AnimationEffectList.swift`'s field list is exactly
    /// `targetBlockID`/`presetID`/`trigger`/`durationMS`/`delayMS` -
    /// verified against the type before choosing this signature), and
    /// `targetBlockID` cannot stand in for one either (a block can
    /// legitimately carry more than one effect, e.g. a fly-in entrance
    /// plus a fade exit) - so play-order index is the only stable
    /// address this P1 type supports. An out-of-range `effectIndex`
    /// (including on a slide with no animations at all) is a no-op:
    /// zero receipts, zero persistence.
    @discardableResult
    public func removeAnimationEffect(
        at effectIndex: Int, forSlideAt index: Int, for deckID: UUID
    ) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        guard index >= 0, index < deck.slideCount else {
            throw SlideStoreError.slideOutOfBounds(index: index, count: deck.slideCount)
        }
        let key = deck.body.rootChildren[index].uuidString
        var meta = deck.slideMeta[key] ?? .default
        guard effectIndex >= 0, effectIndex < meta.effectiveAnimations.count else { return deck }
        meta.animations?.remove(at: effectIndex)
        deck.slideMeta[key] = meta
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID,
            receiptType: SlideReceiptType.removeAnimationEffect.rawValue,
            payload: [
                "index": .number(Double(index)),
                "effectIndex": .number(Double(effectIndex)),
            ]
        )
        return deck
    }

    // MARK: - Media (P1 1.4 write path, wired P2-0)

    /// Attaches a `MediaBlock` to a slide as a new `.media` block,
    /// parented under the slide's own root block (the same "add a
    /// child to the slide's subtree" shape `insertingSlide`'s
    /// `.titleAndContent` case uses to attach a heading + paragraph
    /// under a toggle wrapper) - `collectBlocks`'s recursive walk
    /// already includes any child regardless of the parent's
    /// `BlockType`, so the media block is included in the slide's
    /// sliced AST (`enumeratedSlides()`) without further changes.
    /// Always mutates (a freshly-generated `.media` block id is never
    /// already present), so there is no "identical value" no-op case
    /// here - mirrors `DrawingStore.addLayer`'s own note that a fresh
    /// id has no "unknown id" to reject either.
    @discardableResult
    public func attachMedia(
        _ media: MediaBlock, toSlideAt index: Int, for deckID: UUID
    ) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        guard index >= 0, index < deck.slideCount else {
            throw SlideStoreError.slideOutOfBounds(index: index, count: deck.slideCount)
        }
        let rootID = deck.body.rootChildren[index]
        guard var rootBlock = deck.body.blocks[rootID] else {
            throw SlideStoreError.slideNotFound(id: rootID)
        }
        let mediaBlockID = UUID()
        var mediaBlock = Block(id: mediaBlockID, type: .media, parentID: rootID)
        mediaBlock.media = media
        deck.body.blocks[mediaBlockID] = mediaBlock
        rootBlock.children.append(mediaBlockID)
        deck.body.blocks[rootID] = rootBlock
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID,
            receiptType: SlideReceiptType.attachMedia.rawValue,
            payload: [
                "index": .number(Double(index)),
                "mediaBlockID": .string(mediaBlockID.uuidString),
                "kind": .string(media.kind.rawValue),
            ]
        )
        return deck
    }

    /// Removes a `.media` block (and its reference from its parent's
    /// `children`) from the deck, addressed by the media block's own
    /// id (returned by ``attachMedia(_:toSlideAt:for:)``). Unknown id,
    /// or an id that names a block that isn't a `.media` block, is a
    /// no-op: zero receipts, zero persistence (guard-and-early-return
    /// before persist+receipt, the `DocStore.archive` canonical shape).
    @discardableResult
    public func removeMedia(_ mediaBlockID: UUID, for deckID: UUID) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        guard let mediaBlock = deck.body.blocks[mediaBlockID], mediaBlock.type == .media else {
            return deck
        }
        if let parentID = mediaBlock.parentID, var parent = deck.body.blocks[parentID] {
            parent.children.removeAll { $0 == mediaBlockID }
            deck.body.blocks[parentID] = parent
        }
        deck.body.blocks.removeValue(forKey: mediaBlockID)
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID,
            receiptType: SlideReceiptType.removeMedia.rawValue,
            payload: ["mediaBlockID": .string(mediaBlockID.uuidString)]
        )
        return deck
    }

    // MARK: - Comment lifecycle (P2-0: reply/resolve/delete, same shape
    // as the Calc track's SheetStore equivalent - both use the shared
    // CommentThread.addingReply(_:)/.resolved() + Slide/SheetDeck's own
    // replacingCommentThread(_:)/removingCommentThread(id:) helpers
    // pre-landed in Comments.swift.)

    /// Appends a reply message to an existing comment thread. Unknown
    /// `threadID` is a no-op: zero receipts, zero persistence.
    @discardableResult
    public func replyToComment(
        _ threadID: UUID, author: String, text: String, for deckID: UUID
    ) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        guard let thread = deck.effectiveCommentThreads.first(where: { $0.id == threadID }) else {
            return deck
        }
        let message = CommentMessage(author: author, text: text)
        deck = deck.replacingCommentThread(thread.addingReply(message))
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID,
            receiptType: SlideReceiptType.commentReplied.rawValue,
            payload: [
                "commentID": .string(threadID.uuidString),
                "messageID": .string(message.id.uuidString),
            ]
        )
        return deck
    }

    /// Marks a comment thread resolved. Unknown `threadID`, or a
    /// thread that is already resolved, is a no-op: zero receipts,
    /// zero persistence (re-resolving an already-resolved thread is
    /// not a mutation - `isResolved` would not change).
    @discardableResult
    public func resolveComment(_ threadID: UUID, for deckID: UUID) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        guard let thread = deck.effectiveCommentThreads.first(where: { $0.id == threadID }),
              !thread.isResolved else {
            return deck
        }
        deck = deck.replacingCommentThread(thread.resolved())
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID,
            receiptType: SlideReceiptType.commentResolved.rawValue,
            payload: ["commentID": .string(threadID.uuidString)]
        )
        return deck
    }

    /// Deletes a comment thread entirely. Unknown `threadID` is a
    /// no-op: zero receipts, zero persistence.
    @discardableResult
    public func deleteComment(_ threadID: UUID, for deckID: UUID) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        guard deck.effectiveCommentThreads.contains(where: { $0.id == threadID }) else {
            return deck
        }
        deck = deck.removingCommentThread(id: threadID)
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID,
            receiptType: SlideReceiptType.commentDeleted.rawValue,
            payload: ["commentID": .string(threadID.uuidString)]
        )
        return deck
    }

    // MARK: - Layout application (pure, P1 1.9)

    /// The apply-layout block rearrangement (refinement doc section 4,
    /// Slides cluster, item 1.9): matches the slide's existing blocks
    /// to `spec`'s placeholders first by recorded `attributes
    /// ["placeholderIdx"]`, then by `blockType`, in that order.
    /// Placeholders with no match get a freshly created empty block.
    /// Existing blocks matching NOTHING are NEVER deleted (PowerPoint
    /// orphan rule) - they survive as unassigned children (their
    /// `placeholderIdx` cleared). Re-running with the same `spec`
    /// reproduces the identical assignment: every matched block already
    /// carries the idx it will match on again.
    ///
    /// A pure `SlideDeck -> SlideDeck` transform, no `dataLayer` - kept
    /// `internal` (not `private`) so it's directly testable without a
    /// live `TesseraDataLayer`, mirroring why `MasterPageStoreTests`
    /// tests its own mutation logic at the pure-model level instead of
    /// through the store's async API.
    static func applyingLayout(_ spec: SlideLayoutSpec, atSlideIndex index: Int, to deck: SlideDeck) -> SlideDeck {
        var copy = deck
        guard index >= 0, index < copy.body.rootChildren.count else { return copy }
        let oldRootID = copy.body.rootChildren[index]
        guard let oldRoot = copy.body.blocks[oldRootID] else { return copy }

        // Existing content blocks: the root's own children when it's a
        // pure wrapper (the `.titleAndContent` convention - a toggle
        // whose children ARE the placeholders), else the root itself.
        let rootIsWrapper = !oldRoot.children.isEmpty
        let existingBlocks: [Block] = rootIsWrapper
            ? oldRoot.children.compactMap { copy.body.blocks[$0] }
            : [oldRoot]

        // Target slots: every `SlideLayoutSpec.builtins` entry has
        // exactly one top-level placeholder (see that type's header
        // comment) - its children when it wraps any, else itself.
        let topPlaceholder = spec.placeholders.first
        let targetSlots: [SlideLayoutPlaceholder] = topPlaceholder.map { $0.children.isEmpty ? [$0] : $0.children } ?? []

        // Pass 1: idx match. `idx` is scoped to its OWN spec (not
        // globally unique across the catalog - see `SlideLayoutPlaceholder
        // .idx`'s doc comment), so a recorded idx is only trusted when
        // the target slot at that idx is ALSO the same blockType -
        // otherwise a block carrying idx 1 from a spec where idx 1 was
        // `.paragraph` could wrongly bind to a DIFFERENT spec's idx-1
        // slot that happens to be `.table`. A type mismatch here falls
        // through to pass 2 instead.
        var claimedSlots = Set<Int>()
        var claimedBlocks = Set<UUID>()
        var assignment: [Int: Block] = [:]
        for block in existingBlocks {
            guard let recorded = block.attributes["placeholderIdx"]?.numberValue.map({ Int($0) }) else { continue }
            guard let slotPos = targetSlots.firstIndex(where: { $0.idx == recorded && $0.blockType == block.type }),
                  !claimedSlots.contains(slotPos) else { continue }
            assignment[slotPos] = block
            claimedSlots.insert(slotPos)
            claimedBlocks.insert(block.id)
        }
        // Pass 2: type match, for whatever pass 1 left unclaimed.
        for block in existingBlocks where !claimedBlocks.contains(block.id) {
            guard let slotPos = targetSlots.indices.first(where: { !claimedSlots.contains($0) && targetSlots[$0].blockType == block.type }) else { continue }
            assignment[slotPos] = block
            claimedSlots.insert(slotPos)
            claimedBlocks.insert(block.id)
        }

        // Fill every slot - matched block, or a fresh empty one - and
        // (re)tag it with the slot's idx so the NEXT apply idx-matches.
        var filled: [Block] = []
        for (slotPos, targetSlot) in targetSlots.enumerated() {
            var block = assignment[slotPos] ?? emptyBlock(for: targetSlot)
            if let idx = targetSlot.idx { block.attributes["placeholderIdx"] = .number(Double(idx)) }
            filled.append(block)
        }
        // Orphans: existing blocks the new layout matched nothing for.
        // Kept, unassigned (placeholderIdx cleared) - never deleted.
        let orphans: [Block] = existingBlocks
            .filter { !claimedBlocks.contains($0.id) }
            .map { block in
                var b = block
                b.attributes.removeValue(forKey: "placeholderIdx")
                return b
            }

        let newChildren = filled + orphans
        let newRootID: UUID
        if newChildren.count == 1, var only = newChildren.first {
            only.parentID = nil
            copy.body.blocks[only.id] = only
            newRootID = only.id
            if rootIsWrapper && oldRootID != only.id {
                copy.body.blocks.removeValue(forKey: oldRootID)
            }
        } else {
            let wrapperID = rootIsWrapper ? oldRootID : UUID()
            var childIDs: [UUID] = []
            for var child in newChildren {
                child.parentID = wrapperID
                copy.body.blocks[child.id] = child
                childIDs.append(child.id)
            }
            let wrapperAttributes = rootIsWrapper ? oldRoot.attributes : ["expanded": .bool(true)]
            copy.body.blocks[wrapperID] = Block(id: wrapperID, type: .toggle, attributes: wrapperAttributes, children: childIDs)
            newRootID = wrapperID
        }

        copy.body.rootChildren[index] = newRootID
        if newRootID != oldRootID, let meta = copy.slideMeta.removeValue(forKey: oldRootID.uuidString) {
            copy.slideMeta[newRootID.uuidString] = meta
        }
        return copy
    }

    /// A fresh, empty block for a placeholder with nothing matched to
    /// it - the same minimal-attribute convention `SlideDeck
    /// .insertingSlide` uses per `blockType`.
    private static func emptyBlock(for placeholder: SlideLayoutPlaceholder) -> Block {
        var attributes: [String: AnyCodable] = [:]
        switch placeholder.blockType {
        case .heading: attributes["level"] = .number(1)
        case .image: attributes["source"] = .string(""); attributes["alt"] = .string(placeholder.name ?? "")
        case .table: attributes["rows"] = .number(1); attributes["cols"] = .number(1)
        case .list: attributes["style"] = .string("unordered")
        default: break
        }
        return Block(type: placeholder.blockType, attributes: attributes)
    }

    // MARK: - Comments

    /// Attaches a new comment thread to the deck (P1 1.22 gap closure -
    /// `CommentThread`/`CommentAnchor` already existed; this is the
    /// write path that actually creates one). The thread carries a
    /// single `CommentMessage` built from `author`/`text` - the same
    /// single-message-thread shape `SheetStore`'s own comment-adding
    /// method would build for a `.cell` anchor.
    ///
    /// A `.slide` anchor is validated against `deck.body.rootChildren`
    /// before the thread is created: unlike a Sheet's arbitrary cell
    /// coordinate, a slide id is a closed, checkable set, so an anchor
    /// pointing at a slide that doesn't exist is rejected rather than
    /// silently persisted. Every other anchor kind (`.textRange`,
    /// `.block`, `.cell`) is accepted unchecked, matching how `Sheet`
    /// comments are anchored.
    public func addComment(
        anchor: CommentAnchor, author: String, text: String, for deckID: UUID
    ) async throws -> SlideDeck {
        var deck = try await loadOrFail(id: deckID)
        if case let .slide(slideID) = anchor, !deck.body.rootChildren.contains(slideID) {
            throw SlideStoreError.slideNotFound(id: slideID)
        }
        let message = CommentMessage(author: author, text: text)
        let thread = CommentThread(
            id: UUID(), anchor: anchor, author: author, createdAt: Date(), messages: [message]
        )
        deck = deck.addingCommentThread(thread)
        deck.updatedAt = Date()
        _ = try await upsert(deck)
        try await appendReceipt(
            entityID: deckID,
            receiptType: SlideReceiptType.addComment.rawValue,
            payload: [
                "commentID": .string(thread.id.uuidString),
                "anchor": .string(Self.describeAnchor(anchor)),
            ]
        )
        return deck
    }

    /// A short, human-readable description of an anchor for receipt
    /// payloads - not round-trippable, just enough to identify what a
    /// comment was attached to when reading `graph_receipts` directly.
    private static func describeAnchor(_ anchor: CommentAnchor) -> String {
        switch anchor {
        case let .textRange(blockID, start, end):
            return "textRange(block: \(blockID.uuidString), \(start)..<\(end))"
        case let .block(blockID):
            return "block(\(blockID.uuidString))"
        case let .cell(sheetID, row, col):
            return "cell(sheet: \(sheetID.uuidString), row: \(row), col: \(col))"
        case let .slide(slideID):
            return "slide(\(slideID.uuidString))"
        }
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

    // MARK: - Hybrid search (subtype-filtered)

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
        return results.filter { $0.entityType == SlideDeck.entityType && $0.subtype == SlideDeck.subtype }
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
