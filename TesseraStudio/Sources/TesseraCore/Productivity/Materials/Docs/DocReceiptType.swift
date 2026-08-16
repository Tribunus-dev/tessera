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
    /// A track-changes revision (insertion or deletion block) was
    /// accepted, resolving it into plain content (P1 1.14).
    case revisionAccepted = "doc_revision_accepted"
    /// A track-changes revision was rejected, reverting it (P1 1.14).
    case revisionRejected = "doc_revision_rejected"
    /// One or more `.field` blocks were refreshed, resolving their
    /// cached `content` to current values (P1 1.1). Emitted only when
    /// a refresh actually changed something - see `FieldController`.
    case fieldsRefreshed = "doc_fields_refreshed"
    /// A find-and-replace mutation ran (DocumentSearchIndex.replacingAll).
    /// One receipt per call, regardless of how many matches it touched.
    case findReplace = "doc_find_replace"
    /// A style definition was created or replaced in DocumentMeta.styles.
    case defineStyle = "doc_style_defined"
    /// A style definition was removed; StyleRegistry.deletingStyle
    /// already rebound any orphaned children to the deleted style's
    /// own parent before this fires.
    case deleteStyle = "doc_style_deleted"
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
    /// A footnote or endnote block was inserted (P1 1.2, lifecycle
    /// closed P2-0).
    case insertNote = "doc_note_inserted"
    /// A footnote or endnote block was deleted (P2-0).
    case deleteNote = "doc_note_deleted"
    /// A comment thread was added, anchored to a block range (P2-0;
    /// DocStore had no comment lifecycle before this - Sheet/Slide
    /// equivalents landed P1 1.22).
    case addComment = "doc_comment_added"
    /// A reply was appended to an existing comment thread (P2-0).
    case commentReplied = "doc_comment_replied"
    /// A comment thread was marked resolved (P2-0).
    case commentResolved = "doc_comment_resolved"
    /// A comment thread was deleted (P2-0).
    case commentDeleted = "doc_comment_deleted"
    /// A table of contents was (re)generated (P2-C 2.5). Regenerating
    /// with no change (identical entries) is a no-op - zero receipts.
    case regenerateToc = "doc_toc_regenerated"
    /// A master document's part list, break kind, or numbering mode was
    /// changed (P2-C 2.11).
    case changeMasterParts = "doc_master_parts_changed"
    /// A mail-merge run completed, fanning one template + one record
    /// set out to N output documents (P2-C 2.4). Payload carries the
    /// source hash + record count named by the design contract; the
    /// per-output documents get their own ordinary doc_upsert receipts,
    /// this one is the merge OPERATION's own audit entry.
    case runMailMerge = "doc_mail_merge_run"
}
