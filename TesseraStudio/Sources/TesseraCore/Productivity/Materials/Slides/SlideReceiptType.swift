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
    /// A master page was defined (or replaced) on the deck.
    case defineMasterPage = "slide_master_page_defined"
    /// A master page was removed from the deck.
    case undefineMasterPage = "slide_master_page_undefined"
    /// A slide's assigned master page was changed (or cleared).
    case setSlideMasterPage = "slide_master_page_assigned"
    /// A theme was defined (or replaced) on the deck (P1 1.5).
    case defineTheme = "slide_theme_defined"
    /// The deck's active theme was changed (or cleared) (P1 1.5).
    case setDeckTheme = "slide_theme_assigned"
    /// A transition was defined (or replaced) in the deck's catalog
    /// reference (P1 1.6).
    case defineTransition = "slide_transition_defined"
    /// A slide's assigned transition was changed (or cleared) (P1 1.6).
    case setSlideTransition = "slide_transition_assigned"
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
