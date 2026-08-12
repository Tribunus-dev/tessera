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
        for child in block.children where block.type != .list && block.type != .table && block.type != .toggle {
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

    public init(layout: SlideLayout = .titleAndContent, notes: String = "") {
        self.layout = layout
        self.notes = notes
    }

    public static let `default` = SlideMeta(layout: .titleAndContent, notes: "")

    /// Returns a copy with the notes field updated.
    public func copyWith(notes newNotes: String) -> SlideMeta {
        SlideMeta(layout: self.layout, notes: newNotes)
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
