import Foundation

// MARK: - GhostTextProvider

/// Protocol for a completion backend consumed by TesseraGhostTextManager.
/// The implementation (TesseraStreamingPipeline) wraps TesseraEngineBridge
/// and adapts its AsyncThrowingStream to the manager's callback-based API.
///
/// Thread safety: @MainActor. All calls are bridged through @MainActor via
/// TesseraStreamingPipeline to match the editor's threading model.
@MainActor
public protocol GhostTextProvider: AnyObject {
    /// Returns a non-streaming completion string for the given text prompt.
    /// Used for P0 ghost text shell (no streaming).
    func completion(for prompt: String) async throws -> String

    /// Starts a streaming completion. `onEach` is called for each token.
    /// Returns the full completed string when the stream finishes.
    /// Throw to cancel; the provider checks `currentRequestID` on each token.
    func streamingCompletion(for prompt: String, onEach: @escaping @Sendable (String) -> Void) async throws -> String

    /// Cancels any in-flight streaming request.
    func cancelStreaming()
}
