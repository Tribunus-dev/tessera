import XCTest
@testable import TesseraCore

/// `LayerStore` (P1 1.15): `DrawLayer` plus the pure paint-order/
/// render-list logic layered on top of `Shape.layerID`.
final class LayerStoreTests: XCTestCase {

    private func makeShape(zIndex: Int, layerID: UUID? = nil) -> Shape {
        Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 10, height: 10), zIndex: zIndex, layerID: layerID)
    }

    // MARK: - DrawLayer

    func testDrawLayerDefaults() {
        let layer = DrawLayer(name: "Background")
        XCTAssertEqual(layer.name, "Background")
        XCTAssertTrue(layer.isVisible)
        XCTAssertFalse(layer.isLocked)
        XCTAssertTrue(layer.isPrintable)
    }

    // MARK: - paintOrder: no layers (implicit single layer)

    /// `layers == []` is every P0 drawing's state - paint order must
    /// stay exactly `zIndex` order, unchanged from before this type
    /// existed.
    func testPaintOrderWithNoLayersIsPlainZIndexOrder() {
        let a = makeShape(zIndex: 2)
        let b = makeShape(zIndex: 0)
        let c = makeShape(zIndex: 1)
        let result = LayerStore.paintOrder(shapes: [a, b, c], layers: [])
        XCTAssertEqual(result.map(\.id), [b.id, c.id, a.id])
    }

    // MARK: - paintOrder: band beats zIndex

    /// Band (layer array position) is the primary sort key - a shape
    /// on an earlier layer paints first no matter how its `zIndex`
    /// compares to a shape on a later layer.
    func testPaintOrderOrdersByLayerBandBeforeZIndex() {
        let background = DrawLayer(name: "Background")
        let foreground = DrawLayer(name: "Foreground")
        let layers = [background, foreground]

        let backShape = makeShape(zIndex: 10, layerID: background.id)
        let frontShape = makeShape(zIndex: 0, layerID: foreground.id)

        let result = LayerStore.paintOrder(shapes: [frontShape, backShape], layers: layers)
        XCTAssertEqual(result.map(\.id), [backShape.id, frontShape.id])
    }

    /// Within one band, `zIndex` still orders shapes - and stays dense
    /// PER LAYER: two layers each numbering their own shapes 0, 1, ...
    /// independently is not a collision.
    func testPaintOrderSortsByZIndexWithinABand() {
        let background = DrawLayer(name: "Background")
        let foreground = DrawLayer(name: "Foreground")
        let layers = [background, foreground]

        let back0 = makeShape(zIndex: 0, layerID: background.id)
        let back1 = makeShape(zIndex: 1, layerID: background.id)
        let front0 = makeShape(zIndex: 0, layerID: foreground.id)
        let front1 = makeShape(zIndex: 1, layerID: foreground.id)

        let result = LayerStore.paintOrder(shapes: [front1, back1, front0, back0], layers: layers)
        XCTAssertEqual(result.map(\.id), [back0.id, back1.id, front0.id, front1.id])
    }

    /// A shape with no layer, or one naming a layer no longer in
    /// `layers`, bands with the implicit base layer - underneath every
    /// named layer, regardless of `zIndex`.
    func testUnassignedAndUnknownLayerShapesPaintBeneathNamedLayers() {
        let named = DrawLayer(name: "Named")
        let layers = [named]

        let unassigned = makeShape(zIndex: 99, layerID: nil)
        let unknownLayer = makeShape(zIndex: 50, layerID: UUID())
        let namedShape = makeShape(zIndex: 0, layerID: named.id)

        let result = LayerStore.paintOrder(shapes: [namedShape, unknownLayer, unassigned], layers: layers)
        XCTAssertEqual(Set(result.prefix(2).map(\.id)), Set([unassigned.id, unknownLayer.id]))
        XCTAssertEqual(result.last?.id, namedShape.id)
    }

    /// Ties on both band and `zIndex` keep the input array's own
    /// relative order - `paintOrder` is a STABLE sort.
    func testPaintOrderIsStableOnTies() {
        let a = makeShape(zIndex: 0)
        let b = makeShape(zIndex: 0)
        let c = makeShape(zIndex: 0)
        let result = LayerStore.paintOrder(shapes: [a, b, c], layers: [])
        XCTAssertEqual(result.map(\.id), [a.id, b.id, c.id])
    }

    // MARK: - renderList: hiding a layer filters without mutating zIndex

    /// The test contract: hiding a layer removes its shapes from the
    /// render list without mutating any zIndex. Two layers, shapes with
    /// known zIndex values in each; hide one layer; assert its shapes
    /// are gone from the render list AND every remaining shape's
    /// zIndex is byte-identical to what it was before hiding.
    func testHidingALayerRemovesItsShapesWithoutMutatingZIndex() {
        var background = DrawLayer(name: "Background")
        let foreground = DrawLayer(name: "Foreground")

        let bg0 = makeShape(zIndex: 0, layerID: background.id)
        let bg1 = makeShape(zIndex: 1, layerID: background.id)
        let fg0 = makeShape(zIndex: 0, layerID: foreground.id)
        let fg1 = makeShape(zIndex: 1, layerID: foreground.id)
        let allShapes = [bg0, bg1, fg0, fg1]
        let originalZIndexByID = Dictionary(uniqueKeysWithValues: allShapes.map { ($0.id, $0.zIndex) })

        background.isVisible = false
        let layers = [background, foreground]

        let rendered = LayerStore.renderList(shapes: allShapes, layers: layers)

        // The hidden layer's shapes are gone from the render list.
        XCTAssertEqual(Set(rendered.map(\.id)), Set([fg0.id, fg1.id]))

        // Every shape - visible or hidden - still has the zIndex it
        // started with. Hiding is a read-path filter, never a write.
        for shape in allShapes {
            XCTAssertEqual(shape.zIndex, originalZIndexByID[shape.id])
        }
        for shape in rendered {
            XCTAssertEqual(shape.zIndex, originalZIndexByID[shape.id])
        }
    }

    /// Shapes on the implicit base layer (no `layerID`) are never
    /// members of any named layer, so hiding named layers - even all
    /// of them - never removes them.
    func testUnassignedShapesSurviveEveryLayerBeingHidden() {
        var onlyLayer = DrawLayer(name: "Only")
        onlyLayer.isVisible = false
        let unassigned = makeShape(zIndex: 0, layerID: nil)
        let onLayer = makeShape(zIndex: 1, layerID: onlyLayer.id)

        let rendered = LayerStore.renderList(shapes: [unassigned, onLayer], layers: [onlyLayer])
        XCTAssertEqual(rendered.map(\.id), [unassigned.id])
    }

    /// With no hidden layers, `renderList` matches `paintOrder` exactly.
    func testRenderListWithNoHiddenLayersMatchesPaintOrder() {
        let layer = DrawLayer(name: "A")
        let a = makeShape(zIndex: 1, layerID: layer.id)
        let b = makeShape(zIndex: 0, layerID: layer.id)
        let shapes = [a, b]
        XCTAssertEqual(
            LayerStore.renderList(shapes: shapes, layers: [layer]).map(\.id),
            LayerStore.paintOrder(shapes: shapes, layers: [layer]).map(\.id)
        )
    }

    // MARK: - Drawing.layers

    func testDrawingLayersDefaultsToEmpty() {
        XCTAssertEqual(Drawing.makeBlank().layers, [])
    }

    /// A `Drawing` written before `layers` existed must still decode -
    /// the missing key means "the implicit single layer", not a
    /// decode error.
    func testDrawingWithoutLayersKeyDecodesToEmptyLayers() throws {
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "title": "Old Drawing",
            "body": {"blocks": {}, "rootChildren": []},
            "canvasSize": {"width": 800, "height": 600},
            "gridEnabled": false,
            "isArchived": false,
            "isTrashed": false,
            "isFavorite": false,
            "tags": [],
            "linkedEntityIDs": [],
            "createdAt": "2020-01-01T00:00:00Z",
            "updatedAt": "2020-01-01T00:00:00Z"
        }
        """
        let drawing = try Drawing.from(jsonDataString: json)
        XCTAssertEqual(drawing.layers, [])
    }

    func testDrawingRoundTripsLayers() throws {
        let layer = DrawLayer(name: "Background", isVisible: false, isLocked: true, isPrintable: false)
        let drawing = Drawing(title: "Layered", layers: [layer])
        let roundTripped = try Drawing.from(jsonDataString: try drawing.jsonDataString())
        XCTAssertEqual(roundTripped.layers, [layer])
        XCTAssertEqual(roundTripped.id, drawing.id)
        XCTAssertEqual(roundTripped.title, drawing.title)
        XCTAssertEqual(roundTripped.canvasSize, drawing.canvasSize)
        // Not a full XCTAssertEqual(roundTripped, drawing): Drawing's JSON
        // round-trip goes through .iso8601 date (de)coding, which drops
        // sub-second precision, so createdAt/updatedAt legitimately differ
        // in their fractional second from the freshly-Date()-stamped
        // original - a pre-existing property of the encoding, not
        // something layers touches. The assertions above are what this
        // test's name is actually about.
    }
}
