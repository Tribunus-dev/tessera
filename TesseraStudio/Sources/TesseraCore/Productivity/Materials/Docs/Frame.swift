import Foundation

// MARK: - FrameAnchor

/// How a `.frame` block is positioned relative to the surrounding
/// flow. Mirrors LO's `SwFlyFrame` anchor kinds
/// (`sw/source/core/layout/flylay.cxx`) closely enough to round-trip
/// ODT/DOCX anchored text boxes without losing the anchor type.
public enum FrameAnchor: String, Codable, Sendable, Hashable, CaseIterable {
    /// Fixed to the page, ignores surrounding text reflow.
    case page
    /// Tied to a paragraph; moves with it as the document reflows.
    case paragraph
    /// Tied to a specific character position within a paragraph.
    case character
    /// Flows inline as if it were a character in the text run.
    case asCharacter
}

// MARK: - FrameProperties

/// Position, size, and anchor for one `.frame` block - see
/// ``Block/frame``. Kept as its own nested Codable type (rather than
/// flattened attribute keys) matching ``ShapeGeometry``'s convention,
/// so `Block.frame`'s own `Codable` conformance stays the single
/// source of truth for the wire shape.
public struct FrameProperties: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var anchor: FrameAnchor

    public init(x: Double, y: Double, width: Double, height: Double, anchor: FrameAnchor = .paragraph) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.anchor = anchor
    }
}
