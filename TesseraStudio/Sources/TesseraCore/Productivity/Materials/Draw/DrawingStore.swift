import Foundation

// MARK: - DrawingStore

/// The Draw material's seam to ``TesseraDataLayer``. Owns the
/// `Drawing` <-> data layer integration, enforces the constitutional-
/// receipt invariant for every mutation, exposes a domain-shaped API
/// to the rest of the productivity surface.
///
/// Mirrors ``DocStore``/``SlideStore``: the store is a struct because
/// the data layer actor is the source of concurrency safety. No
/// mutable state of our own.
///
/// **Receipt contract:** every mutation appends a signed receipt to
/// `graph_receipts` with a `receipt_type` from ``DrawingReceiptType``.
public struct DrawingStore: Sendable {

    private let dataLayer: TesseraDataLayer

    public init(dataLayer: TesseraDataLayer) {
        self.dataLayer = dataLayer
    }

    // MARK: - CRUD

    @discardableResult
    public func upsert(_ drawing: Drawing) async throws -> Drawing {
        var stored = drawing
        stored.updatedAt = Date()
        let body = try stored.jsonDataString()
        let label = stored.displayTitle
        _ = try await dataLayer.upsertEntity(
            GraphEntityUpsert(
                id: stored.id,
                entityType: Drawing.entityType,
                subtype: Drawing.subtype,
                label: label,
                body: body,
                sourceURL: nil,
                embedding: nil
            )
        )
        try await appendReceipt(
            entityID: stored.id,
            receiptType: DrawingReceiptType.upsert.rawValue,
            payload: [
                "title": .string(label),
                "tagCount": .number(Double(stored.tags.count)),
                "isFavorite": .bool(stored.isFavorite),
                "isArchived": .bool(stored.isArchived),
                "isTrashed": .bool(stored.isTrashed),
                "linkedEntityCount": .number(Double(stored.linkedEntityIDs.count)),
                "shapeCount": .number(Double(stored.shapeCount)),
            ]
        )
        return stored
    }

    public func get(id: UUID) async throws -> Drawing? {
        guard let entity = try await dataLayer.getEntity(id: id) else { return nil }
        guard entity.entityType == Drawing.entityType, entity.subtype == Drawing.subtype else { return nil }
        return try Self.drawingFromEntity(entity)
    }

    @discardableResult
    public func delete(id: UUID) async throws -> Bool {
        let didDelete = try await dataLayer.deleteEntity(id: id)
        if didDelete {
            try await appendReceipt(entityID: id, receiptType: DrawingReceiptType.delete.rawValue, payload: [:])
        }
        return didDelete
    }

    // MARK: - Listing

    public func list(limit: Int = 1000) async throws -> [Drawing] {
        let rows = try await dataLayer.listByEntityType(entityType: Drawing.entityType, limit: limit)
        return try rows.compactMap { row in
            guard row.subtype == Drawing.subtype else { return nil }
            return try? Self.drawingFromEntity(row)
        }
    }

    public func listActive(limit: Int = 1000) async throws -> [Drawing] {
        let all = try await list(limit: limit)
        return all.filter { !$0.isArchived && !$0.isTrashed }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func search(matching query: String, limit: Int = 20) async throws -> [Drawing] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        let rows = try await dataLayer.searchByLabelPrefix(entityType: Drawing.entityType, labelPrefix: trimmed, limit: limit)
        return try rows.compactMap { row in
            guard row.subtype == Drawing.subtype else { return nil }
            return try? Self.drawingFromEntity(row)
        }
    }

    // MARK: - Archive / Trash / Favorite

    public func archive(_ drawingID: UUID) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        let was = drawing.isArchived
        if !was { drawing.isArchived = true; drawing.updatedAt = Date(); _ = try await upsert(drawing) }
        try await appendReceipt(entityID: drawingID, receiptType: DrawingReceiptType.archive.rawValue, payload: ["wasAlreadyArchived": .bool(was)])
        return drawing
    }

    public func unarchive(_ drawingID: UUID) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        let was = drawing.isArchived
        if was { drawing.isArchived = false; drawing.updatedAt = Date(); _ = try await upsert(drawing) }
        try await appendReceipt(entityID: drawingID, receiptType: DrawingReceiptType.unarchive.rawValue, payload: ["wasArchived": .bool(was)])
        return drawing
    }

    public func trash(_ drawingID: UUID) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        let was = drawing.isTrashed
        if !was { drawing.isTrashed = true; drawing.updatedAt = Date(); _ = try await upsert(drawing) }
        try await appendReceipt(entityID: drawingID, receiptType: DrawingReceiptType.trash.rawValue, payload: ["wasAlreadyTrashed": .bool(was)])
        return drawing
    }

    public func restore(_ drawingID: UUID) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        let was = drawing.isTrashed
        if was { drawing.isTrashed = false; drawing.updatedAt = Date(); _ = try await upsert(drawing) }
        try await appendReceipt(entityID: drawingID, receiptType: DrawingReceiptType.restore.rawValue, payload: ["wasTrashed": .bool(was)])
        return drawing
    }

    public func favorite(_ drawingID: UUID) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        let was = drawing.isFavorite
        if !was { drawing.isFavorite = true; drawing.updatedAt = Date(); _ = try await upsert(drawing) }
        try await appendReceipt(entityID: drawingID, receiptType: DrawingReceiptType.favorite.rawValue, payload: ["wasAlreadyFavorite": .bool(was)])
        return drawing
    }

    public func unfavorite(_ drawingID: UUID) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        let was = drawing.isFavorite
        if was { drawing.isFavorite = false; drawing.updatedAt = Date(); _ = try await upsert(drawing) }
        try await appendReceipt(entityID: drawingID, receiptType: DrawingReceiptType.unfavorite.rawValue, payload: ["wasFavorite": .bool(was)])
        return drawing
    }

    // MARK: - Tags

    public func setTags(_ tags: [String], for drawingID: UUID) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        let oldTags = drawing.tags
        let normalized = Drawing.normalizeTags(tags)
        drawing.tags = normalized
        drawing.updatedAt = Date()
        _ = try await upsert(drawing)
        let added = normalized.filter { !oldTags.contains($0) }
        let removed = oldTags.filter { !normalized.contains($0) }
        try await appendReceipt(
            entityID: drawingID,
            receiptType: DrawingReceiptType.tagChange.rawValue,
            payload: ["addedTags": .array(added.map { .string($0) }), "removedTags": .array(removed.map { .string($0) })]
        )
        return drawing
    }

    public func addTag(_ tag: String, to drawingID: UUID) async throws -> Drawing {
        let normalized = Drawing.normalizeTags([tag])
        guard let first = normalized.first else { return try await loadOrFail(id: drawingID) }
        var drawing = try await loadOrFail(id: drawingID)
        if drawing.tags.contains(first) {
            try await appendReceipt(entityID: drawingID, receiptType: DrawingReceiptType.tagAdded.rawValue, payload: ["tag": .string(first), "wasAlreadyPresent": .bool(true)])
            return drawing
        }
        drawing.tags.append(first)
        drawing.updatedAt = Date()
        _ = try await upsert(drawing)
        try await appendReceipt(entityID: drawingID, receiptType: DrawingReceiptType.tagAdded.rawValue, payload: ["tag": .string(first), "wasAlreadyPresent": .bool(false)])
        return drawing
    }

    public func removeTag(_ tag: String, from drawingID: UUID) async throws -> Drawing {
        let normalized = Drawing.normalizeTags([tag])
        guard let first = normalized.first else { return try await loadOrFail(id: drawingID) }
        var drawing = try await loadOrFail(id: drawingID)
        guard let index = drawing.tags.firstIndex(of: first) else {
            try await appendReceipt(entityID: drawingID, receiptType: DrawingReceiptType.tagRemoved.rawValue, payload: ["tag": .string(first), "wasPresent": .bool(false)])
            return drawing
        }
        drawing.tags.remove(at: index)
        drawing.updatedAt = Date()
        _ = try await upsert(drawing)
        try await appendReceipt(entityID: drawingID, receiptType: DrawingReceiptType.tagRemoved.rawValue, payload: ["tag": .string(first), "wasPresent": .bool(true)])
        return drawing
    }

    // MARK: - Linking

    @discardableResult
    public func link(
        drawingID: UUID,
        to otherEntityID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0
    ) async throws -> EntityLink {
        let link = try await dataLayer.linkEntities(sourceID: drawingID, targetID: otherEntityID, linkType: linkType, weight: weight)
        if var drawing = try await get(id: drawingID), !drawing.linkedEntityIDs.contains(otherEntityID) {
            drawing.linkedEntityIDs.append(otherEntityID)
            drawing.updatedAt = Date()
            _ = try await upsert(drawing)
        }
        try await appendReceipt(
            entityID: drawingID,
            receiptType: DrawingReceiptType.link.rawValue,
            payload: ["targetEntityID": .string(otherEntityID.uuidString), "linkType": .string(linkType), "weight": .number(Double(weight))]
        )
        return link
    }

    public func unlink(drawingID: UUID, from otherEntityID: UUID, linkType: String = "related_to") async throws {
        if var drawing = try await get(id: drawingID), let idx = drawing.linkedEntityIDs.firstIndex(of: otherEntityID) {
            drawing.linkedEntityIDs.remove(at: idx)
            drawing.updatedAt = Date()
            _ = try await upsert(drawing)
        }
        try await appendReceipt(
            entityID: drawingID,
            receiptType: DrawingReceiptType.unlink.rawValue,
            payload: ["targetEntityID": .string(otherEntityID.uuidString), "linkType": .string(linkType)]
        )
    }

    // MARK: - Shape mutations

    @discardableResult
    public func insertShape(_ shape: Shape, for drawingID: UUID) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        drawing = drawing.insertingShape(shape)
        drawing.updatedAt = Date()
        _ = try await upsert(drawing)
        try await appendReceipt(
            entityID: drawingID,
            receiptType: DrawingReceiptType.insertShape.rawValue,
            payload: ["shapeID": .string(shape.id.uuidString), "kind": .string(shape.kind.rawValue)]
        )
        return drawing
    }

    @discardableResult
    public func deleteShape(_ shapeID: UUID, for drawingID: UUID) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        guard drawing.shape(id: shapeID) != nil else {
            throw DrawingStoreError.shapeNotFound(id: shapeID)
        }
        drawing = drawing.deletingShape(shapeID)
        drawing.updatedAt = Date()
        _ = try await upsert(drawing)
        try await appendReceipt(entityID: drawingID, receiptType: DrawingReceiptType.deleteShape.rawValue, payload: ["shapeID": .string(shapeID.uuidString)])
        return drawing
    }

    @discardableResult
    public func setGeometry(_ geometry: ShapeGeometry, forShape shapeID: UUID, in drawingID: UUID) async throws -> Drawing {
        try await mutatingShape(shapeID, in: drawingID, receiptType: .setGeometry) { $0.geometry = geometry }
    }

    @discardableResult
    public func setFill(_ fill: ShapeFill?, forShape shapeID: UUID, in drawingID: UUID) async throws -> Drawing {
        try await mutatingShape(shapeID, in: drawingID, receiptType: .setFill) { $0.fill = fill }
    }

    @discardableResult
    public func setStroke(_ stroke: ShapeStroke?, forShape shapeID: UUID, in drawingID: UUID) async throws -> Drawing {
        try await mutatingShape(shapeID, in: drawingID, receiptType: .setStroke) { $0.stroke = stroke }
    }

    @discardableResult
    public func setText(_ text: ShapeText?, forShape shapeID: UUID, in drawingID: UUID) async throws -> Drawing {
        try await mutatingShape(shapeID, in: drawingID, receiptType: .setText) { $0.text = text }
    }

    /// Sets the geometry of every shape named in `geometries` in a
    /// SINGLE upsert + SINGLE receipt (P2-0 item 3: "one physical drag
    /// = one receipt = one undo unit" - a multi-shape or group drag
    /// commits through this method instead of N calls to
    /// ``setGeometry(_:forShape:in:)``, matching the receipts law's
    /// "no receipt without a mutation" in the other direction too: N
    /// shapes moving together is one mutation of the drawing, not N).
    /// Reuses the SAME `DrawingReceiptType.setGeometry` case
    /// `setGeometry` emits - a batched commit is still fundamentally
    /// "shape geometry changed", so this does not need its own
    /// receipt-type case (AGENTS.md: "reuse existing infrastructure").
    /// A shape id with a geometry identical to its current stored
    /// value is skipped (not counted toward "did anything change");
    /// an unknown shape id throws ``DrawingStoreError/shapeNotFound(id:)``
    /// without persisting anything (error path, matching every other
    /// shape mutator in this store). An empty `geometries`, or a
    /// `geometries` whose every entry is already identical to the
    /// stored value, is a no-op: zero receipts, zero persistence.
    @discardableResult
    public func setGeometries(_ geometries: [UUID: ShapeGeometry], for drawingID: UUID) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        var changedIDs: [UUID] = []
        for (shapeID, geometry) in geometries {
            guard var shape = drawing.shape(id: shapeID) else {
                throw DrawingStoreError.shapeNotFound(id: shapeID)
            }
            guard shape.geometry != geometry else { continue }
            shape.geometry = geometry
            drawing = drawing.updatingShape(shape)
            changedIDs.append(shapeID)
        }
        guard !changedIDs.isEmpty else { return drawing }
        drawing.updatedAt = Date()
        _ = try await upsert(drawing)
        try await appendReceipt(
            entityID: drawingID,
            receiptType: DrawingReceiptType.setGeometry.rawValue,
            payload: [
                "shapeIDs": .array(changedIDs.map { .string($0.uuidString) }),
                "shapeCount": .number(Double(changedIDs.count)),
            ]
        )
        return drawing
    }

    /// Sets (or clears, via `nil`) a shape's extrusion (item 2.17).
    /// Unlike `setGeometry`/`setFill`/`setStroke`/`setText` above, this
    /// does NOT go through `mutatingShape` - that helper has no
    /// no-op guard (a pre-existing gap testing-doctrine.md itself names
    /// as "the DrawingStore no-op-receipt defect" lesson), and the
    /// receipts law is binding for every new store method. An identical
    /// `extrusion` value (including nil == nil) is a no-op: zero
    /// receipts, zero persistence.
    @discardableResult
    public func setExtrusion(_ extrusion: ShapeExtrusion?, forShape shapeID: UUID, in drawingID: UUID) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        guard var shape = drawing.shape(id: shapeID) else {
            throw DrawingStoreError.shapeNotFound(id: shapeID)
        }
        guard shape.extrusion != extrusion else { return drawing }
        shape.extrusion = extrusion
        drawing = drawing.updatingShape(shape)
        drawing.updatedAt = Date()
        _ = try await upsert(drawing)
        try await appendReceipt(
            entityID: drawingID,
            receiptType: DrawingReceiptType.setExtrusion.rawValue,
            payload: [
                "shapeID": .string(shapeID.uuidString),
                "depth": extrusion.map { .number($0.depth) } ?? .null,
                "bevelDepth": extrusion.map { .number($0.bevelDepth) } ?? .null,
                "metalness": extrusion.map { .number($0.metalness) } ?? .null,
                "roughness": extrusion.map { .number($0.roughness) } ?? .null,
            ]
        )
        return drawing
    }

    /// Sets a `.bezier` shape's custom path (item 2.3). Same no-op-
    /// guard shape as `setExtrusion` above, for the same reason - an
    /// identical `path` value is a no-op: zero receipts, zero
    /// persistence. Called once per completed
    /// `BezierPathController` operation, never per intermediate drag
    /// frame (see `BezierPathController.swift`'s own header).
    @discardableResult
    public func setPath(_ path: ShapePath, forShape shapeID: UUID, in drawingID: UUID) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        guard var shape = drawing.shape(id: shapeID) else {
            throw DrawingStoreError.shapeNotFound(id: shapeID)
        }
        guard shape.path != path else { return drawing }
        shape.path = path
        drawing = drawing.updatingShape(shape)
        drawing.updatedAt = Date()
        _ = try await upsert(drawing)
        try await appendReceipt(
            entityID: drawingID,
            receiptType: DrawingReceiptType.setPath.rawValue,
            payload: [
                "shapeID": .string(shapeID.uuidString),
                "subpathCount": .number(Double(path.subpaths.count)),
                "segmentCount": .number(Double(path.subpaths.reduce(0) { $0 + $1.segments.count })),
            ]
        )
        return drawing
    }

    @discardableResult
    public func setZOrder(_ move: ShapeZOrder.Move, forShape shapeID: UUID, in drawingID: UUID) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        guard drawing.shape(id: shapeID) != nil else {
            throw DrawingStoreError.shapeNotFound(id: shapeID)
        }
        drawing = drawing.applyingZOrder(move, toShape: shapeID)
        drawing.updatedAt = Date()
        _ = try await upsert(drawing)
        try await appendReceipt(entityID: drawingID, receiptType: DrawingReceiptType.setZOrder.rawValue, payload: ["shapeID": .string(shapeID.uuidString)])
        return drawing
    }

    /// Shared plumbing for the single-field shape setters above: load,
    /// find the shape (throwing if it's gone), apply `mutate`,
    /// persist, receipt.
    private func mutatingShape(
        _ shapeID: UUID,
        in drawingID: UUID,
        receiptType: DrawingReceiptType,
        mutate: (inout Shape) -> Void
    ) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        guard var shape = drawing.shape(id: shapeID) else {
            throw DrawingStoreError.shapeNotFound(id: shapeID)
        }
        mutate(&shape)
        drawing = drawing.updatingShape(shape)
        drawing.updatedAt = Date()
        _ = try await upsert(drawing)
        try await appendReceipt(entityID: drawingID, receiptType: receiptType.rawValue, payload: ["shapeID": .string(shapeID.uuidString)])
        return drawing
    }

    // MARK: - Layer mutations

    @discardableResult
    public func addLayer(_ layer: DrawLayer, to drawingID: UUID) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        drawing = drawing.addingLayer(layer)
        drawing.updatedAt = Date()
        _ = try await upsert(drawing)
        try await appendReceipt(
            entityID: drawingID,
            receiptType: DrawingReceiptType.layerAdded.rawValue,
            payload: ["layerID": .string(layer.id.uuidString), "name": .string(layer.name)]
        )
        return drawing
    }

    @discardableResult
    public func removeLayer(_ layerID: UUID, from drawingID: UUID) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        let before = drawing.layers
        drawing = drawing.removingLayer(layerID)
        guard drawing.layers != before else { return drawing }
        drawing.updatedAt = Date()
        _ = try await upsert(drawing)
        try await appendReceipt(entityID: drawingID, receiptType: DrawingReceiptType.layerDeleted.rawValue, payload: ["layerID": .string(layerID.uuidString)])
        return drawing
    }

    @discardableResult
    public func renameLayer(_ layerID: UUID, to newName: String, in drawingID: UUID) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        let before = drawing.layers
        drawing = drawing.renamingLayer(layerID, to: newName)
        guard drawing.layers != before else { return drawing }
        drawing.updatedAt = Date()
        _ = try await upsert(drawing)
        try await appendReceipt(
            entityID: drawingID,
            receiptType: DrawingReceiptType.layerRenamed.rawValue,
            payload: ["layerID": .string(layerID.uuidString), "name": .string(newName)]
        )
        return drawing
    }

    @discardableResult
    public func reorderLayers(_ newOrder: [UUID], in drawingID: UUID) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        let before = drawing.layers
        drawing = drawing.reorderingLayers(newOrder)
        guard drawing.layers != before else { return drawing }
        drawing.updatedAt = Date()
        _ = try await upsert(drawing)
        try await appendReceipt(
            entityID: drawingID,
            receiptType: DrawingReceiptType.layerReordered.rawValue,
            payload: ["order": .array(newOrder.map { .string($0.uuidString) })]
        )
        return drawing
    }

    @discardableResult
    public func setLayerVisibility(_ layerID: UUID, isVisible: Bool, in drawingID: UUID) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        let before = drawing.layers
        drawing = drawing.settingLayerVisibility(layerID, isVisible: isVisible)
        guard drawing.layers != before else { return drawing }
        drawing.updatedAt = Date()
        _ = try await upsert(drawing)
        try await appendReceipt(
            entityID: drawingID,
            receiptType: DrawingReceiptType.layerVisibilityChanged.rawValue,
            payload: ["layerID": .string(layerID.uuidString), "isVisible": .bool(isVisible)]
        )
        return drawing
    }

    @discardableResult
    public func setLayerLock(_ layerID: UUID, isLocked: Bool, in drawingID: UUID) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        let before = drawing.layers
        drawing = drawing.settingLayerLock(layerID, isLocked: isLocked)
        guard drawing.layers != before else { return drawing }
        drawing.updatedAt = Date()
        _ = try await upsert(drawing)
        try await appendReceipt(
            entityID: drawingID,
            receiptType: DrawingReceiptType.layerLockChanged.rawValue,
            payload: ["layerID": .string(layerID.uuidString), "isLocked": .bool(isLocked)]
        )
        return drawing
    }

    @discardableResult
    public func setConnector(_ info: ConnectorInfo?, forShape shapeID: UUID, in drawingID: UUID) async throws -> Drawing {
        try await mutatingShape(shapeID, in: drawingID, receiptType: .setConnector) { $0.connector = info }
    }

    // MARK: - Group / ungroup (row 48, P2-0)

    /// Groups `shapeIDs` under a freshly-created group id, assigned to
    /// every named shape's `parentGroupID` (``Shape/parentGroupID``).
    /// Fewer than 2 shape ids (after de-duplicating and dropping any
    /// id that does not name a shape in this drawing) is a no-op:
    /// zero receipts, zero persistence - a "group" of 0 or 1 shape is
    /// not a grouping. The group itself has no separate stored
    /// geometry or block at P0 (`Drawing.swift`'s `.shapeGroup` doc
    /// comment: "Carries no geometry of its own at P0 - group bounds
    /// are derived from members, not stored") - `parentGroupID`
    /// membership IS the group.
    ///
    /// Delegates to ``applyingGroup(_:to:)``, kept `internal` (not
    /// `private`) so it is directly testable without a live
    /// `TesseraDataLayer` - mirrors why `SlideStore.applyingLayout` is
    /// `internal` for the same reason (see that method's doc comment).
    @discardableResult
    public func group(_ shapeIDs: [UUID], for drawingID: UUID) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        guard let (grouped, groupID, memberIDs) = Self.applyingGroup(shapeIDs, to: drawing) else {
            return drawing
        }
        drawing = grouped
        drawing.updatedAt = Date()
        _ = try await upsert(drawing)
        try await appendReceipt(
            entityID: drawingID,
            receiptType: DrawingReceiptType.groupShapes.rawValue,
            payload: [
                "groupID": .string(groupID.uuidString),
                "shapeIDs": .array(memberIDs.map { .string($0.uuidString) }),
            ]
        )
        return drawing
    }

    /// Dissolves a shape group: every shape whose `parentGroupID ==
    /// groupID` has it cleared back to `nil`. `groupID` names nothing
    /// but a value shared shapes' `parentGroupID` happens to carry (no
    /// separate group entity is stored, per ``group(_:for:)``'s doc
    /// comment), so "unknown groupID" is exactly "no shape currently
    /// carries this parentGroupID" - a no-op: zero receipts, zero
    /// persistence.
    @discardableResult
    public func ungroup(_ groupID: UUID, for drawingID: UUID) async throws -> Drawing {
        var drawing = try await loadOrFail(id: drawingID)
        guard let (ungrouped, memberIDs) = Self.applyingUngroup(groupID, to: drawing) else {
            return drawing
        }
        drawing = ungrouped
        drawing.updatedAt = Date()
        _ = try await upsert(drawing)
        try await appendReceipt(
            entityID: drawingID,
            receiptType: DrawingReceiptType.ungroupShapes.rawValue,
            payload: [
                "groupID": .string(groupID.uuidString),
                "shapeIDs": .array(memberIDs.map { .string($0.uuidString) }),
            ]
        )
        return drawing
    }

    // MARK: - Group / ungroup application (pure, P2-0)

    /// The pure group transform: de-duplicates `shapeIDs`, drops any
    /// id that does not name a shape in `drawing`, and - only when at
    /// least 2 valid ids remain - assigns all of them a freshly
    /// generated shared group id. Returns `nil` for the no-op case
    /// (fewer than 2 valid ids) so the caller's guard reads as "no
    /// grouping happened" without a separate boolean. `shapeIDs` order
    /// is not preserved in the returned member list (deduplicated via
    /// `Set`) - grouping does not have a play/z-order contract of its
    /// own to preserve.
    static func applyingGroup(
        _ shapeIDs: [UUID], to drawing: Drawing
    ) -> (drawing: Drawing, groupID: UUID, memberIDs: [UUID])? {
        let existingIDs = Array(Set(shapeIDs)).filter { drawing.shape(id: $0) != nil }
        guard existingIDs.count >= 2 else { return nil }
        let groupID = UUID()
        var updated = drawing
        for id in existingIDs {
            guard var shape = updated.shape(id: id) else { continue }
            shape.parentGroupID = groupID
            updated = updated.updatingShape(shape)
        }
        return (updated, groupID, existingIDs)
    }

    /// The pure ungroup transform: clears `parentGroupID` on every
    /// shape currently carrying `groupID`. Returns `nil` (the no-op
    /// case) when no shape carries it.
    static func applyingUngroup(
        _ groupID: UUID, to drawing: Drawing
    ) -> (drawing: Drawing, memberIDs: [UUID])? {
        let members = drawing.shapes.filter { $0.parentGroupID == groupID }
        guard !members.isEmpty else { return nil }
        var updated = drawing
        for var shape in members {
            shape.parentGroupID = nil
            updated = updated.updatingShape(shape)
        }
        return (updated, members.map(\.id))
    }

    // MARK: - Receipts

    public func receipts(forDrawing drawingID: UUID) async throws -> [GraphReceipt] {
        try await dataLayer.receipts(forEntity: drawingID)
    }

    // MARK: - Helpers

    private func appendReceipt(entityID: UUID, receiptType: String, payload: [String: JSONValue]) async throws {
        _ = try await dataLayer.appendReceipt(entityID: entityID, receiptType: receiptType, payload: payload)
    }

    private func loadOrFail(id: UUID) async throws -> Drawing {
        guard let drawing = try await get(id: id) else {
            throw DrawingStoreError.drawingNotFound(id: id)
        }
        return drawing
    }

    private static func drawingFromEntity(_ entity: GraphEntity) throws -> Drawing? {
        guard entity.entityType == Drawing.entityType, entity.subtype == Drawing.subtype else { return nil }
        guard let body = entity.body, !body.isEmpty else { return nil }
        return try Drawing.from(jsonDataString: body)
    }
}

// MARK: - DrawingStoreError

public enum DrawingStoreError: Error, Sendable, Equatable {
    case drawingNotFound(id: UUID)
    case shapeNotFound(id: UUID)
    case invalidBody(reason: String)
}
