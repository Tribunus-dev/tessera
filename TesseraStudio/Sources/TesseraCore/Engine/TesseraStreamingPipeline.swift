import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - TesseraStreamingPipeline

/// The streaming inference pipeline for Phase 11 AI features.
/// Wraps the existing TesseraEngineBridge and adapts its
/// AsyncThrowingStream to the callback-based GhostTextProvider and
/// DiffProvider APIs.
///
/// Thread safety: @MainActor. All public entry points are main-thread-only,
/// matching the editor's threading model.
@MainActor
public final class TesseraStreamingPipeline: GhostTextProvider, DiffProvider {

    // MARK: - Singleton

    public static let shared = TesseraStreamingPipeline()

    // MARK: - State

    private var engine: TesseraEngineBridge?
    /// Current in-flight request UUID — compared on each token to detect cancellation.
    private var currentRequestID: UUID?
    /// Current in-flight request kind for logging/debugging.
    private var currentRequestKind: String = ""

    /// Prompt cache for keystroke divergence: the last prompt used.
    private var lastPrompt: String = ""

    private init() {}

    // MARK: - Engine Wiring

    /// Inject the engine. Called once by the Coordinator after model load.
    public func setEngine(_ engine: TesseraEngineBridge) {
        self.engine = engine
    }

    // MARK: - GhostTextProvider

    public func completion(for prompt: String) async throws -> String {
        guard let engine = engine else {
            throw StreamingPipelineError.engineNotLoaded
        }
        guard engine.isModelLoaded else {
            throw StreamingPipelineError.modelNotLoaded
        }

        lastPrompt = prompt
        let requestID = UUID()
        currentRequestID = requestID
        currentRequestKind = "completion"

        var accumulated = ""
        let stream = engine.generate(prompt: prompt, maxTokens: 128)

        do {
            for try await token in stream {
                // Check cancellation
                if currentRequestID != requestID {
                    throw StreamingPipelineError.cancelled
                }
                accumulated += token.text
                // P0: no per-token callback for non-streaming
            }
        } catch {
            currentRequestID = nil
            if case StreamingPipelineError.cancelled = error {
                return ""
            }
            throw error
        }

        currentRequestID = nil
        return accumulated
    }

    public func streamingCompletion(for prompt: String, onEach: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let engine = engine else {
            throw StreamingPipelineError.engineNotLoaded
        }
        guard engine.isModelLoaded else {
            throw StreamingPipelineError.modelNotLoaded
        }

        lastPrompt = prompt
        let requestID = UUID()
        currentRequestID = requestID
        currentRequestKind = "streamingCompletion"

        var accumulated = ""
        let stream = engine.generate(prompt: prompt, maxTokens: 128)

        do {
            for try await token in stream {
                if currentRequestID != requestID {
                    throw StreamingPipelineError.cancelled
                }
                accumulated += token.text
                // Dispatch per-token callback on main actor
                let captured = accumulated
                Task { @MainActor in
                    onEach(captured)
                }
            }
        } catch {
            currentRequestID = nil
            if case StreamingPipelineError.cancelled = error {
                return ""
            }
            throw error
        }

        currentRequestID = nil
        return accumulated
    }

    public func cancelStreaming() {
        if currentRequestKind == "streamingCompletion" || currentRequestKind == "completion" {
            currentRequestID = nil
        }
    }

    // MARK: - DiffProvider

    public func rewriteStreaming(
        originalText: String,
        mode: RewriteMode,
        onEach: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let engine = engine else {
            throw StreamingPipelineError.engineNotLoaded
        }
        guard engine.isModelLoaded else {
            throw StreamingPipelineError.modelNotLoaded
        }

        let requestID = UUID()
        currentRequestID = requestID
        currentRequestKind = "rewrite"

        // Build prompt: system instruction + original text
        let prompt = """
        \(mode.systemPrompt)

        \(originalText)

        Rewritten version:
        """

        var accumulated = ""
        let stream = engine.generate(prompt: prompt, maxTokens: 512)

        do {
            for try await token in stream {
                if currentRequestID != requestID {
                    throw StreamingPipelineError.cancelled
                }
                accumulated += token.text
                let captured = accumulated
                Task { @MainActor in
                    onEach(captured)
                }
            }
        } catch {
            currentRequestID = nil
            if case StreamingPipelineError.cancelled = error {
                return ""
            }
            throw error
        }

        currentRequestID = nil
        return accumulated
    }

    public func cancelRewrite() {
        if currentRequestKind == "rewrite" {
            currentRequestID = nil
        }
    }
}

// MARK: - Errors

public enum StreamingPipelineError: Error, LocalizedError {
    case engineNotLoaded
    case modelNotLoaded
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .engineNotLoaded: return "Inference engine not loaded"
        case .modelNotLoaded: return "Model not loaded"
        case .cancelled: return "Request cancelled"
        }
    }
}
