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
//
//  2.17 IMPLEMENTATION NOTE (ratification pending, see this wave's
//  findings file): grew the placeholder with `metalness`/`roughness`,
//  the two `SCNMaterial` PBR parameters `ShapeExtrusionRenderer` needs
//  to light the extruded solid - every other extrusion parameter
//  (extrusionDepth, chamferRadius) was already covered by depth/
//  bevelDepth. Deliberately did NOT add a separate "lighting" field:
//  lighting is a property of the SCENE (the light rig the preview view
//  sets up once), not of one shape's extrusion, so it has no home on
//  this per-shape value type. Deliberately did NOT add a distinct
//  extrusion color: the extruded solid's material color reuses
//  `Shape.fill`'s existing `ColorRef` (resolved the same way
//  `ShapeRenderer` resolves it for the flat 2D fill) rather than storing
//  a second, potentially-divergent color on this type - one fill, one
//  source of truth, same "3-foot rule" reasoning AGENTS.md applies
//  elsewhere in this expansion.
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
    /// `SCNMaterial.metalness` (physically-based rendering), 0
    /// (dielectric - plastic/cardboard) ... 1 (metal). Defaults to 0:
    /// the common case for a Draw shape pushed into 3D is a plain
    /// solid, not chrome.
    public var metalness: Double
    /// `SCNMaterial.roughness` (physically-based rendering), 0
    /// (mirror-smooth) ... 1 (fully matte). Defaults to 0.5, a neutral
    /// satin finish.
    public var roughness: Double

    public init(depth: Double, bevelDepth: Double = 0, metalness: Double = 0, roughness: Double = 0.5) {
        self.depth = max(0, depth)
        self.bevelDepth = max(0, bevelDepth)
        self.metalness = min(max(metalness, 0), 1)
        self.roughness = min(max(roughness, 0), 1)
    }

    // MARK: - Codable
    //
    // Custom, not synthesized: `metalness`/`roughness` were added after
    // this type first shipped (P2-B wave opener landed depth/bevelDepth
    // only) - decoding must tolerate their absence in already-written
    // JSON, falling back to the same defaults the memberwise `init`
    // above uses. Mirrors `ShapeGeometry`'s identical handling of its
    // own later-added `flipH`/`flipV` fields (see that type's doc
    // comment).
    private enum CodingKeys: String, CodingKey {
        case depth, bevelDepth, metalness, roughness
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        depth = try container.decode(Double.self, forKey: .depth)
        bevelDepth = try container.decode(Double.self, forKey: .bevelDepth)
        metalness = try container.decodeIfPresent(Double.self, forKey: .metalness) ?? 0
        roughness = try container.decodeIfPresent(Double.self, forKey: .roughness) ?? 0.5
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(depth, forKey: .depth)
        try container.encode(bevelDepth, forKey: .bevelDepth)
        try container.encode(metalness, forKey: .metalness)
        try container.encode(roughness, forKey: .roughness)
    }
}
