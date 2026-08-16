import XCTest
@testable import TesseraCore

// MARK: - TocControllerTests
//
// Contract: docs/.scratch/sota-p2-core-report.md section "2.5 ToC" +
// AGENTS.md's P2-C track brief item 1:
//   "TocSpec {fromLevel, toLevel, includeOutlineLevels (\u), hyperlink
//   (\h), extraStyles [styleRefUUID: level] (\t), tabLeader} stored at a
//   .toc block's attributes["toc"]. Collection algorithm: walk
//   document-order blocks whose resolved style chain reaches a
//   heading-family StyleDefinition in [fromLevel, toLevel] range, PLUS
//   .heading intrinsic levels, PLUS outline-level attrs when
//   includeOutlineLevels is set ... Regenerate produces entry-paragraph
//   Block children, each with attributes["tocEntry"] =
//   {targetBlockID, level, pageText, pageDirty} - pageText is cached ...
//   match [FieldKind.page's] same 'cached, dirty-until-a-paginator-
//   exists' stance exactly ... Regenerate is IDEMPOTENT: calling it
//   twice with no intervening document change must be detectable as a
//   no-op."
//   "Tests: regenerate idempotent (second call with no document change:
//   entries unchanged, and your API's own 'did anything change' signal
//   says so); adding a Heading-2 adds exactly one level-2 entry with a
//   correctly-resolving targetBlockID; a \u-flagged spec picks up
//   outline-level paragraphs."
//
// TocController is pure (no DocStore) - see the source file header.

final class TocControllerTests: DoctrineTestCase {

    // MARK: - Fixture builders

    private func headingBlock(id: UUID = UUID(), level: Int, text: String) -> Block {
        Block(id: id, type: .heading, attributes: ["level": .number(Double(level))], content: [InlineRun(text: text)])
    }

    private func tocBlock(id: UUID = UUID(), spec: TocSpec) -> Block {
        var block = Block(id: id, type: .toc)
        block.toc = spec
        return block
    }

    private func styledParagraph(id: UUID = UUID(), styleRef: UUID, text: String) -> Block {
        var block = Block(id: id, type: .paragraph, content: [InlineRun(text: text)])
        block.styleRef = styleRef
        return block
    }

    /// Assembles a `DocumentAST` with `blocks` as root children, in
    /// order, plus an optional style registry.
    private func makeAST(_ blocks: [Block], styles: [UUID: StyleDefinition] = [:]) -> DocumentAST {
        var ast = DocumentAST()
        for block in blocks {
            ast.blocks[block.id] = block
        }
        ast.rootChildren = blocks.map(\.id)
        ast.meta.styles = styles
        return ast
    }

    // MARK: - Guard-and-early-return no-ops

    func testRegenerateOnNonTocBlockIsANoOp() {
        let paragraph = Block(type: .paragraph, content: [InlineRun(text: "hello")])
        let ast = makeAST([paragraph])
        let (resultAST, result) = TocController.regenerate(paragraph.id, in: ast)
        XCTAssertEqual(resultAST, ast, "a non-.toc target must leave the document byte-for-byte unchanged")
        XCTAssertFalse(result.changed)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.receiptType, DocReceiptType.regenerateToc.rawValue)
    }

    func testRegenerateOnTocBlockWithNoSpecYetIsANoOp() {
        let toc = Block(type: .toc) // no attributes["toc"] set
        let ast = makeAST([toc])
        let (resultAST, result) = TocController.regenerate(toc.id, in: ast)
        XCTAssertEqual(resultAST, ast)
        XCTAssertFalse(result.changed)
    }

    // MARK: - Idempotence (the headline test contract)

    func testRegenerateSecondCallWithNoDocumentChangeIsANoOp() {
        let h1 = headingBlock(level: 1, text: "Introduction")
        let h2 = headingBlock(level: 2, text: "Background")
        let toc = tocBlock(spec: TocSpec())
        let ast = makeAST([toc, h1, h2])

        let (astAfterFirst, firstResult) = TocController.regenerate(toc.id, in: ast)
        XCTAssertTrue(firstResult.changed, "the first regenerate on an empty ToC must be a real mutation")
        XCTAssertEqual(firstResult.entryCount, 2)

        let (astAfterSecond, secondResult) = TocController.regenerate(toc.id, in: astAfterFirst)
        XCTAssertFalse(secondResult.changed, "no intervening document change must be detectable as a no-op via the result's own signal")
        XCTAssertEqual(secondResult.entries, firstResult.entries)
        XCTAssertEqual(astAfterSecond, astAfterFirst, "a no-op regenerate must return the exact prior document, not a rebuilt copy")
    }

    // MARK: - Adding a heading adds exactly one resolving entry

    func testAddingHeadingTwoAddsExactlyOneLevelTwoEntryWithResolvingTargetBlockID() {
        let h1 = headingBlock(level: 1, text: "Introduction")
        let toc = tocBlock(spec: TocSpec())
        var ast = makeAST([toc, h1])
        let (astAfterFirst, firstResult) = TocController.regenerate(toc.id, in: ast)
        XCTAssertEqual(firstResult.entryCount, 1)

        let h2 = headingBlock(level: 2, text: "Background")
        ast = astAfterFirst
        ast.blocks[h2.id] = h2
        ast.rootChildren.append(h2.id)

        let (_, secondResult) = TocController.regenerate(toc.id, in: ast)
        XCTAssertEqual(secondResult.entryCount, 2, "adding one new heading must add exactly one new entry")
        let newEntry = secondResult.entries.first { $0.targetBlockID == h2.id }
        XCTAssertNotNil(newEntry, "the new entry must resolve targetBlockID to the added heading's own id")
        XCTAssertEqual(newEntry?.level, 2)
    }

    // MARK: - fromLevel/toLevel range filtering

    func testHeadingOutsideFromToLevelRangeIsExcluded() {
        let h1 = headingBlock(level: 1, text: "Title")
        let h4 = headingBlock(level: 4, text: "Too deep")
        let toc = tocBlock(spec: TocSpec(fromLevel: 1, toLevel: 3))
        let ast = makeAST([toc, h1, h4])
        let (_, result) = TocController.regenerate(toc.id, in: ast)
        XCTAssertEqual(result.entries.map(\.targetBlockID), [h1.id], "a heading below toLevel must never appear as an entry")
    }

    // MARK: - includeOutlineLevels (\u)

    func testIncludeOutlineLevelsPicksUpOutlineLevelParagraphsWhenFlagSet() {
        let outlineParagraph = Block(
            id: UUID(),
            type: .paragraph,
            attributes: ["outlineLevel": .number(2)],
            content: [InlineRun(text: "Manually outlined")]
        )
        let toc = tocBlock(spec: TocSpec(includeOutlineLevels: true))
        let ast = makeAST([toc, outlineParagraph])
        let (_, result) = TocController.regenerate(toc.id, in: ast)
        XCTAssertEqual(result.entries.map(\.targetBlockID), [outlineParagraph.id])
        XCTAssertEqual(result.entries.first?.level, 2)
    }

    func testOutlineLevelParagraphIgnoredWhenIncludeOutlineLevelsNotSet() {
        let outlineParagraph = Block(
            id: UUID(),
            type: .paragraph,
            attributes: ["outlineLevel": .number(2)],
            content: [InlineRun(text: "Manually outlined")]
        )
        let toc = tocBlock(spec: TocSpec(includeOutlineLevels: false))
        let ast = makeAST([toc, outlineParagraph])
        let (_, result) = TocController.regenerate(toc.id, in: ast)
        XCTAssertTrue(result.entries.isEmpty, "an outline-level paragraph must not become an entry when \\u is off")
    }

    // MARK: - extraStyles override (\t) bypasses the range filter

    func testExtraStylesOverrideBypassesFromToLevelRange() {
        let captionStyleID = UUID()
        let captionStyle = StyleDefinition(id: captionStyleID, name: "Caption", family: .paragraph)
        let caption = styledParagraph(styleRef: captionStyleID, text: "Figure 1: a diagram")
        // fromLevel/toLevel is 1-1, well outside the extraStyles-assigned
        // level of 4 - the override must still collect it.
        let toc = tocBlock(spec: TocSpec(fromLevel: 1, toLevel: 1, extraStyles: [captionStyleID: 4]))
        let ast = makeAST([toc, caption], styles: [captionStyleID: captionStyle])
        let (_, result) = TocController.regenerate(toc.id, in: ast)
        XCTAssertEqual(result.entries.map(\.targetBlockID), [caption.id])
        XCTAssertEqual(result.entries.first?.level, 4, "extraStyles assigns its OWN level, ignoring the block's natural (non-heading) level")
    }

    // MARK: - Heading-family style resolved through the basedOn chain

    func testStyleRefResolvingToHeadingFamilyAncestorIsDetected() {
        let heading2StyleID = UUID()
        let heading2Style = StyleDefinition(id: heading2StyleID, name: "Heading 2", family: .paragraph)
        let customStyleID = UUID()
        let customStyle = StyleDefinition(id: customStyleID, name: "Custom Head", family: .paragraph, basedOn: heading2StyleID)
        let paragraph = styledParagraph(styleRef: customStyleID, text: "Styled like a heading")
        let toc = tocBlock(spec: TocSpec())
        let ast = makeAST([toc, paragraph], styles: [heading2StyleID: heading2Style, customStyleID: customStyle])
        let (_, result) = TocController.regenerate(toc.id, in: ast)
        XCTAssertEqual(result.entries.map(\.targetBlockID), [paragraph.id], "a style based on a heading-family style must still resolve via the basedOn chain, not just an exact name match")
        XCTAssertEqual(result.entries.first?.level, 2)
    }

    func testDanglingStyleRefIsFailSoftNotACrashOrFalseMatch() {
        let paragraph = styledParagraph(styleRef: UUID(), text: "Points at nothing")
        let toc = tocBlock(spec: TocSpec())
        let ast = makeAST([toc, paragraph])
        let (_, result) = TocController.regenerate(toc.id, in: ast)
        XCTAssertTrue(result.entries.isEmpty, "a styleRef absent from the registry must resolve as no heading family, not crash or false-match")
    }

    // MARK: - Page numbers: cached, carried forward, never invented (FieldKind.page stance)

    func testNewEntryStartsWithEmptyPageTextAndDirtyTrue() {
        let h1 = headingBlock(level: 1, text: "Introduction")
        let toc = tocBlock(spec: TocSpec())
        let ast = makeAST([toc, h1])
        let (_, result) = TocController.regenerate(toc.id, in: ast)
        XCTAssertEqual(result.entries.first?.pageText, "")
        XCTAssertEqual(result.entries.first?.pageDirty, true)
        XCTAssertEqual(result.dirtyPageCount, 1)
    }

    func testRegeneratePreservesCachedPageTextForAnUnmovedHeadingAcrossACall() throws {
        let h1 = headingBlock(level: 1, text: "Introduction")
        let toc = tocBlock(spec: TocSpec())
        var ast = makeAST([toc, h1])
        let (astAfterFirst, _) = TocController.regenerate(toc.id, in: ast)
        let entryBlockID = try XCTUnwrap(astAfterFirst.blocks[toc.id]?.children.first)

        // Simulate a paginator having resolved this entry's page number.
        ast = astAfterFirst
        var entryBlock = try XCTUnwrap(ast.blocks[entryBlockID])
        entryBlock.tocEntry = TocEntry(targetBlockID: h1.id, level: 1, pageText: "12", pageDirty: false)
        ast.blocks[entryBlockID] = entryBlock

        // Add an unrelated second heading so this regenerate call is a
        // real change (not the no-op path), and confirm the FIRST
        // entry's now-resolved page state survives untouched while the
        // brand-new second entry starts fresh.
        let h2 = headingBlock(level: 1, text: "Conclusion")
        ast.blocks[h2.id] = h2
        ast.rootChildren.append(h2.id)

        let (_, secondResult) = TocController.regenerate(toc.id, in: ast)
        let carriedEntry = try XCTUnwrap(secondResult.entries.first { $0.targetBlockID == h1.id })
        XCTAssertEqual(carriedEntry.pageText, "12", "an already-resolved entry's cached page text must survive a regenerate that didn't move it")
        XCTAssertEqual(carriedEntry.pageDirty, false)

        let freshEntry = try XCTUnwrap(secondResult.entries.first { $0.targetBlockID == h2.id })
        XCTAssertEqual(freshEntry.pageText, "")
        XCTAssertEqual(freshEntry.pageDirty, true)
    }

    // MARK: - Derived-never-stored: a renamed heading re-derives the entry's cached label

    func testRenamingAHeadingUpdatesTheEntrysCachedLabelOnNextRegenerate() throws {
        let h1 = headingBlock(level: 1, text: "Old Title")
        let toc = tocBlock(spec: TocSpec())
        var ast = makeAST([toc, h1])
        let (astAfterFirst, _) = TocController.regenerate(toc.id, in: ast)
        let entryBlockID = try XCTUnwrap(astAfterFirst.blocks[toc.id]?.children.first)
        XCTAssertEqual(astAfterFirst.blocks[entryBlockID]?.content.first?.text, "Old Title")

        ast = astAfterFirst
        var renamed = try XCTUnwrap(ast.blocks[h1.id])
        renamed.content = [InlineRun(text: "New Title")]
        ast.blocks[h1.id] = renamed

        let (astAfterSecond, secondResult) = TocController.regenerate(toc.id, in: ast)
        XCTAssertTrue(secondResult.changed, "a heading's text changing must count as a real change even though target/level/page state didn't move")
        let newEntryBlockID = try XCTUnwrap(astAfterSecond.blocks[toc.id]?.children.first)
        XCTAssertEqual(astAfterSecond.blocks[newEntryBlockID]?.content.first?.text, "New Title")
    }

    // MARK: - Round-trip identity (doctrine rule 2)

    func testTocSpecEncodeDecodeIdentity() throws {
        let specs: [TocSpec] = [
            TocSpec(),
            TocSpec(fromLevel: 2, toLevel: 5, includeOutlineLevels: true, hyperlink: false, extraStyles: [UUID(): 1, UUID(): 3], tabLeader: .dashes),
            TocSpec(tabLeader: .noLeader),
        ]
        for spec in specs {
            let data = try JSONEncoder().encode(spec)
            let decoded = try JSONDecoder().decode(TocSpec.self, from: data)
            XCTAssertEqual(decoded, spec)
        }
    }

    func testTocEntryEncodeDecodeIdentity() throws {
        let entries: [TocEntry] = [
            TocEntry(targetBlockID: UUID(), level: 1),
            TocEntry(targetBlockID: UUID(), level: 3, pageText: "42", pageDirty: false),
        ]
        for entry in entries {
            let data = try JSONEncoder().encode(entry)
            let decoded = try JSONDecoder().decode(TocEntry.self, from: data)
            XCTAssertEqual(decoded, entry)
        }
    }

    // MARK: - Block.toc / Block.tocEntry bridges

    func testBlockTocBridgeRoundTripsThroughAttributesOnTocBlock() {
        var block = Block(type: .toc)
        XCTAssertNil(block.toc)
        let spec = TocSpec(fromLevel: 2, toLevel: 4)
        block.toc = spec
        XCTAssertEqual(block.toc, spec)
        XCTAssertNotNil(block.attributes["toc"], "must be stored as a nested JSON object under attributes[\"toc\"]")
        block.toc = nil
        XCTAssertNil(block.attributes["toc"])
    }

    func testBlockTocBridgeIsNoOpOnNonTocBlock() {
        var paragraph = Block(type: .paragraph)
        paragraph.toc = TocSpec()
        XCTAssertNil(paragraph.toc, "setting .toc on a non-.toc block type must be a no-op")
        XCTAssertNil(paragraph.attributes["toc"])
    }

    func testBlockTocEntryBridgeRoundTripsOnAnOrdinaryParagraphBlock() {
        var paragraph = Block(type: .paragraph)
        XCTAssertNil(paragraph.tocEntry)
        let entry = TocEntry(targetBlockID: UUID(), level: 2, pageText: "7", pageDirty: false)
        paragraph.tocEntry = entry
        XCTAssertEqual(paragraph.tocEntry, entry, "tocEntry is NOT gated to .toc blocks - it marks an entry paragraph, a .paragraph block")
        paragraph.tocEntry = nil
        XCTAssertNil(paragraph.attributes["tocEntry"])
    }
}
