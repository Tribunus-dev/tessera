import Foundation

// MARK: - SlideLayout

/// The presentation layout for a single slide. A lightweight hint
/// that drives the canvas chrome (title sizing, content framing,
/// image placement). v1 only distinguishes structural layouts;
/// master layouts, transitions, and animations are punted
/// (see the slides design doc, Punted section).
public enum SlideLayout: String, Codable, Sendable, Hashable, CaseIterable {
    case title
    case titleAndContent
    case image
    case blank

    public var displayName: String {
        switch self {
        case .title: return "Title"
        case .titleAndContent: return "Title and Content"
        case .image: return "Image"
        case .blank: return "Blank"
        }
    }
}

// MARK: - Slide

/// A lightweight, read-only view over one slide slice of a
/// ``SlideDeck``. The deck is the durable `graph_entity` row; the
/// slide is derived from it on demand (no separate row). The
/// deck's `body` holds the canonical `DocumentAST`; each slide's
/// AST is the subset of blocks that belong to that slide.
public struct Slide: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var title: String
    public var body: DocumentAST
    public var index: Int
    public var layout: SlideLayout
    public var notes: String

    public init(
        id: UUID = UUID(),
        title: String = "",
        body: DocumentAST = .empty,
        index: Int = 0,
        layout: SlideLayout = .titleAndContent,
        notes: String = ""
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.index = index
        self.layout = layout
        self.notes = notes
    }

    /// Thumbnail hint: first image block's `source` URL if any,
    /// otherwise nil. The canvas view uses it for the strip
    /// thumbnail when the real image asset isn't cached.
    public var thumbnailHint: String? {
        for id in body.rootChildren {
            guard let block = body.blocks[id], block.type == .image else { continue }
            if let url = block.attributes["source"]?.stringValue, !url.isEmpty {
                return url
            }
        }
        return nil
    }
}

// MARK: - SlideDeck

/// A first-class Material in the Tessera productivity surface — a
/// Keynote/pptx-style slide deck stored as `graph_entity` rows with
/// `entity_type = 'document'` and `subtype = 'slide'`, matching the
/// universal "one row per deck" pattern (see
/// `docs/tessera-data-layer-design.md` §3 and the slides design doc).
/// The `body` column carries the serialized `SlideDeck` JSON (whose
/// `body` field is the canonical `DocumentAST`); `label` is the
/// display title.
///
/// The deck owns the canonical AST. Each slide is a *logical slice*
/// over a contiguous range of `body.rootChildren` (spec §4 / SDL
/// §12.12: "A slide deck is a DocumentAST whose rootChildren are
/// slide sections; each slide is a toggle or a group of heading +
/// paragraph + image blocks"). In v1 the slice is one root block
/// per slide (the simplest mapping that stays valid when the user
/// edits slides via `TesseraEditorView` — every root child is one
/// slide, every new root child is a new slide). The slide's layout
/// and notes are stored in `slideMeta` so they round-trip without
/// polluting the block attributes.
///
/// Slide decks ride the same constitutional-receipt backbone as
/// every other material: every mutation produces a signed receipt.
/// ``SlideStore`` is the seam that enforces that invariant for the
/// slide-specific mutation vocabulary (slide insert / delete / move /
/// duplicate / layout, archive, trash, favorite, tag, link, import).
///
/// The struct is self-contained: no data-layer imports, no
/// framework imports beyond `Foundation`.
public struct SlideDeck: Codable, Sendable, Identifiable, Hashable {

    public let id: UUID
    public var title: String
    public var body: DocumentAST
    /// Per-slide metadata keyed by the slide's root block UUID.
    /// When a root child has no entry the defaults from
    /// ``SlideMeta/default`` apply.
    public var slideMeta: [String: SlideMeta]
    /// Nil (the implicit default) means no master pages defined - read
    /// through `effectiveMasterPages` (SlideMasterPage.swift), not
    /// this field directly.
    public var masterPages: [String: SlideMasterPage]?
    /// Nil (the implicit default) means no comments. Slides have no
    /// block tree to anchor a `.comment` block to the way Writer does,
    /// so slide comments live in this flat list instead, each
    /// anchored via `CommentAnchor.slide`.
    public var commentThreads: [CommentThread]?
    /// Nil (the implicit default) means no custom shows defined (P2
    /// item 2.10, data only - no UI this wave). Read through
    /// ``effectiveCustomShows``, not this field directly: deleting a
    /// slide does NOT touch this stored list (a custom show naming a
    /// since-deleted slide is not itself an edit to the show), only
    /// the read-through view prunes the dangling id.
    public var customShows: [CustomShow]?
    public var isArchived: Bool
    public var isTrashed: Bool
    public var isFavorite: Bool
    public var tags: [String]
    public var linkedEntityIDs: [UUID]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "",
        body: DocumentAST = .empty,
        slideMeta: [String: SlideMeta] = [:],
        isArchived: Bool = false,
        isTrashed: Bool = false,
        isFavorite: Bool = false,
        tags: [String] = [],
        linkedEntityIDs: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.slideMeta = slideMeta
        self.isArchived = isArchived
        self.isTrashed = isTrashed
        self.isFavorite = isFavorite
        self.tags = Self.normalizeTags(tags)
        self.linkedEntityIDs = linkedEntityIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Constants

    public static let entityType = "document"
    public static let subtype = "slide"

    public var subtypeString: String { Self.subtype }

    // MARK: - Display

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let first = SlideDeck.firstHeadingText(in: body), !first.isEmpty {
            return first
        }
        return "Untitled"
    }

    public func snippet(maxLength: Int = 200) -> String {
        SlideDeck.plainTextSnippet(from: body, maxLength: maxLength)
    }

    public var wordCount: Int {
        SlideDeck.wordCount(of: body)
    }

    // MARK: - Slide slicing

    /// Number of slides. One root child = one slide; empty deck = 0.
    public var slideCount: Int { body.rootChildren.count }

    /// All slides as ``Slide`` views. Each slide's body is a
    /// single-root AST containing the deck's root block at `index`.
    public var slides: [Slide] {
        enumeratedSlides()
    }

    public func enumeratedSlides() -> [Slide] {
        var out: [Slide] = []
        out.reserveCapacity(body.rootChildren.count)
        for (i, rootID) in body.rootChildren.enumerated() {
            guard let block = body.blocks[rootID] else { continue }
            let meta = slideMeta[rootID.uuidString] ?? .default
            // Build a single-block AST for the slide slice. Include
            // any nested children (toggle blocks that group a
            // heading + paragraph + image) in the slice's block map
            // so the canvas renderer sees the full subtree.
            var sliceBlocks: [UUID: Block] = [:]
            collectBlocks(blockID: rootID, from: body, into: &sliceBlocks)
            let sliceAST = DocumentAST(blocks: sliceBlocks, rootChildren: [rootID])
            let title = SlideDeck.titleOfSlice(block: block, ast: body) ?? "Slide \(i + 1)"
            out.append(Slide(
                id: rootID,
                title: title,
                body: sliceAST,
                index: i,
                layout: meta.layout,
                notes: meta.notes
            ))
        }
        return out
    }

    /// The ``Slide`` at `index`, or nil when out of range.
    public func slide(at index: Int) -> Slide? {
        guard index >= 0, index < body.rootChildren.count else { return nil }
        return enumeratedSlides()[index]
    }

    public func slide(id: UUID) -> Slide? {
        guard let idx = body.rootChildren.firstIndex(of: id) else { return nil }
        return slide(at: idx)
    }

    // MARK: - Custom shows (P2 item 2.10)

    /// `customShows ?? []`, matching `effectiveCommentThreads`/
    /// `effectiveMasterPages`'s "nil means none" convention, PLUS
    /// pruning: every ``CustomShow/slideIDs`` entry that no longer
    /// names a live slide (`body.rootChildren`) is dropped from the
    /// returned view. The STORED `customShows` list is never touched
    /// by this - a slide deletion is a mutation of `body`/`slideMeta`
    /// only (see ``SlideStore/deleteSlide(at:for:)``), never of
    /// `customShows`, so the show's membership/name/order survive a
    /// delete-then-undo (or a delete of an unrelated slide) intact;
    /// only THIS read-through view ever reflects the pruned state.
    public var effectiveCustomShows: [CustomShow] {
        guard let shows = customShows else { return [] }
        let liveIDs = Set(body.rootChildren)
        return shows.map { show in
            var pruned = show
            pruned.slideIDs = show.slideIDs.filter { liveIDs.contains($0) }
            return pruned
        }
    }

    /// A copy with `show` appended.
    public func addingCustomShow(_ show: CustomShow) -> SlideDeck {
        var updated = self
        updated.customShows = (customShows ?? []) + [show]
        return updated
    }

    /// A copy with the show matching `show.id` replaced. No-op (same
    /// array) if no show with that id exists.
    public func replacingCustomShow(_ show: CustomShow) -> SlideDeck {
        var updated = self
        updated.customShows = (customShows ?? []).map { $0.id == show.id ? show : $0 }
        return updated
    }

    /// A copy with the show matching `id` removed. No-op (same array)
    /// if no show with that id exists.
    public func removingCustomShow(id: UUID) -> SlideDeck {
        var updated = self
        updated.customShows = (customShows ?? []).filter { $0.id != id }
        return updated
    }

    // MARK: - Slide factory

    /// Create a deck with a single blank title slide.
    public static func makeBlank(title: String = "Untitled") -> SlideDeck {
        let deck = makeEmpty(title: title)
        return deck.insertingSlide(at: 0, layout: .title)
    }

    public static func makeEmpty(title: String = "") -> SlideDeck {
        SlideDeck(title: title, body: .empty)
    }

    /// Return a copy of the deck with a new slide at `index`.
    /// Blocks are empty placeholders appropriate to the layout.
    public func insertingSlide(
        at index: Int,
        layout: SlideLayout = .titleAndContent,
        title overrideTitle: String? = nil
    ) -> SlideDeck {
        var copy = self
        let clamped = max(0, min(index, copy.body.rootChildren.count))
        let blockID = UUID()
        let titleText = overrideTitle ?? "Slide \(clamped + 1)"
        let block: Block
        switch layout {
        case .title:
            block = Block(
                id: blockID, type: .heading,
                attributes: ["level": .number(1)],
                content: [InlineRun(text: titleText)])
        case .titleAndContent:
            block = Block(
                id: blockID, type: .toggle,
                attributes: ["expanded": .bool(true)],
                children: [])
            // Populate the toggle with a heading + paragraph so the
            // grouped-blocks slide model (spec §4) has content.
            let h = Block(id: UUID(), type: .heading,
                          attributes: ["level": .number(1)],
                          content: [InlineRun(text: titleText)])
            let p = Block(id: UUID(), type: .paragraph, content: [])
            copy.body.blocks[h.id] = h
            copy.body.blocks[p.id] = p
            var b = block
            b.children = [h.id, p.id]
            copy.body.blocks[blockID] = b
            copy.body.rootChildren.insert(blockID, at: clamped)
            copy.slideMeta[blockID.uuidString] = SlideMeta(layout: layout)
            return copy
        case .image:
            block = Block(
                id: blockID, type: .image,
                attributes: ["source": .string(""), "alt": .string(titleText)])
        case .blank:
            block = Block(id: blockID, type: .paragraph, content: [])
        }
        copy.body.blocks[blockID] = block
        copy.body.rootChildren.insert(blockID, at: clamped)
        copy.slideMeta[blockID.uuidString] = SlideMeta(layout: layout)
        return copy
    }

    // MARK: - Tag normalization

    public static func normalizeTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in tags {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted { out.append(trimmed) }
        }
        return out
    }

    // MARK: - Plain text + heading extraction

    public static func firstHeadingText(in ast: DocumentAST) -> String? {
        for id in ast.rootChildren {
            guard let block = ast.blocks[id] else { continue }
            if block.type == .heading {
                let text = block.content.map { $0.text }.joined()
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
            if block.type == .toggle {
                for child in block.children {
                    guard let b = ast.blocks[child], b.type == .heading else { continue }
                    let text = b.content.map { $0.text }.joined()
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { return t }
                }
            }
        }
        return nil
    }

    public static func plainText(of ast: DocumentAST) -> String {
        var out: [String] = []
        for id in ast.rootChildren { appendPlainText(blockID: id, ast: ast, into: &out) }
        return out.joined(separator: "\n")
    }

    private static func appendPlainText(blockID: UUID, ast: DocumentAST, into out: inout [String]) {
        guard let block = ast.blocks[blockID] else { return }
        switch block.type {
        case .paragraph, .heading, .quote, .listItem, .tableCell:
            let text = block.content.map { $0.text }.joined()
            if !text.isEmpty { out.append(text) }
        case .codeBlock:
            let text = block.content.map { $0.text }.joined()
            if !text.isEmpty { out.append(text) }
        case .callout:
            var line = ""
            if let emoji = block.attributes["emoji"]?.stringValue, !emoji.isEmpty { line += emoji + " " }
            line += block.content.map { $0.text }.joined()
            if !line.isEmpty { out.append(line) }
        case .list:
            for child in block.children { appendPlainText(blockID: child, ast: ast, into: &out) }
        case .table:
            for child in block.children { appendPlainText(blockID: child, ast: ast, into: &out) }
        case .shapeGroup, .section, .frame:
            for child in block.children { appendPlainText(blockID: child, ast: ast, into: &out) }
        case .shape:
            if let text = block.shape?.text?.plainText, !text.isEmpty { out.append(text) }
        case .toggle, .image, .divider, .equation:
            // Toggle: walk children (heading + paragraph + image group)
            for child in block.children { appendPlainText(blockID: child, ast: ast, into: &out) }
            if block.type != .toggle { break }
            return
        case .comment, .trackInsertion, .trackDeletion:
            // Phase 7: comments and track changes — skip from slide plain-text export.
            break
        @unknown default:
            // Future block types: skip gracefully.
            break
        }
        for child in block.children where block.type != .list && block.type != .table && block.type != .toggle
            && block.type != .shapeGroup && block.type != .section && block.type != .frame {
            appendPlainText(blockID: child, ast: ast, into: &out)
        }
    }

    public static func plainTextSnippet(from ast: DocumentAST, maxLength: Int = 200) -> String {
        let raw = plainText(of: ast)
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }.joined(separator: " ")
        if collapsed.count <= maxLength { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: maxLength)
        return String(collapsed[..<end]) + "…"
    }

    public static func wordCount(of ast: DocumentAST) -> Int {
        let text = plainText(of: ast)
        guard !text.isEmpty else { return 0 }
        return text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.count
    }

    // MARK: - Slice helpers

    private static func titleOfSlice(block: Block, ast: DocumentAST) -> String? {
        if block.type == .heading {
            let t = block.content.map { $0.text }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        if block.type == .toggle {
            for child in block.children {
                guard let b = ast.blocks[child], b.type == .heading else { continue }
                let t = b.content.map { $0.text }.joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    private func collectBlocks(blockID: UUID, from ast: DocumentAST, into out: inout [UUID: Block]) {
        guard let block = ast.blocks[blockID], out[blockID] == nil else { return }
        out[blockID] = block
        for child in block.children { collectBlocks(blockID: child, from: ast, into: &out) }
    }
}

// MARK: - SlideMeta

/// Per-slide presentation metadata keyed by the slide's root UUID
/// string in ``SlideDeck/slideMeta``. Stored alongside the block AST
/// so that layout + notes survive importer round-trips even when the
/// underlying blocks only carry content.
public struct SlideMeta: Codable, Sendable, Hashable {
    public var layout: SlideLayout
    public var notes: String
    /// Which of the deck's `effectiveMasterPages` this slide paints
    /// behind its content. `nil` = no master (the renderer's own
    /// default background) - see `SlideDeck.masterPage(forSlideAt:)`.
    public var masterPageID: UUID?
    /// The `TransitionSpec.id` this slide transitions in with, or
    /// `nil` for no transition. Must resolve in `TransitionCatalog`
    /// when non-nil - `TransitionStore.setSlideTransition` validates
    /// this before ever assigning it.
    public var transitionID: String?
    /// The slide's flat, play-order-flattened animation effect list
    /// (P1 1.20, wired P2-0) - the EXISTING, fully-tested-in-isolation
    /// `AnimationEffectList` typealias, previously an unreachable
    /// island with no storage field. `nil` means no animations
    /// defined, the same "nil means none" convention every other
    /// optional field in this struct uses - read through
    /// ``effectiveAnimations``, not this field directly.
    ///
    /// ``SMILAnimationTree`` (P2 item 2.1) evolves this IN PLACE per
    /// decision 7 (no versioned implementations): this field stays,
    /// it does not get replaced by ``animationTree``. Custom
    /// `Codable` below (not the synthesized one) keeps the two in
    /// sync on every encode/decode - see that code's own comments.
    public var animations: AnimationEffectList?
    /// The P2 SMIL timing tree ``animations`` is the flattened
    /// projection of. `nil` means the slide has never been touched by
    /// P2 animation code (either no animations at all, or only ever
    /// written by pre-P2 code that only knows the flat field) - read
    /// through ``effectiveAnimationTree``, not this field directly.
    public var animationTree: SMILAnimationTree?

    public init(
        layout: SlideLayout = .titleAndContent,
        notes: String = "",
        masterPageID: UUID? = nil,
        transitionID: String? = nil,
        animations: AnimationEffectList? = nil,
        animationTree: SMILAnimationTree? = nil
    ) {
        self.layout = layout
        self.notes = notes
        self.masterPageID = masterPageID
        self.transitionID = transitionID
        self.animations = animations
        self.animationTree = animationTree
    }

    public static let `default` = SlideMeta(layout: .titleAndContent, notes: "")

    /// Returns a copy with the notes field updated.
    public func copyWith(notes newNotes: String) -> SlideMeta {
        SlideMeta(
            layout: self.layout, notes: newNotes, masterPageID: self.masterPageID,
            transitionID: self.transitionID, animations: self.animations,
            animationTree: self.animationTree)
    }

    /// `animations ?? []` - the "nil means none" read-through every
    /// other Effective* field in this codebase uses (e.g.
    /// `SlideDeck.effectiveCommentThreads`, `SlideMasterPage
    /// .effectiveMasterPages`).
    public var effectiveAnimations: AnimationEffectList {
        animations ?? []
    }

    /// `animationTree`, or - when absent but the flat field carries
    /// something - `SMILAnimationTree(flat: effectiveAnimations)`
    /// lifted on demand. `nil` only when the slide truly has no
    /// animations at all. Every read site that wants the tree
    /// (as opposed to the flat projection `effectiveAnimations`
    /// already serves the agent-context callers) should go through
    /// this, not `animationTree` directly, for the same reason every
    /// other `effective*` accessor in this codebase exists.
    public var effectiveAnimationTree: SMILAnimationTree? {
        if let animationTree { return animationTree }
        guard let animations else { return nil }
        return SMILAnimationTree(flat: animations)
    }

    // MARK: - Codable (custom: keeps `animations`/`animationTree` in
    // sync per decision 7 - encode ALWAYS writes both the tree and
    // its flattened projection when a tree is present; decode PREFERS
    // the tree when the wire data has one, else lifts it from the
    // flat field via `SMILAnimationTree(flat:)` - so `animationTree`
    // is never silently stale relative to `animations` after a decode,
    // no matter which fields a hand-built fixture or a pre-P2 writer
    // actually populated.)

    private enum CodingKeys: String, CodingKey {
        case layout, notes, masterPageID, transitionID, animations, animationTree
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layout = try container.decodeIfPresent(SlideLayout.self, forKey: .layout) ?? .titleAndContent
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        masterPageID = try container.decodeIfPresent(UUID.self, forKey: .masterPageID)
        transitionID = try container.decodeIfPresent(String.self, forKey: .transitionID)
        let decodedFlat = try container.decodeIfPresent(AnimationEffectList.self, forKey: .animations)
        if let tree = try container.decodeIfPresent(SMILAnimationTree.self, forKey: .animationTree) {
            animationTree = tree
            animations = tree.flattened()
        } else if let decodedFlat {
            animationTree = SMILAnimationTree(flat: decodedFlat)
            animations = decodedFlat
        } else {
            animationTree = nil
            animations = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layout, forKey: .layout)
        try container.encode(notes, forKey: .notes)
        try container.encodeIfPresent(masterPageID, forKey: .masterPageID)
        try container.encodeIfPresent(transitionID, forKey: .transitionID)
        if let animationTree {
            try container.encode(animationTree, forKey: .animationTree)
            try container.encode(animationTree.flattened(), forKey: .animations)
        } else {
            try container.encodeIfPresent(animations, forKey: .animations)
        }
    }
}

// MARK: - CustomShow

/// One named custom show (P2 item 2.10, data only - no UI this wave):
/// an ordered, possibly-non-contiguous, possibly-repeating subset of
/// the deck's slides that plays as its own presentation sequence.
/// OOXML `p:custShowLst > p:custShow@name,@id > p:sldLst` of `r:id`
/// refs; ODF `presentation:show{name, pages}` (a comma list of page
/// NAMES) inside `presentation:settings` - see `LOBridgeDeckIO`'s
/// fodp import/export for the mapping. Exactly the 3 fields the
/// design contract names; no UI-only fields (color, icon, ...) since
/// this item is explicitly data-only.
public struct CustomShow: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    /// Slide root-block ids, in play order for this show. May repeat
    /// an id (LO/PowerPoint both allow a slide to appear more than
    /// once in one custom show) and need not be contiguous or in deck
    /// order. Read through `SlideDeck.effectiveCustomShows`, not this
    /// property directly, to see the live (dangling-id-pruned) view.
    public var slideIDs: [UUID]

    public init(id: UUID = UUID(), name: String, slideIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.slideIDs = slideIDs
    }
}

// MARK: - JSON helpers

extension SlideDeck {
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func from(jsonData: Data) throws -> SlideDeck {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SlideDeck.self, from: jsonData)
    }

    public func jsonDataString() throws -> String {
        let data = try jsonData()
        guard let s = String(data: data, encoding: .utf8) else {
            throw SlideStoreError.invalidBody(reason: "encoded JSON is not UTF-8")
        }
        return s
    }

    public static func from(jsonDataString: String) throws -> SlideDeck {
        guard let data = jsonDataString.data(using: .utf8) else {
            throw SlideStoreError.invalidBody(reason: "body is not valid UTF-8")
        }
        return try from(jsonData: data)
    }
}
