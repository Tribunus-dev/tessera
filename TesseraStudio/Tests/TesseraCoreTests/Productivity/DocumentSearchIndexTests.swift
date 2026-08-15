import XCTest
@testable import TesseraCore

// MARK: - DocumentSearchIndexTests
//
// Contract: studio-expansion-design-refinement-2026-08-14.md section 4,
// "Writer cluster" - DocumentSearchIndex (row 34):
//   "index over depth-first block text sharing plainText()'s exact
//   coordinates; per-block matching with explicit crossBlock opt-in;
//   replace-all = ONE mutation + ONE doc_find_replace receipt, applied
//   back-to-front."
//   "Test: match offsets compose with plainText() to reproduce matched
//   substrings exactly."
//
// The source file's own header names the specific function this shares
// coordinates with: `Doc.plainText(of:)` (not `DocumentAST.plainText()`,
// a different, simpler function with different per-blocktype rules) - so
// this suite composes offsets against `Doc.plainText(of:)`, per the
// source's documented invariant.

final class DocumentSearchIndexTests: DoctrineTestCase {

    // MARK: - Fixtures

    private func block(_ type: BlockType, text: String, id: UUID = UUID(), attributes: [String: AnyCodable] = [:], children: [UUID] = []) -> Block {
        Block(id: id, type: type, attributes: attributes, content: text.isEmpty ? [] : [InlineRun(text: text)], children: children)
    }

    /// Two paragraphs: "hello world" then "say hello again", root order.
    private func twoParagraphFixture() -> (ast: DocumentAST, aID: UUID, bID: UUID) {
        let aID = UUID()
        let bID = UUID()
        var ast = DocumentAST()
        ast.blocks[aID] = block(.paragraph, text: "hello world", id: aID)
        ast.blocks[bID] = block(.paragraph, text: "say hello again", id: bID)
        ast.rootChildren = [aID, bID]
        return (ast, aID, bID)
    }

    // MARK: - Core correctness property: offsets compose with Doc.plainText(of:)

    func testSearchMatchOffsetsComposeWithDocPlainTextToReproduceMatchedSubstringExactly() {
        let (ast, _, _) = twoParagraphFixture()
        let matches = DocumentSearchIndex.search("hello", in: ast, options: .init(caseSensitive: true))
        XCTAssertEqual(matches.count, 2, "literal 'hello' occurs once in each of the two paragraphs")

        let plainText = Doc.plainText(of: ast)
        let utf16 = Array(plainText.utf16)
        for match in matches {
            XCTAssertTrue(match.rangeStart >= 0 && match.rangeEnd <= utf16.count && match.rangeStart < match.rangeEnd,
                           "match range must be a valid, non-empty slice of Doc.plainText(of:)'s UTF-16 view")
            let sliced = String(utf16CodeUnits: Array(utf16[match.rangeStart..<match.rangeEnd]), count: match.rangeEnd - match.rangeStart)
            XCTAssertEqual(sliced, "hello", "the sliced substring at the match's own offsets must reproduce the literal matched text exactly")
        }
    }

    /// Case-insensitive search (the default) still returns offsets that
    /// slice back to the ACTUAL on-disk text, not the query's casing.
    func testCaseInsensitiveSearchOffsetsReproduceOnDiskCasingNotQueryCasing() {
        let (ast, _, _) = twoParagraphFixture()
        let matches = DocumentSearchIndex.search("HELLO", in: ast) // default caseSensitive: false
        XCTAssertEqual(matches.count, 2)
        let plainText = Doc.plainText(of: ast)
        let utf16 = Array(plainText.utf16)
        for match in matches {
            let sliced = String(utf16CodeUnits: Array(utf16[match.rangeStart..<match.rangeEnd]), count: match.rangeEnd - match.rangeStart)
            XCTAssertEqual(sliced, "hello", "the on-disk text is lowercase; the match must reproduce it verbatim, not the query's casing")
        }
    }

    func testCaseSensitiveSearchExcludesDifferentlyCasedOccurrences() {
        let aID = UUID()
        var ast = DocumentAST()
        ast.blocks[aID] = block(.paragraph, text: "Hello hello HELLO", id: aID)
        ast.rootChildren = [aID]
        let matches = DocumentSearchIndex.search("hello", in: ast, options: .init(caseSensitive: true))
        XCTAssertEqual(matches.count, 1, "case-sensitive search must match only the literal lowercase occurrence")
    }

    // MARK: - Per-block matching is the default; crossBlock is explicit opt-in

    func testDefaultSearchDoesNotMatchAcrossABlockBoundary() {
        let (ast, _, _) = twoParagraphFixture()
        // "world\nsay" only exists once the two blocks are joined with "\n" -
        // it cannot appear inside either block's own text alone.
        let matches = DocumentSearchIndex.search("world\nsay", in: ast, options: .init(caseSensitive: true))
        XCTAssertTrue(matches.isEmpty, "per-block matching (the default) must never let a match span two different blocks")
    }

    func testCrossBlockOptInFindsAMatchSpanningTwoBlocks() {
        let (ast, aID, _) = twoParagraphFixture()
        let matches = DocumentSearchIndex.search("world\nsay", in: ast, options: .init(caseSensitive: true, crossBlock: true))
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.blockID, aID, "a cross-block match's blockID is the block owning the match's START")
    }

    func testEmptyQueryReturnsNoMatches() {
        let (ast, _, _) = twoParagraphFixture()
        XCTAssertEqual(DocumentSearchIndex.search("", in: ast), [])
    }

    func testSearchOverEmptyDocumentReturnsNoMatches() {
        XCTAssertEqual(DocumentSearchIndex.search("anything", in: .empty), [])
    }

    // MARK: - Replace-all: ONE mutation, back-to-front, correct final text

    func testReplaceAllOfMultipleMatchesInOneBlockAppliesBackToFrontCorrectly() {
        let id = UUID()
        var ast = DocumentAST()
        // A shorter->longer replacement would corrupt later-match offsets
        // if applied front-to-back without remapping; back-to-front makes
        // this correct regardless of length delta.
        ast.blocks[id] = block(.paragraph, text: "cat and cat", id: id)
        ast.rootChildren = [id]

        let (result, replacedCount, _) = DocumentSearchIndex.replacingAll("cat", with: "elephant", in: ast, options: .init(caseSensitive: true))

        XCTAssertEqual(replacedCount, 2)
        XCTAssertEqual(result.blocks[id]?.content.map(\.text).joined(), "elephant and elephant")
    }

    func testReplaceAllOfAdjacentMatchesEqualsSequentialSingleReplaces() {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = block(.paragraph, text: "aaaa", id: id)
        ast.rootChildren = [id]

        // findAllRanges is non-overlapping, so "aaaa" against "aa" yields
        // two adjacent matches: [0,2) and [2,4).
        let (result, replacedCount, _) = DocumentSearchIndex.replacingAll("aa", with: "b", in: ast, options: .init(caseSensitive: true))
        XCTAssertEqual(replacedCount, 2)
        XCTAssertEqual(result.blocks[id]?.content.map(\.text).joined(), "bb",
                        "replacing both adjacent matches must equal doing each single replace in sequence")
    }

    func testReplaceAllPreservesRunAnnotationsOutsideTheReplacedRange() {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .paragraph, content: [
            InlineRun(text: "bold cat text", annotations: [.bold])
        ])
        ast.rootChildren = [id]
        let (result, _, _) = DocumentSearchIndex.replacingAll("cat", with: "dog", in: ast, options: .init(caseSensitive: true))
        let runs = result.blocks[id]?.content ?? []
        XCTAssertEqual(runs.map(\.text).joined(), "bold dog text")
        XCTAssertTrue(runs.allSatisfy { $0.annotations == [.bold] }, "every resulting run must keep the original run's annotations")
    }

    func testReplaceAllWithNoMatchesReturnsZeroCountAndUnchangedDocument() throws {
        let (ast, _, _) = twoParagraphFixture()
        let originalHash = try ast.contentHash()
        let (result, replacedCount, _) = DocumentSearchIndex.replacingAll("xyzzy", with: "q", in: ast)
        XCTAssertEqual(replacedCount, 0)
        XCTAssertEqual(try result.contentHash(), originalHash)
    }

    /// A crossBlock match cannot be traced back to one block's own
    /// `content` array, so it is silently excluded from the MUTATION even
    /// though `search` itself still reports it.
    func testReplaceAllExcludesACrossBlockMatchFromTheMutation() throws {
        let (ast, _, _) = twoParagraphFixture()
        let originalHash = try ast.contentHash()
        let (result, replacedCount, _) = DocumentSearchIndex.replacingAll(
            "world\nsay", with: "X", in: ast, options: .init(caseSensitive: true, crossBlock: true)
        )
        XCTAssertEqual(replacedCount, 0, "a match spanning a block boundary cannot be spliced into one block's content")
        XCTAssertEqual(try result.contentHash(), originalHash, "the document must be unchanged when every match was excluded")
    }

    // MARK: - Receipt payload shape (doctrine rule 1: named payload keys)

    func testReceiptPayloadCarriesTheDocumentedFields() {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = block(.paragraph, text: "cat cat", id: id)
        ast.rootChildren = [id]

        let (_, replacedCount, payload) = DocumentSearchIndex.replacingAll(
            "cat", with: "dog", in: ast, options: .init(caseSensitive: true, crossBlock: false)
        )
        XCTAssertEqual(replacedCount, 2)
        XCTAssertEqual(payload["query"], .string("cat"))
        XCTAssertEqual(payload["replacement"], .string("dog"))
        XCTAssertEqual(payload["caseSensitive"], .bool(true))
        XCTAssertEqual(payload["crossBlock"], .bool(false))
        XCTAssertEqual(payload["replacedCount"], .number(2))
        guard case .array(let blockIDs)? = payload["blockIDs"] else {
            return XCTFail("payload[\"blockIDs\"] must be a JSON array")
        }
        XCTAssertEqual(blockIDs, [.string(id.uuidString)])
    }

    // MARK: - Callout/table/list coordinate agreement with Doc.plainText(of:)

    func testCalloutPrefixOffsetAgreesWithDocPlainTextCoordinates() {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = block(.callout, text: "warning text", id: id, attributes: ["emoji": .string("!! ")])
        ast.rootChildren = [id]

        let matches = DocumentSearchIndex.search("warning", in: ast, options: .init(caseSensitive: true))
        XCTAssertEqual(matches.count, 1)
        let plainText = Doc.plainText(of: ast)
        let utf16 = Array(plainText.utf16)
        let match = matches[0]
        let sliced = String(utf16CodeUnits: Array(utf16[match.rangeStart..<match.rangeEnd]), count: match.rangeEnd - match.rangeStart)
        XCTAssertEqual(sliced, "warning", "a callout's emoji-prefix offset bookkeeping must not perturb match slicing against Doc.plainText(of:)")
    }
}
