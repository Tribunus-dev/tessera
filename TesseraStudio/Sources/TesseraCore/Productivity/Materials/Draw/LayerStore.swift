//===----------------------------------------------------------------------===//
//  LayerStore.swift
//  Tessera Studio
//
//  Named, ordered paint bands (P1 item 1.15, studio-expansion-plan.md
//  row 50): DrawLayer plus the pure ordering/filtering logic that turns
//  (Drawing.layers, Drawing.shapes) into an effective paint order. Pure
//  and stateless, matching ShapeZOrder's shape - DrawingStore remains
//  the only writer; this is the logic it calls.
//
//  Deliberately STRONGER than LibreOffice, where layers are attribute
//  filters that do not affect stacking: here layer order (array
//  position in Drawing.layers) IS paint order, the modern convention
//  every current vector tool follows. ODG round-trip survives this
//  because ODF stores layer membership and document order separately -
//  export writes shapes in effective paint order; import reconstructs
//  layers from draw:layer-set independently of each shape's z-order.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - DrawLayer

/// One named band in a `Drawing`'s paint order. Array position within
/// `Drawing.layers` IS the band's position - there is no separate
/// order field, matching `Drawing.shapes`' own array-position-is-order
/// convention.
///
/// `isLocked`/`isPrintable` are queryable state only: enforcing them
/// (blocking edits on a locked layer, excluding a non-printable one
/// from export) is the consuming surface's job - editor interaction,
/// print/export - not this pure-logic type's.
public struct DrawLayer: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var isVisible: Bool
    public var isLocked: Bool
    public var isPrintable: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        isVisible: Bool = true,
        isLocked: Bool = false,
        isPrintable: Bool = true
    ) {
        self.id = id
        self.name = name
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.isPrintable = isPrintable
    }
}

// MARK: - LayerStore

public enum LayerStore {

    /// `shape`'s band: the index of the layer named by `shape.layerID`
    /// within `layers`, or `-1` when `shape` has no layer (`layerID ==
    /// nil`) or names a layer no longer present. `-1` sorts before
    /// every real index, so an unassigned shape paints on the implicit
    /// base layer, underneath every named one - the same layer every
    /// shape is implicitly on when `layers` is `[]`.
    private static func band(of shape: Shape, layers: [DrawLayer]) -> Int {
        guard let layerID = shape.layerID,
              let index = layers.firstIndex(where: { $0.id == layerID }) else {
            return -1
        }
        return index
    }

    /// The effective paint order: `shapes` stable-sorted by (band,
    /// zIndex) - band first (`band(of:layers:)`, i.e. layer array
    /// position), then `zIndex` within that band. Stable, so shapes
    /// that tie on both (same band, same `zIndex` - `zIndex` need not
    /// be unique, only dense per layer) keep `shapes`' own relative
    /// order, the same guarantee `ShapeZOrder.apply`'s input handling
    /// documents.
    ///
    /// Visibility plays no part here - this is ordering only. Use
    /// ``renderList(shapes:layers:)`` for what the canvas actually
    /// draws.
    public static func paintOrder(shapes: [Shape], layers: [DrawLayer]) -> [Shape] {
        shapes.sorted { lhs, rhs in
            let lhsBand = band(of: lhs, layers: layers)
            let rhsBand = band(of: rhs, layers: layers)
            if lhsBand != rhsBand { return lhsBand < rhsBand }
            return lhs.zIndex < rhs.zIndex
        }
    }

    /// ``paintOrder(shapes:layers:)`` with shapes on a hidden layer
    /// removed - what the canvas actually draws. A pure filter on the
    /// read path: hiding a layer never touches any shape's `zIndex`,
    /// here or anywhere else - `zIndex` is a paint position within a
    /// layer, and a layer's visibility is not part of what it means.
    public static func renderList(shapes: [Shape], layers: [DrawLayer]) -> [Shape] {
        let hiddenLayerIDs = Set(layers.filter { !$0.isVisible }.map(\.id))
        return paintOrder(shapes: shapes, layers: layers).filter { shape in
            guard let layerID = shape.layerID else { return true }
            return !hiddenLayerIDs.contains(layerID)
        }
    }
}
