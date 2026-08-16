import XCTest
@testable import TesseraCore

// MARK: - FieldControllerTests
//
// Contract: studio-expansion-design-refinement-2026-08-14.md section 4,
// "Writer cluster" - 1.1 BlockType.field + FieldController:
//   "attributes["field"] holds a Codable FieldSpec (kind: page/numPages |
//   ref/sequence | date/time/author/title/docProperty + dirty flag);
//   content holds the cached RESOLVED text as ordinary runs ... layout
//   fields stay dirty with last-known text until a paginator context
//   exists (P2). Field refresh is a receipted mutation
//   (doc_fields_refreshed) or contentHash drifts silently."
//   "Test: refresh under a fixed clock is idempotent (no second receipt)."
//
// FieldController itself is pure (no DocStore); the "no second receipt"
// half of the contract is tested here as FieldController.refresh's own
// idempotence (refresh(refresh(b)) == refresh(b) under the same clock) -
// exactly the property DocStore.refreshFields relies on (its own doc
// comment: "a plain != check ... which refresh's own idempotence ... is
// what makes that check sufficient").
//
// .mergeField(name:) (P2-C item 2.4, sota-p2-core-report.md's "2.4
// MailMergeCoordinator - restatement"): "mergeField joins the existing
// FieldKind enum (reserved by name - not a new BlockType)". Contract for
// its own resolution is this file's OWN header comment (the design
// decision this track made and recorded there + in
// docs/.scratch/p2-c-findings-2.md): a merge record is threaded through
// via `refresh`'s new `mergeRecord` parameter; `nil` (no merge
// underway) behaves like a layout-sensitive field (untouched); a name
// absent from a supplied record resolves to "" (matching `.author`/
// `.docProperty`'s own "empty is a legitimate resolution" precedent).

final class FieldControllerTests: DoctrineTestCase {

    private let fixedClock: () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }

    private func fieldBlock(id: UUID = UUID(), kind: FieldKind, dirty: Bool = true) -> Block {
        var block = Block(id: id, type: .field)
        block.field = FieldSpec(kind: kind, dirty: dirty)
        return block
    }

    // MARK: - Idempotence under a fixed clock (the headline test contract)

    func testRefreshDateFieldTwiceUnderFixedClockIsIdempotent() {
        let original = fieldBlock(kind: .date)
        let once = FieldController.refresh(original, in: .empty, clock: fixedClock)
        let twice = FieldController.refresh(once, in: .empty, clock: fixedClock)
        XCTAssertEqual(once, twice, "a second refresh under the same clock value must produce an identical block (no second receipt-worthy change)")
        XCTAssertEqual(once.field?.dirty, false)
    }

    func testRefreshTimeFieldTwiceUnderFixedClockIsIdempotent() {
        let original = fieldBlock(kind: .time)
        let once = FieldController.refresh(original, in: .empty, clock: fixedClock)
        let twice = FieldController.refresh(once, in: .empty, clock: fixedClock)
        XCTAssertEqual(once, twice)
    }

    /// Under a REAL moving clock, a date field is deliberately NOT
    /// idempotent - the file header's explicit carve-out for this case.
    func testRefreshDateFieldWithDifferentClockValuesProducesDifferentContent() {
        let original = fieldBlock(kind: .date)
        let earlier = FieldController.refresh(original, in: .empty, clock: { Date(timeIntervalSince1970: 0) })
        let later = FieldController.refresh(original, in: .empty, clock: { Date(timeIntervalSince1970: 86_400 * 400) })
        XCTAssertNotEqual(earlier.content, later.content, "a date field must track a genuinely moving clock, not freeze on first resolve")
    }

    // MARK: - Layout-sensitive fields stay dirty (untouched) at P1

    func testRefreshPageFieldLeavesBlockCompletelyUnchanged() {
        let original = fieldBlock(kind: .page, dirty: true)
        let refreshed = FieldController.refresh(original, in: .empty, clock: fixedClock)
        XCTAssertEqual(refreshed, original, "a layout-sensitive field's block must be returned byte-for-byte unchanged, not merely re-marked dirty")
        XCTAssertEqual(refreshed.field?.dirty, true, "dirty flag must stay true - no paginator context exists at P1")
    }

    func testRefreshNumPagesFieldLeavesBlockCompletelyUnchanged() {
        let original = fieldBlock(kind: .numPages, dirty: true)
        let refreshed = FieldController.refresh(original, in: .empty, clock: fixedClock)
        XCTAssertEqual(refreshed, original)
    }

    func testRefreshRefFieldLeavesBlockCompletelyUnchanged() {
        let original = fieldBlock(kind: .ref(targetBlockID: UUID()), dirty: true)
        let refreshed = FieldController.refresh(original, in: .empty, clock: fixedClock)
        XCTAssertEqual(refreshed, original)
    }

    // MARK: - Non-.field / no-spec blocks are untouched no-ops

    func testRefreshNonFieldBlockReturnsBlockUnchanged() {
        let paragraph = Block(type: .paragraph, content: [InlineRun(text: "hello")])
        let refreshed = FieldController.refresh(paragraph, in: .empty)
        XCTAssertEqual(refreshed, paragraph)
    }

    func testRefreshFieldBlockWithNoSpecYetReturnsBlockUnchanged() {
        let block = Block(type: .field) // no attributes["field"] set
        let refreshed = FieldController.refresh(block, in: .empty)
        XCTAssertEqual(refreshed, block)
    }

    // MARK: - .sequence(name:) numbers from document order, not a stored counter

    func testSequenceFieldNumbersFromDocumentOrderAmongSameName() {
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID() // different sequence name - must not share the counter
        var ast = DocumentAST()
        ast.blocks[firstID] = fieldBlock(id: firstID, kind: .sequence(name: "Figure"))
        ast.blocks[secondID] = fieldBlock(id: secondID, kind: .sequence(name: "Figure"))
        ast.blocks[thirdID] = fieldBlock(id: thirdID, kind: .sequence(name: "Table"))
        ast.rootChildren = [firstID, secondID, thirdID]

        let firstRefreshed = FieldController.refresh(ast.blocks[firstID]!, in: ast, clock: fixedClock)
        let secondRefreshed = FieldController.refresh(ast.blocks[secondID]!, in: ast, clock: fixedClock)
        let thirdRefreshed = FieldController.refresh(ast.blocks[thirdID]!, in: ast, clock: fixedClock)

        XCTAssertEqual(firstRefreshed.content.first?.text, "1")
        XCTAssertEqual(secondRefreshed.content.first?.text, "2")
        XCTAssertEqual(thirdRefreshed.content.first?.text, "1", "a different sequence name must count independently")
    }

    /// A detached block (not yet inserted into `ast`) counts as the NEXT
    /// ordinal after every match already found - the file's documented
    /// fallback for resolving a field before insertion.
    func testSequenceFieldNotYetInAstCountsAsNextOrdinal() {
        let existingID = UUID()
        var ast = DocumentAST()
        ast.blocks[existingID] = fieldBlock(id: existingID, kind: .sequence(name: "Figure"))
        ast.rootChildren = [existingID]

        let detached = fieldBlock(kind: .sequence(name: "Figure"))
        let refreshed = FieldController.refresh(detached, in: ast, clock: fixedClock)
        XCTAssertEqual(refreshed.content.first?.text, "2")
    }

    // MARK: - Everything else always resolves (clears dirty even if already clear)

    func testRefreshDateFieldAlwaysClearsDirtyEvenWhenAlreadyClear() {
        let alreadyClean = fieldBlock(kind: .date, dirty: false)
        let refreshed = FieldController.refresh(alreadyClean, in: .empty, clock: fixedClock)
        XCTAssertEqual(refreshed.field?.dirty, false)
        XCTAssertFalse(refreshed.content.isEmpty, "content-insensitive fields always recompute their resolved text")
    }

    // MARK: - .author/.title/.docProperty resolve to "" at P1 (contract-true,
    // not a bug - verified at HEAD against FieldController.swift's own
    // documented P1 limitation; see docs/.scratch/test-rewrite-findings-writer.md)

    func testRefreshAuthorFieldResolvesToEmptyStringAtP1() {
        let block = fieldBlock(kind: .author)
        let refreshed = FieldController.refresh(block, in: .empty, clock: fixedClock)
        XCTAssertEqual(refreshed.content, [InlineRun(text: "")], "P1 has no Doc-level author source threaded through FieldController - see file header")
        XCTAssertEqual(refreshed.field?.dirty, false)
    }

    func testRefreshTitleFieldResolvesToEmptyStringAtP1() {
        let block = fieldBlock(kind: .title)
        let refreshed = FieldController.refresh(block, in: .empty, clock: fixedClock)
        XCTAssertEqual(refreshed.content, [InlineRun(text: "")])
    }

    func testRefreshDocPropertyFieldResolvesToEmptyStringAtP1() {
        let block = fieldBlock(kind: .docProperty(name: "Company"))
        let refreshed = FieldController.refresh(block, in: .empty, clock: fixedClock)
        XCTAssertEqual(refreshed.content, [InlineRun(text: "")])
    }

    // MARK: - Round-trip identity for FieldSpec (doctrine rule 2)

    func testFieldSpecEncodeDecodeIdentityAcrossEveryKind() throws {
        let specs: [FieldSpec] = [
            FieldSpec(kind: .page),
            FieldSpec(kind: .numPages),
            FieldSpec(kind: .ref(targetBlockID: UUID())),
            FieldSpec(kind: .sequence(name: "Figure")),
            FieldSpec(kind: .date),
            FieldSpec(kind: .time),
            FieldSpec(kind: .author),
            FieldSpec(kind: .title),
            FieldSpec(kind: .docProperty(name: "Company"), dirty: false),
            FieldSpec(kind: .mergeField(name: "FirstName"), dirty: false),
        ]
        for spec in specs {
            let data = try JSONEncoder().encode(spec)
            let decoded = try JSONDecoder().decode(FieldSpec.self, from: data)
            XCTAssertEqual(decoded, spec)
        }
    }

    // MARK: - .mergeField(name:) (P2-C item 2.4) - contract per this file's
    // own header comment + docs/.scratch/p2-c-findings-2.md

    /// The headline resolution case: a record supplying the named key
    /// resolves to that value and clears `dirty`, exactly like every
    /// other non-layout-sensitive kind.
    func testRefreshMergeFieldWithMatchingRecordResolvesToRecordValue() {
        let block = fieldBlock(kind: .mergeField(name: "FirstName"))
        let refreshed = FieldController.refresh(block, in: .empty, clock: fixedClock, mergeRecord: ["FirstName": "Ada", "LastName": "Lovelace"])
        XCTAssertEqual(refreshed.content, [InlineRun(text: "Ada")])
        XCTAssertEqual(refreshed.field?.dirty, false)
    }

    /// Degrade gracefully, not crash: a mergeField name absent from the
    /// SUPPLIED record substitutes an empty string, matching `.author`/
    /// `.docProperty`'s own "empty is a legitimate resolution" precedent -
    /// this is this item's own "template mergeField name absent from a
    /// given record" test-coverage requirement.
    func testRefreshMergeFieldWithRecordMissingKeyResolvesToEmptyStringNotACrash() {
        let block = fieldBlock(kind: .mergeField(name: "MiddleName"))
        let refreshed = FieldController.refresh(block, in: .empty, clock: fixedClock, mergeRecord: ["FirstName": "Ada"])
        XCTAssertEqual(refreshed.content, [InlineRun(text: "")])
        XCTAssertEqual(refreshed.field?.dirty, false, "a resolved-to-empty merge field is still RESOLVED, not still dirty")
    }

    /// The load-bearing regression guard from this file's own header:
    /// refreshing WITHOUT a merge record (the ordinary `DocStore.
    /// refreshFields` path, which has no notion of "current record")
    /// must leave an ALREADY-MERGED field's content completely
    /// untouched - never silently blank it back to "".
    func testRefreshMergeFieldWithNoMergeRecordLeavesAlreadyResolvedContentUntouched() {
        var block = fieldBlock(kind: .mergeField(name: "FirstName"), dirty: false)
        block.content = [InlineRun(text: "Ada")]
        let refreshed = FieldController.refresh(block, in: .empty, clock: fixedClock)
        XCTAssertEqual(refreshed, block, "no mergeRecord supplied must be a byte-for-byte no-op, same as a layout-sensitive field")
        XCTAssertEqual(refreshed.content, [InlineRun(text: "Ada")])
    }

    /// Same "no mergeRecord" no-op, on a field that was never resolved
    /// (still dirty, empty content) - dirty must stay true, matching
    /// `.page`/`.numPages`/`.ref`'s own layout-sensitive contract.
    func testRefreshMergeFieldWithNoMergeRecordOnNeverResolvedFieldLeavesDirtyTrue() {
        let block = fieldBlock(kind: .mergeField(name: "FirstName"), dirty: true)
        let refreshed = FieldController.refresh(block, in: .empty, clock: fixedClock)
        XCTAssertEqual(refreshed, block)
        XCTAssertEqual(refreshed.field?.dirty, true)
    }

    /// Idempotence under the SAME record (mirrors this file's own
    /// headline date/time idempotence tests) - refreshing an
    /// already-merged field again with the identical record produces an
    /// identical block.
    func testRefreshMergeFieldTwiceUnderSameRecordIsIdempotent() {
        let original = fieldBlock(kind: .mergeField(name: "FirstName"))
        let record = ["FirstName": "Grace"]
        let once = FieldController.refresh(original, in: .empty, clock: fixedClock, mergeRecord: record)
        let twice = FieldController.refresh(once, in: .empty, clock: fixedClock, mergeRecord: record)
        XCTAssertEqual(once, twice)
    }

    // MARK: - Block.field bridge

    func testBlockFieldBridgeRoundTripsThroughAttributesOnFieldBlock() {
        var block = Block(type: .field)
        XCTAssertNil(block.field)
        let spec = FieldSpec(kind: .date, dirty: false)
        block.field = spec
        XCTAssertEqual(block.field, spec)
        XCTAssertNotNil(block.attributes["field"], "must be stored as a nested JSON object under attributes[\"field\"]")
        block.field = nil
        XCTAssertNil(block.attributes["field"])
    }

    func testBlockFieldBridgeIsNoOpOnNonFieldBlock() {
        var paragraph = Block(type: .paragraph)
        paragraph.field = FieldSpec(kind: .date)
        XCTAssertNil(paragraph.field, "setting .field on a non-.field block type must be a no-op")
        XCTAssertNil(paragraph.attributes["field"])
    }
}
