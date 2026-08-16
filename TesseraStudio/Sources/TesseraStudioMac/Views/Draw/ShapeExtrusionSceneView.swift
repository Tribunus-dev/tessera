//===----------------------------------------------------------------------===//
//  ShapeExtrusionSceneView.swift
//  Tessera Studio
//
//  Item 2.17 (Draw 3D, extrude-only-via-SceneKit minimal design). The
//  thin SwiftUI/SceneKit presentation layer over
//  `ShapeExtrusionRenderer` (`TesseraCore/Views/Renderers/Draw/
//  ShapeExtrusionRenderer.swift` - the actual geometry construction,
//  pure and tested, lives there). This view previews ONE shape's
//  extruded solid in isolation (a "3D preview" panel, e.g. an
//  inspector), not the whole Draw canvas - no `Drawing`/`DrawingStore`
//  dependency, presentation-layer only per the wave brief ("no new
//  Block/BlockType, no new material").
//===----------------------------------------------------------------------===//

import SwiftUI
import SceneKit
import TesseraCore

// MARK: - ShapeExtrusionSceneView

public struct ShapeExtrusionSceneView: View {
    // TesseraCore.Shape, qualified: SwiftUI's own `Shape` protocol is
    // also in scope in this file and a bare `Shape` is ambiguous
    // between the two.
    private let shape: TesseraCore.Shape
    private let allShapes: [TesseraCore.Shape]
    private let renderer = ShapeExtrusionRenderer()

    public init(shape: TesseraCore.Shape, allShapes: [TesseraCore.Shape] = []) {
        self.shape = shape
        self.allShapes = allShapes
    }

    public var body: some View {
        if let geometry = renderer.makeGeometry(for: shape, allShapes: allShapes) {
            SceneView(
                scene: Self.makeScene(geometry: geometry),
                pointOfView: Self.makeCamera(for: geometry),
                options: [.allowsCameraControl, .autoenablesDefaultLighting]
            )
        } else {
            VStack(spacing: 8) {
                Image(systemName: "cube")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("This shape has no extrusion.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func makeScene(geometry: SCNGeometry) -> SCNScene {
        let scene = SCNScene()
        let node = SCNNode(geometry: geometry)
        // Re-centers the extruded solid at the node's own local origin
        // (the geometry itself is built in the shape's absolute canvas
        // coordinates - `ShapeGeometry.x`/`.y`, arbitrary and often far
        // from 0,0 - since `ShapeExtrusionRenderer` reuses `ShapeRenderer
        // .path(for:)` unchanged). `pivot` is applied BEFORE the node's
        // own position/rotation/scale, so translating it by the
        // bounding box's NEGATIVE center cancels the shape's canvas
        // offset without touching the geometry data itself.
        let bounds = geometry.boundingBox
        node.pivot = SCNMatrix4MakeTranslation(
            -(bounds.min.x + bounds.max.x) / 2,
            -(bounds.min.y + bounds.max.y) / 2,
            -(bounds.min.z + bounds.max.z) / 2
        )
        scene.rootNode.addChildNode(node)
        return scene
    }

    private static func makeCamera(for geometry: SCNGeometry) -> SCNNode {
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        let bounds = geometry.boundingBox
        let span = max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y, 1)
        // Stays in `SCNFloat` throughout (CGFloat on macOS, Float on
        // iOS) rather than forcing a `Float(...)` conversion that would
        // only be correct on one of the two platforms.
        cameraNode.position = SCNVector3(x: 0, y: 0, z: span * 2.2)
        return cameraNode
    }
}
