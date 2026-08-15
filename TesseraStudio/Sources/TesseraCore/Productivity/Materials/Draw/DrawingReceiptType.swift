import Foundation

// MARK: - DrawingReceiptType

/// The set of receipt types ``DrawingStore`` emits. The string values
/// are what show up in `graph_receipts.receipt_type`; the enum keeps
/// the call sites self-documenting and makes the receipt vocabulary
/// searchable. Mirrors the ``SlideReceiptType``/``DocReceiptType``
/// taxonomy shapes.
///
/// Case names match `docs/agent-tools-surface.md`'s planned
/// `drawing_*` agent tool surface (`insertShape`/`deleteShape`/
/// `setGeometry`/`setFill`/`setStroke`/`setText`/`setZOrder`/
/// `setLayer` family/`setConnector`) even though those tools aren't
/// wired up yet - so when they are, the receipt vocabulary this store
/// already emits lines up without a rename. `group`/`ungroup`/
/// `export`/`import`/`diff` from that same doc are explicitly marked
/// P1 there and have no corresponding ``DrawingStore`` method yet, so
/// they're not cases here either - a receipt type with nothing that
/// ever emits it would be dead vocabulary. `group`/`ungroup` graduate
/// to real cases in P2-0 alongside the corresponding `DrawingStore`
/// methods (row 48 closure); `export`/`import`/`diff` remain reserved.
public enum DrawingReceiptType: String, Codable, Sendable, CaseIterable {
    /// A drawing was created or fully upserted.
    case upsert = "drawing_upsert"
    /// The drawing was hard-deleted.
    case delete = "drawing_delete"
    /// The drawing was archived.
    case archive = "drawing_archived"
    /// The drawing was unarchived.
    case unarchive = "drawing_unarchived"
    /// The drawing was moved to trash (soft delete).
    case trash = "drawing_trashed"
    /// The drawing was restored from trash.
    case restore = "drawing_restored"
    /// The drawing was marked as favorite.
    case favorite = "drawing_favorited"
    /// The drawing was unmarked as favorite.
    case unfavorite = "drawing_unfavorited"
    /// The drawing's full tag list was set.
    case tagChange = "drawing_tags_changed"
    /// A single tag was added.
    case tagAdded = "drawing_tag_added"
    /// A single tag was removed.
    case tagRemoved = "drawing_tag_removed"
    /// A link to another graph entity was created.
    case link = "drawing_link_created"
    /// A link was removed.
    case unlink = "drawing_link_deleted"
    /// A shape was inserted.
    case insertShape = "drawing_shape_inserted"
    /// A shape was deleted.
    case deleteShape = "drawing_shape_deleted"
    /// A shape's geometry (position/size/rotation) was changed.
    case setGeometry = "drawing_shape_geometry_changed"
    /// A shape's fill was changed.
    case setFill = "drawing_shape_fill_changed"
    /// A shape's stroke was changed.
    case setStroke = "drawing_shape_stroke_changed"
    /// A shape's text was changed.
    case setText = "drawing_shape_text_changed"
    /// A shape's z-order (paint position) was changed.
    case setZOrder = "drawing_shape_z_order_changed"
    /// A shape's connector info (attached endpoints, style) was
    /// changed. Reuses DrawingStore's mutatingShape helper, same as
    /// setGeometry/setFill/setStroke/setText.
    case setConnector = "drawing_shape_connector_changed"
    /// A layer was added.
    case layerAdded = "drawing_layer_added"
    /// A layer was renamed.
    case layerRenamed = "drawing_layer_renamed"
    /// A layer was deleted.
    case layerDeleted = "drawing_layer_deleted"
    /// Layer paint order was changed.
    case layerReordered = "drawing_layer_reordered"
    /// A layer's visibility (isVisible) was changed.
    case layerVisibilityChanged = "drawing_layer_visibility_changed"
    /// A layer's lock state (isLocked) was changed.
    case layerLockChanged = "drawing_layer_lock_changed"
    /// Two or more shapes were grouped into one (row 48, P2-0).
    case groupShapes = "drawing_shapes_grouped"
    /// A shape group was dissolved back into its members (P2-0).
    case ungroupShapes = "drawing_shapes_ungrouped"
}
