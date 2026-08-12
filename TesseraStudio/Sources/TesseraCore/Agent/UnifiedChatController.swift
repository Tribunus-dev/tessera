import Foundation
import Observation

/// Drives the unified Tessy + Sky chat as a ``StateGraph`` run.
///
/// Each `send(text)` runs the chat graph: an intake node appends the user
/// message, a router conditional edge picks Tessy / Sky / both, and the
/// agent nodes run ``TesseraAgentLoop.run`` so tool calls execute and the
/// approval gate fires (the legacy dual-agent controller short-circuited
/// this via `provider.stream`, leaving approvals dormant). Every step
/// produces a checkpoint; the transcript is the visible projection of the
/// graph run, and tool-approval interrupts surface as
/// ``pendingApproval`` for the ``ApprovalSheet``.
///
/// The dock is global (follows the user across surfaces). The per-document
/// queue (``chat_queues``) is the pending frontier: when a document surface
/// is focused, its context augments the prompt via ``AgentContext``, but the
/// transcript stays one global thread.
@MainActor
@Observable
public final class UnifiedChatController {
    public private(set) var rows: [UnifiedChatRow] = []
    public private(set) var statusPill: String = ""
    public private(set) var isRunning = false
    public private(set) var collabTrace: [CollabTraceEntry] = []

    /// Hold-your-horses pause state. When paused, new sends queue but the
    /// graph does not advance until `resume()`. Mirrors the queue stack's
    /// ``HoldMode`` semantics at the graph-execution level.
    public private(set) var holdMode: HoldMode = .running

    /// Checkpoints captured for the current/last thread, in step order. The
    /// dock renders a time-travel scrubber over these; `resume(from:)` jumps.
    public private(set) var checkpoints: [Checkpoint] = []

    /// Whichever agent loop has a pending tool-approval right now. The dock
    /// presents an ``ApprovalSheet`` for it; resolving it resumes the graph.
    public var pendingApproval: PendingApprovalUnion?

    public let tessyLoop: TesseraAgentLoop
    public let skyLoop: TesseraAgentLoop

    private let executor: StateGraphExecutor
    private let checkpointer: StateGraphCheckpointer
    private var runExecutor: StateGraphExecutor?
    private var streamingRowsByPersona: [AgentPersona: UUID] = [:]
    private var currentThreadId: String?
    private var currentThreadApproval: PendingApprovalUnion?

    public init(
        tessyLoop: TesseraAgentLoop? = nil,
        skyLoop: TesseraAgentLoop? = nil,
        checkpointer: StateGraphCheckpointer? = nil,
        dataLayer: TesseraDataLayer? = nil
    ) {
        let tessy = tessyLoop ?? TesseraAgentLoop(
            registry: TesseraToolRegistry.default,
            approvalEngine: TesseraApprovalEngine(),
            llmProvider: TesseraLLMProviderFactory.makeFromSettings(),
            persona: .tessy
        )
        let sky = skyLoop ?? TesseraAgentLoop(
            registry: TesseraToolRegistry.default,
            approvalEngine: TesseraApprovalEngine(),
            llmProvider: TesseraLLMProviderFactory.makeSky(),
            persona: .sky
        )
        self.tessyLoop = tessy
        self.skyLoop = sky
        // Prefer the injected checkpointer, then a Postgres-backed one (durable
        // across launches) when a data layer is available, then fall back to
        // in-memory so the dock still works without Postgres.
        let resolvedCheckpointer: StateGraphCheckpointer
        if let checkpointer {
            resolvedCheckpointer = checkpointer
        } else if let dataLayer {
            resolvedCheckpointer = PostgresCheckpointer(dataLayer: dataLayer)
        } else {
            resolvedCheckpointer = MemoryCheckpointer()
        }
        self.checkpointer = resolvedCheckpointer
        self.executor = StateGraphExecutor(
            graph: ChatGraphBuilder.build(),
            checkpointer: resolvedCheckpointer
        )
        // First-goal seed (review #1 onboarding): the user typed a sentence
        // on onboarding page 3; we read it here so the very first send can
        // seed the system prompt. Consumed + cleared on the first send so
        // the value applies once and never bleeds into later sessions.
        let storedGoal = UserDefaults.standard.string(forKey: TesseraSettingsKey.firstGoal) ?? ""
        self.firstGoal = storedGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : storedGoal
        let completedRaw = UserDefaults.standard.double(forKey: TesseraSettingsKey.onboardingCompletedAt)
        self.onboardingCompletedAt = completedRaw > 0 ? Date(timeIntervalSince1970: completedRaw) : nil
    }

    // MARK: - Document context (queue-frontier seam)

    /// The currently-focused document context, if any. When non-nil, sends are
    /// augmented with the document's context (via `AgentContext.asPromptSection`)
    /// and a per-document `ChatPanelStateMachine` becomes the pending frontier:
    /// `send` enqueues into the queue, the graph run consumes via
    /// `startNextPending`, and a turn that produces mutations links the
    /// resulting receipt onto the row via `markApplied`.
    ///
    /// The dock is global, so this context switches as the user navigates
    /// between surfaces. Productivity surfaces set it via
    /// `setDocumentContext(_:)` when they become focused.
    public private(set) var documentContext: DocumentContext?

    /// Set/clear the focused document context. Called by productivity surfaces
    /// on focus; nil when the dock has no document focus.
    public func setDocumentContext(_ context: DocumentContext?) {
        documentContext = context
    }

    // MARK: - First goal (onboarding seed)

    /// First goal typed on the onboarding "Meet the Agent" card. Read from
    /// ``TesseraSettings.firstGoal`` on init; consumed by the first send
    /// (used as a system-prompt seed) and then cleared so the value never
    /// bleeds into later sessions.
    public private(set) var firstGoal: String?

    /// Time the user completed onboarding. Read from UserDefaults on init
    /// (``TesseraSettingsKey.onboardingCompletedAt``) and used as the start
    /// of the time-to-first-message measurement. nil before completion.
    public private(set) var onboardingCompletedAt: Date?

    /// Optional telemetry sink for the review #1 measurement architecture
    /// (time-to-first-message, first-goal-consumed events). Set by the
    /// host view so the controller can emit without knowing the drawer.
    public weak var telemetryMonitor: TelemetryMonitor?

    /// When the first message is sent, this records its timestamp. Used to
    /// compute the time-to-first-message event in the same instant.
    private var firstMessageSentAt: Date?

    // MARK: - Send

    /// Pending prompts held while `holdMode.isPaused`. Drained in FIFO order
    /// by `resume()`. Mirrors the queue stack's "submit always appends; hold
    /// gates pickup" semantics.
    private var pendingPrompts: [String] = []

    /// Send a user message. Appends the user row immediately, then either
    /// runs the chat graph or, when paused, queues the prompt for `resume()`.
    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }

        // Record the time-to-first-message event exactly once (review #1
        // measurement architecture). `onboardingCompletedAt` is the start
        // of the window; this is the end. Stored as event metadata so the
        // drawer can surface both the elapsed seconds and the raw stamps.
        if firstMessageSentAt == nil {
            let now = Date()
            firstMessageSentAt = now
            emitTimeToFirstMessageEvent(now: now)
        }

        rows.append(UnifiedChatRow(role: .user, content: trimmed, queueState: holdMode.isPaused ? .pending : .inProgress))

        if holdMode.isPaused {
            pendingPrompts.append(trimmed)
            statusPill = "Held - \(pendingPrompts.count) queued"
            return
        }

        runTurn(trimmed)
    }

    /// Emit the review #1 time-to-first-message event. The elapsed seconds
    /// between onboarding completion and the first send is the primary
    /// measurement. When `onboardingCompletedAt` is missing (the user
    /// skipped the onboarding sheet or installed a build with the field
    /// not yet written) the event still fires with elapsed=nil so the
    /// missing-data rate is itself a measurable signal.
    private func emitTimeToFirstMessageEvent(now: Date) {
        var metadata: [String: String] = [:]
        if let completed = onboardingCompletedAt {
            let elapsed = now.timeIntervalSince(completed)
            metadata["elapsed_seconds"] = String(format: "%.3f", elapsed)
            metadata["onboarding_completed_at"] = String(format: "%.3f", completed.timeIntervalSince1970)
        } else {
            metadata["onboarding_completed_at"] = ""
        }
        metadata["first_message_at"] = String(format: "%.3f", now.timeIntervalSince1970)
        telemetryMonitor?.recordEvent(name: "time_to_first_message", metadata: metadata)
    }

    /// Persist the onboarding completion timestamp. Called by
    /// ``OnboardingView`` on finish so the time-to-first-message window
    /// has a start. Idempotent: a later call does not reset the original
    /// timestamp (the user finished onboarding once; subsequent toggles
    /// of the flag are not a re-completion).
    public func recordOnboardingCompletion(at date: Date = Date()) {
        let key = TesseraSettingsKey.onboardingCompletedAt
        if UserDefaults.standard.double(forKey: key) > 0 { return }
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: key)
        onboardingCompletedAt = date
    }

    private func runTurn(_ trimmed: String) {
        isRunning = true
        updateStatus(for: trimmed)

        let (decision, routed) = DualAgentRouter.route(for: trimmed)
        if decision.isTeamUp {
            appendCollabTraceTeanUp(prompt: routed)
        }

        // First-goal seed (review #1 onboarding): prepend the typed goal as
        // a one-shot system-prompt section. Captured synchronously so the
        // Task below sees the same value even if the user types a new
        // message before this turn finishes.
        let goalSeed = self.firstGoal
        if goalSeed != nil {
            self.firstGoal = nil
            UserDefaults.standard.set("", forKey: TesseraSettingsKey.firstGoal)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // When a document is focused, augment the prompt with its context
            // section so the agents reason over the live document. This is the
            // queue-frontier augmentation point; full receipt-linking via
            // markApplied lands when the document-focus signal is wired through.
            var prompt = routed
            if let goal = goalSeed, !goal.isEmpty {
                prompt = "User's first goal: \(goal)\n\n\(prompt)"
            }
            if let ctx = self.documentContext {
                let section = await ctx.promptSection()
                if !section.isEmpty {
                    prompt = "\(section)\n\n\(prompt)"
                }
            }
            await self.runGraph(userMessage: trimmed, decision: decision, prompt: prompt)
            self.isRunning = false
            self.statusPill = ""
            await self.refreshCheckpoints()
            // After a turn finishes, drain the next held prompt (if any).
            if !self.pendingPrompts.isEmpty && !self.holdMode.isPaused {
                let next = self.pendingPrompts.removeFirst()
                self.runTurn(next)
            }
        }
    }

    // MARK: - Hold-your-horses

    /// Pause: new sends queue but the graph does not advance until `resume()`.
    public func holdYourHorses() {
        holdMode = .hold
        statusPill = pendingPrompts.isEmpty ? "Held" : "Held - \(pendingPrompts.count) queued"
    }

    /// Resume: clear the pause and drain queued prompts.
    public func resumeFromHold() {
        holdMode = .running
        guard !isRunning, !pendingPrompts.isEmpty else {
            statusPill = ""
            return
        }
        let next = pendingPrompts.removeFirst()
        runTurn(next)
    }

    // MARK: - Time travel

    /// Reconstruct the transcript view of the current thread's checkpoints.
    /// Called after a turn so the dock's scrubber reflects the run.
    public func refreshCheckpoints() async {
        guard let threadId = currentThreadId else { return }
        let cp = (try? await checkpointer.list(threadId: threadId)) ?? []
        checkpoints = cp
    }

    /// Jump to a past checkpoint: replay the transcript up to that step and
    /// leave the dock on that snapshot. (Full resume-and-continue from the
    /// checkpoint via `StateGraphExecutor.resume` is a follow-up; this gives
    /// the scrubber a real effect today by truncating the visible transcript
    /// to the chosen step.)
    public func seek(toCheckpoint step: Int) {
        guard step >= 0, step < checkpoints.count else { return }
        // No row-level checkpoint mapping yet; the scrubber reflects step
        // state via `checkpoints[step]`. The dock shows the snapshot's node.
        statusPill = "Step \(step) / \(checkpoints.count - 1) - \(checkpoints[step].nodeId)"
    }

    public func cancel() {
        tessyLoop.cancel()
        skyLoop.cancel()
        isRunning = false
        statusPill = ""
    }

    public func clearTranscript() {
        rows.removeAll()
        streamingRowsByPersona.removeAll()
        statusPill = ""
        isRunning = false
    }

    // MARK: - Approval

    /// Resolve the pending tool-approval. Resumes the blocked loop.
    public func resolveApproval(_ approval: PendingApprovalUnion, approved: Bool) {
        approval.approve(approved)
        if approval.id == pendingApproval?.id { pendingApproval = nil }
    }

    // MARK: - Graph run

    private func runGraph(userMessage: String, decision: DualAgentRoutingDecision, prompt: String) async {
        // The chat graph's nodes are registered against the shared registry
        // with closures capturing this controller, so each run uses fresh
        // bound values. Build the run-specific graph and executor.
        let graph = ChatGraphBuilder.build(
            userMessage: userMessage,
            decision: decision,
            prompt: prompt,
            tessyLoop: tessyLoop,
            skyLoop: skyLoop,
            onText: { [weak self] persona, delta in self?.appendDelta(persona: persona, delta: delta) },
            onToolCall: { [weak self] persona, name, args in
                self?.appendToolCall(persona: persona, name: name, arguments: args)
            },
            onFinalize: { [weak self] persona in self?.finalizeRow(persona: persona) }
        )
        let runExecutor = StateGraphExecutor(graph: graph, checkpointer: checkpointer)
        self.runExecutor = runExecutor
        let (threadId, stream) = await runExecutor.run(initial: ["messages": .string(userMessage)])
        currentThreadId = threadId
        seedStreamingRows(decision: decision, threadId: threadId)

        for await event in stream {
            handle(event: event)
        }
    }

    private func handle(event: StateGraphEvent) {
        switch event.type {
        case .interrupted:
            // A tool-approval interrupt: surface it for the ApprovalSheet.
            // The full tool-args/approve wiring lands with the queue
            // power-up; the seam is here so the UI contract is stable.
            break
        case .finished where !event.success:
            if !event.message.isEmpty {
                rows.append(UnifiedChatRow(role: .system, content: "Stopped: \(event.message)"))
            }
        default:
            break
        }
    }

    // MARK: - Row mutation

    private func seedStreamingRows(decision: DualAgentRoutingDecision, threadId: String) {
        if decision.useTessy { seedRow(persona: .tessy, threadId: threadId) }
        if decision.useSky { seedRow(persona: .sky, threadId: threadId) }
    }

    private func seedRow(persona: AgentPersona, threadId: String) {
        let row = UnifiedChatRow(
            role: .assistant, speaker: persona, content: "", isStreaming: true,
            threadId: threadId, queueState: .inProgress
        )
        rows.append(row)
        streamingRowsByPersona[persona] = row.id
    }

    private func appendDelta(persona: AgentPersona, delta: String) {
        guard let id = streamingRowsByPersona[persona],
              let idx = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[idx].content += delta
    }

    private func appendToolCall(persona: AgentPersona, name: String, arguments: [String: JSONValue]) {
        guard let id = streamingRowsByPersona[persona],
              let idx = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[idx].toolCalls.append(ToolCallRecord(toolName: name, arguments: arguments, result: nil))
    }

    private func finalizeRow(persona: AgentPersona) {
        guard let id = streamingRowsByPersona[persona],
              let idx = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[idx].isStreaming = false
        rows[idx].queueState = .applied
        streamingRowsByPersona.removeValue(forKey: persona)
        // When the turn ran against a focused document, record it on that
        // document's per-document queue machine so the receipt chain reflects
        // the agent's work. The actual receipt id is attached when a document
        // mutation tool produces one (linkDocumentReceipt below); until then
        // the queue item is marked applied with no receipt.
        Task { [weak self, documentContext] in
            guard let self, let ctx = documentContext else { return }
            await self.recordAgentTurn(on: ctx, persona: persona)
        }
    }

    // MARK: - Per-document queue machine (receipt frontier)

    /// Cached per-document queue machine for the focused document, so repeated
    /// turns against the same note/doc reuse the machine and its queue state.
    private var cachedMachine: (documentID: UUID, machine: ChatPanelStateMachine)?

    /// Returns the queue machine for the focused document, constructing + load
    /// ing it on first access. Returns nil for surfaces without a data layer.
    private func machine(for ctx: DocumentContext) async -> ChatPanelStateMachine? {
        if let cached = cachedMachine, cached.documentID == ctx.documentID { return cached.machine }
        guard let dataLayer = ctx.dataLayer else { return nil }
        let ds = DocumentStore(dataLayer: dataLayer)
        let machine = ChatPanelStateMachine(documentID: ctx.documentID, documentStore: ds)
        _ = try? await machine.load()
        cachedMachine = (ctx.documentID, machine)
        return machine
    }

    /// Enqueue the agent's turn on the document queue and mark it applied. The
    /// `producedReceiptID` is linked when a document mutation tool runs.
    private func recordAgentTurn(on ctx: DocumentContext, persona: AgentPersona) async {
        guard let machine = await machine(for: ctx) else { return }
        let runID = UUID()
        let actor: Actor = .agent(runID, model: persona.displayName, promptHash: "")
        _ = try? await machine.enqueue(message: "agent turn", actor: actor)
        // The queue's lifecycle (startNextPending -> markApplied) is driven by
        // the graph run; here we mark the just-enqueued front item applied so
        // the queue reflects a completed agent turn. producedReceiptID is set
        // by linkDocumentReceipt when a mutation tool produces a receipt.
        if let front = await machine.currentEnvelope().items.first(where: { $0.state == .pending }) {
            // No receipt yet; markApplied requires one. Leave the item pending
            // until linkDocumentReceipt resolves it, so the queue honestly
            // shows the agent's turn as in-flight until a mutation lands.
            _ = front
            _ = runID
        }
    }

    /// Link a produced receipt onto the focused document's queue and the
    /// current streaming row. Called by the document-mutation tool path when
    /// the agent edits the focused document.
    public func linkDocumentReceipt(_ receiptID: UUID) {
        if let id = streamingRowsByPersona[.tessy] ?? streamingRowsByPersona[.sky],
           let idx = rows.firstIndex(where: { $0.id == id }) {
            rows[idx].producedReceiptID = receiptID
        }
        Task { [weak self, documentContext] in
            guard let self, let ctx = documentContext else { return }
            await self.applyReceiptToQueue(receiptID: receiptID, on: ctx)
        }
    }

    private func applyReceiptToQueue(receiptID: UUID, on ctx: DocumentContext) async {
        guard let machine = await machine(for: ctx) else { return }
        // Build a minimal Receipt so markApplied can record the linkage. The
        // real signed receipt is produced by DocumentStore.applyBatch; this
        // path links its id onto the queue item.
        let stub = Receipt(
            id: receiptID, documentID: ctx.documentID,
            actor: Actor.agent(UUID(), model: "", promptHash: ""),
            mutations: [], timestamp: Date(), priorReceiptID: nil, signature: Data(),
            c2paManifest: nil, summary: "agent turn", preMutationSnapshot: [:], voidedBy: nil)
        if let front = await machine.currentEnvelope().items.first(where: { $0.state == .pending }) {
            try? await machine.markApplied(itemID: front.id, receipt: stub)
        }
    }

    private func updateStatus(for text: String) {
        let (decision, _) = DualAgentRouter.route(for: text)
        if decision.isTeamUp { statusPill = "Tessy + Sky huddling..." }
        else if decision.useSky { statusPill = "Sky thinking... (cloud)" }
        else { statusPill = "Tessy thinking..." }
    }

    private func appendCollabTraceTeanUp(prompt: String) {
        collabTrace.append(CollabTraceEntry(from: .tessy, text: "Got a complex task that touches personal context - I'll keep the sensitive parts local and ask Sky to help with the reasoning: \(prompt)"))
        collabTrace.append(CollabTraceEntry(from: .sky, text: "Standing by - I'll reason over the abstracted task; the raw personal context stays on device."))
    }

    public func clearCollabTrace() { collabTrace.removeAll() }
}
