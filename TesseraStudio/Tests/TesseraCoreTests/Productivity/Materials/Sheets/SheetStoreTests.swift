import XCTest
@testable import TesseraCore

// Contract source: testing-doctrine.md's coverage-shape table ("Store
// mutation: receipt + persistence + no-op zero-receipt + error path
// (not-found throws without writing)") applied to `SheetStore`, per the
// wave brief's explicit instruction: "SheetStore itself needs the full
// mutation quartet ... for every public method, not just the
// Calc-cluster-specific ones." `SheetReceiptType`'s own doc comment is
// the receipt-type contract ("every mutation that changes sheet state
// ... appends a signed receipt").
//
// DB-GATED (doctrine rule 11): `SheetStore` takes a concrete
// `TesseraDataLayer` actor with no protocol seam (verified by reading
// `SheetStore.swift`/`TesseraDataLayer.swift` - see the findings file).
// This whole file requires a real, reachable Postgres + Valkey and is
// skipped (via `XCTSkip`, not silently) unless `TESSERA_DB_INTEGRATION=1`
// is set AND the local stack answers. The ungated shadow of the SAME
// logic paths lives in `SheetStoreLogicShadowTests.swift`.
final class SheetStoreTests: DoctrineTestCase {
    override var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.probe }

    private func makeConnectedStore() async throws -> SheetStore {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip(
                "TESSERA_DB_INTEGRATION not set - skipping real-Postgres SheetStore tests " +
                "(doctrine rule 11: see SheetStoreLogicShadowTests.swift for the ungated shadow)."
            )
        }
        let dataLayer = TesseraDataLayer()
        let outcome = await dataLayer.start()
        guard case .ready = outcome else {
            throw XCTSkip("Postgres/Valkey not reachable in this environment (\(outcome)) - skipping.")
        }
        return SheetStore(dataLayer: dataLayer)
    }

    private func freshSheet(rows: Int = 3, cols: Int = 3) -> Sheet {
        Sheet.makeBlank(title: "SheetStoreTests-\(UUID().uuidString.prefix(8))", rows: rows, cols: cols)
    }

    private func receiptTypes(_ receipts: [GraphReceipt]) -> [String] {
        receipts.map(\.receiptType)
    }

    /// `store.receipts(forSheet:)`, filtering out the fire-and-forget
    /// `SheetReceiptPayload.receiptType` ("sheet_operation") material
    /// receipt every `SheetStore.upsert(_:)` call schedules on an
    /// unawaited `Task` (see `SheetStore.upsert`'s own "Fire-and-forget
    /// material receipt: failure does not block the upsert" comment).
    /// That task's completion is a genuine race against this test file's
    /// own before/after receipt-count snapshots: a test with no real
    /// mutation between creating the sheet and capturing "before" can
    /// observe the material receipt landing at an arbitrary point
    /// relative to its own assertions, non-deterministically inflating
    /// either count by one. Filtering it out here scopes every
    /// before/after comparison in this file to the receipt types
    /// `SheetStore`'s own constitutional-receipt contract actually
    /// governs, independent of that unrelated background task's timing.
    private func sheetReceipts(_ store: SheetStore, forSheet id: UUID) async throws -> [GraphReceipt] {
        try await store.receipts(forSheet: id).filter { $0.receiptType != SheetReceiptPayload.receiptType }
    }

    // MARK: - upsert / get / delete

    func testUpsertEmitsExactlyOneUpsertReceiptAndPersistsTheSheet() async throws {
        let store = try await makeConnectedStore()
        let sheet = freshSheet()

        let stored = try await store.upsert(sheet)

        let receipts = try await store.receipts(forSheet: stored.id)
        XCTAssertEqual(receiptTypes(receipts).filter { $0 == SheetReceiptType.upsert.rawValue }.count, 1)
        let reloaded = try await store.get(id: stored.id)
        XCTAssertEqual(reloaded?.id, stored.id)
        XCTAssertEqual(reloaded?.displayTitle, sheet.displayTitle)
    }

    func testDeleteOfAnExistingSheetEmitsExactlyOneDeleteReceiptAndRemovesIt() async throws {
        let store = try await makeConnectedStore()
        let stored = try await store.upsert(freshSheet())

        let didDelete = try await store.delete(id: stored.id)

        XCTAssertTrue(didDelete)
        let reloaded = try await store.get(id: stored.id)
        XCTAssertNil(reloaded, "the sheet must actually be gone")
        let receipts = try await store.receipts(forSheet: stored.id)
        XCTAssertEqual(receiptTypes(receipts).filter { $0 == SheetReceiptType.delete.rawValue }.count, 1)
    }

    /// Error path: deleting an id that was never a sheet.
    func testDeleteOfUnknownIDReturnsFalseWithoutEmittingAReceipt() async throws {
        let store = try await makeConnectedStore()
        let unknownID = UUID()

        let didDelete = try await store.delete(id: unknownID)

        XCTAssertFalse(didDelete)
        let receipts = try await store.receipts(forSheet: unknownID)
        XCTAssertTrue(receipts.isEmpty, "a delete that deleted nothing must not emit a receipt")
    }

    // MARK: - setCell (error path: not-found throws without writing)

    func testSetCellAgainstAnUnknownSheetThrowsWithoutPersistingOrReceipting() async throws {
        let store = try await makeConnectedStore()
        let unknownID = UUID()

        do {
            _ = try await store.setCell(row: 0, col: 0, value: "x", for: unknownID)
            XCTFail("expected SheetStoreError.sheetNotFound")
        } catch SheetStoreError.sheetNotFound(let id) {
            XCTAssertEqual(id, unknownID)
        }

        let receipts = try await store.receipts(forSheet: unknownID)
        XCTAssertTrue(receipts.isEmpty)
        let reloaded = try await store.get(id: unknownID)
        XCTAssertNil(reloaded)
    }

    func testSetCellEmitsExactlyOneSetCellReceiptAndPersistsTheNewValue() async throws {
        let store = try await makeConnectedStore()
        let stored = try await store.upsert(freshSheet())

        let updated = try await store.setCell(row: 0, col: 0, value: "hello", for: stored.id)

        XCTAssertEqual(updated.cellText(row: 0, col: 0), "hello")
        let receipts = try await store.receipts(forSheet: stored.id)
        XCTAssertEqual(receiptTypes(receipts).filter { $0 == SheetReceiptType.setCell.rawValue }.count, 1)
        let reloaded = try await store.get(id: stored.id)
        XCTAssertEqual(reloaded?.cellText(row: 0, col: 0), "hello")
    }

    // MARK: - setCellFormat

    func testSetCellFormatEmitsExactlyOneReceiptAndPersistsThePresentationOnly() async throws {
        let store = try await makeConnectedStore()
        var sheet = freshSheet()
        sheet = try await store.upsert(sheet)
        sheet = try await store.setCell(row: 0, col: 0, value: "42", for: sheet.id)

        let format = SheetCellFormat(numberFormat: .currency, decimals: 2, isBold: true)
        let updated = try await store.setCellFormat(row: 0, col: 0, format: format, for: sheet.id)

        XCTAssertEqual(updated.cellFormat(row: 0, col: 0), format)
        XCTAssertEqual(updated.cellText(row: 0, col: 0), "42", "a restyle must not touch the cell's own text/value")
        let receipts = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptTypes(receipts).filter { $0 == SheetReceiptType.setCellFormat.rawValue }.count, 1)
    }

    // MARK: - Protected sheet: cell/format mutation refused, protection-setting itself never refused

    func testSetCellAgainstALockedSheetThrowsWithoutPersistingOrReceipting() async throws {
        let store = try await makeConnectedStore()
        var sheet = try await store.upsert(freshSheet())
        sheet = try await store.setProtection(SheetProtection(isLocked: true, reason: "published"), for: sheet.id)
        let receiptsBeforeAttempt = try await sheetReceipts(store, forSheet: sheet.id)

        do {
            _ = try await store.setCell(row: 0, col: 0, value: "x", for: sheet.id)
            XCTFail("expected SheetStoreError.sheetProtected")
        } catch SheetStoreError.sheetProtected(let sheetID, _) {
            XCTAssertEqual(sheetID, sheet.id)
        }

        let receiptsAfterAttempt = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptsAfterAttempt.count, receiptsBeforeAttempt.count, "the refused write must not append a receipt")
        let reloaded = try await store.get(id: sheet.id)
        XCTAssertEqual(reloaded?.cellText(row: 0, col: 0), "", "the refused write must not persist")
    }

    func testSettingProtectionItselfIsNeverBlockedByExistingProtection() async throws {
        let store = try await makeConnectedStore()
        var sheet = try await store.upsert(freshSheet())
        sheet = try await store.setProtection(SheetProtection(isLocked: true), for: sheet.id)

        // Unlocking a locked sheet must succeed - only cell/format edits
        // are refused, never a protection change itself.
        let unlocked = try await store.setProtection(SheetProtection(isLocked: false), for: sheet.id)
        XCTAssertFalse(unlocked.effectiveProtection.isLocked)
    }

    // MARK: - insertRow / deleteRow

    func testInsertRowEmitsExactlyOneReceiptAndPersistsTheGrownGrid() async throws {
        let store = try await makeConnectedStore()
        let sheet = try await store.upsert(freshSheet(rows: 2, cols: 2))

        let updated = try await store.insertRow(at: 0, for: sheet.id)

        XCTAssertEqual(updated.rowCount, 3)
        let receipts = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptTypes(receipts).filter { $0 == SheetReceiptType.insertRow.rawValue }.count, 1)
        let reloaded = try await store.get(id: sheet.id)
        XCTAssertEqual(reloaded?.rowCount, 3)
    }

    /// Error path: deleting the last remaining row must refuse without
    /// mutating or receipting.
    func testDeleteRowOfTheLastRemainingRowThrowsWithoutPersistingOrReceipting() async throws {
        let store = try await makeConnectedStore()
        let sheet = try await store.upsert(freshSheet(rows: 1, cols: 2))
        let receiptsBefore = try await sheetReceipts(store, forSheet: sheet.id)

        do {
            _ = try await store.deleteRow(at: 0, for: sheet.id)
            XCTFail("expected SheetStoreError.cannotDeleteLastRow")
        } catch SheetStoreError.cannotDeleteLastRow {
            // expected
        }

        let receiptsAfter = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptsAfter.count, receiptsBefore.count)
        let reloaded = try await store.get(id: sheet.id)
        XCTAssertEqual(reloaded?.rowCount, 1)
    }

    func testDeleteRowEmitsExactlyOneReceiptAndPersistsTheShrunkGrid() async throws {
        let store = try await makeConnectedStore()
        let sheet = try await store.upsert(freshSheet(rows: 2, cols: 2))

        let updated = try await store.deleteRow(at: 0, for: sheet.id)

        XCTAssertEqual(updated.rowCount, 1)
        let receipts = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptTypes(receipts).filter { $0 == SheetReceiptType.deleteRow.rawValue }.count, 1)
    }

    // MARK: - sortRange / applyFilter / clearFilter

    func testSortRangeEmitsExactlyOneSheetSortedReceiptAndPersistsTheNewOrder() async throws {
        let store = try await makeConnectedStore()
        var sheet = try await store.upsert(freshSheet(rows: 2, cols: 1))
        sheet = try await store.setCell(row: 0, col: 0, value: "2", for: sheet.id)
        sheet = try await store.setCell(row: 1, col: 0, value: "1", for: sheet.id)

        let sorted = try await store.sortRange([SheetSortCondition(columnIndex: 0, ascending: true)], for: sheet.id)

        XCTAssertEqual(sorted.cellText(row: 0, col: 0), "1")
        XCTAssertEqual(sorted.cellText(row: 1, col: 0), "2")
        let receipts = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptTypes(receipts).filter { $0 == SheetReceiptType.sorted.rawValue }.count, 1)
    }

    func testApplyFilterEmitsExactlyOneSheetFilterAppliedReceiptAndPersistsHiddenRows() async throws {
        let store = try await makeConnectedStore()
        var sheet = try await store.upsert(freshSheet(rows: 2, cols: 1))
        sheet = try await store.setCell(row: 0, col: 0, value: "keep", for: sheet.id)
        sheet = try await store.setCell(row: 1, col: 0, value: "drop", for: sheet.id)

        let criteria = [SheetFilterColumn(columnIndex: 0, criteria: SheetFilterCriteria(kind: .valueSet, values: ["keep"]))]
        let filtered = try await store.applyFilter(criteria, for: sheet.id)

        XCTAssertEqual(filtered.effectiveFilterState.hiddenRows, [1])
        let receipts = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptTypes(receipts).filter { $0 == SheetReceiptType.filterApplied.rawValue }.count, 1)
    }

    func testClearFilterEmitsExactlyOneSheetFilterClearedReceiptAndResetsState() async throws {
        let store = try await makeConnectedStore()
        var sheet = try await store.upsert(freshSheet(rows: 2, cols: 1))
        sheet = try await store.setCell(row: 0, col: 0, value: "a", for: sheet.id)
        let criteria = [SheetFilterColumn(columnIndex: 0, criteria: SheetFilterCriteria(kind: .valueSet, values: ["a"]))]
        sheet = try await store.applyFilter(criteria, for: sheet.id)

        let cleared = try await store.clearFilter(for: sheet.id)

        XCTAssertEqual(cleared.effectiveFilterState, .empty)
        let receipts = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptTypes(receipts).filter { $0 == SheetReceiptType.filterCleared.rawValue }.count, 1)
    }

    // MARK: - sortRange hiddenRows remap (audit item A4, "hidden rows are truth")

    func testSortRangeRemapsHiddenRowsThroughTheSamePermutationAsTheRowReorderSoTheSameLogicalRowStaysHidden() async throws {
        let store = try await makeConnectedStore()
        var sheet = try await store.upsert(freshSheet(rows: 3, cols: 1))
        // Row content by ORIGINAL physical index: row0="b", row1="a",
        // row2="c". Sorting ascending moves "a" to row0, "b" to row1,
        // "c" stays at row2.
        sheet = try await store.setCell(row: 0, col: 0, value: "b", for: sheet.id)
        sheet = try await store.setCell(row: 1, col: 0, value: "a", for: sheet.id)
        sheet = try await store.setCell(row: 2, col: 0, value: "c", for: sheet.id)
        // QueryEngine.rowsFailing/.valueSet hides rows whose display text
        // is NOT in `values` (SheetFilterCriteria.matchesValueSet: the
        // filter SHOWS the named set, hides everything else) - so
        // `values: ["b"]` hides row1 ("a") and row2 ("c") BY IDENTITY,
        // not row0 ("b") itself.
        let criteria = [SheetFilterColumn(columnIndex: 0, criteria: SheetFilterCriteria(kind: .valueSet, values: ["b"]))]
        sheet = try await store.applyFilter(criteria, for: sheet.id)
        XCTAssertEqual(sheet.effectiveFilterState.hiddenRows, [1, 2], "sanity: row1 (\"a\") and row2 (\"c\") are hidden before the sort - the filter SHOWS \"b\", hides everything else")

        let sorted = try await store.sortRange([SheetSortCondition(columnIndex: 0, ascending: true)], for: sheet.id)

        XCTAssertEqual(sorted.cellText(row: 0, col: 0), "a")
        XCTAssertEqual(sorted.cellText(row: 1, col: 0), "b")
        XCTAssertEqual(sorted.cellText(row: 2, col: 0), "c")
        // "a" (pre-sort row1, hidden) now lives at row0; "c" (pre-sort
        // row2, hidden) stays at row2. hiddenRows must follow those two
        // logical rows to their new positions, not stay pinned to the
        // pre-sort indices {1, 2} (which now hold "b" and "c").
        XCTAssertEqual(sorted.effectiveFilterState.hiddenRows, [0, 2])
    }

    // MARK: - defineNamedRange / undefineNamedRange

    func testDefineNamedRangeEmitsExactlyOneReceiptAndPersistsTheRange() async throws {
        let store = try await makeConnectedStore()
        let sheet = try await store.upsert(freshSheet(rows: 3, cols: 3))

        let updated = try await store.defineNamedRange(
            "MyRange", topLeftRow: 0, topLeftCol: 0, bottomRightRow: 1, bottomRightCol: 1, for: sheet.id
        )

        XCTAssertNotNil(updated.effectiveNamedRanges["MYRANGE"])
        let receipts = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptTypes(receipts).filter { $0 == SheetReceiptType.defineNamedRange.rawValue }.count, 1)
    }

    /// No-op zero-receipt path: undefining a name that was never defined.
    func testUndefineNamedRangeOfAnUndefinedNameIsANoOpEmittingNoReceiptAndNotPersisting() async throws {
        let store = try await makeConnectedStore()
        let sheet = try await store.upsert(freshSheet())
        let receiptsBefore = try await sheetReceipts(store, forSheet: sheet.id)

        let result = try await store.undefineNamedRange("NeverDefined", for: sheet.id)

        XCTAssertEqual(result.id, sheet.id)
        let receiptsAfter = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptsAfter.count, receiptsBefore.count, "undefining a name that was never defined must not emit a receipt")
    }

    // MARK: - addComment

    func testAddCommentEmitsExactlyOneReceiptWithTheCellAnchorPayload() async throws {
        let store = try await makeConnectedStore()
        let sheet = try await store.upsert(freshSheet())

        let updated = try await store.addComment(
            anchor: .cell(sheetID: sheet.id, row: 1, col: 2), author: "alice", text: "check this", for: sheet.id
        )

        XCTAssertEqual(updated.effectiveCommentThreads.count, 1)
        let receipts = try await sheetReceipts(store, forSheet: sheet.id)
        let commentReceipts = receipts.filter { $0.receiptType == SheetReceiptType.addComment.rawValue }
        XCTAssertEqual(commentReceipts.count, 1)
        XCTAssertEqual(commentReceipts.first?.payload["anchor"], .object([
            "kind": .string("cell"), "row": .number(1), "col": .number(2),
        ]))
    }

    // MARK: - Comment lifecycle: reply / resolve / delete (P2-0 item 13)

    func testReplyToCommentEmitsExactlyOneCommentRepliedReceiptAndAppendsTheMessage() async throws {
        let store = try await makeConnectedStore()
        var sheet = try await store.upsert(freshSheet())
        sheet = try await store.addComment(anchor: .cell(sheetID: sheet.id, row: 0, col: 0), author: "alice", text: "root", for: sheet.id)
        let threadID = try XCTUnwrap(sheet.effectiveCommentThreads.first?.id)

        let updated = try await store.replyToComment(threadID: threadID, author: "bob", text: "reply", for: sheet.id)

        XCTAssertEqual(updated.effectiveCommentThreads.first?.messages.count, 2)
        XCTAssertEqual(updated.effectiveCommentThreads.first?.messages.last?.text, "reply")
        let receipts = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptTypes(receipts).filter { $0 == SheetReceiptType.commentReplied.rawValue }.count, 1)
    }

    /// No-op zero-receipt path: replying to a thread id that doesn't exist.
    func testReplyToCommentOfAnUnknownThreadIDIsANoOpEmittingNoReceiptAndNotPersisting() async throws {
        let store = try await makeConnectedStore()
        let sheet = try await store.upsert(freshSheet())
        let receiptsBefore = try await sheetReceipts(store, forSheet: sheet.id)

        let result = try await store.replyToComment(threadID: UUID(), author: "bob", text: "reply", for: sheet.id)

        XCTAssertTrue(result.effectiveCommentThreads.isEmpty)
        let receiptsAfter = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptsAfter.count, receiptsBefore.count, "replying to an unknown thread must not emit a receipt")
    }

    func testResolveCommentEmitsExactlyOneCommentResolvedReceiptAndFlipsIsResolved() async throws {
        let store = try await makeConnectedStore()
        var sheet = try await store.upsert(freshSheet())
        sheet = try await store.addComment(anchor: .cell(sheetID: sheet.id, row: 0, col: 0), author: "alice", text: "root", for: sheet.id)
        let threadID = try XCTUnwrap(sheet.effectiveCommentThreads.first?.id)

        let updated = try await store.resolveComment(threadID: threadID, for: sheet.id)

        XCTAssertEqual(updated.effectiveCommentThreads.first?.isResolved, true)
        let receipts = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptTypes(receipts).filter { $0 == SheetReceiptType.commentResolved.rawValue }.count, 1)
    }

    /// No-op zero-receipt path: resolving an ALREADY-resolved thread.
    func testResolvingAnAlreadyResolvedCommentEmitsNoReceipt() async throws {
        let store = try await makeConnectedStore()
        var sheet = try await store.upsert(freshSheet())
        sheet = try await store.addComment(anchor: .cell(sheetID: sheet.id, row: 0, col: 0), author: "alice", text: "root", for: sheet.id)
        let threadID = try XCTUnwrap(sheet.effectiveCommentThreads.first?.id)
        sheet = try await store.resolveComment(threadID: threadID, for: sheet.id)
        let receiptsBefore = try await sheetReceipts(store, forSheet: sheet.id)

        _ = try await store.resolveComment(threadID: threadID, for: sheet.id)

        let receiptsAfter = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptsAfter.count, receiptsBefore.count, "resolving an already-resolved thread must not emit a second receipt")
    }

    /// No-op zero-receipt path: resolving a thread id that doesn't exist.
    func testResolveCommentOfAnUnknownThreadIDIsANoOpEmittingNoReceipt() async throws {
        let store = try await makeConnectedStore()
        let sheet = try await store.upsert(freshSheet())
        let receiptsBefore = try await sheetReceipts(store, forSheet: sheet.id)

        _ = try await store.resolveComment(threadID: UUID(), for: sheet.id)

        let receiptsAfter = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptsAfter.count, receiptsBefore.count)
    }

    func testDeleteCommentEmitsExactlyOneCommentDeletedReceiptAndRemovesTheThread() async throws {
        let store = try await makeConnectedStore()
        var sheet = try await store.upsert(freshSheet())
        sheet = try await store.addComment(anchor: .cell(sheetID: sheet.id, row: 0, col: 0), author: "alice", text: "root", for: sheet.id)
        let threadID = try XCTUnwrap(sheet.effectiveCommentThreads.first?.id)

        let updated = try await store.deleteComment(threadID: threadID, for: sheet.id)

        XCTAssertTrue(updated.effectiveCommentThreads.isEmpty)
        let receipts = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptTypes(receipts).filter { $0 == SheetReceiptType.commentDeleted.rawValue }.count, 1)
    }

    /// No-op zero-receipt path: deleting a thread id that doesn't exist.
    func testDeleteCommentOfAnUnknownThreadIDIsANoOpEmittingNoReceipt() async throws {
        let store = try await makeConnectedStore()
        let sheet = try await store.upsert(freshSheet())
        let receiptsBefore = try await sheetReceipts(store, forSheet: sheet.id)

        _ = try await store.deleteComment(threadID: UUID(), for: sheet.id)

        let receiptsAfter = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptsAfter.count, receiptsBefore.count)
    }

    // MARK: - Archive/trash/favorite family: happy path + a SUSPECTED
    // no-op-receipt defect shared by all six methods (see findings file)

    func testArchivingAnUnarchivedSheetEmitsExactlyOneReceiptAndPersists() async throws {
        let store = try await makeConnectedStore()
        let sheet = try await store.upsert(freshSheet())

        let archived = try await store.archive(sheet.id)

        XCTAssertTrue(archived.isArchived)
        let receipts = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptTypes(receipts).filter { $0 == SheetReceiptType.archive.rawValue }.count, 1)
        let reloaded = try await store.get(id: sheet.id)
        XCTAssertEqual(reloaded?.isArchived, true)
    }

    /// SUSPECTED CODE BUG: `archive(_:)` appends a `sheet_archived`
    /// receipt UNCONDITIONALLY, even when `wasAlreadyArchived` is true
    /// and nothing is mutated or persisted - violating doctrine rule 1 /
    /// plan decision 17 ("No receipt without a mutation... mandatory per
    /// store method, both directions"). See `SheetStore.archive(_:)`:
    /// the `if !wasArchived { ...; upsert }` guard skips the mutation,
    /// but `appendReceipt` runs outside that guard.
    func testArchivingAnAlreadyArchivedSheetEmitsNoReceiptAndDoesNotPersist() async throws {
        let store = try await makeConnectedStore()
        var sheet = try await store.upsert(freshSheet())
        sheet = try await store.archive(sheet.id)
        let receiptsBeforeSecondCall = try await sheetReceipts(store, forSheet: sheet.id)

        _ = try await store.archive(sheet.id)
        let receiptsAfterSecondCall = try await sheetReceipts(store, forSheet: sheet.id)

        XCTAssertEqual(receiptsAfterSecondCall.count, receiptsBeforeSecondCall.count)
    }

    func testUnarchivingASheetThatWasNeverArchivedEmitsNoReceipt() async throws {
        let store = try await makeConnectedStore()
        let sheet = try await store.upsert(freshSheet())
        let receiptsBefore = try await sheetReceipts(store, forSheet: sheet.id)

        _ = try await store.unarchive(sheet.id)

        let receiptsAfter = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptsAfter.count, receiptsBefore.count)
    }

    func testTrashingAnAlreadyTrashedSheetEmitsNoReceipt() async throws {
        let store = try await makeConnectedStore()
        var sheet = try await store.upsert(freshSheet())
        sheet = try await store.trash(sheet.id)
        let receiptsBefore = try await sheetReceipts(store, forSheet: sheet.id)

        _ = try await store.trash(sheet.id)

        let receiptsAfter = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptsAfter.count, receiptsBefore.count)
    }

    func testRestoringASheetThatWasNeverTrashedEmitsNoReceipt() async throws {
        let store = try await makeConnectedStore()
        let sheet = try await store.upsert(freshSheet())
        let receiptsBefore = try await sheetReceipts(store, forSheet: sheet.id)

        _ = try await store.restore(sheet.id)

        let receiptsAfter = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptsAfter.count, receiptsBefore.count)
    }

    func testFavoritingAnAlreadyFavoriteSheetEmitsNoReceipt() async throws {
        let store = try await makeConnectedStore()
        var sheet = try await store.upsert(freshSheet())
        sheet = try await store.favorite(sheet.id)
        let receiptsBefore = try await sheetReceipts(store, forSheet: sheet.id)

        _ = try await store.favorite(sheet.id)

        let receiptsAfter = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptsAfter.count, receiptsBefore.count)
    }

    func testUnfavoritingASheetThatWasNeverFavoriteEmitsNoReceipt() async throws {
        let store = try await makeConnectedStore()
        let sheet = try await store.upsert(freshSheet())
        let receiptsBefore = try await sheetReceipts(store, forSheet: sheet.id)

        _ = try await store.unfavorite(sheet.id)

        let receiptsAfter = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptsAfter.count, receiptsBefore.count)
    }

    // MARK: - Tags

    func testSetTagsEmitsExactlyOneReceiptAndPersistsTheNormalizedList() async throws {
        let store = try await makeConnectedStore()
        let sheet = try await store.upsert(freshSheet())

        let updated = try await store.setTags(["Alpha", " beta ", "alpha"], for: sheet.id)

        XCTAssertEqual(updated.tags, ["alpha", "beta"])
        let receipts = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptTypes(receipts).filter { $0 == SheetReceiptType.tagChange.rawValue }.count, 1)
    }

    /// SUSPECTED CODE BUG: `addTag(_:to:)` appends a `sheet_tag_added`
    /// receipt even on the `wasAlreadyPresent: true` early-return branch,
    /// which performs no mutation and no persistence write.
    func testAddingATagThatIsAlreadyPresentEmitsNoReceipt() async throws {
        let store = try await makeConnectedStore()
        var sheet = try await store.upsert(freshSheet())
        sheet = try await store.addTag("dup", to: sheet.id)
        let receiptsBefore = try await sheetReceipts(store, forSheet: sheet.id)

        _ = try await store.addTag("dup", to: sheet.id)

        let receiptsAfter = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptsAfter.count, receiptsBefore.count)
    }

    /// SUSPECTED CODE BUG: `removeTag(_:from:)`'s not-present branch has
    /// the same shape - it appends a receipt on a path that mutates
    /// nothing.
    func testRemovingATagThatIsNotPresentEmitsNoReceipt() async throws {
        let store = try await makeConnectedStore()
        let sheet = try await store.upsert(freshSheet())
        let receiptsBefore = try await sheetReceipts(store, forSheet: sheet.id)

        _ = try await store.removeTag("never-added", from: sheet.id)

        let receiptsAfter = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptsAfter.count, receiptsBefore.count)
    }

    func testAddTagEmitsExactlyOneReceiptOnAGenuinelyNewTag() async throws {
        let store = try await makeConnectedStore()
        let sheet = try await store.upsert(freshSheet())

        let updated = try await store.addTag("new-tag", to: sheet.id)

        XCTAssertTrue(updated.tags.contains("new-tag"))
        let receipts = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptTypes(receipts).filter { $0 == SheetReceiptType.tagAdded.rawValue }.count, 1)
    }
}
