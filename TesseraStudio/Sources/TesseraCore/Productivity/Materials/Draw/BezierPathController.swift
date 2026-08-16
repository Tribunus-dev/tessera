//===----------------------------------------------------------------------===//
//  BezierPathController.swift
//  Tessera Studio
//
//  Item 2.3 (P2, design locked - studio-expansion-design-refinement-
//  2026-08-14.md, "2.3 BezierPathController"): the classic subpath model
//  edit state machine. "The bend tool is the one network-era UX
//  adopted" - converting a straight `.line` segment into a smooth curve
//  by dragging is the one Figma-vector-network-era interaction this
//  design keeps; everything else here is plain path-authoring (place a
//  point, drag an existing point or control handle, close/finish a
//  subpath), matching ODF/OOXML/SVG's own subpath model directly rather
//  than a lossy network intermediate.
//
//  PURE, like `TransformController`/`SnapEngine` in this same
//  directory: takes the current `ShapePath` plus one edit `Command`,
//  returns the updated `ShapePath` plus the state machine's next
//  `EditState` - never touches `DrawingStore` itself. A future
//  gesture-layer caller (mirroring `DrawCanvasView`'s own use of
//  `TransformController`: zero store writes during a drag, one commit
//  at gesture end) holds one `EditState` value starting at `.idle`,
//  threads it through repeated `apply(_:to:state:)` calls as gestures
//  land, and commits to `DrawingStore.setPath` (see this wave's
//  findings/wiringNotes for that method's exact contract) exactly once
//  per non-nil `Result.completedOperation` - never per intermediate
//  drag frame. See this file's own findings-file entry for the public
//  surface this was designed against.
//
//  Coordinate space: every `ShapePathPoint` this type reads or writes is
//  in the edited shape's own LOCAL space (0...`geometry.width`,
//  0...`geometry.height`, matching `ShapeGeometry.anchorPoint`'s "not
//  canvas coordinates" convention - see `ShapeRenderer.swift`'s
//  `.bezier` case and this wave's findings file for the reasoning). A
//  caller translating a canvas-space gesture into a `Command` subtracts
//  the shape's current `geometry.x`/`geometry.y` first, exactly the way
//  `TransformController.resize`'s caller already works in world/canvas
//  space while `ShapeGeometry.anchorPoint` itself stays local.
//===----------------------------------------------------------------------===//

import Foundation
import CoreGraphics

// MARK: - BezierPathController

public enum BezierPathController {

    // MARK: - SegmentPointSlot

    /// Which point WITHIN a segment a drag or set-operation targets.
    /// `.endpoint` exists on every segment case; `.quadControl` only on
    /// `.quad`; `.cubicControl1`/`.cubicControl2` only on `.cubic`. A
    /// slot that does not match the segment's own case is a no-op
    /// everywhere this type consumes one (`settingPoint(of:slot:to:)`
    /// below) - "dragging a control handle" (the design contract's own
    /// state-list phrase) IS a drag with `slot != .endpoint`, so this
    /// single family covers both "move a placed vertex" and "reshape an
    /// existing curve's handle" without two parallel drag states.
    public enum SegmentPointSlot: Equatable, Sendable {
        case endpoint
        case quadControl
        case cubicControl1
        case cubicControl2
    }

    // MARK: - EditState

    /// The state machine's own state. A future gesture-layer caller
    /// holds exactly one of these (starting at `.idle`) and threads it
    /// through `apply(_:to:state:)`.
    public enum EditState: Equatable, Sendable {
        /// Not currently editing a path.
        case idle
        /// Actively placing points for the subpath at `subpathIndex`
        /// (a brand-new subpath from `.beginSubpath`, or an existing
        /// open one resumed via `.resumeSubpath`) - each
        /// `.placeLinePoint`/`.placeCubicPoint` command appends a
        /// segment; `.finishSubpath`/`.closeSubpath` ends it.
        case placingSubpath(subpathIndex: Int)
        /// Dragging `slot` of the segment at `(subpathIndex,
        /// segmentIndex)`. `originalSegment` is the PRE-drag segment
        /// value, restored verbatim by `.cancelDragPoint`.
        case draggingPoint(subpathIndex: Int, segmentIndex: Int, slot: SegmentPointSlot, originalSegment: ShapePathSegment)
        /// The bend tool: dragging is turning the `.line` segment at
        /// `(subpathIndex, segmentIndex)` into a curve.
        /// `originalSegment` is always that starting `.line`, restored
        /// verbatim by `.cancelBend`.
        case bending(subpathIndex: Int, segmentIndex: Int, originalSegment: ShapePathSegment)
    }

    // MARK: - Command

    /// One edit gesture/command. A caller drives the state machine by
    /// feeding these in sequence via `apply(_:to:state:)`.
    public enum Command: Equatable, Sendable {
        // Placing a new (or resumed) subpath.
        case beginSubpath(at: ShapePathPoint)
        case resumeSubpath(subpathIndex: Int)
        case placeLinePoint(ShapePathPoint)
        case placeCubicPoint(control1: ShapePathPoint, control2: ShapePathPoint, end: ShapePathPoint)
        case finishSubpath
        case closeSubpath

        // Dragging an existing vertex OR control handle (SegmentPointSlot
        // distinguishes the two - see that type's own doc comment).
        case beginDragPoint(subpathIndex: Int, segmentIndex: Int, slot: SegmentPointSlot)
        case dragPoint(to: ShapePathPoint)
        case endDragPoint
        case cancelDragPoint

        // The bend tool: turning a straight `.line` segment into a
        // curve by dragging. `offset` in `.bend` is the drag distance
        // from the segment's own straight-line path (canvas/world
        // units, same space `TransformController.resize`'s
        // `worldDelta` uses) - see `bentSegment(from:to:offset:)`'s doc
        // comment for the exact solve.
        case beginBend(subpathIndex: Int, segmentIndex: Int)
        case bend(offset: CGVector)
        case endBend
        case cancelBend

        // Deletion - single atomic actions, not multi-frame gestures,
        // so they act directly from `.idle` rather than needing their
        // own state.
        case deleteSegment(subpathIndex: Int, segmentIndex: Int)
        case deleteSubpath(subpathIndex: Int)
    }

    // MARK: - CompletedOperation

    /// Non-nil exactly when a `Command` completed one logical editing
    /// operation - "one receipt per completed operation" (this item's
    /// own design contract). A caller commits to `DrawingStore.setPath`
    /// exactly once per non-nil value here, never per intermediate
    /// `.dragPoint`/`.bend` frame. Whether that commit actually produces
    /// a receipt is `DrawingStore.setPath`'s own no-op-guard's job (see
    /// this wave's findings file) - this type reports "an operation
    /// finished," not "the path actually changed," the same way
    /// `TransformController`'s pure functions don't decide receipts
    /// either.
    public enum CompletedOperation: Equatable, Sendable {
        case subpathFinished(subpathIndex: Int, closed: Bool)
        case pointMoved(subpathIndex: Int, segmentIndex: Int, slot: SegmentPointSlot)
        case segmentBent(subpathIndex: Int, segmentIndex: Int)
        case segmentDeleted(subpathIndex: Int, segmentIndex: Int)
        case subpathDeleted(subpathIndex: Int)
    }

    // MARK: - Result

    public struct Result: Equatable, Sendable {
        public let path: ShapePath
        public let state: EditState
        public let completedOperation: CompletedOperation?

        public init(path: ShapePath, state: EditState, completedOperation: CompletedOperation?) {
            self.path = path
            self.state = state
            self.completedOperation = completedOperation
        }

        /// `path` and `state` unchanged, no operation completed - the
        /// shared "this command does not apply to the current state"
        /// no-op result. Pure functions degrade rather than trap: an
        /// out-of-sequence gesture (a stale callback racing a cancelled
        /// drag, a command sent while `.idle` that only makes sense
        /// mid-edit) leaves both untouched instead of crashing.
        fileprivate static func unchanged(path: ShapePath, state: EditState) -> Result {
            Result(path: path, state: state, completedOperation: nil)
        }
    }

    // MARK: - apply

    /// Advances the state machine by one `Command`. See this type's own
    /// header comment for the full threading contract.
    public static func apply(_ command: Command, to path: ShapePath, state: EditState) -> Result {
        switch (state, command) {

        // MARK: Placing

        case (.idle, .beginSubpath(let point)):
            var newPath = path
            newPath.subpaths.append(ShapeSubpath(segments: [.move(point)], closed: false))
            return Result.unchanged(path: newPath, state: .placingSubpath(subpathIndex: newPath.subpaths.count - 1))

        case (.idle, .resumeSubpath(let subpathIndex)):
            guard let subpath = path.subpaths[safe: subpathIndex], !subpath.closed, !subpath.segments.isEmpty else {
                return Result.unchanged(path: path, state: state)
            }
            return Result.unchanged(path: path, state: .placingSubpath(subpathIndex: subpathIndex))

        case (.placingSubpath(let subpathIndex), .placeLinePoint(let point)):
            guard path.subpaths[safe: subpathIndex] != nil else { return Result.unchanged(path: path, state: .idle) }
            var newPath = path
            newPath.subpaths[subpathIndex].segments.append(.line(point))
            return Result.unchanged(path: newPath, state: state)

        case (.placingSubpath(let subpathIndex), .placeCubicPoint(let control1, let control2, let end)):
            guard path.subpaths[safe: subpathIndex] != nil else { return Result.unchanged(path: path, state: .idle) }
            var newPath = path
            newPath.subpaths[subpathIndex].segments.append(.cubic(control1: control1, control2: control2, end: end))
            return Result.unchanged(path: newPath, state: state)

        case (.placingSubpath(let subpathIndex), .finishSubpath):
            guard path.subpaths[safe: subpathIndex] != nil else { return Result.unchanged(path: path, state: .idle) }
            return Result(path: path, state: .idle, completedOperation: .subpathFinished(subpathIndex: subpathIndex, closed: false))

        case (.placingSubpath(let subpathIndex), .closeSubpath):
            guard path.subpaths[safe: subpathIndex] != nil else { return Result.unchanged(path: path, state: .idle) }
            var newPath = path
            newPath.subpaths[subpathIndex].closed = true
            return Result(path: newPath, state: .idle, completedOperation: .subpathFinished(subpathIndex: subpathIndex, closed: true))

        // MARK: Dragging a vertex or control handle

        case (.idle, .beginDragPoint(let subpathIndex, let segmentIndex, let slot)):
            guard let segment = path.subpaths[safe: subpathIndex]?.segments[safe: segmentIndex],
                  Self.isValid(slot: slot, for: segment)
            else {
                return Result.unchanged(path: path, state: state)
            }
            return Result.unchanged(
                path: path,
                state: .draggingPoint(subpathIndex: subpathIndex, segmentIndex: segmentIndex, slot: slot, originalSegment: segment)
            )

        case (.draggingPoint(let subpathIndex, let segmentIndex, let slot, _), .dragPoint(let point)):
            guard let segment = path.subpaths[safe: subpathIndex]?.segments[safe: segmentIndex] else {
                return Result.unchanged(path: path, state: .idle)
            }
            var newPath = path
            newPath.subpaths[subpathIndex].segments[segmentIndex] = Self.settingPoint(of: segment, slot: slot, to: point)
            return Result.unchanged(path: newPath, state: state)

        case (.draggingPoint(let subpathIndex, let segmentIndex, let slot, _), .endDragPoint):
            return Result(path: path, state: .idle, completedOperation: .pointMoved(subpathIndex: subpathIndex, segmentIndex: segmentIndex, slot: slot))

        case (.draggingPoint(let subpathIndex, let segmentIndex, _, let original), .cancelDragPoint):
            var newPath = path
            if path.subpaths[safe: subpathIndex]?.segments[safe: segmentIndex] != nil {
                newPath.subpaths[subpathIndex].segments[segmentIndex] = original
            }
            return Result.unchanged(path: newPath, state: .idle)

        // MARK: Bend tool (line -> curve)

        case (.idle, .beginBend(let subpathIndex, let segmentIndex)):
            guard segmentIndex > 0,
                  let segment = path.subpaths[safe: subpathIndex]?.segments[safe: segmentIndex],
                  case .line = segment
            else {
                // The bend tool only legally starts from a straight
                // `.line` segment with a real predecessor point
                // (`segmentIndex > 0` - a subpath's own `.move` at
                // index 0 has no "line before it" to bend).
                return Result.unchanged(path: path, state: state)
            }
            return Result.unchanged(path: path, state: .bending(subpathIndex: subpathIndex, segmentIndex: segmentIndex, originalSegment: segment))

        case (.bending(let subpathIndex, let segmentIndex, let original), .bend(let offset)):
            guard case .line(let end) = original,
                  let start = path.subpaths[safe: subpathIndex]?.segments[safe: segmentIndex - 1]?.endPoint
            else {
                return Result.unchanged(path: path, state: .idle)
            }
            var newPath = path
            newPath.subpaths[subpathIndex].segments[segmentIndex] = Self.bentSegment(from: start, to: end, offset: offset)
            return Result.unchanged(path: newPath, state: state)

        case (.bending(let subpathIndex, let segmentIndex, _), .endBend):
            return Result(path: path, state: .idle, completedOperation: .segmentBent(subpathIndex: subpathIndex, segmentIndex: segmentIndex))

        case (.bending(let subpathIndex, let segmentIndex, let original), .cancelBend):
            var newPath = path
            if path.subpaths[safe: subpathIndex]?.segments[safe: segmentIndex] != nil {
                newPath.subpaths[subpathIndex].segments[segmentIndex] = original
            }
            return Result.unchanged(path: newPath, state: .idle)

        // MARK: Deletion

        case (.idle, .deleteSegment(let subpathIndex, let segmentIndex)):
            guard var subpath = path.subpaths[safe: subpathIndex],
                  subpath.segments.indices.contains(segmentIndex),
                  subpath.segments.count > 1
            else {
                // An out-of-range index, or deleting the LAST remaining
                // segment (an empty subpath is not a meaningful edit
                // result - deleting the whole subpath is
                // `.deleteSubpath` below) - no-op.
                return Result.unchanged(path: path, state: state)
            }
            subpath.segments.remove(at: segmentIndex)
            if segmentIndex == 0, let newFirst = subpath.segments.first {
                // Deleting the `.move` promotes the new first segment
                // to an implicit move AT THE SAME POINT, keeping
                // "a subpath's first segment is always `.move`"
                // (`ShapePathSegment`'s own doc comment) intact rather
                // than leaving a dangling `.line`/`.quad`/`.cubic` first.
                subpath.segments[0] = .move(newFirst.endPoint)
            }
            var newPath = path
            newPath.subpaths[subpathIndex] = subpath
            return Result(path: newPath, state: .idle, completedOperation: .segmentDeleted(subpathIndex: subpathIndex, segmentIndex: segmentIndex))

        case (.idle, .deleteSubpath(let subpathIndex)):
            guard path.subpaths.indices.contains(subpathIndex) else {
                return Result.unchanged(path: path, state: state)
            }
            var newPath = path
            newPath.subpaths.remove(at: subpathIndex)
            return Result(path: newPath, state: .idle, completedOperation: .subpathDeleted(subpathIndex: subpathIndex))

        // MARK: Anything else: out-of-sequence, no-op.

        default:
            return Result.unchanged(path: path, state: state)
        }
    }

    // MARK: - Segment point access

    private static func isValid(slot: SegmentPointSlot, for segment: ShapePathSegment) -> Bool {
        switch (segment, slot) {
        case (_, .endpoint): return true
        case (.quad, .quadControl): return true
        case (.cubic, .cubicControl1), (.cubic, .cubicControl2): return true
        default: return false
        }
    }

    /// Returns `segment` with `slot`'s point replaced by `point` - a
    /// no-op (returns `segment` unchanged) when `slot` does not match
    /// `segment`'s own case, matching `isValid(slot:for:)` above; every
    /// call site already guards with that function before entering a
    /// drag, so this mismatch path only matters for a `ShapePath`
    /// mutated out from under an in-progress drag between frames.
    private static func settingPoint(of segment: ShapePathSegment, slot: SegmentPointSlot, to point: ShapePathPoint) -> ShapePathSegment {
        switch (segment, slot) {
        case (.move, .endpoint):
            return .move(point)
        case (.line, .endpoint):
            return .line(point)
        case (.quad(_, let end), .quadControl):
            return .quad(control: point, end: end)
        case (.quad(let control, _), .endpoint):
            return .quad(control: control, end: point)
        case (.cubic(_, let control2, let end), .cubicControl1):
            return .cubic(control1: point, control2: control2, end: end)
        case (.cubic(let control1, _, let end), .cubicControl2):
            return .cubic(control1: control1, control2: point, end: end)
        case (.cubic(let control1, let control2, _), .endpoint):
            return .cubic(control1: control1, control2: control2, end: point)
        default:
            return segment
        }
    }

    // MARK: - Bend tool solve

    /// Turns the straight line from `start` to `end` into a cubic curve
    /// bowed by `offset`: control points sit at exactly 1/3 and 2/3
    /// along the straight line, each additionally displaced by
    /// `offset`. `offset == .zero` is a deliberately exact identity - a
    /// cubic bezier whose two control points sit ON the straight line
    /// at the 1/3 and 2/3 parametric marks traces that same straight
    /// line exactly (a real, testable property, not an approximation),
    /// so the bend tool with no drag distance yet is indistinguishable
    /// from the `.line` it started from; any nonzero `offset` bows the
    /// segment smoothly in that direction, matching the familiar
    /// drag-the-middle-of-an-edge-to-bow-it interaction.
    static func bentSegment(from start: ShapePathPoint, to end: ShapePathPoint, offset: CGVector) -> ShapePathSegment {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let control1 = ShapePathPoint(x: start.x + dx / 3 + Double(offset.dx), y: start.y + dy / 3 + Double(offset.dy))
        let control2 = ShapePathPoint(x: start.x + dx * 2 / 3 + Double(offset.dx), y: start.y + dy * 2 / 3 + Double(offset.dy))
        return .cubic(control1: control1, control2: control2, end: end)
    }
}

// MARK: - Array safe-subscript

extension Array {
    /// `nil` for an out-of-range index instead of a trap - every
    /// `BezierPathController` command references indices supplied by a
    /// caller (a future gesture layer's own hit-test), which this pure
    /// state machine treats as untrusted input: an index that no longer
    /// names anything (the path changed out from under an in-progress
    /// gesture) degrades to a no-op `Result`, matching this file's
    /// other "pure functions degrade rather than trap" call sites.
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
