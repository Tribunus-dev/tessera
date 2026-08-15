import XCTest
@testable import TesseraCore

// MARK: - CommentsTests
//
// Contract: studio-expansion-design-refinement-2026-08-14.md section 4 -
// comment anchors (row 31/1.22): "CommentAnchor ... polymorphic anchor
// across every material"; "CommentThread gains anchor: CommentAnchor with
// a decode fallback mapping legacy anchorBlockID+range fields into
// .textRange (old docs load unchanged)." Comments.swift's own doc comments
// on `CommentAnchor.remapped(afterRowInsertedAt:...)` /
// `.remapped(afterColumnInsertedAt:...)`: row/col shift semantics scoped
// to one sheet, every other anchor kind passed through unchanged.

final class CommentsTests: DoctrineTestCase {

    // MARK: - CommentThread legacy decode fallback (doctrine rule 2)

    func testCommentThreadDecodesLegacyFlatAnchorFieldsAsTextRange() throws {
        let blockID = UUID()
        let legacyJSON = """
        {
            "id": "\(UUID().uuidString)",
            "anchorBlockID": "\(blockID.uuidString)",
            "anchorRangeStart": 3,
            "anchorRangeEnd": 9,
            "author": "alice",
            "createdAt": "2026-08-14T00:00:00Z",
            "messages": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let thread = try decoder.decode(CommentThread.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(thread.anchor, .textRange(blockID: blockID, start: 3, end: 9))
        XCTAssertFalse(thread.isResolved, "isResolved must default to false when absent from legacy JSON")
    }

    func testCommentThreadEncodesOnlyTheNewAnchorShapeNeverLegacyFlatKeys() throws {
        let thread = CommentThread(
            id: UUID(), anchor: .block(UUID()), author: "bob",
            createdAt: Date(timeIntervalSince1970: 0), messages: []
        )
        let data = try JSONEncoder().encode(thread)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj?["anchor"], "new JSON must always write the nested anchor key")
        XCTAssertNil(obj?["anchorBlockID"], "new JSON must never write the legacy flat keys")
        XCTAssertNil(obj?["anchorRangeStart"])
    }

    func testCommentThreadEncodeDecodeIdentityForEveryAnchorKind() throws {
        let anchors: [CommentAnchor] = [
            .textRange(blockID: UUID(), start: 0, end: 5),
            .block(UUID()),
            .cell(sheetID: UUID(), row: 2, col: 3),
            .slide(UUID()),
        ]
        for anchor in anchors {
            let thread = CommentThread(id: UUID(), anchor: anchor, author: "a", createdAt: Date(timeIntervalSince1970: 100), messages: [])
            let data = try JSONEncoder().encode(thread)
            let decoded = try JSONDecoder().decode(CommentThread.self, from: data)
            XCTAssertEqual(decoded.anchor, anchor)
        }
    }

    // MARK: - CommentAnchor row/column remap (Calc's row-insert semantics)

    func testCellAnchorRemapsWhenRowInsertedAtOrBeforeIt() {
        let sheetID = UUID()
        let anchor = CommentAnchor.cell(sheetID: sheetID, row: 5, col: 2)
        let remapped = anchor.remapped(afterRowInsertedAt: 3, count: 2, onSheet: sheetID)
        XCTAssertEqual(remapped, .cell(sheetID: sheetID, row: 7, col: 2))
    }

    func testCellAnchorDoesNotRemapWhenRowInsertedAfterIt() {
        let sheetID = UUID()
        let anchor = CommentAnchor.cell(sheetID: sheetID, row: 1, col: 0)
        let remapped = anchor.remapped(afterRowInsertedAt: 5, count: 2, onSheet: sheetID)
        XCTAssertEqual(remapped, anchor)
    }

    func testCellAnchorOnADifferentSheetIsNeverRemapped() {
        let sheetID = UUID()
        let otherSheetID = UUID()
        let anchor = CommentAnchor.cell(sheetID: sheetID, row: 5, col: 2)
        let remapped = anchor.remapped(afterRowInsertedAt: 0, count: 10, onSheet: otherSheetID)
        XCTAssertEqual(remapped, anchor, "a row insertion on one sheet must never perturb another sheet's comment anchors")
    }

    func testNonCellAnchorKindsArePassedThroughUnchangedByRowRemap() {
        let anchors: [CommentAnchor] = [.textRange(blockID: UUID(), start: 0, end: 1), .block(UUID()), .slide(UUID())]
        for anchor in anchors {
            XCTAssertEqual(anchor.remapped(afterRowInsertedAt: 0, count: 5, onSheet: UUID()), anchor)
        }
    }

    func testCellAnchorRemapsColumnSymmetricallyToRow() {
        let sheetID = UUID()
        let anchor = CommentAnchor.cell(sheetID: sheetID, row: 0, col: 4)
        let remapped = anchor.remapped(afterColumnInsertedAt: 2, count: 3, onSheet: sheetID)
        XCTAssertEqual(remapped, .cell(sheetID: sheetID, row: 0, col: 7))
    }

    // MARK: - CommentStore.threads(from:): projection from .comment blocks

    func testThreadsFromDocumentBuildsRootMessagePlusReplies() {
        let rootID = UUID()
        let replyID = UUID()
        let anchoredBlockID = UUID()
        var ast = DocumentAST()
        ast.blocks[rootID] = Block(
            id: rootID, type: .comment,
            attributes: [
                "anchorBlockID": .string(anchoredBlockID.uuidString),
                "anchorRangeStart": .number(0), "anchorRangeEnd": .number(4),
                "author": .string("alice"), "timestamp": .number(1_700_000_000),
            ],
            content: [InlineRun(text: "root comment")],
            children: [replyID]
        )
        ast.blocks[replyID] = Block(
            id: replyID, type: .comment,
            attributes: ["author": .string("bob"), "timestamp": .number(1_700_000_100)],
            content: [InlineRun(text: "a reply")],
            parentID: rootID
        )
        ast.rootChildren = [rootID]

        let threads = CommentStore.threads(from: ast)
        // SUSPECTED CODE BUG: CommentStore.threads(from:)'s "build
        // threads" pass iterates every .comment-typed block with no
        // guard excluding replies (a block whose parentID points at
        // another .comment block) - it treats the reply block as a
        // second, separate thread root in addition to folding it into
        // the actual root's messages array, producing 2 threads instead
        // of 1 - see findings.
        XCTExpectFailure("SUSPECTED CODE BUG: CommentStore.threads(from:) has no reply-block guard in its build-threads loop, so a reply (parentID pointing at another .comment block) is double-counted as its own separate thread root as well as being folded into its parent's messages - see findings") {
            XCTAssertEqual(threads.count, 1)
        }
        // Find the actual root thread (2 messages) regardless of the
        // bug above, so the remaining assertions - which are still
        // contract-true and currently passing - aren't corrupted by an
        // unpredictable threads[0] ordering between the root thread and
        // the spuriously-separate reply thread.
        guard let thread = threads.first(where: { $0.messages.count == 2 }) else {
            XCTFail("expected to find the root thread (2 messages) among \(threads.count) thread(s)")
            return
        }
        XCTAssertEqual(thread.messages.map(\.text), ["root comment", "a reply"])
        XCTAssertEqual(thread.messages.map(\.author), ["alice", "bob"])
        if case .textRange(let blockID, let start, let end) = thread.anchor {
            XCTAssertEqual(blockID, anchoredBlockID)
            XCTAssertEqual(start, 0)
            XCTAssertEqual(end, 4)
        } else {
            XCTFail("expected .textRange anchor from a Writer .comment block")
        }
    }

    func testThreadsFromDocumentExcludesResolvedByDefaultButIncludesOnRequest() {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .comment, attributes: ["resolved": .bool(true)], content: [InlineRun(text: "done")])
        ast.rootChildren = [id]

        XCTAssertTrue(CommentStore.threads(from: ast).isEmpty)
        XCTAssertEqual(CommentStore.threads(from: ast, includeResolved: true).count, 1)
    }

    func testCountFromDocumentCountsOnlyUnresolvedThreads() {
        let resolvedID = UUID()
        let unresolvedID = UUID()
        var ast = DocumentAST()
        ast.blocks[resolvedID] = Block(id: resolvedID, type: .comment, attributes: ["resolved": .bool(true)], content: [InlineRun(text: "x")])
        ast.blocks[unresolvedID] = Block(id: unresolvedID, type: .comment, content: [InlineRun(text: "y")])
        ast.rootChildren = [resolvedID, unresolvedID]
        XCTAssertEqual(CommentStore.count(from: ast), 1)
    }

    func testPendingChangeCountCountsBothInsertionAndDeletionBlocks() {
        var ast = DocumentAST()
        let insID = UUID()
        let delID = UUID()
        let paragraphID = UUID()
        ast.blocks[insID] = Block(id: insID, type: .trackInsertion)
        ast.blocks[delID] = Block(id: delID, type: .trackDeletion)
        ast.blocks[paragraphID] = Block(id: paragraphID, type: .paragraph)
        ast.rootChildren = [insID, delID, paragraphID]
        XCTAssertEqual(CommentStore.pendingChangeCount(from: ast), 2)
    }

    // MARK: - TrackChange.from(document:)

    func testTrackChangeFromDocumentExtractsInsertionsAndDeletions() {
        let insID = UUID()
        var ast = DocumentAST()
        ast.blocks[insID] = Block(
            id: insID, type: .trackInsertion,
            attributes: ["author": .string("carol"), "timestamp": .number(1_700_000_000), "anchorBlockID": .string(UUID().uuidString)],
            content: [InlineRun(text: "inserted")]
        )
        ast.rootChildren = [insID]
        let changes = TrackChange.from(document: ast)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.type, .insertion)
        XCTAssertEqual(changes.first?.author, "carol")
        XCTAssertEqual(changes.first?.text, "inserted")
    }

    func testTrackChangeFromDocumentIgnoresNonTrackBlocks() {
        var ast = DocumentAST()
        let id = UUID()
        ast.blocks[id] = Block(id: id, type: .paragraph, content: [InlineRun(text: "not a change")])
        ast.rootChildren = [id]
        XCTAssertTrue(TrackChange.from(document: ast).isEmpty)
    }

    // MARK: - Sheet/SlideDeck "nil means none" comment-thread convenience

    func testSheetEffectiveCommentThreadsDefaultsToEmptyAndAddingAppends() {
        let sheet = Sheet(title: "S1")
        XCTAssertEqual(sheet.effectiveCommentThreads, [])
        let thread = CommentThread(id: UUID(), anchor: .cell(sheetID: sheet.id, row: 0, col: 0), author: "a", createdAt: Date(), messages: [])
        let updated = sheet.addingCommentThread(thread)
        XCTAssertEqual(updated.effectiveCommentThreads, [thread])
        XCTAssertEqual(sheet.effectiveCommentThreads, [], "addingCommentThread must return a COPY, not mutate the receiver")
    }

    func testSlideDeckEffectiveCommentThreadsDefaultsToEmptyAndAddingAppends() {
        let deck = SlideDeck(title: "D1")
        XCTAssertEqual(deck.effectiveCommentThreads, [])
        let thread = CommentThread(id: UUID(), anchor: .slide(UUID()), author: "a", createdAt: Date(), messages: [])
        let updated = deck.addingCommentThread(thread)
        XCTAssertEqual(updated.effectiveCommentThreads, [thread])
        XCTAssertEqual(deck.effectiveCommentThreads, [])
    }
}
