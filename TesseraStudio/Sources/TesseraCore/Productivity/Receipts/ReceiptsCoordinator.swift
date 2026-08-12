import Foundation

// MARK: - ReceiptsFocus

/// The current focus of the receipts drawer (per spec section 7.3
/// + the cross-surface coordination in section 15). The focus is
/// the receipt (or graph entity) the drawer is currently
/// showing in its detail view. The chat panel reads the
/// focus to decide whether to highlight the corresponding
/// applied item.
public enum ReceiptsFocus: Sendable, Hashable, Codable {
    /// No focus. The drawer is showing the chain list
    /// without a selected receipt.
    case none
    /// A receipt is focused. The id is the receipt's own
    /// id (which matches a `ChatQueueItem.producedReceiptID`
    /// for the corresponding chat-panel row).
    case receipt(UUID)
    /// A graph entity is focused. This is the Phase 6 hook
    /// -- the Graph view takes over from the drawer.
    case graphEntity(UUID)

    public var receiptID: UUID? {
        if case .receipt(let id) = self { return id }
        return nil
    }

    public var graphEntityID: UUID? {
        if case .graphEntity(let id) = self { return id }
        return nil
    }
}

// MARK: - ReceiptsCoordinator

/// Cross-surface navigation state for the receipts drawer
/// + chat panel + (eventually) Graph view. The coordinator
/// is an `actor` for the cross-surface state, with an
/// `ObservableObject` companion (`ReceiptsCoordinatorBridge`)
/// that SwiftUI views observe on the main actor.
///
/// **Three navigation paths:**
/// - **Chat -> drawer.** The chat panel's "applied" rows tap
///   a receipt chip; the chip fires `openReceiptInDrawer`,
///   the drawer's detail view appears.
/// - **Drawer -> chat.** The drawer's detail view has a
///   "Show in chat" button that scrolls the chat panel to
///   the corresponding applied item.
/// - **Drawer -> graph.** The drawer's detail view has a
///   "Show in graph" button that hands off to the Phase 6
///   Graph view (placeholder for now; the navigation
///   surface is wired but the Graph view itself is a later
///   phase).
///
/// The coordinator is also the registry the chat panel
/// uses to look up which chat item corresponds to a given
/// receipt (the `chatItem(forReceipt:)` path). This is a
/// per-document lookup; the coordinator is fed a lookup
/// function from the host view.
///
/// **Receipt stream (Wave 3B, agent-ux-fatigue review #5).**
/// The coordinator also publishes an `AsyncStream<Receipt>`
/// that emits each new receipt registered via
/// ``register(receipt:)``. This replaces the 200ms polling
/// in ``ReceiptsCoordinatorBridge`` with a push-based
/// observation. The stream is broadcast: each call to
/// ``receiptStream()`` returns a new stream subscribed to
/// the same event source. Back-pressure is bounded per
/// subscriber via `.bufferingNewest(_:)`; drops are
/// counted and exposed via ``droppedReceiptCount``.
public actor ReceiptsCoordinator {

    // MARK: - State

    private var focus: ReceiptsFocus = .none
    private var drawerVisible: Bool = true
    private var scrollTarget: UUID?  // chat item id
    private var openRequest: OpenRequest?

    /// A pending "open" request that the host view will
    /// observe. The request is set when the user taps a
    /// receipt chip in the chat panel; the drawer's
    /// container view consumes the request and clears it
    /// once the drawer has shown the receipt.
    public struct OpenRequest: Sendable, Hashable {
        public let receiptID: UUID
        public let fromChatItemID: UUID?
        public let timestamp: Date
        public init(receiptID: UUID, fromChatItemID: UUID?, timestamp: Date = Date()) {
            self.receiptID = receiptID
            self.fromChatItemID = fromChatItemID
            self.timestamp = timestamp
        }
    }

    public init() {}

    // MARK: - Drawer visibility

    public var isDrawerVisible: Bool { drawerVisible }

    public func setDrawerVisible(_ visible: Bool) {
        drawerVisible = visible
    }

    public func toggleDrawerVisibility() {
        drawerVisible.toggle()
    }

    // MARK: - Open / scroll / focus

    /// Open a receipt in the drawer. Called by the chat
    /// panel when the user taps a chip. The drawer's
    /// container view observes `pendingOpenRequest()` to
    /// know when to show the receipt.
    public func openReceiptInDrawer(
        _ receiptID: UUID,
        fromChatItem itemID: UUID? = nil
    ) {
        focus = .receipt(receiptID)
        drawerVisible = true
        openRequest = OpenRequest(
            receiptID: receiptID,
            fromChatItemID: itemID
        )
    }

    /// Scroll the chat panel to the chat item that
    /// corresponds to a given receipt id. The host view
    /// is expected to provide a `chatItemLookup` so the
    /// coordinator can resolve the receipt id to a chat
    /// item id (the chat item's `producedReceiptID`
    /// matches the receipt id).
    public func showInChat(receiptID: UUID) async -> UUID? {
        // The host view is expected to wire the lookup; we
        // record the request and the host resolves it.
        // The lookup is async because the chat panel's
        // view-model is `@MainActor`-isolated.
        if let lookup = chatItemLookup, let resolved = await lookup(receiptID) {
            scrollTarget = resolved
            return resolved
        }
        scrollTarget = nil
        return nil
    }

    /// Hand off to the Graph view (Phase 6). The drawer
    /// container observes the focus and navigates.
    public func showInGraph(entityID: UUID) {
        focus = .graphEntity(entityID)
    }

    /// Clear the focus (e.g., when the drawer is closed).
    public func clearFocus() {
        focus = .none
        openRequest = nil
    }

    /// The current focus. The drawer's detail view reads
    /// this to know which receipt to show.
    public var currentFocus: ReceiptsFocus { focus }

    /// The pending open request. The drawer's container
    /// view consumes this when it appears.
    public func consumeOpenRequest() -> OpenRequest? {
        defer { openRequest = nil }
        return openRequest
    }

    /// The current scroll target. The chat panel reads
    /// this to know which item to scroll to.
    public var currentScrollTarget: UUID? { scrollTarget }

    /// Clear the scroll target. Called by the chat panel
    /// after it has scrolled.
    public func clearScrollTarget() {
        scrollTarget = nil
    }

    // MARK: - Lookup hook

    /// A function the host view provides to map a receipt
    /// id to the corresponding chat item id. The chat
    /// panel's view layer sets this on appearance and
    /// clears it on disappearance. The closure is async
    /// because the lookup may need to hop to the main
    /// actor to read the chat panel's `@Published` items.
    public var chatItemLookup: (@Sendable (UUID) async -> UUID?)?

    public func setChatItemLookup(_ lookup: (@Sendable (UUID) async -> UUID?)?) {
        chatItemLookup = lookup
    }

    // MARK: - Receipt stream (Wave 3B)

    /// Maximum number of receipts retained in the
    /// coordinator's in-memory navigation snapshot. The
    /// canonical receipt list lives in ``ReceiptExportService``;
    /// this is the cross-surface navigation view. Older
    /// receipts roll off as new ones arrive so the actor
    /// cannot grow unbounded in long sessions.
    private static let inMemoryReceiptCap: Int = 1024

    /// Per-subscriber buffer cap for the receipt stream.
    /// When a subscriber falls behind, ``.bufferingNewest``
    /// drops the oldest buffered receipt to make room for
    /// the new one. The cap is bounded so a wedged
    /// subscriber cannot OOM the process. The drop count
    /// is exposed via ``droppedReceiptCount`` as the
    /// back-pressure anti-metric.
    private static let receiptStreamBufferLimit: Int = 64

    /// In-memory navigation snapshot of the receipts that
    /// have been registered via ``register(receipt:)``.
    /// Bounded by ``inMemoryReceiptCap``.
    private var registeredReceipts: [Receipt] = []

    /// Continuations for all active ``receiptStream()``
    /// subscribers. The stream is broadcast: each
    /// ``receiptStream()`` call registers a fresh
    /// continuation; each ``register(receipt:)`` call
    /// yields to all live continuations. A continuation
    /// is removed from the table on stream termination
    /// (consumer exit, deallocation, or cancellation).
    private var receiptContinuations: [UUID: AsyncStream<Receipt>.Continuation] = [:]

    /// Number of receipts the coordinator tried to yield
    /// into a full subscriber buffer. The anti-metric for
    /// the Wave 3B move: target == 0 in normal use. Non-
    /// zero means a subscriber is slower than receipts
    /// are arriving; the oldest buffered receipt was
    /// dropped from that subscriber's view.
    private var droppedReceiptAccumulator: Int = 0

    /// Register a new receipt with the coordinator. The
    /// receipt is appended to the in-memory snapshot and
    /// broadcast to every live ``receiptStream()``
    /// subscriber. This is the new "receipt created"
    /// event source that replaces the bridge's 200ms
    /// polling. P95 latency from this call to a
    /// subscriber's `for await` resumption is bounded by
    /// the cooperative scheduler (typically << 1 ms);
    /// the test asserts the 100 ms budget.
    public func register(receipt: Receipt) {
        registeredReceipts.append(receipt)
        // Bound the in-memory list. Older receipts are
        // still available from ``ReceiptExportService``;
        // this is the cross-surface navigation view.
        if registeredReceipts.count > Self.inMemoryReceiptCap {
            registeredReceipts.removeFirst(
                registeredReceipts.count - Self.inMemoryReceiptCap
            )
        }
        // Fan out to every active subscriber. The
        // continuation's buffering policy decides
        // whether the value is enqueued or dropped.
        for continuation in receiptContinuations.values {
            let result = continuation.yield(receipt)
            if case .dropped = result {
                droppedReceiptAccumulator += 1
            }
        }
    }

    /// An `AsyncStream<Receipt>` that emits each receipt
    /// registered via ``register(receipt:)``. The stream
    /// is broadcast: each call returns a fresh stream
    /// subscribed to the same event source. Back-pressure
    /// is bounded per subscriber by
    /// ``receiptStreamBufferLimit``; older buffered
    /// receipts are dropped when the buffer is full.
    ///
    /// The stream does NOT replay history. Consumers that
    /// need the current snapshot should call
    /// ``currentReceipts()`` after subscribing.
    public nonisolated func receiptStream() -> AsyncStream<Receipt> {
        AsyncStream<Receipt>(
            bufferingPolicy: .bufferingNewest(Self.receiptStreamBufferLimit)
        ) { continuation in
            // Hop into the actor to register the
            // continuation. `AsyncStream`'s init closure
            // is synchronous, so we dispatch the
            // registration through a detached task.
            let id = UUID()
            let coordinator = self
            continuation.onTermination = { [weak coordinator] _ in
                Task { [weak coordinator] in
                    await coordinator?.removeContinuation(id)
                }
            }
            Task { [coordinator] in
                await coordinator.addContinuation(id, continuation)
            }
        }
    }

    private func addContinuation(
        _ id: UUID,
        _ continuation: AsyncStream<Receipt>.Continuation
    ) {
        receiptContinuations[id] = continuation
    }

    private func removeContinuation(_ id: UUID) {
        receiptContinuations.removeValue(forKey: id)
    }

    /// The current in-memory receipt snapshot. Bounded by
    /// ``inMemoryReceiptCap``; older receipts roll off as
    /// new ones are registered. For the canonical receipt
    /// list, use ``ReceiptExportService``.
    public func currentReceipts() -> [Receipt] {
        registeredReceipts
    }

    /// The number of receipts dropped from a subscriber's
    /// buffer due to back-pressure. The Wave 3B anti-
    /// metric: target == 0 in normal use. Non-zero means
    /// a subscriber is slower than receipts are arriving.
    public var droppedReceiptCount: Int {
        droppedReceiptAccumulator
    }
}

// MARK: - ReceiptsCoordinatorBridge

/// The SwiftUI-friendly companion to ``ReceiptsCoordinator``.
/// The coordinator is an actor; SwiftUI can't observe it
/// directly. The bridge subscribes to the coordinator's
/// `AsyncStream<Receipt>` and republishes the state as
/// `@Published` properties on every receipt arrival.
///
/// The bridge is `@MainActor` so all `@Published` updates
/// happen on the main thread.
///
/// **Lifecycle.** The host view calls `start()` on appear
/// and `stop()` on disappear. `start()` does an initial
/// re-read of the coordinator's state to capture the
/// current snapshot, then subscribes to the receipt
/// stream. Each emission triggers a re-read so the
/// `@Published` properties stay in sync with the actor.
/// The 200ms polling that this bridge used to run is
/// removed (Wave 3B, agent-ux-fatigue review #5).
@MainActor
public final class ReceiptsCoordinatorBridge: ObservableObject {

    @Published public private(set) var isDrawerVisible: Bool = true
    @Published public private(set) var focus: ReceiptsFocus = .none
    @Published public private(set) var scrollTarget: UUID?
    @Published public private(set) var pendingOpenRequest: ReceiptsCoordinator.OpenRequest?

    private let coordinator: ReceiptsCoordinator
    /// The subscription task. `nonisolated(unsafe)` so the
    /// `deinit` can cancel it when the bridge is
    /// deallocated; the bridge is `@MainActor` and all
    /// access to this property happens on the main actor
    /// (start/stop are main-actor-isolated; deinit runs on
    /// the thread that released the last strong reference,
    /// which for a SwiftUI-bound bridge is the main
    /// thread).
    private nonisolated(unsafe) var subscriptionTask: Task<Void, Never>?

    public init(coordinator: ReceiptsCoordinator) {
        self.coordinator = coordinator
    }

    deinit {
        subscriptionTask?.cancel()
    }

    /// Begin observing the coordinator. Captures the
    /// current state with a one-shot re-read, then
    /// subscribes to the coordinator's receipt stream.
    /// Each stream emission triggers another re-read so
    /// the `@Published` properties track the actor. The
    /// 200ms polling that this method used to run is
    /// removed (Wave 3B).
    public func start() async {
        guard subscriptionTask == nil else { return }
        // Prime: capture the current state on
        // subscription so the UI does not miss anything
        // that happened before the subscription was set
        // up. The stream does not replay history.
        await refresh()
        let coordinator = self.coordinator
        subscriptionTask = Task { [weak self] in
            let stream = await coordinator.receiptStream()
            for await _ in stream {
                await self?.refresh()
                if Task.isCancelled { break }
            }
        }
    }

    /// Stop observing the coordinator. Cancels the
    /// subscription task. The host view should call this
    /// on disappear to release the subscriber and its
    /// buffer.
    public func stop() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
    }

    /// Re-read the coordinator's state and republish the
    /// `@Published` properties. Called by `start()` once
    /// for the prime, by the stream subscription on each
    /// emission, and by the action-forwarding methods
    /// after each mutation. Not driven by a timer (the
    /// 200ms polling was removed in Wave 3B).
    public func refresh() async {
        let visible = await coordinator.isDrawerVisible
        let focus = await coordinator.currentFocus
        let target = await coordinator.currentScrollTarget
        let open = await coordinator.consumeOpenRequest()
        self.isDrawerVisible = visible
        self.focus = focus
        self.scrollTarget = target
        if let open { self.pendingOpenRequest = open }
    }

    // MARK: - Action forwarding

    public func toggleDrawer() async {
        await coordinator.toggleDrawerVisibility()
        await refresh()
    }

    public func openReceipt(_ receiptID: UUID, fromChatItem itemID: UUID? = nil) async {
        await coordinator.openReceiptInDrawer(receiptID, fromChatItem: itemID)
        await refresh()
    }

    public func showInChat(receiptID: UUID) async -> UUID? {
        let result = await coordinator.showInChat(receiptID: receiptID)
        await refresh()
        return result
    }

    public func showInGraph(entityID: UUID) async {
        await coordinator.showInGraph(entityID: entityID)
        await refresh()
    }

    public func clearScrollTarget() async {
        await coordinator.clearScrollTarget()
        await refresh()
    }
}
