import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - GhostTextState

/// Transient UI state for one active ghost text session.
/// All mutations must happen on @MainActor.
@MainActor
public struct GhostTextState: Sendable {
    /// Character range in the text storage where ghost text is rendered.
    public var range: NSRange
    /// How many words have been accepted so far (for partial-accept).
    public var acceptedWordCount: Int
    /// UUID of the in-flight request; nil if none.
    public var inFlightID: UUID?
    /// The full ghost text string.
    public var text: String
    /// The base typing attributes at the caret (font, color, etc.) for rendering.
    public var baseAttributes: [NSAttributedString.Key: Any]

    public init(
        range: NSRange,
        acceptedWordCount: Int = 0,
        inFlightID: UUID? = nil,
        text: String = "",
        baseAttributes: [NSAttributedString.Key: Any] = [:]
    ) {
        self.range = range
        self.acceptedWordCount = acceptedWordCount
        self.inFlightID = inFlightID
        self.text = text
        self.baseAttributes = baseAttributes
    }
}

// MARK: - GhostTextDisplayAttributes

/// Visual attributes for ghost text: inherits base typing attributes
/// but applies the ghost text color override (40% opacity, ~tertiaryLabelColor).
/// Per the SOTA research: ghost text is a variant of the base input token system,
/// not a standalone layer. Only three overrides: dimmed color, transparent bg, 80ms transition.
public struct GhostTextDisplayAttributes {
    public let attributes: [NSAttributedString.Key: Any]

    public init(baseAttributes: [NSAttributedString.Key: Any]) {
        var attrs = baseAttributes
        // Dimmed foreground: tertiaryLabelColor or ~40% opacity
        if let existingColor = attrs[.foregroundColor] as? NSColor {
            attrs[.foregroundColor] = existingColor.withAlphaComponent(0.4)
        } else {
            attrs[.foregroundColor] = NSColor.tertiaryLabelColor
        }
        self.attributes = attrs
    }
}

// MARK: - LocalGhostTextProvider
//
// STUB — replaced by the real GhostTextProvider from Agent 2 (Streaming) during
// the integration merge. Naming convention follows phase11-integration-plan.md:
//   stub: LocalGhostTextProvider
//   real: GhostTextProvider  (Agent 2's TesseraStreamingPipeline conforms to this)

public protocol LocalGhostTextProvider: AnyObject, Sendable {
    /// Returns a non-streaming completion string for the current context.
    func completion(for prompt: String) async throws -> String
    /// Starts a streaming completion; onEach is called per token.
    func streamingCompletion(
        for prompt: String,
        onEach: @escaping @Sendable (String) -> Void
    ) async throws -> String
    /// Cancels any in-flight streaming request.
    func cancelStreaming()
}

// MARK: - GhostTextManagerDelegate

/// Called by GhostTextManager to apply changes to the text view.
/// The delegate is always @MainActor.
@MainActor
public protocol GhostTextManagerDelegate: AnyObject {
    /// Render ghost text at `range` with the given attributed string.
    func ghostTextManager(
        _ manager: TesseraGhostTextManager,
        renderGhostText attributedString: NSAttributedString,
        at range: NSRange
    )
    /// Remove ghost text at `range` and restore the caret to `caretLocation`.
    func ghostTextManager(
        _ manager: TesseraGhostTextManager,
        removeGhostTextAt range: NSRange,
        caretLocation: Int
    )
    /// Accept: replace the ghost text range with committed text and move caret.
    func ghostTextManager(
        _ manager: TesseraGhostTextManager,
        acceptGhostTextAt range: NSRange,
        committedText: NSAttributedString
    )
    /// Commit only `count` words from the ghost text and advance acceptedCount.
    func ghostTextManager(
        _ manager: TesseraGhostTextManager,
        acceptPartialGhostTextAt range: NSRange,
        wordCount: Int,
        remainingGhostText: NSAttributedString
    )
}

// MARK: - TesseraGhostTextManager

/// Manages the ghost text lifecycle: debounce, triggering, acceptance, dismissal.
/// Uses a GhostTextProvider (typically TesseraStreamingPipeline) for completions.
///
/// Thread safety: all public entry points are @MainActor. The provider call is
/// async but initiated from the main thread.
@MainActor
public final class TesseraGhostTextManager {

    // MARK: - Dependencies

    public weak var delegate: GhostTextManagerDelegate?
    private weak var provider: LocalGhostTextProvider?

    // MARK: - State

    private var state: GhostTextState?
    private var debounceWorkItem: DispatchWorkItem?
    private var keystrokeTimestamp: Date = .distantPast

    /// The last prompt sent to the provider; used for keystroke divergence check.
    private var lastPrompt: String = ""

    /// Debounce interval: 300ms is the SOTA consensus (200–500ms range).
    public var debounceInterval: TimeInterval = 0.3

    // MARK: - Init

    public init(provider: LocalGhostTextProvider?) {
        self.provider = provider
    }

    /// Replace the provider at runtime (e.g., when streaming pipeline is wired up).
    public func setProvider(_ provider: LocalGhostTextProvider?) {
        self.provider = provider
    }

    // MARK: - Public API

    /// Call from keyDown when user types a character. Returns true if the
    /// ghost text was cancelled due to divergence, false if no ghost text was active.
    public func onKeystroke(character: String, prompt: String) -> Bool {
        keystrokeTimestamp = Date()

        guard let state = state else { return false }

        // Check divergence: does the typed character match what ghost text expects?
        // offset is how far into the ghost text we've "pre-typed" via acceptance
        let acceptedLen = state.text.prefix(state.acceptedWordCount > 0 ? countUTF16Prefix(state.text, words: state.acceptedWordCount) : 0).utf16.count
        let offset = state.range.location - state.text.utf16.count + acceptedLen

        if offset >= 0 && offset < state.text.utf16.count {
            // UTF-16 safe: check by offset into the UTF-16 view
            let ghostUTF16 = Array(state.text.utf16)
            if offset < ghostUTF16.count {
                let expectedUTF16 = ghostUTF16[offset]
                if character.utf16.first != expectedUTF16 {
                    cancelAndDismiss()
                    return true
                }
            }
        }

        // Restart debounce on every keystroke
        restartDebounce(prompt: prompt)
        return false
    }

    /// Accept the full ghost text suggestion.
    public func acceptFull() {
        guard let state = state, let delegate = delegate else { return }
        let committed = NSAttributedString(
            string: state.text,
            attributes: GhostTextDisplayAttributes(baseAttributes: state.baseAttributes).attributes
        )
        delegate.ghostTextManager(self, acceptGhostTextAt: state.range, committedText: committed)
        clearState()
    }

    /// Accept the next word from the ghost text.
    public func acceptNextWord() {
        guard let state = state, let delegate = delegate else { return }

        let words = state.text.split(separator: " ", omittingEmptySubsequences: false)
        let newAcceptedCount = state.acceptedWordCount + 1

        guard newAcceptedCount <= words.count else {
            acceptFull()
            return
        }

        // Committed portion: first `newAcceptedCount` words
        let committedWords = words.prefix(newAcceptedCount)
        let committedStr = committedWords.joined(separator: " ")

        // Remaining portion
        let remainingWords = words.dropFirst(newAcceptedCount)
        let remainingStr = remainingWords.joined(separator: " ")

        // Build attributed strings
        let committedAttr = NSAttributedString(string: committedStr, attributes: state.baseAttributes)
        let remainingAttr = NSAttributedString(
            string: remainingStr,
            attributes: GhostTextDisplayAttributes(baseAttributes: state.baseAttributes).attributes
        )

        // Adjust range: shrink from left by committed length, shift location right
        let committedLen = committedStr.utf16.count
        let combinedAttrLen = committedLen + remainingStr.utf16.count
        let newRange = NSRange(location: state.range.location + committedLen, length: state.range.length - committedLen)

        // Notify delegate to replace ghost text range with [committed + remaining_ghost]
        let combined = NSMutableAttributedString(attributedString: committedAttr)
        combined.append(remainingAttr)
        delegate.ghostTextManager(
            self,
            renderGhostText: combined,
            at: NSRange(location: state.range.location, length: combined.length)
        )
        // Update state
        self.state = GhostTextState(
            range: newRange,
            acceptedWordCount: newAcceptedCount,
            inFlightID: nil,
            text: remainingStr,
            baseAttributes: state.baseAttributes
        )
    }

    /// Dismiss the ghost text without accepting.
    public func dismiss() {
        guard let state = state, let delegate = delegate else { return }
        let caretLocation = state.range.location
        delegate.ghostTextManager(self, removeGhostTextAt: state.range, caretLocation: caretLocation)
        clearState()
    }

    /// Cancel in-flight request and dismiss.
    public func cancelAndDismiss() {
        provider?.cancelStreaming()
        debounceWorkItem?.cancel()
        dismiss()
    }

    /// Trigger a new completion request after debounce.
    public func triggerCompletion(prompt: String, baseAttributes: [NSAttributedString.Key: Any]) {
        lastPrompt = prompt
        restartDebounce(prompt: prompt, baseAttributes: baseAttributes)
    }

    // MARK: - Private

    private func restartDebounce(
        prompt: String,
        baseAttributes: [NSAttributedString.Key: Any]? = nil
    ) {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                await self?.requestCompletion(prompt: prompt, baseAttributes: baseAttributes)
            }
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func requestCompletion(
        prompt: String,
        baseAttributes: [NSAttributedString.Key: Any]?
    ) async {
        guard let provider = provider else { return }

        // Check staleness: did the prompt change while we were waiting?
        guard lastPrompt == prompt, state == nil else { return }

        do {
            let completion = try await provider.completion(for: prompt)

            // Second staleness check after await
            guard lastPrompt == prompt, state == nil else { return }

            let attrs = baseAttributes ?? [:]
            let ghostAttr = NSAttributedString(
                string: completion,
                attributes: GhostTextDisplayAttributes(baseAttributes: attrs).attributes
            )
            let range = NSRange(location: lastCaretLocation, length: completion.utf16.count)

            state = GhostTextState(range: range, text: completion, baseAttributes: attrs)
            delegate?.ghostTextManager(self, renderGhostText: ghostAttr, at: range)
        } catch {
            // Cancelled or failed silently
            clearState()
        }
    }

    private func clearState() {
        state = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    /// UTF-16 prefix length for the first `wordCount` space-separated words.
    private func countUTF16Prefix(_ str: String, words: Int) -> Int {
        guard words > 0 else { return 0 }
        let allWords = str.split(separator: " ", omittingEmptySubsequences: false)
        let prefix = allWords.prefix(words).joined(separator: " ")
        return prefix.utf16.count
    }

    // MARK: - Placeholder stubs
    //
    // Replaced by @MainActor calls once wired into TesseraSTTextView.
    // These exist so TesseraGhostTextManager compiles without a concrete delegate.
    // The real implementations are in TesseraSTTextView (GhostTextManagerDelegate).

    /// Returns the current caret location in the text storage.
    /// Override/assign this when embedded in a text view.
    public var lastCaretLocation: Int { _lastCaretLocation }
    private var _lastCaretLocation: Int = 0

    /// Call from the text view to update the caret location.
    public func updateCaretLocation(_ location: Int) {
        _lastCaretLocation = location
    }
}
