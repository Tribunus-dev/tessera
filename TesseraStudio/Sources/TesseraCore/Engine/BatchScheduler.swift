import Foundation
import CLlama

/// A request submitted to the ``BatchScheduler``. One per agent turn.
public struct AgentRequest: Sendable {
    public let id: UUID
    public let agentId: UUID
    public let prompt: String
    public let maxTokens: Int
    public let priority: Priority
    public let useSpec: Bool
    public let onToken: @Sendable (String) -> Void
    public let onComplete: @Sendable () -> Void

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
        onToken: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void = {}
    ) {
        self.id = id
        self.agentId = agentId
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.priority = priority
        self.useSpec = useSpec
        self.onToken = onToken
        self.onComplete = onComplete
    }
}

/// One slot in the batch pool.
struct BatchSlot {
    let id: Int                  // slot index
    var seqId: Int32             // KV sequence id (== slot id)
    var requestId: UUID?
    var pos: Int32               // next position to write into KV
    var generated: Int           // tokens generated (decode phase only)
    var state: SlotState
    var priority: AgentRequest.Priority
    // Prefill: the prompt tokens still being fed. nil once prefill is done.
    var promptTokens: [Int32]?
    var promptConsumed: Int      // index into promptTokens
    var lastToken: Int32?        // last sampled token (fed on the next decode)
}

enum SlotState {
    case idle
    case prefill                // still consuming promptTokens
    case decode                 // promptTokens consumed; generating
    case done
}

/// Events streamed back to a `submit(_:)` caller.
public enum ScheduleEvent: Sendable {
    case token(String)
    case done
    case evicted
}

/// Multiplexes many concurrent agent requests through ONE decode loop over a
/// shared `cllama_engine`, advancing every ready sequence in a single
/// `llama_decode` call per tick. This is continuous batching on device.
///
/// **Dynamic batch size + batched prefill**: each tick builds a batch mixing
/// prefill tokens (multiple per slot, up to `n_batch` total) with decode
/// tokens (one per slot). Intermediate prefill tokens set `logits=false` (no
/// output) to save compute; only the last prefill token of each slot and every
/// decode token request logits. The batch is capped at `n_batch` tokens; slots
/// that don't fit wait for the next tick. Slots are served in priority order
/// (foreground first), then round-robin.
///
/// **Correct logits indexing**: uses `cllama_get_logits_ith` (the safe per-
/// batch-position accessor) so mixed-logits batches index correctly.
///
/// **Priority preemption**: a foreground request that finds all slots busy
/// evicts the lowest-priority background slot (clears its KV, re-queues it).
public actor BatchScheduler {
    private let engine: OpaquePointer
    private let nVocab: Int
    private let nBatch: Int
    private let maxSlots: Int
    private var slots: [BatchSlot]
    private var pending: [AgentRequest] = []
    private var streams: [UUID: AsyncStream<ScheduleEvent>.Continuation] = [:]
    private var requestsById: [UUID: AgentRequest] = [:]
    private var tickTask: Task<Void, Never>?

    public init?(engine: OpaquePointer, maxSlots: Int = 4) {
        self.engine = engine
        let nv = Int(cllama_engine_n_vocab(engine))
        guard nv > 0 else { return nil }
        self.nVocab = nv
        self.nBatch = Int(cllama_engine_n_batch(engine))
        self.maxSlots = max(1, min(maxSlots, 8))
        self.slots = (0..<self.maxSlots).map {
            BatchSlot(id: $0, seqId: Int32($0), requestId: nil, pos: 0, generated: 0,
                      state: .idle, priority: .background,
                      promptTokens: nil, promptConsumed: 0, lastToken: nil)
        }
    }

    public func submit(_ req: AgentRequest) -> AsyncStream<ScheduleEvent> {
        requestsById[req.id] = req
        return AsyncStream { continuation in
            self.streams[req.id] = continuation
            Task { await self.enqueue(req) }
        }
    }

    public func cancel(requestId: UUID) async {
        if let idx = slots.firstIndex(where: { $0.requestId == requestId }) {
            clearSlot(idx)
        }
        streams[requestId]?.finish()
        streams.removeValue(forKey: requestId)
        requestsById.removeValue(forKey: requestId)
        pending.removeAll { $0.id == requestId }
    }

    // MARK: - Enqueue

    private func enqueue(_ req: AgentRequest) async {
        if let idx = slots.firstIndex(where: { $0.state == .idle }) {
            assignSlot(idx, to: req)
            ensureTickRunning()
        } else if req.priority == .foreground {
            if let victim = lowestBackgroundSlot() {
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

    private func assignSlot(_ idx: Int, to req: AgentRequest) {
        let bos: Int32 = 1
        var tokenBuf = [Int32](repeating: 0, count: 4096)
        let n = tokenBuf.withUnsafeMutableBufferPointer { buf -> Int32 in
            cllama_tokenize_prompt(engine, req.prompt, bos, buf.baseAddress!, Int32(buf.count))
        }
        guard n > 0 else {
            streams[req.id]?.yield(.done)
            streams[req.id]?.finish()
            streams.removeValue(forKey: req.id)
            requestsById.removeValue(forKey: req.id)
            return
        }
        slots[idx].requestId = req.id
        slots[idx].pos = 0
        slots[idx].generated = 0
        slots[idx].priority = req.priority
        slots[idx].promptTokens = Array(tokenBuf.prefix(Int(n)))
        slots[idx].promptConsumed = 0
        slots[idx].lastToken = nil
        slots[idx].state = .prefill
    }

    private func lowestBackgroundSlot() -> Int? {
        slots.firstIndex { $0.priority == .background && $0.state != .idle }
    }

    private func evictSlot(_ idx: Int) {
        if let reqId = slots[idx].requestId, let req = requestsById[reqId] {
            streams[reqId]?.yield(.evicted)
            pending.append(req)
        }
        clearSlot(idx)
    }

    private func clearSlot(_ idx: Int) {
        cllama_slot_clear(engine, slots[idx].seqId)
        slots[idx].requestId = nil
        slots[idx].pos = 0
        slots[idx].generated = 0
        slots[idx].state = .idle
        slots[idx].priority = .background
        slots[idx].promptTokens = nil
        slots[idx].promptConsumed = 0
        slots[idx].lastToken = nil
    }

    // MARK: - Tick loop

    private func ensureTickRunning() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let more = await self.tick()
                if !more { break }
            }
            await self?.clearTickTask()
        }
    }

    private func clearTickTask() {
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

        // Dynamic batch sizing: build the batch up to n_batch tokens. Each
        // prefill slot contributes as many remaining prompt tokens as fit;
        // each decode slot contributes one token. Track which batch positions
        // belong to which slot and which requested logits.
        var batchTokens: [Int32] = []
        var batchSeqIds: [Int32] = []
        var batchPositions: [Int32] = []
        var batchLogits: [Int8] = []
        // (slotIndex, batchPosition, wantsLogits) for results we care about.
        var results: [(slot: Int, batchPos: Int)] = []

        for idx in readyIdx where batchTokens.count < nBatch {
            let slot = slots[idx]
            if slot.state == .prefill, let prompt = slot.promptTokens {
                // Feed as many remaining prompt tokens as fit in the budget.
                let remaining = prompt.count - slot.promptConsumed
                let budget = nBatch - batchTokens.count
                let take = min(remaining, budget)
                let lastInPrompt = slot.promptConsumed + take - 1
                for k in 0..<take {
                    let promptIdx = slot.promptConsumed + k
                    let isLast = (promptIdx == prompt.count - 1)
                    batchTokens.append(prompt[promptIdx])
                    batchSeqIds.append(slot.seqId)
                    batchPositions.append(slot.pos + Int32(k))
                    // Only the LAST prefill token needs logits (the next
                    // predicted token). Intermediate tokens: logits=false.
                    let wantsLogits: Int8 = isLast ? 1 : 0
                    batchLogits.append(wantsLogits)
                    if isLast {
                        results.append((slot: idx, batchPos: batchTokens.count - 1))
                    }
                }
                slots[idx].pos += Int32(take)
                slots[idx].promptConsumed += take
                if slot.promptConsumed + take >= prompt.count {
                    // Prefill done for this slot; transition to decode next tick.
                    slots[idx].state = .decode
                }
            } else if slot.state == .decode {
                // One decode token (the last sampled token, fed back).
                guard let tok = slot.lastToken else { continue }
                batchTokens.append(tok)
                batchSeqIds.append(slot.seqId)
                batchPositions.append(slot.pos)
                batchLogits.append(1)  // decode tokens always want logits
                results.append((slot: idx, batchPos: batchTokens.count - 1))
                slots[idx].pos += 1
            }
        }

        guard !batchTokens.isEmpty else { return slots.contains { $0.state == .prefill || $0.state == .decode } }

        // Build the llama_batch + decode. Decode via the ext entry point that
        // takes per-token logits flags (mixed prefill+decode safe).
        let n = Int32(batchTokens.count)
        let decoded = batchTokens.withUnsafeMutableBufferPointer { tokBuf in
            batchSeqIds.withUnsafeMutableBufferPointer { seqBuf in
                batchPositions.withUnsafeMutableBufferPointer { posBuf in
                    batchLogits.withUnsafeMutableBufferPointer { logBuf in
                        guard let tok = tokBuf.baseAddress,
                              let seq = seqBuf.baseAddress,
                              let pos = posBuf.baseAddress,
                              let log = logBuf.baseAddress else {
                            return Int32(-1)
                        }
                        return cllama_engine_batch_decode_ext(engine, tok, seq, pos, log, n)
                    }
                }
            }
        }

        guard decoded == 0 else {
            // Non-zero return: 1 = no KV slot (try reducing batch), 2 = aborted.
            // For 1, we'll retry next tick with fewer slots; the loop continues.
            return slots.contains { $0.state == .prefill || $0.state == .decode }
        }

        // Sample each result slot's logits via the safe per-position accessor.
        var rowBuf = [Float](repeating: 0, count: nVocab)
        for res in results {
            let ok = rowBuf.withUnsafeMutableBufferPointer { buf -> Int32 in
                guard let base = buf.baseAddress else { return Int32(-1) }
                return cllama_get_logits_ith(engine, Int32(res.batchPos), base, Int32(nVocab))
            }
            guard ok == 0 else { continue }
            let token = greedyArgmax(rowBuf)
            slots[res.slot].lastToken = token
            slots[res.slot].generated += 1

            // Detokenize.
            var pieceBuf = [CChar](repeating: 0, count: 64)
            let pieceLen = pieceBuf.withUnsafeMutableBufferPointer { buf -> Int32 in
                cllama_token_to_piece_str(engine, token, buf.baseAddress, Int32(buf.count))
            }
            let piece = pieceLen > 0 ? String(cString: pieceBuf) : ""

            let isEOG = cllama_token_is_eog(engine, token) != 0
            let reqId = slots[res.slot].requestId
            let req = reqId.flatMap { requestsById[$0] }
            let atMax = slots[res.slot].generated >= (req?.maxTokens ?? 512)

            if isEOG || atMax {
                if let reqId {
                    streams[reqId]?.yield(.done)
                    streams[reqId]?.finish()
                    streams.removeValue(forKey: reqId)
                    requestsById.removeValue(forKey: reqId)
                }
                req?.onComplete()
                clearSlot(res.slot)
            } else if !piece.isEmpty, let reqId, let req {
                req.onToken(piece)
                streams[reqId]?.yield(.token(piece))
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
        var bestVal: Float = -Float.greatestFiniteMagnitude
        for (i, v) in logits.enumerated() where v > bestVal {
            bestVal = v
            best = Int32(i)
        }
        return best
    }
}

// MARK: - C bridge helpers

@inline(__always) private func cllama_tokenize_prompt(
    _ eng: OpaquePointer, _ text: String, _ bos: Int32,
    _ buf: UnsafeMutablePointer<Int32>, _ n: Int32
) -> Int32 {
    text.withCString { cstr in cllama_engine_tokenize(eng, cstr, bos, buf, n) }
}
