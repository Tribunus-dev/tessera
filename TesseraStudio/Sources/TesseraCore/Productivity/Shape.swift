//===----------------------------------------------------------------------===//
//  Shape.swift
//  Tessera Studio
//
//  The 2D vector primitive - peer of Block.swift, the way Block is the
//  text/table primitive. A Drawing's body is a flat, z-ordered list of
//  these; Impress reuses the same type for free shapes on a slide (per
//  the architect decision: Draw and Impress share the shape data model,
//  not just the rendering code).
//===----------------------------------------------------------------------===//

import Foundation
import CoreGraphics

// MARK: - ShapeKind

/// The P0 shape catalog. P1 adds `.connector`; P2 adds `.bezier` /
/// CAD-style custom paths - both explicitly out of scope here per the
/// architect decision (3D and morph are punted entirely, not phased).
public enum ShapeKind: String, Codable, Sendable, Hashable, CaseIterable {
    case rect
    case ellipse
    case line
    case arrow
    case polygon
    case star
    case freeform
}

// MARK: - ShapeGeometry

/// Position, size, and rotation, all in the drawing's own coordinate
/// space (points, origin top-left - matching `DocumentPageLayout`'s
/// convention elsewhere in this file's sibling types).
///
/// Plain `Double` fields throughout, not `CGPoint`/`CGRect` - this is
/// the persisted document model, decoupled from the rendering layer's
/// types the way `DocumentPageLayout` already is. `frame`/`anchorPoint`
/// below hand `ShapeRenderer` the `CGRect`/`CGPoint` it actually wants
/// without making the STORED shape depend on CoreGraphics conforming
/// its own types to `Codable`.
public struct ShapeGeometry: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Degrees, clockwise, about the anchor.
    public var rotation: Double
    /// Rotation pivot, in the shape's own UNROTATED local coordinates
    /// (0...width, 0...height) - not canvas coordinates. nil (the
    /// default) means the shape's own center, matching every
    /// mainstream drawing tool's default pivot; resolved lazily via
    /// `anchorPoint` rather than baked into `init` so resizing a shape
    /// with an unset anchor keeps re-centering instead of freezing at
    /// the pivot the shape happened to have at creation time.
    public var anchorX: Double?
    public var anchorY: Double?

    public init(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        rotation: Double = 0,
        anchorX: Double? = nil,
        anchorY: Double? = nil
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.rotation = rotation
        self.anchorX = anchorX
        self.anchorY = anchorY
    }

    public var frame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// The resolved pivot in local (unrotated, 0...width/0...height)
    /// coordinates.
    public var anchorPoint: CGPoint {
        CGPoint(x: anchorX ?? width / 2, y: anchorY ?? height / 2)
    }
}

// MARK: - ShapeFill / ShapeStroke

/// Solid fill only at P0 - matching `SheetCellFormat.fillHex`'s
/// hex-string convention rather than introducing a second color
/// representation. Gradient/image/pattern fills are P2+ (not in the
/// architect's punted list, but not part of the P0 2D capability set
/// either - they're absent from studio-expansion-plan.md's P0 field
/// list for this type).
public struct ShapeFill: Codable, Sendable, Hashable {
    /// `#RRGGBB` or `#RRGGBBAA`.
    public var colorHex: String
    /// 0 (fully transparent) ... 1 (opaque), independent of any alpha
    /// baked into `colorHex` - the two multiply, matching how every
    /// vector tool separates "the color" from "how see-through it is."
    public var opacity: Double

    public init(colorHex: String, opacity: Double = 1) {
        self.colorHex = colorHex
        self.opacity = max(0, min(opacity, 1))
    }
}

public struct ShapeStroke: Codable, Sendable, Hashable {
    public var colorHex: String
    public var width: Double
    /// Alternating on/off segment lengths, in points. Empty = solid.
    public var dashPattern: [Double]

    public init(colorHex: String, width: Double = 1, dashPattern: [Double] = []) {
        self.colorHex = colorHex
        self.width = max(0, width)
        self.dashPattern = dashPattern
    }
}

// MARK: - ShapeText

/// Text-on-shape. Reuses `InlineRun` (the same inline model `Block`
/// content uses) rather than a shape-specific text type, so bold /
/// italic / links etc. work identically wherever text appears in the
/// document model.
public struct ShapeText: Codable, Sendable, Hashable {
    public var runs: [InlineRun]

    public init(runs: [InlineRun] = []) {
        self.runs = runs
    }

    public var plainText: String {
        runs.map(\.text).joined()
    }
}

// MARK: - Shape

/// One vector shape on a `Drawing`'s canvas (or, when Impress reuses
/// this type, a free shape on a slide).
public struct Shape: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var kind: ShapeKind
    public var geometry: ShapeGeometry
    public var fill: ShapeFill?
    public var stroke: ShapeStroke?
    public var text: ShapeText?
    /// Paint order within the drawing: higher draws on top. Not
    /// necessarily contiguous or unique - `ShapeRenderer`/callers sort
    /// by this, they don't rely on it being densely packed.
    public var zIndex: Int
    /// Non-nil when this shape is a member of a group (P1's group/
    /// ungroup). The group itself is a `Shape` too (kind determines
    /// whether a shape can host children is a P1 concern; P0 leaves
    /// every shape's `parentGroupID` nil).
    public var parentGroupID: UUID?

    public init(
        id: UUID = UUID(),
        kind: ShapeKind,
        geometry: ShapeGeometry,
        fill: ShapeFill? = nil,
        stroke: ShapeStroke? = nil,
        text: ShapeText? = nil,
        zIndex: Int = 0,
        parentGroupID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.geometry = geometry
        self.fill = fill
        self.stroke = stroke
        self.text = text
        self.zIndex = zIndex
        self.parentGroupID = parentGroupID
    }
}
