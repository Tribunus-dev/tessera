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

/// The P0 shape catalog plus P1's `.connector` (item 1.19) and P2's
/// `.bezier` (item 2.3, full custom-geometry paths - the P0 `.freeform`
/// case stays as a plain rect-bounded placeholder; `.bezier` is the one
/// with a real `Shape.path`). 3D (2.17) and morph (2.18) do NOT get new
/// `ShapeKind` cases - a 3D-extruded shape is still fundamentally a 2D
/// `ShapeKind` (rect/ellipse/polygon/bezier/...) with `Shape.extrusion`
/// set, matching how OOXML/ODF themselves model extrusion as a
/// property of an existing 2D shape, not a distinct shape family.
public enum ShapeKind: String, Codable, Sendable, Hashable, CaseIterable {
    case rect
    case ellipse
    case line
    case arrow
    case polygon
    case star
    case freeform
    /// Full custom-geometry path (item 2.3) - `Shape.path` is this
    /// case's real geometry; `Shape.geometry`'s x/y/width/height still
    /// carries the path's bounding box (kept in sync by whoever mutates
    /// `path`) so every geometry-agnostic call site (z-order, layer
    /// membership, group transforms) keeps working unchanged.
    case bezier
    /// A `Shape.connector`-carrying shape - see `ConnectorInfo`. Its
    /// own `geometry` is NOT the connector's source of truth (`Shape
    /// .connector`'s doc comment): `ConnectorRouter` derives the
    /// visible path at render time from `connector`'s resolved
    /// endpoints, not from this shape's `x`/`y`/`width`/`height`.
    case connector
    /// A callout (item 2.12): a body shape (own fill/stroke/text, via
    /// the same `Shape` fields every other kind uses) that ALSO carries
    /// a leader line to `Shape.calloutAnchor` - distinct from
    /// `.connector`, which IS just a line with no body of its own. A
    /// new case (not an orthogonal field on every kind, unlike
    /// `.extrusion`/`.dimensionInfo` below) because real office formats
    /// model a callout as its own preset shape family (OOXML
    /// `wedgeRectCallout` and friends, ODF's own callout custom-shape
    /// types), not as a property layered onto an arbitrary shape - see
    /// this wave's findings file for the full reasoning and the
    /// `ODGBridgeFilter.swift`/`ShapeCatalog.swift` follow-up this
    /// choice requires (both outside this track's owned file list).
    /// `geometry` is the callout's own body rect, same convention as
    /// `.rect`.
    case callout
    /// A Draw-native table (item 2.12): `Shape.table` carries the real
    /// grid content (`DrawTable.swift`). A `ShapeKind` case (not a
    /// separate top-level `Drawing` entity) so a table gets z-order,
    /// layer membership, group, snap, and transform for free through
    /// the exact same `Shape`-based machinery every other kind already
    /// has - see this wave's findings file for the full reasoning.
    /// `geometry`'s width/height is the table's own outer bounding box
    /// (sum of `DrawTable.columnWidths`/`rowHeights`), kept in sync by
    /// whoever mutates the table, matching `.bezier`'s own documented
    /// bbox-sync convention above.
    case table
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
    /// Non-nil and non-empty puts this text in BULLETED-LIST mode
    /// (item 2.12): `ShapeRenderer` draws `listItems` instead of
    /// `runs` when present, matching how `Block`'s own `.list`/
    /// `.listItem` container walks its children instead of a leaf's
    /// `content`. `nil` (the default) is the ORIGINAL plain-paragraph
    /// shape (every shape before this field existed) - purely additive,
    /// both new fields decode/encode via Swift's synthesized
    /// `Codable` `Optional` handling (`decodeIfPresent`/absent-on-nil),
    /// so no custom `Codable` conformance was needed to add these,
    /// unlike `ShapeGeometry`'s `flipH`/`flipV`. `runs` is left
    /// untouched when `listItems` is set (not required to be empty) -
    /// it simply isn't the field the renderer reads while list mode is
    /// active.
    public var listItems: [ShapeTextListItem]?
    /// The bullet/number/checkbox convention every item in `listItems`
    /// renders with (item 2.12) - one style per shape, matching
    /// `Block`'s own `.list` container's single `attributes["style"]`
    /// (a list does not mix bullet conventions mid-list). `nil` when
    /// `listItems` is `nil`; defaults to `.unordered` when `listItems`
    /// is set but this is left `nil` (mirrors `BlockRenderer
    /// .renderListContainer`'s own `?? "unordered"` fallback).
    public var listStyle: ShapeTextListStyle?

    public init(runs: [InlineRun] = [], listItems: [ShapeTextListItem]? = nil, listStyle: ShapeTextListStyle? = nil) {
        self.runs = runs
        self.listItems = listItems
        self.listStyle = listStyle
    }

    /// `listItems`' own text, one item per line, when list mode is
    /// active; else `runs`' plain text - derived, matching every other
    /// "plain text view" in this codebase (never a second stored copy).
    public var plainText: String {
        if let listItems, !listItems.isEmpty {
            return listItems.map { $0.runs.map(\.text).joined() }.joined(separator: "\n")
        }
        return runs.map(\.text).joined()
    }
}

// MARK: - ShapeTextListItem / ShapeTextListStyle

/// One bulleted-list line inside a shape's text (item 2.12). Peer of
/// `Block`'s own `.listItem` case, flattened to a plain array (no
/// nested block-id indirection) since shape text has no need for
/// `Block`'s general container machinery - a shape's list is always a
/// single flat run of items, indent level and all.
public struct ShapeTextListItem: Codable, Sendable, Hashable {
    public var runs: [InlineRun]
    /// 0-based indent depth. Clamped to `>= 0` in `init` - matching
    /// every other "no negative magnitude" field in this codebase
    /// (`ShapeStroke.width`, `ShapeExtrusion.depth`).
    public var level: Int

    public init(runs: [InlineRun] = [], level: Int = 0) {
        self.runs = runs
        self.level = max(0, level)
    }
}

/// The bullet/number/checkbox convention a `ShapeText`'s `listItems`
/// render with - same three-way vocabulary as `BlockType.list`'s own
/// `attributes["style"]` string (`"unordered" | "ordered" | "task"`),
/// typed here instead of a raw string since `ShapeText` is not
/// attribute-bag-shaped the way `Block` is.
public enum ShapeTextListStyle: String, Codable, Sendable, Hashable, CaseIterable {
    case unordered
    case ordered
    case task
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

// MARK: - ShapeDimensionInfo

/// A measure/dimension-line's own annotation (item 2.12) - reuses
/// `ShapeKind.line` (a dimension line IS a line, geometrically: two
/// endpoints, `ShapeRenderer.linePath`'s existing horizontal-midline
/// construction is already exactly right) rather than a new
/// `ShapeKind` case, matching `ShapeExtrusion`'s own "orthogonal
/// property of an existing 2D shape" precedent (`ShapeKind`'s own doc
/// comment) - a dimension line has no body/fill concept a callout
/// needs, so there is no real-format precedent pulling it toward a
/// distinct shape family the way `.callout` has.
public struct ShapeDimensionInfo: Codable, Sendable, Hashable {
    public var units: DimensionUnit
    /// Decimal places shown in the auto-computed label. Clamped to
    /// `>= 0` in `init`, matching this file's other "no negative
    /// magnitude" fields.
    public var precision: Int
    /// A non-nil, non-empty value overrides the auto-computed label
    /// text outright - the same "manual override always wins" contract
    /// `FieldSpec`'s dirty-cache convention already establishes
    /// elsewhere in this codebase, not a second parallel mechanism.
    public var manualOverrideText: String?

    public init(units: DimensionUnit = .point, precision: Int = 1, manualOverrideText: String? = nil) {
        self.units = units
        self.precision = max(0, precision)
        self.manualOverrideText = manualOverrideText
    }

    /// The measured distance in `units`, auto-computed from `geometry`.
    /// A `.line` shape's own two endpoints are `(x, y + height/2)` and
    /// `(x + width, y + height/2)` (`ShapeRenderer.linePath`'s existing
    /// construction) - a horizontal segment of length `width` in the
    /// shape's own local space, which rotation/flip do not change the
    /// LENGTH of (only its on-canvas orientation) - so `abs(width)` IS
    /// the segment length, no trigonometry needed.
    public func measuredLength(for geometry: ShapeGeometry) -> Double {
        abs(geometry.width) / units.pointsPerUnit
    }

    /// The text `ShapeRenderer` draws at the dimension line's midpoint:
    /// `manualOverrideText` verbatim when set, else the auto-computed
    /// `measuredLength(for:)` formatted to `precision` decimal places
    /// plus `units`' own display suffix.
    public func displayText(for geometry: ShapeGeometry) -> String {
        if let manualOverrideText, !manualOverrideText.isEmpty { return manualOverrideText }
        return String(format: "%.\(precision)f", measuredLength(for: geometry)) + units.suffix
    }
}

/// The unit vocabulary `ShapeDimensionInfo.units` measures in. Every
/// case's `pointsPerUnit` conversion factor is exact (points are this
/// codebase's own persisted-model unit, `ShapeGeometry`'s header
/// comment - the same convention `DocumentPageLayout` uses elsewhere).
public enum DimensionUnit: String, Codable, Sendable, Hashable, CaseIterable {
    case point
    case millimeter
    case centimeter
    case inch

    /// Points per one unit of `self` (1 pt = 1/72 in, the standard
    /// desktop-publishing/PDF/CoreGraphics point).
    public var pointsPerUnit: Double {
        switch self {
        case .point: return 1
        case .inch: return 72
        case .millimeter: return 72 / 25.4
        case .centimeter: return 72 / 2.54
        }
    }

    public var suffix: String {
        switch self {
        case .point: return "pt"
        case .millimeter: return "mm"
        case .centimeter: return "cm"
        case .inch: return "in"
        }
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
    /// Non-nil only for `.bezier` shapes (item 2.3) - the actual custom
    /// geometry. See `ShapePath.swift`.
    public var path: ShapePath?
    /// Non-nil when this shape is extruded into 3D (item 2.17,
    /// extrude-only minimal design). Orthogonal to `kind`/`path` - any
    /// 2D shape can carry an extrusion. See `ShapeExtrusion.swift`.
    public var extrusion: ShapeExtrusion?
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
    /// Non-nil only for `.callout` shapes (item 2.12) - the leader
    /// line's target: either glued to another shape's compass glue
    /// point, or a free canvas point. Reuses `ConnectorEndpoint`
    /// verbatim rather than a second attachment type (this file's own
    /// "one identity/attachment model" convention) - `ShapeRenderer`
    /// resolves it the same way `ConnectorRouter` resolves a
    /// connector's own endpoints. UNLIKE `.connector`, a callout DOES
    /// use `geometry` as its body's source of truth - only the leader
    /// line's far end comes from this field.
    public var calloutAnchor: ConnectorEndpoint?
    /// Non-nil only for `.line` shapes (item 2.12) that are dimension/
    /// measure lines rather than plain lines - see
    /// `ShapeDimensionInfo`. Orthogonal to `kind`, matching
    /// `extrusion`'s own "any 2D shape can carry X" convention above.
    public var dimensionInfo: ShapeDimensionInfo?
    /// Non-nil only for `.table` shapes (item 2.12) - the real grid
    /// content. See `DrawTable.swift`.
    public var table: DrawTable?

    public init(
        id: UUID = UUID(),
        kind: ShapeKind,
        geometry: ShapeGeometry,
        fill: ShapeFill? = nil,
        stroke: ShapeStroke? = nil,
        text: ShapeText? = nil,
        connector: ConnectorInfo? = nil,
        path: ShapePath? = nil,
        extrusion: ShapeExtrusion? = nil,
        zIndex: Int = 0,
        parentGroupID: UUID? = nil,
        layerID: UUID? = nil,
        calloutAnchor: ConnectorEndpoint? = nil,
        dimensionInfo: ShapeDimensionInfo? = nil,
        table: DrawTable? = nil
    ) {
        self.id = id
        self.kind = kind
        self.geometry = geometry
        self.fill = fill
        self.stroke = stroke
        self.text = text
        self.connector = connector
        self.path = path
        self.extrusion = extrusion
        self.zIndex = zIndex
        self.parentGroupID = parentGroupID
        self.layerID = layerID
        self.calloutAnchor = calloutAnchor
        self.dimensionInfo = dimensionInfo
        self.table = table
    }
}
