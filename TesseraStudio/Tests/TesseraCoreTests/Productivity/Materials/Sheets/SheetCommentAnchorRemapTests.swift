import XCTest
@testable import TesseraCore

// Contract source: studio-expansion-design-refinement-2026-08-14.md
// section 4, Calc cluster, item "1.22 cell/slide comments": "One thread
// model: extend Productivity/Comments.swift with a polymorphic
// CommentAnchor (textRange | block | cell(sheetID,row,col) | slide) and
// a decode fallback for legacy anchors... Test: legacy fixture decodes
// to .textRange; cell comments survive row/col insertion via anchor
// remap." Scoped here to the `.cell` case and its remap, which is the
// Sheets-cluster-owned half of this polymorphic type (`.textRange`/
// `.block`/`.slide` are the Writer/Slides clusters' concern).
final class SheetCommentAnchorRemapTests: DoctrineTestCase {

    // MARK: - Legacy decode: flat anchorBlockID/anchorRangeStart/anchorRangeEnd -> .textRange

    func testLegacyFlatAnchorShapeDecodesToTextRange() throws {
        let blockID = UUID()
        let threadID = UUID()
        let json = """
        {
            "id": "\(threadID.uuidString)",
            "author": "alice",
            "createdAt": "2024-01-01T00:00:00Z",
            "messages": [],
            "anchorBlockID": "\(blockID.uuidString)",
            "anchorRangeStart": 5,
            "anchorRangeEnd": 12
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let thread = try decoder.decode(CommentThread.self, from: json)

        XCTAssertEqual(thread.anchor, .textRange(blockID: blockID, start: 5, end: 12))
        XCTAssertEqual(thread.id, threadID)
        XCTAssertFalse(thread.isResolved, "isResolved must default to false when absent from legacy JSON")
    }

    /// Current (post-1.22) shape round-trips through encode/decode - a
    /// safer way to pin "the current shape decodes" than hand-writing
    /// the nested `anchor` object's exact JSON layout (that layout comes
    /// from `CommentAnchor`'s Swift-synthesized `Codable`, which this
    /// test does not need to predict by hand).
    func testCurrentNestedAnchorShapeRoundTripsThroughEncodeDecode() throws {
        let sheetID = UUID()
        let original = CommentThread(
            id: UUID(), anchor: .cell(sheetID: sheetID, row: 3, col: 4),
            author: "bob", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            messages: [], isResolved: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(CommentThread.self, from: data)

        XCTAssertEqual(decoded.anchor, .cell(sheetID: sheetID, row: 3, col: 4))
        XCTAssertTrue(decoded.isResolved)
        XCTAssertEqual(decoded.id, original.id)
    }

    // MARK: - .cell anchor remap on row/column insertion

    func testCellAnchorAtOrBelowTheInsertionPointShiftsDownByCount() {
        let sheetID = UUID()
        let anchor = CommentAnchor.cell(sheetID: sheetID, row: 5, col: 2)
        let remapped = anchor.remapped(afterRowInsertedAt: 2, count: 3, onSheet: sheetID)
        XCTAssertEqual(remapped, .cell(sheetID: sheetID, row: 8, col: 2))
    }

    func testCellAnchorAboveTheInsertionPointIsUnaffected() {
        let sheetID = UUID()
        let anchor = CommentAnchor.cell(sheetID: sheetID, row: 1, col: 2)
        let remapped = anchor.remapped(afterRowInsertedAt: 5, count: 3, onSheet: sheetID)
        XCTAssertEqual(remapped, anchor)
    }

    func testCellAnchorOnADifferentSheetIsNeverRemapped() {
        let thisSheet = UUID()
        let otherSheet = UUID()
        let anchor = CommentAnchor.cell(sheetID: otherSheet, row: 5, col: 2)
        let remapped = anchor.remapped(afterRowInsertedAt: 0, count: 10, onSheet: thisSheet)
        XCTAssertEqual(remapped, anchor, "a row insertion on one sheet must never perturb another sheet's comments")
    }

    func testCellAnchorColumnInsertionCounterpartShiftsRightByCount() {
        let sheetID = UUID()
        let anchor = CommentAnchor.cell(sheetID: sheetID, row: 5, col: 2)
        let remapped = anchor.remapped(afterColumnInsertedAt: 2, count: 1, onSheet: sheetID)
        XCTAssertEqual(remapped, .cell(sheetID: sheetID, row: 5, col: 3))
    }

    func testNonCellAnchorKindsAreNeverAffectedByRowOrColumnRemap() {
        let blockID = UUID()
        let textRange = CommentAnchor.textRange(blockID: blockID, start: 0, end: 5)
        let block = CommentAnchor.block(blockID)
        let slide = CommentAnchor.slide(UUID())
        let anySheet = UUID()

        for anchor in [textRange, block, slide] {
            XCTAssertEqual(anchor.remapped(afterRowInsertedAt: 0, count: 5, onSheet: anySheet), anchor)
            XCTAssertEqual(anchor.remapped(afterColumnInsertedAt: 0, count: 5, onSheet: anySheet), anchor)
        }
    }

    // MARK: - End-to-end: SheetStore-style cell comment survives a row insertion (pure-logic shadow)

    func testCellCommentThreadAnchorSurvivesARowInsertionViaRemap() {
        let sheet = Sheet.makeBlank(title: "t", rows: 5, cols: 2)
        let thread = CommentThread(
            id: UUID(), anchor: .cell(sheetID: sheet.id, row: 3, col: 0),
            author: "alice", createdAt: Date(), messages: [CommentMessage(author: "alice", text: "note")]
        )
        let withComment = sheet.addingCommentThread(thread)

        // Simulate the row-insertion remap a store-level insertRow(at: 1)
        // would apply to every .cell-anchored thread on this sheet.
        let remappedThreads = withComment.effectiveCommentThreads.map { t in
            CommentThread(
                id: t.id, anchor: t.anchor.remapped(afterRowInsertedAt: 1, count: 1, onSheet: sheet.id),
                author: t.author, createdAt: t.createdAt, messages: t.messages, isResolved: t.isResolved
            )
        }

        XCTAssertEqual(remappedThreads.first?.anchor, .cell(sheetID: sheet.id, row: 4, col: 0))
    }
}
