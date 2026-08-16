//===----------------------------------------------------------------------===//
//  ShapePath.swift
//  Tessera Studio
//
//  Item 2.3 (BezierPathController, P2 design-locked): the classic
//  subpath model - move/line/quad/cubic segments per subpath, each
//  subpath independently open or closed. Deliberately NOT a Figma-style
//  vector network (lossy against the ODF/OOXML/SVG path formats this
//  type is a binding round-trip target for); the bend tool is the one
//  network-era UX concept this design adopts. Peer of `ShapeGeometry` -
//  same "plain value types, no CoreGraphics in the persisted model"
//  convention (`Shape.swift`'s header comment).
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - ShapePathPoint

/// A point in the shape's own local coordinate space (same space as
/// `ShapeGeometry`'s unrotated 0...width/0...height) - plain `Double`
/// fields, not `CGPoint`, matching `ShapeGeometry`'s own persisted-model
/// convention.
public struct ShapePathPoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

// MARK: - ShapePathSegment

/// One drawing instruction. `.move` may only legally appear as a
/// subpath's first segment (an interior `.move` is a second subpath in
/// disguise and should be split by whoever constructs a `ShapeSubpath` -
/// this type itself doesn't enforce that, callers do).
public enum ShapePathSegment: Codable, Sendable, Hashable {
    case move(ShapePathPoint)
    case line(ShapePathPoint)
    case quad(control: ShapePathPoint, end: ShapePathPoint)
    case cubic(control1: ShapePathPoint, control2: ShapePathPoint, end: ShapePathPoint)

    /// The segment's own terminal point (where the pen ends up after
    /// drawing it) - every case has exactly one.
    public var endPoint: ShapePathPoint {
        switch self {
        case .move(let p), .line(let p): return p
        case .quad(_, let end): return end
        case .cubic(_, _, let end): return end
        }
    }
}

// MARK: - ShapeSubpath

/// One contiguous run of segments. `closed` draws an implicit final
/// line back to the subpath's own first point (its `.move`'s point) -
/// matching SVG `Z`/ODF `svg:path` `z` semantics, not a duplicated
/// closing segment.
public struct ShapeSubpath: Codable, Sendable, Hashable {
    public var segments: [ShapePathSegment]
    public var closed: Bool

    public init(segments: [ShapePathSegment], closed: Bool = false) {
        self.segments = segments
        self.closed = closed
    }
}

// MARK: - ShapePath

/// A `.bezier` shape's actual geometry (`Shape.path`). One or more
/// independent subpaths, matching how a single SVG `<path>`/ODF
/// `draw:path` element can carry multiple `M...Z M...Z` runs (e.g. a
/// letter "O" is two subpaths: an outer ring and an inner hole).
public struct ShapePath: Codable, Sendable, Hashable {
    public var subpaths: [ShapeSubpath]

    public init(subpaths: [ShapeSubpath] = []) {
        self.subpaths = subpaths
    }
}
