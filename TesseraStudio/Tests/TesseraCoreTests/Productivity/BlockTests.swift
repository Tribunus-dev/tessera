import XCTest
import CryptoKit
@testable import TesseraCore

/// Tests for the Block AST data model: BlockType, InlineRun,
/// Block, DocumentAST. Round-trip JSON serialization for every
/// block type and every inline annotation variant. Empty
/// document, deep nesting, content-hash stability.
final class BlockTests: XCTestCase {

    // MARK: - BlockType

    func testEveryBlockTypeRoundTrips() throws {
        for type in BlockType.allCases {
            let block = Block(
                id: UUID(),
                type: type,
                attributes: ["k": .string("v")],
                content: [InlineRun(text: "hi")]
            )
            let data = try JSONEncoder().encode(block)
            let decoded = try JSONDecoder().decode(Block.self, from: data)
            XCTAssertEqual(decoded.type, type, "round-trip failed for \(type)")
            XCTAssertEqual(decoded.attributes["k"]?.stringValue, "v")
        }
    }

    func testAllCasesPresent() {
        // Lock in the BlockType set. If a new case is added
        // intentionally, this test must be updated.
        let expected: Set<BlockType> = [
            .heading, .paragraph, .list, .listItem, .table, .tableCell,
            .image, .codeBlock, .callout, .divider, .quote, .toggle, .equation,
            // Track-changes and comment blocks (added after this test was
            // first written; the editor's review mode renders them).
            .trackInsertion, .trackDeletion, .comment,
            // Draw data model (P0 0.12): a single vector shape and a
            // group container over shape/shapeGroup members.
            .shape, .shapeGroup,
            // Writer section/frame (P0 0.5): multi-column/break regions
            // and anchored text-box containers.
            .section, .frame,
            // Chart (P1 1.3): series-typed chart spec via the
            // attributes["chart"] bridge, same pattern as .shape.
            .chart,
        ]
        XCTAssertEqual(Set(BlockType.allCases), expected)
    }

    // MARK: - Block + Shape

    func testShapeBlockRoundTripsThroughAttributes() {
        let shape = Shape(
            kind: .ellipse,
            geometry: ShapeGeometry(x: 10, y: 20, width: 30, height: 40, rotation: 15),
            fill: ShapeFill(colorHex: "#FF0000"),
            stroke: ShapeStroke(colorHex: "#000000", width: 2),
            zIndex: 3
        )
        var block = Block(shape: shape)
        XCTAssertEqual(block.type, .shape)
        XCTAssertEqual(block.shape, shape)

        // The bridge round-trips through attributes["shape"], not a
        // parallel field - confirm it actually landed there.
        XCTAssertNotNil(block.attributes["shape"])

        block.shape = nil
        XCTAssertNil(block.attributes["shape"])
        XCTAssertNil(block.shape)
    }

    func testShapeAccessorIsNilForNonShapeBlocks() {
        var block = Block(type: .paragraph)
        XCTAssertNil(block.shape)

        // Setting on a non-.shape block is a no-op (matches this file's
        // other attribute accessors, which don't validate `type` either).
        block.shape = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 1, height: 1))
        XCTAssertNil(block.shape)
        XCTAssertNil(block.attributes["shape"])
    }

    func testShapeGroupIsAPlainChildrenContainer() throws {
        let child = Block(shape: Shape(kind: .star, geometry: ShapeGeometry(x: 0, y: 0, width: 5, height: 5)))
        var group = Block(type: .shapeGroup)
        group.children = [child.id]
        let doc = DocumentAST(blocks: [group.id: group, child.id: child], rootChildren: [group.id])
        let decoded = try DocumentAST.from(jsonData: try doc.jsonData())
        XCTAssertEqual(decoded.blocks[group.id]?.children, [child.id])
        XCTAssertEqual(decoded.blocks[child.id]?.shape?.kind, .star)
    }

    // MARK: - Block + Frame

    func testFrameBlockRoundTripsThroughAttributes() {
        let props = FrameProperties(x: 5, y: 6, width: 100, height: 200, anchor: .page)
        var block = Block(type: .frame)
        block.frame = props
        XCTAssertEqual(block.frame, props)
        XCTAssertNotNil(block.attributes["frame"])

        block.frame = nil
        XCTAssertNil(block.attributes["frame"])
        XCTAssertNil(block.frame)
    }

    func testFrameAccessorIsNilForNonFrameBlocks() {
        var block = Block(type: .paragraph)
        block.frame = FrameProperties(x: 0, y: 0, width: 1, height: 1)
        XCTAssertNil(block.frame)
        XCTAssertNil(block.attributes["frame"])
    }

    func testFrameHoldsFlowedChildContent() throws {
        let paragraph = Block(type: .paragraph, content: [InlineRun(text: "boxed text")])
        var frame = Block(type: .frame)
        frame.frame = FrameProperties(x: 0, y: 0, width: 150, height: 50, anchor: .paragraph)
        frame.children = [paragraph.id]
        let doc = DocumentAST(blocks: [frame.id: frame, paragraph.id: paragraph], rootChildren: [frame.id])
        let decoded = try DocumentAST.from(jsonData: try doc.jsonData())
        XCTAssertEqual(decoded.blocks[frame.id]?.children, [paragraph.id])
        XCTAssertEqual(decoded.blocks[frame.id]?.frame?.anchor, .paragraph)
        XCTAssertEqual(decoded.blocks[paragraph.id]?.content.first?.text, "boxed text")
    }

    // MARK: - Section + SectionStore

    func testMakeSectionRegistersAndLinksASection() {
        let p1 = Block(type: .paragraph, content: [InlineRun(text: "one")])
        let p2 = Block(type: .paragraph, content: [InlineRun(text: "two")])
        var ast = DocumentAST(blocks: [p1.id: p1, p2.id: p2], rootChildren: [])
        let sectionBlock = SectionStore.makeSection(kind: .continuous, columns: 2, children: [p1.id, p2.id], in: &ast)
        ast.blocks[sectionBlock.id] = sectionBlock
        ast.rootChildren = [sectionBlock.id]

        XCTAssertEqual(sectionBlock.type, .section)
        XCTAssertEqual(sectionBlock.children, [p1.id, p2.id])
        let resolved = SectionStore.section(for: sectionBlock, in: ast)
        XCTAssertEqual(resolved?.columns, 2)
        XCTAssertEqual(resolved?.kind, .continuous)
    }

    func testSectionRoundTripsThroughDocumentMeta() throws {
        let p1 = Block(type: .paragraph, content: [InlineRun(text: "one")])
        let p2 = Block(type: .paragraph, content: [InlineRun(text: "two")])
        var ast = DocumentAST(blocks: [p1.id: p1, p2.id: p2], rootChildren: [])
        let sectionBlock = SectionStore.makeSection(kind: .nextPage, columns: 3, columnGap: 24, children: [p1.id, p2.id], in: &ast)
        ast.blocks[sectionBlock.id] = sectionBlock
        ast.rootChildren = [sectionBlock.id]

        let decoded = try DocumentAST.from(jsonData: try ast.jsonData())
        let decodedSection = decoded.blocks[sectionBlock.id].flatMap { SectionStore.section(for: $0, in: decoded) }
        XCTAssertEqual(decodedSection?.columns, 3)
        XCTAssertEqual(decodedSection?.columnGap, 24)
        XCTAssertEqual(decodedSection?.kind, .nextPage)
        XCTAssertEqual(decoded.blocks[sectionBlock.id]?.children, [p1.id, p2.id])
    }

    func testDocumentMetaWithoutSectionsKeyDecodesAsEmpty() throws {
        // Documents written before BlockType.section existed have a
        // "meta" object with no "sections" key at all - the decoder
        // must default to empty, not throw.
        let json = """
        {"blocks": {}, "rootChildren": [], "meta": {"pageLayout": {
            "pageWidth": 595, "pageHeight": 842,
            "marginTop": 72, "marginBottom": 72, "marginLeft": 72, "marginRight": 72,
            "columnCount": 1, "columnGap": 18, "pageColor": "#FFFFFF"
        }}}
        """
        let decoded = try DocumentAST.from(jsonData: Data(json.utf8))
        XCTAssertTrue(decoded.meta.sections.isEmpty)
        XCTAssertEqual(decoded.meta.pageLayout.pageWidth, 595)
    }

    // MARK: - InlineRun

    func testPlainInlineRun() throws {
        let run = InlineRun(text: "hello")
        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(InlineRun.self, from: data)
        XCTAssertEqual(decoded.text, "hello")
        XCTAssertTrue(decoded.annotations.isEmpty)
    }

    func testBoldAnnotation() throws {
        let run = InlineRun(text: "bold", annotations: [.bold])
        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(InlineRun.self, from: data)
        XCTAssertEqual(decoded.annotations, [.bold])
    }

    func testItalicAnnotation() throws {
        let run = InlineRun(text: "italic", annotations: [.italic])
        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(InlineRun.self, from: data)
        XCTAssertEqual(decoded.annotations, [.italic])
    }

    func testUnderlineAnnotation() throws {
        let run = InlineRun(text: "u", annotations: [.underline])
        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(InlineRun.self, from: data)
        XCTAssertEqual(decoded.annotations, [.underline])
    }

    func testStrikethroughAnnotation() throws {
        let run = InlineRun(text: "x", annotations: [.strikethrough])
        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(InlineRun.self, from: data)
        XCTAssertEqual(decoded.annotations, [.strikethrough])
    }

    func testCodeAnnotation() throws {
        let run = InlineRun(text: "code", annotations: [.code])
        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(InlineRun.self, from: data)
        XCTAssertEqual(decoded.annotations, [.code])
    }

    func testSubscriptAnnotation() throws {
        let run = InlineRun(text: "x", annotations: [.subscript])
        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(InlineRun.self, from: data)
        XCTAssertEqual(decoded.annotations, [.subscript])
    }

    func testSuperscriptAnnotation() throws {
        let run = InlineRun(text: "x", annotations: [.superscript])
        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(InlineRun.self, from: data)
        XCTAssertEqual(decoded.annotations, [.superscript])
    }

    func testLinkAnnotation() throws {
        let url = URL(string: "https://tessera.example")!
        let run = InlineRun(text: "link", annotations: [.link(url)])
        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(InlineRun.self, from: data)
        XCTAssertEqual(decoded.annotations.count, 1)
        if case .link(let decodedURL) = decoded.annotations[0] {
            XCTAssertEqual(decodedURL, url)
        } else {
            XCTFail("expected .link annotation")
        }
    }

    func testColorAnnotation() throws {
        let run = InlineRun(text: "c", annotations: [.color(hex: "#FF00FF")])
        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(InlineRun.self, from: data)
        XCTAssertEqual(decoded.annotations.count, 1)
        if case .color(let hex) = decoded.annotations[0] {
            XCTAssertEqual(hex, "#FF00FF")
        } else {
            XCTFail("expected .color annotation")
        }
    }

    func testMultipleAnnotationsOnOneRun() throws {
        let url = URL(string: "https://x")!
        let run = InlineRun(
            text: "combo",
            annotations: [.bold, .italic, .link(url), .color(hex: "#000")]
        )
        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(InlineRun.self, from: data)
        XCTAssertEqual(decoded.annotations.count, 4)
        XCTAssertTrue(decoded.annotations.contains(.bold))
        XCTAssertTrue(decoded.annotations.contains(.italic))
    }

    // MARK: - DocumentAST round-trip

    func testEmptyDocumentRoundTrip() throws {
        let doc = DocumentAST.empty
        let data = try doc.jsonData()
        let decoded = try DocumentAST.from(jsonData: data)
        XCTAssertTrue(decoded.blocks.isEmpty)
        XCTAssertTrue(decoded.rootChildren.isEmpty)
    }

    func testSingleBlockDocument() throws {
        let block = Block(
            type: .paragraph,
            content: [InlineRun(text: "hello world")]
        )
        let doc = DocumentAST(
            blocks: [block.id: block],
            rootChildren: [block.id]
        )
        let decoded = try DocumentAST.from(jsonData: try doc.jsonData())
        XCTAssertEqual(decoded.rootChildren, [block.id])
        XCTAssertEqual(decoded.blocks[block.id]?.type, .paragraph)
        XCTAssertEqual(decoded.blocks[block.id]?.content.first?.text, "hello world")
    }

    func testDeepNestingPreserved() throws {
        // Build a 100-deep nested list.
        var blocks: [UUID: Block] = [:]
        var currentParent: UUID? = nil
        var lastID: UUID? = nil
        for depth in 0..<100 {
            let block = Block(
                type: .listItem,
                content: [InlineRun(text: "level \(depth)")],
                parentID: currentParent
            )
            blocks[block.id] = block
            if let pid = currentParent {
                blocks[pid]?.children.append(block.id)
            }
            currentParent = block.id
            lastID = block.id
        }
        let doc = DocumentAST(blocks: blocks, rootChildren: [blocks.first(where: { $0.value.parentID == nil })!.key])
        let decoded = try DocumentAST.from(jsonData: try doc.jsonData())

        // Walk the depth-first order; it should be exactly 100.
        XCTAssertEqual(decoded.depthFirstOrder().count, 100)
        // The deepest block's text should be preserved.
        XCTAssertEqual(
            decoded.blocks[lastID!]?.content.first?.text,
            "level 99"
        )
    }

    func testContentHashIsStable() throws {
        let block = Block(
            type: .paragraph,
            content: [InlineRun(text: "stable")]
        )
        let doc = DocumentAST(
            blocks: [block.id: block],
            rootChildren: [block.id]
        )
        // Two hashes of the same document should be byte-equal.
        let h1 = try doc.contentHash()
        let h2 = try doc.contentHash()
        XCTAssertEqual(h1, h2)
        XCTAssertTrue(h1.hasPrefix("sha256:"))
        XCTAssertEqual(h1.count, "sha256:".count + 64)  // 32 bytes hex
    }

    func testContentHashChangesWhenContentChanges() throws {
        let b1 = Block(
            id: UUID(),
            type: .paragraph,
            content: [InlineRun(text: "v1")]
        )
        let b2 = Block(
            id: b1.id,
            type: .paragraph,
            content: [InlineRun(text: "v2")]
        )
        let doc1 = DocumentAST(blocks: [b1.id: b1], rootChildren: [b1.id])
        let doc2 = DocumentAST(blocks: [b2.id: b2], rootChildren: [b2.id])
        XCTAssertNotEqual(try doc1.contentHash(), try doc2.contentHash())
    }

    func testDepthFirstOrderEmpty() {
        let doc = DocumentAST.empty
        XCTAssertEqual(doc.depthFirstOrder(), [])
    }

    func testDepthFirstOrderSingleRoot() {
        let block = Block(type: .paragraph)
        let doc = DocumentAST(
            blocks: [block.id: block],
            rootChildren: [block.id]
        )
        XCTAssertEqual(doc.depthFirstOrder(), [block.id])
    }

    func testDepthFirstOrderSiblingOrder() {
        let a = Block(type: .paragraph)
        let b = Block(type: .paragraph)
        let c = Block(type: .paragraph)
        let doc = DocumentAST(
            blocks: [a.id: a, b.id: b, c.id: c],
            rootChildren: [a.id, b.id, c.id]
        )
        XCTAssertEqual(doc.depthFirstOrder(), [a.id, b.id, c.id])
    }

    func testChildrenOf() {
        let parent = Block(type: .list)
        let child1 = Block(type: .listItem, parentID: parent.id)
        let child2 = Block(type: .listItem, parentID: parent.id)
        let doc = DocumentAST(
            blocks: [
                parent.id: parent,
                child1.id: child1,
                child2.id: child2
            ],
            rootChildren: [parent.id]
        )
        // Update parent's children after construction.
        var updatedDoc = doc
        updatedDoc.blocks[parent.id]?.children = [child1.id, child2.id]
        XCTAssertEqual(updatedDoc.children(of: nil), [parent.id])
        XCTAssertEqual(updatedDoc.children(of: parent.id), [child1.id, child2.id])
    }

    func testContains() {
        let block = Block(type: .paragraph)
        let doc = DocumentAST(blocks: [block.id: block], rootChildren: [block.id])
        XCTAssertTrue(doc.contains(block.id))
        XCTAssertFalse(doc.contains(UUID()))
    }

    // MARK: - AnyCodable

    func testAnyCodableTypealiasIsJSONValue() {
        // The brief writes `AnyCodable`; we typealias to JSONValue.
        // Lock the alias in.
        let v: AnyCodable = .string("hello")
        XCTAssertEqual(v.stringValue, "hello")
    }
}
