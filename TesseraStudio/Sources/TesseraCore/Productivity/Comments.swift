import Foundation

// MARK: - CommentAnchor

/// Where a comment thread is attached. One polymorphic anchor across every
/// material with comments (Writer/Calc/Impress), so the thread model
/// doesn't fork per surface (studio-expansion-design-refinement-2026-08-14
/// .md section 4, Calc cluster).
public enum CommentAnchor: Codable, Sendable, Hashable {
    /// A character range inside a text-bearing block (Writer). The only
    /// anchor kind before this type existed - see `CommentThread`'s
    /// legacy decode fallback, which produces this case.
    case textRange(blockID: UUID, start: Int, end: Int)
    /// A whole block, no character range (e.g. a shape or image comment).
    case block(UUID)
    /// A single cell on a sheet (Calc).
    case cell(sheetID: UUID, row: Int, col: Int)
    /// A whole slide (Impress).
    case slide(UUID)

    /// Shifts a `.cell` anchor on `sheetID` when `count` rows are inserted
    /// at `insertedAt` (0-based; a row at or below `insertedAt` moves down
    /// by `count` - Calc's "insert row above" semantics). Every other
    /// anchor kind, and every `.cell` anchor on a different sheet, comes
    /// back unchanged: a row insertion on one sheet must never perturb
    /// another sheet's comments.
    public func remapped(afterRowInsertedAt insertedAt: Int, count: Int, onSheet sheetID: UUID) -> CommentAnchor {
        guard case let .cell(anchorSheetID, row, col) = self, anchorSheetID == sheetID, row >= insertedAt else {
            return self
        }
        return .cell(sheetID: anchorSheetID, row: row + count, col: col)
    }

    /// Column counterpart of ``remapped(afterRowInsertedAt:count:onSheet:)``.
    public func remapped(afterColumnInsertedAt insertedAt: Int, count: Int, onSheet sheetID: UUID) -> CommentAnchor {
        guard case let .cell(anchorSheetID, row, col) = self, anchorSheetID == sheetID, col >= insertedAt else {
            return self
        }
        return .cell(sheetID: anchorSheetID, row: row, col: col + count)
    }
}

// MARK: - CommentThread

/// A resolved comment thread anchored somewhere in a document, sheet, or
/// slide deck - one thread model across every material (studio-expansion
/// -design-refinement-2026-08-14.md section 4). For Writer, one thread
/// corresponds to one `BlockType.comment` block and zero or more
/// `.comment` reply blocks as children (see `CommentStore`); Calc/Impress
/// comments have no block tree to live in and are addressed purely by
/// `anchor`.
public struct CommentThread: Identifiable, Hashable {
    public let id: UUID
    /// Where the thread is attached. `.textRange` was the implicit-only
    /// anchor kind before P1 1.22; see the legacy `Decodable` fallback
    /// below for documents/threads written before this type existed.
    public let anchor: CommentAnchor
    /// Stable author identifier (a GUID), NOT a display name - no
    /// `PersonRegistry`-shaped type exists yet in this codebase to
    /// resolve it to a name/avatar (grepped for `PersonRegistry` and
    /// similar before writing this), so the call site owns that lookup.
    public let author: String
    /// UTC timestamp of the first comment. Encoded/decoded with the
    /// codebase's standard `.iso8601` `JSONEncoder`/`JSONDecoder`
    /// strategy at the call site - see e.g. `SlideDeck.jsonData()`.
    public let createdAt: Date
    /// Every message in the thread, flat (not a tree) - see
    /// `CommentMessage.parentMessageID` for how replies chain. Order is
    /// not significant; a genuine reply chain is not necessarily append-
    /// order.
    public let messages: [CommentMessage]
    /// True when the thread has been marked resolved ("done").
    public var isResolved: Bool

    public init(
        id: UUID,
        anchor: CommentAnchor,
        author: String,
        createdAt: Date,
        messages: [CommentMessage],
        isResolved: Bool = false
    ) {
        self.id = id
        self.anchor = anchor
        self.author = author
        self.createdAt = createdAt
        self.messages = messages
        self.isResolved = isResolved
    }
}

extension CommentThread: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, anchor, author, createdAt, messages, isResolved
        // Legacy flat shape (pre-P1-1.22): the anchor was always an
        // implicit textRange, written as three top-level keys instead of
        // a nested `anchor` - same three key names `BlockType.comment`
        // blocks already use in `Block.attributes`.
        case anchorBlockID, anchorRangeStart, anchorRangeEnd
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        if let decodedAnchor = try c.decodeIfPresent(CommentAnchor.self, forKey: .anchor) {
            anchor = decodedAnchor
        } else {
            let blockID = try c.decode(UUID.self, forKey: .anchorBlockID)
            let start = try c.decode(Int.self, forKey: .anchorRangeStart)
            let end = try c.decode(Int.self, forKey: .anchorRangeEnd)
            anchor = .textRange(blockID: blockID, start: start, end: end)
        }
        author = try c.decode(String.self, forKey: .author)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        messages = try c.decode([CommentMessage].self, forKey: .messages)
        isResolved = try c.decodeIfPresent(Bool.self, forKey: .isResolved) ?? false
    }

    /// Not backward-compatible by design: new JSON always writes `anchor`,
    /// never the legacy flat keys. Only decode reads both shapes -
    /// matching `Drawing.layers`'s Codable-evolution pattern.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(anchor, forKey: .anchor)
        try c.encode(author, forKey: .author)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(messages, forKey: .messages)
        try c.encode(isResolved, forKey: .isResolved)
    }
}

// MARK: - CommentMessage

/// One message inside a comment thread. A flat list, not a tree: a
/// reply's place in the thread comes from `parentMessageID`, not from
/// list order or nesting.
public struct CommentMessage: Identifiable, Hashable {
    public let id: UUID
    /// Stable author identifier (a GUID) - see `CommentThread.author`.
    public let author: String
    public let text: String
    public let createdAt: Date
    /// nil = root message of the thread. Non-nil = a reply, pointing at
    /// the message it replies to - NOT necessarily the thread's first
    /// message, so a genuine reply chain (not just a flat list under one
    /// root) is representable.
    public let parentMessageID: UUID?
    /// `@mention` offsets into `text`, plain-text-and-offsets rather than
    /// rich inline markup.
    public let mentions: [MentionOffset]

    public init(
        id: UUID = UUID(),
        author: String,
        text: String,
        createdAt: Date = Date(),
        parentMessageID: UUID? = nil,
        mentions: [MentionOffset] = []
    ) {
        self.id = id
        self.author = author
        self.text = text
        self.createdAt = createdAt
        self.parentMessageID = parentMessageID
        self.mentions = mentions
    }
}

extension CommentMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, author, text, createdAt, parentMessageID, mentions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        author = try c.decode(String.self, forKey: .author)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        // Both new in P1 1.22; absent in any message written before
        // threading/mentions existed.
        parentMessageID = try c.decodeIfPresent(UUID.self, forKey: .parentMessageID)
        mentions = try c.decodeIfPresent([MentionOffset].self, forKey: .mentions) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(author, forKey: .author)
        try c.encode(text, forKey: .text)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(parentMessageID, forKey: .parentMessageID)
        try c.encode(mentions, forKey: .mentions)
    }
}

// MARK: - CommentThread + lifecycle (P2-0: reply/resolve/delete)

extension CommentThread {
    /// A copy with `message` appended to `messages`. `messages` is
    /// `let`, so this goes through the memberwise `init` rather than
    /// mutating in place - same shape as `Sheet.addingCommentThread`.
    public func addingReply(_ message: CommentMessage) -> CommentThread {
        CommentThread(
            id: id,
            anchor: anchor,
            author: author,
            createdAt: createdAt,
            messages: messages + [message],
            isResolved: isResolved
        )
    }

    /// A copy with `isResolved` set true. `isResolved` is `var`, so
    /// this one *can* mutate a local copy directly.
    public func resolved() -> CommentThread {
        var updated = self
        updated.isResolved = true
        return updated
    }
}

// MARK: - MentionOffset

/// A `@mention` inside a `CommentMessage`'s plain text. UTF-16 start/end
/// offsets into `text`, the same shape `ChatMessage.swift`'s `RangeOffset`
/// uses for the same reason (`Range<String.Index>` isn't `Codable`) -
/// flattened here rather than composing `RangeOffset` directly because
/// `RangeOffset` is only `Equatable`, not `Hashable`, and `CommentMessage`
/// (and `CommentThread` above it) need to stay `Hashable` end to end.
public struct MentionOffset: Codable, Sendable, Hashable {
    public let start: Int
    public let end: Int
    public let personID: String

    public init(start: Int, end: Int, personID: String) {
        self.start = start
        self.end = end
        self.personID = personID
    }
}

// MARK: - CommentStore

/// Extracts comment threads from a `DocumentAST`. Used by both the sidebar
/// and the text view highlight renderer.
public enum CommentStore {
    /// Build the list of active comment threads from a document AST.
    /// Skips resolved threads unless `includeResolved` is true.
    public static func threads(from document: DocumentAST, includeResolved: Bool = false) -> [CommentThread] {
        var threads: [CommentThread] = []
        var anchorRanges: [UUID: (start: Int, end: Int)] = [:]

        // First pass: collect anchor ranges from comment blocks.
        for (id, block) in document.blocks {
            if block.type == .comment {
                let start = block.attributes["anchorRangeStart"]?.intValue ?? 0
                let end = block.attributes["anchorRangeEnd"]?.intValue ?? start
                anchorRanges[id] = (start, end)
            }
        }

        // Reply blocks are any .comment block that appears as a CHILD of another .comment
        // block - they surface inside their parent's thread (below), not as their own thread root.
        var replyBlockIDs: Set<UUID> = []
        for (_, block) in document.blocks where block.type == .comment {
            for childID in block.children {
                if document.blocks[childID]?.type == .comment {
                    replyBlockIDs.insert(childID)
                }
            }
        }

        // Second pass: build threads.
        for (id, block) in document.blocks where block.type == .comment && !replyBlockIDs.contains(id) {
            let resolved = block.attributes["resolved"]?.boolValue ?? false
            if !includeResolved && resolved { continue }

            let anchorBlockID = UUID(uuidString: block.attributes["anchorBlockID"]?.stringValue ?? "") ?? UUID()
            let range = anchorRanges[id] ?? (0, 0)
            let author = block.attributes["author"]?.stringValue ?? "Unknown"
            let timestamp: Date
            if let ts = block.attributes["timestamp"]?.numberValue {
                timestamp = Date(timeIntervalSince1970: ts)
            } else {
                timestamp = Date()
            }

            // Collect messages: the root comment block's content + all children.
            var messages: [CommentMessage] = []
            // Root comment block message.
            let rootText = block.content.map(\.text).joined()
            if !rootText.isEmpty {
                messages.append(CommentMessage(
                    id: id,
                    author: author,
                    text: rootText,
                    createdAt: timestamp
                ))
            }
            // Reply blocks.
            for childID in block.children {
                if let replyBlock = document.blocks[childID],
                   replyBlock.type == .comment {
                    let replyText = replyBlock.content.map(\.text).joined()
                    let replyAuthor = replyBlock.attributes["author"]?.stringValue ?? author
                    let replyTimestamp: Date
                    if let ts = replyBlock.attributes["timestamp"]?.numberValue {
                        replyTimestamp = Date(timeIntervalSince1970: ts)
                    } else {
                        replyTimestamp = timestamp
                    }
                    if !replyText.isEmpty {
                        messages.append(CommentMessage(
                            id: childID,
                            author: replyAuthor,
                            text: replyText,
                            createdAt: replyTimestamp
                        ))
                    }
                }
            }

            threads.append(CommentThread(
                id: id,
                anchor: .textRange(blockID: anchorBlockID, start: range.start, end: range.end),
                author: author,
                createdAt: timestamp,
                messages: messages,
                isResolved: resolved
            ))
        }

        return threads.sorted { $0.createdAt < $1.createdAt }
    }

    /// Count of unresolved comment threads in a document.
    public static func count(from document: DocumentAST) -> Int {
        threads(from: document, includeResolved: false).count
    }

    /// Count of pending track-change blocks (insertion + deletion) in a document.
    public static func pendingChangeCount(from document: DocumentAST) -> Int {
        document.blocks.values.filter { $0.type == .trackInsertion || $0.type == .trackDeletion }.count
    }
}

// MARK: - TrackChange

/// Represents a tracked change (insertion or deletion) in the document.
public struct TrackChange: Identifiable, Hashable {
    public let id: UUID
    public let type: ChangeType
    public let author: String
    public let createdAt: Date
    public let text: String
    /// The block being commented on / changed.
    public let anchorBlockID: UUID

    public enum ChangeType: String, Hashable {
        case insertion
        case deletion
    }

    public init(id: UUID, type: ChangeType, author: String, createdAt: Date, text: String, anchorBlockID: UUID) {
        self.id = id
        self.type = type
        self.author = author
        self.createdAt = createdAt
        self.text = text
        self.anchorBlockID = anchorBlockID
    }

    public static func from(document: DocumentAST) -> [TrackChange] {
        var changes: [TrackChange] = []
        for (id, block) in document.blocks {
            let blockType: TrackChange.ChangeType?
            switch block.type {
            case .trackInsertion: blockType = .insertion
            case .trackDeletion: blockType = .deletion
            default: blockType = nil
            }
            guard let ct = blockType else { continue }
            let author = block.attributes["author"]?.stringValue ?? "Unknown"
            let timestamp: Date
            if let ts = block.attributes["timestamp"]?.numberValue {
                timestamp = Date(timeIntervalSince1970: ts)
            } else {
                timestamp = Date()
            }
            let text = block.content.map(\.text).joined()
            let anchor = UUID(uuidString: block.attributes["anchorBlockID"]?.stringValue ?? "") ?? UUID()
            changes.append(TrackChange(
                id: id,
                type: ct,
                author: author,
                createdAt: timestamp,
                text: text,
                anchorBlockID: anchor
            ))
        }
        return changes.sorted { $0.createdAt < $1.createdAt }
    }
}

// MARK: - Sheet + Comments

extension Sheet {
    /// `commentThreads ?? []`, matching `effectiveConditionalFormats`/
    /// `effectiveValidationRules`'s "nil means none" convention.
    public var effectiveCommentThreads: [CommentThread] {
        commentThreads ?? []
    }

    /// A copy with `thread` appended.
    public func addingCommentThread(_ thread: CommentThread) -> Sheet {
        var updated = self
        updated.commentThreads = effectiveCommentThreads + [thread]
        return updated
    }

    /// A copy with the thread matching `thread.id` replaced (reply,
    /// resolve - anything that produces a modified `CommentThread`
    /// value rather than removing it). No-op (same array) if no
    /// thread with that id exists.
    public func replacingCommentThread(_ thread: CommentThread) -> Sheet {
        var updated = self
        updated.commentThreads = effectiveCommentThreads.map { $0.id == thread.id ? thread : $0 }
        return updated
    }

    /// A copy with the thread matching `id` removed. No-op (same
    /// array) if no thread with that id exists.
    public func removingCommentThread(id: UUID) -> Sheet {
        var updated = self
        updated.commentThreads = effectiveCommentThreads.filter { $0.id != id }
        return updated
    }
}

// MARK: - SlideDeck + Comments

extension SlideDeck {
    /// `commentThreads ?? []`, matching `effectiveMasterPages`'s "nil
    /// means none" convention.
    public var effectiveCommentThreads: [CommentThread] {
        commentThreads ?? []
    }

    /// A copy with `thread` appended.
    public func addingCommentThread(_ thread: CommentThread) -> SlideDeck {
        var updated = self
        updated.commentThreads = effectiveCommentThreads + [thread]
        return updated
    }

    /// A copy with the thread matching `thread.id` replaced. No-op
    /// (same array) if no thread with that id exists. See
    /// `Sheet.replacingCommentThread`.
    public func replacingCommentThread(_ thread: CommentThread) -> SlideDeck {
        var updated = self
        updated.commentThreads = effectiveCommentThreads.map { $0.id == thread.id ? thread : $0 }
        return updated
    }

    /// A copy with the thread matching `id` removed. No-op (same
    /// array) if no thread with that id exists.
    public func removingCommentThread(id: UUID) -> SlideDeck {
        var updated = self
        updated.commentThreads = effectiveCommentThreads.filter { $0.id != id }
        return updated
    }
}
