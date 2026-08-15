import XCTest
@testable import TesseraCore

/// `CommentAnchor` (P1 1.22): the polymorphic anchor (textRange | block |
/// cell | slide) that lets `CommentThread` address a Writer text range, a
/// Calc cell, or an Impress slide with one thread model.
final class CommentsTests: XCTestCase {

    // MARK: - Legacy anchor decode fallback

    func testLegacyFlatAnchorDecodesToTextRange() throws {
        // Threads written before CommentAnchor existed have no "anchor"
        // key at all - the anchor was always an implicit textRange,
        // spelled out as three flat top-level keys (the same three keys
        // BlockType.comment blocks still use in Block.attributes). The
        // decoder must recover exactly that shape, not throw.
        let threadID = UUID()
        let blockID = UUID()
        let messageID = UUID()
        let json = """
        {
            "id": "\(threadID.uuidString)",
            "anchorBlockID": "\(blockID.uuidString)",
            "anchorRangeStart": 4,
            "anchorRangeEnd": 12,
            "author": "author-guid-1",
            "createdAt": "2026-01-01T00:00:00Z",
            "messages": [
                {
                    "id": "\(messageID.uuidString)",
                    "author": "author-guid-1",
                    "text": "Looks good to me",
                    "createdAt": "2026-01-01T00:00:00Z"
                }
            ],
            "isResolved": false
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let thread = try decoder.decode(CommentThread.self, from: Data(json.utf8))

        XCTAssertEqual(thread.id, threadID)
        XCTAssertEqual(thread.anchor, .textRange(blockID: blockID, start: 4, end: 12))
        XCTAssertEqual(thread.author, "author-guid-1")
        XCTAssertFalse(thread.isResolved)

        // The legacy fixture's message also predates parentMessageID /
        // mentions - both must default rather than fail to decode.
        XCTAssertEqual(thread.messages.count, 1)
        XCTAssertNil(thread.messages[0].parentMessageID)
        XCTAssertTrue(thread.messages[0].mentions.isEmpty)
    }

    // MARK: - New anchor shape round-trips

    func testCellAnchorRoundTripsThroughEncodeDecode() throws {
        let sheetID = UUID()
        let thread = CommentThread(
            id: UUID(),
            anchor: .cell(sheetID: sheetID, row: 2, col: 3),
            author: "author-guid-2",
            createdAt: Date(),
            messages: [CommentMessage(author: "author-guid-2", text: "what does this total assume?")]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CommentThread.self, from: encoder.encode(thread))

        XCTAssertEqual(decoded.anchor, .cell(sheetID: sheetID, row: 2, col: 3))
        XCTAssertEqual(decoded.messages.first?.text, "what does this total assume?")
    }

    func testSlideAnchorRoundTrips() throws {
        let slideID = UUID()
        let thread = CommentThread(
            id: UUID(), anchor: .slide(slideID), author: "author-guid-3",
            createdAt: Date(), messages: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CommentThread.self, from: encoder.encode(thread))
        XCTAssertEqual(decoded.anchor, .slide(slideID))
    }

    // MARK: - Threading + mentions

    func testReplyChainsToAnArbitraryParentMessage() throws {
        let root = CommentMessage(author: "a", text: "root")
        let firstReply = CommentMessage(author: "b", text: "first reply", parentMessageID: root.id)
        // A reply to the FIRST REPLY, not to the root - a genuine chain,
        // not a flat "everyone replies to message 0" star.
        let secondReply = CommentMessage(author: "a", text: "second reply", parentMessageID: firstReply.id)

        let thread = CommentThread(
            id: UUID(), anchor: .block(UUID()), author: "a",
            createdAt: Date(), messages: [root, firstReply, secondReply]
        )

        XCTAssertNil(thread.messages[0].parentMessageID)
        XCTAssertEqual(thread.messages[1].parentMessageID, root.id)
        XCTAssertEqual(thread.messages[2].parentMessageID, firstReply.id)
    }

    func testMentionOffsetsRoundTrip() throws {
        let personID = UUID().uuidString
        let message = CommentMessage(
            author: "a",
            text: "hey @bob take a look",
            mentions: [MentionOffset(start: 4, end: 8, personID: personID)]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CommentMessage.self, from: encoder.encode(message))

        XCTAssertEqual(decoded.mentions.count, 1)
        XCTAssertEqual(decoded.mentions[0].start, 4)
        XCTAssertEqual(decoded.mentions[0].end, 8)
        XCTAssertEqual(decoded.mentions[0].personID, personID)
    }

    // MARK: - Cell anchor remap on row insertion

    func testCellAnchorRemapsOnRowInsertion() {
        let sheetA = UUID()
        let sheetB = UUID()

        // At the insertion point: shifts down by the inserted count.
        let atInsertion = CommentAnchor.cell(sheetID: sheetA, row: 2, col: 3)
        XCTAssertEqual(
            atInsertion.remapped(afterRowInsertedAt: 2, count: 1, onSheet: sheetA),
            .cell(sheetID: sheetA, row: 3, col: 3)
        )

        // Above the insertion point: untouched.
        let aboveInsertion = CommentAnchor.cell(sheetID: sheetA, row: 0, col: 1)
        XCTAssertEqual(
            aboveInsertion.remapped(afterRowInsertedAt: 2, count: 1, onSheet: sheetA),
            aboveInsertion
        )

        // Same row, different sheet: never touched, even though the row
        // number matches the insertion point exactly.
        let otherSheet = CommentAnchor.cell(sheetID: sheetB, row: 2, col: 3)
        XCTAssertEqual(
            otherSheet.remapped(afterRowInsertedAt: 2, count: 1, onSheet: sheetA),
            otherSheet
        )

        // A multi-row insertion shifts by the full count.
        XCTAssertEqual(
            atInsertion.remapped(afterRowInsertedAt: 2, count: 5, onSheet: sheetA),
            .cell(sheetID: sheetA, row: 7, col: 3)
        )

        // Non-cell anchors are never touched by a cell remap.
        let textAnchor = CommentAnchor.textRange(blockID: UUID(), start: 0, end: 1)
        XCTAssertEqual(
            textAnchor.remapped(afterRowInsertedAt: 0, count: 1, onSheet: sheetA),
            textAnchor
        )
    }

    func testCellAnchorRemapsOnColumnInsertion() {
        let sheetA = UUID()
        let sheetB = UUID()

        let atInsertion = CommentAnchor.cell(sheetID: sheetA, row: 5, col: 2)
        XCTAssertEqual(
            atInsertion.remapped(afterColumnInsertedAt: 2, count: 1, onSheet: sheetA),
            .cell(sheetID: sheetA, row: 5, col: 3)
        )

        let beforeInsertion = CommentAnchor.cell(sheetID: sheetA, row: 5, col: 0)
        XCTAssertEqual(
            beforeInsertion.remapped(afterColumnInsertedAt: 2, count: 1, onSheet: sheetA),
            beforeInsertion
        )

        let otherSheet = CommentAnchor.cell(sheetID: sheetB, row: 5, col: 2)
        XCTAssertEqual(
            otherSheet.remapped(afterColumnInsertedAt: 2, count: 1, onSheet: sheetA),
            otherSheet
        )
    }

    // MARK: - CommentStore still builds textRange anchors from blocks

    func testCommentStoreBuildsTextRangeAnchorFromDocumentBlocks() {
        let blockID = UUID()
        let commentID = UUID()
        let paragraph = Block(id: blockID, type: .paragraph, content: [InlineRun(text: "Hello world")])
        let comment = Block(
            id: commentID,
            type: .comment,
            attributes: [
                "anchorBlockID": .string(blockID.uuidString),
                "anchorRangeStart": .number(0),
                "anchorRangeEnd": .number(5),
                "author": .string("author-guid-4"),
                "timestamp": .number(Date().timeIntervalSince1970),
                "resolved": .bool(false),
            ],
            content: [InlineRun(text: "nice opening")]
        )
        let doc = DocumentAST(blocks: [blockID: paragraph, commentID: comment], rootChildren: [blockID, commentID])

        let threads = CommentStore.threads(from: doc)

        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads.first?.anchor, .textRange(blockID: blockID, start: 0, end: 5))
        XCTAssertEqual(threads.first?.messages.first?.text, "nice opening")
    }
}
