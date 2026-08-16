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

    // MARK: - Cell-write mechanics shared by the mutations below
    //
    // (P2-A centralized wiring pass, item 2.2a/2.7/2.6.) `setCell` itself
    // stays the public, single-cell, single-receipt entry point; the
    // helpers below extract its value-classification write so pivot
    // output, subtotal summary rows, and goal-seek/solver applies can
    // batch several writes under ONE upsert + ONE receipt without
    // double-emitting through the public wrapper.

    /// A `.tableCell` block for `text`, classified through
    /// `CellValue.classify` exactly as `setCell` classifies a written
    /// value (e.g. a `=SUBTOTAL(...)` string classifies to `.formula`,
    /// not `.text`). Used by the row-insertion primitive below to
    /// pre-populate a brand-new row's cells (no existing block to look
    /// up by id yet - see `writingCellValue` for the existing-cell case).
    private func classifiedCellBlock(text: String, columnType: SheetColumnType) -> Block {
        var block = Block(type: .tableCell, content: text.isEmpty ? [] : [InlineRun(text: text)])
        let classified = CellValue.classify(text, columnType: columnType)
        if !classified.isEmpty {
            block.attributes[CellValue.attributeKey] = classified.json
        }
        return block
    }

    /// Writes `text` into the EXISTING cell at (row, col), using the same
    /// classification `setCell` uses, throwing the same `SheetStoreError`
    /// `setCell` would for a missing table / out-of-bounds coordinate /
    /// missing cell block. Goal seek's and the solver's applies share
    /// this rather than calling the public, individually-receipted
    /// `setCell`.
    private func writingCellValue(_ text: String, row: Int, col: Int, in sheet: inout Sheet) throws {
        guard let tableDims = tableDimensions(of: sheet.body) else {
            throw SheetStoreError.noTable(sheetID: sheet.id)
        }
        guard row >= 0, row < tableDims.rows, col >= 0, col < tableDims.cols else {
            throw SheetStoreError.cellOutOfBounds(row: row, col: col, rows: tableDims.rows, cols: tableDims.cols)
        }
        let cid = try cellID(row: row, col: col, dims: tableDims, body: sheet.body)
        guard var cell = sheet.body.blocks[cid] else {
            throw SheetStoreError.cellNotFound(row: row, col: col)
        }
        cell.content = text.isEmpty ? [] : [InlineRun(text: text)]
        let columnType = col < sheet.columns.count ? sheet.columns[col].type : .text
        let classified = CellValue.classify(text, columnType: columnType)
        if classified.isEmpty {
            cell.attributes.removeValue(forKey: CellValue.attributeKey)
        } else {
            cell.attributes[CellValue.attributeKey] = classified.json
        }
        sheet.body.blocks[cid] = cell
    }

    // MARK: - Pivot tables (P2-A 2.2a)

    /// Plain text for an already-typed `CellValue`, e.g. for a pivot
    /// grid cell that is computed directly (a `.number` aggregate, a
    /// `.text` header) rather than typed by a user. Mirrors
    /// `PivotTableStore`'s own private `displayText(_:)` convention
    /// (each pure engine owns its own copy rather than sharing one - see
    /// that file's header for the no-cross-track-file-reach rule this
    /// wave's tracks worked under).
    private func plainText(for value: CellValue) -> String {
        switch value {
        case .empty: return ""
        case .text(let s): return s
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
            return String(n)
        case .date(let d): return ISO8601DateFormatter().string(from: d)
        case .checkbox(let b): return b ? "TRUE" : "FALSE"
        case .formula(let s): return s
        case .error(let s): return s
        }
    }

    /// Writes a rectangular `[[CellValue]]` (a computed pivot grid) into
    /// the sheet starting at (topLeftRow, topLeftCol), one cell per
    /// entry, using the already-typed `CellValue` directly (no
    /// text-classification round-trip - the grid's cells are already
    /// exactly the values they should be). A position outside the
    /// sheet's CURRENT physical extent is silently skipped, matching
    /// `Sheet.settingCellValue`'s own "coordinate outside the grid
    /// leaves the sheet unchanged" contract - growing the grid to fit an
    /// output range that runs past the current table bounds is out of
    /// P2a scope (`PivotTableStore`'s own "P2a: tabular layout + grand
    /// totals only" framing). Returns the RangeRef the write TARGETED
    /// (not clipped to what was actually in-bounds), for the receipt
    /// payload's `outputRange` description.
    @discardableResult
    private func writingGrid(_ rows: [[CellValue]], into sheet: inout Sheet, topLeftRow: Int, topLeftCol: Int) -> RangeRef {
        if let tableDims = tableDimensions(of: sheet.body) {
            for (rOffset, rowValues) in rows.enumerated() {
                let row = topLeftRow + rOffset
                guard row >= 0, row < tableDims.rows else { continue }
                for (cOffset, value) in rowValues.enumerated() {
                    let col = topLeftCol + cOffset
                    guard col >= 0, col < tableDims.cols,
                          let cid = try? cellID(row: row, col: col, dims: tableDims, body: sheet.body),
                          var cell = sheet.body.blocks[cid] else { continue }
                    let text = plainText(for: value)
                    cell.content = text.isEmpty ? [] : [InlineRun(text: text)]
                    if value.isEmpty {
                        cell.attributes.removeValue(forKey: CellValue.attributeKey)
                    } else {
                        cell.attributes[CellValue.attributeKey] = value.json
                    }
                    sheet.body.blocks[cid] = cell
                }
            }
        }
        let bottomRow = topLeftRow + max(rows.count - 1, 0)
        let bottomCol = topLeftCol + max((rows.first?.count ?? 1) - 1, 0)
        return RangeRef(
            topLeft: CellAddr(col: max(0, topLeftCol), row: max(0, topLeftRow)),
            bottomRight: CellAddr(col: max(0, bottomCol), row: max(0, bottomRow))
        )
    }

    /// Where a pivot's output grid lands absent an explicit
    /// `outputTopLeftRow`/`outputTopLeftCol`: the same row as the source
    /// range's own top-left, two columns past the source range's right
    /// edge.
    private func outputOrigin(for definition: SheetPivotDefinition) -> (row: Int, col: Int) {
        let row = definition.outputTopLeftRow ?? definition.topLeftRow
        let col = definition.outputTopLeftCol ?? (definition.bottomRightCol + 2)
        return (row, col)
    }

    /// Define (or replace) a pivot table definition and (re)compute its
    /// output grid via `PivotTableStore.build`. A no-op (zero receipts,
    /// zero persistence) when an EQUATABLE-identical definition (same
    /// id, every field equal) already exists - a caller re-submitting
    /// the unchanged definition (e.g. a UI re-save with no edits) must
    /// not spam the receipt chain. A definition sharing an id with an
    /// existing one but differing in some field REPLACES it (still
    /// `.definePivot`, not `.updatePivot` - there is no automatic-
    /// recompute trigger yet that `.updatePivot` would distinguish from
    /// this explicit define/redefine call).
    public func definePivot(_ definition: SheetPivotDefinition, for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        try guardUnlocked(sheet)
        if let existing = sheet.effectivePivotDefinitions.first(where: { $0.id == definition.id }),
           existing == definition {
            return sheet
        }
        if sheet.effectivePivotDefinitions.contains(where: { $0.id == definition.id }) {
            sheet = sheet.removingPivotDefinition(definition.id)
        }
        sheet = sheet.addingPivotDefinition(definition)

        let grid = try PivotTableStore.build(sheet: sheet, definition: definition)
        let origin = outputOrigin(for: definition)
        let outputRange = writingGrid(grid.rows, into: &sheet, topLeftRow: origin.row, topLeftCol: origin.col)

        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.definePivot.rawValue,
            payload: [
                "id": .string(definition.id.uuidString),
                "sourceHash": .string(definition.sourceRangeRef?.description ?? ""),
                "outputRange": .string(outputRange.description),
                "rowCount": .number(Double(grid.rowCount)),
                "columnCount": .number(Double(grid.columnCount)),
            ]
        )
        return sheet
    }

    /// Remove a pivot table definition. A no-op (zero receipts) when
    /// `id` doesn't name a definition on this sheet. Leaves any
    /// previously-written output-range cells as-is (clearing them is out
    /// of P2a scope).
    public func removePivot(_ id: UUID, for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        try guardUnlocked(sheet)
        guard sheet.effectivePivotDefinitions.contains(where: { $0.id == id }) else { return sheet }
        sheet = sheet.removingPivotDefinition(id)
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.removePivot.rawValue,
            payload: ["id": .string(id.uuidString)]
        )
        return sheet
    }

    /// Explicitly refresh a pivot's output grid against the sheet's
    /// current data. Throws `SheetStoreError.pivotNotFound` when `id`
    /// doesn't name a definition on this sheet (an explicit user action
    /// against a specific pivot, unlike `definePivot`'s create-or-
    /// replace). A no-op (zero receipts) when the newly-computed grid is
    /// cell-for-cell identical to what is currently written at the
    /// output range - "identical-grid refresh = no-op" per the design
    /// contract.
    public func refreshPivot(id: UUID, for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        try guardUnlocked(sheet)
        guard let definition = sheet.effectivePivotDefinitions.first(where: { $0.id == id }) else {
            throw SheetStoreError.pivotNotFound(id: id)
        }
        let grid = try PivotTableStore.build(sheet: sheet, definition: definition)
        let origin = outputOrigin(for: definition)

        let unchanged = grid.rows.enumerated().allSatisfy { rOffset, rowValues in
            rowValues.enumerated().allSatisfy { cOffset, value in
                sheet.cellValue(row: origin.row + rOffset, col: origin.col + cOffset) == value
            }
        }
        guard !unchanged else { return sheet }

        writingGrid(grid.rows, into: &sheet, topLeftRow: origin.row, topLeftCol: origin.col)
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.refreshPivot.rawValue,
            payload: [
                "id": .string(id.uuidString),
                "rowCount": .number(Double(grid.rowCount)),
                "columnCount": .number(Double(grid.columnCount)),
            ]
        )
        return sheet
    }

    // MARK: - Subtotals (P2-A 2.7)
    //
    // Row-insertion/deletion primitives that mirror `insertRow`/
    // `deleteRow`'s own grid-mutation block exactly, but perform NO
    // upsert and append NO receipt of their own - `applySubtotals`/
    // `removeSubtotals` apply potentially many of these under ONE
    // upsert + ONE receipt, which the public `insertRow`/`deleteRow`
    // (each individually receipted) cannot do.

    /// Inserts one new row at `index`, pre-populated per-column from
    /// `cellTexts` (a subtotal summary row is not blank - see
    /// `SubtotalRowInsertion.cellTexts`'s own doc comment).
    private func insertingRowInPlace(in sheet: inout Sheet, at index: Int, cellTexts: [Int: String] = [:]) throws {
        guard let tableID = primaryTableID(of: sheet.body),
              var table = sheet.body.blocks[tableID] else {
            throw SheetStoreError.noTable(sheetID: sheet.id)
        }
        let rows = Int(table.attributes["rows"]?.numberValue ?? 0)
        let cols = Int(table.attributes["cols"]?.numberValue ?? 0)
        guard index >= 0, index <= rows else {
            throw SheetStoreError.rowOutOfBounds(index: index, rows: rows)
        }
        let newCellIDs: [UUID] = (0..<cols).map { _ in UUID() }
        for (col, id) in newCellIDs.enumerated() {
            let columnType = col < sheet.columns.count ? sheet.columns[col].type : .text
            sheet.body.blocks[id] = classifiedCellBlock(text: cellTexts[col] ?? "", columnType: columnType)
        }
        let insertAt = index * cols
        table.children.insert(contentsOf: newCellIDs, at: insertAt)
        table.attributes["rows"] = .number(Double(rows + 1))
        sheet.body.blocks[tableID] = table
    }

    /// Deletes the row at `index`. Mirrors `deleteRow`'s own
    /// grid-mutation block; see `insertingRowInPlace` above.
    private func deletingRowInPlace(in sheet: inout Sheet, at index: Int) throws {
        guard let tableID = primaryTableID(of: sheet.body),
              var table = sheet.body.blocks[tableID] else {
            throw SheetStoreError.noTable(sheetID: sheet.id)
        }
        let rows = Int(table.attributes["rows"]?.numberValue ?? 0)
        let cols = Int(table.attributes["cols"]?.numberValue ?? 0)
        guard index >= 0, index < rows else {
            throw SheetStoreError.rowOutOfBounds(index: index, rows: rows)
        }
        let start = index * cols
        let toRemove = Array(table.children[start..<(start + cols)])
        table.children.removeSubrange(start..<(start + cols))
        table.attributes["rows"] = .number(Double(rows - 1))
        sheet.body.blocks[tableID] = table
        for id in toRemove { sheet.body.blocks.removeValue(forKey: id) }
    }

    /// Removes every row currently tracked in
    /// `sheet.effectiveSubtotalRowIndices` (descending order, so earlier
    /// deletions never invalidate a later target index) and clears the
    /// three subtotal-related fields. No upsert, no receipt - shared by
    /// `applySubtotals` (when `descriptor.replaceExisting`) and
    /// `removeSubtotals`, each of which persists + receipts once.
    private func strippingSubtotals(from sheet: Sheet) throws -> Sheet {
        var updated = sheet
        for index in updated.effectiveSubtotalRowIndices.sorted(by: >) {
            try deletingRowInPlace(in: &updated, at: index)
            updated = adjustFormulas(in: updated, for: .deleteRows(at: index, count: 1))
        }
        updated.rowOutlineLevels = nil
        updated.outlineSummaryBelow = nil
        updated.subtotalRowIndices = nil
        return updated
    }

    /// Group `sheet` by `descriptor.groupByColumn` and insert a
    /// `=SUBTOTAL(...)` summary row per group (plus a grand total) via
    /// `SubtotalEngine.plan`. When `descriptor.replaceExisting`, any
    /// subtotal structure already on the sheet is stripped first (NOT
    /// separately receipted - see `strippingSubtotals`). A no-op (zero
    /// receipts, zero persistence) when the resulting plan has nothing
    /// to insert (e.g. an empty sheet, or an empty
    /// `perColumnFunctions`).
    public func applySubtotals(_ descriptor: SubtotalDescriptor, for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        try guardUnlocked(sheet)
        if descriptor.replaceExisting {
            sheet = try strippingSubtotals(from: sheet)
        }
        let plan = SubtotalEngine.plan(for: sheet, descriptor: descriptor)
        guard !plan.insertions.isEmpty else { return sheet }

        // Apply DESCENDING (`SubtotalRowInsertion.beforeOriginalRow`'s
        // own documented contract): every insertion's `beforeOriginalRow`
        // is always the correct raw row index to insert at, regardless
        // of what already happened earlier in this loop, precisely
        // because only LARGER-or-equal targets have been applied so far.
        for insertion in plan.insertions.reversed() {
            try insertingRowInPlace(in: &sheet, at: insertion.beforeOriginalRow, cellTexts: insertion.cellTexts)
            sheet = adjustFormulas(in: sheet, for: .insertRows(at: insertion.beforeOriginalRow, count: 1))
        }

        // Re-key existing rows to their post-insertion index: every
        // original row shifts down by however many insertions targeted
        // a position at or before its own original index.
        var newOutlineLevels: [Int: Int] = [:]
        for (originalRow, level) in plan.existingRowLevels {
            let shift = plan.insertions.filter { $0.beforeOriginalRow <= originalRow }.count
            newOutlineLevels[originalRow + shift] = level
        }
        // Each insertion's own final index: `plan.insertions` is sorted
        // ascending by `beforeOriginalRow` (its own documented
        // contract), so the i-th insertion in that ascending order lands
        // `i` positions past its own original target - see this
        // method's wiring notes for the worked derivation.
        var newSubtotalRowIndices: Set<Int> = []
        for (i, insertion) in plan.insertions.enumerated() {
            let finalIndex = insertion.beforeOriginalRow + i
            newOutlineLevels[finalIndex] = insertion.outlineLevel
            newSubtotalRowIndices.insert(finalIndex)
        }

        sheet.rowOutlineLevels = newOutlineLevels
        sheet.outlineSummaryBelow = descriptor.summaryBelow
        sheet.subtotalRowIndices = newSubtotalRowIndices
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.applySubtotals.rawValue,
            payload: [
                "groupByColumn": .number(Double(descriptor.groupByColumn)),
                "groupCount": .number(Double(plan.groupCount)),
                "insertedRowCount": .number(Double(plan.insertions.count)),
                "columnFunctionCount": .number(Double(descriptor.perColumnFunctions.count)),
                "summaryBelow": .bool(descriptor.summaryBelow),
            ]
        )
        return sheet
    }

    /// Remove a previously-applied subtotal structure, restoring the
    /// sheet to its pre-subtotal contents. A no-op (zero receipts) when
    /// `sheet.effectiveSubtotalRowIndices` is empty.
    public func removeSubtotals(for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        try guardUnlocked(sheet)
        guard !sheet.effectiveSubtotalRowIndices.isEmpty else { return sheet }
        let removedRowCount = sheet.effectiveSubtotalRowIndices.count
        sheet = try strippingSubtotals(from: sheet)
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.removeSubtotals.rawValue,
            payload: ["removedRowCount": .number(Double(removedRowCount))]
        )
        return sheet
    }

    /// Toggle an outline group's collapsed/expanded state.
    /// `summaryRowIndex` must currently be a level > 0 key in
    /// `sheet.effectiveRowOutlineLevels` (a no-op otherwise). The rows
    /// toggled are the contiguous run immediately preceding (when
    /// `sheet.effectiveOutlineSummaryBelow`) or following (otherwise)
    /// `summaryRowIndex` whose own outline level is exactly one deeper -
    /// a no-op when that run is empty. "Toggle" flips the WHOLE run
    /// together: if every row in the run is already hidden, this reveals
    /// all of them (`collapsed` reports `false`); otherwise it hides all
    /// of them (`collapsed` reports `true`) - a single well-defined new
    /// state for the group, not an independent per-row flip.
    public func toggleOutline(summaryRowIndex: Int, for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        try guardUnlocked(sheet)
        guard let summaryLevel = sheet.effectiveRowOutlineLevels[summaryRowIndex], summaryLevel > 0 else {
            return sheet
        }
        let detailLevel = summaryLevel + 1
        var detailRows: [Int] = []
        if sheet.effectiveOutlineSummaryBelow {
            var row = summaryRowIndex - 1
            while row >= 0, sheet.effectiveRowOutlineLevels[row] == detailLevel {
                detailRows.append(row)
                row -= 1
            }
        } else {
            var row = summaryRowIndex + 1
            let rowCount = sheet.rowCount
            while row < rowCount, sheet.effectiveRowOutlineLevels[row] == detailLevel {
                detailRows.append(row)
                row += 1
            }
        }
        guard !detailRows.isEmpty else { return sheet }

        var hidden = sheet.effectiveManuallyHiddenRows
        let isCurrentlyCollapsed = detailRows.allSatisfy { hidden.contains($0) }
        let collapsed = !isCurrentlyCollapsed
        if collapsed {
            hidden.formUnion(detailRows)
        } else {
            hidden.subtract(detailRows)
        }
        sheet.manuallyHiddenRows = hidden
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.toggleOutline.rawValue,
            payload: [
                "summaryRowIndex": .number(Double(summaryRowIndex)),
                "collapsed": .bool(collapsed),
                "hiddenRowCount": .number(Double(detailRows.count)),
            ]
        )
        return sheet
    }

    // MARK: - Solver (P2-A 2.6)

    /// Commit a converged goal-seek result: write the resolved variable
    /// value into `request.variableCell`. A no-op (zero receipts) when
    /// `result.status != .converged` - the store does not trust the
    /// caller alone to have checked this (defense in depth; the tool
    /// layer already refuses to call this for a non-converged result).
    public func applyGoalSeek(_ request: GoalSeekRequest, result: GoalSeekResult, for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        try guardUnlocked(sheet)
        guard result.status == .converged else { return sheet }
        try writingCellValue(
            String(result.resolvedValue),
            row: request.variableCell.row, col: request.variableCell.col,
            in: &sheet
        )
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        let outcome = SolverEngine.goalSeekReceiptPayload(request: request, result: result)
        try await appendReceipt(entityID: sheetID, receiptType: outcome.receiptType, payload: outcome.payload)
        return sheet
    }

    /// Commit an optimal solver run: write every resolved variable
    /// value into its cell, all under ONE upsert. A no-op (zero
    /// receipts) when `result.status != .optimal` - same defense-in-
    /// depth reasoning as `applyGoalSeek`.
    public func applySolverRun(_ model: SolverModel, result: SolverResult, for sheetID: UUID) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        try guardUnlocked(sheet)
        guard result.status == .optimal else { return sheet }
        for cell in model.variableCells {
            let value = result.variableValues[cell] ?? 0
            try writingCellValue(String(value), row: cell.row, col: cell.col, in: &sheet)
        }
        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        let outcome = SolverEngine.solverReceiptPayload(model: model, result: result)
        try await appendReceipt(entityID: sheetID, receiptType: outcome.receiptType, payload: outcome.payload)
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

    // MARK: - Database import (P2-D 2.16, db_import_range)

    /// Materialize a local-database query's result into a rectangular
    /// range of `sheetID`'s primary table, anchored at `anchor`. Column
    /// headers are written to the anchor row and the data rows follow it,
    /// so an `N` x `M` result writes `N+1` rows x `M` cols. Grows the
    /// table first (columns, then rows, so new rows land at full width)
    /// when the result does not fit the current grid - see
    /// `growingTable(rows:cols:in:)`.
    ///
    /// One upsert, one `.importFromDatabase` receipt carrying the design
    /// contract's own "full audit provenance" payload: the source file's
    /// path + content hash (`sha256:<hex>`, computed by the caller -
    /// `DatabaseConnector.sourceHash(of:)` - this store never touches the
    /// filesystem itself), the exact SQL text that produced the result,
    /// and the row count. `db_query` itself never reaches this method -
    /// only materialization emits a receipt ("no receipt without a
    /// mutation" is a standing rule, not new to this item).
    ///
    /// A no-op (zero receipts, zero persistence) when `columns` or `rows`
    /// is empty - nothing to materialize.
    public func importFromDatabase(
        columns: [String],
        rows: [[String]],
        sourcePath: String,
        sourceHash: String,
        sql: String,
        anchor: CellAddr,
        for sheetID: UUID
    ) async throws -> Sheet {
        var sheet = try await loadOrFail(id: sheetID)
        try guardUnlocked(sheet)
        guard !columns.isEmpty, !rows.isEmpty else { return sheet }

        let neededRows = anchor.row + rows.count + 1 // +1 header row
        let neededCols = anchor.col + columns.count
        sheet = try growingTable(rows: neededRows, cols: neededCols, in: sheet)

        for (c, name) in columns.enumerated() {
            try writingCellValue(name, row: anchor.row, col: anchor.col + c, in: &sheet)
        }
        for (r, rowValues) in rows.enumerated() {
            for (c, value) in rowValues.enumerated() where c < columns.count {
                try writingCellValue(value, row: anchor.row + 1 + r, col: anchor.col + c, in: &sheet)
            }
        }

        sheet.updatedAt = Date()
        _ = try await upsert(sheet)
        try await appendReceipt(
            entityID: sheetID,
            receiptType: SheetReceiptType.importFromDatabase.rawValue,
            payload: [
                "sourcePath": .string(sourcePath),
                "sourceHash": .string(sourceHash),
                "sql": .string(sql),
                "rowCount": .number(Double(rows.count)),
                "columnCount": .number(Double(columns.count)),
                "anchor": .string(anchor.description),
            ]
        )
        return sheet
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

    /// A copy of `sheet` whose primary table has at least `neededRows` x
    /// `neededCols` cells, appending blank cells/columns at the tail only
    /// - existing cell IDs keep their (row, col) position, so nothing
    /// already on the grid (formulas, styles, values) moves or is
    /// disturbed. A no-op copy when the table already meets or exceeds
    /// the requested size. Throws `.noTable` when `sheet` has no primary
    /// table at all - same no-table contract every other grid mutation in
    /// this file uses.
    ///
    /// Used by `importFromDatabase(...)` (`db_import_range`) to grow the
    /// grid to fit a materialized query result before writing into it.
    ///
    /// `internal`, not `private`, ONLY so
    /// `SheetStoreImportFromDatabaseLogicShadowTests.swift` can exercise
    /// this exact logic path via `@testable import` without a real
    /// `TesseraDataLayer` - doctrine rule 11's "ungated shadow of the
    /// same logic path", the same requirement `SheetStoreLogicShadowTests.
    /// swift` satisfies for every other mutation method by calling a
    /// public pure `Sheet` method. This wave's file-ownership split
    /// leaves `Sheet.swift` outside this track's file list (see this
    /// track's findings file), so the shadow test reaches the pure logic
    /// through this store-internal helper instead of a `Sheet` extension.
    func growingTable(rows neededRows: Int, cols neededCols: Int, in sheet: Sheet) throws -> Sheet {
        guard let tableID = primaryTableID(of: sheet.body), var table = sheet.body.blocks[tableID] else {
            throw SheetStoreError.noTable(sheetID: sheet.id)
        }
        let currentRows = Int(table.attributes["rows"]?.numberValue ?? 0)
        let currentCols = Int(table.attributes["cols"]?.numberValue ?? 0)
        let newRows = max(currentRows, neededRows)
        let newCols = max(currentCols, neededCols)
        guard newRows > currentRows || newCols > currentCols else { return sheet }

        var updated = sheet
        var newChildren: [UUID] = []
        newChildren.reserveCapacity(newRows * newCols)
        for r in 0..<newRows {
            for c in 0..<newCols {
                if r < currentRows, c < currentCols {
                    newChildren.append(table.children[r * currentCols + c])
                } else {
                    let newID = UUID()
                    updated.body.blocks[newID] = Block(type: .tableCell, content: [])
                    newChildren.append(newID)
                }
            }
        }
        table.children = newChildren
        table.attributes["rows"] = .number(Double(newRows))
        table.attributes["cols"] = .number(Double(newCols))
        updated.body.blocks[tableID] = table
        while updated.columns.count < newCols {
            updated.columns.append(SheetColumn(label: "", type: .text))
        }
        return updated
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
    /// `refreshPivot(id:for:)` was called against an id that names no
    /// pivot definition on the sheet - an explicit user action against a
    /// specific pivot, unlike `definePivot`'s create-or-replace, so this
    /// is a real error rather than a no-op (P2-A 2.2a wiring).
    case pivotNotFound(id: UUID)
}

// JSONValue accessors are provided by TesseraTool.swift; no local extension.
