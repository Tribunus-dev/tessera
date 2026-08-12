import Foundation

// MARK: - Doc

/// A first-class Material in the Tessera productivity surface — a
/// Notion/Craft-style longform document. Docs are stored as
/// `graph_entity` rows with `entity_type = 'document'` and
/// `subtype = 'doc'`, matching the universal "one row per thing"
/// pattern (see `docs/tessera-data-layer-design.md` §3). The `body`
/// column carries the serialized `Doc` JSON (whose `body` field is
/// the `DocumentAST`); `label` is the display title.
///
/// Docs ride the same constitutional-receipt backbone as every
/// other material: every mutation produces a signed receipt. The
/// ``DocStore`` is the seam that enforces that invariant for the
/// document-specific mutation vocabulary (archive, trash, favorite,
/// tag, link).
///
/// The struct is self-contained: no data-layer imports, no
/// framework imports beyond `Foundation`.
public struct Doc: Codable, Sendable, Identifiable, Hashable {

    /// Stable identifier. New docs get a fresh UUID at creation;
    /// importer round-trips preserve the id so re-imports upsert
    /// in place.
    public let id: UUID

    /// Display title. The editor auto-derives this from the first
    /// heading in the body when the field is empty; the user can
    /// override it via the title field. The `label` column of
    /// `graph_entities` mirrors this field so the graph view +
    /// search by label work without decoding the AST.
    public var title: String

    /// The Block AST (spec §4). The document editor binds to this;
    /// `TesseraEditorView` is configured with `EditorMode.document`
    /// so the toolbar offers the full block palette.
    public var body: DocumentAST

    /// Optional cover image URL. Shown as a banner in the detail
    /// view when present. The URL may be a remote https URL or a
    /// local file URL for imported covers.
    public var coverImageURL: URL?

    /// Optional leading emoji icon for the document (Notion-style).
    /// Shown next to the title in the list + detail view.
    public var iconEmoji: String?

    /// Whether the document is archived. Archived docs are hidden
    /// from the All list and only appear in the Archived filter.
    public var isArchived: Bool

    /// Whether the document is in the trash. Trashed docs are
    /// hidden from every filter except Trash; a hard delete
    /// removes the row (receipt chain is preserved).
    public var isTrashed: Bool

    /// Whether the document is starred as a favorite. Favorites
    /// surface at the top of the All list and have their own
    /// filter.
    public var isFavorite: Bool

    /// Free-form tags. Normalized to lowercase + trimmed;
    /// duplicates are removed.
    public var tags: [String]

    /// Other graph entities this doc is linked to — contacts,
    /// calendar events, tasks, notes, other docs. Denormalized
    /// cache for the detail view's "related" section.
    public var linkedEntityIDs: [UUID]

    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "",
        body: DocumentAST = .empty,
        coverImageURL: URL? = nil,
        iconEmoji: String? = nil,
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
        self.coverImageURL = coverImageURL
        self.iconEmoji = iconEmoji
        self.isArchived = isArchived
        self.isTrashed = isTrashed
        self.isFavorite = isFavorite
        self.tags = Self.normalizeTags(tags)
        self.linkedEntityIDs = linkedEntityIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Constants

    /// The `graph_entities.entity_type` value.
    public static let entityType = "document"

    /// The `graph_entities.subtype` value for this material.
    public static let subtype = "doc"

    public var subtypeString: String { Self.subtype }

    // MARK: - Display

    /// Display title with fallbacks. Prefers the explicit `title`,
    /// then the first heading in the body, then "Untitled".
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let first = Doc.firstHeadingText(in: body), !first.isEmpty {
            return first
        }
        return "Untitled"
    }

    /// Snippet for the list view: first `maxLength` characters of
    /// plain text, collapsed to a single line.
    public func snippet(maxLength: Int = 200) -> String {
        Doc.plainTextSnippet(from: body, maxLength: maxLength)
    }

    /// Word count of the body. Splits on whitespace; empty AST
    /// returns 0.
    public var wordCount: Int {
        Doc.wordCount(of: body)
    }

    /// Estimated reading time in whole minutes. `ceil(wordCount / 250)`.
    public var readingTimeMinutes: Int {
        let words = wordCount
        guard words > 0 else { return 0 }
        return max(1, Int((Double(words) / 250.0).rounded(.up)))
    }

    // MARK: - Tag normalization

    public static func normalizeTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in tags {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                out.append(trimmed)
            }
        }
        return out
    }

    // MARK: - Plain text + heading extraction

    public static func firstHeadingText(in ast: DocumentAST) -> String? {
        for id in ast.rootChildren {
            guard let block = ast.blocks[id] else { continue }
            if block.type == .heading {
                let text = block.content.map { $0.text }.joined()
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    public static func plainText(of ast: DocumentAST) -> String {
        var out: [String] = []
        for id in ast.rootChildren {
            appendPlainText(blockID: id, ast: ast, into: &out)
        }
        return out.joined(separator: "\n")
    }

    private static func appendPlainText(
        blockID: UUID,
        ast: DocumentAST,
        into out: inout [String]
    ) {
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
            if let emoji = block.attributes["emoji"]?.stringValue, !emoji.isEmpty {
                line += emoji + " "
            }
            line += block.content.map { $0.text }.joined()
            if !line.isEmpty { out.append(line) }
        case .list:
            for child in block.children {
                appendPlainText(blockID: child, ast: ast, into: &out)
            }
        case .table:
            for child in block.children {
                appendPlainText(blockID: child, ast: ast, into: &out)
            }
        case .toggle, .image, .divider, .equation, .comment, .trackInsertion, .trackDeletion:
            break
        }
        for child in block.children where block.type != .list && block.type != .table {
            appendPlainText(blockID: child, ast: ast, into: &out)
        }
    }

    public static func plainTextSnippet(from ast: DocumentAST, maxLength: Int = 200) -> String {
        let raw = plainText(of: ast)
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= maxLength { return collapsed }
        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: maxLength)
        return String(collapsed[..<endIndex]) + "…"
    }

    public static func wordCount(of ast: DocumentAST) -> Int {
        let text = plainText(of: ast)
        guard !text.isEmpty else { return 0 }
        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
    }
}

// MARK: - JSON helpers

extension Doc {

    /// Encode to JSON. Uses sorted keys + ISO-8601 dates for
    /// deterministic bytes (receipt hashing relies on this).
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Decode from JSON. Inverse of ``jsonData()``.
    public static func from(jsonData: Data) throws -> Doc {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Doc.self, from: jsonData)
    }

    /// UTF-8 string form. Convenience for the store path (data
    /// layer deals in `String` bodies).
    public func jsonDataString() throws -> String {
        let data = try jsonData()
        guard let s = String(data: data, encoding: .utf8) else {
            throw DocStoreError.invalidBody(reason: "encoded JSON is not UTF-8")
        }
        return s
    }

    /// Inverse of ``jsonDataString()``.
    public static func from(jsonDataString: String) throws -> Doc {
        guard let data = jsonDataString.data(using: .utf8) else {
            throw DocStoreError.invalidBody(reason: "body is not valid UTF-8")
        }
        return try from(jsonData: data)
    }
}


