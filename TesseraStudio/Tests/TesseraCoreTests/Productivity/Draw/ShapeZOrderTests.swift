import XCTest
@testable import TesseraCore

final class ShapeZOrderTests: XCTestCase {

    /// Three shapes, bottom to top: A(0), B(1), C(2).
    private func makeStack() -> (a: Shape, b: Shape, c: Shape, all: [Shape]) {
        let g = ShapeGeometry(x: 0, y: 0, width: 10, height: 10)
        let a = Shape(kind: .rect, geometry: g, zIndex: 0)
        let b = Shape(kind: .rect, geometry: g, zIndex: 1)
        let c = Shape(kind: .rect, geometry: g, zIndex: 2)
        return (a, b, c, [a, b, c])
    }

    private func order(_ shapes: [Shape]) -> [Shape] {
        shapes.sorted { $0.zIndex < $1.zIndex }
    }

    func testBringForwardSwapsWithTheShapeAbove() {
        let s = makeStack()
        let result = order(ShapeZOrder.apply(.bringForward, to: s.a.id, in: s.all))
        XCTAssertEqual(result.map(\.id), [s.b.id, s.a.id, s.c.id])
        // Renumbered densely, not just the moved shape.
        XCTAssertEqual(result.map(\.zIndex), [0, 1, 2])
    }

    func testSendBackwardSwapsWithTheShapeBelow() {
        let s = makeStack()
        let result = order(ShapeZOrder.apply(.sendBackward, to: s.c.id, in: s.all))
        XCTAssertEqual(result.map(\.id), [s.a.id, s.c.id, s.b.id])
    }

    func testBringToFrontMovesAllTheWayToTheTop() {
        let s = makeStack()
        let result = order(ShapeZOrder.apply(.toFront, to: s.a.id, in: s.all))
        XCTAssertEqual(result.map(\.id), [s.b.id, s.c.id, s.a.id])
    }

    func testSendToBackMovesAllTheWayToTheBottom() {
        let s = makeStack()
        let result = order(ShapeZOrder.apply(.toBack, to: s.c.id, in: s.all))
        XCTAssertEqual(result.map(\.id), [s.c.id, s.a.id, s.b.id])
    }

    /// Already at the top/bottom: the move is a no-op on ORDER, but
    /// still renumbers densely (idempotent, not a special-cased skip
    /// that could leave stale indices from an earlier, sparser state).
    func testBringForwardAtTheTopIsANoOp() {
        let s = makeStack()
        let result = order(ShapeZOrder.apply(.bringForward, to: s.c.id, in: s.all))
        XCTAssertEqual(result.map(\.id), [s.a.id, s.b.id, s.c.id])
    }

    func testSendBackwardAtTheBottomIsANoOp() {
        let s = makeStack()
        let result = order(ShapeZOrder.apply(.sendBackward, to: s.a.id, in: s.all))
        XCTAssertEqual(result.map(\.id), [s.a.id, s.b.id, s.c.id])
    }

    /// An id that isn't in the array is a no-op, not a crash - the
    /// caller may be racing a concurrent delete.
    func testUnknownIDIsANoOp() {
        let s = makeStack()
        let result = ShapeZOrder.apply(.toFront, to: UUID(), in: s.all)
        XCTAssertEqual(Set(result.map(\.id)), Set(s.all.map(\.id)))
    }

    /// Composed moves must keep converging correctly - no drift from
    /// repeated renumbering.
    func testComposedMoves() {
        let s = makeStack()
        var current = s.all
        current = ShapeZOrder.apply(.bringForward, to: s.a.id, in: current) // B, A, C
        current = ShapeZOrder.apply(.toBack, to: s.c.id, in: current)       // C, B, A
        current = ShapeZOrder.apply(.sendBackward, to: s.a.id, in: current) // C, A, B
        XCTAssertEqual(order(current).map(\.id), [s.c.id, s.a.id, s.b.id])
        XCTAssertEqual(order(current).map(\.zIndex), [0, 1, 2])
    }

    /// The input need not arrive pre-sorted - paint order is
    /// established from zIndex, not array position.
    func testInputOrderDoesNotMatterOnlyZIndexDoes() {
        let s = makeStack()
        let shuffled = [s.c, s.a, s.b]
        let result = order(ShapeZOrder.apply(.bringForward, to: s.a.id, in: shuffled))
        XCTAssertEqual(result.map(\.id), [s.b.id, s.a.id, s.c.id])
    }
}
