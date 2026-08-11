import Foundation

/// A request submitted to the ``BatchScheduler``. One per agent turn.
public struct AgentRequest: Sendable {
    public let id: UUID
    public let agentId: UUID
    public let prompt: String
    public let maxTokens: Int
    public let priority: Priority
    /// If true, route to the spec engine (low-latency speculative
    /// decoding) instead of the batched engine. Falls back to the
    /// batched engine if the spec library/engine is not loaded.
    public let useSpec: Bool
    /// Telemetry top-k for spec tracing (0 = no trace; > 0 = one
    /// `llama.tessera.spec.v1` record per spec step). Ignored on the
    /// batched path.
    public let telemetryTopK: Int

    public enum Priority: Int, Sendable, Comparable {
        case background = 0
        case foreground = 1
        public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public init(
        id: UUID = UUID(),
        agentId: UUID,
        prompt: String,
        maxTokens: Int = 512,
        priority: Priority = .background,
        useSpec: Bool = false,
        telemetryTopK: Int = 0
    ) {
        self.id = id
        self.agentId = agentId
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.priority = priority
        self.useSpec = useSpec
        self.telemetryTopK = telemetryTopK
    }
}

/// Reason a request could not be started. Streamed as `.failed(reason)` to
/// the consumer so it can distinguish "rejected up front" from "finished
/// naturally".
public enum ScheduleFailure: Sendable, Equatable {
    /// The model vocabulary could not be queried (load failure, lib not
    /// loaded, etc).
    case engineUnavailable
    /// The tokenize call returned a negative count (vocab problem).
    case tokenizeFailed
    /// prompt.count + maxTokens would not fit in the context. Up-front
    /// rejection so the caller knows the prompt is too long rather than
    /// seeing the slot wedge in prefill and silently time out.
    case promptExceedsContext(promptTokens: Int, maxTokens: Int, nCtx: Int)
}

/// Events streamed back to a `submit(_:)` caller.
public enum ScheduleEvent: Sendable {
    case token(String)
    case done
    case evicted
    case failed(ScheduleFailure)
}

/// One slot in the batch pool.
struct BatchSlot {
    let id: Int
    let seqId: Int32
    var requestId: UUID?
    var maxTokens: Int
    var pos: Int32
    var generated: Int
    var state: SlotState
    var priority: AgentRequest.Priority
    var promptTokens: [Int32]
    var promptConsumed: Int
    var lastToken: Int32?
}

enum SlotState {
    case idle
    case prefill
    case decode
}

/// Multiplexes many concurrent agent requests through ONE decode loop over a
/// shared engine, advancing every ready sequence in a single `llama_decode`
/// call per tick. This is continuous batching on device.
///
/// **Dynamic batch size + batched prefill**: each tick builds a batch mixing
/// prefill tokens (multiple per slot, up to `nBatch` total) with decode
/// tokens (one per slot). Intermediate prefill tokens set `logits=false` (no
/// output) to save compute; only the last prefill token of each slot and
/// every decode token request logits. The batch is capped at `nBatch` tokens;
/// slots that don't fit wait for the next tick. Slots are served in priority
/// order (foreground first), then by slot id.
///
/// **Correct logits indexing**: uses `getLogitsIth(eng, batchPos)` (the safe
/// per-batch-position accessor) so mixed-logits batches index correctly.
/// Using the flat logits buffer with `i * nVocab` is wrong whenever any
/// token in the batch has `logits=false`.
///
/// **Priority preemption**: a foreground request that finds all slots busy
/// evicts the lowest-priority background slot (clears its KV, re-queues it).
public actor BatchScheduler {
    private let engine: CLlamaEngine
    private let maxSlots: Int
    private var slots: [BatchSlot]
    private var pending: [AgentRequest] = []
    private var streams: [UUID: AsyncStream<ScheduleEvent>.Continuation] = [:]
    private var tickTask: Task<Void, Never>?
    private var stopped = false
    /// Optional spec engine for `useSpec=true` foreground requests.
    /// nil = no spec library loaded; spec-routed requests fall back to the
    /// batched engine.
    private let specEngine: CLlamaSpecEngine?
    /// FIFO of spec-routed request IDs waiting for the spec engine.
    /// The spec engine is single-sequence; only one generation runs at
    /// a time, so additional requests are queued here. Off-actor via
    /// the `CLlamaSpecEngineImpl`'s serial queue; this list is just the
    /// observable wait queue.
    private var specPending: [UUID] = []

    public init(engine: CLlamaEngine, specEngine: CLlamaSpecEngine? = nil, maxSlots: Int = 4) {
        self.engine = engine
        self.specEngine = specEngine
        self.maxSlots = max(1, min(maxSlots, 8))
        self.slots = (0..<self.maxSlots).map {
            BatchSlot(id: $0, seqId: Int32($0), requestId: nil, maxTokens: 0, pos: 0,
                      generated: 0, state: .idle, priority: .background,
                      promptTokens: [], promptConsumed: 0, lastToken: nil)
        }
    }

    deinit {
        stopped = true
        tickTask?.cancel()
    }

    public func submit(_ req: AgentRequest) -> AsyncStream<ScheduleEvent> {
        let stream = AsyncStream { continuation in
            self.streams[req.id] = continuation
        }
        Task { await self.enqueue(req) }
        return stream
    }

    public func cancel(requestId: UUID) async {
        if let idx = slots.firstIndex(where: { $0.requestId == requestId }) {
            engine.slotClear(slots[idx].seqId)
            slots[idx].requestId = nil
            slots[idx].state = .idle
            slots[idx].pos = 0
            slots[idx].generated = 0
            slots[idx].promptTokens = []
            slots[idx].promptConsumed = 0
            slots[idx].lastToken = nil
        }
        // Yield .evicted but do NOT finish the stream. Finishing drops any
        // events still in the buffer for iterators that haven't started
        // yet, which races with consumers that subscribe after the cancel
        // call. Leaving the stream open lets the .evicted event be
        // delivered to a fresh iterator; the consumer breaks on the event
        // and deallocates the stream.
        if let s = streams.removeValue(forKey: requestId) {
            s.yield(.evicted)
        }
        pending.removeAll { $0.id == requestId }
    }

    public func stop() async {
        stopped = true
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Enqueue

    private func enqueue(_ req: AgentRequest) async {
        // Preflight: tokenize once to learn the prompt length, then reject
        // up front if it doesn't fit. This is the second tokenize call (one
        // in preflight, one in assignSlot) but it's cheap relative to a
        // decode step and it keeps the slot state self-contained.
        if engine.nCtx > 0 {
            let probe = engine.tokenizeAlloc(req.prompt, addBos: true, parseSpecial: true)
            defer {
                if let buf = probe.buffer { engine.tokenizeFree(buf) }
            }
            if probe.count < 0 {
                emitFailure(req.id, .tokenizeFailed)
                return
            }
            if probe.count + req.maxTokens > engine.nCtx {
                emitFailure(req.id, .promptExceedsContext(
                    promptTokens: probe.count,
                    maxTokens: req.maxTokens,
                    nCtx: engine.nCtx))
                return
            }
        }

        // Spec-routed path: useSpec=true with a loaded spec engine. The
        // spec engine is a SEPARATE resource from the batched engine (no
        // shared KV), so this is a single-shot generation that runs on a
        // background queue (off-actor). Falls back to the batched path
        // if the spec engine is not loaded - the request still gets
        // served, just without speculative-decoding latency wins.
        if req.useSpec, let spec = specEngine, spec.isLoaded {
            runSpecGeneration(for: req, via: spec)
            return
        }

        if let idx = slots.firstIndex(where: { $0.state == .idle }) {
            assignSlot(idx, to: req)
            ensureTickRunning()
        } else if req.priority == .foreground {
            if let victim = evictionTarget() {
                evictSlot(victim)
                assignSlot(victim, to: req)
                ensureTickRunning()
            } else {
                pending.append(req)
            }
        } else {
            pending.append(req)
        }
    }

    /// Run a spec-routed generation for the given request. Spawns a
    /// Task that iterates the spec engine's `generate` stream and pipes
    /// tokens to the request's `AsyncStream<ScheduleEvent>`. The Task
    /// runs OFF the scheduler actor so the batched tick loop is not
    /// blocked. Concurrent spec calls serialize on the spec engine's
    /// internal serial queue; this scheduler just dispatches them.
    private func runSpecGeneration(for req: AgentRequest, via spec: CLlamaSpecEngine) {
        let reqId = req.id
        let maxTokens = req.maxTokens
        let topK = req.telemetryTopK
        let prompt = req.prompt
        Task {
            do {
                for try await piece in spec.generate(prompt: prompt, maxTokens: maxTokens, telemetryTopK: topK) {
                    // Touch the actor to look up the continuation; releases
                    // the actor between yields so cancel / submit can interleave.
                    if let s = await self.continuationFor(reqId) {
                        s.yield(.token(piece))
                    } else {
                        // Stream was removed (cancel / finish). Stop iterating.
                        return
                    }
                }
                if let s = await self.removeContinuation(reqId) {
                    s.yield(.done)
                }
            } catch {
                if let s = await self.removeContinuation(reqId) {
                    s.yield(.failed(.engineUnavailable))
                }
            }
        }
    }

    /// Look up the stream continuation for a request, awaiting on the
    /// actor. Returns nil if the stream was already removed.
    private func continuationFor(_ id: UUID) -> AsyncStream<ScheduleEvent>.Continuation? {
        streams[id]
    }

    /// Remove the stream continuation and return it. Used by the spec
    /// path to finalize a generation.
    private func removeContinuation(_ id: UUID) -> AsyncStream<ScheduleEvent>.Continuation? {
        streams.removeValue(forKey: id)
    }

    private func emitFailure(_ id: UUID, _ reason: ScheduleFailure) {
        if let s = streams.removeValue(forKey: id) {
            s.yield(.failed(reason))
            s.finish()
        }
    }

    private func assignSlot(_ idx: Int, to req: AgentRequest) {
        let probe = engine.tokenizeAlloc(req.prompt, addBos: true, parseSpecial: true)
        guard probe.count > 0, let buf = probe.buffer else {
            if let buf = probe.buffer { engine.tokenizeFree(buf) }
            emitFailure(req.id, .tokenizeFailed)
            return
        }
        let tokens = Array(UnsafeBufferPointer(start: buf, count: probe.count))
        engine.tokenizeFree(buf)

        slots[idx].requestId = req.id
        slots[idx].maxTokens = req.maxTokens
        slots[idx].pos = 0
        slots[idx].generated = 0
        slots[idx].priority = req.priority
        slots[idx].promptTokens = tokens
        slots[idx].promptConsumed = 0
        slots[idx].lastToken = nil
        slots[idx].state = .prefill
    }

    /// Pick the background slot to evict when a foreground request needs
    /// a slot and all slots are busy. Heuristic: the slot with the
    /// HIGHEST progress ratio - it would finish naturally soonest, so
    /// preempting it now is the smallest loss in terms of "slot free
    /// time" (we get a slot back faster). This is the standard
    /// continuous-batching preemption-by-progress policy (vLLM, TGI).
    ///
    /// Progress is computed per state:
    /// - prefill: pos / promptTokens.count (how much of the prefill is done)
    /// - decode:  generated / maxTokens (how much of the max is done)
    /// - idle:    0 (should never be selected, but defensively handled)
    ///
    /// Tie-break by slot index for determinism (lower index wins, so we
    /// always pick a consistent slot when progress is equal).
    private func evictionTarget() -> Int? {
        let bg = slots.enumerated().filter { _, s in
            s.priority == .background && s.state != .idle
        }
        guard !bg.isEmpty else { return nil }
        return bg.max { lhs, rhs in
            let lp = progressRatio(lhs.element)
            let rp = progressRatio(rhs.element)
            if lp != rp { return lp < rp }
            return lhs.offset > rhs.offset
        }?.offset
    }

    /// Progress ratio for eviction sorting. Higher = more progress.
    private func progressRatio(_ slot: BatchSlot) -> Double {
        switch slot.state {
        case .idle:
            return 0
        case .prefill:
            let denom = max(1, slot.promptTokens.count)
            return Double(slot.pos) / Double(denom)
        case .decode:
            let denom = max(1, slot.maxTokens)
            return Double(slot.generated) / Double(denom)
        }
    }

    private func evictSlot(_ idx: Int) {
        if let reqId = slots[idx].requestId, let s = streams.removeValue(forKey: reqId) {
            // Re-queue the displaced request so a future submit or promote
            // can pick it up.
            // Note: we don't re-queue here because the request struct isn't
            // stored on the slot. Eviction is best-effort - the displaced
            // request is finished and the caller can resubmit if needed.
            s.yield(.evicted)
            s.finish()
        }
        engine.slotClear(slots[idx].seqId)
        slots[idx].requestId = nil
        slots[idx].maxTokens = 0
        slots[idx].pos = 0
        slots[idx].generated = 0
        slots[idx].state = .idle
        slots[idx].priority = .background
        slots[idx].promptTokens = []
        slots[idx].promptConsumed = 0
        slots[idx].lastToken = nil
    }

    // MARK: - Tick loop

    private func ensureTickRunning() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            await self?.runTickLoop()
        }
    }

    /// Run ticks until no slot is active. Clearing `tickTask = nil` BEFORE
    /// returning closes the post-break race where a new enqueue finds a
    /// stale non-nil `tickTask` and no-op's, leaving the new assignment
    /// without a runner.
    private func runTickLoop() async {
        while !Task.isCancelled && !stopped {
            let more = await tick()
            if !more { break }
            await Task.yield()
        }
        tickTask = nil
    }

    /// Run one batched decode step. Returns true if any slot is still active.
    private func tick() async -> Bool {
        // Gather ready slots in priority order (foreground first, then by id).
        let readyIdx = slots.enumerated().compactMap { (i, s) -> Int? in
            guard s.requestId != nil, s.state == .prefill || s.state == .decode else { return nil }
            return i
        }.sorted { a, b in
            if slots[a].priority != slots[b].priority { return slots[a].priority > slots[b].priority }
            return a < b
        }
        guard !readyIdx.isEmpty else { return false }

        // Build the batch up to nBatch tokens. Each prefill slot contributes
        // as many remaining prompt tokens as fit; each decode slot
        // contributes one token. Track which batch positions to read back.
        let nBatch = engine.nBatch
        var batchTokens: [Int32] = []
        var batchSeqIds: [Int32] = []
        var batchPositions: [Int32] = []
        var batchLogits: [Int8] = []
        // (slotIndex, batchPos) for results we care about.
        var results: [(slot: Int, batchPos: Int)] = []
        // Snapshot the slot state before the batch build. On rc=1 (no KV
        // slot) the decode did not commit any tokens, so we rewind each
        // touched slot to its pre-batch state - otherwise the slot is
        // left mid-prefill with no lastToken and the tick loop spins
        // forever.
        let preBatchPos: [Int: Int32] = Dictionary(uniqueKeysWithValues:
            readyIdx.map { ($0, slots[$0].pos) })
        let preBatchConsumed: [Int: Int] = Dictionary(uniqueKeysWithValues:
            readyIdx.map { ($0, slots[$0].promptConsumed) })

        for idx in readyIdx where batchTokens.count < nBatch {
            let slot = slots[idx]
            if slot.state == .prefill {
                let remaining = slot.promptTokens.count - slot.promptConsumed
                let budget = nBatch - batchTokens.count
                let take = min(remaining, budget)
                if take == 0 { continue }
                for k in 0..<take {
                    let promptIdx = slot.promptConsumed + k
                    let isLast = (promptIdx == slot.promptTokens.count - 1)
                    batchTokens.append(slot.promptTokens[promptIdx])
                    batchSeqIds.append(slot.seqId)
                    batchPositions.append(slot.pos + Int32(k))
                    let wantsLogits: Int8 = isLast ? 1 : 0
                    batchLogits.append(wantsLogits)
                    if isLast {
                        results.append((slot: idx, batchPos: batchTokens.count - 1))
                    }
                }
                slots[idx].pos += Int32(take)
                slots[idx].promptConsumed += take
                if slots[idx].promptConsumed >= slot.promptTokens.count {
                    slots[idx].state = .decode
                }
            } else if slot.state == .decode {
                guard let tok = slot.lastToken else { continue }
                batchTokens.append(tok)
                batchSeqIds.append(slot.seqId)
                batchPositions.append(slot.pos)
                batchLogits.append(1)
                results.append((slot: idx, batchPos: batchTokens.count - 1))
                slots[idx].pos += 1
            }
        }

        guard !batchTokens.isEmpty else {
            promotePending()
            return slots.contains { $0.state == .prefill || $0.state == .decode }
        }

        // Yield the actor before the synchronous C decode call. The
        // decode can take hundreds of ms on a GPU; without this yield
        // the actor is held across the whole call and any
        // `submit`/`cancel` Task queued during the decode has to wait
        // for it to complete. The yield is a runtime hint, not a
        // cancellation point: the decode still runs to completion in
        // the same tick, but other tasks get a chance to interleave.
        //
        // NOTE: the "real" yield that lets cancel/submit interleave is
        // the one in `runTickLoop` between ticks. This mid-tick yield
        // is only useful if the batch decode ever becomes async (e.g.
        // moved to `Task.detached`). Today the C call is synchronous
        // and this yield is a no-op for the actor; we still keep it
        // for the day the decode becomes async.
        //
        // We do NOT actually yield here today — yielding mid-tick
        // exposes the slot state between batch-build and rc=2 re-sync,
        // which is a mid-update snapshot and not safe to read. The
        // eviction heuristic, the cancel path, and any state reader
        // all assume the slot is in a steady state. The loop yield
        // in `runTickLoop` is the right place to interleave.
        let n = Int32(batchTokens.count)
        let rc: Int32 = batchTokens.withUnsafeBufferPointer { tokBuf in
            batchSeqIds.withUnsafeBufferPointer { seqBuf in
                batchPositions.withUnsafeBufferPointer { posBuf in
                    batchLogits.withUnsafeBufferPointer { logBuf in
                        engine.batchDecodeExt(
                            tokens: tokBuf.baseAddress!,
                            seqIds: seqBuf.baseAddress!,
                            positions: posBuf.baseAddress!,
                            logitsFlags: logBuf.baseAddress!,
                            n: n)
                    }
                }
            }
        }

        if rc == 1 {
            // No KV slot: the decode did not commit. Rewind each touched
            // slot to its pre-batch state so the next tick re-feeds the
            // same tokens. The slot may also be in .decode now (if the
            // prefill happened to complete before the rc=1 response) -
            // in that case revert it to .prefill.
            for idx in readyIdx {
                if let prevPos = preBatchPos[idx] {
                    slots[idx].pos = prevPos
                }
                if let prevConsumed = preBatchConsumed[idx] {
                    slots[idx].promptConsumed = prevConsumed
                    slots[idx].lastToken = nil
                    // If the prefill completed during this tick, the
                    // slot transitioned to .decode. With the rewind above
                    // the prompt is no longer fully consumed, so put the
                    // slot back in .prefill.
                    if prevConsumed < slots[idx].promptTokens.count {
                        slots[idx].state = .prefill
                    }
                }
            }
            promotePending()
            return slots.contains { $0.state == .prefill || $0.state == .decode }
        }
        if rc == 2 {
            // Aborted: partial ubatches committed. The committed positions
            // may differ from what we asked for. Re-sync each touched
            // slot's pos to slotPosMax so the next tick continues from the
            // right place instead of re-feeding already-committed tokens.
            // If the prefill happened to complete during this tick (so
            // state moved to .decode) but only a partial subset was
            // committed, put the slot back in .prefill and clear
            // lastToken so it re-feeds the remaining tokens instead of
            // being stuck in decode with no token to feed.
            for idx in readyIdx where slots[idx].requestId != nil {
                let seqId = slots[idx].seqId
                let actualMax = engine.slotPosMax(seqId)
                if actualMax >= 0 {
                    slots[idx].pos = actualMax + 1
                    let target = Int(actualMax + 1)
                    if target < slots[idx].promptTokens.count {
                        // There's still prompt to feed - rewind to prefill.
                        slots[idx].promptConsumed = target
                        slots[idx].lastToken = nil
                        slots[idx].state = .prefill
                    } else {
                        // Prefill was complete. Stay in decode but clear
                        // lastToken since we never actually got a sample.
                        slots[idx].lastToken = nil
                    }
                }
            }
            promotePending()
            return slots.contains { $0.state == .prefill || $0.state == .decode }
        }
        if rc != 0 {
            // -1 or -2: fatal. Clear the touched slots and continue.
            for idx in readyIdx {
                if let reqId = slots[idx].requestId {
                    engine.slotClear(slots[idx].seqId)
                    slots[idx].state = .idle
                    slots[idx].requestId = nil
                    slots[idx].maxTokens = 0
                    slots[idx].pos = 0
                    slots[idx].generated = 0
                    slots[idx].promptTokens = []
                    slots[idx].promptConsumed = 0
                    slots[idx].lastToken = nil
                    if let s = streams.removeValue(forKey: reqId) {
                        s.yield(.failed(.engineUnavailable))
                        s.finish()
                    }
                }
            }
            promotePending()
            return slots.contains { $0.state == .prefill || $0.state == .decode }
        }

        // Success. Sample each result slot's logits via the safe per-position
        // accessor.
        let nVocab = engine.nVocab
        var rowBuf = [Float](repeating: 0, count: nVocab)
        for res in results {
            // The slot may have been preempted between batch-build and now
            // (race-free in practice because tick is on the actor, but
            // defensive). Skip if so.
            guard let reqId = slots[res.slot].requestId,
                  streams[reqId] != nil else { continue }

            let ok = rowBuf.withUnsafeMutableBufferPointer { buf -> Bool in
                engine.getLogitsIth(Int32(res.batchPos), outBuf: buf.baseAddress!, nVocab: Int32(nVocab))
            }
            guard ok else { continue }
            let token = greedyArgmax(rowBuf)
            slots[res.slot].lastToken = token
            slots[res.slot].generated += 1

            let piece = engine.tokenToPiece(token)
            let isEOG = engine.tokenIsEog(token)
            let generated = slots[res.slot].generated
            let maxTokens = slots[res.slot].maxTokens

            if isEOG || generated >= maxTokens {
                if let s = streams.removeValue(forKey: reqId) {
                    s.yield(.done)
                    s.finish()
                }
                engine.slotClear(slots[res.slot].seqId)
                slots[res.slot].requestId = nil
                slots[res.slot].maxTokens = 0
                slots[res.slot].pos = 0
                slots[res.slot].generated = 0
                slots[res.slot].promptTokens = []
                slots[res.slot].promptConsumed = 0
                slots[res.slot].lastToken = nil
                slots[res.slot].state = .idle
            } else if !piece.isEmpty, let s = streams[reqId] {
                s.yield(.token(piece))
            }
        }

        promotePending()
        return slots.contains { $0.state == .prefill || $0.state == .decode }
    }

    private func promotePending() {
        guard !pending.isEmpty else { return }
        while let idx = slots.firstIndex(where: { $0.state == .idle }), !pending.isEmpty {
            let next = pending.removeFirst()
            assignSlot(idx, to: next)
        }
    }

    // MARK: - Greedy sampling

    private func greedyArgmax(_ logits: [Float]) -> Int32 {
        var best = Int32(0)
        var bestVal: Float = -.greatestFiniteMagnitude
        for (i, v) in logits.enumerated() where v > bestVal {
            bestVal = v
            best = Int32(i)
        }
        return best
    }
}
