import XCTest
import Foundation
@testable import TesseraCore

// MARK: - LayerStoreTests
//
// Contract source: LayerStore.swift's own header + doc comments, which
// state the design contract directly (studio-expansion-design-
// refinement-2026-08-14.md's Draw cluster, item 1.15): paint order =
// stable sort by (band, zIndex); band -1 for unassigned/dangling
// layerID sorts before every real layer; renderList additionally drops
// shapes on a hidden layer WITHOUT touching zIndex.

final class LayerStoreTests: DoctrineTestCase {

    private func rectShape(zIndex: Int, layerID: UUID? = nil) -> Shape {
        var shape = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 1, height: 1), zIndex: zIndex)
        shape.layerID = layerID
        return shape
    }

    // MARK: paintOrder

    func testPaintOrderSortsByLayerBandThenZIndex() {
        let back = DrawLayer(name: "Back")
        let front = DrawLayer(name: "Front")
        let layers = [back, front]

        let shapeOnFront = rectShape(zIndex: 0, layerID: front.id)
        let shapeOnBack = rectShape(zIndex: 5, layerID: back.id)

        let order = LayerStore.paintOrder(shapes: [shapeOnFront, shapeOnBack], layers: layers)

        XCTAssertEqual(order.map(\.id), [shapeOnBack.id, shapeOnFront.id], "layer band dominates zIndex: the back-layer shape paints first even though its own zIndex is higher")
    }

    func testPaintOrderPlacesUnassignedShapesBeforeEveryNamedLayer() {
        let named = DrawLayer(name: "Named")
        let unassigned = rectShape(zIndex: 100, layerID: nil)
        let onNamed = rectShape(zIndex: 0, layerID: named.id)

        let order = LayerStore.paintOrder(shapes: [onNamed, unassigned], layers: [named])

        XCTAssertEqual(order.map(\.id), [unassigned.id, onNamed.id])
    }

    func testPaintOrderTreatsDanglingLayerIDAsUnassigned() {
        let named = DrawLayer(name: "Named")
        let dangling = rectShape(zIndex: 0, layerID: UUID()) // no matching DrawLayer
        let onNamed = rectShape(zIndex: 999, layerID: named.id)

        let order = LayerStore.paintOrder(shapes: [onNamed, dangling], layers: [named])

        XCTAssertEqual(order.map(\.id), [dangling.id, onNamed.id])
    }

    func testPaintOrderIsStableForShapesTiedOnBandAndZIndex() {
        // Two shapes with the SAME (band, zIndex): relative order in
        // the input array must be preserved (stable sort).
        let a = rectShape(zIndex: 0)
        let b = rectShape(zIndex: 0)
        let order = LayerStore.paintOrder(shapes: [a, b], layers: [])
        XCTAssertEqual(order.map(\.id), [a.id, b.id])

        let reversedOrder = LayerStore.paintOrder(shapes: [b, a], layers: [])
        XCTAssertEqual(reversedOrder.map(\.id), [b.id, a.id])
    }

    // MARK: renderList

    func testRenderListDropsShapesOnAHiddenLayerWithoutMutatingZIndex() {
        let hidden = DrawLayer(name: "Hidden", isVisible: false)
        let visible = DrawLayer(name: "Visible", isVisible: true)
        let onHidden = rectShape(zIndex: 3, layerID: hidden.id)
        let onVisible = rectShape(zIndex: 1, layerID: visible.id)

        let rendered = LayerStore.renderList(shapes: [onHidden, onVisible], layers: [hidden, visible])

        XCTAssertEqual(rendered.map(\.id), [onVisible.id])
        // paintOrder (which renderList filters, not re-sorts) leaves
        // zIndex completely untouched - hiding a layer is a pure read-path
        // filter, per the file's own header comment.
        XCTAssertEqual(onHidden.zIndex, 3)
    }

    func testRenderListKeepsUnassignedShapesRegardlessOfAnyLayerVisibility() {
        let hidden = DrawLayer(name: "Hidden", isVisible: false)
        let unassigned = rectShape(zIndex: 0, layerID: nil)

        let rendered = LayerStore.renderList(shapes: [unassigned], layers: [hidden])

        XCTAssertEqual(rendered.map(\.id), [unassigned.id])
    }

    // MARK: property - renderList is always a subsequence of paintOrder

    func testRenderListIsAlwaysASubsequenceOfPaintOrder() {
        let l1 = DrawLayer(name: "L1", isVisible: true)
        let l2 = DrawLayer(name: "L2", isVisible: false)
        let shapes = (0..<6).map { i in rectShape(zIndex: i, layerID: i.isMultiple(of: 2) ? l1.id : l2.id) }
        let layers = [l1, l2]

        let order = LayerStore.paintOrder(shapes: shapes, layers: layers).map(\.id)
        let rendered = LayerStore.renderList(shapes: shapes, layers: layers).map(\.id)

        var orderIterator = order.makeIterator()
        for renderedID in rendered {
            var found = false
            while let next = orderIterator.next() {
                if next == renderedID { found = true; break }
            }
            XCTAssertTrue(found, "renderList must preserve paintOrder's relative ordering (it only filters, never reorders)")
        }
    }
}
