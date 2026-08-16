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
import CoreGraphics

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

// MARK: - Bounding box (item 2.3: BezierPathController/ShapeRenderer helper)
//
// Additive per this file's own wave-brief instructions ("evolve the
// ShapePath/ShapeSubpath/ShapePathSegment types additively if your
// controller needs more"). `Shape.geometry`'s width/height is documented
// as "the path's bounding box (kept in sync by whoever mutates path)" -
// this is that sync operation's source of truth.

extension ShapeSubpath {
    /// The axis-aligned box spanning every point THIS subpath carries,
    /// INCLUDING control points - a loose bound, not a curve's true
    /// tight extrema-solved bbox (which needs the curve's derivative,
    /// nothing else in this codebase requires that precision yet). Good
    /// enough for keeping `Shape.geometry` roughly in sync as a path is
    /// edited. `.zero` for an empty subpath.
    public var boundingBox: CGRect {
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        var sawAny = false
        func consider(_ p: ShapePathPoint) {
            sawAny = true
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        for segment in segments {
            switch segment {
            case .move(let p), .line(let p):
                consider(p)
            case .quad(let control, let end):
                consider(control); consider(end)
            case .cubic(let control1, let control2, let end):
                consider(control1); consider(control2); consider(end)
            }
        }
        guard sawAny else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

extension ShapePath {
    /// The union of every subpath's own `boundingBox` - `.null` (CGRect's
    /// own "no area, absorbed by any union" identity value) for a path
    /// with no subpaths.
    public var boundingBox: CGRect {
        subpaths.reduce(CGRect.null) { $0.union($1.boundingBox) }
    }
}

// MARK: - SVG/ODF path-data codec (item 2.3's own named test: "ShapePath
// round-trips SVG path data losslessly")
//
// Lives here (not ODGBridgeFilter.swift) because it is a property of
// THIS type's own wire representation, not ODF-specific plumbing -
// `ODGBridgeFilter` consumes `pathData`/`parsingPathData(_:)` plus
// `rescaled(from:to:)` below the same way it consumes `Codable` for
// every other persisted type, rather than owning a second copy of the
// mapping.
//
// ENCODE writes explicit ABSOLUTE M/L/Q/C commands only (one per
// segment, "Z" when a subpath is closed) - deliberately not the terser
// relative/shorthand vocabulary a real `soffice` re-export actually
// uses (confirmed empirically against LibreOffice 26.2.5.2, probed
// 2026-08-15 - see ODGBezierPathWireFormatProbeTests.swift): a
// hand-authored absolute `svg:d` parses correctly through soffice's own
// importer (that probe's own fixtures are hand-authored exactly this
// way), so this encoder only has to be unambiguous, not byte-identical
// to soffice's own style.
//
// DECODE (`parsingPathData(_:)`) understands the FULLER vocabulary a
// real round trip actually round-trips through: absolute AND relative
// M/L/H/V/C/Q/Z, implicit command repetition (extra coordinate groups
// after one command letter repeat that same command, standard SVG path
// grammar - e.g. "L10 10 20 20" is two linetos), and numbers packed
// without a separator before a sign or decimal point (e.g. "h-4001",
// observed verbatim in `draw:connector`'s own `svg:d` per
// `ODGBridgeFilter.connectorAttributes`'s doc comment, and in this
// item's own probe for `draw:path`). Malformed/truncated input degrades
// to whatever subpaths parsed successfully before the problem, matching
// this codebase's "malformed data degrades" convention (see
// `ODGBridgeFilter`'s own import parsing) rather than throwing.
extension ShapePath {

    /// Encodes this path as ODF/SVG-style path-data (an `svg:d` value).
    /// Numbers use Swift's own `Double` description, which is the
    /// shortest decimal string that reads back to the exact same
    /// `Double` - the property `parsingPathData(_:)` relies on for a
    /// LOSSLESS round trip of this encoder's own output (a real
    /// external `soffice` round trip is separately lossy for other
    /// reasons - see the probe file - but the PURE encode/decode pair
    /// here is not).
    public var pathData: String {
        subpaths.map(Self.encode).joined(separator: " ")
    }

    private static func encode(_ subpath: ShapeSubpath) -> String {
        var parts: [String] = []
        parts.reserveCapacity(subpath.segments.count + 1)
        for segment in subpath.segments {
            switch segment {
            case .move(let p):
                parts.append("M \(fmt(p.x)) \(fmt(p.y))")
            case .line(let p):
                parts.append("L \(fmt(p.x)) \(fmt(p.y))")
            case .quad(let control, let end):
                parts.append("Q \(fmt(control.x)) \(fmt(control.y)) \(fmt(end.x)) \(fmt(end.y))")
            case .cubic(let control1, let control2, let end):
                parts.append(
                    "C \(fmt(control1.x)) \(fmt(control1.y)) \(fmt(control2.x)) \(fmt(control2.y)) \(fmt(end.x)) \(fmt(end.y))"
                )
            }
        }
        if subpath.closed { parts.append("Z") }
        return parts.joined(separator: " ")
    }

    private static func fmt(_ value: Double) -> String {
        String(value)
    }

    /// Parses ODF/SVG-style path-data (an `svg:d` value) into a
    /// `ShapePath`, in WHATEVER coordinate space the numbers in `d` are
    /// already expressed in (a real `draw:path`'s own `svg:viewBox`
    /// space, not necessarily this shape's local 0...width/0...height
    /// space - see `rescaled(from:to:)` below for mapping between the
    /// two).
    public static func parsingPathData(_ d: String) -> ShapePath {
        var subpaths: [ShapeSubpath] = []
        var currentSegments: [ShapePathSegment] = []
        var current = ShapePathPoint(x: 0, y: 0)
        var subpathStart = ShapePathPoint(x: 0, y: 0)

        func flushOpenSubpath() {
            guard !currentSegments.isEmpty else { return }
            subpaths.append(ShapeSubpath(segments: currentSegments, closed: false))
            currentSegments = []
        }

        func point(_ group: [Double], relativeToCurrent: Bool) -> ShapePathPoint {
            relativeToCurrent
                ? ShapePathPoint(x: current.x + group[0], y: current.y + group[1])
                : ShapePathPoint(x: group[0], y: group[1])
        }

        let commandLetters = Set<Character>("MmLlHhVvCcQqZz")
        let chars = Array(d)
        var i = 0
        while i < chars.count {
            while i < chars.count, !commandLetters.contains(chars[i]) { i += 1 }
            guard i < chars.count else { break }
            let letter = chars[i]
            i += 1
            let numbersStart = i
            while i < chars.count, !commandLetters.contains(chars[i]) { i += 1 }
            let numbers = scanNumbers(chars[numbersStart..<i])
            let isRelative = letter.isLowercase

            if letter == "Z" || letter == "z" {
                // Closes the CURRENT subpath and resets the pen to its
                // own start point, matching SVG's post-Z pen-position
                // rule - a later command in the same `d` string
                // continues from the closed shape's own start, not
                // wherever Z's own (nonexistent) endpoint would be.
                guard !currentSegments.isEmpty else { continue }
                subpaths.append(ShapeSubpath(segments: currentSegments, closed: true))
                currentSegments = []
                current = subpathStart
                continue
            }

            let arity: Int
            switch letter {
            case "M", "m", "L", "l": arity = 2
            case "H", "h", "V", "v": arity = 1
            case "Q", "q": arity = 4
            case "C", "c": arity = 6
            default: arity = 0
            }
            guard arity > 0 else { continue }

            var idx = 0
            var isFirstGroup = true
            while idx + arity <= numbers.count {
                let group = Array(numbers[idx..<(idx + arity)])
                idx += arity
                let isMoveGroup = (letter == "M" || letter == "m") && isFirstGroup
                isFirstGroup = false

                if isMoveGroup {
                    flushOpenSubpath()
                    let p = point(group, relativeToCurrent: isRelative)
                    current = p
                    subpathStart = p
                    currentSegments = [.move(p)]
                    continue
                }

                switch letter.lowercased().first {
                case "m", "l":
                    // A repeated coordinate group after M (or any group
                    // after L) is an implicit lineto, per SVG grammar.
                    let p = point(group, relativeToCurrent: isRelative)
                    currentSegments.append(.line(p))
                    current = p
                case "h":
                    let p = ShapePathPoint(x: isRelative ? current.x + group[0] : group[0], y: current.y)
                    currentSegments.append(.line(p))
                    current = p
                case "v":
                    let p = ShapePathPoint(x: current.x, y: isRelative ? current.y + group[0] : group[0])
                    currentSegments.append(.line(p))
                    current = p
                case "q":
                    let c = point(Array(group[0...1]), relativeToCurrent: isRelative)
                    let e = point(Array(group[2...3]), relativeToCurrent: isRelative)
                    currentSegments.append(.quad(control: c, end: e))
                    current = e
                case "c":
                    let c1 = point(Array(group[0...1]), relativeToCurrent: isRelative)
                    let c2 = point(Array(group[2...3]), relativeToCurrent: isRelative)
                    let e = point(Array(group[4...5]), relativeToCurrent: isRelative)
                    currentSegments.append(.cubic(control1: c1, control2: c2, end: e))
                    current = e
                default:
                    break
                }
            }
        }
        flushOpenSubpath()
        return ShapePath(subpaths: subpaths)
    }

    /// Scans a run of characters (everything between one command letter
    /// and the next) into the numbers it encodes - handling numbers
    /// packed without a separator before a sign or decimal point (e.g.
    /// "h-4001", "1.5.5" is NOT specially split, matching what this
    /// item's own probed real-world inputs actually contain; plain
    /// whitespace/comma-separated and sign-adjacent runs are the only
    /// cases this codebase's own emitters or a real soffice re-export
    /// produce).
    private static func scanNumbers(_ chars: ArraySlice<Character>) -> [Double] {
        let arr = Array(chars)
        var result: [Double] = []
        var i = 0
        while i < arr.count {
            while i < arr.count, arr[i] == " " || arr[i] == "," || arr[i] == "\t" || arr[i] == "\n" || arr[i] == "\r" {
                i += 1
            }
            guard i < arr.count else { break }
            var j = i
            if arr[j] == "+" || arr[j] == "-" { j += 1 }
            var sawDigit = false
            while j < arr.count, arr[j].isNumber { j += 1; sawDigit = true }
            if j < arr.count, arr[j] == "." {
                j += 1
                while j < arr.count, arr[j].isNumber { j += 1; sawDigit = true }
            }
            if sawDigit, j < arr.count, arr[j] == "e" || arr[j] == "E" {
                var k = j + 1
                if k < arr.count, arr[k] == "+" || arr[k] == "-" { k += 1 }
                var sawExponentDigit = false
                while k < arr.count, arr[k].isNumber { k += 1; sawExponentDigit = true }
                if sawExponentDigit { j = k }
            }
            guard sawDigit, let value = Double(String(arr[i..<j])) else {
                // A stray, non-numeric character (or a bare sign/dot
                // with no digits) - skip it and keep scanning, rather
                // than aborting the whole path on one bad token.
                i += 1
                continue
            }
            result.append(value)
            i = j
        }
        return result
    }

    /// Maps every point in this path from `sourceBox`'s coordinate
    /// space into `targetBox`'s. This is the fix-up `ODGBridgeFilter`
    /// needs on import: a real `draw:path`'s `svg:viewBox` is NOT
    /// guaranteed to match this shape's own local point-space 1:1 -
    /// soffice rewrites `svg:viewBox` to its own internal unit on a
    /// real round trip (confirmed empirically - see the probe file), so
    /// `svg:d`'s raw numbers must be rescaled from THAT viewBox into
    /// `Shape.geometry`'s local 0...width/0...height space before they
    /// mean what `ShapePath`'s own doc comment says they mean. A
    /// degenerate `sourceBox` (zero width or height - a malformed or
    /// absent viewBox) is treated as already matching `targetBox`:
    /// identity, not a divide-by-zero crash.
    public func rescaled(from sourceBox: CGRect, to targetBox: CGRect) -> ShapePath {
        guard sourceBox.width > 0, sourceBox.height > 0, sourceBox != targetBox else { return self }
        func mappedPoint(_ p: ShapePathPoint) -> ShapePathPoint {
            ShapePathPoint(
                x: targetBox.minX + (p.x - sourceBox.minX) / sourceBox.width * targetBox.width,
                y: targetBox.minY + (p.y - sourceBox.minY) / sourceBox.height * targetBox.height
            )
        }
        func mappedSegment(_ segment: ShapePathSegment) -> ShapePathSegment {
            switch segment {
            case .move(let p): return .move(mappedPoint(p))
            case .line(let p): return .line(mappedPoint(p))
            case .quad(let control, let end): return .quad(control: mappedPoint(control), end: mappedPoint(end))
            case .cubic(let control1, let control2, let end):
                return .cubic(control1: mappedPoint(control1), control2: mappedPoint(control2), end: mappedPoint(end))
            }
        }
        return ShapePath(subpaths: subpaths.map { subpath in
            ShapeSubpath(segments: subpath.segments.map(mappedSegment), closed: subpath.closed)
        })
    }
}
