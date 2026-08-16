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
        // Fire-and-forget material receipt: failure does not block the upsert.
        Task {
            try? await dataLayer.appendMaterialReceipt(
                entityID: stored.id,
                receiptType: SheetReceiptPayload.receiptType,
                payload: [
                    "entityID": .string(stored.id.uuidString),
                    "action": .string("create"),
                    "sheetID": .string(stored.id.uuidString),
                ]
            )
        }
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
            // Fire-and-forget material receipt: failure does not block the deletion.
            Task {
                try? await dataLayer.appendMaterialReceipt(
                    entityID: id,
                    receiptType: SheetReceiptPayload.receiptType,
                    payload: [
                        "entityID": .string(id.uuidString),
                        "action": .string("delete"),
                        "sheetID": .string(id.uuidString),
                    ]
                )
            }
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

    /// Refuse a mutation against a locked sheet. Every cell/format
    /// mutation path (the UI's two `commitEditingCell`s and the agent's
    /// `applyAgentEdit`) converges on `setCell`/`setCellFormat`, so this
    /// one call site is the real choke point despite there being three
    /// Swift call sites above it.
    private func guardUnlocked(_ sheet: Sheet) throws {
        let protection = sheet.effectiveProtection
        guard protection.isLocked else { return }
        throw SheetStoreError.sheetProtected(sheetID: sheet.id, reason: protection.reason)
    }

    /// Lock or unlock a sheet against further cell/format mutations.
    /// Setting protection itself is never blocked by protection - only
    /// cell/format edits are.
    public func setProtection(_ protection: SheetProtection?, for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        let previous = sheet.effectiveProtection
        sheet.protection = protection
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.setProtection.rawValue,
            payload: [
                "wasLocked": .bool(previous.isLocked),
                "isLocked": .bool(sheet.effectiveProtection.isLocked),
            ]
        )
        return sheet
    }

    /// Set the plain text value of the cell at (row, col) in the
    /// primary table. Rows and cols are 0-indexed. The cell's
    /// block content is replaced with a single run holding `value`.
    public func setCell(row: Int, col: Int, value: String, for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        try guardUnlocked(sheet)
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
        let columnType = col < sheet.columns.count ? sheet.columns[col].type : .text
        let classified = CellValue.classify(value, columnType: columnType)
        if classified.isEmpty {
            cell.attributes.removeValue(forKey: CellValue.attributeKey)
        } else {
            cell.attributes[CellValue.attributeKey] = classified.json
        }
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
        // Fire-and-forget material receipt: failure does not block the cell edit.
        Task {
            try? await dataLayer.appendMaterialReceipt(
                entityID: sheetID,
                receiptType: SheetReceiptPayload.receiptType,
                payload: [
                    "entityID": .string(sheetID.uuidString),
                    "action": .string("cellEdit"),
                    "sheetID": .string(sheetID.uuidString),
                    "cell": .string("\(row+1), \(col+1)"),
                    "oldValue": .string(oldText),
                    "newValue": .string(value),
                ]
            )
        }
        return sheet
    }

    /// Set the presentation of the cell at (row, col). Presentation
    /// only: the cell's text is not read or written here, so a restyle
    /// can never disturb a formula.
    public func setCellFormat(
        row: Int,
        col: Int,
        format: SheetCellFormat,
        for sheetID: UUID
    ) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        try guardUnlocked(sheet)
        guard let tableDims = tableDimensions(of: sheet.body) else {
            throw SheetStoreError.noTable(sheetID: sheetID)
        }
        guard row >= 0, row < tableDims.rows, col >= 0, col < tableDims.cols else {
            throw SheetStoreError.cellOutOfBounds(row: row, col: col, rows: tableDims.rows, cols: tableDims.cols)
        }
        let previous = sheet.cellFormat(row: row, col: col)
        sheet = sheet.settingCellFormat(row: row, col: col, format)
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.setCellFormat.rawValue,
            payload: [
                "row": .number(Double(row)),
                "col": .number(Double(col)),
                "oldFormat": previous.json,
                "newFormat": format.json,
            ]
        )
        return sheet
    }

    /// Define (or replace) a named range. `range` is stored relative to
    /// the sheet's own grid - `sheet` scoping (a name that only
    /// resolves against a specific sheet, as opposed to the whole
    /// workbook) is not exposed at the product layer yet, matching
    /// 0.1's "workbook-wide named ranges" framing; every persisted
    /// range is unscoped.
    public func defineNamedRange(
        _ name: String,
        topLeftRow: Int, topLeftCol: Int,
        bottomRightRow: Int, bottomRightCol: Int,
        for sheetID: UUID
    ) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        try guardUnlocked(sheet)
        guard let tableDims = tableDimensions(of: sheet.body) else {
            throw SheetStoreError.noTable(sheetID: sheetID)
        }
        guard topLeftRow >= 0, topLeftRow < tableDims.rows, topLeftCol >= 0, topLeftCol < tableDims.cols,
              bottomRightRow >= 0, bottomRightRow < tableDims.rows, bottomRightCol >= 0, bottomRightCol < tableDims.cols
        else {
            throw SheetStoreError.cellOutOfBounds(row: bottomRightRow, col: bottomRightCol, rows: tableDims.rows, cols: tableDims.cols)
        }
        let range = RangeRef(
            topLeft: CellAddr(col: min(topLeftCol, bottomRightCol), row: min(topLeftRow, bottomRightRow)),
            bottomRight: CellAddr(col: max(topLeftCol, bottomRightCol), row: max(topLeftRow, bottomRightRow))
        )
        let previous = sheet.effectiveNamedRanges[name.uppercased()]
        sheet = sheet.settingNamedRange(name, range: range)
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.defineNamedRange.rawValue,
            payload: [
                "name": .string(name),
                "range": .string(range.description),
                "replacedPrevious": .bool(previous != nil),
            ]
        )
        return sheet
    }

    /// Remove a named range. A no-op (still persisted, no receipt) if
    /// `name` isn't defined.
    public func undefineNamedRange(_ name: String, for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        try guardUnlocked(sheet)
        guard sheet.effectiveNamedRanges[name.uppercased()] != nil else { return sheet }
        sheet = sheet.removingNamedRange(name)
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.undefineNamedRange.rawValue,
            payload: ["name": .string(name)]
        )
        return sheet
    }

    /// Rewrite every formula for a structural edit. Runs AFTER the grid
    /// is restructured and BEFORE the save, so references follow the
    /// cells they point at. See ``Sheet/adjustingFormulas(for:)``.
    private func adjustFormulas(in sheet: Sheet, for edit: StructuralEdit) -> Sheet {
        sheet.adjustingFormulas(for: edit)
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
        sheet = adjustFormulas(in: sheet, for: .insertRows(at: index, count: 1))
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
        sheet = adjustFormulas(in: sheet, for: .deleteRows(at: index, count: 1))
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
        sheet = adjustFormulas(in: sheet, for: .insertColumns(at: index, count: 1))
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
        sheet = adjustFormulas(in: sheet, for: .deleteColumns(at: index, count: 1))
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.deleteColumn.rawValue,
            payload: ["index": .number(Double(index)), "newColumnCount": .number(Double(cols - 1))]
        )
        return sheet
    }

    // MARK: - Query (sort/filter)

    /// Sort the primary table's rows by `conditions` (see
    /// ``QueryEngine/sort(rowCount:conditions:cellValue:)``) and
    /// persist the new physical row order.
    ///
    /// `filterState.criteria` is left exactly as it was: a sort
    /// permutes which row holds what, it does not re-run or invalidate
    /// an autofilter (see `QueryEngine.sort`'s `(order:, outcome:)`
    /// return shape - there is no mutated `SheetFilterState` for a sort
    /// to hand back). `hiddenRows`, though, is remapped through the
    /// SAME permutation the grid itself gets below - "hidden rows are
    /// truth" (audit item A4): a row hidden before the sort must be the
    /// SAME logical row that is hidden after it, not whatever content
    /// happens to land at that physical index post-sort.
    public func sortRange(_ conditions: [SheetSortCondition], for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        try guardUnlocked(sheet)
        guard let tableID = primaryTableID(of: sheet.body),
              var table = sheet.body.blocks[tableID] else {
            throw SheetStoreError.noTable(sheetID: sheetID)
        }
        let rows = Int(table.attributes["rows"]?.numberValue ?? 0)
        let cols = Int(table.attributes["cols"]?.numberValue ?? 0)
        let (order, outcome) = QueryEngine.sort(
            rowCount: rows,
            conditions: conditions,
            cellValue: { row, col in sheet.cellValue(row: row, col: col) }
        )
        if cols > 0 {
            var reordered: [UUID] = []
            reordered.reserveCapacity(table.children.count)
            for r in order {
                let start = r * cols
                reordered.append(contentsOf: table.children[start..<(start + cols)])
            }
            table.children = reordered
            sheet.body.blocks[tableID] = table
        }
        // `order[newRow] == oldRow` (QueryEngine.sort's own contract):
        // a physical row previously hidden at `oldRow` now lives at
        // `newRow`, so remap the set through that same mapping rather
        // than leaving it pointing at pre-sort indices.
        if var state = sheet.filterState, !state.hiddenRows.isEmpty {
            var remapped: Set<Int> = []
            remapped.reserveCapacity(state.hiddenRows.count)
            for (newRow, oldRow) in order.enumerated() where state.hiddenRows.contains(oldRow) {
                remapped.insert(newRow)
            }
            state.hiddenRows = remapped
            sheet.filterState = state
        }
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(entityID: sheetID, receiptType: outcome.receiptType, payload: outcome.payload)
        return sheet
    }

    /// Evaluate `criteria` against the live grid (see
    /// ``QueryEngine/applyFilter(rowCount:criteria:referenceDate:value:displayText:format:)``)
    /// and persist the resulting ``SheetFilterState``.
    ///
    /// `displayText` reads through `Sheet.cellText`, the same stored
    /// inline-run text every other cell-reading path in this file
    /// uses - not a number-format-rendered string (no
    /// `SheetValueRenderer` dependency here; see the type header).
    public func applyFilter(_ criteria: [SheetFilterColumn], for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        try guardUnlocked(sheet)
        guard let tableDims = tableDimensions(of: sheet.body) else {
            throw SheetStoreError.noTable(sheetID: sheetID)
        }
        let (state, outcome) = QueryEngine.applyFilter(
            rowCount: tableDims.rows,
            criteria: criteria,
            value: { row, col in sheet.cellValue(row: row, col: col) },
            displayText: { row, col in sheet.cellText(row: row, col: col) },
            format: { row, col in sheet.cellFormat(row: row, col: col) }
        )
        sheet.filterState = state
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(entityID: sheetID, receiptType: outcome.receiptType, payload: outcome.payload)
        return sheet
    }

    /// Drop every active autofilter criterion and unhide every row
    /// (see ``QueryEngine/clearFilter(previousState:)``).
    public func clearFilter(for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        try guardUnlocked(sheet)
        let (state, outcome) = QueryEngine.clearFilter(previousState: sheet.effectiveFilterState)
        sheet.filterState = state
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(entityID: sheetID, receiptType: outcome.receiptType, payload: outcome.payload)
        return sheet
    }

    // MARK: - Comments

    /// Attach a new comment thread to `sheetID`, anchored at `anchor`,
    /// with a single root message holding `text`. Mirrors the grid
    /// mutations above (loadOrFail -> mutate -> upsert -> receipt), but
    /// deliberately skips bounds-checking a `.cell` anchor's row/col
    /// against the sheet's live grid dimensions - a comment can
    /// reasonably anchor to content that doesn't exist yet (e.g. a
    /// template comment left for a row not yet filled in).
    public func addComment(
        anchor: CommentAnchor,
        author: String,
        text: String,
        for sheetID: UUID
    ) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        let thread = CommentThread(
            id: UUID(),
            anchor: anchor,
            author: author,
            createdAt: Date(),
            messages: [CommentMessage(author: author, text: text)],
            isResolved: false
        )
        sheet = sheet.addingCommentThread(thread)
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.addComment.rawValue,
            payload: [
                "commentID": .string(thread.id.uuidString),
                "anchor": .object(Self.anchorPayload(anchor)),
            ]
        )
        return sheet
    }

    /// Structural summary of `anchor` for the `addComment` receipt
    /// payload - not `CommentAnchor`'s full `Codable` encoding (that's
    /// what persists the thread itself); just enough for an auditor
    /// reading the receipt chain to see where the comment landed.
    private static func anchorPayload(_ anchor: CommentAnchor) -> [String: JSONValue] {
        switch anchor {
        case let .cell(_, row, col):
            return ["kind": .string("cell"), "row": .number(Double(row)), "col": .number(Double(col))]
        case let .textRange(blockID, start, end):
            return [
                "kind": .string("textRange"),
                "blockID": .string(blockID.uuidString),
                "start": .number(Double(start)),
                "end": .number(Double(end)),
            ]
        case let .block(blockID):
            return ["kind": .string("block"), "blockID": .string(blockID.uuidString)]
        case let .slide(slideID):
            return ["kind": .string("slide"), "slideID": .string(slideID.uuidString)]
        }
    }

    /// Append a reply to an existing comment thread. Uses
    /// `CommentThread.addingReply(_:)` (Comments.swift) for the value
    /// mutation and `Sheet.replacingCommentThread(_:)` to write it
    /// back. A no-op (zero receipts, zero persistence) when `threadID`
    /// doesn't name a thread on this sheet - guard-and-early-return
    /// before persist+receipt, the receipts law's canonical shape (see
    /// `SheetStore.archive`).
    public func replyToComment(
        threadID: UUID,
        author: String,
        text: String,
        for sheetID: UUID
    ) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        guard let thread = sheet.effectiveCommentThreads.first(where: { $0.id == threadID }) else {
            return sheet
        }
        let message = CommentMessage(author: author, text: text)
        sheet = sheet.replacingCommentThread(thread.addingReply(message))
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.commentReplied.rawValue,
            payload: [
                "commentID": .string(threadID.uuidString),
                "messageID": .string(message.id.uuidString),
            ]
        )
        return sheet
    }

    /// Mark a comment thread resolved via `CommentThread.resolved()`.
    /// A no-op when `threadID` doesn't name a thread on this sheet, OR
    /// the thread is already resolved - the second guard is what keeps
    /// a repeated "resolve" from receipting a non-mutation, matching
    /// `SheetStore.archive`'s `guard !sheet.isArchived` shape exactly.
    public func resolveComment(threadID: UUID, for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        guard let thread = sheet.effectiveCommentThreads.first(where: { $0.id == threadID }),
              !thread.isResolved else {
            return sheet
        }
        sheet = sheet.replacingCommentThread(thread.resolved())
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.commentResolved.rawValue,
            payload: ["commentID": .string(threadID.uuidString)]
        )
        return sheet
    }

    /// Delete a comment thread outright via
    /// `Sheet.removingCommentThread(id:)`. A no-op when `threadID`
    /// doesn't name a thread on this sheet.
    public func deleteComment(threadID: UUID, for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        guard sheet.effectiveCommentThreads.contains(where: { $0.id == threadID }) else {
            return sheet
        }
        sheet = sheet.removingCommentThread(id: threadID)
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.commentDeleted.rawValue,
            payload: ["commentID": .string(threadID.uuidString)]
        )
        return sheet
    }

    // MARK: - Archive / Trash / Favorite

    public func archive(_ sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        guard !sheet.isArchived else { return sheet }
        sheet.isArchived = true
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.archive.rawValue,
            payload: ["wasAlreadyArchived": .bool(false)]
        )
        return sheet
    }

    public func unarchive(_ sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        guard sheet.isArchived else { return sheet }
        sheet.isArchived = false
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.unarchive.rawValue,
            payload: ["wasArchived": .bool(true)]
        )
        return sheet
    }

    public func trash(_ sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        guard !sheet.isTrashed else { return sheet }
        sheet.isTrashed = true
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.trash.rawValue,
            payload: ["wasAlreadyTrashed": .bool(false)]
        )
        return sheet
    }

    public func restore(_ sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        guard sheet.isTrashed else { return sheet }
        sheet.isTrashed = false
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.restore.rawValue,
            payload: ["wasTrashed": .bool(true)]
        )
        return sheet
    }

    public func favorite(_ sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        guard !sheet.isFavorite else { return sheet }
        sheet.isFavorite = true
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.favorite.rawValue,
            payload: ["wasAlreadyFavorite": .bool(false)]
        )
        return sheet
    }

    public func unfavorite(_ sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        guard sheet.isFavorite else { return sheet }
        sheet.isFavorite = false
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.unfavorite.rawValue,
            payload: ["wasFavorite": .bool(true)]
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
        guard !sheet.tags.contains(first) else { return sheet }
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
        guard let index = sheet.tags.firstIndex(of: first) else { return sheet }
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
        try guardUnlocked(sheet)
        guard let tableDims = tableDimensions(of: sheet.body) else {
            throw SheetStoreError.cellNotFound(row: row, col: col)
        }
        let cellListID = try cellID(row: row, col: col, dims: tableDims, body: sheet.body)
        guard var cell = sheet.body.blocks[cellListID] else {
            throw SheetStoreError.cellNotFound(row: row, col: col)
        }
        cell.content = value.isEmpty ? [] : [InlineRun(text: value)]
        let columnType = col < sheet.columns.count ? sheet.columns[col].type : .text
        let classified = CellValue.classify(value, columnType: columnType)
        if classified.isEmpty {
            cell.attributes.removeValue(forKey: CellValue.attributeKey)
        } else {
            cell.attributes[CellValue.attributeKey] = classified.json
        }
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
    case sheetProtected(sheetID: UUID, reason: String?)
}

// JSONValue accessors are provided by TesseraTool.swift; no local extension.
