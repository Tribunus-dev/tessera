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

/// The P0 shape catalog plus P1's `.connector` (item 1.19). P2 adds
/// `.bezier` / CAD-style custom paths - out of scope here per the
/// architect decision (3D and morph are punted entirely, not phased).
public enum ShapeKind: String, Codable, Sendable, Hashable, CaseIterable {
    case rect
    case ellipse
    case line
    case arrow
    case polygon
    case star
    case freeform
    /// A `Shape.connector`-carrying shape - see `ConnectorInfo`. Its
    /// own `geometry` is NOT the connector's source of truth (`Shape
    /// .connector`'s doc comment): `ConnectorRouter` derives the
    /// visible path at render time from `connector`'s resolved
    /// endpoints, not from this shape's `x`/`y`/`width`/`height`.
    case connector
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
    /// Mirroring, applied in the shape's own unrotated local frame
    /// BEFORE rotation - matches OOXML `a:xfrm`'s flip-then-rotate
    /// order and ODF's equivalent, so a round-tripped file keeps the
    /// same visual result. `TransformController` sets these when a
    /// resize handle is dragged past its opposite handle, instead of
    /// ever writing a negative `width`/`height`.
    public var flipH: Bool
    public var flipV: Bool

    public init(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        rotation: Double = 0,
        anchorX: Double? = nil,
        anchorY: Double? = nil,
        flipH: Bool = false,
        flipV: Bool = false
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.rotation = rotation
        self.anchorX = anchorX
        self.anchorY = anchorY
        self.flipH = flipH
        self.flipV = flipV
    }

    // MARK: - Codable

    /// Custom, not synthesized: `flipH`/`flipV` were added after this
    /// type shipped, so decoding must tolerate their absence in JSON
    /// written before they existed - `decodeIfPresent` falls back to
    /// `false` (no mirroring), the same default the memberwise `init`
    /// above uses. Mirrors `Drawing`'s handling of its own later-added
    /// `layers` field. Every other field decodes/encodes exactly as
    /// the synthesized conformance did before this type needed a
    /// custom one.
    private enum CodingKeys: String, CodingKey {
        case x, y, width, height, rotation, anchorX, anchorY, flipH, flipV
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        width = try container.decode(Double.self, forKey: .width)
        height = try container.decode(Double.self, forKey: .height)
        rotation = try container.decode(Double.self, forKey: .rotation)
        anchorX = try container.decodeIfPresent(Double.self, forKey: .anchorX)
        anchorY = try container.decodeIfPresent(Double.self, forKey: .anchorY)
        flipH = try container.decodeIfPresent(Bool.self, forKey: .flipH) ?? false
        flipV = try container.decodeIfPresent(Bool.self, forKey: .flipV) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(rotation, forKey: .rotation)
        try container.encodeIfPresent(anchorX, forKey: .anchorX)
        try container.encodeIfPresent(anchorY, forKey: .anchorY)
        try container.encode(flipH, forKey: .flipH)
        try container.encode(flipV, forKey: .flipV)
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
    /// `.literal("#RRGGBB"/"#RRGGBBAA")` or a `.theme` slot reference
    /// (P1 1.5), matching `SlideMasterPage.backgroundColorHex`'s
    /// `ColorRef` adoption.
    public var colorHex: ColorRef
    /// 0 (fully transparent) ... 1 (opaque), independent of any alpha
    /// baked into `colorHex` - the two multiply, matching how every
    /// vector tool separates "the color" from "how see-through it is."
    public var opacity: Double

    public init(colorHex: ColorRef, opacity: Double = 1) {
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

// MARK: - ConnectorInfo

/// One endpoint of a `.connector` shape: either glued to another
/// shape's compass glue point, or a free point in the drawing's own
/// coordinate space. Plain `Double` `x`/`y` for the free case, not
/// `CGPoint` - matching `ShapeGeometry`'s persisted-model convention
/// (see that type's header comment).
public enum ConnectorEndpoint: Codable, Sendable, Hashable {
    /// `gluePointIndex` is the compass index `ConnectorRouter
    /// .gluePoints(for:)` computes (0=top, 1=right, 2=bottom, 3=left) -
    /// chosen to map 1:1 onto OOXML `stCxn`/`endCxn` `idx` and ODF
    /// glue-point ids per this item's design contract.
    case attached(shapeID: UUID, gluePointIndex: Int)
    case free(x: Double, y: Double)
}

/// How a `.connector`'s path bends between its two resolved endpoints.
/// `ConnectorRouter` derives the actual path at render time from this
/// plus the current shape list - never stored.
public enum ConnectorStyle: String, Codable, Sendable, Hashable, CaseIterable {
    case straight
    case elbow
    case curved
}

/// A connector's typed wiring - a `.connector`-only field, peer of
/// `ShapeFill`/`ShapeStroke`/`ShapeText`. Carries only WHAT is
/// connected and HOW the bend is styled, never WHERE the path actually
/// bends - `ConnectorRouter.route(_:shapes:)` derives that at render
/// time, so a connector re-routes correctly whenever either attached
/// shape moves without this value ever being touched.
public struct ConnectorInfo: Codable, Sendable, Hashable {
    public var start: ConnectorEndpoint
    public var end: ConnectorEndpoint
    public var style: ConnectorStyle

    public init(start: ConnectorEndpoint, end: ConnectorEndpoint, style: ConnectorStyle = .elbow) {
        self.start = start
        self.end = end
        self.style = style
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
    /// Non-nil only for `.connector` shapes - the typed start/end/
    /// style wiring `ConnectorRouter` resolves into a path at render
    /// time. Nothing keeps `geometry` in sync with this field's
    /// resolved endpoints (see `ShapeKind.connector`'s doc comment) -
    /// renderers read `connector`, not `geometry`, for a connector's
    /// actual path.
    public var connector: ConnectorInfo?
    /// Paint order within the drawing: higher draws on top. Not
    /// necessarily contiguous or unique - `ShapeRenderer`/callers sort
    /// by this, they don't rely on it being densely packed.
    public var zIndex: Int
    /// Non-nil when this shape is a member of a group (P1's group/
    /// ungroup). The group itself is a `Shape` too (kind determines
    /// whether a shape can host children is a P1 concern; P0 leaves
    /// every shape's `parentGroupID` nil).
    public var parentGroupID: UUID?
    /// Non-nil when this shape belongs to a named layer in the owning
    /// `Drawing.layers` (see `LayerStore`). `nil` means the shape is
    /// on the implicit default layer - every P0 shape, since layers
    /// didn't exist yet. Membership only: doesn't affect this shape's
    /// `zIndex`, which stays dense per layer, not globally.
    public var layerID: UUID?

    public init(
        id: UUID = UUID(),
        kind: ShapeKind,
        geometry: ShapeGeometry,
        fill: ShapeFill? = nil,
        stroke: ShapeStroke? = nil,
        text: ShapeText? = nil,
        connector: ConnectorInfo? = nil,
        zIndex: Int = 0,
        parentGroupID: UUID? = nil,
        layerID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.geometry = geometry
        self.fill = fill
        self.stroke = stroke
        self.text = text
        self.connector = connector
        self.zIndex = zIndex
        self.parentGroupID = parentGroupID
        self.layerID = layerID
    }
}
