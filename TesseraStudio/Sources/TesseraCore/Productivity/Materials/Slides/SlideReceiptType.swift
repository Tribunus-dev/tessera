import Foundation

// MARK: - SlideReceiptType

/// The set of receipt types ``SlideStore`` emits. The string values
/// are what show up in `graph_receipts.receipt_type`; the enum keeps
/// the call sites self-documenting and makes the receipt vocabulary
/// searchable. Mirrors the ``NoteReceiptType`` / `SheetReceiptType` /
/// `DocReceiptType` taxonomy shapes.
public enum SlideReceiptType: String, Codable, Sendable, CaseIterable {
    /// A slide deck was created or fully upserted.
    case upsert = "slide_upsert"
    /// The deck's body AST was replaced.
    case updateBody = "slide_body_changed"
    /// A slide was inserted at an index.
    case insertSlide = "slide_inserted"
    /// A slide was deleted.
    case deleteSlide = "slide_deleted"
    /// A slide was moved to a new index.
    case moveSlide = "slide_moved"
    /// A slide was duplicated.
    case duplicateSlide = "slide_duplicated"
    /// A slide's layout was changed.
    case setSlideLayout = "slide_layout_changed"
    /// The deck was archived.
    case archive = "slide_archived"
    /// The deck was unarchived.
    case unarchive = "slide_unarchived"
    /// The deck was moved to trash (soft delete).
    case trash = "slide_trashed"
    /// The deck was restored from trash.
    case restore = "slide_restored"
    /// The deck was hard-deleted.
    case delete = "slide_delete"
    /// The deck was marked as favorite.
    case favorite = "slide_favorited"
    /// The deck was unmarked as favorite.
    case unfavorite = "slide_unfavorited"
    /// The deck's full tag list was set.
    case tagChange = "slide_tags_changed"
    /// A single tag was added.
    case tagAdded = "slide_tag_added"
    /// A single tag was removed.
    case tagRemoved = "slide_tag_removed"
    /// A link to another graph entity was created.
    case link = "slide_link_created"
    /// A link was removed.
    case unlink = "slide_link_deleted"
    /// The deck was imported from an external format (pptx via
    /// python-pptx, PDF via PDFKit/PDFMiner).
    case `import` = "slide_imported"
}
