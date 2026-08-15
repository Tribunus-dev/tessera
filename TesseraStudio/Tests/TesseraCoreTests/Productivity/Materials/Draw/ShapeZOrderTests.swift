import XCTest
import Foundation
@testable import TesseraCore

// MARK: - ShapeZOrderTests
//
// Contract source: ShapeZOrder.swift's own doc comment (studio-
// expansion-plan.md row 46): bringForward/sendBackward/toFront/toBack;
// every call renumbers zIndex densely (0, 1, 2, ...) in the resulting
// paint order; moving an unknown id is a no-op returning the input
// array unchanged.

final class ShapeZOrderTests: DoctrineTestCase {

    private func shape(_ zIndex: Int) -> Shape {
        Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 1, height: 1), zIndex: zIndex)
    }

    func testBringForwardMovesOneStepUpAndRenumbersDensely() {
        let a = shape(0), b = shape(1), c = shape(2)
        let result = ShapeZOrder.apply(.bringForward, to: a.id, in: [a, b, c])
        XCTAssertEqual(result.map(\.id), [b.id, a.id, c.id])
        XCTAssertEqual(result.map(\.zIndex), [0, 1, 2])
    }

    func testSendBackwardMovesOneStepDown() {
        let a = shape(0), b = shape(1), c = shape(2)
        let result = ShapeZOrder.apply(.sendBackward, to: c.id, in: [a, b, c])
        XCTAssertEqual(result.map(\.id), [a.id, c.id, b.id])
    }

    func testToFrontMovesToTheEnd() {
        let a = shape(0), b = shape(1), c = shape(2)
        let result = ShapeZOrder.apply(.toFront, to: a.id, in: [a, b, c])
        XCTAssertEqual(result.map(\.id), [b.id, c.id, a.id])
    }

    func testToBackMovesToTheStart() {
        let a = shape(0), b = shape(1), c = shape(2)
        let result = ShapeZOrder.apply(.toBack, to: c.id, in: [a, b, c])
        XCTAssertEqual(result.map(\.id), [c.id, a.id, b.id])
    }

    func testBringForwardOnTheTopmostShapeIsClampedNotWrapped() {
        let a = shape(0), b = shape(1)
        let result = ShapeZOrder.apply(.bringForward, to: b.id, in: [a, b])
        XCTAssertEqual(result.map(\.id), [a.id, b.id], "already-topmost shape stays topmost, doesn't wrap to the back")
    }

    func testApplyToUnknownIDReturnsTheInputUnchanged() {
        let a = shape(0), b = shape(1)
        let input = [a, b]
        let result = ShapeZOrder.apply(.toFront, to: UUID(), in: input)
        XCTAssertEqual(result.map(\.id), input.map(\.id))
        XCTAssertEqual(result.map(\.zIndex), input.map(\.zIndex))
    }

    func testApplyEstablishesOrderFromWhateverArrayOrderItIsGivenNotRequiringPreSortedInput() {
        // shapes handed in out of zIndex order (c has zIndex 0, a has 2)
        var a = shape(0); a.zIndex = 2
        var b = shape(0); b.zIndex = 1
        var c = shape(0); c.zIndex = 0
        let result = ShapeZOrder.apply(.toFront, to: c.id, in: [a, b, c])
        // paint order established by zIndex first (c, b, a), then c moves to front.
        XCTAssertEqual(result.map(\.id), [b.id, a.id, c.id])
    }

    // MARK: Property - every call renumbers to a dense 0..<n regardless of move

    func testEveryMoveAlwaysProducesADenseZeroBasedRenumbering() {
        let shapes = (0..<5).map { shape($0 * 10) } // sparse starting indices
        for move: ShapeZOrder.Move in [.bringForward, .sendBackward, .toFront, .toBack] {
            let result = ShapeZOrder.apply(move, to: shapes[2].id, in: shapes)
            XCTAssertEqual(result.map(\.zIndex), Array(0..<result.count), "\(move) must leave zIndex densely 0..<n")
        }
    }
}
