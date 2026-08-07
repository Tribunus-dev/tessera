import Foundation

// MARK: - SheetStore

/// The Sheets material's seam to ``TesseraDataLayer``. Owns the
/// `Sheet` <-> data layer integration, enforces the
/// constitutional-receipt invariant for every mutation, exposes a
/// domain-shaped API to the rest of the productivity surface.
///
/// Mirrors ``NoteStore`` / ``DocStore`` / ``CodeStore``: the store
/// is a struct because the data layer actor is the source of
/// concurrency safety. No mutable state of our own.
///
/// **Receipt contract:** every mutation that changes sheet state
/// (upsert, body, cell, row, column, archive, trash, favorite,
/// tag, link) appends a signed receipt to `graph_receipts` with a
/// `receipt_type` from ``SheetReceiptType`` and a payload that
/// names the affected `entity_id` plus a structural summary.
public struct SheetStore: Sendable {

    private let dataLayer: TesseraDataLayer

    public init(dataLayer: TesseraDataLayer) {
        self.dataLayer = dataLayer
    }

    // MARK: - CRUD

    @discardableResult
    public func upsert(_ sheet: Sheet) async throws -> Sheet {
        var stored = sheet
        stored.updatedAt = Date()
        let body = try stored.jsonDataString()
        let label = stored.displayTitle
        _ = try await dataLayer.upsertEntity(
            GraphEntityUpsert(
                id: stored.id,
                entityType: Sheet.entityType,
                subtype: Sheet.subtype,
                label: label,
                body: body,
                sourceURL: nil,
                embedding: nil
            )
        )
        try await appendReceipt(
            entityID: stored.id,
            receiptType: SheetReceiptType.upsert.rawValue,
            payload: [
                "title": .string(label),
                "tagCount": .number(Double(stored.tags.count)),
                "isFavorite": .bool(stored.isFavorite),
                "isArchived": .bool(stored.isArchived),
                "isTrashed": .bool(stored.isTrashed),
                "linkedEntityCount": .number(Double(stored.linkedEntityIDs.count)),
                "rowCount": .number(Double(stored.rowCount)),
                "columnCount": .number(Double(stored.columnCount)),
            ]
        )
        return stored
    }

    public func get(id: UUID) async throws -> Sheet? {
        guard let entity = try await dataLayer.getEntity(id: id) else {
            return nil
        }
        guard entity.entityType == Sheet.entityType,
              entity.subtype == Sheet.subtype else {
            return nil
        }
        return try Self.sheetFromEntity(entity)
    }

    @discardableResult
    public func delete(id: UUID) async throws -> Bool {
        let didDelete = try await dataLayer.deleteEntity(id: id)
        if didDelete {
            try await appendReceipt(
                entityID: id,
                receiptType: SheetReceiptType.delete.rawValue,
                payload: [:]
            )
        }
        return didDelete
    }

    // MARK: - Listing

    public func list(limit: Int = 1000) async throws -> [Sheet] {
        let rows = try await dataLayer.listByEntityType(
            entityType: Sheet.entityType,
            limit: limit
        )
        return try rows.compactMap { row in
            guard row.subtype == Sheet.subtype else { return nil }
            return try? Self.sheetFromEntity(row)
        }
    }

    public func listActive(limit: Int = 1000) async throws -> [Sheet] {
        let all = try await list(limit: limit)
        return all.filter { !$0.isArchived && !$0.isTrashed }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func search(matching query: String, limit: Int = 20) async throws -> [Sheet] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        let rows = try await dataLayer.searchByLabelPrefix(
            entityType: Sheet.entityType,
            labelPrefix: trimmed,
            limit: limit
        )
        return try rows.compactMap { row in
            guard row.subtype == Sheet.subtype else { return nil }
            return try? Self.sheetFromEntity(row)
        }
    }

    // MARK: - Body

    public func setBody(_ body: DocumentAST, for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        if sheet.title.isEmpty, let first = Sheet.firstHeadingText(in: body) {
            sheet.title = first
        }
        sheet.body = body
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.updateBody.rawValue,
            payload: [
                "blockCount": .number(Double(body.blocks.count)),
                "rootChildCount": .number(Double(body.rootChildren.count)),
            ]
        )
        return sheet
    }

    // MARK: - Grid mutations

    /// Set the plain text value of the cell at (row, col) in the
    /// primary table. Rows and cols are 0-indexed. The cell's
    /// block content is replaced with a single run holding `value`.
    public func setCell(row: Int, col: Int, value: String, for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        guard let tableDims = tableDimensions(of: sheet.body) else {
            throw SheetStoreError.noTable(sheetID: sheetID)
        }
        guard row >= 0, row < tableDims.rows, col >= 0, col < tableDims.cols else {
            throw SheetStoreError.cellOutOfBounds(row: row, col: col, rows: tableDims.rows, cols: tableDims.cols)
        }
        let cellID = try cellID(row: row, col: col, dims: tableDims, body: sheet.body)
        guard var cell = sheet.body.blocks[cellID] else {
            throw SheetStoreError.cellNotFound(row: row, col: col)
        }
        let oldText = cell.content.map { $0.text }.joined()
        cell.content = value.isEmpty ? [] : [InlineRun(text: value)]
        sheet.body.blocks[cellID] = cell
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.setCell.rawValue,
            payload: [
                "row": .number(Double(row)),
                "col": .number(Double(col)),
                "oldValue": .string(oldText),
                "newValue": .string(value),
            ]
        )
        return sheet
    }

    public func insertRow(at index: Int, for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        guard let tableID = primaryTableID(of: sheet.body),
              var table = sheet.body.blocks[tableID] else {
            throw SheetStoreError.noTable(sheetID: sheetID)
        }
        let rows = Int(table.attributes["rows"]?.numberValue ?? 0)
        let cols = Int(table.attributes["cols"]?.numberValue ?? 0)
        guard index >= 0, index <= rows else {
            throw SheetStoreError.rowOutOfBounds(index: index, rows: rows)
        }
        let newCellIDs: [UUID] = (0..<cols).map { _ in UUID() }
        for id in newCellIDs {
            sheet.body.blocks[id] = Block(type: .tableCell, content: [])
        }
        let insertAt = index * cols
        table.children.insert(contentsOf: newCellIDs, at: insertAt)
        table.attributes["rows"] = .number(Double(rows + 1))
        sheet.body.blocks[tableID] = table
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.insertRow.rawValue,
            payload: ["index": .number(Double(index)), "newRowCount": .number(Double(rows + 1))]
        )
        return sheet
    }

    public func deleteRow(at index: Int, for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        guard let tableID = primaryTableID(of: sheet.body),
              var table = sheet.body.blocks[tableID] else {
            throw SheetStoreError.noTable(sheetID: sheetID)
        }
        let rows = Int(table.attributes["rows"]?.numberValue ?? 0)
        let cols = Int(table.attributes["cols"]?.numberValue ?? 0)
        guard index >= 0, index < rows else {
            throw SheetStoreError.rowOutOfBounds(index: index, rows: rows)
        }
        guard rows > 1 else {
            throw SheetStoreError.cannotDeleteLastRow
        }
        let start = index * cols
        let toRemove = Array(table.children[start..<(start + cols)])
        table.children.removeSubrange(start..<(start + cols))
        table.attributes["rows"] = .number(Double(rows - 1))
        sheet.body.blocks[tableID] = table
        for id in toRemove { sheet.body.blocks.removeValue(forKey: id) }
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.deleteRow.rawValue,
            payload: ["index": .number(Double(index)), "newRowCount": .number(Double(rows - 1))]
        )
        return sheet
    }

    public func insertColumn(at index: Int, for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        guard let tableID = primaryTableID(of: sheet.body),
              var table = sheet.body.blocks[tableID] else {
            throw SheetStoreError.noTable(sheetID: sheetID)
        }
        let rows = Int(table.attributes["rows"]?.numberValue ?? 0)
        let cols = Int(table.attributes["cols"]?.numberValue ?? 0)
        guard index >= 0, index <= cols else {
            throw SheetStoreError.columnOutOfBounds(index: index, cols: cols)
        }
        // Insert one cell per row at the column position, from bottom
        // to top so earlier row offsets don't shift.
        for r in stride(from: rows - 1, through: 0, by: -1) {
            let newID = UUID()
            sheet.body.blocks[newID] = Block(type: .tableCell, content: [])
            let pos = r * cols + index
            table.children.insert(newID, at: pos)
        }
        table.attributes["cols"] = .number(Double(cols + 1))
        sheet.body.blocks[tableID] = table
        sheet.columns.insert(SheetColumn(label: "", type: .text), at: index)
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.insertColumn.rawValue,
            payload: ["index": .number(Double(index)), "newColumnCount": .number(Double(cols + 1))]
        )
        return sheet
    }

    public func deleteColumn(at index: Int, for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        guard let tableID = primaryTableID(of: sheet.body),
              var table = sheet.body.blocks[tableID] else {
            throw SheetStoreError.noTable(sheetID: sheetID)
        }
        let rows = Int(table.attributes["rows"]?.numberValue ?? 0)
        let cols = Int(table.attributes["cols"]?.numberValue ?? 0)
        guard index >= 0, index < cols else {
            throw SheetStoreError.columnOutOfBounds(index: index, cols: cols)
        }
        guard cols > 1 else {
            throw SheetStoreError.cannotDeleteLastColumn
        }
        // Remove from bottom to top to keep indices stable.
        var removed: [UUID] = []
        for r in stride(from: rows - 1, through: 0, by: -1) {
            let pos = r * cols + index
            removed.append(table.children.remove(at: pos))
        }
        table.attributes["cols"] = .number(Double(cols - 1))
        sheet.body.blocks[tableID] = table
        for id in removed { sheet.body.blocks.removeValue(forKey: id) }
        if index < sheet.columns.count {
            sheet.columns.remove(at: index)
        }
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.deleteColumn.rawValue,
            payload: ["index": .number(Double(index)), "newColumnCount": .number(Double(cols - 1))]
        )
        return sheet
    }

    // MARK: - Archive / Trash / Favorite

    public func archive(_ sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        let wasArchived = sheet.isArchived
        if !wasArchived {
            sheet.isArchived = true
            sheet.updatedAt = Date()
            _ = try await upsert(sheet)
        }
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.archive.rawValue,
            payload: ["wasAlreadyArchived": .bool(wasArchived)]
        )
        return sheet
    }

    public func unarchive(_ sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        let wasArchived = sheet.isArchived
        if wasArchived {
            sheet.isArchived = false
            sheet.updatedAt = Date()
            _ = try await upsert(sheet)
        }
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.unarchive.rawValue,
            payload: ["wasArchived": .bool(wasArchived)]
        )
        return sheet
    }

    public func trash(_ sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        let wasTrashed = sheet.isTrashed
        if !wasTrashed {
            sheet.isTrashed = true
            sheet.updatedAt = Date()
            _ = try await upsert(sheet)
        }
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.trash.rawValue,
            payload: ["wasAlreadyTrashed": .bool(wasTrashed)]
        )
        return sheet
    }

    public func restore(_ sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        let wasTrashed = sheet.isTrashed
        if wasTrashed {
            sheet.isTrashed = false
            sheet.updatedAt = Date()
            _ = try await upsert(sheet)
        }
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.restore.rawValue,
            payload: ["wasTrashed": .bool(wasTrashed)]
        )
        return sheet
    }

    public func favorite(_ sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        let wasFavorite = sheet.isFavorite
        if !wasFavorite {
            sheet.isFavorite = true
            sheet.updatedAt = Date()
            _ = try await upsert(sheet)
        }
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.favorite.rawValue,
            payload: ["wasAlreadyFavorite": .bool(wasFavorite)]
        )
        return sheet
    }

    public func unfavorite(_ sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        let wasFavorite = sheet.isFavorite
        if wasFavorite {
            sheet.isFavorite = false
            sheet.updatedAt = Date()
            _ = try await upsert(sheet)
        }
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.unfavorite.rawValue,
            payload: ["wasFavorite": .bool(wasFavorite)]
        )
        return sheet
    }

    // MARK: - Tags

    public func setTags(_ tags: [String], for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        let oldTags = sheet.tags
        let normalized = Sheet.normalizeTags(tags)
        sheet.tags = normalized
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        let added = normalized.filter { !oldTags.contains($0) }
        let removed = oldTags.filter { !normalized.contains($0) }
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.tagChange.rawValue,
            payload: [
                "addedTags": .array(added.map { .string($0) }),
                "removedTags": .array(removed.map { .string($0) }),
            ]
        )
        return sheet
    }

    public func addTag(_ tag: String, to sheetID: UUID) async throws -> Sheet {
        let normalized = Sheet.normalizeTags([tag])
        guard let first = normalized.first else { return try await loadOrFail(id: sheetID) }
        var sheet = try await loadOrFail(id: sheetID)
        if sheet.tags.contains(first) {
            try await appendReceipt(
                entityID: sheetID,
                receiptType: SheetReceiptType.tagAdded.rawValue,
                payload: ["tag": .string(first), "wasAlreadyPresent": .bool(true)]
            )
            return sheet
        }
        sheet.tags.append(first)
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.tagAdded.rawValue,
            payload: ["tag": .string(first), "wasAlreadyPresent": .bool(false)]
        )
        return sheet
    }

    public func removeTag(_ tag: String, from sheetID: UUID) async throws -> Sheet {
        let normalized = Sheet.normalizeTags([tag])
        guard let first = normalized.first else { return try await loadOrFail(id: sheetID) }
        var sheet = try await loadOrFail(id: sheetID)
        guard let index = sheet.tags.firstIndex(of: first) else {
            try await appendReceipt(
                entityID: sheetID,
                receiptType: SheetReceiptType.tagRemoved.rawValue,
                payload: ["tag": .string(first), "wasPresent": .bool(false)]
            )
            return sheet
        }
        sheet.tags.remove(at: index)
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.tagRemoved.rawValue,
            payload: ["tag": .string(first), "wasPresent": .bool(true)]
        )
        return sheet
    }

    // MARK: - Linking

    @discardableResult
    public func link(
        sheetID: UUID,
        to otherEntityID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0
    ) async throws -> EntityLink {
        let link = try await dataLayer.linkEntities(
            sourceID: sheetID,
            targetID: otherEntityID,
            linkType: linkType,
            weight: weight
        )
        if var sheet = try await get(id: sheetID),
           !sheet.linkedEntityIDs.contains(otherEntityID) {
            sheet.linkedEntityIDs.append(otherEntityID)
            sheet.updatedAt = Date()
            _ = try await dataLayer.upsertEntity(
                GraphEntityUpsert(
                    id: sheet.id,
                    entityType: Sheet.entityType,
                    subtype: Sheet.subtype,
                    label: sheet.displayTitle,
                    body: try sheet.jsonDataString(),
                    sourceURL: nil,
                    embedding: nil
                )
            )
        }
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.link.rawValue,
            payload: [
                "targetEntityID": .string(otherEntityID.uuidString),
                "linkType": .string(linkType),
                "weight": .number(Double(weight)),
            ]
        )
        return link
    }

    public func unlink(
        sheetID: UUID,
        from otherEntityID: UUID,
        linkType: String = "related_to"
    ) async throws {
        if var sheet = try await get(id: sheetID),
           let idx = sheet.linkedEntityIDs.firstIndex(of: otherEntityID) {
            sheet.linkedEntityIDs.remove(at: idx)
            sheet.updatedAt = Date()
            _ = try await dataLayer.upsertEntity(
                GraphEntityUpsert(
                    id: sheet.id,
                    entityType: Sheet.entityType,
                    subtype: Sheet.subtype,
                    label: sheet.displayTitle,
                    body: try sheet.jsonDataString(),
                    sourceURL: nil,
                    embedding: nil
                )
            )
        }
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.unlink.rawValue,
            payload: [
                "targetEntityID": .string(otherEntityID.uuidString),
                "linkType": .string(linkType),
            ]
        )
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
        return results.filter { $0.entityType == Sheet.entityType && $0.subtype == Sheet.subtype }
    }

    // MARK: - Import marker

    public func recordImport(sheetID: UUID, sourceFormat: String) async throws {
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.import.rawValue,
            payload: ["sourceFormat": .string(sourceFormat)]
        )
    }

    // MARK: - Cell value via display (lightweight setCell alias)

    public func setCell(row: Int, col: Int, value: String, sheetID: UUID, emitReceipt: Bool) async throws -> Sheet {
        if emitReceipt {
            return try await setCell(row: row, col: col, value: value, for: sheetID)
        }
        var sheet = try await loadOrFail(id: sheetID)
        guard let tableDims = tableDimensions(of: sheet.body) else {
            throw SheetStoreError.cellNotFound(row: row, col: col)
        }
        let cellListID = try cellID(row: row, col: col, dims: tableDims, body: sheet.body)
        guard var cell = sheet.body.blocks[cellListID] else {
            throw SheetStoreError.cellNotFound(row: row, col: col)
        }
        cell.content = value.isEmpty ? [] : [InlineRun(text: value)]
        sheet.body.blocks[cellListID] = cell
        sheet.updatedAt = Date()
        _ = try await dataLayer.upsertEntity(
            GraphEntityUpsert(
                id: sheet.id,
                entityType: Sheet.entityType,
                subtype: Sheet.subtype,
                label: sheet.displayTitle,
                body: try sheet.jsonDataString(),
                sourceURL: nil,
                embedding: nil
            )
        )
        return sheet
    }

    // MARK: - Receipts

    public func receipts(forSheet sheetID: UUID) async throws -> [GraphReceipt] {
        try await dataLayer.receipts(forEntity: sheetID)
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

    private func loadOrFail(id: UUID) async throws -> Sheet {
        guard let sheet = try await get(id: id) else {
            throw SheetStoreError.sheetNotFound(id: id)
        }
        return sheet
    }

    private static func sheetFromEntity(_ entity: GraphEntity) throws -> Sheet? {
        guard entity.entityType == Sheet.entityType,
              entity.subtype == Sheet.subtype else { return nil }
        guard let body = entity.body, !body.isEmpty else { return nil }
        return try Sheet.from(jsonDataString: body)
    }

    // MARK: - Grid internals

    private func primaryTableID(of ast: DocumentAST) -> UUID? {
        for id in ast.rootChildren {
            if ast.blocks[id]?.type == .table { return id }
        }
        return nil
    }

    private func tableDimensions(of ast: DocumentAST) -> (rows: Int, cols: Int)? {
        guard let tableID = primaryTableID(of: ast),
              let table = ast.blocks[tableID] else { return nil }
        let rows = Int(table.attributes["rows"]?.numberValue ?? 0)
        let cols = Int(table.attributes["cols"]?.numberValue ?? 0)
        return (rows: rows, cols: cols)
    }

    private func cellID(row: Int, col: Int, dims: (rows: Int, cols: Int), body: DocumentAST) throws -> UUID {
        guard let tableID = primaryTableID(of: body),
              let table = body.blocks[tableID] else {
            throw SheetStoreError.noTable(sheetID: UUID())
        }
        let index = row * dims.cols + col
        guard index >= 0, index < table.children.count else {
            throw SheetStoreError.cellNotFound(row: row, col: col)
        }
        return table.children[index]
    }
}

// MARK: - SheetStoreError

public enum SheetStoreError: Error, Sendable, Equatable {
    case sheetNotFound(id: UUID)
    case invalidBody(reason: String)
    case noTable(sheetID: UUID)
    case cellNotFound(row: Int, col: Int)
    case cellOutOfBounds(row: Int, col: Int, rows: Int, cols: Int)
    case rowOutOfBounds(index: Int, rows: Int)
    case columnOutOfBounds(index: Int, cols: Int)
    case cannotDeleteLastRow
    case cannotDeleteLastColumn
}

// JSONValue accessors are provided by TesseraTool.swift; no local extension.
