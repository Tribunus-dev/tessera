import Foundation

// MARK: - CommentThread

/// A resolved comment thread in the document. One thread corresponds to one
/// `BlockType.comment` block and zero or more `.comment` reply blocks as children.
/// All blocks in a thread share the same `anchorBlockID` and `anchorRangeStart/End`.
public struct CommentThread: Identifiable, Hashable {
    public let id: UUID
    /// The UUID of the block this thread is anchored to.
    public let anchorBlockID: UUID
    /// The character offset into the anchor block where the highlight begins.
    public let anchorRangeStart: Int
    /// The character offset into the anchor block where the highlight ends.
    public let anchorRangeEnd: Int
    /// The author name shown in the UI.
    public let author: String
    /// The ISO-8601 timestamp of the first comment.
    public let createdAt: Date
    /// The plain text of each comment in the thread, in order.
    public let messages: [CommentMessage]
    /// True when the thread has been marked resolved (stored in the comment block).
    public var isResolved: Bool

    public init(
        id: UUID,
        anchorBlockID: UUID,
        anchorRangeStart: Int,
        anchorRangeEnd: Int,
        author: String,
        createdAt: Date,
        messages: [CommentMessage],
        isResolved: Bool = false
    ) {
        self.id = id
        self.anchorBlockID = anchorBlockID
        self.anchorRangeStart = anchorRangeStart
        self.anchorRangeEnd = anchorRangeEnd
        self.author = author
        self.createdAt = createdAt
        self.messages = messages
        self.isResolved = isResolved
    }
}

// MARK: - CommentMessage

/// One message inside a comment thread.
public struct CommentMessage: Identifiable, Hashable {
    public let id: UUID
    public let author: String
    public let text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), author: String, text: String, createdAt: Date = Date()) {
        self.id = id
        self.author = author
        self.text = text
        self.createdAt = createdAt
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

        // Second pass: build threads.
        for (id, block) in document.blocks where block.type == .comment {
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
                anchorBlockID: anchorBlockID,
                anchorRangeStart: range.start,
                anchorRangeEnd: range.end,
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
