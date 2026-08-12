import Foundation

// MARK: - DiffProvider

/// Protocol for a rewrite/diff backend consumed by TesseraDiffOverlayView.
/// Streaming diff: `rewriteStreaming` calls `onEach` with the partial rewritten
/// text as each token arrives, so the diff engine can incrementally compute
/// Myers diff against the original.
///
/// Thread safety: @MainActor. All calls are bridged through @MainActor via
/// TesseraStreamingPipeline to match the editor's threading model.
@MainActor
public protocol DiffProvider: AnyObject {
    /// Streams a rewrite of `originalText`. `onEach` receives the partial
    /// rewritten text so far. Returns the full rewritten string when done.
    func rewriteStreaming(originalText: String, mode: RewriteMode, onEach: @escaping @Sendable (String) -> Void) async throws -> String

    /// Cancels any in-flight rewrite request.
    func cancelRewrite()
}

// MARK: - RewriteMode

/// The style/mode for AI rewrite operations.
/// Mirrors the Apple Writing Tools preset tones.
public enum RewriteMode: String, Sendable, CaseIterable, Codable {
    case friendly = "friendly"
    case professional = "professional"
    case concise = "concise"
    case improve = "improve"
    case custom = "custom"

    public var systemPrompt: String {
        switch self {
        case .friendly: return "Rewrite the following text in a friendly, warm tone:"
        case .professional: return "Rewrite the following text in a professional, clear tone:"
        case .concise: return "Rewrite the following text to be more concise and to the point:"
        case .improve: return "Improve the following text, fixing any issues while keeping the meaning:"
        case .custom: return "Rewrite the following text:"
        }
    }
}
