import XCTest
import Foundation
@testable import TesseraCore

// MARK: - DrawingTests
//
// Contract sources: Sources/TesseraCore/Productivity/Materials/Draw/Drawing.swift
// (doc comments cite studio-expansion-plan.md row 50 and the P1 design
// refinement's Draw cluster directly - the "no-op if unknown id" and
// "orphan clears layerID" contracts are stated in the pure mutators'
// own doc comments). Doctrine rule 2 (round-trip identity), rule 3
// (n/a - nothing here is derived-never-stored), rule 6 (one behavior
// per test).

final class DrawingTests: DoctrineTestCase {

    // MARK: - Round-trip identity (rule 2)

    func testDrawingEncodeDecodeIsIdentity() throws {
        var drawing = Drawing(
            title: "Org Chart", canvasSize: CanvasSize(width: 1024, height: 768),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        drawing = drawing.insertingShape(
            Shape(kind: .rect, geometry: ShapeGeometry(x: 10, y: 20, width: 100, height: 50))
        )
        drawing = drawing.addingLayer(DrawLayer(name: "Background"))

        let data = try drawing.jsonData()
        let decoded = try Drawing.from(jsonData: data)

        XCTAssertEqual(decoded, drawing)
    }

    func testDrawingJSONDataStringRoundTripIsIdentity() throws {
        let drawing = Drawing(
            title: "Blank",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ).insertingShape(
            Shape(kind: .ellipse, geometry: ShapeGeometry(x: 0, y: 0, width: 10, height: 10))
        )
        let string = try drawing.jsonDataString()
        let decoded = try Drawing.from(jsonDataString: string)
        XCTAssertEqual(decoded, drawing)
    }

    func testDrawingDecodesLegacyJSONMissingLayersFieldAsEmptyLayers() throws {
        // Pins Drawing's own documented back-compat contract ("layers was
        // added after this type shipped... decodeIfPresent falls back to
        // [], the same implicit-single-layer default the memberwise init
        // above uses" - Drawing.swift's Codable doc comment).
        let id = UUID()
        let now = "2026-01-01T00:00:00Z"
        let legacyJSON = """
        {
            "id": "\(id.uuidString)",
            "title": "Pre-layers drawing",
            "body": {"blocks": {}, "rootChildren": []},
            "canvasSize": {"width": 800, "height": 600},
            "gridEnabled": false,
            "isArchived": false,
            "isTrashed": false,
            "isFavorite": false,
            "tags": [],
            "linkedEntityIDs": [],
            "createdAt": "\(now)",
            "updatedAt": "\(now)"
        }
        """.data(using: .utf8)!

        let decoded = try Drawing.from(jsonData: legacyJSON)
        XCTAssertEqual(decoded.layers, [])
        XCTAssertEqual(decoded.title, "Pre-layers drawing")
    }

    func testCanvasSizeEncodeDecodeIsIdentity() throws {
        let size = CanvasSize(width: 1920, height: 1080)
        let data = try JSONEncoder().encode(size)
        let decoded = try JSONDecoder().decode(CanvasSize.self, from: data)
        XCTAssertEqual(decoded, size)
    }

    func testDrawLayerEncodeDecodeIsIdentity() throws {
        let layer = DrawLayer(name: "Annotations", isVisible: false, isLocked: true, isPrintable: false)
        let data = try JSONEncoder().encode(layer)
        let decoded = try JSONDecoder().decode(DrawLayer.self, from: data)
        XCTAssertEqual(decoded, layer)
    }

    // MARK: - Shape mutations (pure) - insert/delete/update no-op contracts

    func testInsertingShapeAppendsToShapesAndBody() {
        let drawing = Drawing.makeBlank()
        let shape = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 10, height: 10))
        let updated = drawing.insertingShape(shape)

        XCTAssertEqual(updated.shapes.map(\.id), [shape.id])
        XCTAssertEqual(updated.shapeCount, 1)
    }

    func testDeletingShapeOfUnknownIDIsANoOp() {
        let drawing = Drawing.makeBlank().insertingShape(
            Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 10, height: 10))
        )
        let unrelated = drawing.deletingShape(UUID())
        XCTAssertEqual(unrelated, drawing)
    }

    func testDeletingShapeOfKnownIDRemovesItFromShapesAndBody() {
        let shape = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 10, height: 10))
        let drawing = Drawing.makeBlank().insertingShape(shape)
        let updated = drawing.deletingShape(shape.id)
        XCTAssertTrue(updated.shapes.isEmpty)
        XCTAssertNil(updated.body.blocks[shape.id])
    }

    func testUpdatingShapeOfUnknownIDIsANoOp() {
        let drawing = Drawing.makeBlank()
        let phantom = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 10, height: 10))
        let updated = drawing.updatingShape(phantom)
        XCTAssertEqual(updated, drawing)
    }

    func testUpdatingShapeOfKnownIDReplacesItInPlace() {
        let shape = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 10, height: 10))
        let drawing = Drawing.makeBlank().insertingShape(shape)
        var moved = shape
        moved.geometry.x = 999
        let updated = drawing.updatingShape(moved)
        XCTAssertEqual(updated.shape(id: shape.id)?.geometry.x, 999)
    }

    // MARK: - Layer mutations (pure) - the no-op contracts DrawingStore's
    // wrapper methods are supposed to respect (see DrawingStoreTests.swift
    // for the store-level receipts-law test of the same contract, and the
    // findings file for the confirmed store-level bug).

    func testAddingLayerAlwaysAppendsANewLayer() {
        let drawing = Drawing.makeBlank()
        let layer = DrawLayer(name: "Foreground")
        let updated = drawing.addingLayer(layer)
        XCTAssertEqual(updated.layers, [layer])
    }

    func testRemovingLayerOfUnknownIDIsANoOp() {
        let drawing = Drawing.makeBlank().addingLayer(DrawLayer(name: "Only"))
        let updated = drawing.removingLayer(UUID())
        XCTAssertEqual(updated, drawing)
    }

    func testRemovingLayerOfKnownIDClearsLayerIDOnOrphanedShapes() {
        let layer = DrawLayer(name: "Doomed")
        var shape = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 10, height: 10))
        shape.layerID = layer.id
        let drawing = Drawing.makeBlank()
            .addingLayer(layer)
            .insertingShape(shape)

        let updated = drawing.removingLayer(layer.id)

        XCTAssertTrue(updated.layers.isEmpty)
        XCTAssertNil(updated.shape(id: shape.id)?.layerID, "orphaned shape must fall back to the implicit base layer, never a dangling reference")
    }

    func testRenamingLayerOfUnknownIDIsANoOp() {
        let drawing = Drawing.makeBlank().addingLayer(DrawLayer(name: "Base"))
        let updated = drawing.renamingLayer(UUID(), to: "New Name")
        XCTAssertEqual(updated, drawing)
    }

    func testRenamingLayerOfKnownIDChangesOnlyItsName() {
        let layer = DrawLayer(name: "Old")
        let drawing = Drawing.makeBlank().addingLayer(layer)
        let updated = drawing.renamingLayer(layer.id, to: "New")
        XCTAssertEqual(updated.layers.first?.name, "New")
        XCTAssertEqual(updated.layers.first?.id, layer.id)
    }

    func testReorderingLayersWithMismatchedSetIsANoOp() {
        let a = DrawLayer(name: "A")
        let b = DrawLayer(name: "B")
        let drawing = Drawing.makeBlank().addingLayer(a).addingLayer(b)

        // Missing `b`, and names an id not present at all - not the same set.
        let updated = drawing.reorderingLayers([a.id, UUID()])
        XCTAssertEqual(updated, drawing)
    }

    func testReorderingLayersWithSameSetInNewOrderSucceeds() {
        let a = DrawLayer(name: "A")
        let b = DrawLayer(name: "B")
        let drawing = Drawing.makeBlank().addingLayer(a).addingLayer(b)

        let updated = drawing.reorderingLayers([b.id, a.id])
        XCTAssertEqual(updated.layers.map(\.id), [b.id, a.id])
    }

    func testSettingLayerVisibilityOfUnknownIDIsANoOp() {
        let drawing = Drawing.makeBlank().addingLayer(DrawLayer(name: "Base"))
        let updated = drawing.settingLayerVisibility(UUID(), isVisible: false)
        XCTAssertEqual(updated, drawing)
    }

    func testSettingLayerVisibilityOfKnownIDTogglesOnlyThatLayer() {
        let layer = DrawLayer(name: "Base", isVisible: true)
        let drawing = Drawing.makeBlank().addingLayer(layer)
        let updated = drawing.settingLayerVisibility(layer.id, isVisible: false)
        XCTAssertEqual(updated.layers.first?.isVisible, false)
    }

    func testSettingLayerLockOfUnknownIDIsANoOp() {
        let drawing = Drawing.makeBlank().addingLayer(DrawLayer(name: "Base"))
        let updated = drawing.settingLayerLock(UUID(), isLocked: true)
        XCTAssertEqual(updated, drawing)
    }

    func testSettingLayerLockOfKnownIDTogglesOnlyThatLayer() {
        let layer = DrawLayer(name: "Base", isLocked: false)
        let drawing = Drawing.makeBlank().addingLayer(layer)
        let updated = drawing.settingLayerLock(layer.id, isLocked: true)
        XCTAssertEqual(updated.layers.first?.isLocked, true)
    }

    // MARK: - z-order composition

    func testApplyingZOrderKeepsBodyRootChildrenInSyncWithResultOrder() {
        let s1 = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 1, height: 1), zIndex: 0)
        let s2 = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 1, height: 1), zIndex: 1)
        let drawing = Drawing.makeBlank().insertingShape(s1).insertingShape(s2)

        let updated = drawing.applyingZOrder(.toBack, toShape: s2.id)

        XCTAssertEqual(updated.body.rootChildren, updated.shapes.map(\.id))
        XCTAssertEqual(updated.shape(id: s2.id)?.zIndex, 0)
        XCTAssertEqual(updated.shape(id: s1.id)?.zIndex, 1)
    }

    // MARK: - displayTitle

    func testDisplayTitleFallsBackToUntitledWhenTitleIsBlank() {
        let drawing = Drawing(title: "   ")
        XCTAssertEqual(drawing.displayTitle, "Untitled")
    }

    func testDisplayTitleUsesTrimmedTitleWhenPresent() {
        let drawing = Drawing(title: "  Floor Plan  ")
        XCTAssertEqual(drawing.displayTitle, "Floor Plan")
    }
}
