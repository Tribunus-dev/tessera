import XCTest
@testable import TesseraCore

/// `DrawingStore` (P0 0.15). Async mutations need a live data layer
/// this test target doesn't stand up (see `SlideStoreTests`/
/// `DocStoreTests`, scoped the same way) - the mutation LOGIC itself
/// is pinned at the pure `Drawing` model level in `DrawingTests`.
final class DrawingStoreTests: XCTestCase {

    func testStoreConstruction() {
        let dataLayer = TesseraDataLayer()
        let store = DrawingStore(dataLayer: dataLayer)
        _ = store
    }

    func testJSONStringRoundTripViaDrawingHelper() throws {
        let drawing = Drawing(title: "Hello", tags: ["a"])
        let s = try drawing.jsonDataString()
        XCTAssertTrue(s.contains("Hello"))
        let parsed = try Drawing.from(jsonDataString: s)
        XCTAssertEqual(parsed.title, "Hello")
    }

    func testDrawingNotFoundEquatable() {
        let id = UUID()
        XCTAssertEqual(DrawingStoreError.drawingNotFound(id: id), DrawingStoreError.drawingNotFound(id: id))
        XCTAssertNotEqual(DrawingStoreError.drawingNotFound(id: id), DrawingStoreError.drawingNotFound(id: UUID()))
    }

    func testShapeNotFoundEquatable() {
        let id = UUID()
        XCTAssertEqual(DrawingStoreError.shapeNotFound(id: id), DrawingStoreError.shapeNotFound(id: id))
        XCTAssertNotEqual(DrawingStoreError.shapeNotFound(id: id), DrawingStoreError.shapeNotFound(id: UUID()))
    }

    func testInvalidBodyEquatable() {
        XCTAssertEqual(DrawingStoreError.invalidBody(reason: "x"), DrawingStoreError.invalidBody(reason: "x"))
        XCTAssertNotEqual(DrawingStoreError.invalidBody(reason: "x"), DrawingStoreError.invalidBody(reason: "y"))
    }

    func testListFilterApply() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let a = Drawing(id: UUID(), title: "a", isFavorite: true, createdAt: now, updatedAt: now)
        let b = Drawing(id: UUID(), title: "b", isArchived: true, createdAt: now, updatedAt: now)
        let c = Drawing(id: UUID(), title: "c", isTrashed: true, createdAt: now, updatedAt: now)
        let all = [a, b, c]
        XCTAssertEqual(DrawingListFilter.all.apply(to: all).map { $0.title }, ["a"])
        XCTAssertEqual(DrawingListFilter.favorites.apply(to: all).map { $0.title }, ["a"])
        XCTAssertEqual(DrawingListFilter.archived.apply(to: all).map { $0.title }, ["b"])
        XCTAssertEqual(DrawingListFilter.trash.apply(to: all).map { $0.title }, ["c"])
    }

    func testDrawingRowProjection() {
        let shape = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 1, height: 1))
        let drawing = Drawing(title: "T", isFavorite: true, tags: ["x"]).insertingShape(shape)
        let row = DrawingRow(drawing: drawing)
        XCTAssertEqual(row.title, "T")
        XCTAssertEqual(row.shapeCount, 1)
        XCTAssertEqual(row.tags, ["x"])
        XCTAssertTrue(row.isFavorite)
    }

    // MARK: - Layer / connector receipt types
    //
    // `DrawingStore.addLayer`/`removeLayer`/`renameLayer`/`reorderLayers`/
    // `setLayerVisibility`/`setLayerLock`/`setConnector` are thin async
    // wrappers (loadOrFail -> pure Drawing mutator -> upsert -> receipt)
    // around the pure `Drawing` mutators exercised below - this file's
    // own header note (no live data layer in this test target) applies
    // to those wrappers the same way it already applies to every other
    // async mutation here. The wrapped logic - the mutation itself and
    // the receipt vocabulary it emits - is what's pinned here; JSON
    // encode/decode (`jsonDataString`/`from(jsonDataString:)`) stands in
    // for "persist and reload" the same way it already does above.

    func testLayerReceiptTypesAreStable() {
        XCTAssertEqual(DrawingReceiptType.layerAdded.rawValue, "drawing_layer_added")
        XCTAssertEqual(DrawingReceiptType.layerRenamed.rawValue, "drawing_layer_renamed")
        XCTAssertEqual(DrawingReceiptType.layerDeleted.rawValue, "drawing_layer_deleted")
        XCTAssertEqual(DrawingReceiptType.layerReordered.rawValue, "drawing_layer_reordered")
        XCTAssertEqual(DrawingReceiptType.layerVisibilityChanged.rawValue, "drawing_layer_visibility_changed")
        XCTAssertEqual(DrawingReceiptType.layerLockChanged.rawValue, "drawing_layer_lock_changed")
        XCTAssertEqual(DrawingReceiptType.setConnector.rawValue, "drawing_shape_connector_changed")
    }

    // MARK: - Layer mutations round-trip

    func testAddingLayerRoundTrips() throws {
        let layer = DrawLayer(name: "Background")
        let drawing = Drawing.makeBlank(title: "T").addingLayer(layer)
        let reloaded = try Drawing.from(jsonDataString: drawing.jsonDataString())
        XCTAssertEqual(reloaded.layers.map(\.id), [layer.id])
        XCTAssertEqual(reloaded.layers.first?.name, "Background")
    }

    func testRenamingLayerRoundTrips() throws {
        let layer = DrawLayer(name: "Old")
        let drawing = Drawing.makeBlank(title: "T").addingLayer(layer).renamingLayer(layer.id, to: "New")
        let reloaded = try Drawing.from(jsonDataString: drawing.jsonDataString())
        XCTAssertEqual(reloaded.layers.first?.name, "New")
    }

    func testRenamingAnUnknownLayerIsANoOp() {
        let layer = DrawLayer(name: "Old")
        let drawing = Drawing.makeBlank(title: "T").addingLayer(layer)
        let unchanged = drawing.renamingLayer(UUID(), to: "New")
        XCTAssertEqual(unchanged.layers.first?.name, "Old")
    }

    func testSettingLayerVisibilityRoundTrips() throws {
        let layer = DrawLayer(name: "L")
        let drawing = Drawing.makeBlank(title: "T").addingLayer(layer).settingLayerVisibility(layer.id, isVisible: false)
        let reloaded = try Drawing.from(jsonDataString: drawing.jsonDataString())
        XCTAssertEqual(reloaded.layers.first?.isVisible, false)
    }

    func testSettingLayerLockRoundTrips() throws {
        let layer = DrawLayer(name: "L")
        let drawing = Drawing.makeBlank(title: "T").addingLayer(layer).settingLayerLock(layer.id, isLocked: true)
        let reloaded = try Drawing.from(jsonDataString: drawing.jsonDataString())
        XCTAssertEqual(reloaded.layers.first?.isLocked, true)
    }

    func testReorderingLayersRoundTrips() throws {
        let a = DrawLayer(name: "A")
        let b = DrawLayer(name: "B")
        let drawing = Drawing.makeBlank(title: "T").addingLayer(a).addingLayer(b).reorderingLayers([b.id, a.id])
        let reloaded = try Drawing.from(jsonDataString: drawing.jsonDataString())
        XCTAssertEqual(reloaded.layers.map(\.id), [b.id, a.id])
    }

    func testReorderingLayersWithMismatchedSetIsANoOp() {
        let a = DrawLayer(name: "A")
        let b = DrawLayer(name: "B")
        let drawing = Drawing.makeBlank(title: "T").addingLayer(a).addingLayer(b)
        // Missing `b.id`, has a stray unknown id instead - must not drop `b`.
        let unchanged = drawing.reorderingLayers([a.id, UUID()])
        XCTAssertEqual(unchanged.layers.map(\.id), [a.id, b.id])
    }

    func testRemovingLayerRoundTripsAndClearsShapeLayerID() throws {
        let layer = DrawLayer(name: "L")
        var shape = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 10, height: 10))
        shape.layerID = layer.id
        let drawing = Drawing.makeBlank(title: "T")
            .addingLayer(layer)
            .insertingShape(shape)
            .removingLayer(layer.id)

        XCTAssertTrue(drawing.layers.isEmpty)
        XCTAssertNil(drawing.shape(id: shape.id)?.layerID, "removing a layer must clear layerID on shapes that referenced it, not leave it dangling")

        let reloaded = try Drawing.from(jsonDataString: drawing.jsonDataString())
        XCTAssertTrue(reloaded.layers.isEmpty)
        XCTAssertNil(reloaded.shape(id: shape.id)?.layerID)
    }

    func testRemovingAnUnknownLayerIsANoOp() {
        let layer = DrawLayer(name: "L")
        let drawing = Drawing.makeBlank(title: "T").addingLayer(layer)
        let unchanged = drawing.removingLayer(UUID())
        XCTAssertEqual(unchanged.layers.map(\.id), [layer.id])
    }

    // MARK: - Connector round-trip

    func testConnectorInfoRoundTripsOnShape() throws {
        var shape = Shape(kind: .connector, geometry: ShapeGeometry(x: 0, y: 0, width: 0, height: 0))
        let info = ConnectorInfo(
            start: .attached(shapeID: UUID(), gluePointIndex: 0),
            end: .free(x: 5, y: 5),
            style: .curved
        )
        shape.connector = info
        let drawing = Drawing.makeBlank(title: "T").insertingShape(shape)
        let reloaded = try Drawing.from(jsonDataString: drawing.jsonDataString())
        XCTAssertEqual(reloaded.shape(id: shape.id)?.connector, info)
    }
}
