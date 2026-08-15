import XCTest
@testable import TesseraCore

// MARK: - TextEditReducerTests
//
// Contract: TextEditReducer.swift's own doc comments - "The reducer walks
// the two strings, finds the common prefix and common suffix, and the
// differing middle is the edit region"; classification into Insertion/
// Deletion/Replacement/pure-formatting-change; "The reducer is stateless
// and pure: the same input always produces the same output" (doctrine
// rule 4 - determinism first). Coverage shape (engine): fixtures +
// property (determinism) + trap guards (empty diff -> []).

final class TextEditReducerTests: DoctrineTestCase {

    private let reducer = TextEditReducer()

    // MARK: - diff(before:after:): fixtures (doctrine rule 9)

    func testDiffOfPureInsertionHasEmptyDeletedRange() {
        let diff = TextEditReducer.diff(before: "hello", after: "hello world")
        XCTAssertTrue(diff.isInsertion)
        XCTAssertEqual(diff.deletedRange.length, 0)
        XCTAssertEqual(diff.insertedRange, NSRange(location: 5, length: 6))
    }

    func testDiffOfPureDeletionHasEmptyInsertedRange() {
        let diff = TextEditReducer.diff(before: "hello world", after: "hello")
        XCTAssertTrue(diff.isDeletion)
        XCTAssertEqual(diff.insertedRange.length, 0)
        XCTAssertEqual(diff.deletedRange, NSRange(location: 5, length: 6))
    }

    func testDiffOfReplacementInTheMiddleFindsCommonPrefixAndSuffix() {
        // "the CAT sat" -> "the DOG sat": common prefix "the ", common suffix " sat".
        let diff = TextEditReducer.diff(before: "the cat sat", after: "the dog sat")
        XCTAssertTrue(diff.isReplacement)
        XCTAssertEqual(diff.commonPrefix, 4)
        XCTAssertEqual(diff.commonSuffix, 4)
        XCTAssertEqual(diff.deletedRange, NSRange(location: 4, length: 3))
        XCTAssertEqual(diff.insertedRange, NSRange(location: 4, length: 3))
    }

    func testDiffOfIdenticalStringsIsEmpty() {
        let diff = TextEditReducer.diff(before: "same", after: "same")
        XCTAssertTrue(diff.isEmpty)
    }

    func testDiffOfEntirelyDifferentStringsHasNoSharedPrefixOrSuffix() {
        let diff = TextEditReducer.diff(before: "abc", after: "xyz")
        XCTAssertEqual(diff.commonPrefix, 0)
        XCTAssertEqual(diff.commonSuffix, 0)
        XCTAssertEqual(diff.deletedRange, NSRange(location: 0, length: 3))
        XCTAssertEqual(diff.insertedRange, NSRange(location: 0, length: 3))
    }

    func testDiffFromEmptyToNonEmptyStringIsAPureInsertionAtZero() {
        let diff = TextEditReducer.diff(before: "", after: "new")
        XCTAssertTrue(diff.isInsertion)
        XCTAssertEqual(diff.insertedRange, NSRange(location: 0, length: 3))
    }

    // MARK: - Property: determinism (doctrine rule 4) - the same input always produces the same diff

    func testDiffIsDeterministicAcrossRepeatedCalls() {
        let first = TextEditReducer.diff(before: "the cat sat", after: "the dog sat")
        let second = TextEditReducer.diff(before: "the cat sat", after: "the dog sat")
        XCTAssertEqual(first, second)
    }

    // MARK: - reduce(blockID:before:after:)

    func testReduceOfEmptyDiffReturnsNoMutations() {
        let blockID = UUID()
        let content = [InlineRun(text: "same")]
        XCTAssertEqual(reducer.reduce(blockID: blockID, before: content, after: content), [])
    }

    func testReduceOfAChangeProducesSetBlockContentWithTheAfterContent() {
        let blockID = UUID()
        let before = [InlineRun(text: "hello")]
        let after = [InlineRun(text: "hello world")]
        let mutations = reducer.reduce(blockID: blockID, before: before, after: after)
        XCTAssertEqual(mutations, [.setBlockContent(blockID: blockID, content: after)])
    }

    // MARK: - reduceFormattingChange: toggles the annotation at the cursor's run

    func testReduceFormattingChangeEnablesAnnotationWhenNotPresent() {
        let blockID = UUID()
        let content = [InlineRun(text: "hello")]
        let mutations = reducer.reduceFormattingChange(blockID: blockID, content: content, offset: 2, annotation: .bold)
        XCTAssertEqual(mutations, [.setInlineAnnotation(blockID: blockID, index: 0, annotation: .bold, enabled: true)])
    }

    func testReduceFormattingChangeDisablesAnnotationWhenAlreadyPresent() {
        let blockID = UUID()
        let content = [InlineRun(text: "hello", annotations: [.bold])]
        let mutations = reducer.reduceFormattingChange(blockID: blockID, content: content, offset: 2, annotation: .bold)
        XCTAssertEqual(mutations, [.setInlineAnnotation(blockID: blockID, index: 0, annotation: .bold, enabled: false)])
    }

    func testReduceFormattingChangeAtOffsetInSecondRunTargetsThatRun() {
        let blockID = UUID()
        let content = [InlineRun(text: "hello"), InlineRun(text: "world")]
        let mutations = reducer.reduceFormattingChange(blockID: blockID, content: content, offset: 7, annotation: .italic)
        XCTAssertEqual(mutations, [.setInlineAnnotation(blockID: blockID, index: 1, annotation: .italic, enabled: true)])
    }

    func testReduceFormattingChangeAtExactEndOfLastRunAppliesToTheLastRun() {
        let blockID = UUID()
        let content = [InlineRun(text: "hello"), InlineRun(text: "world")]
        // offset == total length (10): matches inside the loop, on the last run
        // (remaining(5) <= "world".count(5)).
        let mutations = reducer.reduceFormattingChange(blockID: blockID, content: content, offset: 10, annotation: .bold)
        XCTAssertEqual(mutations, [.setInlineAnnotation(blockID: blockID, index: 1, annotation: .bold, enabled: true)])
    }

    func testReduceFormattingChangeWithOffsetPastTheEndFallsBackToTheLastRun() {
        let blockID = UUID()
        let content = [InlineRun(text: "hello"), InlineRun(text: "world", annotations: [.italic])]
        // offset (99) exceeds the total flattened length (10): the loop never
        // matches, so the post-loop fallback applies to the last run.
        let mutations = reducer.reduceFormattingChange(blockID: blockID, content: content, offset: 99, annotation: .italic)
        XCTAssertEqual(mutations, [.setInlineAnnotation(blockID: blockID, index: 1, annotation: .italic, enabled: false)])
    }

    func testReduceFormattingChangeOnEmptyContentReturnsNoMutations() {
        let mutations = reducer.reduceFormattingChange(blockID: UUID(), content: [], offset: 0, annotation: .bold)
        XCTAssertEqual(mutations, [])
    }

    // MARK: - reducePaste

    func testReducePasteProducesOneRunWithTheExistingAnnotations() {
        let blockID = UUID()
        let mutations = reducer.reducePaste(blockID: blockID, pastedText: "pasted text", existingAnnotations: [.italic])
        XCTAssertEqual(mutations, [.setBlockContent(blockID: blockID, content: [InlineRun(text: "pasted text", annotations: [.italic])])])
    }

    // MARK: - NSRange.substring(in:)

    func testNSRangeSubstringExtractsTheCoveredText() {
        let range = NSRange(location: 6, length: 5)
        XCTAssertEqual(range.substring(in: "hello world"), "world")
    }

    func testNSRangeSubstringOutOfRangeReturnsEmptyString() {
        let range = NSRange(location: 100, length: 5)
        XCTAssertEqual(range.substring(in: "short"), "")
    }

    func testNSRangeSubstringOfZeroLengthRangeReturnsEmptyString() {
        let range = NSRange(location: 3, length: 0)
        XCTAssertEqual(range.substring(in: "hello"), "")
    }
}
