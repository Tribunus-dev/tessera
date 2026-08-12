import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(STTextView)
import STTextView
#endif
import TesseraCore  // RewriteMode from DiffProvider.swift

// MARK: - TesseraStreamingDiffView

/// Coordinates the streaming diff overlay lifecycle:
/// - Subscribes to DiffProvider (TesseraStreamingPipeline)
/// - Computes incremental word-level diff on each token
/// - Positions the NSHostingView over the selected text rect
/// - Fires callbacks when user accepts/rejects
@MainActor
public final class TesseraStreamingDiffView: NSObject, ObservableObject {

    // MARK: - Published state

    @Published public private(set) var overlayState: DiffOverlayState = .idle
    @Published public private(set) var hostingView: NSView?

    // MARK: - Dependencies

    private weak var diffProvider: DiffProvider?
    private weak var textView: NSView?
    /// Called when user accepts the rewritten text. Provides (originalRange, rewrittenText).
    public var onAcceptRewrite: ((NSRange, String) -> Void)?
    /// Called when user rejects or cancels.
    public var onDismissOverlay: (() -> Void)?

    // MARK: - Internal State

    private var originalRange: NSRange?
    private var originalText: String = ""
    private var streamingTask: Task<Void, Never>?
    private var currentMode: RewriteMode = .improve

    // MARK: - Init

    public init(textView: NSView?, diffProvider: DiffProvider?) {
        self.textView = textView
        self.diffProvider = diffProvider
        super.init()
    }

    public func setDiffProvider(_ provider: DiffProvider?) {
        self.diffProvider = provider
    }

    // MARK: - Public API

    /// Start a streaming rewrite for `selectedRange` in the given `textView`.
    /// Marked @MainActor so it can access $overlayState for the hosting view.
    @MainActor
    public func startRewrite(
        originalText: String,
        selectedRange: NSRange,
        mode: RewriteMode,
        in textView: NSView
    ) {
        cancel()
        self.originalText = originalText
        self.originalRange = selectedRange
        self.currentMode = mode
        self.textView = textView

        // Show streaming state immediately
        overlayState = .streaming(
            originalRange: selectedRange,
            partialText: "",
            segments: [.unchanged(originalText)]
        )

        // Position overlay above the selected range
        positionOverlay(over: selectedRange, in: textView)

        // Accumulator for partial text
        var partial = ""

        // Start streaming
        streamingTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.diffProvider?.rewriteStreaming(
                    originalText: originalText,
                    mode: mode
                ) { [weak self] token in
                    guard let self = self else { return }
                    partial += token
                    let segments = self.computeDiff(original: originalText, rewritten: partial)
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.overlayState = .streaming(
                            originalRange: selectedRange,
                            partialText: partial,
                            segments: segments
                        )
                    }
                }
                // Stream complete — final diff
                let finalSegments = self.computeDiff(original: originalText, rewritten: partial)
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.overlayState = .diffComplete(
                        originalRange: selectedRange,
                        originalText: originalText,
                        rewrittenText: partial,
                        segments: finalSegments
                    )
                }
            } catch {
                // Cancelled or failed — dismiss
                await MainActor.run { [weak self] in
                    self?.dismiss()
                }
            }
        }
    }

    public func accept() {
        guard let range = originalRange else { return }
        if case .diffComplete(_, _, _, let segments) = overlayState {
            let fullRewritten = segments.map(\.text).joined()
            onAcceptRewrite?(range, fullRewritten)
        }
        dismiss()
    }

    public func reject() {
        onDismissOverlay?()
        dismiss()
    }

    public func cancel() {
        streamingTask?.cancel()
        diffProvider?.cancelRewrite()
        dismiss()
    }

    // MARK: - Diff

    /// Simple word-level LCS-based diff.
    /// Produces [DiffSegment] from original vs rewritten.
    /// Marked nonisolated so it can be called from streaming callbacks.
    private nonisolated func computeDiff(original: String, rewritten: String) -> [DiffSegment] {
        let originalWords = original.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let rewrittenWords = rewritten.split(separator: " ", omittingEmptySubsequences: false).map(String.init)

        var result: [DiffSegment] = []
        var i = 0, j = 0

        while i < originalWords.count || j < rewrittenWords.count {
            if i < originalWords.count && j < rewrittenWords.count && originalWords[i] == rewrittenWords[j] {
                result.append(.unchanged(originalWords[i]))
                i += 1; j += 1
            } else if j < rewrittenWords.count && (i >= originalWords.count || shouldInsert(word: rewrittenWords[j], inOriginal: originalWords, fromIndex: i)) {
                result.append(.added(rewrittenWords[j]))
                j += 1
            } else {
                result.append(.deleted(originalWords[i]))
                i += 1
            }
        }

        return collapseSegments(result)
    }

    /// Heuristic: prefer insertion when the rewritten word doesn't appear later in original.
    private nonisolated func shouldInsert(word: String, inOriginal: [String], fromIndex: Int) -> Bool {
        let remainingOriginal = Array(inOriginal.dropFirst(fromIndex))
        return !remainingOriginal.contains(word)
    }

    /// Collapse consecutive segments of the same type.
    private nonisolated func collapseSegments(_ segments: [DiffSegment]) -> [DiffSegment] {
        guard !segments.isEmpty else { return [] }
        var result: [DiffSegment] = [segments[0]]
        for segment in segments.dropFirst() {
            if let last = result.last,
               Swift.type(of: segment) == Swift.type(of: last) {
                let mergedText = last.text + " " + segment.text
                switch result.removeLast() {
                case .unchanged: result.append(.unchanged(mergedText))
                case .added:     result.append(.added(mergedText))
                case .deleted:   result.append(.deleted(mergedText))
                }
            } else {
                result.append(segment)
            }
        }
        return result
    }

    // MARK: - Overlay Positioning

    @MainActor
    private func positionOverlay(over range: NSRange, in textView: NSView) {
        guard let stTextView = textView as? STTextView else { return }

        // Use the standard NSTextView method to get the rect for the character range.
        var actualRange: NSRange = NSRange(location: 0, length: 0)
        let overlayRect = stTextView.firstRect(forCharacterRange: range, actualRange: &actualRange)

        // Capture the binding explicitly to satisfy the type checker in this
        // @MainActor context where @Published projects as Binding on this actor.
        let stateBinding = Binding(
            get: { self.overlayState },
            set: { self.overlayState = $0 }
        )

        // Create and position the hosting view 120pt above the text
        let rootView = TesseraDiffOverlayView(
            state: stateBinding,
            mode: currentMode,
            onAccept: { [weak self] in self?.accept() },
            onReject: { [weak self] in self?.reject() }
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(
            x: overlayRect.origin.x,
            y: overlayRect.origin.y - 120,
            width: min(max(overlayRect.width, 300), 600),
            height: 120
        )

        textView.addSubview(hosting)
        self.hostingView = hosting
    }

    private func dismiss() {
        hostingView?.removeFromSuperview()
        hostingView = nil
        overlayState = .idle
    }
}
