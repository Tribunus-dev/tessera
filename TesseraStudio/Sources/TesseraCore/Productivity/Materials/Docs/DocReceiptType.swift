import Foundation

// MARK: - DocReceiptType

/// The set of receipt types ``DocStore`` emits. The string values
/// are what show up in `graph_receipts.receipt_type`; the enum
/// keeps the call sites self-documenting and makes the receipt
/// vocabulary searchable. Mirrors the ``EmailReceiptType`` /
/// ``NoteReceiptType`` taxonomy shapes.
public enum DocReceiptType: String, Codable, Sendable, CaseIterable {
    /// A document was created or fully upserted.
    case upsert = "doc_upsert"
    /// The document's body AST was replaced.
    case updateBody = "doc_body_changed"
    /// The document was archived.
    case archive = "doc_archived"
    /// The document was unarchived (restored from archive).
    case unarchive = "doc_unarchived"
    /// The document was moved to trash (soft delete).
    case trash = "doc_trashed"
    /// The document was restored from trash.
    case restore = "doc_restored"
    /// The document was hard-deleted.
    case delete = "doc_delete"
    /// The document was marked as favorite.
    case favorite = "doc_favorited"
    /// The document was unmarked as favorite.
    case unfavorite = "doc_unfavorited"
    /// The document's full tag list was set.
    case tagChange = "doc_tags_changed"
    /// A single tag was added.
    case tagAdded = "doc_tag_added"
    /// A single tag was removed.
    case tagRemoved = "doc_tag_removed"
    /// A link to another graph entity was created.
    case link = "doc_link_created"
    /// A link was removed.
    case unlink = "doc_link_deleted"
    /// The document was imported from an external format
    /// (python-docx, Pandoc, HTML via SwiftSoup).
    case `import` = "doc_imported"
}
