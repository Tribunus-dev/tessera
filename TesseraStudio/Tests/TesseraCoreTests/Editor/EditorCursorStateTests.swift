import XCTest
@testable import TesseraCore

// MARK: - EditorCursorStateTests
//
// Contract: EditorCursorState.swift's own doc comments - the two-cursor
// model's derived properties (`isEmpty`/`hasUserFocus`/`hasAgentActive`/
// `asCursorPair`); `CursorSelection`'s derived `isEmpty`/`length`/
// `lowerOffset`/`upperOffset`; `TextCursor.resolved(in:)` / the
// `TextCursor.init(_:in:)` round trip translating a flattened offset to a
// (runIndex, runOffset) pair and back.

final class EditorCursorStateTests: DoctrineTestCase {

    // MARK: - EditorCursorState derived properties

    func testEmptyStateIsEmptyHasNoFocusNoAgentActive() {
        let state = EditorCursorState.empty
        XCTAssertTrue(state.isEmpty)
        XCTAssertFalse(state.hasUserFocus)
        XCTAssertFalse(state.hasAgentActive)
    }

    func testHasUserFocusTrueWhenUserCursorPresent() {
        let state = EditorCursorState(userCursor: TextCursor(blockID: UUID(), offset: 0))
        XCTAssertTrue(state.hasUserFocus)
        XCTAssertFalse(state.isEmpty)
    }

    func testHasAgentActiveRequiresBothACursorAndTheActiveFlag() {
        let cursorOnlyState = EditorCursorState(agentCursor: TextCursor(blockID: UUID(), offset: 0), agentCursorActive: false)
        XCTAssertFalse(cursorOnlyState.hasAgentActive, "an agent cursor that is present but not active must not report hasAgentActive")

        let activeState = EditorCursorState(agentCursor: TextCursor(blockID: UUID(), offset: 0), agentCursorActive: true)
        XCTAssertTrue(activeState.hasAgentActive)
    }

    func testAsCursorPairCarriesBothCursorsThrough() {
        let userCursor = TextCursor(blockID: UUID(), offset: 1)
        let agentCursor = TextCursor(blockID: UUID(), offset: 2)
        let state = EditorCursorState(userCursor: userCursor, agentCursor: agentCursor)
        XCTAssertEqual(state.asCursorPair, CursorPair(user: userCursor, agent: agentCursor))
    }

    // MARK: - CursorSelection derived properties

    func testCursorSelectionIsEmptyWhenAnchorEqualsHead() {
        let selection = CursorSelection(blockID: UUID(), anchorOffset: 5, headOffset: 5)
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.length, 0)
    }

    func testCursorSelectionLengthIsAbsoluteDistanceRegardlessOfDirection() {
        let forward = CursorSelection(blockID: UUID(), anchorOffset: 2, headOffset: 9)
        let backward = CursorSelection(blockID: UUID(), anchorOffset: 9, headOffset: 2)
        XCTAssertEqual(forward.length, 7)
        XCTAssertEqual(backward.length, 7)
        XCTAssertEqual(forward.lowerOffset, 2)
        XCTAssertEqual(forward.upperOffset, 9)
        XCTAssertEqual(backward.lowerOffset, 2, "lowerOffset must be the smaller of the two regardless of selection direction")
        XCTAssertEqual(backward.upperOffset, 9)
    }

    // MARK: - TextCursor.resolved(in:) <-> TextCursor.init(_:in:) round trip

    func testResolvedInBlockFindsTheCorrectRunAndLocalOffset() {
        let blockID = UUID()
        let block = Block(id: blockID, type: .paragraph, content: [InlineRun(text: "hello"), InlineRun(text: "world")])
        let cursor = TextCursor(blockID: blockID, offset: 7) // 2 chars into the second run
        let resolved = cursor.resolved(in: block)
        XCTAssertEqual(resolved?.runIndex, 1)
        XCTAssertEqual(resolved?.runOffset, 2)
    }

    func testResolvedInBlockAtTheVeryStartResolvesToFirstRunOffsetZero() {
        let blockID = UUID()
        let block = Block(id: blockID, type: .paragraph, content: [InlineRun(text: "hello")])
        let cursor = TextCursor(blockID: blockID, offset: 0)
        let resolved = cursor.resolved(in: block)
        XCTAssertEqual(resolved?.runIndex, 0)
        XCTAssertEqual(resolved?.runOffset, 0)
    }

    func testResolvedInBlockNilForDividerImageOrEquationBlocks() {
        let blockID = UUID()
        for type: BlockType in [.divider, .image, .equation] {
            let block = Block(id: blockID, type: type)
            let cursor = TextCursor(blockID: blockID, offset: 0)
            XCTAssertNil(cursor.resolved(in: block), "\(type) blocks have no inline content to resolve a cursor into")
        }
    }

    func testCursorInBlockRoundTripsBackToTheSameFlattenedOffset() {
        let blockID = UUID()
        let block = Block(id: blockID, type: .paragraph, content: [InlineRun(text: "hello"), InlineRun(text: "world")])
        let original = TextCursor(blockID: blockID, offset: 7)
        let inBlock = original.resolved(in: block)!
        let reconstructed = TextCursor(inBlock, in: block)
        XCTAssertEqual(reconstructed.offset, 7, "resolved(in:) then init(_:in:) must reconstruct the original flattened offset")
        XCTAssertEqual(reconstructed.blockID, blockID)
    }
}
