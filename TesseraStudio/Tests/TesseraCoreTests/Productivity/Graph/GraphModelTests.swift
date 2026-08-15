import XCTest
import SwiftUI
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Graph/GraphModel.swift
// doc comments (GraphNode.iconName(for:subtype:)/color(for:subtype:),
// GraphEdge.Style.from(linkType:)/lineWidth/color, GraphSnapshot.neighbors)
// plus Sources/TesseraCore/Productivity/Graph/GraphStore.swift's doc
// comment on `recomputeImportance` ("0.5 * normalizedDegree + 0.5 *
// recency"). No design doc names the Graph feature by file (fallback
// hierarchy: doc comments + AGENTS.md's material-type list). Doctrine
// rule 7: the icon/color fixtures below are an independent oracle --
// hand-picked from the doc comment's enumerated cases, not derived by
// iterating the switch statement.

final class GraphModelTests: DoctrineTestCase {

    private func makeNode(
        id: UUID = UUID(),
        entityType: String = "task",
        subtype: String? = nil,
        importance: Double = 0.5,
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        isPinned: Bool = false
    ) -> GraphNode {
        GraphNode(id: id, entityType: entityType, subtype: subtype, label: "A task", importance: importance, updatedAt: updatedAt, isPinned: isPinned)
    }

    // MARK: - GraphNode construction

    func testShortLabelIsCappedAt30Characters() {
        let longLabel = String(repeating: "x", count: 50)
        let node = GraphNode(id: UUID(), entityType: "note", label: longLabel, importance: 0, updatedAt: Date())
        XCTAssertEqual(node.shortLabel.count, 30)
    }

    func testShortLabelIsUnchangedWhenUnder30Characters() {
        let node = GraphNode(id: UUID(), entityType: "note", label: "short", importance: 0, updatedAt: Date())
        XCTAssertEqual(node.shortLabel, "short")
    }

    // MARK: - iconName(for:subtype:) fixtures

    func testIconNameFixtures() {
        let cases: [(String, String?, String)] = [
            ("document", nil, "doc.text"),
            ("document", "doc", "doc.text"),
            ("document", "sheet", "tablecells"),
            ("document", "slide", "rectangle.on.rectangle"),
            ("note", nil, "doc.text"),
            ("task", nil, "checkmark.square"),
            ("todo", nil, "checkmark.square"),
            ("reminder", nil, "bell"),
            ("calendar_event", nil, "calendar"),
            ("event", nil, "calendar"),
            ("email", nil, "envelope"),
            ("contact", nil, "person.crop.circle"),
            ("contact", "organization", "building.2"),
            ("contact", "group", "person.3"),
            ("spreadsheet", nil, "tablecells"),
            ("presentation", nil, "rectangle.on.rectangle"),
            ("code", nil, "chevron.left.forwardslash.chevron.right"),
            ("something_unknown", nil, "circle"),
        ]
        for (entityType, subtype, expected) in cases {
            XCTAssertEqual(GraphNode.iconName(for: entityType, subtype: subtype), expected, "\(entityType)/\(subtype ?? "nil")")
        }
    }

    // MARK: - color(for:subtype:) fixtures

    func testColorFixtures() {
        let cases: [(String, String?, Color)] = [
            ("document", nil, .blue),
            ("document", "sheet", .teal),
            ("document", "slide", .indigo),
            ("task", nil, .green),
            ("reminder", nil, .yellow),
            ("calendar_event", nil, .purple),
            ("email", nil, .pink),
            ("contact", nil, .orange),
            ("spreadsheet", nil, .teal),
            ("presentation", nil, .indigo),
            ("code", nil, .gray),
            ("something_unknown", nil, .secondary),
        ]
        for (entityType, subtype, expected) in cases {
            XCTAssertEqual(GraphNode.color(for: entityType, subtype: subtype), expected, "\(entityType)/\(subtype ?? "nil")")
        }
    }

    // MARK: - GraphEdge.Style

    func testEdgeStyleNormalForOrdinaryLinkType() {
        XCTAssertEqual(GraphEdge.Style.from(linkType: "related_to"), .normal)
    }

    func testEdgeStyleSupersededForSupersededPrefixedLinkType() {
        XCTAssertEqual(GraphEdge.Style.from(linkType: "superseded_by"), .superseded)
    }

    func testEdgeStyleVoidedForVoidedPrefixedLinkType() {
        XCTAssertEqual(GraphEdge.Style.from(linkType: "voided_by"), .voided)
    }

    // MARK: - GraphEdge.lineWidth (fixture + property: clamps to [0.5, 3.0])

    func testLineWidthAtWeightZeroIsTheMinimum() {
        let edge = GraphEdge(id: UUID(), sourceID: UUID(), targetID: UUID(), linkType: "related_to", weight: 0)
        XCTAssertEqual(edge.lineWidth, 0.5, accuracy: 0.001)
    }

    func testLineWidthNeverExceedsTheMaximum() {
        let edge = GraphEdge(id: UUID(), sourceID: UUID(), targetID: UUID(), linkType: "related_to", weight: 100)
        XCTAssertEqual(edge.lineWidth, 3.0, accuracy: 0.001)
    }

    func testLineWidthIsMonotonicInWeightBeforeClamping() {
        let low = GraphEdge(id: UUID(), sourceID: UUID(), targetID: UUID(), linkType: "related_to", weight: 0.1)
        let high = GraphEdge(id: UUID(), sourceID: UUID(), targetID: UUID(), linkType: "related_to", weight: 0.5)
        XCTAssertLessThan(low.lineWidth, high.lineWidth)
    }

    // MARK: - GraphSnapshot.neighbors

    func testNeighborsAtHopZeroReturnsOnlyTheNodeItself() {
        let a = makeNode()
        let b = makeNode()
        let edge = GraphEdge(id: UUID(), sourceID: a.id, targetID: b.id, linkType: "related_to", weight: 1)
        let snapshot = GraphSnapshot(nodes: [a, b], edges: [edge])
        XCTAssertEqual(snapshot.neighbors(of: a.id, hops: 0), [a.id])
    }

    func testNeighborsAtHopOneReturnsDirectNeighborsBothDirections() {
        let a = makeNode()
        let b = makeNode()
        let c = makeNode()
        let edgeAB = GraphEdge(id: UUID(), sourceID: a.id, targetID: b.id, linkType: "related_to", weight: 1)
        // c is only reachable via b, not a direct neighbor of a.
        let edgeBC = GraphEdge(id: UUID(), sourceID: b.id, targetID: c.id, linkType: "related_to", weight: 1)
        let snapshot = GraphSnapshot(nodes: [a, b, c], edges: [edgeAB, edgeBC])
        XCTAssertEqual(snapshot.neighbors(of: a.id, hops: 1), [a.id, b.id])
    }

    func testNeighborsExpandTransitivelyAtHopTwo() {
        let a = makeNode()
        let b = makeNode()
        let c = makeNode()
        let edgeAB = GraphEdge(id: UUID(), sourceID: a.id, targetID: b.id, linkType: "related_to", weight: 1)
        let edgeBC = GraphEdge(id: UUID(), sourceID: b.id, targetID: c.id, linkType: "related_to", weight: 1)
        let snapshot = GraphSnapshot(nodes: [a, b, c], edges: [edgeAB, edgeBC])
        XCTAssertEqual(snapshot.neighbors(of: a.id, hops: 2), [a.id, b.id, c.id])
    }

    func testNodeCountAndEdgeCount() {
        let a = makeNode()
        let b = makeNode()
        let edge = GraphEdge(id: UUID(), sourceID: a.id, targetID: b.id, linkType: "related_to", weight: 1)
        let snapshot = GraphSnapshot(nodes: [a, b], edges: [edge])
        XCTAssertEqual(snapshot.nodeCount, 2)
        XCTAssertEqual(snapshot.edgeCount, 1)
    }

    func testEmptySnapshotHasZeroNodesAndEdges() {
        XCTAssertEqual(GraphSnapshot.empty.nodeCount, 0)
        XCTAssertEqual(GraphSnapshot.empty.edgeCount, 0)
    }

    // MARK: - GraphStore.recomputeImportance (fixture + property, doctrine
    // rule 9): "0.5 * normalizedDegree + 0.5 * recency"

    func testRecomputeImportanceGivesHighestDegreeNodeTheHighestDegreeComponent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Same updatedAt for both nodes so recency contributes equally;
        // only degree differs.
        let hub = makeNode(updatedAt: now)
        let leaf = makeNode(updatedAt: now)
        let other = makeNode(updatedAt: now)
        let edges = [
            GraphEdge(id: UUID(), sourceID: hub.id, targetID: leaf.id, linkType: "related_to", weight: 1),
            GraphEdge(id: UUID(), sourceID: hub.id, targetID: other.id, linkType: "related_to", weight: 1),
        ]
        let recomputed = GraphStore.recomputeImportance(for: [hub, leaf, other], edges: edges)
        let hubScore = recomputed.first { $0.id == hub.id }!.importance
        let leafScore = recomputed.first { $0.id == leaf.id }!.importance
        XCTAssertGreaterThan(hubScore, leafScore)
    }

    func testRecomputeImportanceScoresAreClampedToUnitInterval() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let a = makeNode(updatedAt: now)
        let b = makeNode(updatedAt: now.addingTimeInterval(-1_000_000))
        let edge = GraphEdge(id: UUID(), sourceID: a.id, targetID: b.id, linkType: "related_to", weight: 1)
        let recomputed = GraphStore.recomputeImportance(for: [a, b], edges: [edge])
        for node in recomputed {
            XCTAssertGreaterThanOrEqual(node.importance, 0.0)
            XCTAssertLessThanOrEqual(node.importance, 1.0)
        }
    }

    func testRecomputeImportanceOfEmptyNodeListIsEmpty() {
        XCTAssertEqual(GraphStore.recomputeImportance(for: [], edges: []), [])
    }

    func testRecomputeImportancePreservesIsPinnedFlag() {
        let pinned = makeNode(isPinned: true)
        let recomputed = GraphStore.recomputeImportance(for: [pinned], edges: [])
        XCTAssertEqual(recomputed.first?.isPinned, true)
    }
}
