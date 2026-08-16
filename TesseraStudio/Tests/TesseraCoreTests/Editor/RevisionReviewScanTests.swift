import XCTest
@testable import TesseraCore

// MARK: - RevisionReviewScanTests
//
// Contract: sota-p2-core-report.md section 2.9's design contract - "Zero
// new data model - pure scan of the AST grouped by revisionID (isMove
// pairs = one 'moved' row)" - plus this track's own tests list: "each
// revisionID listed exactly once (move = one row)". Fully testable
// without a live DB or a real SwiftUI host, per testing-doctrine.md and
// the track brief ("Pure logic (the AST-scan-and-group step) should be
// fully testable ... separate that logic from the View body").

final class RevisionReviewScanTests: DoctrineTestCase {

    // MARK: - Fixture helpers

    private func insertionBlock(
        id: UUID = UUID(), author: String, timestamp: Double, text: String, revisionGroup: UUID? = nil
    ) -> Block {
        var attrs: [String: AnyCodable] = ["author": .string(author), "timestamp": .number(timestamp)]
        if let revisionGroup { attrs["revisionID"] = .string(revisionGroup.uuidString) }
        return Block(id: id, type: .trackInsertion, attributes: attrs, content: [InlineRun(text: text)])
    }

    private func deletionBlock(
        id: UUID = UUID(), author: String, timestamp: Double, text: String, revisionGroup: UUID? = nil
    ) -> Block {
        var attrs: [String: AnyCodable] = ["author": .string(author), "timestamp": .number(timestamp)]
        if let revisionGroup { attrs["revisionID"] = .string(revisionGroup.uuidString) }
        return Block(id: id, type: .trackDeletion, attributes: attrs, content: [InlineRun(text: text)])
    }

    // MARK: - Grouping

    func testEachRevisionIDListedExactlyOnceAndAMovePairCollapsesToOneRow() {
        let aID = UUID()
        let bID = UUID()
        let moveGroup = UUID()
        let insertPart = insertionBlock(author: "alice", timestamp: 1, text: "moved-in", revisionGroup: moveGroup)
        let deletePart = deletionBlock(author: "alice", timestamp: 1, text: "moved-out", revisionGroup: moveGroup)
        let a = insertionBlock(id: aID, author: "alice", timestamp: 10, text: "hello")
        let b = deletionBlock(id: bID, author: "bob", timestamp: 20, text: "goodbye")

        var ast = DocumentAST()
        for block in [a, b, insertPart, deletePart] { ast.blocks[block.id] = block }
        ast.rootChildren = [aID, bID, insertPart.id, deletePart.id]

        let rows = RevisionReviewScan.scan(ast)

        // 4 track-change blocks, but only 3 DISTINCT revisionIDs - the
        // move pair must collapse to exactly one row.
        XCTAssertEqual(rows.count, 3, "a move pair must collapse to one row, not two")
        XCTAssertEqual(Set(rows.map(\.id)), [aID, bID, moveGroup])

        let moveRow = rows.first { $0.id == moveGroup }
        XCTAssertEqual(moveRow?.kind, .moved)
        XCTAssertEqual(moveRow?.author, "alice")

        let insertionRow = rows.first { $0.id == aID }
        XCTAssertEqual(insertionRow?.kind, .insertion)
        XCTAssertEqual(insertionRow?.author, "alice")

        let deletionRow = rows.first { $0.id == bID }
        XCTAssertEqual(deletionRow?.kind, .deletion)
        XCTAssertEqual(deletionRow?.author, "bob")

        for row in rows { XCTAssertEqual(row.status, .pending) }
    }

    func testEmptyDocumentScansToNoRows() {
        XCTAssertTrue(RevisionReviewScan.scan(.empty).isEmpty)
    }

    func testPlainParagraphsAreNotScanned() {
        var ast = DocumentAST()
        let id = UUID()
        ast.blocks[id] = Block(id: id, type: .paragraph, content: [InlineRun(text: "already resolved")])
        ast.rootChildren = [id]
        XCTAssertTrue(RevisionReviewScan.scan(ast).isEmpty, "resolved/plain blocks must not surface as pending rows")
    }

    func testSingleBlockRevisionIDIsItsOwnBlockID() {
        // Matches RevisionController.revisionID(for:)'s own contract: a
        // block with no `attributes["revisionID"]` is its own revision id.
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = insertionBlock(id: id, author: "alice", timestamp: 1, text: "solo")
        ast.rootChildren = [id]
        XCTAssertEqual(RevisionReviewScan.scan(ast).first?.id, id)
    }

    // MARK: - Excerpt

    func testExcerptTruncatesLongContentWithAsciiEllipsis() {
        let longText = String(repeating: "x", count: 200)
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = insertionBlock(id: id, author: "alice", timestamp: 1, text: longText)
        ast.rootChildren = [id]

        let row = RevisionReviewScan.scan(ast).first
        XCTAssertEqual(row?.excerpt.count, 83, "80 kept chars + a 3-char ASCII ellipsis")
        XCTAssertTrue(row?.excerpt.hasSuffix("...") ?? false)
    }

    func testExcerptOfShortContentIsNotTruncated() {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = insertionBlock(id: id, author: "alice", timestamp: 1, text: "short")
        ast.rootChildren = [id]
        XCTAssertEqual(RevisionReviewScan.scan(ast).first?.excerpt, "short")
    }

    // MARK: - Ordering (deterministic, per testing-doctrine.md rule 4)

    func testOrderIsNewestTimestampFirst() {
        let older = insertionBlock(author: "alice", timestamp: 1, text: "older")
        let newer = insertionBlock(author: "bob", timestamp: 100, text: "newer")
        var ast = DocumentAST()
        ast.blocks[older.id] = older
        ast.blocks[newer.id] = newer
        ast.rootChildren = [older.id, newer.id]

        let rows = RevisionReviewScan.scan(ast)
        XCTAssertEqual(rows.map(\.id), [newer.id, older.id])
    }

    func testRowsWithNoTimestampSortLast() {
        let timestamped = insertionBlock(author: "alice", timestamp: 1, text: "has-time")
        let untimestamped = Block(
            id: UUID(), type: .trackInsertion,
            attributes: ["author": .string("bob")], content: [InlineRun(text: "no-time")]
        )
        var ast = DocumentAST()
        ast.blocks[timestamped.id] = timestamped
        ast.blocks[untimestamped.id] = untimestamped
        ast.rootChildren = [timestamped.id, untimestamped.id]

        let rows = RevisionReviewScan.scan(ast)
        XCTAssertEqual(rows.map(\.id), [timestamped.id, untimestamped.id])
    }
}
