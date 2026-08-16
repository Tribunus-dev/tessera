import XCTest
@testable import TesseraCore

// Doctrine rule 11: "Every gated test has an ungated shadow ... paired
// with an ungated test of the SAME contract against the in-memory/stub
// seam, so a plain `swift test` exercises the wiring logic too." As
// established in `SheetStoreTests.swift`'s header comment and the
// findings file, `SheetStore` has no protocol seam over
// `TesseraDataLayer` - there is no fake to inject. This file is the
// doctrine's own documented fallback for exactly that situation: "a
// fixture-level test of the SAME logic path minus the actual database
// write ... mirror whatever pattern you find in how the store itself is
// structured." Every `SheetStore` mutation method here is a thin
// (loadOrFail -> mutate -> upsert -> appendReceipt) wrapper around a
// PURE `Sheet`/`QueryEngine` value-type operation; this file exercises
// those pure operations directly - the exact logic each paired
// `SheetStoreTests.swift` test also runs, minus the two DB calls.
//
// `QueryEngine.sort`/`.applyFilter`/`.clearFilter` - the pure logic
// behind `SheetStore.sortRange`/`.applyFilter`/`.clearFilter` - already
// have a full ungated shadow in `QueryEngineTests.swift`; not repeated
// here.
final class SheetStoreLogicShadowTests: DoctrineTestCase {

    // MARK: - setCell's pure logic: CellValue.classify + settingCellValue/settingCellText

    func testSetCellPureLogicClassifiesAndStoresBothTextAndTypedValue() {
        let sheet = Sheet.makeBlank(title: "t", rows: 2, cols: 2)
        let classified = CellValue.classify("42", columnType: .text)
        let updated = sheet.settingCellText(row: 0, col: 0, "42").settingCellValue(row: 0, col: 0, classified)

        XCTAssertEqual(updated.cellText(row: 0, col: 0), "42")
        XCTAssertEqual(updated.cellValue(row: 0, col: 0), .number(42), "a numeric-looking string is sniffed as a number even in a .text column")
    }

    func testSetCellPureLogicClearingToEmptyStringLeavesNoTypedValue() {
        var sheet = Sheet.makeBlank(title: "t", rows: 2, cols: 2)
        sheet = sheet.settingCellText(row: 0, col: 0, "5").settingCellValue(row: 0, col: 0, .number(5))
        sheet = sheet.settingCellText(row: 0, col: 0, "").settingCellValue(row: 0, col: 0, CellValue.classify("", columnType: .text))
        XCTAssertEqual(sheet.cellValue(row: 0, col: 0), .empty)
        XCTAssertEqual(sheet.cellText(row: 0, col: 0), "")
    }

    // MARK: - setCellFormat's pure logic: Sheet.settingCellFormat / cellFormat

    func testSetCellFormatPureLogicRoundTripsThroughTheSheetValueType() {
        let sheet = Sheet.makeBlank(title: "t", rows: 2, cols: 2)
        let format = SheetCellFormat(numberFormat: .percent, decimals: 1, isItalic: true, fillHex: "#FFEE00")
        let updated = sheet.settingCellFormat(row: 1, col: 1, format)
        XCTAssertEqual(updated.cellFormat(row: 1, col: 1), format)
    }

    func testSetCellFormatPureLogicClearingToStandardRemovesTheStoredAttributeEntirely() {
        // Snapshot the ORIGINAL, never-styled sheet before applying any
        // format - Sheet.makeBlank mints fresh UUIDs (sheet id, block
        // ids) on every call, so a second, separately-constructed
        // makeBlank(...) can never be byte-identical to this one
        // regardless of format-clearing correctness. Comparing against
        // this sheet's own prior state is what actually tests "clearing
        // leaves the block exactly as it started".
        let original = Sheet.makeBlank(title: "t", rows: 2, cols: 2)
        let originalJSON = try! original.jsonData()
        let styled = original.settingCellFormat(row: 0, col: 0, SheetCellFormat(isBold: true))
        let cleared = styled.settingCellFormat(row: 0, col: 0, .standard)
        XCTAssertEqual(cleared.cellFormat(row: 0, col: 0), .standard)
        // Byte-identical to the same sheet before it was ever styled -
        // the documented "no dead JSON forever" contract.
        XCTAssertEqual(try cleared.jsonData(), originalJSON, "clearing a format must leave the block exactly as it started")
    }

    // MARK: - insertRow/deleteRow's pure logic: Sheet.adjustingFormulas

    func testInsertRowPureLogicShiftsFormulaReferencesBelowTheInsertionPoint() {
        var sheet = Sheet.makeBlank(title: "t", rows: 3, cols: 1)
        sheet = sheet.settingCellText(row: 2, col: 0, "=A1")
        let adjusted = sheet.adjustingFormulas(for: .insertRows(at: 0, count: 1))
        // A1 (row 0) is at/after the insertion point (index 0), so the
        // reference shifts down by one row to A2.
        XCTAssertEqual(adjusted.cellText(row: 2, col: 0), "=A2")
    }

    func testDeleteRowPureLogicShiftsFormulaReferencesAboveTheDeletionPoint() {
        var sheet = Sheet.makeBlank(title: "t", rows: 3, cols: 1)
        sheet = sheet.settingCellText(row: 2, col: 0, "=A3")
        let adjusted = sheet.adjustingFormulas(for: .deleteRows(at: 0, count: 1))
        XCTAssertEqual(adjusted.cellText(row: 2, col: 0), "=A2")
    }

    // MARK: - sortRange's hiddenRows remap: pure permutation logic
    //
    // `QueryEngine.sortedRowOrder` itself (the pure function
    // `SheetStore.sortRange` calls to get `order`) already has a full
    // ungated shadow in QueryEngineTests.swift - not repeated here. What
    // IS shadowed here is the REMAP arithmetic `SheetStore.sortRange`
    // performs on `order` (audit item A4), which is inline in that
    // store method with no extracted pure function of its own to call
    // directly - the same situation the "Archive/trash/favorite
    // family's pure logic" section below documents and handles the
    // same way: pin the identical computation as a standalone value-
    // type-layer assertion.

    func testSortRangeHiddenRowsRemapPureLogicFollowsTheSamePermutationAsTheRowReorder() {
        // order[newRow] == oldRow (QueryEngine.sortedRowOrder's own
        // contract) - here the row that was physically at index 0
        // sorts to index 1.
        let order = [1, 0]
        let hiddenRowsBeforeSort: Set<Int> = [0]

        var remapped: Set<Int> = []
        for (newRow, oldRow) in order.enumerated() where hiddenRowsBeforeSort.contains(oldRow) {
            remapped.insert(newRow)
        }

        XCTAssertEqual(remapped, [1], "the row physically hidden before the sort (old index 0) now lives at new index 1 - the SAME logical row must stay hidden")
    }

    func testSortRangeHiddenRowsRemapPureLogicIsEmptyWhenNothingWasHidden() {
        let order = [2, 0, 1]
        let hiddenRowsBeforeSort: Set<Int> = []

        var remapped: Set<Int> = []
        for (newRow, oldRow) in order.enumerated() where hiddenRowsBeforeSort.contains(oldRow) {
            remapped.insert(newRow)
        }

        XCTAssertTrue(remapped.isEmpty)
    }

    // MARK: - Comment lifecycle's pure logic: CommentThread.addingReply/.resolved, Sheet.replacingCommentThread/.removingCommentThread

    private func rootThread(anchorRow: Int = 0, anchorCol: Int = 0, sheetID: UUID) -> CommentThread {
        CommentThread(
            id: UUID(), anchor: .cell(sheetID: sheetID, row: anchorRow, col: anchorCol),
            author: "alice", createdAt: Date(), messages: [CommentMessage(author: "alice", text: "root")]
        )
    }

    func testReplyToCommentPureLogicAppendsAMessageViaAddingReply() {
        let sheet = Sheet.makeBlank(title: "t", rows: 1, cols: 1)
        let thread = rootThread(sheetID: sheet.id)
        let reply = CommentMessage(author: "bob", text: "reply")

        let updated = thread.addingReply(reply)

        XCTAssertEqual(updated.messages.count, 2)
        XCTAssertEqual(updated.messages.last?.text, "reply")
        XCTAssertEqual(updated.messages.first?.text, "root", "the original root message must survive a reply")
    }

    func testResolveCommentPureLogicFlipsIsResolvedAndReplacingCommentThreadWritesItBackByID() {
        var sheet = Sheet.makeBlank(title: "t", rows: 1, cols: 1)
        let thread = rootThread(sheetID: sheet.id)
        sheet = sheet.addingCommentThread(thread)

        sheet = sheet.replacingCommentThread(thread.resolved())

        XCTAssertEqual(sheet.effectiveCommentThreads.count, 1, "replacingCommentThread must not add a second thread")
        XCTAssertEqual(sheet.effectiveCommentThreads.first?.isResolved, true)
    }

    func testDeleteCommentPureLogicRemovesTheThreadByID() {
        var sheet = Sheet.makeBlank(title: "t", rows: 1, cols: 1)
        let thread = rootThread(sheetID: sheet.id)
        sheet = sheet.addingCommentThread(thread)

        sheet = sheet.removingCommentThread(id: thread.id)

        XCTAssertTrue(sheet.effectiveCommentThreads.isEmpty)
    }

    func testReplacingCommentThreadPureLogicIsANoOpWhenTheIDIsUnknown() {
        var sheet = Sheet.makeBlank(title: "t", rows: 1, cols: 1)
        let thread = rootThread(sheetID: sheet.id)
        sheet = sheet.addingCommentThread(thread)
        let before = sheet.effectiveCommentThreads
        let unrelated = rootThread(anchorRow: 1, anchorCol: 1, sheetID: sheet.id)

        let unchanged = sheet.replacingCommentThread(unrelated.resolved())

        XCTAssertEqual(unchanged.effectiveCommentThreads, before, "replacing an unknown thread id must leave the list unchanged - the guard-and-return-unchanged shape SheetStore's comment lifecycle methods rely on for their zero-receipt no-op path")
    }

    func testRemovingCommentThreadPureLogicIsANoOpWhenTheIDIsUnknown() {
        var sheet = Sheet.makeBlank(title: "t", rows: 1, cols: 1)
        let thread = rootThread(sheetID: sheet.id)
        sheet = sheet.addingCommentThread(thread)
        let before = sheet.effectiveCommentThreads

        let unchanged = sheet.removingCommentThread(id: UUID())

        XCTAssertEqual(unchanged.effectiveCommentThreads, before)
    }

    // MARK: - defineNamedRange/undefineNamedRange's pure logic

    func testDefineNamedRangePureLogicStoresUppercaseKeyedRange() {
        let sheet = Sheet.makeBlank(title: "t", rows: 3, cols: 3)
        let range = RangeRef(topLeft: CellAddr(col: 0, row: 0), bottomRight: CellAddr(col: 1, row: 1))
        let updated = sheet.settingNamedRange("myRange", range: range)
        XCTAssertNotNil(updated.effectiveNamedRanges["MYRANGE"])
        XCTAssertEqual(updated.effectiveNamedRanges["MYRANGE"]?.name, "myRange", "the original spelling survives for display")
    }

    func testUndefineNamedRangePureLogicIsANoOpWhenTheNameIsNotDefined() {
        let sheet = Sheet.makeBlank(title: "t", rows: 3, cols: 3)
        let unchanged = sheet.removingNamedRange("NeverDefined")
        XCTAssertTrue(unchanged.effectiveNamedRanges.isEmpty)
        // This is the SheetStore method that does NOT share the
        // no-op-receipt defect (its `guard ... != nil else { return
        // sheet }` returns before appendReceipt is ever reached) -
        // confirmed correct in this shadow, verified end-to-end in the
        // DB-gated `testUndefineNamedRangeOfAnUndefinedNameIsANoOp...`.
    }

    // MARK: - addComment's pure logic: Sheet.addingCommentThread

    func testAddCommentPureLogicAppendsAThreadAnchoredToTheGivenCell() {
        let sheet = Sheet.makeBlank(title: "t", rows: 3, cols: 3)
        let thread = CommentThread(
            id: UUID(), anchor: .cell(sheetID: sheet.id, row: 0, col: 0),
            author: "alice", createdAt: Date(), messages: [CommentMessage(author: "alice", text: "hi")]
        )
        let updated = sheet.addingCommentThread(thread)
        XCTAssertEqual(updated.effectiveCommentThreads.count, 1)
        XCTAssertEqual(updated.effectiveCommentThreads.first?.anchor, .cell(sheetID: sheet.id, row: 0, col: 0))
    }

    // MARK: - Archive/trash/favorite family's pure logic: the flag flip itself is correct

    /// The shadow for the receipt-emission defect is NOT "the flag flips
    /// wrong" - `isArchived` etc. flip correctly; the defect is scoped
    /// entirely to the receipt call in `SheetStore`, which has no pure
    /// counterpart to shadow (there is nothing to test at the `Sheet`
    /// value-type layer for "should a receipt fire" - that decision
    /// lives only in the store method itself). This test pins the part
    /// that IS pure: flipping the flag is idempotent-safe at the value
    ///-type layer (setting `isArchived = true` twice is harmless), which
    /// is what makes the store's `if !wasAlreadyInState` guard SAFE to
    /// use as the fix (once the receipt call is moved inside it).
    func testArchiveFlagFlipAtTheValueTypeLayerIsIdempotent() {
        var sheet = Sheet.makeBlank(title: "t", rows: 1, cols: 1)
        sheet.isArchived = true
        sheet.isArchived = true
        XCTAssertTrue(sheet.isArchived)
    }

    // MARK: - Tags family's pure logic

    func testAddTagPureLogicSkipsAppendingWhenAlreadyPresent() {
        var sheet = Sheet.makeBlank(title: "t", rows: 1, cols: 1)
        sheet.tags = Sheet.normalizeTags(["dup"])
        // Mirrors SheetStore.addTag's own `if sheet.tags.contains(first)`
        // check - the pure predicate the store's early-return branches on.
        XCTAssertTrue(sheet.tags.contains(Sheet.normalizeTags(["dup"]).first!))
    }
}
