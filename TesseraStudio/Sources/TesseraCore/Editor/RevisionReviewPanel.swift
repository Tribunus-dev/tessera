import Foundation
import SwiftUI

// RevisionReviewPanel (P2 item 2.9, sota-p2-core-report.md "Design
// contracts" section 2.9). A side panel that reviews Writer track-
// changes: one row per pending revision (a move pair collapses to one
// "moved" row), with author/pending-only filters, search, and a
// receipt-id chip that routes to the receipts drawer. Mirrors
// `ActionAuditLogPanel.swift`'s shape exactly (an `@Observable` store
// class + the main SwiftUI View + a row subview + a trigger view + an
// `NSWindowDelegate` presenter) - read that file before this one.
//
// **Zero new data model.** Pure scan of the existing `DocumentAST`,
// grouped by `RevisionController.revisionID(for:)` - see
// `RevisionReviewScan`. Nothing here is persisted; `rows` is rebuilt
// from scratch every `refresh(from:)` call.
//
// **Pull, not push.** Same IA as the audit log: the host calls
// `RevisionReviewStore.refresh(from:)` whenever the document changes
// (on open, and after any accept/reject - including ones made
// elsewhere); the panel never observes the document itself.
//
// **SCOPE NOTE (honesty, per the design contract).** The plan's row
// says "Calc + Writer" but no Calc revision model exists (1.14
// RevisionController is Doc-side only). This ships Writer-first; the
// Calc half is satisfied by the receipts drawer until a Calc revision
// model is ever ratified.
//
// **Accept/Reject reuse the EXISTING mutation path.** `RevisionReviewStore`
// calls `DocStore.acceptRevision`/`rejectRevision` (already landed,
// already receipted with `doc_revision_accepted`/`doc_revision_rejected`)
// - no new receipt types here. The pure `RevisionController.accept`/
// `reject` calculation is ALSO run locally, on the same pre-call AST,
// purely to read back which blocks resolved which way (`RevisionResolution
// .blocks`) so the local Cmd-Z bookkeeping below can be built from real
// outcomes instead of re-deriving the accept/reject rule by hand; it is
// never used to write anything - `DocStore` is the only persister.
//
// **Accept-all / per-author = one undo unit.** Mirrors
// `DrawCanvasView.registerUndo` (`Views/Draw/DrawCanvasView.swift`,
// P2-0's Draw canvas gesture layer): one `Mutation` per resolved block,
// signed as one local `Receipt` each via `ReceiptSigner`, grouped with
// `ReceiptUndoManager.group(_:)` so the whole batch is a single Cmd-Z.
// This is a SEPARATE bookkeeping system from the persisted `GraphReceipt`
// audit trail `DocStore` already appended above it - see
// `DrawCanvasView.swift`'s own header comment for why the two receipt
// systems in this codebase are independent. Best-effort: a missing
// signing key costs only this window's Cmd-Z affordance, never the real
// persistence, which already landed by that point regardless.
//
// **Receipt-id chip.** `DocStore.acceptRevision`/`rejectRevision` persist
// through `dataLayer.appendReceipt` internally but do not return the
// receipt id to the caller. Rather than guess one, `RevisionReviewStore`
// looks it up after the fact via the already-public
// `TesseraDataLayer.receiptChain(documentID:limit:)`, matching on
// receipt type + the `revisionID` payload key `RevisionResolution
// .payload` already writes. A lookup miss (or the call throwing) simply
// leaves the chip absent for that row - see `recordResolvedLog`. A
// PENDING row has no receipt at all (nothing has happened yet), so the
// chip only ever appears on the trailing "recently resolved" log this
// store keeps for the current session - seeing a chip on every row
// forever is not the contract; that data does not exist yet without a
// DocStore signature change (see this track's wiringNotes).

// MARK: - RevisionRowKind

/// What kind of tracked change a row represents. A move pair (one
/// `.trackInsertion` + one `.trackDeletion` sharing a revisionID)
/// collapses to `.moved` - see `RevisionResolution.isMove`.
public enum RevisionRowKind: String, Sendable, Hashable, CaseIterable {
    case insertion
    case deletion
    case moved

    /// Short label for the row's kind chip. ASCII only.
    public var shortLabel: String {
        switch self {
        case .insertion: return "ins"
        case .deletion: return "del"
        case .moved: return "move"
        }
    }
}

// MARK: - RevisionRowStatus

/// Whether a row is still actionable or was already resolved THIS
/// session. `RevisionReviewScan.scan` only ever produces `.pending`
/// rows (a resolved revision's blocks are no longer `.trackInsertion`/
/// `.trackDeletion`, so they vanish from the scan entirely); `.resolved`
/// rows come only from `RevisionReviewStore`'s own trailing log of
/// actions the panel itself just took.
public enum RevisionRowStatus: Sendable, Hashable {
    case pending
    case resolved(direction: RevisionDirection, receiptID: UUID?, resolvedAt: Date)

    public var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}

// MARK: - RevisionRow

/// One row in the panel. `id` IS the revisionID - `RevisionReviewScan
/// .scan` groups by that value, so each id appears at most once among
/// the pending rows (a move pair's two blocks collapse to one row).
public struct RevisionRow: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let author: String?
    public let timestamp: Date?
    public let kind: RevisionRowKind
    public let excerpt: String
    public let status: RevisionRowStatus

    public init(
        id: UUID,
        author: String?,
        timestamp: Date?,
        kind: RevisionRowKind,
        excerpt: String,
        status: RevisionRowStatus
    ) {
        self.id = id
        self.author = author
        self.timestamp = timestamp
        self.kind = kind
        self.excerpt = excerpt
        self.status = status
    }
}

// MARK: - RevisionReviewScan

/// Pure AST scan - no store, no DB, no SwiftUI host. Fully testable on
/// its own (testing-doctrine.md: "the AST-scan-and-group step should be
/// fully testable without a live DB or a real SwiftUI host").
public enum RevisionReviewScan {

    /// Groups every `.trackInsertion`/`.trackDeletion` block in `ast` by
    /// `RevisionController.revisionID(for:)` and returns one PENDING row
    /// per group. Deterministic order: newest `timestamp` first (rows
    /// with no timestamp sort last), ties broken by revisionID string so
    /// the order is stable across runs.
    public static func scan(_ ast: DocumentAST) -> [RevisionRow] {
        var groups: [UUID: [Block]] = [:]
        for block in ast.blocks.values where block.type == .trackInsertion || block.type == .trackDeletion {
            let revisionID = RevisionController.revisionID(for: block)
            groups[revisionID, default: []].append(block)
        }
        let rows = groups.compactMap { revisionID, blocks in row(revisionID: revisionID, blocks: blocks) }
        return rows.sorted(by: isOrderedBeforeInDisplay)
    }

    private static func isOrderedBeforeInDisplay(_ a: RevisionRow, _ b: RevisionRow) -> Bool {
        switch (a.timestamp, b.timestamp) {
        case let (l?, r?) where l != r:
            return l > r // newest first
        case (nil, .some):
            return false // nil sorts last
        case (.some, nil):
            return true
        default:
            return a.id.uuidString < b.id.uuidString
        }
    }

    private static func row(revisionID: UUID, blocks: [Block]) -> RevisionRow? {
        guard !blocks.isEmpty else { return nil }
        // Matches `RevisionResolution.isMove`'s own check exactly (a set
        // comparison, not a count check) so a row reads "moved" iff the
        // resolved receipt would also report `isMove == true`.
        let isMove = Set(blocks.map(\.type)) == [.trackInsertion, .trackDeletion]
        let kind: RevisionRowKind = isMove ? .moved : (blocks[0].type == .trackInsertion ? .insertion : .deletion)
        // The insertion block is the canonical source for a move row -
        // it is the content that survives an accept. Any other case has
        // only one type among its blocks, so blocks[0] is representative.
        let primary = isMove ? (blocks.first { $0.type == .trackInsertion } ?? blocks[0]) : blocks[0]
        let author = primary.attributes["author"]?.stringValue
        let timestamp = primary.attributes["timestamp"]?.numberValue.map { Date(timeIntervalSince1970: $0) }
        return RevisionRow(
            id: revisionID,
            author: author,
            timestamp: timestamp,
            kind: kind,
            excerpt: excerpt(for: primary),
            status: .pending
        )
    }

    /// First 80 characters of the block's own inline text. ASCII
    /// ellipsis on truncation (AGENTS.md: ASCII only).
    private static func excerpt(for block: Block, limit: Int = 80) -> String {
        let text = block.content.map(\.text).joined()
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "..."
    }
}

// MARK: - RevisionReviewFiltering

/// Pure filter/search over an already-scanned row list. Separated from
/// `RevisionReviewStore` so "author filter partitions exactly" is
/// testable without `@MainActor`/`@Observable`.
public enum RevisionReviewFiltering {
    public static func apply(
        to rows: [RevisionRow],
        authorFilter: Set<String>,
        pendingOnly: Bool,
        searchText: String
    ) -> [RevisionRow] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows.filter { row in
            if pendingOnly, !row.status.isPending { return false }
            if !authorFilter.isEmpty {
                guard let author = row.author, authorFilter.contains(author) else { return false }
            }
            if !needle.isEmpty {
                let haystack = ((row.author ?? "") + " " + row.excerpt).lowercased()
                if !haystack.contains(needle) { return false }
            }
            return true
        }
    }
}

// MARK: - RevisionReviewUndoBuilder

/// Pure builder for the LOCAL Cmd-Z mutation set behind an accept/reject
/// batch - no signing, no `ReceiptUndoManager`, no store. Separated from
/// `RevisionReviewStore.registerUndo` so the mapping from
/// `RevisionResolution` outcomes to `Mutation`s is testable without a
/// live `DocStore`/`TesseraDataLayer` (this codebase has no in-memory
/// stub for either - see `DocStoreTests.swift`'s own header). See the
/// file header's "Accept-all / per-author" section for the documented
/// scope limit on `.removed` outcomes.
public enum RevisionReviewUndoBuilder {

    /// One resolved revisionID: the `RevisionResolution` a pure
    /// `RevisionController.accept`/`reject` call produced, plus the AST
    /// it produced alongside it (needed to read back a `.convertedToPlainContent`
    /// block's post-resolution state).
    public struct ResolvedEntry {
        public let resolution: RevisionResolution
        public let postAST: DocumentAST

        public init(resolution: RevisionResolution, postAST: DocumentAST) {
            self.resolution = resolution
            self.postAST = postAST
        }
    }

    /// One `Mutation` per resolved block across every entry, in order.
    /// `baseAST` is the document state BEFORE the first entry resolved.
    /// Throws if any mutation fails `MutationEngine.apply` against the
    /// running working copy (mirrors the abort-the-whole-batch semantics
    /// `RevisionReviewStore.registerUndo`'s single `do`/`catch` already
    /// had before this was extracted - a partial local undo chain is
    /// worse than none, since `ReceiptUndoManager.group` is all-or-
    /// nothing per call).
    public static func mutations(for entries: [ResolvedEntry], baseAST: DocumentAST) throws -> [Mutation] {
        var workingBody = baseAST
        var engine = MutationEngine()
        var result: [Mutation] = []
        for entry in entries {
            for outcome in entry.resolution.blocks {
                let mutation: Mutation
                switch outcome.action {
                case .convertedToPlainContent:
                    guard let post = entry.postAST.blocks[outcome.blockID] else { continue }
                    mutation = .replaceBlock(blockID: outcome.blockID, block: post)
                case .removed:
                    guard workingBody.blocks[outcome.blockID] != nil else { continue }
                    mutation = .deleteBlock(blockID: outcome.blockID)
                }
                _ = try engine.apply(mutation, to: &workingBody)
                result.append(mutation)
            }
        }
        return result
    }
}

// MARK: - RevisionReviewStore

/// The data + integration layer for the panel. `@Observable` so a
/// SwiftUI view can `@Bindable` it, matching `ActionAuditLogStore`.
/// Owns the `DocStore`/`TesseraDataLayer`/`ReceiptUndoManager` seams;
/// the pure scan/filter logic above has none of those and is tested
/// independently.
@Observable
@MainActor
public final class RevisionReviewStore {

    /// Cap on the trailing "recently resolved this session" log -
    /// mirrors `ActionAuditLogStore.defaultCapacity`'s "recent, not a
    /// full session log" stance, at a much smaller scale (a review pass
    /// resolves a handful of revisions, not hundreds of agent actions).
    public nonisolated static let defaultResolvedLogCapacity: Int = 20

    private let docStore: DocStore
    private let dataLayer: TesseraDataLayer
    public let docID: UUID
    private let undoManager: ReceiptUndoManager
    private let userID: UserID
    private let signer: ReceiptSigner
    private let resolvedLogCapacity: Int

    /// The document AST as of the last `refresh(from:)` call. Used to
    /// run the pure `RevisionController.accept`/`reject` precompute in
    /// `resolve(_:direction:)` - see the file header.
    private var lastKnownAST: DocumentAST?

    public private(set) var rows: [RevisionRow] = []
    public private(set) var resolvedLog: [RevisionRow] = []
    public private(set) var lastError: String?

    public var authorFilter: Set<String> = []
    public var pendingOnlyFilter: Bool = false
    public var searchText: String = ""

    public init(
        docStore: DocStore,
        dataLayer: TesseraDataLayer,
        docID: UUID,
        undoManager: ReceiptUndoManager,
        userID: UserID,
        signer: ReceiptSigner = ReceiptSigner(),
        resolvedLogCapacity: Int = RevisionReviewStore.defaultResolvedLogCapacity
    ) {
        self.docStore = docStore
        self.dataLayer = dataLayer
        self.docID = docID
        self.undoManager = undoManager
        self.userID = userID
        self.signer = signer
        self.resolvedLogCapacity = resolvedLogCapacity
    }

    /// Rescans `ast` for pending revisions. Pull, not push - see the
    /// file header.
    public func refresh(from ast: DocumentAST) {
        lastKnownAST = ast
        rows = RevisionReviewScan.scan(ast)
    }

    /// Every author seen across pending + recently-resolved rows, for
    /// the filter bar's author chip list.
    public var authors: [String] {
        Array(Set(rows.compactMap(\.author) + resolvedLog.compactMap(\.author))).sorted()
    }

    public var visible: [RevisionRow] {
        RevisionReviewFiltering.apply(
            to: rows + resolvedLog,
            authorFilter: authorFilter,
            pendingOnly: pendingOnlyFilter,
            searchText: searchText
        )
    }

    public var headerSubtitle: String {
        "\(rows.count) pending revision\(rows.count == 1 ? "" : "s")"
    }

    // MARK: - Actions

    public func accept(_ revisionID: UUID) async {
        await resolve([revisionID], direction: .accept)
    }

    public func reject(_ revisionID: UUID) async {
        await resolve([revisionID], direction: .reject)
    }

    /// Accepts every currently-VISIBLE pending row (respecting the
    /// active filters), grouped as one undo unit.
    public func acceptAllVisible() async {
        await resolve(visible.filter(\.status.isPending).map(\.id), direction: .accept)
    }

    public func rejectAllVisible() async {
        await resolve(visible.filter(\.status.isPending).map(\.id), direction: .reject)
    }

    /// Accepts every pending row from one author, grouped as one undo
    /// unit ("accept-all / per-author" per the design contract).
    public func acceptAll(author: String) async {
        await resolve(rows.filter { $0.status.isPending && $0.author == author }.map(\.id), direction: .accept)
    }

    public func rejectAll(author: String) async {
        await resolve(rows.filter { $0.status.isPending && $0.author == author }.map(\.id), direction: .reject)
    }

    // MARK: - Resolution

    private struct ResolvedEntry {
        let id: UUID
        let resolution: RevisionResolution
        let postAST: DocumentAST

        var asBuilderEntry: RevisionReviewUndoBuilder.ResolvedEntry {
            RevisionReviewUndoBuilder.ResolvedEntry(resolution: resolution, postAST: postAST)
        }
    }

    private func resolve(_ ids: [UUID], direction: RevisionDirection) async {
        guard !ids.isEmpty else { return }
        guard let baseAST = lastKnownAST else { return }
        lastError = nil

        // Pure precompute - see the file header for why this never
        // writes anything; `DocStore` below is the only persister.
        var workingAST = baseAST
        var planned: [ResolvedEntry] = []
        for id in ids {
            let (resolvedAST, resolution) = direction == .accept
                ? RevisionController.accept(revisionID: id, in: workingAST)
                : RevisionController.reject(revisionID: id, in: workingAST)
            guard !resolution.isEmpty else { continue }
            planned.append(ResolvedEntry(id: id, resolution: resolution, postAST: resolvedAST))
            workingAST = resolvedAST
        }
        guard !planned.isEmpty else { return }

        // The real, receipted persistence path - one call per
        // revisionID. Stops at the first failure; only entries that
        // actually persisted are grouped into the local undo unit or
        // logged below, so a partial batch never claims more than it did.
        var succeeded: [ResolvedEntry] = []
        var lastDoc: Doc?
        for entry in planned {
            do {
                lastDoc = direction == .accept
                    ? try await docStore.acceptRevision(entry.id, for: docID)
                    : try await docStore.rejectRevision(entry.id, for: docID)
                succeeded.append(entry)
            } catch {
                lastError = error.localizedDescription
                break
            }
        }
        if let lastDoc { refresh(from: lastDoc.body) }
        guard !succeeded.isEmpty else { return }

        await registerUndo(succeeded, baseAST: baseAST)
        await recordResolvedLog(succeeded, direction: direction)
    }

    /// Local Cmd-Z bookkeeping only - the REAL persisted `GraphReceipt`
    /// audit trail already landed via `DocStore` in `resolve` above, one
    /// EXISTING receipt per revisionID (no new receipt types here). See
    /// the file header for the full rationale, including the documented
    /// scope limit: a `.removed` outcome's `Mutation.deleteBlock` only
    /// unlinks the top-level block `RevisionResolution.blocks` itself
    /// names, matching that payload's own granularity - it does not
    /// re-derive every descendant `RevisionController.removeSubtree`
    /// purged, since `MutationEngine` has no subtree-delete primitive.
    private func registerUndo(_ entries: [ResolvedEntry], baseAST: DocumentAST) async {
        var engine = MutationEngine()
        var workingBody = baseAST
        var receipts: [Receipt] = []
        var priorID = undoManager.snapshotUndoStack().last?.id
        do {
            let mutations = try RevisionReviewUndoBuilder.mutations(
                for: entries.map(\.asBuilderEntry), baseAST: baseAST
            )
            for mutation in mutations {
                let preSnapshot = try engine.apply(mutation, to: &workingBody)
                let receipt = try signer.sign(
                    documentID: docID,
                    mutations: [mutation],
                    priorReceiptID: priorID,
                    actor: .user(userID),
                    preMutationSnapshot: preSnapshot
                )
                receipts.append(receipt)
                priorID = receipt.id
            }
            if !receipts.isEmpty {
                undoManager.group(receipts)
            }
        } catch {
            // Best-effort - see the file header. The persisted
            // GraphReceipt audit trail already landed regardless.
        }
    }

    /// Appends one resolved `RevisionRow` per entry to the trailing log,
    /// best-effort populating `receiptID` from the document's own
    /// receipt chain - see the file header's "Receipt-id chip" section.
    private func recordResolvedLog(_ entries: [ResolvedEntry], direction: RevisionDirection) async {
        let resolvedAt = Date()
        let receiptType = (direction == .accept ? DocReceiptType.revisionAccepted : .revisionRejected).rawValue
        var chain: [(chainIndex: Int64, receipt: GraphReceipt)] = []
        do {
            chain = try await dataLayer.receiptChain(documentID: docID, limit: entries.count + 20)
        } catch {
            // Best-effort - see the file header. The chip stays absent.
        }
        for entry in entries {
            let priorRow = rows.first { $0.id == entry.id }
            let receiptID = chain.last {
                $0.receipt.receiptType == receiptType
                    && $0.receipt.payload["revisionID"]?.stringValue == entry.id.uuidString
            }?.receipt.id
            resolvedLog.append(RevisionRow(
                id: entry.id,
                author: priorRow?.author,
                timestamp: priorRow?.timestamp,
                kind: priorRow?.kind ?? (entry.resolution.isMove ? .moved : .insertion),
                excerpt: priorRow?.excerpt ?? "",
                status: .resolved(direction: direction, receiptID: receiptID, resolvedAt: resolvedAt)
            ))
        }
        if resolvedLog.count > resolvedLogCapacity {
            resolvedLog.removeFirst(resolvedLog.count - resolvedLogCapacity)
        }
    }
}

// MARK: - RevisionReviewPanel

/// The SwiftUI view that renders the panel as a side panel. Same shape
/// as `ActionAuditLogPanel`: header (title, subtitle, close), a filter
/// bar (search + author chips + pending-only toggle), and a scrolling
/// list of ``RevisionReviewRow``s, plus an accept-all/reject-all footer
/// over the currently-visible set.
public struct RevisionReviewPanel: View {
    @Bindable public var store: RevisionReviewStore
    @Binding public var isPresented: Bool
    public let onTapReceipt: (UUID) -> Void

    public init(
        store: RevisionReviewStore,
        isPresented: Binding<Bool>,
        onTapReceipt: @escaping (UUID) -> Void = { _ in }
    ) {
        self._store = Bindable(store)
        self._isPresented = isPresented
        self.onTapReceipt = onTapReceipt
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            content
            if hasActionablePendingRows {
                Divider()
                footer
            }
        }
        .frame(minWidth: 320, idealWidth: 400, maxWidth: 520,
               minHeight: 320, idealHeight: 480, maxHeight: 720)
        .background(.regularMaterial)
        .accessibilityLabel("Revision review")
        .accessibilityHint("Review pending track changes. Filter or search to narrow. Tap a resolved row's receipt id to open the full record.")
    }

    private var hasActionablePendingRows: Bool {
        store.visible.contains { $0.status.isPending }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.and.ellipsis.rectangle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Revisions")
                    .font(.headline)
                Text(store.headerSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close revision review")
            .accessibilityHint("Closes the panel. Pending revisions are unaffected.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            searchField
            if !store.authors.isEmpty {
                authorFilterRow
            }
            pendingOnlyChip
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar.opacity(0.5))
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("filter by author or excerpt", text: $store.searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .accessibilityLabel("Filter revisions by author or excerpt")
            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
    }

    private var authorFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(store.authors, id: \.self) { author in
                    AuthorFilterChip(
                        author: author,
                        isOn: store.authorFilter.contains(author)
                    ) {
                        toggleAuthor(author)
                    }
                }
            }
        }
    }

    private func toggleAuthor(_ author: String) {
        if store.authorFilter.contains(author) {
            store.authorFilter.remove(author)
        } else {
            store.authorFilter.insert(author)
        }
    }

    /// Same chip shape as `AuthorFilterChip`, not a platform `Toggle`:
    /// `ToggleStyle.checkbox` is macOS-only and this file compiles into
    /// both `TesseraStudioMac` and `TesseraStudioiOS` (see this
    /// package's platform list) - a plain chip button is the one shape
    /// that needs no `#if os()` guard.
    private var pendingOnlyChip: some View {
        Button {
            store.pendingOnlyFilter.toggle()
        } label: {
            Text("Pending only")
                .font(.caption2.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(store.pendingOnlyFilter ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.05))
                )
                .foregroundStyle(store.pendingOnlyFilter ? Color.accentColor : .secondary)
                .overlay(
                    Capsule().stroke(store.pendingOnlyFilter ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.20),
                                     lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show pending revisions only")
        .accessibilityAddTraits(store.pendingOnlyFilter ? .isSelected : [])
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.rows.isEmpty, store.resolvedLog.isEmpty {
            emptyState
        } else if store.visible.isEmpty {
            noMatchesState
        } else {
            list
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "checkmark.seal")
                .symbolRenderingMode(.hierarchical)
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No pending revisions")
                .font(.callout.bold())
            Text("Track changes in this document will appear here for review, grouped one row per revision.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
    }

    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .symbolRenderingMode(.hierarchical)
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No matches")
                .font(.callout.bold())
            Text("No revisions match the current filter + search. Clear them to see the full list.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(store.visible) { row in
                    RevisionReviewRow(
                        row: row,
                        onAccept: { Task { await store.accept(row.id) } },
                        onReject: { Task { await store.reject(row.id) } },
                        onTapReceipt: onTapReceipt
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Footer (accept-all / reject-all)

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Accept all") { Task { await store.acceptAllVisible() } }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Reject all") { Task { await store.rejectAllVisible() } }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

// MARK: - RevisionReviewRow

/// One row in the panel: a compact `field: value | field: value` line
/// (author/kind/time) plus the excerpt, matching the audit log's chip
/// vocabulary shape (`ActionAuditLogRow`) without literally reusing its
/// tier/risk/outcome field set - revisions have no tier or risk. Pending
/// rows show Accept/Reject; resolved rows (this session's trailing log
/// only - see `RevisionReviewStore`) show a receipt-id chip when one was
/// found.
public struct RevisionReviewRow: View {
    public let row: RevisionRow
    public let onAccept: () -> Void
    public let onReject: () -> Void
    public let onTapReceipt: (UUID) -> Void

    public init(
        row: RevisionRow,
        onAccept: @escaping () -> Void,
        onReject: @escaping () -> Void,
        onTapReceipt: @escaping (UUID) -> Void = { _ in }
    ) {
        self.row = row
        self.onAccept = onAccept
        self.onReject = onReject
        self.onTapReceipt = onTapReceipt
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 6) {
            kindGlyph
            VStack(alignment: .leading, spacing: 2) {
                Text(headerLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !row.excerpt.isEmpty {
                    Text(row.excerpt)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(tint.opacity(0.07))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headerLine + (row.excerpt.isEmpty ? "" : ", " + row.excerpt))
    }

    private var headerLine: String {
        var fields = ["kind: \(row.kind.shortLabel)"]
        if let author = row.author, !author.isEmpty { fields.append("author: \(author)") }
        if let timestamp = row.timestamp { fields.append("time: \(Self.timeFormatter.string(from: timestamp))") }
        return fields.joined(separator: " | ")
    }

    private var kindGlyph: some View {
        Image(systemName: kindSymbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .font(.caption)
            .frame(width: 16)
    }

    private var kindSymbol: String {
        switch row.kind {
        case .insertion: return "plus.circle"
        case .deletion: return "minus.circle"
        case .moved: return "arrow.left.arrow.right.circle"
        }
    }

    private var tint: Color {
        switch row.kind {
        case .insertion: return .green
        case .deletion: return .red
        case .moved: return .blue
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.status {
        case .pending:
            HStack(spacing: 6) {
                Button("Accept", action: onAccept)
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .accessibilityLabel("Accept this revision")
                Button("Reject", action: onReject)
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .accessibilityLabel("Reject this revision")
            }
        case .resolved(let direction, let receiptID, _):
            HStack(spacing: 4) {
                Text(direction == .accept ? "accepted" : "rejected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let receiptID {
                    let short = String(receiptID.uuidString.prefix(8))
                    Button(action: { onTapReceipt(receiptID) }) {
                        Text("receipt: \(short)...")
                            .font(.caption2.monospaced())
                            .foregroundStyle(Color.accentColor)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open receipt \(short)")
                }
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

// MARK: - AuthorFilterChip

/// A small author chip used in the panel's filter bar. Same shape as
/// `ActionAuditLogPanel`'s `TierFilterChip`/`OutcomeFilterChip`.
private struct AuthorFilterChip: View {
    let author: String
    let isOn: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(author)
                .font(.caption2.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(isOn ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.05))
                )
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .overlay(
                    Capsule().stroke(isOn ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.20),
                                     lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter by author \(author)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - RevisionReviewTrigger

/// A button the host view can drop into its surface to toggle the
/// panel. Mirrors `ActionAuditLogTrigger`.
public struct RevisionReviewTrigger: View {
    @Bindable public var store: RevisionReviewStore
    @Binding public var isPresented: Bool

    public init(store: RevisionReviewStore, isPresented: Binding<Bool>) {
        self._store = Bindable(store)
        self._isPresented = isPresented
    }

    public var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "pencil.and.ellipsis.rectangle")
                    .symbolRenderingMode(.hierarchical)
                    .font(.caption2)
                Text(labelText)
                    .font(.caption2.bold())
                    .monospacedDigit()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.secondary.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open revision review")
        .accessibilityHint("Pulls up the pending track-changes for this document.")
    }

    private var labelText: String {
        let count = _store.wrappedValue.rows.count
        if count == 0 { return "Revisions" }
        return "Revisions (\(count))"
    }
}

#if canImport(AppKit)
import AppKit

// MARK: - RevisionReviewPanelPresenter (macOS only)

/// The AppKit-side presenter. Owns the `NSPanel` (a non-activating
/// utility panel that does not steal focus) and the shared
/// ``RevisionReviewStore``. Mirrors `ActionAuditLogPanelPresenter`
/// exactly - see that type's doc comments for the non-activating-panel
/// and positioning rationale, which apply unchanged here.
@MainActor
public final class RevisionReviewPanelPresenter: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    public let store: RevisionReviewStore
    private let onTapReceipt: (UUID) -> Void

    public init(
        store: RevisionReviewStore,
        onTapReceipt: @escaping (UUID) -> Void = { _ in }
    ) {
        self.store = store
        self.onTapReceipt = onTapReceipt
    }

    /// Show the panel. Idempotent: re-presenting when already visible
    /// just brings it to the front.
    public func present() {
        if let window = window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = RevisionReviewPanel(
            store: store,
            isPresented: Binding(
                get: { [weak self] in self?.window?.isVisible ?? false },
                set: { [weak self] newValue in
                    if !newValue { self?.dismiss() }
                }
            ),
            onTapReceipt: onTapReceipt
        )
        let hosting = NSHostingController(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 480),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Revisions"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.contentViewController = hosting
        panel.delegate = self
        positionNearMainWindow(panel)

        self.window = panel
        panel.makeKeyAndOrderFront(nil)
    }

    /// Close the panel. Safe to call when not visible.
    public func dismiss() {
        window?.close()
        window = nil
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        if let window = self.window, notification.object as? NSWindow === window {
            self.window = nil
        }
    }

    // MARK: - Layout

    private func positionNearMainWindow(_ panel: NSPanel) {
        guard let main = NSApp.keyWindow ?? NSApp.mainWindow else {
            panel.center()
            return
        }
        let mainFrame = main.frame
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: mainFrame.maxX + 12,
            y: mainFrame.midY - panelSize.height / 2
        )
        let candidate = NSRect(origin: origin, size: panelSize)
        if let screen = main.screen,
           screen.visibleFrame.contains(candidate) {
            panel.setFrameOrigin(origin)
        } else {
            panel.setFrameOrigin(NSPoint(
                x: mainFrame.maxX + 24,
                y: mainFrame.maxY - panelSize.height - 24
            ))
        }
    }
}
#endif
