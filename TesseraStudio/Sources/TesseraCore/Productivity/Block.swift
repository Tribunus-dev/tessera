import Foundation
import CryptoKit

// MARK: - AnyCodable

/// Type-erased JSON value for block attributes and document meta.
///
/// This is a type alias for ``JSONValue`` (defined in `TesseraTool.swift`):
/// `JSONValue` is already `Codable, Sendable, Equatable, Hashable` and
/// covers every value the spec's block attributes need (string, number,
/// bool, array, object, null). The spec writes `AnyCodable` to match
/// community conventions (FlightSchool's `AnyCodable` package), so we
/// expose the alias at the productivity surface to keep the API name
/// recognisable while reusing the existing implementation.
public typealias AnyCodable = JSONValue

// MARK: - BlockType

/// The set of block types the editor understands. Each case carries
/// the data shape its block stores in `attributes` / `content` /
/// `children`. The spec's section 4.1 is the source of truth.
public enum BlockType: String, Codable, Sendable, Hashable, CaseIterable {
    /// Headings h1-h6. `attributes["level"]` is `AnyCodable.number(1..6)`.
    case heading
    /// Plain prose. `content` holds the inline runs.
    case paragraph
    /// List container. `attributes["style"]` is `"unordered" | "ordered" | "task"`.
    /// `attributes["items"]` is `AnyCodable.array` of block IDs (deprecated in
    /// favour of `children` -- see spec §4.1; we keep the field for round-trip
    /// compatibility with v0 imports).
    case list
    /// A single item in a list. `content` holds the inline runs.
    case listItem
    /// Table. `attributes["rows"]`/`attributes["cols"]` give the grid
    /// size; `children` is a FLAT, row-major list of `.tableCell`
    /// blocks (no per-cell row/col attribute) - see ``TableLayout``,
    /// which resolves that flat list into actual grid positions and is
    /// what any code walking a table's cells should use rather than
    /// re-deriving `row * cols + col` by hand.
    case table
    /// One cell in a table. `content` holds the inline runs, unless
    /// `children` is non-empty, in which case those nested blocks
    /// (paragraphs, lists, even a nested table) are the cell's real
    /// content instead - see `DocumentExporter.renderTableCellContent`.
    /// `rowSpan`/`colSpan` (``Block/rowSpan``/``Block/colSpan``) merge
    /// this cell across multiple grid slots; absent means 1x1.
    case tableCell
    /// Image. `attributes["source"]` is the URL, `attributes["alt"]` the
    /// accessibility text, `width` / `height` are optional pixel hints.
    case image
    /// Code block. `attributes["language"]` is the optional language tag;
    /// `content` is a single run whose `text` holds the source.
    case codeBlock
    /// Callout (Notion-style). `attributes["emoji"]` and
    /// `attributes["color"]` are optional styling.
    case callout
    /// Horizontal divider. `content` is empty.
    case divider
    /// Block quote. `content` holds the inline runs; `attributes["cite"]`
    /// is the optional citation source.
    case quote
    /// Collapsible section. `attributes["expanded"]` is the bool state;
    /// `children` is the ordered list of contained block IDs.
    case toggle
    /// Display equation. `attributes["latex"]` is the LaTeX source.
    case equation
    /// An inline comment anchored to a text range. `attributes["anchorBlockID"]`
    /// is the block being commented on; `attributes["anchorRangeStart"]` /
    /// `attributes["anchorRangeEnd"]` mark the character range; `attributes["author"]`
    /// and `attributes["timestamp"]` track the source. `children` holds reply blocks.
    case comment
    /// A tracked insertion. `attributes["author"]` and `attributes["timestamp"]`
    /// track who inserted the text. The inserted text lives in `content`.
    case trackInsertion
    /// A tracked deletion. `attributes["author"]` and `attributes["timestamp"]`
    /// track who deleted the text. The deleted text (shown struck-through) is in `content`.
    case trackDeletion
    /// A single vector shape on a Draw/Impress canvas. `attributes["shape"]`
    /// holds the JSON-encoded ``Shape`` (geometry, fill, stroke, text) - see
    /// ``Block/shape``. A leaf: `content` and `children` are unused.
    case shape
    /// A group of `.shape` (or nested `.shapeGroup`) blocks. `children`
    /// holds the ordered member block IDs, matching `.list`/`.toggle`'s
    /// container convention. Carries no geometry of its own at P0 - group
    /// bounds are derived from members, not stored.
    case shapeGroup
    /// A multi-column region or page/section break, carrying the
    /// contained blocks as `children`. `attributes["sectionRef"]` points
    /// into ``DocumentMeta/sections`` - see ``SectionStore``. Two section
    /// blocks can share one `DocumentSection` identity (a section that continues
    /// across a page break).
    case section
    /// An anchored, flowed-content container (a text box) - distinct
    /// from `.image` (a single picture) and `.shape` (a single vector
    /// primitive with no flowed content): a frame holds arbitrary child
    /// blocks. `attributes["frame"]` holds the JSON-encoded
    /// ``FrameProperties`` (position, size, anchor) - see ``Block/frame``.
    case frame
    /// A chart on a Calc/Impress canvas. `attributes["chart"]` holds
    /// the JSON-encoded ``ChartSpec`` (kind, series, axes, legend) -
    /// see ``Block/chart``. A leaf: `content` and `children` are unused.
    case chart
    /// A field (page number, date, ref, sequence, ...) in a Writer
    /// document. `attributes["field"]` holds the JSON-encoded
    /// ``FieldSpec`` (kind + dirty flag) - see ``Block/field``.
    /// `content` holds the CACHED RESOLVED text as ordinary
    /// `InlineRun`s, not attributes, so `plainText()`/`DocumentExporter`/
    /// agent context see real text with no field-aware special-casing -
    /// see ``FieldController/refresh(_:in:clock:)``.
    case field
    /// An out-of-flow footnote body in a Writer document. NOT placed
    /// inline in the document's reading flow - it lives registered in
    /// ``DocumentMeta/notes`` keyed by this block's own `id` (the
    /// `headerBlockID`/`footerBlockID` precedent on
    /// ``DocumentPageLayout``, generalized to a dictionary since a
    /// document can have many notes). `content` holds the note's own
    /// text directly, same as `.paragraph`. In-text references point
    /// at this id via ``InlineRun/Annotation/noteRef(_:)`` without
    /// embedding the note. The 1..n number shown to the reader is
    /// DERIVED from reference order, never stored - see
    /// ``DocumentAST/deriveNoteNumbering()``.
    case footnote
    /// An out-of-flow endnote body. Same registry, reference, and
    /// content shape as ``footnote``; endnotes number independently
    /// (their own 1..n sequence, not continuing the footnote sequence).
    case endnote
    /// An audio/video object on an Impress canvas. `attributes["media"]`
    /// holds the JSON-encoded ``MediaBlock`` (kind, source, duration,
    /// poster image, autoplay/loop) - see ``Block/media``. A leaf:
    /// `content` and `children` are unused. The data model carries no
    /// AVFoundation type (not simply Codable/Sendable-friendly);
    /// playback is a view-layer concern that reads this spec.
    case media
    /// A table of contents (item 2.5). `attributes["toc"]` holds the
    /// JSON-encoded `TocSpec` (fromLevel/toLevel/includeOutlineLevels/
    /// hyperlink/extraStyles/tabLeader); `children` are the generated
    /// entry paragraphs (derived-never-stored: regenerated from the
    /// document's own heading-family styles, never hand-edited).
    case toc
}

// MARK: - InlineRun

/// A contiguous run of inline content with a uniform set of
/// annotations (bold / italic / link / ...). The editor renders each
/// run as a single styled span; the agent's mutation API reasons
/// about runs at this granularity.
public struct InlineRun: Codable, Sendable, Hashable {
    /// Inline annotation tags. Some variants carry an associated value
    /// (link URL, color hex); those are encoded as a tagged JSON object
    /// via ``InlineRun/AnnotatedAnnotation`` so the on-disk shape stays
    /// human-readable.
    public enum Annotation: Codable, Sendable, Hashable {
        case bold
        case italic
        case underline
        case strikethrough
        case code
        case `subscript`
        case `superscript`
        case link(URL)
        case color(hex: String)
        /// Points at a `.footnote`/`.endnote` body block's own `id` in
        /// ``DocumentMeta/notes`` - the in-text reference marker. Does
        /// not embed the note; the referenced block carries the actual
        /// text. The displayed number is derived, not carried here -
        /// see ``DocumentAST/deriveNoteNumbering()``.
        case noteRef(UUID)
    }

    public var text: String
    public var annotations: [Annotation]

    public init(text: String, annotations: [Annotation] = []) {
        self.text = text
        self.annotations = annotations
    }
}

// MARK: - Block

/// One block in the document. A block is a leaf or container; the
/// `type` field drives the renderer, the `attributes` field carries
/// the type-specific data, `content` holds the inline runs for leaf
/// blocks (paragraph, listItem, tableCell, codeBlock, quote), and
/// `children` holds the ordered list of child IDs for container
/// blocks (list, toggle, table, callout).
///
/// The flat `[UUID: Block]` map + `rootChildren: [UUID]` ordered list
/// in ``DocumentAST`` is what the spec uses (matching Notion's
/// internal shape). Each block carries a `parentID` for fast upward
/// walks without re-deriving the tree.
public struct Block: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var type: BlockType
    public var attributes: [String: AnyCodable]
    public var content: [InlineRun]
    public var children: [UUID]
    public var parentID: UUID?

    public init(
        id: UUID = UUID(),
        type: BlockType,
        attributes: [String: AnyCodable] = [:],
        content: [InlineRun] = [],
        children: [UUID] = [],
        parentID: UUID? = nil
    ) {
        self.id = id
        self.type = type
        self.attributes = attributes
        self.content = content
        self.children = children
        self.parentID = parentID
    }
}

// MARK: - Block + Shape

extension Block {
    /// Convenience constructor for a `.shape` block.
    public init(shape: Shape, id: UUID = UUID(), parentID: UUID? = nil) {
        self.init(id: id, type: .shape, parentID: parentID)
        self.shape = shape
    }

    /// Reads/writes the block's ``Shape`` via `attributes["shape"]`.
    ///
    /// `Shape` is stored as a nested JSON object rather than flattened
    /// into individual attribute keys, so its own `Codable` conformance
    /// stays the single source of truth for the wire shape - adding a
    /// field to `Shape` doesn't require touching this bridge. Returns
    /// `nil` for non-`.shape` blocks or malformed/missing content;
    /// setting on a non-`.shape` block is a no-op (mirrors the rest of
    /// this file's attribute accessors, which don't validate `type`
    /// either - `.shape` blocks with a missing `attributes["shape"]`
    /// key are treated as "no shape yet", not corrupted data).
    public var shape: Shape? {
        get {
            guard type == .shape, let raw = attributes["shape"] else { return nil }
            guard let data = try? JSONEncoder().encode(raw) else { return nil }
            return try? JSONDecoder().decode(Shape.self, from: data)
        }
        set {
            guard type == .shape else { return }
            guard let newValue else {
                attributes.removeValue(forKey: "shape")
                return
            }
            guard let data = try? JSONEncoder().encode(newValue),
                  let raw = try? JSONDecoder().decode(AnyCodable.self, from: data) else { return }
            attributes["shape"] = raw
        }
    }
}

// MARK: - Block + Frame

extension Block {
    /// Reads/writes the block's ``FrameProperties`` via
    /// `attributes["frame"]`. Same bridge shape as ``Block/shape`` and
    /// for the same reason: `FrameProperties`'s own `Codable`
    /// conformance stays the single source of truth for the wire shape.
    public var frame: FrameProperties? {
        get {
            guard type == .frame, let raw = attributes["frame"] else { return nil }
            guard let data = try? JSONEncoder().encode(raw) else { return nil }
            return try? JSONDecoder().decode(FrameProperties.self, from: data)
        }
        set {
            guard type == .frame else { return }
            guard let newValue else {
                attributes.removeValue(forKey: "frame")
                return
            }
            guard let data = try? JSONEncoder().encode(newValue),
                  let raw = try? JSONDecoder().decode(AnyCodable.self, from: data) else { return }
            attributes["frame"] = raw
        }
    }
}

// MARK: - Block + Chart

extension Block {
    /// Reads/writes the block's ``ChartSpec`` via `attributes["chart"]`.
    /// Same bridge shape as ``Block/shape``/``Block/frame`` and for the
    /// same reason: `ChartSpec`'s own `Codable` conformance stays the
    /// single source of truth for the wire shape.
    public var chart: ChartSpec? {
        get {
            guard type == .chart, let raw = attributes["chart"] else { return nil }
            guard let data = try? JSONEncoder().encode(raw) else { return nil }
            return try? JSONDecoder().decode(ChartSpec.self, from: data)
        }
        set {
            guard type == .chart else { return }
            guard let newValue else {
                attributes.removeValue(forKey: "chart")
                return
            }
            guard let data = try? JSONEncoder().encode(newValue),
                  let raw = try? JSONDecoder().decode(AnyCodable.self, from: data) else { return }
            attributes["chart"] = raw
        }
    }
}

// MARK: - Block + Field

extension Block {
    /// Reads/writes the block's ``FieldSpec`` via `attributes["field"]`.
    /// Same bridge shape as ``Block/shape``/``Block/frame``/``Block/chart``
    /// and for the same reason: `FieldSpec`'s own `Codable` conformance
    /// stays the single source of truth for the wire shape. The
    /// RESOLVED text lives in the block's own `content`, not here -
    /// see ``FieldController``.
    public var field: FieldSpec? {
        get {
            guard type == .field, let raw = attributes["field"] else { return nil }
            guard let data = try? JSONEncoder().encode(raw) else { return nil }
            return try? JSONDecoder().decode(FieldSpec.self, from: data)
        }
        set {
            guard type == .field else { return }
            guard let newValue else {
                attributes.removeValue(forKey: "field")
                return
            }
            guard let data = try? JSONEncoder().encode(newValue),
                  let raw = try? JSONDecoder().decode(AnyCodable.self, from: data) else { return }
            attributes["field"] = raw
        }
    }
}

// MARK: - Block + Media

extension Block {
    /// Reads/writes the block's ``MediaBlock`` via `attributes["media"]`.
    /// Same bridge shape as ``Block/shape``/``Block/frame``/``Block/chart``/
    /// ``Block/field`` and for the same reason: `MediaBlock`'s own
    /// `Codable` conformance stays the single source of truth for the
    /// wire shape.
    public var media: MediaBlock? {
        get {
            guard type == .media, let raw = attributes["media"] else { return nil }
            guard let data = try? JSONEncoder().encode(raw) else { return nil }
            return try? JSONDecoder().decode(MediaBlock.self, from: data)
        }
        set {
            guard type == .media else { return }
            guard let newValue else {
                attributes.removeValue(forKey: "media")
                return
            }
            guard let data = try? JSONEncoder().encode(newValue),
                  let raw = try? JSONDecoder().decode(AnyCodable.self, from: data) else { return }
            attributes["media"] = raw
        }
    }
}

// MARK: - DocumentPageLayout

/// Page layout for a document. Stored in ``DocumentAST/meta``.
public struct DocumentPageLayout: Codable, Sendable, Hashable {
    /// Page width in points. A4 default = 595pt.
    public var pageWidth: Double
    /// Page height in points. A4 default = 842pt.
    public var pageHeight: Double
    /// Margins in points.
    public var marginTop: Double
    public var marginBottom: Double
    public var marginLeft: Double
    public var marginRight: Double
    /// Number of text columns (1 = single column).
    public var columnCount: Int
    /// Space between columns in points.
    public var columnGap: Double
    /// Page background color as hex string (e.g. "#FFFFFF").
    public var pageColor: String
    /// Header block ID (stored in `blocks`).
    public var headerBlockID: UUID?
    /// Footer block ID (stored in `blocks`).
    public var footerBlockID: UUID?

    public init(
        pageWidth: Double = 595,
        pageHeight: Double = 842,
        marginTop: Double = 72,
        marginBottom: Double = 72,
        marginLeft: Double = 72,
        marginRight: Double = 72,
        columnCount: Int = 1,
        columnGap: Double = 18,
        pageColor: String = "#FFFFFF",
        headerBlockID: UUID? = nil,
        footerBlockID: UUID? = nil
    ) {
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
        self.marginTop = marginTop
        self.marginBottom = marginBottom
        self.marginLeft = marginLeft
        self.marginRight = marginRight
        self.columnCount = columnCount
        self.columnGap = columnGap
        self.pageColor = pageColor
        self.headerBlockID = headerBlockID
        self.footerBlockID = footerBlockID
    }

    /// Returns the content width (page width minus left and right margins).
    public var contentWidth: Double {
        max(1, pageWidth - marginLeft - marginRight)
    }
}

// MARK: - DocumentMeta

/// Top-level document metadata. Stored as a field in ``DocumentAST``.
public struct DocumentMeta: Sendable, Hashable {
    public var pageLayout: DocumentPageLayout
    /// Section identities referenced by `.section` blocks via
    /// `attributes["sectionRef"]` - see ``SectionStore``. Keyed by
    /// section ID.
    public var sections: [UUID: DocumentSection]
    /// Footnote/endnote body blocks (`.footnote`/`.endnote`), keyed
    /// by their own `id` - the `headerBlockID`/`footerBlockID`
    /// precedent on ``DocumentPageLayout``, generalized to a
    /// dictionary since a document can have many notes. In-text
    /// content points into this registry via
    /// ``InlineRun/Annotation/noteRef(_:)``; the displayed 1..n
    /// number is derived from reference order (see
    /// ``DocumentAST/deriveNoteNumbering()``), never stored here.
    public var notes: [UUID: Block]
    /// Paragraph/character/table/list style definitions, keyed by the
    /// style's own id - the `sections` registry precedent, generalized
    /// the same way `notes` was: a document can define many styles, and
    /// `Block.attributes["styleRef"]`/run-level style refs look them up
    /// by id here rather than embedding them. See ``StyleRegistry``.
    public var styles: [UUID: StyleDefinition]

    public init(
        pageLayout: DocumentPageLayout = DocumentPageLayout(),
        sections: [UUID: DocumentSection] = [:],
        notes: [UUID: Block] = [:],
        styles: [UUID: StyleDefinition] = [:]
    ) {
        self.pageLayout = pageLayout
        self.sections = sections
        self.notes = notes
        self.styles = styles
    }
}

extension DocumentMeta: Codable {
    private enum CodingKeys: String, CodingKey {
        case pageLayout
        case sections
        case notes
        case styles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.pageLayout = try container.decode(DocumentPageLayout.self, forKey: .pageLayout)
        // `sections` is new; absent entirely in documents written before
        // BlockType.section existed. Same [String: V] -> [UUID: V]
        // bridge DocumentAST.blocks uses, for the same reason: JSONDecoder
        // doesn't decode a UUID-keyed Dictionary from a JSON object.
        let rawSections = try container.decodeIfPresent([String: DocumentSection].self, forKey: .sections) ?? [:]
        var sections: [UUID: DocumentSection] = [:]
        for (key, value) in rawSections {
            guard let uuid = UUID(uuidString: key) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .sections,
                    in: container,
                    debugDescription: "invalid UUID '\(key)' as section key"
                )
            }
            sections[uuid] = value
        }
        self.sections = sections
        // `notes` is new; absent entirely in documents written before
        // BlockType.footnote/.endnote existed. Same bridge as `sections`,
        // for the same reason.
        let rawNotes = try container.decodeIfPresent([String: Block].self, forKey: .notes) ?? [:]
        var notes: [UUID: Block] = [:]
        for (key, value) in rawNotes {
            guard let uuid = UUID(uuidString: key) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .notes,
                    in: container,
                    debugDescription: "invalid UUID '\(key)' as note key"
                )
            }
            notes[uuid] = value
        }
        self.notes = notes
        // `styles` is new; absent entirely in documents written before
        // StyleRegistry existed. Same bridge as `sections`/`notes`, for
        // the same reason.
        let rawStyles = try container.decodeIfPresent([String: StyleDefinition].self, forKey: .styles) ?? [:]
        var styles: [UUID: StyleDefinition] = [:]
        for (key, value) in rawStyles {
            guard let uuid = UUID(uuidString: key) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .styles,
                    in: container,
                    debugDescription: "invalid UUID '\(key)' as style key"
                )
            }
            styles[uuid] = value
        }
        self.styles = styles
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageLayout, forKey: .pageLayout)
        let rawSections = sections.reduce(into: [String: DocumentSection]()) { acc, entry in
            acc[entry.key.uuidString] = entry.value
        }
        try container.encode(rawSections, forKey: .sections)
        let rawNotes = notes.reduce(into: [String: Block]()) { acc, entry in
            acc[entry.key.uuidString] = entry.value
        }
        try container.encode(rawNotes, forKey: .notes)
        let rawStyles = styles.reduce(into: [String: StyleDefinition]()) { acc, entry in
            acc[entry.key.uuidString] = entry.value
        }
        try container.encode(rawStyles, forKey: .styles)
    }
}

// MARK: - DocumentAST

/// The full document model. Stored in the data layer as the `body`
/// JSONB column of a `graph_entity` (entity_type = "document").
/// The `blocks` map gives O(1) lookup; `rootChildren` is the
/// ordered list of top-level block IDs.
public struct DocumentAST: Codable, Sendable, Hashable {
    public var blocks: [UUID: Block]
    public var rootChildren: [UUID]
    /// Document-level metadata (page layout, etc.).
    public var meta: DocumentMeta

    public init(
        blocks: [UUID: Block] = [:],
        rootChildren: [UUID] = [],
        meta: DocumentMeta = DocumentMeta()
    ) {
        self.blocks = blocks
        self.rootChildren = rootChildren
        self.meta = meta
    }

    /// The empty document. Useful as a starting point for new
    /// documents and for tests.
    public static let empty = DocumentAST()

    // MARK: - Page layout helpers

    /// Convenience: access the page layout directly.
    public var pageLayout: DocumentPageLayout {
        get { meta.pageLayout }
        set { meta.pageLayout = newValue }
    }

    /// Returns content width in points.
    public var contentWidth: Double { meta.pageLayout.contentWidth }

    // MARK: - Codable

    /// Custom Codable: Swift's `JSONDecoder` does not decode
    /// `Dictionary<UUID, V>` from a JSON object directly (it
    /// expects an array of [key, value, key, value, ...] pairs).
    /// We use a JSON object with stringified UUID keys for
    /// round-trip-ability with standard JSON tools, and convert
    /// at the boundary.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decode the blocks as [String: Block] and convert to UUID keys.
        let rawBlocks = try container.decode([String: Block].self, forKey: .blocks)
        var blocks: [UUID: Block] = [:]
        for (key, value) in rawBlocks {
            guard let uuid = UUID(uuidString: key) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .blocks,
                    in: container,
                    debugDescription: "invalid UUID '\(key)' as block key"
                )
            }
            blocks[uuid] = value
        }
        self.blocks = blocks
        self.rootChildren = try container.decode([UUID].self, forKey: .rootChildren)
        // meta is optional in old documents; fall back to the default.
        self.meta = try container.decodeIfPresent(DocumentMeta.self, forKey: .meta) ?? DocumentMeta()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Encode as [String: Block] so the JSON shape is an object
        // with stringified UUID keys.
        let rawBlocks = blocks.reduce(into: [String: Block]()) { acc, entry in
            acc[entry.key.uuidString] = entry.value
        }
        try container.encode(rawBlocks, forKey: .blocks)
        try container.encode(rootChildren, forKey: .rootChildren)
        try container.encode(meta, forKey: .meta)
    }

    private enum CodingKeys: String, CodingKey {
        case blocks
        case rootChildren
        case meta
    }

    // MARK: Tree helpers

    /// Children of `parentID` in document order. Returns the root
    /// children when `parentID` is `nil`.
    public func children(of parentID: UUID?) -> [UUID] {
        guard let parentID else { return rootChildren }
        return blocks[parentID]?.children ?? []
    }

    /// `true` if `blockID` is present in the document.
    public func contains(_ blockID: UUID) -> Bool {
        blocks[blockID] != nil
    }

    /// Walks the tree depth-first and returns every block ID, root
    /// first. Includes the root children; the order is stable.
    public func depthFirstOrder() -> [UUID] {
        var out: [UUID] = []
        out.reserveCapacity(blocks.count)
        for root in rootChildren { walk(root, into: &out) }
        return out
    }

    private func walk(_ id: UUID, into out: inout [UUID]) {
        guard let block = blocks[id] else { return }
        out.append(id)
        for child in block.children { walk(child, into: &out) }
    }
}

// MARK: - Note numbering (footnote/endnote)

/// Footnote/endnote reference numbers, derived fresh from document
/// order - never persisted anywhere (not on the block, not in
/// `DocumentMeta`). Footnotes and endnotes number independently:
/// each is its own 1-based sequence, matching standard word-processor
/// convention.
public struct NoteNumbering: Sendable, Equatable {
    public var footnotes: [UUID: Int]
    public var endnotes: [UUID: Int]

    public init(footnotes: [UUID: Int] = [:], endnotes: [UUID: Int] = [:]) {
        self.footnotes = footnotes
        self.endnotes = endnotes
    }
}

extension DocumentAST {
    /// Walks the document in ``depthFirstOrder()`` and assigns each
    /// distinct ``InlineRun/Annotation/noteRef(_:)`` UUID a 1-based
    /// number the first time it is encountered, scoped by the
    /// referenced note block's type (`.footnote` or `.endnote`) in
    /// ``DocumentMeta/notes``. A `noteRef` whose UUID has no entry in
    /// `meta.notes` (a dangling reference) is skipped - it contributes
    /// no number in either sequence. Reordering which note is
    /// referenced first re-derives the numbering; nothing here reads
    /// or writes stored state.
    public func deriveNoteNumbering() -> NoteNumbering {
        var numbering = NoteNumbering()
        var nextFootnote = 1
        var nextEndnote = 1
        for blockID in depthFirstOrder() {
            guard let block = blocks[blockID] else { continue }
            for run in block.content {
                for annotation in run.annotations {
                    guard case .noteRef(let noteID) = annotation else { continue }
                    switch meta.notes[noteID]?.type {
                    case .footnote:
                        if numbering.footnotes[noteID] == nil {
                            numbering.footnotes[noteID] = nextFootnote
                            nextFootnote += 1
                        }
                    case .endnote:
                        if numbering.endnotes[noteID] == nil {
                            numbering.endnotes[noteID] = nextEndnote
                            nextEndnote += 1
                        }
                    default:
                        break
                    }
                }
            }
        }
        return numbering
    }
}

// MARK: - JSON helpers

extension DocumentAST {
    /// Encode the AST to JSON. Uses a stable key ordering and ISO-8601
    /// dates so that two semantically-equal ASTs produce byte-identical
    /// JSON (the property the receipt chain relies on for content
    /// hashing). The encoder excludes `parentID` from the round-trip
    /// because the parent is implicit in the tree shape; storing it
    /// would create ambiguity if a stale value was written.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Decode an AST from JSON. The inverse of ``jsonData()``.
    public static func from(jsonData: Data) throws -> DocumentAST {
        let decoder = JSONDecoder()
        return try decoder.decode(DocumentAST.self, from: jsonData)
    }

    /// SHA-256 content hash of the canonical JSON form. The receipt
    /// infrastructure embeds this hash in the C2PA `c2pa.hash.data`
    /// assertion. The hash is computed over ``jsonData()`` (sorted
    /// keys) so two semantically-equal ASTs produce the same hash.
    public func contentHash() throws -> String {
        let data = try jsonData()
        var hasher = SHA256()
        hasher.update(data: data)
        let digest = hasher.finalize()
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A plain-text rendering of the document (root children depth-first,
    /// each block's inline runs joined, blocks separated by newlines). Used
    /// to build chat-prompt context sections so Tessy + Sky reason over the
    /// live document body without seeing markup.
    public func plainText() -> String {
        guard !rootChildren.isEmpty else { return "" }
        var lines: [String] = []
        func render(_ blockID: UUID) {
            guard let block = blocks[blockID] else { return }
            let text = block.content.map(\.text).joined()
            if !text.isEmpty { lines.append(text) }
            for child in block.children { render(child) }
        }
        for child in rootChildren { render(child) }
        return lines.joined(separator: "\n")
    }
}
