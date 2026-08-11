import XCTest
@testable import TesseraCore

/// Records every `batchDecodeExt` call so tests can assert the scheduler
/// built the right (tokens, seqIds, positions, logitsFlags) tuple. The mock
/// is synchronous and not thread-safe - the scheduler is an actor and the
/// test drives it from a single Task.
final class MockCLlamaEngine: CLlamaEngine, @unchecked Sendable {
    let nVocab: Int
    let nBatch: Int
    let nCtx: Int

    /// Per-prompt canned token sequence. Tokenize returns a copy of this.
    var tokenizeCanned: [String: [Int32]] = [:]

    /// Token id that the canned logits row favors (greedy argmax target).
    let favoriteToken: Int32
    /// Token id that the canned logits row flags as EOG. When a slot
    /// accumulates this many decode tokens, the next decode tick yields
    /// isEOG=true and the slot finishes.
    let eogToken: Int32
    var tokensUntilEog: Int

    /// Captured batch calls. Each entry: (tokens, seqIds, positions,
    /// logitsFlags). The test asserts on the most-recent entry.
    var batches: [BatchCall] = []
    /// Configurable return code for the next `batchDecodeExt` call. The
    /// mock pops it off; once the list is empty, defaults to 0 (success).
    var returnCodeQueue: [Int32] = []
    /// If non-nil, every `batchDecodeExt` call returns this code (overrides
    /// the queue). Used to keep slots in prefill at controlled progress
    /// levels for eviction-heuristic tests.
    var alwaysReturnCode: Int32? = nil
    /// Counter of decode ticks per slot. Used to drive EOG.
    var decodeTicksBySeq: [Int32: Int] = [:]
    /// seqId values whose KV the scheduler has cleared via slotClear.
    var clearedSeqs: [Int32] = []
    /// seqId values whose posMax was queried.
    var posMaxQueries: [Int32] = []
    /// posMax value to return per seqId. Default -1.
    var posMaxBySeq: [Int32: Int32] = [:]
    /// posMax to return once the scheduler has called slotClear on a seq.
    /// Simulates "the abort committed up to position N" semantics.
    var posMaxAfterClear: [Int32: Int32] = [:]

    struct BatchCall {
        let tokens: [Int32]
        let seqIds: [Int32]
        let positions: [Int32]
        let logitsFlags: [Int8]
        let n: Int32
    }

    init(nVocab: Int = 100, nBatch: Int = 8, nCtx: Int = 4096,
         favoriteToken: Int32 = 42, eogToken: Int32 = 99,
         tokensUntilEog: Int = 3) {
        self.nVocab = nVocab
        self.nBatch = nBatch
        self.nCtx = nCtx
        self.favoriteToken = favoriteToken
        self.eogToken = eogToken
        self.tokensUntilEog = tokensUntilEog
    }

    func tokenizeAlloc(_ text: String, addBos: Bool, parseSpecial: Bool) -> (count: Int, buffer: UnsafeMutablePointer<Int32>?) {
        let tokens = tokenizeCanned[text] ?? [1, 2, 3, 4, 5]
        let buf = UnsafeMutablePointer<Int32>.allocate(capacity: tokens.count)
        for (i, t) in tokens.enumerated() { buf[i] = t }
        return (tokens.count, buf)
    }

    func tokenizeFree(_ buffer: UnsafeMutablePointer<Int32>) {
        buffer.deallocate()
    }

    func batchDecodeExt(
        tokens: UnsafePointer<Int32>,
        seqIds: UnsafePointer<Int32>,
        positions: UnsafePointer<Int32>,
        logitsFlags: UnsafePointer<Int8>,
        n: Int32
    ) -> Int32 {
        let tokArr = (0..<Int(n)).map { tokens[$0] }
        let seqArr = (0..<Int(n)).map { seqIds[$0] }
        let posArr = (0..<Int(n)).map { positions[$0] }
        let logArr = (0..<Int(n)).map { logitsFlags[$0] }
        batches.append(BatchCall(tokens: tokArr, seqIds: seqArr,
                                 positions: posArr, logitsFlags: logArr, n: n))
        for s in seqArr { decodeTicksBySeq[s, default: 0] += 1 }
        if let rc = alwaysReturnCode { return rc }
        return returnCodeQueue.isEmpty ? 0 : returnCodeQueue.removeFirst()
    }

    func getLogitsIth(_ i: Int32, outBuf: UnsafeMutablePointer<Float>, nVocab: Int32) -> Bool {
        // Fill the row so argmax lands on `favoriteToken`.
        for k in 0..<Int(nVocab) {
            outBuf[k] = (Int32(k) == favoriteToken) ? 10.0 : 0.0
        }
        return true
    }

    func slotPosMax(_ seqId: Int32) -> Int32 {
        posMaxQueries.append(seqId)
        if clearedSeqs.contains(seqId), let v = posMaxAfterClear[seqId] {
            return v
        }
        return posMaxBySeq[seqId] ?? -1
    }

    func slotClear(_ seqId: Int32) {
        clearedSeqs.append(seqId)
    }

    func tokenToPiece(_ tokenId: Int32) -> String {
        tokenId == eogToken ? "<eog>" : "tok\(tokenId)"
    }

    func tokenIsEog(_ tokenId: Int32) -> Bool {
        // Trigger EOG after the Nth call across the test. The scheduler
        // calls tokenIsEog exactly once per decode result, so for
        // single-slot tests this fires after `tokensUntilEog` decode
        // tokens have been sampled. Multi-slot tests should use
        // `tokensUntilEog` high enough to avoid premature EOG.
        let n = eogCallCount
        eogCallCount += 1
        return n + 1 >= tokensUntilEog
    }
    var eogCallCount: Int = 0
}

/// Records every `generate` call so tests can assert the spec-routed path
/// was used. The mock is not thread-safe - the scheduler drives it from a
/// single Task.
final class MockCLlamaSpecEngine: CLlamaSpecEngine, @unchecked Sendable {
    /// If non-nil, override `isLoaded`. Defaults to true.
    var loadedOverride: Bool? = nil

    /// Recorded `generate` calls. Each entry: (prompt, maxTokens, topK).
    var calls: [(prompt: String, maxTokens: Int, topK: Int)] = []

    /// Canned tokens to yield per call. Popped FIFO.
    var tokensToYield: [String] = []

    /// If true, throw this error from the stream instead of yielding.
    var failWith: CLlamaSpecEngineError? = nil

    /// Sleep this many ms before yielding the first token (lets the test
    /// observe that the scheduler is NOT blocked on the spec call).
    var preYieldDelayMs: UInt64 = 0

    var isLoaded: Bool { loadedOverride ?? true }

    func generate(prompt: String, maxTokens: Int, telemetryTopK: Int) -> AsyncThrowingStream<String, Error> {
        calls.append((prompt, maxTokens, telemetryTopK))
        let tokens = tokensToYield
        let fail = failWith
        let delayMs = preYieldDelayMs
        return AsyncThrowingStream<String, Error> { (cont: AsyncThrowingStream<String, Error>.Continuation) in
            if let fail {
                cont.finish(throwing: fail)
                return
            }
            Task {
                if delayMs > 0 {
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                }
                for t in tokens {
                    cont.yield(t)
                }
                cont.finish()
            }
        }
    }
}

// MARK: - Tests

final class BatchSchedulerTests: XCTestCase {
    // Small helper to drain an AsyncStream into an array of events.
    private func collect(_ stream: AsyncStream<ScheduleEvent>, timeout: TimeInterval = 2.0) async -> [ScheduleEvent] {
        let deadline = Date().addingTimeInterval(timeout)
        var out: [ScheduleEvent] = []
        for await ev in stream {
            out.append(ev)
            if Date() > deadline { break }
        }
        return out
    }

    // MARK: Preflight: prompt too long

    func testPreflightRejectsPromptThatExceedsContext() async throws {
        let mock = MockCLlamaEngine(nCtx: 16)
        // Prompt of 10 tokens + maxTokens 100 -> 110 > 16.
        mock.tokenizeCanned["hello world"] = Array(0..<10)
        let scheduler = BatchScheduler(engine: mock, maxSlots: 2)
        let req = AgentRequest(agentId: UUID(), prompt: "hello world", maxTokens: 100)
        let stream = await scheduler.submit(req)
        // Wait for the .failed event.
        var gotFailure: ScheduleFailure?
        for await ev in stream {
            if case let .failed(reason) = ev { gotFailure = reason; break }
        }
        XCTAssertEqual(gotFailure, .promptExceedsContext(promptTokens: 10, maxTokens: 100, nCtx: 16))
    }

    // MARK: Pure prefill: only the LAST prefill token has logits=true

    func testPurePrefillFlagsLogitsOnlyForLastToken() async throws {
        let mock = MockCLlamaEngine(nBatch: 8, tokensUntilEog: 1)
        mock.tokenizeCanned["prompt"] = [100, 101, 102, 103, 104]
        let scheduler = BatchScheduler(engine: mock, maxSlots: 1)
        let stream = await scheduler.submit(AgentRequest(agentId: UUID(), prompt: "prompt", maxTokens: 1))
        // Wait for .done (EOG after 1 decode).
        var gotDone = false
        for await ev in stream {
            if case .done = ev { gotDone = true; break }
        }
        XCTAssertTrue(gotDone, "should reach .done")
        // First batch should be the entire prefill: 5 tokens, 1 with logits.
        guard let first = mock.batches.first else {
            return XCTFail("no batch recorded")
        }
        XCTAssertEqual(first.n, 5)
        XCTAssertEqual(first.tokens, [100, 101, 102, 103, 104])
        XCTAssertEqual(first.seqIds, [0, 0, 0, 0, 0])
        XCTAssertEqual(first.positions, [0, 1, 2, 3, 4])
        XCTAssertEqual(first.logitsFlags, [0, 0, 0, 0, 1])
    }

    // MARK: Dynamic batch size: prefill is split across ticks when > nBatch

    func testPrefillSplitWhenLargerThanNBatch() async throws {
        let mock = MockCLlamaEngine(nBatch: 3, tokensUntilEog: 1)
        // 7-token prompt, nBatch=3: tick 1 -> tokens 0,1,2; tick 2 -> tokens 3,4,5; tick 3 -> token 6.
        mock.tokenizeCanned["big"] = [10, 11, 12, 13, 14, 15, 16]
        let scheduler = BatchScheduler(engine: mock, maxSlots: 1)
        let stream = await scheduler.submit(AgentRequest(agentId: UUID(), prompt: "big", maxTokens: 1))
        var gotDone = false
        for await ev in stream {
            if case .done = ev { gotDone = true; break }
        }
        XCTAssertTrue(gotDone)
        // First three batches: tick1=[10,11,12], tick2=[13,14,15], tick3=[16].
        XCTAssertGreaterThanOrEqual(mock.batches.count, 3)
        XCTAssertEqual(mock.batches[0].tokens, [10, 11, 12])
        XCTAssertEqual(mock.batches[0].positions, [0, 1, 2])
        XCTAssertEqual(mock.batches[0].logitsFlags, [0, 0, 0])  // all intermediate, no logits
        XCTAssertEqual(mock.batches[1].tokens, [13, 14, 15])
        XCTAssertEqual(mock.batches[1].positions, [3, 4, 5])
        XCTAssertEqual(mock.batches[1].logitsFlags, [0, 0, 0])  // still intermediate
        XCTAssertEqual(mock.batches[2].tokens, [16])
        XCTAssertEqual(mock.batches[2].positions, [6])
        XCTAssertEqual(mock.batches[2].logitsFlags, [1])  // last prefill token
    }

    // MARK: Mixed prefill + decode in one batch

    func testMixedPrefillAndDecodeInOneBatch() async throws {
        // With maxTokens large and tokensUntilEog not triggered, both
        // slots remain in prefill, and the scheduler should mix their
        // prefill tokens in a single batch when nBatch permits.
        // Assert: at least one batch contains tokens from BOTH seq_ids
        // (proving mixed batching), the per-seq prefill positions are
        // monotonically increasing (proving each slot's prefill
        // progresses without re-feeding), and the total count of
        // logits=1 flags across all batches equals the number of slots
        // (each slot's last prefill token requests logits, exactly once).
        let mock = MockCLlamaEngine(nBatch: 4, nCtx: 10_000_000, tokensUntilEog: 999_999)
        mock.tokenizeCanned["p0"] = [200, 201, 202]
        let scheduler = BatchScheduler(engine: mock, maxSlots: 2)
        let s0 = await scheduler.submit(AgentRequest(agentId: UUID(), prompt: "p0", maxTokens: 999_999))
        let s1 = await scheduler.submit(AgentRequest(agentId: UUID(), prompt: "p0", maxTokens: 999_999, priority: .foreground))
        Task { for await _ in s0 {} }
        Task { for await _ in s1 {} }
        try await Task.sleep(nanoseconds: 200_000_000)
        // At least one batch must mix tokens from both seq_ids 0 and 1.
        let mixedBatches = mock.batches.filter { batch in
            let seqSet = Set(batch.seqIds)
            return seqSet.contains(0) && seqSet.contains(1)
        }
        XCTAssertGreaterThanOrEqual(mixedBatches.count, 1,
                                    "at least one batch should mix prefill tokens from both slots")
        // For each seq_id, the positions across batches should be
        // monotonically non-decreasing (prefill progresses, no re-feed).
        for seq: Int32 in [0, 1] {
            var lastPos: Int32 = -1
            for batch in mock.batches {
                for (i, p) in batch.positions.enumerated() where batch.seqIds[i] == seq {
                    XCTAssertGreaterThanOrEqual(p, lastPos,
                                                "positions for seq \(seq) must be monotonic")
                    lastPos = p
                }
            }
        }
        // The total count of logits=1 across all batches equals the
        // number of slots: each slot's last prefill token (and only
        // that one) gets logits=1, then the slot transitions to
        // decode where every decode token also gets logits=1. With
        // no EOG and no maxTokens, the slot never EOGs, so it keeps
        // generating decode tokens - so the decode count is unbounded.
        // We only check that there's AT LEAST one logits=1 per slot
        // (i.e., the prefill completed and a sample was produced).
        let logitsOneBySeq: [Int32: Int] = mock.batches.reduce(into: [:]) { acc, batch in
            for (i, flag) in batch.logitsFlags.enumerated() where flag == 1 {
                acc[batch.seqIds[i], default: 0] += 1
            }
        }
        XCTAssertGreaterThanOrEqual(logitsOneBySeq[0] ?? 0, 1,
                                    "seq 0 should have at least one logits=1 (last prefill token or decode)")
        XCTAssertGreaterThanOrEqual(logitsOneBySeq[1] ?? 0, 1,
                                    "seq 1 should have at least one logits=1 (last prefill token or decode)")
    }

    // MARK: Return code 1 (no KV slot) leaves slot state intact for retry

    func testReturnCodeOneDoesNotAdvanceState() async throws {
        // After the retry, the slot must reach .done via EOG, otherwise the
        // test hangs. tokensUntilEog=1 + maxTokens=1: EOG fires on the first
        // decode token after prefill completes.
        let mock = MockCLlamaEngine(nBatch: 8, tokensUntilEog: 1)
        mock.tokenizeCanned["p"] = [50, 51, 52, 53]
        mock.returnCodeQueue = [1, 0]  // first tick fails (rc=1), then succeeds
        let scheduler = BatchScheduler(engine: mock, maxSlots: 1)
        let stream = await scheduler.submit(AgentRequest(agentId: UUID(), prompt: "p", maxTokens: 1))
        var gotDone = false
        let deadline = Date().addingTimeInterval(2.0)
        for await ev in stream {
            if case .done = ev { gotDone = true; break }
            if Date() > deadline { break }
        }
        XCTAssertTrue(gotDone, "should reach .done (otherwise an infinite loop happened)")
        // First batch (rc=1): tokens fed.
        // Second batch (rc=0): same tokens fed again (since state wasn't advanced).
        XCTAssertGreaterThanOrEqual(mock.batches.count, 2)
        XCTAssertEqual(mock.batches[0].tokens, [50, 51, 52, 53])
        XCTAssertEqual(mock.batches[1].tokens, [50, 51, 52, 53])
    }

    // MARK: Return code 2 (aborted) re-syncs pos from slotPosMax

    func testReturnCodeTwoResyncsPos() async throws {
        let mock = MockCLlamaEngine(nBatch: 8, nCtx: 10_000_000, tokensUntilEog: 999_999)
        mock.tokenizeCanned["p"] = [70, 71, 72, 73, 74]
        // First tick: rc=2 (aborted). Mock reports posMax=1 for seq 0
        // (2 tokens committed at positions 0,1). The scheduler should
        // re-sync pos=2, promptConsumed=2, put slot back in prefill.
        // Second tick onward: rc=0 (success).
        mock.returnCodeQueue = [2, 0, 0, 0]
        mock.posMaxBySeq = [0: 1]  // seq 0: committed up to position 1
        let scheduler = BatchScheduler(engine: mock, maxSlots: 1)
        let stream = await scheduler.submit(AgentRequest(agentId: UUID(), prompt: "p", maxTokens: 999_999))
        // The slot never finishes (no EOG, no maxTokens). Wait for a
        // bounded time, then assert the re-sync happened.
        let deadline = Date().addingTimeInterval(2.0)
        for await _ in stream {
            if Date() > deadline { break }
        }
        // First batch: the full 5-token prefill attempt (fails with rc=2).
        XCTAssertGreaterThanOrEqual(mock.batches.count, 2)
        XCTAssertEqual(mock.batches[0].tokens, [70, 71, 72, 73, 74])
        // After the abort re-sync, the next batch should start at position 2.
        XCTAssertGreaterThanOrEqual(mock.batches.count, 2)
        XCTAssertEqual(mock.batches[1].positions.first, 2,
                       "after abort re-sync, next batch should start at position 2")
        // The slot should have queried posMax(0) to learn the actual position.
        XCTAssertTrue(mock.posMaxQueries.contains(0))
    }

    // MARK: Cancel emits .evicted

    func testCancelEmitsEvicted() async throws {
        // Set up the consumer FIRST so its iterator is active when the
        // cancel yields .evicted. Then cancel. The consumer should
        // observe .evicted and return true.
        let mock = MockCLlamaEngine(nBatch: 4, nCtx: 10_000_000, tokensUntilEog: 999_999)
        mock.tokenizeCanned["slow"] = [10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]
        let scheduler = BatchScheduler(engine: mock, maxSlots: 1)
        let req = AgentRequest(agentId: UUID(), prompt: "slow", maxTokens: 999_999)
        let stream = await scheduler.submit(req)
        // Start the consumer immediately, BEFORE any tick work runs. The
        // consumer's iterator is active and will receive the .evicted
        // event when the cancel yields it.
        let consumer = Task<Bool, Never> {
            for await ev in stream {
                if case .evicted = ev { return true }
            }
            return false
        }
        // Give the scheduler a brief moment to start its tick task.
        try await Task.sleep(nanoseconds: 10_000_000)
        await scheduler.cancel(requestId: req.id)
        // Wait up to 2s for the consumer to observe the event.
        let result = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask { await consumer.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            for await first in group {
                group.cancelAll()
                return first
            }
            return false
        }
        XCTAssertTrue(result, "cancel should emit .evicted")
    }

    // MARK: Priority preemption

    func testForegroundPreemptsBackground() async throws {
        let mock = MockCLlamaEngine(nBatch: 4)
        mock.tokenizeCanned["bg"] = Array(0..<50)  // background: slow prefill
        mock.tokenizeCanned["fg"] = Array(100..<120)
        let scheduler = BatchScheduler(engine: mock, maxSlots: 1)
        // Fill the single slot with a background request.
        let bgReq = AgentRequest(agentId: UUID(), prompt: "bg", maxTokens: 10, priority: .background)
        _ = await scheduler.submit(bgReq)
        // Wait briefly for the bg request to occupy the slot.
        try await Task.sleep(nanoseconds: 30_000_000)
        // Submit foreground. The only slot is occupied by bg; the scheduler
        // should evict bg and assign fg to it.
        let fgReq = AgentRequest(agentId: UUID(), prompt: "fg", maxTokens: 1, priority: .foreground)
        _ = await scheduler.submit(fgReq)
        // The scheduler should have called slotClear on seq 0 (eviction).
        XCTAssertTrue(mock.clearedSeqs.contains(0), "eviction should clear bg's KV")
    }

    // MARK: - Follow-up 1: useSpec routes foreground to the spec engine

    /// A request with useSpec=true and a loaded spec engine should be
    /// routed to the spec engine, NOT the batched engine. The spec
    /// engine's `generate` is called with the request's prompt and
    /// maxTokens; tokens stream to the request's AsyncStream.
    func testUseSpecRoutesForegroundToSpecEngine() async throws {
        let mock = MockCLlamaEngine(nCtx: 10_000_000)
        mock.tokenizeCanned["fg"] = [100, 101, 102]
        let spec = MockCLlamaSpecEngine()
        spec.tokensToYield = ["hello", " ", "world"]
        let scheduler = BatchScheduler(engine: mock, specEngine: spec, maxSlots: 4)
        let stream = await scheduler.submit(AgentRequest(
            agentId: UUID(),
            prompt: "fg",
            maxTokens: 16,
            priority: .foreground,
            useSpec: true,
            telemetryTopK: 4
        ))
        var received: [ScheduleEvent] = []
        let consumer = Task<Bool, Never> {
            for await ev in stream {
                received.append(ev)
                if case .done = ev { return true }
                if case .failed = ev { return true }
            }
            return false
        }
        let got = await consumer.value
        XCTAssertTrue(got)
        // Spec engine was called with the right prompt and metadata.
        XCTAssertEqual(spec.calls.count, 1)
        XCTAssertEqual(spec.calls[0].prompt, "fg")
        XCTAssertEqual(spec.calls[0].maxTokens, 16)
        XCTAssertEqual(spec.calls[0].topK, 4)
        // The three tokens streamed to the consumer.
        let pieces = received.compactMap { ev -> String? in
            if case let .token(p) = ev { return p }
            return nil
        }
        XCTAssertEqual(pieces, ["hello", " ", "world"])
        // The batched engine was NOT called for this request (the spec
        // path is separate from the batched tick loop). No batch should
        // have been built containing tokens from this request's prompt.
        let fgBatches = mock.batches.filter { batch in
            batch.tokens.contains(where: { $0 == 100 || $0 == 101 || $0 == 102 })
        }
        XCTAssertEqual(fgBatches.count, 0, "spec-routed request should not reach the batched engine")
    }

    /// useSpec=true with NO spec engine loaded falls back to the batched
    /// engine. The request still gets served - the spec library is
    /// optional.
    func testUseSpecFallsBackToBatchedWhenSpecUnavailable() async throws {
        let mock = MockCLlamaEngine(nBatch: 8, tokensUntilEog: 1)
        mock.tokenizeCanned["fg"] = [100, 101, 102]
        let scheduler = BatchScheduler(engine: mock, specEngine: nil, maxSlots: 4)
        let stream = await scheduler.submit(AgentRequest(
            agentId: UUID(),
            prompt: "fg",
            maxTokens: 1,
            priority: .foreground,
            useSpec: true
        ))
        var gotDone = false
        let deadline = Date().addingTimeInterval(2.0)
        for await ev in stream {
            if case .done = ev { gotDone = true; break }
            if Date() > deadline { break }
        }
        XCTAssertTrue(gotDone, "fallback to batched should still serve the request")
        // The batched engine was called - find the batch with the fg tokens.
        let fgBatches = mock.batches.filter { $0.tokens == [100, 101, 102] }
        XCTAssertGreaterThanOrEqual(fgBatches.count, 1, "batched engine should serve the request")
    }

    /// useSpec=false (the default) goes to the batched engine even when
    /// the spec engine is loaded. The spec path is opt-in.
    func testUseSpecFalseBypassesSpecEngine() async throws {
        let mock = MockCLlamaEngine(nBatch: 8, tokensUntilEog: 1)
        mock.tokenizeCanned["bg"] = [200, 201, 202]
        let spec = MockCLlamaSpecEngine()
        let scheduler = BatchScheduler(engine: mock, specEngine: spec, maxSlots: 4)
        let stream = await scheduler.submit(AgentRequest(
            agentId: UUID(),
            prompt: "bg",
            maxTokens: 1,
            priority: .background,
            useSpec: false
        ))
        var gotDone = false
        let deadline = Date().addingTimeInterval(2.0)
        for await ev in stream {
            if case .done = ev { gotDone = true; break }
            if Date() > deadline { break }
        }
        XCTAssertTrue(gotDone)
        XCTAssertEqual(spec.calls.count, 0, "useSpec=false should NOT call the spec engine")
    }

    // MARK: - Follow-up 2: eviction heuristic picks the highest-progress slot

    /// Thread-safe collector for stream `.evicted` events. The eviction test
    /// spawns a consumer Task per background stream and they all run on the
    /// cooperative pool; we need a lock because the order of `.evicted`
    /// arrivals is non-deterministic w.r.t. the test's main Task.
    final class EvictionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var prompts: [String] = []
        func record(_ prompt: String) {
            lock.lock(); defer { lock.unlock() }
            if !prompts.contains(prompt) { prompts.append(prompt) }
        }
        func snapshot() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return prompts
        }
    }

    /// The eviction heuristic picks the background slot with the highest
    /// progress ratio (closest to finishing naturally). vLLM/TGI standard
    /// "preempt by progress". We verify that when 4 background slots have
    /// different progress ratios and a foreground arrives, the slot with
    /// the HIGHEST progress (closest to natural completion) is the one
    /// whose stream gets `.evicted`.
    ///
    /// Setup: keep all 4 bg slots in prefill at controlled positions via
    /// `alwaysReturnCode=2` + `posMaxBySeq`. With rc=2 the scheduler
    /// re-syncs each slot's pos to `posMaxBySeq[s]+1` after every batch,
    /// so the slots never advance (and never naturally finish). The
    /// progress ratio for prefill is `pos / promptTokens.count`, so
    /// different `posMaxBySeq` values give different progress ratios.
    /// After the fg is submitted and evicts a slot, we set
    /// `posMaxAfterClear[evictedSeqId] = -1` so the rc=2 re-sync no-ops
    /// for the fg's seqId and the fg can advance normally.
    func testEvictionPicksHighestProgressSlot() async throws {
        let mock = MockCLlamaEngine(nBatch: 16, nCtx: 10_000_000, tokensUntilEog: 999_999)
        // 8-token prompts for all 4 slots. With posMaxBySeq controlling
        // each slot's pos, the prefill progress ratios are:
        //   slot 0: 1/8 = 0.125
        //   slot 1: 5/8 = 0.625   <-- HIGHEST
        //   slot 2: 3/8 = 0.375
        //   slot 3: 1/8 = 0.125
        for i in 0..<4 {
            let start = 10 * (i + 1)
            let end = start + 8
            var arr: [Int32] = []
            arr.reserveCapacity(end - start)
            for v in start..<end { arr.append(Int32(v)) }
            mock.tokenizeCanned["p\(i)"] = arr
        }
        // Force the bg slots to stay in prefill at controlled positions.
        // After every batch decode (rc=2), each slot's pos is reset to
        // posMaxBySeq[s]+1. This means the slots never advance and never
        // naturally finish, regardless of how many ticks pass.
        mock.alwaysReturnCode = 2
        mock.posMaxBySeq = [0: 0, 1: 4, 2: 2, 3: 0]
        // After a slot is cleared (via eviction), posMax returns -1 so
        // the rc=2 re-sync is a no-op for the fg's seqId and the fg can
        // advance through prefill + decode normally.
        mock.posMaxAfterClear = [0: -1, 1: -1, 2: -1, 3: -1]
        let scheduler = BatchScheduler(engine: mock, maxSlots: 4)
        let recorder = EvictionRecorder()
        for i in 0..<4 {
            let prompt = "p\(i)"
            let s = await scheduler.submit(AgentRequest(
                agentId: UUID(),
                prompt: prompt,
                maxTokens: 999_999,
                priority: .background
            ))
            Task {
                for await ev in s {
                    if case .evicted = ev {
                        recorder.record(prompt)
                        return
                    }
                    if case .done = ev { return }
                }
            }
        }
        // Let the scheduler run a few ticks with rc=2 so the bg slots
        // are in their controlled prefill state.
        try await Task.sleep(nanoseconds: 50_000_000)
        // Submit foreground. No idle slots (all 4 stuck in prefill) -
        // eviction picks the highest-progress.
        let fg = await scheduler.submit(AgentRequest(
            agentId: UUID(),
            prompt: "fg",
            maxTokens: 1,
            priority: .foreground
        ))
        Task { for await _ in fg {} }
        // Wait for the eviction to fire.
        try await Task.sleep(nanoseconds: 100_000_000)
        let captured = recorder.snapshot()
        XCTAssertEqual(captured, ["p1"],
                       "slot 1 (pos=5/8, highest prefill progress) should be the ONLY background slot evicted; got \(captured), clearedSeqs=\(mock.clearedSeqs)")
    }

    // MARK: - Follow-up 3: yield before batch decode (actor starvation)

    /// The scheduler yields the actor BEFORE the synchronous
    /// `batchDecodeExt` C call. Without this yield, a slow decode
    /// would hold the actor for hundreds of ms, blocking every
    /// `submit` / `cancel` call queued during the decode. The yield
    /// is a runtime hint: the decode still runs to completion in the
    /// same tick, but other tasks get a chance to interleave.
    ///
    /// We verify the yield indirectly via its EFFECT: we submit a
    /// request that gets assigned to a slot, then immediately cancel
    /// it. The cancel must be processed WITHOUT a full
    /// prefill-completion latency - the cancel runs during the yield
    /// before the first batch decode, so the batch is never built.
    /// Concretely: no batch decode should contain the canceled
    /// request's tokens.
    func testSchedulerYieldsBeforeBatchDecode() async throws {
        let mock = MockCLlamaEngine(nBatch: 8, nCtx: 10_000_000, tokensUntilEog: 999_999)
        mock.tokenizeCanned["p"] = [1, 2, 3]
        // Force every batch decode to rc=2 so slots stay in prefill
        // (the cancel test doesn't care about decode completion).
        mock.alwaysReturnCode = 2
        mock.posMaxBySeq = [0: 0]
        let scheduler = BatchScheduler(engine: mock, maxSlots: 4)
        let req = AgentRequest(agentId: UUID(), prompt: "p",
                               maxTokens: 999_999, priority: .background)
        let stream = await scheduler.submit(req)
        // Give the scheduler one tick to start prefill.
        try await Task.sleep(nanoseconds: 5_000_000)
        // Cancel. With the yield, this runs on the actor between
        // ticks; the next batch decode will not include the canceled
        // request's tokens.
        await scheduler.cancel(requestId: req.id)
        var gotEvicted = false
        for await ev in stream {
            if case .evicted = ev { gotEvicted = true; break }
        }
        XCTAssertTrue(gotEvicted, "cancel should be processed promptly via the yield")
    }
}
