import XCTest
@testable import TesseraCore

// MARK: - MasterDocSpecTests
//
// Contract: docs/.scratch/sota-p2-core-report.md section "2.11 Master
// documents" + AGENTS.md's P2-C track brief items 5-7:
//   "MasterDocSpec {parts: [UUID], continuousNumbering: Bool, partBreak:
//   .pageBreak|.sectionBreak} ... Parts are mirrored into the EXISTING
//   Doc.linkedEntityIDs ... parts stay independent Docs, the master body
//   is optional front matter, no sync-back, no live transclusion."
//   "Assembly logic: concatenate part ASTs with breaks, merge
//   StyleRegistries (master wins on name collision ...), re-derive
//   note/sequence numbering ..., THROUGH the existing
//   DocumentExporter.export(_:to:destination:) ... A dangling part UUID
//   ... is skipped, named in a resulting receipt payload, not a crash."
//   "Tests: assembled plainText == parts joined with breaks; continuous
//   numbering re-derives 1..n across part boundaries; a dangling part
//   UUID is skipped and named; an absent-spec Doc decodes unchanged
//   (backward compat)."
//
// MasterDocController is pure (no DocStore) - see MasterDocSpec.swift's
// file header, which also records the judgment calls this suite tests
// against (break-as-divider, style-merge-without-basedOn-rewrite,
// continuousNumbering scoped to .sequence fields only).

final class MasterDocSpecTests: DoctrineTestCase {

    // MARK: - Fixture builders

    private func doc(id: UUID = UUID(), blocks: [Block], styles: [UUID: StyleDefinition] = [:]) -> Doc {
        var ast = DocumentAST()
        for block in blocks { ast.blocks[block.id] = block }
        ast.rootChildren = blocks.map(\.id)
        ast.meta.styles = styles
        return Doc(id: id, title: "", body: ast)
    }

    private func paragraph(id: UUID = UUID(), text: String) -> Block {
        Block(id: id, type: .paragraph, content: [InlineRun(text: text)])
    }

    private func sequenceFieldBlock(id: UUID = UUID(), name: String, cachedText: String) -> Block {
        var block = Block(id: id, type: .field, content: [InlineRun(text: cachedText)])
        block.field = FieldSpec(kind: .sequence(name: name), dirty: false)
        return block
    }

    // MARK: - assembled plainText == parts joined with breaks

    func testAssembledPlainTextEqualsPartsJoinedWithBreaks() {
        let part1 = doc(blocks: [paragraph(text: "Part One Line A"), paragraph(text: "Part One Line B")])
        let part2 = doc(blocks: [paragraph(text: "Part Two Line A")])
        let master = doc(blocks: []) // no front matter
        let spec = MasterDocSpec(parts: [part1.id, part2.id])
        let parts = [part1.id: part1, part2.id: part2]

        let result = MasterDocController.assemble(masterDoc: master, spec: spec) { parts[$0] }

        let expected = [Doc.plainText(of: part1.body), Doc.plainText(of: part2.body)].joined(separator: "\n")
        XCTAssertEqual(Doc.plainText(of: result.doc.body), expected, "breaks (dividers) contribute no text, so plainText must equal each part's own plainText joined by the same newline plainText already uses between blocks")
        XCTAssertTrue(result.skippedPartIDs.isEmpty)
    }

    func testAssembledPlainTextIncludesFrontMatterFirst() {
        let master = doc(blocks: [paragraph(text: "Front matter line")])
        let part = doc(blocks: [paragraph(text: "Part line")])
        let spec = MasterDocSpec(parts: [part.id])
        let parts = [part.id: part]

        let result = MasterDocController.assemble(masterDoc: master, spec: spec) { parts[$0] }
        XCTAssertEqual(Doc.plainText(of: result.doc.body), "Front matter line\nPart line")
    }

    // MARK: - continuousNumbering re-derives 1..n across part boundaries

    func testContinuousNumberingRederivesSequenceAcrossPartBoundaries() {
        let p1a = sequenceFieldBlock(name: "Figure", cachedText: "1")
        let p1b = sequenceFieldBlock(name: "Figure", cachedText: "2")
        let part1 = doc(blocks: [p1a, p1b])
        // Resolved independently within part2 ALONE before assembly -
        // exactly what a standalone Doc's own FieldController.refresh
        // pass would have cached.
        let p2a = sequenceFieldBlock(name: "Figure", cachedText: "1")
        let part2 = doc(blocks: [p2a])
        let master = doc(blocks: [])
        let parts = [part1.id: part1, part2.id: part2]

        let continuousResult = MasterDocController.assemble(
            masterDoc: master,
            spec: MasterDocSpec(parts: [part1.id, part2.id], continuousNumbering: true)
        ) { parts[$0] }
        let continuousTexts = [p1a.id, p1b.id, p2a.id].map { continuousResult.doc.body.blocks[$0]?.content.first?.text }
        XCTAssertEqual(continuousTexts, ["1", "2", "3"], "continuousNumbering must re-derive 1..n across the part boundary")

        let restartResult = MasterDocController.assemble(
            masterDoc: master,
            spec: MasterDocSpec(parts: [part1.id, part2.id], continuousNumbering: false)
        ) { parts[$0] }
        let restartTexts = [p1a.id, p1b.id, p2a.id].map { restartResult.doc.body.blocks[$0]?.content.first?.text }
        XCTAssertEqual(restartTexts, ["1", "2", "1"], "continuousNumbering == false must leave each part's own already-cached numbering untouched")
    }

    // MARK: - Dangling part UUID is skipped and named

    func testDanglingPartUUIDIsSkippedAndNamed() {
        let part1 = doc(blocks: [paragraph(text: "Real part")])
        let danglingID = UUID()
        let master = doc(blocks: [])
        let spec = MasterDocSpec(parts: [part1.id, danglingID])
        let parts = [part1.id: part1]

        let result = MasterDocController.assemble(masterDoc: master, spec: spec) { parts[$0] }
        XCTAssertEqual(result.skippedPartIDs, [danglingID], "the dangling id must be named, not merely counted")
        XCTAssertEqual(Doc.plainText(of: result.doc.body), "Real part", "a dangling part must contribute nothing to the assembled body, not crash")
    }

    // MARK: - Absent-spec Doc decodes unchanged (backward compat)
    //
    // PROXY test (documented limitation - see this wave's findings file
    // and wiringNotes): Doc.swift is not in this track's file list this
    // wave, so MasterDocSpec is not yet wired onto Doc as a real field.
    // This proves the exact decode contract the centralized pass's
    // future `Doc.masterDocSpec: MasterDocSpec?` field needs - an
    // absent JSON key decodes to nil via ordinary Codable synthesis for
    // an Optional property (no custom decodeIfPresent plumbing needed,
    // since MasterDocSpec carries no UUID-keyed dictionary requiring
    // the [String:V] bridge DocumentMeta needs elsewhere).

    func testMasterDocSpecDecodesAsAbsentOptionalFieldForBackwardCompat() throws {
        struct DocLikeContainer: Codable, Equatable {
            var title: String
            var masterDocSpec: MasterDocSpec?
        }
        // A "legacy" JSON payload with NO masterDocSpec key at all -
        // exactly what every Doc persisted before this wave looks like.
        let legacyJSON = Data(#"{"title":"Untitled"}"#.utf8)
        let decoded = try JSONDecoder().decode(DocLikeContainer.self, from: legacyJSON)
        XCTAssertNil(decoded.masterDocSpec, "an absent masterDocSpec key must decode to nil, not throw or default-construct a spec")
        XCTAssertEqual(decoded.title, "Untitled")
    }

    // MARK: - Round-trip identity (doctrine rule 2)

    func testMasterDocSpecEncodeDecodeIdentity() throws {
        let specs: [MasterDocSpec] = [
            MasterDocSpec(),
            MasterDocSpec(parts: [UUID(), UUID()], continuousNumbering: false, partBreak: .sectionBreak),
        ]
        for spec in specs {
            let data = try JSONEncoder().encode(spec)
            let decoded = try JSONDecoder().decode(MasterDocSpec.self, from: data)
            XCTAssertEqual(decoded, spec)
        }
    }

    // MARK: - applyingSpec: no-op on identical spec (item 5's wiring signal)

    func testApplyingSpecDetectsNoChangeOnIdenticalSpec() {
        let docID = UUID()
        let spec = MasterDocSpec(parts: [UUID()])
        let result = MasterDocController.applyingSpec(spec, over: spec, docID: docID)
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.receiptType, DocReceiptType.changeMasterParts.rawValue)
    }

    func testApplyingSpecDetectsChangeFromNilPreviousSpec() {
        let docID = UUID()
        let spec = MasterDocSpec(parts: [UUID()])
        let result = MasterDocController.applyingSpec(spec, over: nil, docID: docID)
        XCTAssertTrue(result.changed, "setting a spec where none existed before is a real change")
    }

    func testApplyingSpecDetectsChangeWhenPartsDiffer() {
        let docID = UUID()
        let original = MasterDocSpec(parts: [UUID()])
        let changed = MasterDocSpec(parts: [UUID(), UUID()])
        let result = MasterDocController.applyingSpec(changed, over: original, docID: docID)
        XCTAssertTrue(result.changed)
    }

    // MARK: - mirroringParts

    func testMirroringPartsAddsNewRemovesDroppedPreservesOtherLinks() {
        let unrelatedLink = UUID()
        let keptPart = UUID()
        let droppedPart = UUID()
        let addedPart = UUID()
        let existing = [unrelatedLink, keptPart, droppedPart]

        let result = MasterDocController.mirroringParts([keptPart, addedPart], previousParts: [keptPart, droppedPart], into: existing)

        XCTAssertFalse(result.contains(droppedPart), "a part removed from the spec must be dropped from linkedEntityIDs")
        XCTAssertTrue(result.contains(unrelatedLink), "a non-master-doc link must never be touched")
        XCTAssertTrue(result.contains(keptPart))
        XCTAssertTrue(result.contains(addedPart))
    }

    // MARK: - Style registry merge: master wins on name collision

    func testAssembleMergesStyleRegistriesMasterWinsOnNameCollisionAndRemapsPartStyleRefs() {
        let masterHeadingID = UUID()
        let masterHeading = StyleDefinition(id: masterHeadingID, name: "Heading 1", family: .paragraph)
        let master = doc(blocks: [], styles: [masterHeadingID: masterHeading])

        let partHeadingID = UUID()
        let partHeading = StyleDefinition(id: partHeadingID, name: "Heading 1", family: .paragraph) // same NAME, different id
        var styledBlock = paragraph(text: "Styled paragraph")
        styledBlock.styleRef = partHeadingID
        let part = doc(blocks: [styledBlock], styles: [partHeadingID: partHeading])

        let spec = MasterDocSpec(parts: [part.id])
        let parts = [part.id: part]
        let result = MasterDocController.assemble(masterDoc: master, spec: spec) { parts[$0] }

        XCTAssertNil(result.doc.body.meta.styles[partHeadingID], "the part's colliding style must be dropped, not duplicated")
        XCTAssertNotNil(result.doc.body.meta.styles[masterHeadingID], "master's own style survives")
        XCTAssertEqual(
            result.doc.body.blocks[styledBlock.id]?.styleRef, masterHeadingID,
            "the part block's styleRef must be remapped to the surviving (master's) style id"
        )
    }

    func testAssembleKeepsUniquelyNamedPartStyleUnchanged() {
        let master = doc(blocks: [])
        let uniqueStyleID = UUID()
        let uniqueStyle = StyleDefinition(id: uniqueStyleID, name: "Pull Quote", family: .paragraph)
        var styledBlock = paragraph(text: "Quoted")
        styledBlock.styleRef = uniqueStyleID
        let part = doc(blocks: [styledBlock], styles: [uniqueStyleID: uniqueStyle])

        let spec = MasterDocSpec(parts: [part.id])
        let parts = [part.id: part]
        let result = MasterDocController.assemble(masterDoc: master, spec: spec) { parts[$0] }

        XCTAssertNotNil(result.doc.body.meta.styles[uniqueStyleID], "a uniquely-named part style must survive the merge under its own id")
        XCTAssertEqual(result.doc.body.blocks[styledBlock.id]?.styleRef, uniqueStyleID, "no remap needed for a non-colliding style")
    }

    // MARK: - Break placement

    func testAssembleInsertsBreakBetweenFrontMatterAndFirstPart() {
        let master = doc(blocks: [paragraph(text: "Front matter")])
        let part = doc(blocks: [paragraph(text: "Part content")])
        let spec = MasterDocSpec(parts: [part.id], partBreak: .sectionBreak)
        let parts = [part.id: part]

        let result = MasterDocController.assemble(masterDoc: master, spec: spec) { parts[$0] }
        let breakBlocks = result.doc.body.rootChildren.compactMap { result.doc.body.blocks[$0] }.filter { $0.type == .divider }
        XCTAssertEqual(breakBlocks.count, 1)
        XCTAssertEqual(breakBlocks.first?.attributes["partBreak"]?.stringValue, "sectionBreak")
    }

    func testAssembleWithEmptyFrontMatterInsertsNoLeadingBreak() {
        let master = doc(blocks: [])
        let part = doc(blocks: [paragraph(text: "Only part")])
        let spec = MasterDocSpec(parts: [part.id])
        let parts = [part.id: part]

        let result = MasterDocController.assemble(masterDoc: master, spec: spec) { parts[$0] }
        let breakBlocks = result.doc.body.rootChildren.compactMap { result.doc.body.blocks[$0] }.filter { $0.type == .divider }
        XCTAssertTrue(breakBlocks.isEmpty, "an empty front matter must not produce a stray leading break")
    }

    // MARK: - Through the existing exporter (design contract's own phrasing)

    func testAssembledDocProducesHTMLThroughTheExistingExporter() throws {
        let part1 = doc(blocks: [paragraph(text: "Hello from part one")])
        let master = doc(blocks: [])
        let spec = MasterDocSpec(parts: [part1.id])
        let parts = [part1.id: part1]
        let result = MasterDocController.assemble(masterDoc: master, spec: spec) { parts[$0] }

        let html = try DocumentExporter().htmlPreview(result.doc)
        XCTAssertTrue(html.contains("Hello from part one"), "the assembled Doc must be a valid input to the EXISTING exporter, unmodified")
    }
}
