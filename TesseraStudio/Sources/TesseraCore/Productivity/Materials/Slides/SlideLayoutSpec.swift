import Foundation

// MARK: - SlideLayoutPlaceholder

/// One placeholder block a ``SlideLayoutSpec`` creates - a `blockType`
/// plus its own nested placeholders, mirroring `Block.children`'s
/// shape (e.g. `.titleAndContent`'s single `.toggle` placeholder wraps
/// a `.heading` and a `.paragraph`, matching `SlideDeck
/// .insertingSlide`'s current toggle-wrapping exactly).
public struct SlideLayoutPlaceholder: Codable, Sendable, Hashable {
    public var blockType: BlockType
    public var children: [SlideLayoutPlaceholder]

    public init(blockType: BlockType, children: [SlideLayoutPlaceholder] = []) {
        self.blockType = blockType
        self.children = children
    }
}

// MARK: - SlideLayoutSpec

/// A named placeholder-block recipe for a new slide.
///
/// `SlideLayout`'s 4 cases (title/titleAndContent/image/blank) become
/// this type's built-in defaults via ``default(for:)`` - "the 4-case
/// enum becomes defaults; no v2 enum" per studio-expansion-plan.md
/// 0.7. The enum itself is untouched: it stays the compact, persisted
/// selector `SlideMeta.layout` stores, and `SlideLayoutSpec` is what
/// describes what a layout actually MEANS in terms of placeholder
/// blocks, in a shape a future custom-layout picker (P1, LO's 25+
/// AutoLayout catalog per the decision log) can extend without a
/// second enum case explosion.
///
/// **What this does NOT do**: `SlideDeck.insertingSlide(at:layout:
/// title:)`'s own block-generation switch is UNCHANGED - it is not
/// refactored to read `placeholders` from this type. A
/// behavior-preserving refactor of already-shipped, already-tested
/// slide-creation code has no upside without a consumer that actually
/// needs the flexibility yet (the P1 custom-layout picker is that
/// consumer); until then this type exists purely as an accurate,
/// introspectable description of what the 4 built-in layouts already
/// produce - `SlideLayoutSpecTests` pins that the two stay in sync.
public struct SlideLayoutSpec: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var placeholders: [SlideLayoutPlaceholder]

    public init(id: String, name: String, placeholders: [SlideLayoutPlaceholder]) {
        self.id = id
        self.name = name
        self.placeholders = placeholders
    }

    // MARK: - Built-ins

    /// Mirrors `SlideDeck.insertingSlide`'s `.title` case: one
    /// top-level heading.
    public static let title = SlideLayoutSpec(
        id: SlideLayout.title.rawValue,
        name: SlideLayout.title.displayName,
        placeholders: [SlideLayoutPlaceholder(blockType: .heading)]
    )

    /// Mirrors the `.titleAndContent` case: one top-level toggle
    /// wrapping a heading and a paragraph.
    public static let titleAndContent = SlideLayoutSpec(
        id: SlideLayout.titleAndContent.rawValue,
        name: SlideLayout.titleAndContent.displayName,
        placeholders: [
            SlideLayoutPlaceholder(blockType: .toggle, children: [
                SlideLayoutPlaceholder(blockType: .heading),
                SlideLayoutPlaceholder(blockType: .paragraph),
            ]),
        ]
    )

    /// Mirrors the `.image` case: one top-level image block.
    public static let image = SlideLayoutSpec(
        id: SlideLayout.image.rawValue,
        name: SlideLayout.image.displayName,
        placeholders: [SlideLayoutPlaceholder(blockType: .image)]
    )

    /// Mirrors the `.blank` case: one empty top-level paragraph.
    public static let blank = SlideLayoutSpec(
        id: SlideLayout.blank.rawValue,
        name: SlideLayout.blank.displayName,
        placeholders: [SlideLayoutPlaceholder(blockType: .paragraph)]
    )

    /// Every built-in, in `SlideLayout.allCases` order.
    public static let builtins: [SlideLayoutSpec] = [.title, .titleAndContent, .image, .blank]

    /// The spec `layout` maps to by default.
    public static func `default`(for layout: SlideLayout) -> SlideLayoutSpec {
        switch layout {
        case .title: return .title
        case .titleAndContent: return .titleAndContent
        case .image: return .image
        case .blank: return .blank
        }
    }
}
