import XCTest
@testable import TesseraCore

final class DocGraphViewIntegrationTests: XCTestCase {

    func testDocNodeRenders() {
        let id = UUID()
        let node = GraphNode(id: id, entityType: "document", subtype: "doc", label: "Design note", importance: 0.6, updatedAt: Date())
        XCTAssertEqual(node.iconName, "doc.text")
        XCTAssertEqual(node.subtype, "doc")
    }

    func testDocIconViaSubtype() {
        XCTAssertEqual(GraphNode.iconName(for: "document", subtype: "doc"), "doc.text")
    }

    func testDocTypeChipsPresent() throws {
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
        XCTAssertTrue(s.contains("(\"doc\", \"doc.text\")"), "missing doc chip")
    }

    func testMatchesTypeFilter() {
        let docNode = GraphNode(id: UUID(), entityType: "document", subtype: "doc", label: "D", importance: 1, updatedAt: Date())
        let sheetNode = GraphNode(id: UUID(), entityType: "document", subtype: "sheet", label: "S", importance: 1, updatedAt: Date())
        XCTAssertTrue(GraphViewModel.matchesTypeFilter(docNode, filter: ["doc"]))
        XCTAssertFalse(GraphViewModel.matchesTypeFilter(sheetNode, filter: ["doc"]))
        XCTAssertTrue(GraphViewModel.matchesTypeFilter(docNode, filter: ["document"]))
        XCTAssertTrue(GraphViewModel.matchesTypeFilter(sheetNode, filter: ["document"]))
    }

    func testDocSnapshotLinkWalk() {
        let docID = UUID()
        let contactID = UUID()
        let docNode = GraphNode(id: docID, entityType: "document", subtype: "doc", label: "Plan", importance: 0.5, updatedAt: Date())
        let contactNode = GraphNode(id: contactID, entityType: "contact", label: "Alice", importance: 0.5, updatedAt: Date())
        let edge = GraphEdge(id: UUID(), sourceID: docID, targetID: contactID, linkType: "related_to", weight: 1)
        let snap = GraphSnapshot(nodes: [docNode, contactNode], edges: [edge])
        XCTAssertEqual(snap.nodeCount, 2)
        XCTAssertTrue(snap.neighbors(of: docID).contains(contactID))
    }

    func testHybridSearchResultSubtype() {
        let r = HybridSearchResult(entityID: UUID(), entityType: "document", subtype: "doc", label: "D", body: nil, graphScore: 1, vectorScore: 0, keywordScore: 0, rrfScore: 1)
        XCTAssertEqual(r.subtype, "doc")
    }
}
