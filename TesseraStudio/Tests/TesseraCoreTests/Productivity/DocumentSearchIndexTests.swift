import XCTest
@testable import TesseraCore

final class DocumentSearchIndexTests: XCTestCase {

    // MARK: - Fixtures

    /// Three paragraph/heading blocks with a deliberate case mismatch
    /// ("The" vs "the") so case-sensitive and case-insensitive search
    /// can be told apart by match count.
    private func threeBlockDoc() -> (ast: DocumentAST, b1: UUID, b2: UUID, b3: UUID) {
        var ast = DocumentAST()
        let b1 = UUID()
        let b2 = UUID()
        let b3 = UUID()
        ast.blocks[b1] = Block(id: b1, type: .paragraph, content: [InlineRun(text: "The quick brown fox")])
        ast.blocks[b2] = Block(id: b2, type: .heading, content: [InlineRun(text: "jumps over the moon")])
        ast.blocks[b3] = Block(id: b3, type: .paragraph, content: [InlineRun(text: "the lazy dog")])
        ast.rootChildren = [b1, b2, b3]
        return (ast, b1, b2, b3)
    }

    /// Slices `Doc.plainText(of: ast)` at a match's UTF-16 range - the
    /// literal composition the design contract requires.
    private func slice(_ ast: DocumentAST, _ match: DocumentSearchIndex.SearchMatch) -> String {
        let plainText = Doc.plainText(of: ast)
        let start = String.Index(utf16Offset: match.rangeStart, in: plainText)
        let end = String.Index(utf16Offset: match.rangeEnd, in: plainText)
        return String(plainText[start..<end])
    }

    // MARK: - search: offsets compose with plainText()

    func testCaseSensitiveMatchOffsetsComposeWithPlainTextExactly() {
        let (ast, _, b2, b3) = threeBlockDoc()
        let matches = DocumentSearchIndex.search("the", in: ast, options: .init(caseSensitive: true))

        // "The" (capital T, block 1) must NOT match; "the" appears once
        // in block 2 and once in block 3.
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(Set(matches.map(\.blockID)), Set([b2, b3]))
        for match in matches {
            XCTAssertEqual(slice(ast, match), "the")
        }
    }

    func testCaseInsensitiveMatchOffsetsComposeWithPlainTextEvenWhenCaseDiffers() {
        let (ast, b1, b2, b3) = threeBlockDoc()
        let matches = DocumentSearchIndex.search("the", in: ast, options: .init(caseSensitive: false))

        XCTAssertEqual(matches.count, 3)
        XCTAssertEqual(Set(matches.map(\.blockID)), Set([b1, b2, b3]))
        for match in matches {
            let sliced = slice(ast, match)
            // Every slice is the query up to case ...
            XCTAssertEqual(sliced.lowercased(), "the")
            // ... and the block-1 match is the literal proof the offset
            // reproduces text that DIFFERS in case from the query.
            if match.blockID == b1 {
                XCTAssertEqual(sliced, "The")
                XCTAssertNotEqual(sliced, "the")
            } else {
                XCTAssertEqual(sliced, "the")
            }
        }
    }

    func testSearchReturnsEmptyForEmptyQuery() {
        let (ast, _, _, _) = threeBlockDoc()
        XCTAssertEqual(DocumentSearchIndex.search("", in: ast), [])
    }

    func testSearchMatchesAreInDocumentOrder() {
        var ast = DocumentAST()
        let ids = (0..<3).map { _ in UUID() }
        for (i, id) in ids.enumerated() {
            ast.blocks[id] = Block(id: id, type: .paragraph, content: [InlineRun(text: "marker \(i)")])
        }
        ast.rootChildren = ids

        let matches = DocumentSearchIndex.search("marker", in: ast, options: .init(caseSensitive: true))
        XCTAssertEqual(matches.map(\.blockID), ids)
    }

    // MARK: - search: per-block matching vs explicit crossBlock opt-in

    func testDefaultCrossBlockFalseDoesNotMatchAcrossBlockBoundary() {
        var ast = DocumentAST()
        let c1 = UUID()
        let c2 = UUID()
        ast.blocks[c1] = Block(id: c1, type: .paragraph, content: [InlineRun(text: "trailing end")])
        ast.blocks[c2] = Block(id: c2, type: .paragraph, content: [InlineRun(text: "Second line here")])
        ast.rootChildren = [c1, c2]

        // "end\nSecond" only exists once the two blocks' text is joined
        // by plainText()'s "\n" separator - per-block search must miss it.
        let matches = DocumentSearchIndex.search("end\nSecond", in: ast, options: .init(crossBlock: false))
        XCTAssertEqual(matches, [])
    }

    func testCrossBlockTrueFindsMatchSpanningBlockBoundary() {
        var ast = DocumentAST()
        let c1 = UUID()
        let c2 = UUID()
        ast.blocks[c1] = Block(id: c1, type: .paragraph, content: [InlineRun(text: "trailing end")])
        ast.blocks[c2] = Block(id: c2, type: .paragraph, content: [InlineRun(text: "Second line here")])
        ast.rootChildren = [c1, c2]

        let matches = DocumentSearchIndex.search("end\nSecond", in: ast, options: .init(crossBlock: true))
        XCTAssertEqual(matches.count, 1)
        let match = matches[0]
        XCTAssertEqual(slice(ast, match), "end\nSecond")
        // The match started inside c1's own entry.
        XCTAssertEqual(match.blockID, c1)
    }

    // MARK: - replacingAll: back-to-front application

    func testReplacingAllMultipleMatchesInSameBlockBackToFrontDoesNotCorruptOffsets() {
        var ast = DocumentAST()
        let bid = UUID()
        ast.blocks[bid] = Block(id: bid, type: .paragraph, content: [InlineRun(text: "cat cat cat")])
        ast.rootChildren = [bid]

        // Growing the matched text (3 chars -> 8 chars) means a naive
        // front-to-back pass using precomputed offsets would misalign
        // every match after the first; back-to-front must not.
        let result = DocumentSearchIndex.replacingAll(
            "cat", with: "elephant", in: ast, options: .init(caseSensitive: true)
        )

        XCTAssertEqual(result.replacedCount, 3)
        XCTAssertEqual(Doc.plainText(of: result.ast), "elephant elephant elephant")
        XCTAssertEqual(result.receiptPayload["replacedCount"]?.numberValue, 3)
        XCTAssertEqual(result.receiptPayload["receiptType"]?.stringValue, "doc_find_replace")
        XCTAssertEqual(result.receiptPayload["query"]?.stringValue, "cat")
        XCTAssertEqual(result.receiptPayload["replacement"]?.stringValue, "elephant")
        if case .array(let ids)? = result.receiptPayload["blockIDs"] {
            XCTAssertEqual(ids, [.string(bid.uuidString)])
        } else {
            XCTFail("expected blockIDs array in receiptPayload")
        }
    }

    func testReplacingAllAppliesOneCombinedMutationAcrossBlocks() {
        let (ast, b1, b2, b3) = threeBlockDoc()
        let result = DocumentSearchIndex.replacingAll(
            "the", with: "a", in: ast, options: .init(caseSensitive: false)
        )
        XCTAssertEqual(result.replacedCount, 3)
        let plainText = Doc.plainText(of: result.ast)
        XCTAssertFalse(plainText.lowercased().contains("the "))
        if case .array(let ids)? = result.receiptPayload["blockIDs"] {
            let expected: Set<JSONValue> = Set([b1, b2, b3].map { JSONValue.string($0.uuidString) })
            XCTAssertEqual(Set(ids), expected)
        } else {
            XCTFail("expected blockIDs array in receiptPayload")
        }
    }

    func testReplacingAllPreservesUnaffectedRunAnnotations() {
        var ast = DocumentAST()
        let bid = UUID()
        ast.blocks[bid] = Block(
            id: bid,
            type: .paragraph,
            content: [
                InlineRun(text: "Hello ", annotations: []),
                InlineRun(text: "world", annotations: [.bold]),
            ]
        )
        ast.rootChildren = [bid]

        let result = DocumentSearchIndex.replacingAll("world", with: "there", in: ast, options: .init(caseSensitive: true))
        XCTAssertEqual(result.replacedCount, 1)
        let content = result.ast.blocks[bid]?.content
        XCTAssertEqual(content, [
            InlineRun(text: "Hello ", annotations: []),
            InlineRun(text: "there", annotations: [.bold]),
        ])
    }

    func testReplacingAllNoMatchesReturnsUnchangedASTAndZeroCount() {
        let (ast, _, _, _) = threeBlockDoc()
        let result = DocumentSearchIndex.replacingAll("giraffe", with: "x", in: ast)
        XCTAssertEqual(result.replacedCount, 0)
        XCTAssertEqual(result.ast, ast)
        XCTAssertEqual(result.receiptPayload["replacedCount"]?.numberValue, 0)
        if case .array(let ids)? = result.receiptPayload["blockIDs"] {
            XCTAssertEqual(ids, [])
        } else {
            XCTFail("expected an (empty) blockIDs array in receiptPayload")
        }
    }
}
