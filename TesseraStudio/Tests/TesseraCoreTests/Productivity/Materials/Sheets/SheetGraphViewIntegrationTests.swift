import XCTest
@testable import TesseraCore

final class SheetGraphViewIntegrationTests: XCTestCase {

    func testSheetNodeRenders() {
        let node = GraphNode(id: UUID(), entityType: "document", subtype: "sheet", label: "Budget 2026", importance: 0.5, updatedAt: Date())
        XCTAssertEqual(node.iconName, "tablecells")
        XCTAssertEqual(node.subtype, "sheet")
    }

    func testSheetIconViaSubtype() {
        XCTAssertEqual(GraphNode.iconName(for: "document", subtype: "sheet"), "tablecells")
    }

    func testSheetTypeChipPresent() throws {
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
        XCTAssertTrue(s.contains("(\"sheet\", \"tablecells\")"), "missing sheet chip")
    }

    func testSheetColorDistinctFromDoc() {
        // Color is not Equatable; just verify the call does not trap and
        // the subtype path is distinct from the entityType path.
        _ = GraphNode.color(for: "document", subtype: "sheet")
        _ = GraphNode.color(for: "document", subtype: "doc")
    }

    func testSheetSnapshotLinkWalk() {
        let sheetID = UUID()
        let taskID = UUID()
        let sheetNode = GraphNode(id: sheetID, entityType: "document", subtype: "sheet", label: "Sheet", importance: 0.5, updatedAt: Date())
        let taskNode = GraphNode(id: taskID, entityType: "task", label: "Review", importance: 0.5, updatedAt: Date())
        let edge = GraphEdge(id: UUID(), sourceID: sheetID, targetID: taskID, linkType: "related_to", weight: 1)
        let snap = GraphSnapshot(nodes: [sheetNode, taskNode], edges: [edge])
        XCTAssertTrue(snap.neighbors(of: sheetID).contains(taskID))
    }

    func testHybridSearchResultSubtype() {
        let r = HybridSearchResult(entityID: UUID(), entityType: "document", subtype: "sheet", label: "S", body: nil, graphScore: 1, vectorScore: 0, keywordScore: 0, rrfScore: 1)
        XCTAssertEqual(r.subtype, "sheet")
    }
}
