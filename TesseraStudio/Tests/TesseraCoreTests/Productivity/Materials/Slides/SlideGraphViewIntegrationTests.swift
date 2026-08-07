import XCTest
@testable import TesseraCore

final class SlideGraphViewIntegrationTests: XCTestCase {

    func testSlideNodeRenders() {
        let node = GraphNode(id: UUID(), entityType: "document", subtype: "slide", label: "Q3 Deck", importance: 0.5, updatedAt: Date())
        XCTAssertEqual(node.iconName, "rectangle.on.rectangle")
        XCTAssertEqual(node.subtype, "slide")
    }

    func testSlideIconViaSubtype() {
        XCTAssertEqual(GraphNode.iconName(for: "document", subtype: "slide"), "rectangle.on.rectangle")
    }

    func testSlideTypeChipPresent() throws {
        let path = "TesseraStudio/Sources/TesseraCore/Productivity/Graph/GraphView.swift"
        let candidates = [path, "../" + path, "../../" + path]
        var source: String?
        for c in candidates {
            if FileManager.default.fileExists(atPath: c) {
                source = try String(contentsOf: URL(fileURLWithPath: c), encoding: .utf8)
                break
            }
        }
        guard let s = source else { throw XCTSkip("GraphView.swift not found") }
        XCTAssertTrue(s.contains("(\"slide\", \"rectangle.on.rectangle\")"), "missing slide chip")
    }

    func testSlideSnapshotLinkWalk() {
        let deckID = UUID()
        let noteID = UUID()
        let deckNode = GraphNode(id: deckID, entityType: "document", subtype: "slide", label: "Deck", importance: 0.5, updatedAt: Date())
        let noteNode = GraphNode(id: noteID, entityType: "note", label: "Note", importance: 0.5, updatedAt: Date())
        let edge = GraphEdge(id: UUID(), sourceID: deckID, targetID: noteID, linkType: "related_to", weight: 1)
        let snap = GraphSnapshot(nodes: [deckNode, noteNode], edges: [edge])
        XCTAssertTrue(snap.neighbors(of: deckID).contains(noteID))
    }

    func testHybridSearchResultSubtype() {
        let r = HybridSearchResult(entityID: UUID(), entityType: "document", subtype: "slide", label: "Deck", body: nil, graphScore: 1, vectorScore: 0, keywordScore: 0, rrfScore: 1)
        XCTAssertEqual(r.subtype, "slide")
    }
}
