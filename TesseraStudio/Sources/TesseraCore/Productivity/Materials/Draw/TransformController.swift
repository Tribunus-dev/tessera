//===----------------------------------------------------------------------===//
//  TransformController.swift
//  Tessera Studio
//
//  Pure resize/rotate solve for the Draw canvas (P1 item 1.16,
//  studio-expansion-design-refinement-2026-08-14.md's Draw cluster).
//  8 resize handles + a dedicated rotation handle (LO/PowerPoint
//  convention - the rotation handle is its own affordance, never one
//  of the 8). Stateless and side-effect-free, matching ShapeZOrder/
//  LayerStore in this same directory: this computes proposed geometry
//  only and never touches DrawingStore.
//
//  Zero store writes during drag; one commit per gesture. The caller
//  (a future editor view) calls `resize`/`rotate` per selected shape
//  as the gesture updates (a pure function, cheap to call every frame),
//  then at gesture-end calls `DrawingStore.setGeometry` once per shape
//  and wraps a multi-shape gesture's resulting receipts in
//  `ReceiptUndoManager.group(_:)` so one drag is one undo unit. Both
//  `resize` and `rotate` already return a plain value rather than
//  performing a write, so a caller driving a multi-selection composes
//  them with a single `shapes.map { resize(...) }` - one array in, one
//  array out, no per-shape store round-trip baked into this type.
//
//  `anchorX`/`anchorY` (the ROTATION pivot - see `ShapeGeometry`) are
//  read-only here. Neither `resize` nor `rotate` ever assigns them;
//  both copy `startGeometry`'s value straight through. That is the
//  whole of the "transient gesture anchors are never written to the
//  stored anchorX/anchorY" contract for this file - a plain resize or
//  rotate never touches them, mid-drag or at commit.
//===----------------------------------------------------------------------===//

import Foundation
import CoreGraphics

// MARK: - TransformController

public enum TransformController {

    // MARK: - Handle

    /// The 8 resize handles (4 corners + 4 edge midpoints) plus the
    /// dedicated rotation handle.
    public enum Handle: CaseIterable, Sendable, Equatable, Hashable {
        case topLeft, top, topRight
        case right
        case bottomRight, bottom, bottomLeft
        case left
        case rotation

        /// This handle's position within the shape's UNROTATED local
        /// frame, as an (fx, fy) fraction of (width, height) - e.g.
        /// `topRight` is (1, 0). `rotation` has no frame-relative
        /// fraction (its position is a fixed offset above `top` - see
        /// `localPosition(of:in:)`), so it returns `nil`; every other
        /// case returns non-nil, which is what lets `resize(...)`
        /// force-unwrap it after excluding `.rotation` up front.
        fileprivate var fraction: (fx: Double, fy: Double)? {
            switch self {
            case .topLeft:     return (0, 0)
            case .top:         return (0.5, 0)
            case .topRight:    return (1, 0)
            case .right:       return (1, 0.5)
            case .bottomRight: return (1, 1)
            case .bottom:      return (0.5, 1)
            case .bottomLeft:  return (0, 1)
            case .left:        return (0, 0.5)
            case .rotation:    return nil
            }
        }

        /// The handle diagonally/orthogonally opposite this one - the
        /// point the rotated-resize solve holds world-fixed by
        /// default (Option-key resize substitutes the shape's own
        /// center instead - see `resize(...)`). `nil` for `.rotation`,
        /// which has no opposite.
        public var opposite: Handle? {
            switch self {
            case .topLeft:     return .bottomRight
            case .top:         return .bottom
            case .topRight:    return .bottomLeft
            case .right:       return .left
            case .bottomRight: return .topLeft
            case .bottom:      return .top
            case .bottomLeft:  return .topRight
            case .left:        return .right
            case .rotation:    return nil
            }
        }
    }

    /// Points above the `top` handle the rotation handle sits at,
    /// before rotation - the fixed offset every mainstream drawing
    /// tool uses for the dedicated rotation affordance.
    public static let rotationHandleOffset: Double = 24

    // MARK: - Handle position

    /// `handle`'s position in the shape's own unrotated frame - the
    /// same flat coordinate space `geometry.x`/`y`/`width`/`height`
    /// are already in (see `ShapeGeometry`'s header).
    private static func localPosition(of handle: Handle, in geometry: ShapeGeometry) -> CGPoint {
        if let f = handle.fraction {
            return CGPoint(x: geometry.x + f.fx * geometry.width, y: geometry.y + f.fy * geometry.height)
        }
        // .rotation: fixed offset above the top-center handle.
        return CGPoint(x: geometry.x + geometry.width / 2, y: geometry.y - rotationHandleOffset)
    }

    /// The rotation pivot in the same flat coordinate space, resolved
    /// exactly as `ShapeRenderer.applyRotation` resolves it: the
    /// shape's own origin plus `anchorPoint` (which itself falls back
    /// to the frame's center when `anchorX`/`anchorY` are unset).
    private static func worldPivot(_ geometry: ShapeGeometry) -> CGPoint {
        CGPoint(x: geometry.x + geometry.anchorPoint.x, y: geometry.y + geometry.anchorPoint.y)
    }

    /// Rotate `point` by `degrees` clockwise about `pivot`, matching
    /// `ShapeGeometry.rotation`'s documented sign convention in the
    /// coordinate space this type assumes throughout (origin top-left,
    /// y increasing downward - `ShapeRenderer.applyRotation`'s
    /// `context.rotate(by:)` call produces the same visual result from
    /// the same flat numbers).
    private static func rotate(_ point: CGPoint, around pivot: CGPoint, byDegrees degrees: Double) -> CGPoint {
        guard degrees != 0 else { return point }
        let theta = degrees * .pi / 180
        let dx = point.x - pivot.x
        let dy = point.y - pivot.y
        let cosT = CGFloat(cos(theta))
        let sinT = CGFloat(sin(theta))
        return CGPoint(x: pivot.x + dx * cosT - dy * sinT, y: pivot.y + dx * sinT + dy * cosT)
    }

    /// `handle`'s position in the drawing's canvas coordinates,
    /// rotation applied - exactly where the handle paints (before any
    /// view-level pan/zoom transform). Pure function of `geometry`;
    /// used both to lay out the 9 handle affordances and, inside
    /// `resize(...)`, to recover a handle's pre-drag position.
    public static func position(of handle: Handle, in geometry: ShapeGeometry) -> CGPoint {
        rotate(localPosition(of: handle, in: geometry), around: worldPivot(geometry), byDegrees: geometry.rotation)
    }

    // MARK: - Resize

    /// Modifier keys the resize solve recognizes. Not a raw key-event
    /// type - this file has no AppKit/UIKit dependency; the caller
    /// translates its own event's modifier flags into this.
    public struct ResizeOptions: Sendable, Equatable {
        /// Option/Alt: resize about the shape's own center instead of
        /// the opposite handle.
        public var centerAnchored: Bool
        /// Shift: preserve `startGeometry`'s aspect ratio.
        public var aspectLocked: Bool

        public init(centerAnchored: Bool = false, aspectLocked: Bool = false) {
            self.centerAnchored = centerAnchored
            self.aspectLocked = aspectLocked
        }
    }

    /// Resolve one resize drag: `handle` moved by `worldDelta` (canvas
    /// space, the same space `position(of:in:)` returns) from
    /// `startGeometry`. Implements the documented "unrotate, resize in
    /// local space, re-rotate" solve, plus the pivot correction a
    /// rotated shape needs (see the long comment inline below).
    ///
    /// `width`/`height` never go negative: dragging a handle past its
    /// reference point flips the matching `flipH`/`flipV` flag instead
    /// (drag-past-opposite, LO/PowerPoint/Keynote convention) and
    /// continues resizing in the flipped orientation.
    ///
    /// `anchorX`/`anchorY` are untouched - copied from `startGeometry`
    /// unchanged (see this file's header).
    public static func resize(
        handle: Handle,
        startGeometry: ShapeGeometry,
        worldDelta: CGVector,
        options: ResizeOptions = ResizeOptions()
    ) -> ShapeGeometry {
        precondition(handle != .rotation, "TransformController.resize does not accept .rotation - see rotate(...)")
        let (fx, fy) = handle.fraction!

        let pivot = worldPivot(startGeometry)
        let startHandleWorld = position(of: handle, in: startGeometry)
        let draggedWorld = CGPoint(x: startHandleWorld.x + worldDelta.dx, y: startHandleWorld.y + worldDelta.dy)
        // Unrotate the drag point: which flat (unrotated) point is now
        // under the cursor.
        let draggedLocal = rotate(draggedWorld, around: pivot, byDegrees: -startGeometry.rotation)

        // The reference point that must stay world-fixed: the
        // opposite handle, or the shape's own center under Option.
        // `opposite.fraction` already carries (0.5, ...) or (..., 0.5)
        // on whichever axis IT doesn't affect, so using it directly
        // below (rather than branching per axis) already gives the
        // right "hold this axis at the shape's own center" behavior
        // for edge handles - no separate case needed.
        let referenceFraction: (fx: Double, fy: Double)
        let referenceLocal: CGPoint
        let referenceWorld: CGPoint
        if options.centerAnchored {
            referenceFraction = (0.5, 0.5)
            referenceLocal = CGPoint(x: startGeometry.x + startGeometry.width / 2, y: startGeometry.y + startGeometry.height / 2)
            referenceWorld = rotate(referenceLocal, around: pivot, byDegrees: startGeometry.rotation)
        } else {
            let opposite = handle.opposite!
            referenceFraction = opposite.fraction!
            referenceLocal = localPosition(of: opposite, in: startGeometry)
            referenceWorld = position(of: opposite, in: startGeometry)
        }

        var newWidth = startGeometry.width
        var newHeight = startGeometry.height
        var flipH = startGeometry.flipH
        var flipV = startGeometry.flipV

        if fx != 0.5 {
            newWidth = extent(centerAnchored: options.centerAnchored, fixed: referenceLocal.x, dragged: draggedLocal.x)
            if crossed(handleFraction: fx, fixed: referenceLocal.x, dragged: draggedLocal.x) { flipH.toggle() }
        }
        if fy != 0.5 {
            newHeight = extent(centerAnchored: options.centerAnchored, fixed: referenceLocal.y, dragged: draggedLocal.y)
            if crossed(handleFraction: fy, fixed: referenceLocal.y, dragged: draggedLocal.y) { flipV.toggle() }
        }

        // Shift: rescale to `startGeometry`'s aspect ratio. The axis
        // whose raw extent changed proportionally more drives a common
        // scale factor applied to both dimensions - an edge handle's
        // un-dragged axis (which only ever reaches this as the
        // `else` branch, since it never satisfies the `&&`) is driven
        // entirely by the axis actually dragged.
        if options.aspectLocked, startGeometry.width > 0, startGeometry.height > 0 {
            let scaleX = newWidth / startGeometry.width
            let scaleY = newHeight / startGeometry.height
            let scale = (fx != 0.5 && fy != 0.5)
                ? (abs(scaleX - 1) >= abs(scaleY - 1) ? scaleX : scaleY)
                : (fx != 0.5 ? scaleX : scaleY)
            newWidth = startGeometry.width * scale
            newHeight = startGeometry.height * scale
        }

        // The render pivot (`worldPivot`) is itself origin + anchor
        // offset, so it moves whenever origin moves - which the
        // reference point's own world position must NOT do. Solving
        // rotate(referenceLocalInNewGeometry, around: worldPivot(new),
        // rotation) == referenceWorld for the unknown new origin
        // (everything else - newWidth/newHeight, hence the anchor
        // offset and the reference's offset-from-origin - is already
        // fixed above) gives the closed form below. This is why origin
        // is not simply `min(reference, dragged)` the way an unrotated
        // resize would compute it - that shortcut only happens to be
        // right for the 3 handles that never move the origin at all
        // (right/bottom/bottomRight); every other handle needs this
        // once rotation != 0.
        let anchorOffset = CGPoint(x: startGeometry.anchorX ?? newWidth / 2, y: startGeometry.anchorY ?? newHeight / 2)
        let referenceOffsetFromOrigin = CGPoint(x: referenceFraction.fx * newWidth, y: referenceFraction.fy * newHeight)
        let rotatedOffsetDelta = rotate(
            CGPoint(x: referenceOffsetFromOrigin.x - anchorOffset.x, y: referenceOffsetFromOrigin.y - anchorOffset.y),
            around: .zero,
            byDegrees: startGeometry.rotation
        )
        let newOrigin = CGPoint(
            x: referenceWorld.x - anchorOffset.x - rotatedOffsetDelta.x,
            y: referenceWorld.y - anchorOffset.y - rotatedOffsetDelta.y
        )

        var result = startGeometry
        result.x = newOrigin.x
        result.y = newOrigin.y
        result.width = newWidth
        result.height = newHeight
        result.flipH = flipH
        result.flipV = flipV
        return result
    }

    /// The new extent along one axis: the distance between the fixed
    /// reference and the dragged point, doubled when the reference is
    /// the shape's own center (Option) since the opposite edge mirrors
    /// the dragged one instead of staying put. Always non-negative -
    /// `crossed(...)` below is what turns a would-be sign flip into
    /// the `flipH`/`flipV` flags instead.
    private static func extent(centerAnchored: Bool, fixed: Double, dragged: Double) -> Double {
        let d = abs(dragged - fixed)
        return centerAnchored ? 2 * d : d
    }

    /// Whether the dragged point ended up on the opposite side of
    /// `fixed` from where this handle started - `handleFraction` is
    /// the DRAGGED handle's own (fx or fy) fraction (0 = started on
    /// the low side, 1 = started on the high side; 0.5 never reaches
    /// here, callers only call this on an axis the handle affects).
    private static func crossed(handleFraction: Double, fixed: Double, dragged: Double) -> Bool {
        let startedHigh = handleFraction > 0.5
        let nowHigh = dragged > fixed
        return startedHigh != nowHigh
    }

    // MARK: - Rotate

    /// Resolve one rotation drag: the pointer moved from `startPoint`
    /// to `currentPoint` (both canvas space) while dragging the
    /// `.rotation` handle. The new `rotation` is `startGeometry`'s own
    /// plus the signed angle between (pivot -> startPoint) and
    /// (pivot -> currentPoint), where pivot is `startGeometry`'s own
    /// `anchorPoint` resolved to canvas coordinates - the SAME pivot
    /// `ShapeRenderer` renders with. `x`/`y`/`width`/`height` and
    /// `flipH`/`flipV` are untouched; a pure rotation never moves
    /// them, so the pivot itself provably cannot shift mid-gesture the
    /// way it can during a resize.
    public static func rotate(
        startGeometry: ShapeGeometry,
        startPoint: CGPoint,
        currentPoint: CGPoint
    ) -> ShapeGeometry {
        let pivot = worldPivot(startGeometry)
        let startAngle = atan2(Double(startPoint.y - pivot.y), Double(startPoint.x - pivot.x))
        let currentAngle = atan2(Double(currentPoint.y - pivot.y), Double(currentPoint.x - pivot.x))
        let deltaDegrees = (currentAngle - startAngle) * 180 / .pi

        var result = startGeometry
        result.rotation = startGeometry.rotation + deltaDegrees
        return result
    }

    // MARK: - Group transform (row 48, P2-0)

    /// The group-recursion entry point the design contract calls for
    /// ("TransformController recurses"): applies a uniform world-space
    /// translation to every shape whose `parentGroupID == groupID`,
    /// instead of only the one shape a drag started on. A
    /// `.shapeGroup` carries no geometry of its own at P0
    /// (`Drawing.swift`'s doc comment: "Carries no geometry of its own
    /// at P0 - group bounds are derived from members, not stored"),
    /// so there is nothing else to move - every member moving by the
    /// same delta together as one rigid body IS what "transforming a
    /// group" means until a P2 group-relative resize/rotate lands.
    ///
    /// `shapes` is the caller's full (unfiltered) shape list - reads
    /// straight through, like `SnapContext.build`'s own `shapes`
    /// parameter; non-members are simply absent from the result, the
    /// same "only the affected ids come back" shape ``resize``/
    /// ``rotate`` don't need since they operate on one shape at a
    /// time. Zero-member `groupID` (nothing currently carries it)
    /// returns an empty dictionary rather than a special-cased nil -
    /// callers already treat "no entries changed" as their own no-op
    /// signal (see `DrawingStore.setGeometries`'s empty-map no-op).
    public static func applyingGroupDelta(
        groupID: UUID,
        shapes: [Shape],
        worldDelta: CGVector
    ) -> [UUID: ShapeGeometry] {
        var result: [UUID: ShapeGeometry] = [:]
        for shape in shapes where shape.parentGroupID == groupID {
            var g = shape.geometry
            g.x += worldDelta.dx
            g.y += worldDelta.dy
            result[shape.id] = g
        }
        return result
    }
}
