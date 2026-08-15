import XCTest
@testable import TesseraCore

// MARK: - TextCursorTests
//
// Contract: TextCursor.swift's own doc comments - "Two cursors can exist
// in the same document at the same time: the user cursor... and the agent
// cursor"; `CursorPair.isEmpty`/`.count` derived purely from the two
// optional cursors (doctrine rule 3: derived, not separately stored).

final class TextCursorTests: DoctrineTestCase {

    // MARK: - Round-trip identity (doctrine rule 2)

    func testTextCursorEncodeDecodeIdentity() throws {
        let cursor = TextCursor(blockID: UUID(), offset: 4, affinity: .upstream)
        let data = try JSONEncoder().encode(cursor)
        let decoded = try JSONDecoder().decode(TextCursor.self, from: data)
        XCTAssertEqual(decoded, cursor)
    }

    func testTextCursorDefaultAffinityIsDownstream() {
        let cursor = TextCursor(blockID: UUID(), offset: 0)
        XCTAssertEqual(cursor.affinity, .downstream)
    }

    func testCursorPairEncodeDecodeIdentity() throws {
        let pair = CursorPair(user: TextCursor(blockID: UUID(), offset: 1), agent: nil)
        let data = try JSONEncoder().encode(pair)
        let decoded = try JSONDecoder().decode(CursorPair.self, from: data)
        XCTAssertEqual(decoded, pair)
    }

    // MARK: - CursorPair derived properties

    func testCursorPairIsEmptyWhenBothCursorsAreNil() {
        XCTAssertTrue(CursorPair().isEmpty)
        XCTAssertEqual(CursorPair().count, 0)
    }

    func testCursorPairCountReflectsHowManyCursorsArePresent() {
        let userOnly = CursorPair(user: TextCursor(blockID: UUID(), offset: 0))
        XCTAssertEqual(userOnly.count, 1)
        XCTAssertFalse(userOnly.isEmpty)

        let both = CursorPair(user: TextCursor(blockID: UUID(), offset: 0), agent: TextCursor(blockID: UUID(), offset: 1))
        XCTAssertEqual(both.count, 2)
    }
}
