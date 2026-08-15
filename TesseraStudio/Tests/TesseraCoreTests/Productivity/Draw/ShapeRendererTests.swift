import XCTest
import CoreGraphics
@testable import TesseraCore

/// Black-box: render into a real offscreen bitmap and read pixels back,
/// rather than trying to expose `ShapeRenderer`'s private path-building
/// internals to the test target. Two assertions are deliberately
/// robust to CGBitmapContext's flip convention (drawing-space origin
/// vs. raw-buffer row order, which this file does not pin down): a
/// square filling the WHOLE canvas samples the same at its center
/// either way, and a thin horizontal line's non-stroked area is far
/// from the stroke regardless of which direction is "up."
final class ShapeRendererTests: XCTestCase {

    private func makeContext(width: Int, height: Int) -> CGContext {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    private func pixel(_ context: CGContext, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = (y * context.bytesPerRow) + (x * 4)
        return (data[offset], data[offset + 1], data[offset + 2])
    }

    /// Whole-buffer snapshot for "these two renders are not pixel-
    /// identical" comparisons, where naming one specific differing
    /// pixel up front is more fragile than the fact of a difference.
    private func snapshot(_ context: CGContext) -> [UInt8] {
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        let count = context.bytesPerRow * context.height
        return Array(UnsafeBufferPointer(start: data, count: count))
    }

    func testRenderingDoesNotCrashForEveryCatalogKind() {
        let renderer = ShapeRenderer()
        for entry in ShapeCatalog.entries {
            let context = makeContext(width: 100, height: 100)
            let shape = ShapeCatalog.makeShape(kind: entry.kind, at: (x: 10, y: 10), zIndex: 0)
            renderer.render(shape, in: context)
        }
    }

    func testFilledRectPaintsItsInteriorColor() {
        let context = makeContext(width: 50, height: 50)
        let shape = Shape(
            kind: .rect,
            geometry: ShapeGeometry(x: 0, y: 0, width: 50, height: 50),
            fill: ShapeFill(colorHex: "#FF0000")
        )
        ShapeRenderer().render(shape, in: context)
        let p = pixel(context, x: 25, y: 25)
        XCTAssertGreaterThan(p.r, 200, "center of a full-canvas red rect should read red, got \(p)")
        XCTAssertLessThan(p.g, 50)
        XCTAssertLessThan(p.b, 50)
    }

    func testUnfilledShapeLeavesInteriorUntouched() {
        let context = makeContext(width: 50, height: 50)
        let shape = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 50, height: 50))
        ShapeRenderer().render(shape, in: context)
        let p = pixel(context, x: 25, y: 25)
        XCTAssertGreaterThan(p.r, 240, "no fill set - interior must stay the white background, got \(p)")
        XCTAssertGreaterThan(p.g, 240)
        XCTAssertGreaterThan(p.b, 240)
    }

    /// A line/arrow has no interior (`kindIsFillable` excludes them) -
    /// setting `fill` anyway must not paint one.
    func testLineIgnoresFillEvenWhenOneIsSet() {
        let context = makeContext(width: 100, height: 20)
        let shape = Shape(
            kind: .line,
            geometry: ShapeGeometry(x: 0, y: 0, width: 100, height: 20),
            fill: ShapeFill(colorHex: "#FF0000"),
            stroke: ShapeStroke(colorHex: "#000000", width: 2)
        )
        ShapeRenderer().render(shape, in: context)
        // The stroke is a thin horizontal line through the vertical
        // center of the box; sampling 8pt away from center is clear of
        // it regardless of which edge (y=0 or y=19) is "top" in the
        // raw buffer.
        let p = pixel(context, x: 50, y: 2)
        XCTAssertGreaterThan(p.r, 240, "line's bounding-box interior must not be filled, got \(p)")
    }

    /// Rotation must not throw or corrupt state for a later shape drawn
    /// in the same context - `render` saves/restores the graphics
    /// state around its rotation transform.
    func testRotatedShapeDoesNotLeakTransformState() {
        let context = makeContext(width: 60, height: 60)
        let rotated = Shape(
            kind: .rect,
            geometry: ShapeGeometry(x: 10, y: 10, width: 20, height: 20, rotation: 45),
            fill: ShapeFill(colorHex: "#00FF00")
        )
        ShapeRenderer().render(rotated, in: context)

        // A second, unrotated, unrelated shape must land at its own
        // untransformed coordinates, not wherever the first shape's
        // rotation left the CTM.
        let second = Shape(
            kind: .rect,
            geometry: ShapeGeometry(x: 0, y: 40, width: 10, height: 10),
            fill: ShapeFill(colorHex: "#0000FF")
        )
        ShapeRenderer().render(second, in: context)
        let p = pixel(context, x: 5, y: 45)
        XCTAssertGreaterThan(p.b, 200, "the second shape's own fill must land at its own coordinates, got \(p)")
    }

    // MARK: - Connector (P1 1.19)

    /// A `.connector` shape with both endpoints attached to sibling
    /// shapes must render (stroke the `ConnectorRouter`-derived path)
    /// without crashing, given the sibling list via `allShapes:`.
    func testRenderingAttachedConnectorDoesNotCrash() {
        let context = makeContext(width: 200, height: 200)
        let a = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 50, height: 50))
        let b = Shape(kind: .rect, geometry: ShapeGeometry(x: 120, y: 120, width: 50, height: 50))
        let connector = Shape(
            kind: .connector,
            geometry: ShapeGeometry(x: 0, y: 0, width: 0, height: 0),
            stroke: ShapeStroke(colorHex: "#000000", width: 2),
            connector: ConnectorInfo(
                start: .attached(shapeID: a.id, gluePointIndex: 1),
                end: .attached(shapeID: b.id, gluePointIndex: 3),
                style: .elbow
            )
        )
        ShapeRenderer().render(connector, in: context, allShapes: [a, b, connector])
    }

    /// A `.connector` shape rendered WITHOUT its sibling shapes (the
    /// default `allShapes: []`) must degrade to "nothing drawn," not
    /// crash - the same contract `ConnectorRouter.route` documents for
    /// an unresolved endpoint.
    func testRenderingConnectorWithMissingSiblingsDoesNotCrash() {
        let context = makeContext(width: 50, height: 50)
        let connector = Shape(
            kind: .connector,
            geometry: ShapeGeometry(x: 0, y: 0, width: 0, height: 0),
            stroke: ShapeStroke(colorHex: "#000000", width: 2),
            connector: ConnectorInfo(start: .attached(shapeID: UUID(), gluePointIndex: 0), end: .free(x: 10, y: 10), style: .straight)
        )
        ShapeRenderer().render(connector, in: context)
    }

    // MARK: - Shape text (P1 1.19)

    /// `shape.text` must render (via `BlockRenderer`/`CTFramesetter`)
    /// without crashing for a shape that also has a fill/stroke.
    func testRenderingShapeWithTextDoesNotCrash() {
        let context = makeContext(width: 100, height: 100)
        let shape = Shape(
            kind: .rect,
            geometry: ShapeGeometry(x: 0, y: 0, width: 100, height: 100),
            fill: ShapeFill(colorHex: "#D7E8FF"),
            text: ShapeText(runs: [InlineRun(text: "Hello shape")])
        )
        ShapeRenderer().render(shape, in: context)
    }

    // MARK: - Flip (gap-closure: ShapeGeometry.flipH/flipV)

    /// `.arrow`'s arrowhead sits at the line's right end (`x + width`)
    /// and is symmetric top-to-bottom, so it isolates `flipH`: a
    /// left-right mirror about the frame's own center moves the solid
    /// triangle from the right side to the left, without disturbing
    /// the horizontal stroke's own band at the vertical center (the
    /// sampled y stays clear of that band on both sides).
    func testFlipHMirrorsArrowheadAcrossFrameCenter() {
        func makeArrow(flipH: Bool) -> CGContext {
            let context = makeContext(width: 100, height: 20)
            let shape = Shape(
                kind: .arrow,
                geometry: ShapeGeometry(x: 0, y: 0, width: 100, height: 20, flipH: flipH),
                stroke: ShapeStroke(colorHex: "#000000", width: 2)
            )
            ShapeRenderer().render(shape, in: context)
            return context
        }

        // Arrowhead occupies roughly x in [88, 100] unflipped; mirrored
        // about the frame's center (x=50) it lands at roughly x in
        // [0, 12]. y=7 stays clear of both the triangle's slanted edge
        // (safely inside at x=89) and the line stroke's own band
        // around the vertical center (y=9...11).
        let unflipped = makeArrow(flipH: false)
        XCTAssertLessThan(pixel(unflipped, x: 89, y: 7).r, 100, "unflipped arrowhead should darken its own (right) side")
        XCTAssertGreaterThan(pixel(unflipped, x: 11, y: 7).r, 200, "unflipped arrowhead must not bleed to the mirrored (left) side")

        let flipped = makeArrow(flipH: true)
        XCTAssertGreaterThan(pixel(flipped, x: 89, y: 7).r, 200, "flipH must clear the original (right) side")
        XCTAssertLessThan(pixel(flipped, x: 11, y: 7).r, 100, "flipH must move the arrowhead to the mirrored (left) side")
    }

    /// A 5-point star with its first vertex pointing straight up is
    /// mirror-symmetric left-to-right but NOT top-to-bottom (a single
    /// top spike vs. a two-legged base with a center notch), so it
    /// isolates `flipV` the way `.arrow`'s asymmetric arrowhead
    /// isolates `flipH` above.
    func testFlipVMirrorsStarAcrossFrameCenter() {
        func makeStar(flipV: Bool) -> CGContext {
            let context = makeContext(width: 60, height: 60)
            let shape = Shape(
                kind: .star,
                geometry: ShapeGeometry(x: 0, y: 0, width: 60, height: 60, flipV: flipV),
                fill: ShapeFill(colorHex: "#000000")
            )
            ShapeRenderer().render(shape, in: context)
            return context
        }

        // regularStarPath's vertex math is expressed in CG's own
        // bottom-left-origin user space, where the star's y=0 tip (its
        // "top" spike, per the -pi/2 first-vertex comment) sits at the
        // SMALLEST user-space y. But CGBitmapContext's raw backing
        // buffer - what pixel(_:x:y:) indexes into directly via
        // y*bytesPerRow - stores row 0 as the top of the rendered
        // image, i.e. the LARGEST user-space y. So in buffer-row
        // coordinates, (30, 50) - not (30, 10) - is where the top
        // spike actually lands, and (30, 10) is the notch between the
        // two bottom legs, outside the star's fill.
        let unflipped = makeStar(flipV: false)
        XCTAssertLessThan(pixel(unflipped, x: 30, y: 50).r, 100, "unflipped star's top spike should be filled")
        XCTAssertGreaterThan(pixel(unflipped, x: 30, y: 10).r, 200, "unflipped star's bottom notch must stay unfilled")

        let flipped = makeStar(flipV: true)
        XCTAssertGreaterThan(pixel(flipped, x: 30, y: 50).r, 200, "flipV must clear the original spike position")
        XCTAssertLessThan(pixel(flipped, x: 30, y: 10).r, 100, "flipV must move the filled spike into the former notch position")
    }

    /// Rotation and flip together must not crash, and the combined
    /// render must actually reflect BOTH transforms rather than one
    /// silently overwriting the other's CTM push - the ordering itself
    /// (flip pushed before rotation, per `applyFlip`/`applyRotation`'s
    /// call order in `render`) is what this item is closing, not
    /// rotation's own math, which `testRotatedShapeDoesNotLeakTransformState`
    /// already covers.
    func testFlipAndRotationTogetherRenderWithoutCrashingAndDifferFromEitherAlone() {
        func render(rotation: Double, flipH: Bool) -> [UInt8] {
            let context = makeContext(width: 100, height: 60)
            let shape = Shape(
                kind: .arrow,
                geometry: ShapeGeometry(x: 10, y: 10, width: 60, height: 20, rotation: rotation, flipH: flipH),
                stroke: ShapeStroke(colorHex: "#000000", width: 2)
            )
            ShapeRenderer().render(shape, in: context)
            return snapshot(context)
        }

        let flipOnly = render(rotation: 0, flipH: true)
        let rotationOnly = render(rotation: 40, flipH: false)
        let both = render(rotation: 40, flipH: true)

        XCTAssertNotEqual(both, flipOnly, "flip+rotation combined must differ from flip alone")
        XCTAssertNotEqual(both, rotationOnly, "flip+rotation combined must differ from rotation alone")
    }
}
