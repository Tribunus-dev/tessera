import Foundation
import CoreGraphics

// MARK: - SlideLayoutPlaceholder

/// One placeholder block a ``SlideLayoutSpec`` creates - a `blockType`
/// plus its own nested placeholders, mirroring `Block.children`'s
/// shape (e.g. `.titleAndContent`'s single `.toggle` placeholder wraps
/// a `.heading` and a `.paragraph`, matching `SlideDeck
/// .insertingSlide`'s current toggle-wrapping exactly).
public struct SlideLayoutPlaceholder: Codable, Sendable, Hashable {
    public var blockType: BlockType
    public var children: [SlideLayoutPlaceholder]
    /// OOXML-style placeholder index (P1 1.9) - the placeholder's
    /// explicit identity within its owning ``SlideLayoutSpec``, scoped
    /// to that spec (not globally unique across the catalog). Real,
    /// unique-per-spec idx values are what let `SlideStore.setSlideLayout`
    /// re-bind an already-placed block to the SAME placeholder across
    /// repeated layout applications even if block order in the tree
    /// changes - the OOXML lesson: identity by position is unstable,
    /// identity by idx is not. `nil` only for a placeholder that
    /// predates this field; every entry in ``SlideLayoutSpec/builtins``
    /// assigns a real one.
    public var idx: Int?
    /// Optional human-readable label for a layout-picker UI (e.g.
    /// "Title", "Content Left"). Purely presentational.
    public var name: String?
    /// The placeholder's frame in normalized 0...1 unit-square
    /// coordinates ("U" for "unit", P1 1.7) - top-left origin, matching
    /// `ShapeGeometry`'s documented convention elsewhere in this
    /// codebase, so a layout renders identically at any output size
    /// (canvas, thumbnail, print) without a separate per-size frame
    /// table. `nil` means no explicit frame: none of ``builtins`` sets
    /// one yet (P1 1.9 shipped `idx`/`name` only), so
    /// ``SlideDeckRenderer`` falls back to a reasonable default
    /// position/size for the placeholder's `blockType` rather than
    /// crashing or drawing at zero size.
    public var frameU: CGRect?

    public init(
        blockType: BlockType,
        children: [SlideLayoutPlaceholder] = [],
        idx: Int? = nil,
        name: String? = nil,
        frameU: CGRect? = nil
    ) {
        self.blockType = blockType
        self.children = children
        self.idx = idx
        self.name = name
        self.frameU = frameU
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
/// produce.
///
/// P1 1.9 (MasterPageLayoutPicker) is that consumer: it grows
/// ``builtins`` from the 4 `SlideLayout`-backed defaults to the LO
/// AutoLayout catalog (~25) and gives every placeholder a real `idx`.
/// `SlideStore.setSlideLayout` reads a spec's `placeholders` to
/// rearrange a slide's blocks (idx-then-type matching, orphans kept -
/// see that method). `SlideDeck.insertingSlide`'s own switch, and the
/// 4 built-ins' placeholder SHAPE, are still untouched by this - only
/// `idx`/`name` were added to the 4, so `builtins.count` is now ~25,
/// not `SlideLayout.allCases.count`.
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
    /// top-level heading. Placeholder shape (blockType/children)
    /// UNCHANGED from P0 0.7 - only `idx` is new - so this still
    /// matches `insertingSlide`'s real output exactly.
    public static let title = SlideLayoutSpec(
        id: SlideLayout.title.rawValue,
        name: SlideLayout.title.displayName,
        placeholders: [SlideLayoutPlaceholder(blockType: .heading, idx: 0, name: "Title")]
    )

    /// Mirrors the `.titleAndContent` case: one top-level toggle
    /// wrapping a heading and a paragraph.
    public static let titleAndContent = SlideLayoutSpec(
        id: SlideLayout.titleAndContent.rawValue,
        name: SlideLayout.titleAndContent.displayName,
        placeholders: [
            SlideLayoutPlaceholder(blockType: .toggle, children: [
                SlideLayoutPlaceholder(blockType: .heading, idx: 0, name: "Title"),
                SlideLayoutPlaceholder(blockType: .paragraph, idx: 1, name: "Content"),
            ]),
        ]
    )

    /// Mirrors the `.image` case: one top-level image block.
    public static let image = SlideLayoutSpec(
        id: SlideLayout.image.rawValue,
        name: SlideLayout.image.displayName,
        placeholders: [SlideLayoutPlaceholder(blockType: .image, idx: 0, name: "Picture")]
    )

    /// Mirrors the `.blank` case: one empty top-level paragraph.
    public static let blank = SlideLayoutSpec(
        id: SlideLayout.blank.rawValue,
        name: SlideLayout.blank.displayName,
        placeholders: [SlideLayoutPlaceholder(blockType: .paragraph, idx: 0, name: "Content")]
    )

    // MARK: - AutoLayout catalog (P1 1.9)

    /// A real content slot: a leaf placeholder with stable per-spec
    /// `idx` identity and a picker-facing label.
    private static func slot(_ type: BlockType, _ idx: Int, _ name: String) -> SlideLayoutPlaceholder {
        SlideLayoutPlaceholder(blockType: type, idx: idx, name: name)
    }

    /// A catalog entry whose content is a single, unwrapped placeholder
    /// - matches `insertingSlide`'s bare-block convention (`.title` /
    /// `.image` / `.blank`).
    private static func single(_ id: String, _ name: String, _ type: BlockType, _ slotName: String) -> SlideLayoutSpec {
        SlideLayoutSpec(id: id, name: name, placeholders: [slot(type, 0, slotName)])
    }

    /// A catalog entry whose root placeholder wraps 2+ content slots -
    /// `insertingSlide`'s toggle-wrapping convention (`.titleAndContent`)
    /// generalized to N slots instead of exactly 2.
    private static func wrapping(_ id: String, _ name: String, _ slots: [SlideLayoutPlaceholder]) -> SlideLayoutSpec {
        SlideLayoutSpec(id: id, name: name, placeholders: [SlideLayoutPlaceholder(blockType: .toggle, children: slots)])
    }

    /// The LO Impress AutoLayout catalog (refinement doc section 4,
    /// Slides cluster, item 1.9) as DATA, layered on top of the 4
    /// `SlideLayout`-backed built-ins above. `BlockType` is not
    /// extended for this - every slot below reuses an existing case
    /// (`.heading` / `.paragraph` / `.image` / `.table` / `.list`);
    /// `.toggle` is reserved for the wrapping container, never a
    /// content slot, matching the built-ins' own convention.
    private static let autoLayoutCatalog: [SlideLayoutSpec] = [
        single("titleOnly", "Title Only", .heading, "Title"),
        wrapping("sectionHeader", "Section Header", [
            slot(.heading, 0, "Title"), slot(.paragraph, 1, "Text"),
        ]),
        wrapping("titleAndTable", "Title, Table", [
            slot(.heading, 0, "Title"), slot(.table, 1, "Table"),
        ]),
        wrapping("titleAndPicture", "Title, Picture", [
            slot(.heading, 0, "Title"), slot(.image, 1, "Picture"),
        ]),
        wrapping("titleAndList", "Title, Bulleted List", [
            slot(.heading, 0, "Title"), slot(.list, 1, "Bulleted List"),
        ]),
        wrapping("twoContent", "Two Content", [
            slot(.heading, 0, "Title"), slot(.paragraph, 1, "Content Left"), slot(.paragraph, 2, "Content Right"),
        ]),
        wrapping("comparison", "Comparison", [
            slot(.heading, 0, "Title"),
            slot(.paragraph, 1, "Caption Left"), slot(.paragraph, 2, "Content Left"),
            slot(.paragraph, 3, "Caption Right"), slot(.paragraph, 4, "Content Right"),
        ]),
        wrapping("contentWithCaption", "Content with Caption", [
            slot(.heading, 0, "Title"), slot(.paragraph, 1, "Text"), slot(.image, 2, "Content"),
        ]),
        wrapping("pictureWithCaption", "Picture with Caption", [
            slot(.heading, 0, "Title"), slot(.image, 1, "Picture"), slot(.paragraph, 2, "Caption"),
        ]),
        wrapping("titleTwoContentOverContent", "Title, Two Content over Content", [
            slot(.heading, 0, "Title"),
            slot(.paragraph, 1, "Content Top Left"), slot(.paragraph, 2, "Content Top Right"),
            slot(.paragraph, 3, "Content Bottom"),
        ]),
        wrapping("titleContentOverTwoContent", "Title, Content over Two Content", [
            slot(.heading, 0, "Title"), slot(.paragraph, 1, "Content Top"),
            slot(.paragraph, 2, "Content Bottom Left"), slot(.paragraph, 3, "Content Bottom Right"),
        ]),
        wrapping("titleFourContent", "Title, Four Content", [
            slot(.heading, 0, "Title"),
            slot(.paragraph, 1, "Content 1"), slot(.paragraph, 2, "Content 2"),
            slot(.paragraph, 3, "Content 3"), slot(.paragraph, 4, "Content 4"),
        ]),
        wrapping("titleSixContent", "Title, Six Content", [
            slot(.heading, 0, "Title"),
            slot(.paragraph, 1, "Content 1"), slot(.paragraph, 2, "Content 2"), slot(.paragraph, 3, "Content 3"),
            slot(.paragraph, 4, "Content 4"), slot(.paragraph, 5, "Content 5"), slot(.paragraph, 6, "Content 6"),
        ]),
        single("centeredText", "Centered Text", .paragraph, "Text"),
        wrapping("verticalTitleAndText", "Vertical Title and Text", [
            slot(.heading, 0, "Title"), slot(.paragraph, 1, "Vertical Text"),
        ]),
        wrapping("verticalTitleVerticalText", "Vertical Title, Vertical Text", [
            slot(.heading, 0, "Title"), slot(.list, 1, "Vertical Outline"),
        ]),
        wrapping("titleTableAndContent", "Title, Table and Content", [
            slot(.heading, 0, "Title"), slot(.table, 1, "Table"), slot(.paragraph, 2, "Notes"),
        ]),
        wrapping("titleTwoPicture", "Title, Two Picture", [
            slot(.heading, 0, "Title"), slot(.image, 1, "Picture Left"), slot(.image, 2, "Picture Right"),
        ]),
        wrapping("titleContentAndList", "Title, Content and List", [
            slot(.heading, 0, "Title"), slot(.paragraph, 1, "Content"), slot(.list, 2, "Bulleted List"),
        ]),
        single("tableOnly", "Table Only", .table, "Table"),
        single("listOnly", "Bulleted List Only", .list, "Bulleted List"),
    ]

    /// Every built-in - the 4 `SlideLayout`-backed defaults plus the
    /// LO AutoLayout catalog (~25 total, P1 1.9). `default(for:)` below
    /// still resolves the 4 `SlideLayout` cases directly, independent
    /// of this array's contents or order.
    public static let builtins: [SlideLayoutSpec] = [.title, .titleAndContent, .image, .blank] + autoLayoutCatalog

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
