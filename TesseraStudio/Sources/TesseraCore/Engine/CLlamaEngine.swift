import Foundation
import CLlama

/// Thin Swift protocol over the C shim so `BatchScheduler` can be tested
/// without a real libllama. The production implementation (`CLlamaEngineImpl`)
/// wraps the global `cllama_*` C functions; tests inject `MockCLlamaEngine`
/// to record calls and drive the scheduler's batch-construction logic.
///
/// Every method here is the exact surface `BatchScheduler` needs - no more.
/// If a new C call gets added to the scheduler, add it here too.
public protocol CLlamaEngine {
    /// Vocab size of the model. Drives the logits readback buffer size.
    var nVocab: Int { get }

    /// Logical maximum batch size (tokens per `llama_decode` call).
    var nBatch: Int { get }

    /// Context size in tokens. Used to reject requests that won't fit
    /// (prompt + maxTokens > nCtx) before starting prefill.
    var nCtx: Int { get }

    /// Tokenize a prompt into a freshly-allocated buffer (caller frees with
    /// `tokenizeFree`). Returns the count, or -1 on error.
    func tokenizeAlloc(_ text: String, addBos: Bool, parseSpecial: Bool) -> (count: Int, buffer: UnsafeMutablePointer<Int32>?)

    /// Free a buffer returned by `tokenizeAlloc`. The default just calls
    /// `free()`; exposed so tests can replace it with a counted allocator.
    func tokenizeFree(_ buffer: UnsafeMutablePointer<Int32>)

    /// Submit a mixed prefill+decode batch. Returns the libllama return
    /// code: 0 = success, 1 = no KV slot, 2 = aborted, -1 = error,
    /// -2 = batch surface unavailable.
    func batchDecodeExt(
        tokens: UnsafePointer<Int32>,
        seqIds: UnsafePointer<Int32>,
        positions: UnsafePointer<Int32>,
        logitsFlags: UnsafePointer<Int8>,
        n: Int32
    ) -> Int32

    /// Read the logits row for batch position `i` (BATCH position, 0-indexed
    /// within the last batch_decode call). Returns true on success; fills
    /// `outBuf` with `nVocab` floats. Returns false if the position had
    /// logits=false or is out of range.
    func getLogitsIth(_ i: Int32, outBuf: UnsafeMutablePointer<Float>, nVocab: Int32) -> Bool

    /// Largest position present in the sequence's KV cells, or -1 if empty.
    /// Used after a return-code-2 (aborted) decode to re-sync the slot's
    /// `pos` to what actually got committed.
    func slotPosMax(_ seqId: Int32) -> Int32

    /// Clear (evict) a sequence's KV cells. The slot becomes empty.
    func slotClear(_ seqId: Int32)

    /// Convert a token id to a UTF-8 text piece. Returns "" on failure.
    func tokenToPiece(_ tokenId: Int32) -> String

    /// True if the token is an end-of-generation marker.
    func tokenIsEog(_ tokenId: Int32) -> Bool
}

/// Production implementation - wraps the global `cllama_*` C functions.
struct CLlamaEngineImpl: CLlamaEngine {
    let engine: OpaquePointer
    let nVocab: Int
    let nBatch: Int
    let nCtx: Int

    init?(engine: OpaquePointer) {
        let nv = Int(cllama_engine_n_vocab(engine))
        let nb = Int(cllama_engine_n_batch(engine))
        let nc = Int(cllama_engine_n_ctx(engine))
        guard nv > 0, nb > 0 else { return nil }
        self.engine = engine
        self.nVocab = nv
        self.nBatch = nb
        self.nCtx = nc
    }

    func tokenizeAlloc(_ text: String, addBos: Bool, parseSpecial: Bool) -> (count: Int, buffer: UnsafeMutablePointer<Int32>?) {
        var buf: UnsafeMutablePointer<Int32>? = nil
        let n = text.withCString { cstr -> Int32 in
            cllama_engine_tokenize_alloc(engine, cstr, addBos ? 1 : 0, parseSpecial ? 1 : 0, &buf)
        }
        return (Int(n), buf)
    }

    func tokenizeFree(_ buffer: UnsafeMutablePointer<Int32>) {
        free(buffer)
    }

    func batchDecodeExt(
        tokens: UnsafePointer<Int32>,
        seqIds: UnsafePointer<Int32>,
        positions: UnsafePointer<Int32>,
        logitsFlags: UnsafePointer<Int8>,
        n: Int32
    ) -> Int32 {
        cllama_engine_batch_decode_ext(engine, tokens, seqIds, positions, logitsFlags, n)
    }

    func getLogitsIth(_ i: Int32, outBuf: UnsafeMutablePointer<Float>, nVocab: Int32) -> Bool {
        cllama_get_logits_ith(engine, i, outBuf, nVocab) == 0
    }

    func slotPosMax(_ seqId: Int32) -> Int32 {
        cllama_slot_pos_max(engine, seqId)
    }

    func slotClear(_ seqId: Int32) {
        cllama_slot_clear(engine, seqId)
    }

    func tokenToPiece(_ tokenId: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 64)
        let n = buf.withUnsafeMutableBufferPointer { bp -> Int32 in
            cllama_token_to_piece_str(engine, tokenId, bp.baseAddress, Int32(bp.count))
        }
        return n > 0 ? String(cString: buf) : ""
    }

    func tokenIsEog(_ tokenId: Int32) -> Bool {
        cllama_token_is_eog(engine, tokenId) != 0
    }
}
