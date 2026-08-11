import Foundation
import CLlama

/// Errors that the spec engine can surface to a caller.
public enum CLlamaSpecEngineError: Error, Equatable, Sendable {
    /// The spec library (`libllama-common.dylib`) was not loaded.
    case libraryUnavailable
    /// The spec engine was not built (trunk+drafter not loaded).
    case engineUnavailable
    /// The spec engine returned a negative token count from
    /// `cllama_engine_generate_spec`.
    case generateFailed
    /// Another generation is already running on this spec engine.
    /// The spec engine is single-sequence; concurrent calls serialize on a
    /// background queue. The caller can either wait for the next free
    /// slot or fall back to the batched engine.
    case busy
}

/// Thin Swift protocol over the spec C shim. Mirrors the surface that
/// `cllama_engine_generate_spec` exposes, exposed as an
/// `AsyncThrowingStream<String, Error>` so the Swift side can integrate it
/// with the `BatchScheduler`'s event-based model.
///
/// The spec engine is single-sequence by design: only one generation runs
/// at a time. Concurrent calls serialize on a background queue; the
/// second caller gets `busy` if it does not want to wait.
public protocol CLlamaSpecEngine: Sendable {
    /// True if the spec library AND the spec engine are both loaded.
    var isLoaded: Bool { get }

    /// Run a single generation. Tokens are yielded as they are accepted by
    /// the speculative decoder. The whole call runs on a background
    /// queue (off-actor) so the `BatchScheduler` actor remains responsive.
    /// The stream finishes after the last accepted token; an error
    /// terminator signals failure.
    func generate(prompt: String, maxTokens: Int, telemetryTopK: Int) -> AsyncThrowingStream<String, Error>
}

/// Production implementation. Wraps the global `cllama_*` spec
/// functions. Concurrent calls serialize on a dedicated serial queue
/// (the spec engine is single-sequence).
public final class CLlamaSpecEngineImpl: CLlamaSpecEngine, @unchecked Sendable {
    private let engine: OpaquePointer
    private let queue: DispatchQueue

    public var isLoaded: Bool { true }

    public init(engine: OpaquePointer) {
        self.engine = engine
        self.queue = DispatchQueue(label: "com.tessera.spec-engine", qos: .userInitiated)
    }

    public func generate(prompt: String, maxTokens: Int, telemetryTopK: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error> { (cont: AsyncThrowingStream<String, Error>.Continuation) in
            // C function pointers can't capture Swift context. Box the
            // continuation + prompt through userData using Unmanaged, so
            // the C callback can recover the Swift objects. The queue
            // holds the box for the duration of the generation.
            let box = SpecGenerationBox(prompt: prompt, continuation: cont)
            let userData = Unmanaged.passRetained(box).toOpaque()
            queue.async {
                let eng = self.engine
                let topK = Int32(telemetryTopK)
                let maxT = Int32(maxTokens)
                let cb: cllama_token_callback = { piece, _, ctx in
                    guard let ctx, let piece else { return }
                    let b = Unmanaged<SpecGenerationBox>.fromOpaque(ctx).takeUnretainedValue()
                    let s = String(cString: piece)
                    b.continuation.yield(s)
                }
                // on_trace is unused in v1; pass NULL.
                let n = box.prompt.withCString { cstr -> Int32 in
                    cllama_engine_generate_spec(eng, cstr, maxT, topK, cb, nil, userData)
                }
                if n < 0 {
                    cont.finish(throwing: CLlamaSpecEngineError.generateFailed)
                } else {
                    cont.finish()
                }
                Unmanaged<SpecGenerationBox>.fromOpaque(userData).release()
            }
        }
    }
}

/// Box passed through the C callback's `userData` parameter. The
/// callback can't capture Swift context, so we box the continuation
/// and the prompt here. The serial queue retains the box for the
/// duration of the generation and releases it once the C call returns.
private final class SpecGenerationBox: @unchecked Sendable {
    let prompt: String
    let continuation: AsyncThrowingStream<String, Error>.Continuation
    init(prompt: String, continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.prompt = prompt
        self.continuation = continuation
    }
}

/// Null-object for tests and the no-spec-library case.
public final class NullCLlamaSpecEngine: CLlamaSpecEngine, Sendable {
    public init() {}
    public var isLoaded: Bool { false }
    public func generate(prompt: String, maxTokens: Int, telemetryTopK: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: CLlamaSpecEngineError.libraryUnavailable)
        }
    }
}
