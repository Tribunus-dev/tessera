//===----------------------------------------------------------------------===//
//  ShapeExtrusion.swift
//  Tessera Studio
//
//  Item 2.17 (Draw 3D, re-opened 2026-08-14 as a design-gated P2 item -
//  AGENTS.md's "Tessera Studio product-surface expansion" section):
//  minimal viable design is EXTRUDE-ONLY via SceneKit (lathe/sphere/
//  cube from LO's `fucon3d.cxx` are explicitly NOT in this slice - a
//  flat 2D shape pushed into a solid along its own normal is the whole
//  P2 scope). Orthogonal to `ShapeKind`/`ShapePath`: any 2D shape
//  (`.rect`/`.ellipse`/`.polygon`/`.bezier`/...) can carry an extrusion:
//  `Shape.extrusion` is the switch, this type is its payload.
//
//  This is a scope-minimal placeholder shape, not an exhaustive spec -
//  no design doc enumerates every field a real extrusion needs
//  (bevel/material/lighting parameters in particular). Whoever
//  implements item 2.17 should grow this type additively as needed and
//  record the final field list in that wave's findings file for
//  architect ratification, per this codebase's doctrine on
//  contracts-not-located items.
//===----------------------------------------------------------------------===//

import Foundation

/// Extrudes a 2D shape into a solid along its own normal (perpendicular
/// to the drawing canvas), rendered via SceneKit. `depth` is in the
/// same point units as `ShapeGeometry`.
public struct ShapeExtrusion: Codable, Sendable, Hashable {
    public var depth: Double
    /// Rounds the extruded solid's edges; 0 = sharp edge (SceneKit's
    /// own `SCNShape.chamferRadius`, same unit as `depth`).
    public var bevelDepth: Double

    public init(depth: Double, bevelDepth: Double = 0) {
        self.depth = max(0, depth)
        self.bevelDepth = max(0, bevelDepth)
    }
}
