//===----------------------------------------------------------------------===//
//  ShapeZOrder.swift
//  Tessera Studio
//
//  Z-order control (P0 item 0.16, studio-expansion-plan.md row 46):
//  bring forward, send backward, to front, to back. Pure and stateless,
//  matching FormulaReferenceAdjuster's shape (a plain transform over a
//  value, no store dependency) - the Drawing material itself (0.15)
//  is not built yet, so this has no natural persistence-layer home to
//  live inside; it is ready to be called from wherever that store
//  lands without this file needing to change.
//===----------------------------------------------------------------------===//

import Foundation

public enum ShapeZOrder {

    /// One step forward/backward, or all the way to an end. Mirrors
    /// `drawing_set_z_order`'s argument shape in
    /// `docs/agent-tools-surface.md` (`z: Int | bringForward |
    /// sendBackward | toFront | toBack`) minus the raw-`Int` case,
    /// which is just `zIndex` assignment and needs no helper here.
    public enum Move: Sendable, Equatable {
        case bringForward
        case sendBackward
        case toFront
        case toBack
    }

    /// Apply `move` to the shape at `id` within `shapes`, returning a
    /// new array with every shape's `zIndex` renumbered densely
    /// (0, 1, 2, ...) in the resulting paint order.
    ///
    /// Renumbering on every call - not just adjusting the moved
    /// shape's own index - is deliberate: z-order operations compose
    /// (bring-forward, bring-forward, send-to-back, ...), and sparse or
    /// fractional indices drift and eventually collide under repeated
    /// use. A dense renumber after each move is simpler to reason
    /// about and keeps `zIndex` meaning exactly one thing: position in
    /// today's paint order, not a record of how it got there.
    ///
    /// `shapes` need not arrive already sorted by `zIndex` - paint
    /// order is established here, from whatever order the caller's
    /// storage happens to hand back.
    public static func apply(_ move: Move, to id: UUID, in shapes: [Shape]) -> [Shape] {
        var ordered = shapes.sorted { $0.zIndex < $1.zIndex }
        guard let from = ordered.firstIndex(where: { $0.id == id }) else { return shapes }

        let to: Int
        switch move {
        case .bringForward:
            to = min(from + 1, ordered.count - 1)
        case .sendBackward:
            to = max(from - 1, 0)
        case .toFront:
            to = ordered.count - 1
        case .toBack:
            to = 0
        }

        if to != from {
            let shape = ordered.remove(at: from)
            ordered.insert(shape, at: to)
        }

        for i in ordered.indices {
            ordered[i].zIndex = i
        }
        return ordered
    }
}
