import Foundation

//===----------------------------------------------------------------------===//
//  StyleRegistry.swift
//  Tessera Studio
//
//  Named paragraph/character/table/list styles for Writer (P1 item 9,
//  studio-expansion-design-refinement-2026-08-14.md's Writer cluster).
//  `StyleDefinition`s live in `DocumentMeta.styles` (the `sections`
//  registry precedent - see `DocumentMeta.styles`'s doc comment in
//  Block.swift); `Block.attributes["styleRef"]` and run-level style
//  refs look a style up by id rather than embedding it, the same
//  indirection `SectionStore`/`attributes["sectionRef"]` already use.
//
//  A thorough grep of this codebase (attribute usage, DocumentExporter,
//  WriterBridgeFilter, LOBridgeDeckIO, the editor toolbar's style
//  buttons) found no pre-existing per-block "string label" style
//  attribute for this `styleRef` to supersede - the only other
//  `attributes["style"]` key is `.list`'s bullet-kind indicator
//  (`"unordered" | "ordered" | "task"`, see `BlockType.list`), an
//  unrelated concept. `styleRef` is a wholly new mechanism, not a
//  replacement for one found in the wild.
//
//  Word's `latentStyles`/`link`/`uiPriority` machinery is explicitly
//  NOT adopted here (design contract) - no style-visibility ranking,
//  no paragraph-style-linked-to-character-style pairing beyond what
//  `StyleFamily` already expresses.
//
//  Pure and stateless, matching `FieldController`/`RevisionController`/
//  `TransformController`/`QueryEngine` in this same wave family:
//  `resolve`/`deletingStyle` take value types and return value types,
//  never touching `DocStore`. A future `DocStore` integration is the
//  one place that both mutates `DocumentMeta.styles` (via
//  `deletingStyle` or a plain dictionary write for define/update) and
//  appends the receipt for that change, mirroring
//  `FieldController.refresh`'s own "future DocStore integration"
//  boundary - this file owns the model and the resolver, not the
//  persistence call.
//===----------------------------------------------------------------------===//

// MARK: - StyleFamily

/// The block/run kinds a style can apply to.
public enum StyleFamily: String, Codable, Sendable, Hashable, CaseIterable {
    case paragraph
    case character
    case table
    case list
}

// MARK: - StyleAlignment

/// Paragraph alignment a style can set. A separate vocabulary from
/// `SheetCellAlignment` (which has no `.justify` and a `.automatic`
/// default that means something specific to spreadsheet cells) rather
/// than reused across domains.
public enum StyleAlignment: String, Codable, Sendable, Hashable, CaseIterable {
    case leading
    case center
    case trailing
    case justify
}

// MARK: - StyleProperties

/// A style's own local property overrides - every field optional,
/// `nil` meaning "this style doesn't touch that property" rather than
/// "clear it". Same shape and contract as
/// ``SheetCellFormatOverlay``'s dxf-style overlay: composing several of
/// these (a `basedOn` chain, then run annotations) is how
/// ``StyleRegistry/resolve(runAnnotations:characterStyleRef:paragraphStyleRef:docDefaults:registry:)``
/// implements leaf-wins inheritance.
///
/// One shared bag across every ``StyleFamily`` rather than a
/// family-specific type: a table or list style setting `isBold`/
/// `alignment` is exactly as meaningful as a paragraph style doing so
/// (LO/Word table and list styles carry paragraph+character properties
/// too), and a single type keeps ``StyleRegistry/resolve`` from needing
/// a family-keyed switch.
public struct StyleProperties: Codable, Sendable, Hashable {
    // Character-level
    public var isBold: Bool?
    public var isItalic: Bool?
    public var isUnderline: Bool?
    public var isStrikethrough: Bool?
    public var textColorHex: ColorRef?
    public var fontFamily: String?
    public var fontSizePt: Double?
    // Paragraph-level
    public var alignment: StyleAlignment?
    public var lineSpacing: Double?
    public var spaceBeforePt: Double?
    public var spaceAfterPt: Double?
    public var indentLeadingPt: Double?

    public init(
        isBold: Bool? = nil,
        isItalic: Bool? = nil,
        isUnderline: Bool? = nil,
        isStrikethrough: Bool? = nil,
        textColorHex: ColorRef? = nil,
        fontFamily: String? = nil,
        fontSizePt: Double? = nil,
        alignment: StyleAlignment? = nil,
        lineSpacing: Double? = nil,
        spaceBeforePt: Double? = nil,
        spaceAfterPt: Double? = nil,
        indentLeadingPt: Double? = nil
    ) {
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderline = isUnderline
        self.isStrikethrough = isStrikethrough
        self.textColorHex = textColorHex
        self.fontFamily = fontFamily
        self.fontSizePt = fontSizePt
        self.alignment = alignment
        self.lineSpacing = lineSpacing
        self.spaceBeforePt = spaceBeforePt
        self.spaceAfterPt = spaceAfterPt
        self.indentLeadingPt = indentLeadingPt
    }

    /// True when every field is `nil` - composing this overlay is a no-op.
    public var isEmpty: Bool { self == StyleProperties() }

    /// `base` with every non-nil field of this overlay substituted in.
    /// Fields left `nil` here pass `base`'s value through unchanged -
    /// the exact contract of `SheetCellFormatOverlay.applied(over:)`,
    /// generalized to a same-shaped base instead of a distinct
    /// non-optional type.
    public func applied(over base: StyleProperties) -> StyleProperties {
        var result = base
        if let isBold { result.isBold = isBold }
        if let isItalic { result.isItalic = isItalic }
        if let isUnderline { result.isUnderline = isUnderline }
        if let isStrikethrough { result.isStrikethrough = isStrikethrough }
        if let textColorHex { result.textColorHex = textColorHex }
        if let fontFamily { result.fontFamily = fontFamily }
        if let fontSizePt { result.fontSizePt = fontSizePt }
        if let alignment { result.alignment = alignment }
        if let lineSpacing { result.lineSpacing = lineSpacing }
        if let spaceBeforePt { result.spaceBeforePt = spaceBeforePt }
        if let spaceAfterPt { result.spaceAfterPt = spaceAfterPt }
        if let indentLeadingPt { result.indentLeadingPt = indentLeadingPt }
        return result
    }
}

/// The fully-resolved property set at one document point (a run inside
/// a paragraph). Same shape as ``StyleProperties`` - resolution is
/// nothing more than repeated overlay application - kept as a distinct
/// name because callers read `ResolvedStyle` as "this point's final
/// presentation," not "one style's local diff." A field still `nil`
/// here means no layer in the whole walk (docDefaults included) set
/// it; the view's own hard default applies.
public typealias ResolvedStyle = StyleProperties

// MARK: - StyleDefinition

/// One named style: a paragraph/character/table/list preset a block or
/// run can reference by id via `Block.attributes["styleRef"]`.
public struct StyleDefinition: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var family: StyleFamily
    /// The parent style in the inheritance chain. `nil` = no parent;
    /// resolution falls through directly to `docDefaults`. Cycles
    /// (through a chain of `basedOn` ids) are tolerated by
    /// ``StyleRegistry/resolve`` and ``StyleRegistry/deletingStyle``
    /// (fail-soft; see each function's doc comment) rather than
    /// enforced here, since malformed/imported documents can carry one
    /// and this type has no registry context to validate against at
    /// construction time.
    public var basedOn: UUID?
    /// The style a NEW block/run should default to after this one -
    /// e.g. "Heading 1" followed by "Body Text". `nil` = the same
    /// style continues. Purely a UI/editor convenience: `resolve`
    /// never reads it.
    public var next: UUID?
    public var props: StyleProperties

    public init(
        id: UUID = UUID(),
        name: String,
        family: StyleFamily,
        basedOn: UUID? = nil,
        next: UUID? = nil,
        props: StyleProperties = StyleProperties()
    ) {
        self.id = id
        self.name = name
        self.family = family
        self.basedOn = basedOn
        self.next = next
        self.props = props
    }
}

// MARK: - StyleRegistry

/// Pure style resolution and deletion over `DocumentMeta.styles` - peer
/// of `FieldController`/`RevisionController`/`TransformController`/
/// `QueryEngine`: a plain namespace of static functions, no state, no
/// `DocStore` dependency. See the file header for the full design.
public enum StyleRegistry {

    // MARK: Resolution

    /// 4-layer resolution: `docDefaults` -> the paragraph style's own
    /// `basedOn` chain (root-to-leaf) -> the character style's own
    /// `basedOn` chain (root-to-leaf) -> `runAnnotations`. Each layer's
    /// non-nil properties override every layer before it - leaf wins,
    /// and a literal run annotation (`.bold`/`.color(hex:)`/...) always
    /// wins over anything style-derived, being the outermost/most-
    /// specific layer.
    ///
    /// `characterStyleRef`/`paragraphStyleRef` missing from `registry`
    /// (a dangling ref) resolves as an empty chain, not an error -
    /// same fail-soft posture as a `basedOn` cycle (see `chain(from:in:)`).
    public static func resolve(
        runAnnotations: [InlineRun.Annotation] = [],
        characterStyleRef: UUID? = nil,
        paragraphStyleRef: UUID? = nil,
        docDefaults: StyleDefinition? = nil,
        registry: [UUID: StyleDefinition]
    ) -> ResolvedStyle {
        var resolved = ResolvedStyle()
        if let docDefaults {
            resolved = docDefaults.props.applied(over: resolved)
        }
        for style in chain(from: paragraphStyleRef, in: registry) {
            resolved = style.props.applied(over: resolved)
        }
        for style in chain(from: characterStyleRef, in: registry) {
            resolved = style.props.applied(over: resolved)
        }
        resolved = runOverlay(runAnnotations).applied(over: resolved)
        return resolved
    }

    /// `styleID`'s `basedOn` chain, root (most distant ancestor) first
    /// and `styleID` itself last, so a caller folding left-to-right
    /// with `applied(over:)` naturally gets leaf-wins. A ref absent
    /// from `registry` (including `styleID == nil`) returns `[]`.
    ///
    /// Cycle-guarded: if walking `basedOn` revisits a style id already
    /// seen in THIS walk, the walk stops there without including that
    /// repeat - the last style collected is treated as if its own
    /// `basedOn` were nil, keeping whatever ancestors were already
    /// gathered before the repeat but growing the chain no further,
    /// rather than looping or throwing. Malformed/imported documents
    /// can carry a `basedOn` cycle; this is the documented fallback,
    /// not a bug.
    ///
    /// Internal (not `private`) so `TocController` (P2-C item 2.5) can
    /// reuse this exact walk to find a heading-family ancestor in a
    /// block's style chain, rather than reimplementing the `basedOn`
    /// walk + cycle guard a second time - the design contract's
    /// explicit instruction. No behavior change from widening alone.
    static func chain(from styleID: UUID?, in registry: [UUID: StyleDefinition]) -> [StyleDefinition] {
        var result: [StyleDefinition] = []
        var seen = Set<UUID>()
        var current = styleID
        while let id = current, let style = registry[id] {
            guard !seen.contains(id) else { break }
            seen.insert(id)
            result.append(style)
            current = style.basedOn
        }
        // Collected leaf-to-root; flip in place to root-to-leaf (`reversed()`
        // returns a `ReversedCollection`, not `[StyleDefinition]`, so this
        // mutating reverse is the direct way back to the declared return type).
        result.reverse()
        return result
    }

    /// Translates the literal annotations on a run into a
    /// `StyleProperties` overlay. Only the annotations with a direct
    /// style-property analog participate (`bold`/`italic`/`underline`/
    /// `strikethrough`/`color(hex:)`); `code`/`subscript`/`superscript`/
    /// `link`/`noteRef` mark structure or navigation, not presentation
    /// a style resolves, so they're left out rather than forced into
    /// an ill-fitting field.
    private static func runOverlay(_ annotations: [InlineRun.Annotation]) -> StyleProperties {
        var overlay = StyleProperties()
        for annotation in annotations {
            switch annotation {
            case .bold: overlay.isBold = true
            case .italic: overlay.isItalic = true
            case .underline: overlay.isUnderline = true
            case .strikethrough: overlay.isStrikethrough = true
            case .color(let hex): overlay.textColorHex = .literal(hex)
            case .code, .subscript, .superscript, .link, .noteRef:
                break
            }
        }
        return overlay
    }

    // MARK: Deletion

    /// Removes `id` from `registry` and rebinds every OTHER style whose
    /// `basedOn` pointed at it to `id`'s own `basedOn` (its parent) -
    /// "rebinds to parent, never dangles". If the deleted style was a
    /// root (`basedOn == nil`), its children become new roots rather
    /// than dangling. `next` references are left untouched (out of
    /// scope - only `basedOn` participates in resolution's inheritance
    /// walk, so only `basedOn` needs a no-dangling guarantee). A no-op
    /// if `id` isn't present.
    public static func deletingStyle(_ id: UUID, from registry: [UUID: StyleDefinition]) -> [UUID: StyleDefinition] {
        guard let removed = registry[id] else { return registry }
        var result = registry
        result.removeValue(forKey: id)
        for (childID, child) in result where child.basedOn == id {
            var rebased = child
            rebased.basedOn = removed.basedOn
            result[childID] = rebased
        }
        return result
    }
}

// MARK: - Block + StyleRef

extension Block {
    /// The style this block (or, for run-level resolution, its
    /// containing paragraph) uses - see file header. A plain UUID
    /// string, unlike `.shape`/`.frame`/`.chart`/`.field`/`.media`
    /// (which each nest a whole encoded JSON object): a style
    /// reference is just an id, nothing to encode beyond its string
    /// form. Not gated to one `BlockType` the way those bridges are -
    /// a style can apply to any block that carries prose.
    public var styleRef: UUID? {
        get {
            attributes["styleRef"]?.stringValue.flatMap(UUID.init(uuidString:))
        }
        set {
            guard let newValue else {
                attributes.removeValue(forKey: "styleRef")
                return
            }
            attributes["styleRef"] = .string(newValue.uuidString)
        }
    }
}
