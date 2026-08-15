import Foundation

//===----------------------------------------------------------------------===//
//  RevisionController.swift
//  Tessera Studio
//
//  Accept/reject lifecycle for track-changes (P1 item 1.14,
//  studio-expansion-design-refinement-2026-08-14.md's Writer cluster).
//  Operates entirely on the existing `.trackInsertion`/`.trackDeletion`
//  BlockType cases - no new block types, no moveFrom/moveTo. A block's
//  own `id` IS its revision id; `attributes["revisionID"]` is only
//  present when several blocks (a multi-paragraph paste, or a move's
//  paired insertion+deletion) resolve as one atomic group - see
//  `RevisionController.revisionID(for:)`.
//
//  Pure and stateless, matching TransformController/QueryEngine in this
//  same wave family: `accept`/`reject` take a `DocumentAST` and return a
//  new one plus a `RevisionResolution`, never touching `DocStore`. A
//  future `DocStore` integration is the one place that both calls this
//  and appends the `doc_revision_accepted`/`doc_revision_rejected`
//  receipt (`RevisionResolution.receiptType`/`.payload` are shaped for
//  exactly that call, mirroring `QueryEngineOutcome`).
//
//  **Resolving one block.** `accept`/`reject` each reduce to one of two
//  primitive actions per block in the target revisionID's group:
//    - convert to plain content: the track-change wrapper is removed
//      (`type` -> `.paragraph`, track attributes stripped) but `id`,
//      `content`, AND `children` are untouched. Never clearing
//      `children` here is what keeps a still-pending NESTED revision
//      (a different revisionID, nested via `children`) fully intact and
//      independently resolvable afterward, regardless of which of the
//      two revisions gets resolved first - see the "innermost-first"
//      note below.
//    - remove entirely: the block and its WHOLE subtree (every block
//      reachable via `children`, recursively) is purged from the tree.
//      "The deleted content is gone" / "never happened" both mean
//      everything under the block, not just the node itself - a
//      still-pending nested revision inside a subtree being removed
//      here has no base document left to revert to once its container
//      is gone, so it is purged along with everything else rather than
//      left as an orphaned entry in `ast.blocks`.
//
//  **Nested revisions resolve innermost-first.** Because "convert"
//  never touches `children` and "remove" purges its whole subtree
//  regardless of what's pending inside it, resolving an outer revision
//  and an unrelated inner revision (nested via `children`) in EITHER
//  order produces the same final tree: resolve the outer first (a
//  "convert" leaves the inner block sitting exactly where it was,
//  ready for its own call; a "remove" was always going to take the
//  inner block with it) or resolve the inner first (its own removal or
//  conversion happens exactly as it would have anyway, and the outer's
//  later resolution sees whatever state the inner call left behind).
//  Neither order lets an outer accept/reject silently discard a still-
//  pending inner block's own state out from under a caller who hasn't
//  resolved it yet - see `RevisionControllerTests` for the two-order
//  same-contentHash proof.
//
//  **Moves need no special case.** A move is one `.trackInsertion` +
//  one `.trackDeletion` sharing `attributes["revisionID"]`. Grouping by
//  revisionID and resolving each block by its OWN type (per the two
//  actions above) already gives the right pair semantics: accept keeps
//  the insertion and drops the deletion (the move completes); reject
//  drops the insertion and restores the deletion (the move undoes) -
//  see `RevisionResolution.isMove`.
//===----------------------------------------------------------------------===//

// MARK: - RevisionDirection

/// Which lifecycle operation a `RevisionResolution` records.
public enum RevisionDirection: String, Sendable, Equatable, Hashable {
    case accept
    case reject
}

// MARK: - RevisionBlockAction

/// How ONE block in a resolved revision group was resolved. Every
/// `.trackInsertion`/`.trackDeletion` block resolves to exactly one of
/// these two outcomes - see the type header for what each does to the
/// tree.
public enum RevisionBlockAction: String, Sendable, Equatable, Hashable {
    case convertedToPlainContent
    case removed
}

// MARK: - RevisionBlockOutcome

/// One block's resolution within a `RevisionResolution`. `blockType`
/// is the block's type BEFORE resolution (`.trackInsertion` or
/// `.trackDeletion`) - `.convertedToPlainContent` blocks are
/// `.paragraph` in the returned AST, so this is the only place that
/// records what kind of tracked change it originally was.
public struct RevisionBlockOutcome: Sendable, Equatable {
    public let blockID: UUID
    public let blockType: BlockType
    public let action: RevisionBlockAction

    public init(blockID: UUID, blockType: BlockType, action: RevisionBlockAction) {
        self.blockID = blockID
        self.blockType = blockType
        self.action = action
    }
}

// MARK: - RevisionResolution

/// The result of one `RevisionController.accept`/`.reject` call: every
/// block that shared the target revisionID, and how each resolved.
/// Shaped for a future `DocStore` integration to turn directly into a
/// receipt - `receiptType` is the matching `DocReceiptType` raw value,
/// `payload` is the structural summary in the `[String: JSONValue]`
/// shape `appendReceipt(entityID:receiptType:payload:)` already takes
/// (mirrors `QueryEngineOutcome`'s receipt-emission boundary: this type
/// does not append anything itself).
public struct RevisionResolution: Sendable, Equatable {
    public let revisionID: UUID
    public let direction: RevisionDirection
    public let receiptType: String
    public let blocks: [RevisionBlockOutcome]

    public init(revisionID: UUID, direction: RevisionDirection, receiptType: String, blocks: [RevisionBlockOutcome]) {
        self.revisionID = revisionID
        self.direction = direction
        self.receiptType = receiptType
        self.blocks = blocks
    }

    /// `true` when no block in the document carried `revisionID` - the
    /// call was a safe no-op (e.g. resolving a group an ancestor's own
    /// removal already purged). The returned AST is unchanged.
    public var isEmpty: Bool { blocks.isEmpty }

    /// `true` when the group paired exactly one `.trackInsertion` with
    /// one `.trackDeletion` - the move shape `attributes["revisionID"]`
    /// grouping produces with no dedicated move block types.
    public var isMove: Bool {
        Set(blocks.map(\.blockType)) == [.trackInsertion, .trackDeletion]
    }

    /// The receipt payload a future `DocStore` integration appends
    /// verbatim.
    public var payload: [String: JSONValue] {
        [
            "revisionID": .string(revisionID.uuidString),
            "direction": .string(direction.rawValue),
            "blockCount": .number(Double(blocks.count)),
            "isMove": .bool(isMove),
            "blocks": .array(blocks.map {
                .object([
                    "blockID": .string($0.blockID.uuidString),
                    "blockType": .string($0.blockType.rawValue),
                    "action": .string($0.action.rawValue),
                ])
            }),
        ]
    }
}

// MARK: - RevisionController

/// Pure accept/reject resolution over `DocumentAST`'s existing
/// `.trackInsertion`/`.trackDeletion` blocks - peer of
/// `TransformController`/`QueryEngine`: a plain namespace of static
/// functions, no state, no `DocStore` dependency. See the file header
/// for the full design.
public enum RevisionController {

    /// The attribute key that groups several blocks into one
    /// multi-block revision. Absent on a single-block revision, whose
    /// revision id is simply its own `id` - see `revisionID(for:)`.
    public static let revisionIDAttributeKey = "revisionID"

    /// Attributes stripped when a block converts to plain content -
    /// exactly the track-change-specific attributes `BlockType.trackInsertion`/
    /// `.trackDeletion`'s doc comments document (`author`, `timestamp`),
    /// plus this controller's own grouping key.
    private static let trackChangeAttributeKeys: Set<String> = ["author", "timestamp", revisionIDAttributeKey]

    /// `block`'s effective revision id: `attributes["revisionID"]` when
    /// present (a multi-block revision), otherwise `block.id` itself
    /// ("block UUID = revision ID" for the single-block case).
    public static func revisionID(for block: Block) -> UUID {
        if let raw = block.attributes[revisionIDAttributeKey]?.stringValue, let uuid = UUID(uuidString: raw) {
            return uuid
        }
        return block.id
    }

    /// Accept every block sharing `revisionID`, atomically:
    /// `.trackInsertion` blocks convert to plain content (the insertion
    /// stands); `.trackDeletion` blocks are removed entirely (the
    /// deletion stands). See the file header for the move and nested-
    /// revision cases, which need no special handling here.
    public static func accept(revisionID: UUID, in ast: DocumentAST) -> (ast: DocumentAST, resolution: RevisionResolution) {
        resolve(target: revisionID, in: ast, direction: .accept)
    }

    /// Reject every block sharing `revisionID`, atomically: the
    /// inverse of `accept` - `.trackInsertion` blocks are removed
    /// entirely (the insertion never happened); `.trackDeletion` blocks
    /// convert to plain content (the deletion is undone).
    public static func reject(revisionID: UUID, in ast: DocumentAST) -> (ast: DocumentAST, resolution: RevisionResolution) {
        resolve(target: revisionID, in: ast, direction: .reject)
    }

    // MARK: - Resolution

    private static func resolve(
        target: UUID,
        in ast: DocumentAST,
        direction: RevisionDirection
    ) -> (ast: DocumentAST, resolution: RevisionResolution) {
        // Snapshot group membership from the INPUT ast before any
        // mutation - `result` below is a separate copy (DocumentAST is
        // a value type), so `ast` itself is never touched, which is
        // what lets a caller reconstruct the pre-resolution state from
        // the original value it already holds (the "undo" half of this
        // component's test contract).
        let group = ast.blocks.values
            .filter { ($0.type == .trackInsertion || $0.type == .trackDeletion) && revisionID(for: $0) == target }
            .sorted { $0.id.uuidString < $1.id.uuidString } // deterministic outcome order, independent of Dictionary iteration order

        let outcomes = group.map {
            RevisionBlockOutcome(blockID: $0.id, blockType: $0.type, action: resolvedAction(blockType: $0.type, direction: direction))
        }

        var result = ast
        // Pass 1 (convert) never mutates `children`/`rootChildren`, so
        // it can never race with pass 2's removals. Pass 2 runs after,
        // so a "convert" that is an ancestor of a same-group "remove"
        // (the move pair is siblings in practice, but nothing here
        // requires that) still gets its own type flipped before its
        // descendant is spliced out from under it.
        for outcome in outcomes where outcome.action == .convertedToPlainContent {
            convertToPlainContent(outcome.blockID, in: &result)
        }
        for outcome in outcomes where outcome.action == .removed {
            // May already be gone: an earlier removal THIS pass can
            // have purged a later group member as part of its subtree.
            // The outcome above still reports it as `.removed` - that
            // is its true fate - this guard just avoids re-deriving
            // work already done.
            guard result.blocks[outcome.blockID] != nil else { continue }
            removeSubtree(outcome.blockID, in: &result)
        }

        let receiptType = direction == .accept ? DocReceiptType.revisionAccepted.rawValue : DocReceiptType.revisionRejected.rawValue
        let resolution = RevisionResolution(revisionID: target, direction: direction, receiptType: receiptType, blocks: outcomes)
        return (result, resolution)
    }

    /// The one action a block resolves to, given its (pre-resolution)
    /// type and the requested direction. `.trackInsertion` and
    /// `.trackDeletion` always resolve oppositely for the same
    /// direction - see the file header's "moves need no special case"
    /// note for why that alone is enough to resolve a move pair.
    private static func resolvedAction(blockType: BlockType, direction: RevisionDirection) -> RevisionBlockAction {
        let isInsertion = blockType == .trackInsertion
        let keep = direction == .accept ? isInsertion : !isInsertion
        return keep ? .convertedToPlainContent : .removed
    }

    /// Removes the track-change wrapper: `type` becomes `.paragraph`
    /// and the track-specific attributes are stripped. `id`, `content`,
    /// `children`, and `parentID` are untouched - see the file header
    /// for why `children` in particular must never be cleared here.
    private static func convertToPlainContent(_ blockID: UUID, in ast: inout DocumentAST) {
        guard var block = ast.blocks[blockID] else { return }
        block.type = .paragraph
        block.attributes = block.attributes.filter { !trackChangeAttributeKeys.contains($0.key) }
        ast.blocks[blockID] = block
    }

    /// Removes `blockID` and every block reachable from it via
    /// `children`, recursively, then unlinks `blockID` from its
    /// parent's `children` (or `rootChildren` when it was a root).
    private static func removeSubtree(_ blockID: UUID, in ast: inout DocumentAST) {
        guard let removed = ast.blocks.removeValue(forKey: blockID) else { return }
        for child in removed.children {
            removeSubtree(child, in: &ast)
        }
        if let parentID = removed.parentID {
            ast.blocks[parentID]?.children.removeAll { $0 == blockID }
        } else {
            ast.rootChildren.removeAll { $0 == blockID }
        }
    }
}
