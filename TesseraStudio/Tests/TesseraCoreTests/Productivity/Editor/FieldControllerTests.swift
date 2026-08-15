import XCTest
@testable import TesseraCore

/// Tests for `FieldController.refresh` (P1 item 1.1). Per the design
/// contract: idempotent under a fixed clock, a layout-insensitive kind
/// (`.date`) resolves to real non-empty text, and a layout-sensitive
/// kind (`.page`) is left unchanged/dirty at P1 - see
/// FieldController.swift's file header for why the last one is correct
/// behavior, not a bug.
final class FieldControllerTests: XCTestCase {

    private let fixedClock: () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }

    // MARK: - Idempotence

    func testRefreshUnderFixedClockIsIdempotent() {
        var block = Block(type: .field)
        block.field = FieldSpec(kind: .date)
        let ast = DocumentAST(blocks: [block.id: block], rootChildren: [block.id])

        let once = FieldController.refresh(block, in: ast, clock: fixedClock)
        // Feed the already-refreshed block back in: a second refresh
        // under the SAME clock must land on the same Block, byte for
        // byte - the pure-logic proxy for "no second receipt" (see
        // FieldController.swift's file header on the future DocStore
        // integration this makes possible).
        let twice = FieldController.refresh(once, in: ast, clock: fixedClock)

        XCTAssertEqual(once, twice)
    }

    func testSequenceFieldRefreshIsAlsoIdempotentUnderFixedClock() {
        var block = Block(type: .field)
        block.field = FieldSpec(kind: .sequence(name: "Figure"))
        let ast = DocumentAST(blocks: [block.id: block], rootChildren: [block.id])

        let once = FieldController.refresh(block, in: ast, clock: fixedClock)
        let twice = FieldController.refresh(once, in: ast, clock: fixedClock)

        XCTAssertEqual(once, twice)
    }

    // MARK: - Layout-insensitive: always resolves

    func testDateFieldResolvesToRealNonEmptyText() {
        var block = Block(type: .field)
        block.field = FieldSpec(kind: .date)
        let ast = DocumentAST(blocks: [block.id: block], rootChildren: [block.id])

        let refreshed = FieldController.refresh(block, in: ast, clock: fixedClock)

        let text = refreshed.content.map(\.text).joined()
        XCTAssertFalse(text.isEmpty)
        XCTAssertEqual(text, "2023-11-14") // 1_700_000_000 UTC
        XCTAssertEqual(refreshed.field?.dirty, false)
    }

    func testSequenceFieldNumbersByDocumentOrder() {
        var f1 = Block(type: .field)
        f1.field = FieldSpec(kind: .sequence(name: "Figure"))
        var f2 = Block(type: .field)
        f2.field = FieldSpec(kind: .sequence(name: "Figure"))
        let ast = DocumentAST(blocks: [f1.id: f1, f2.id: f2], rootChildren: [f1.id, f2.id])

        let r1 = FieldController.refresh(f1, in: ast, clock: fixedClock)
        let r2 = FieldController.refresh(f2, in: ast, clock: fixedClock)

        XCTAssertEqual(r1.content.map(\.text).joined(), "1")
        XCTAssertEqual(r2.content.map(\.text).joined(), "2")
        XCTAssertEqual(r1.field?.dirty, false)
        XCTAssertEqual(r2.field?.dirty, false)
    }

    func testRefreshClearsAlreadyClearDirtyFlagWithoutChangingResolvedText() {
        // Re-resolving a field that was already clean under the same
        // clock must not perturb anything - covered again explicitly
        // here (distinct from the idempotence test) because this is
        // the "even if it was already clear" case the file header calls out.
        var block = Block(type: .field, content: [InlineRun(text: "2023-11-14")])
        block.field = FieldSpec(kind: .date, dirty: false)
        let ast = DocumentAST(blocks: [block.id: block], rootChildren: [block.id])

        let refreshed = FieldController.refresh(block, in: ast, clock: fixedClock)

        XCTAssertEqual(refreshed, block)
    }

    // MARK: - Layout-sensitive: stays dirty with last-known text (P1 limitation, not a bug)

    func testPageFieldStaysDirtyAndUnchangedAtP1() {
        var block = Block(type: .field, content: [InlineRun(text: "3")])
        block.field = FieldSpec(kind: .page, dirty: true)
        let ast = DocumentAST(blocks: [block.id: block], rootChildren: [block.id])

        let refreshed = FieldController.refresh(block, in: ast, clock: fixedClock)

        // No paginator context exists at P1 - refresh must return the
        // input Block completely untouched, last-known text included.
        XCTAssertEqual(refreshed, block)
        XCTAssertEqual(refreshed.content.map(\.text).joined(), "3")
        XCTAssertEqual(refreshed.field?.dirty, true)
    }

    func testNumPagesAndRefFieldsAreAlsoLayoutSensitive() {
        var numPages = Block(type: .field, content: [InlineRun(text: "10")])
        numPages.field = FieldSpec(kind: .numPages, dirty: true)
        var ref = Block(type: .field, content: [InlineRun(text: "5")])
        ref.field = FieldSpec(kind: .ref(targetBlockID: UUID()), dirty: true)
        let ast = DocumentAST(
            blocks: [numPages.id: numPages, ref.id: ref],
            rootChildren: [numPages.id, ref.id]
        )

        XCTAssertEqual(FieldController.refresh(numPages, in: ast, clock: fixedClock), numPages)
        XCTAssertEqual(FieldController.refresh(ref, in: ast, clock: fixedClock), ref)
    }

    // MARK: - Non-field inputs are a no-op

    func testRefreshIsANoOpForNonFieldBlocks() {
        let block = Block(type: .paragraph, content: [InlineRun(text: "plain")])
        let ast = DocumentAST(blocks: [block.id: block], rootChildren: [block.id])
        XCTAssertEqual(FieldController.refresh(block, in: ast, clock: fixedClock), block)
    }

    func testRefreshIsANoOpForAFieldBlockWithNoSpecYet() {
        let block = Block(type: .field)
        let ast = DocumentAST(blocks: [block.id: block], rootChildren: [block.id])
        XCTAssertEqual(FieldController.refresh(block, in: ast, clock: fixedClock), block)
    }
}
