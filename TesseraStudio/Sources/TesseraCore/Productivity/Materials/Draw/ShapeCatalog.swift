//===----------------------------------------------------------------------===//
//  ShapeCatalog.swift
//  Tessera Studio
//
//  The authoritative list of shape kinds and their default appearance -
//  what "insert a rectangle" actually inserts. Shared by Draw (the
//  canvas) and Impress (free shapes on a slide): both surfaces offer
//  the same catalog rather than each defining their own.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - ShapeCatalog

public enum ShapeCatalog {

    /// One catalog entry: what a shape of this kind looks like the
    /// moment it's inserted, before the user has touched it.
    public struct Entry: Sendable {
        public let kind: ShapeKind
        public let displayName: String
        /// SF Symbol name, matching the icon convention used elsewhere
        /// in the productivity surfaces (e.g. `SheetColumnType`'s
        /// per-case icon in the Sheets grid header).
        public let symbolName: String
        /// Width/height only - `defaultGeometry(at:)` positions it.
        public let defaultSize: (width: Double, height: Double)
        public let defaultFill: ShapeFill?
        public let defaultStroke: ShapeStroke?
    }

    /// One entry per `ShapeKind` case, in catalog display order (not
    /// necessarily `ShapeKind.allCases`' declaration order - this is
    /// the order a shape picker UI would show them in).
    public static let entries: [Entry] = [
        Entry(
            kind: .rect, displayName: "Rectangle", symbolName: "rectangle",
            defaultSize: (120, 80),
            defaultFill: ShapeFill(colorHex: "#D7E8FF"),
            defaultStroke: ShapeStroke(colorHex: "#2C6FBB", width: 1)
        ),
        Entry(
            kind: .ellipse, displayName: "Ellipse", symbolName: "oval",
            defaultSize: (120, 80),
            defaultFill: ShapeFill(colorHex: "#D8F3DC"),
            defaultStroke: ShapeStroke(colorHex: "#2D8A4E", width: 1)
        ),
        Entry(
            kind: .line, displayName: "Line", symbolName: "line.diagonal",
            defaultSize: (120, 0),
            defaultFill: nil,
            defaultStroke: ShapeStroke(colorHex: "#333333", width: 2)
        ),
        Entry(
            kind: .arrow, displayName: "Arrow", symbolName: "arrow.right",
            defaultSize: (120, 0),
            defaultFill: nil,
            defaultStroke: ShapeStroke(colorHex: "#333333", width: 2)
        ),
        Entry(
            kind: .polygon, displayName: "Polygon", symbolName: "pentagon",
            defaultSize: (100, 100),
            defaultFill: ShapeFill(colorHex: "#FFF3C4"),
            defaultStroke: ShapeStroke(colorHex: "#B8952E", width: 1)
        ),
        Entry(
            kind: .star, displayName: "Star", symbolName: "star",
            defaultSize: (100, 100),
            defaultFill: ShapeFill(colorHex: "#FFD9D9"),
            defaultStroke: ShapeStroke(colorHex: "#B84A4A", width: 1)
        ),
        Entry(
            kind: .freeform, displayName: "Freeform", symbolName: "scribble",
            defaultSize: (100, 100),
            defaultFill: nil,
            defaultStroke: ShapeStroke(colorHex: "#333333", width: 2)
        ),
    ]

    private static let byKind: [ShapeKind: Entry] = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.kind, $0) }
    )

    /// The catalog entry for a kind. Every `ShapeKind` case has exactly
    /// one entry - `entries` is exhaustive over `ShapeKind.allCases`,
    /// enforced by `ShapeCatalogTests`, not by the compiler (a
    /// `[ShapeKind: Entry]` literal has no exhaustiveness check the way
    /// a `switch` does) - so this is force-unwrapped rather than
    /// returning an `Entry?` that every caller would have to
    /// needlessly guard against.
    public static func entry(for kind: ShapeKind) -> Entry {
        byKind[kind]!
    }

    /// A freshly-inserted shape of `kind`, positioned at `origin` with
    /// the catalog's default size/fill/stroke. `zIndex` is the
    /// caller's responsibility (it depends on how many shapes already
    /// exist on the canvas, which this catalog does not know about).
    public static func makeShape(kind: ShapeKind, at origin: (x: Double, y: Double), zIndex: Int) -> Shape {
        let e = entry(for: kind)
        return Shape(
            kind: kind,
            geometry: ShapeGeometry(x: origin.x, y: origin.y, width: e.defaultSize.width, height: e.defaultSize.height),
            fill: e.defaultFill,
            stroke: e.defaultStroke,
            zIndex: zIndex
        )
    }
}
