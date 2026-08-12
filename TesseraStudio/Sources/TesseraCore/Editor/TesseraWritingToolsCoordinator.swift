import Foundation
#if canImport(AppKit)
import AppKit

// MARK: - TesseraWritingToolsTextViewProtocol

/// Minimal protocol for the Writing Tools coordinator to interact with a text view
/// without depending on TesseraStudioMac. Adopt this in TesseraSTTextView.
@available(macOS 15.2, *)
public protocol TesseraWritingToolsTextViewProtocol: AnyObject {
    var textContentManager: NSTextContentManager? { get }
    /// Returns the current selection range. Must match STTextView's @objc selectedRange() -> NSRange.
    func selectedRange() -> NSRange
}

// MARK: - TesseraWritingToolsCoordinator

/// Coordinates between Apple Writing Tools and Tessera's custom TextKit 2 text engine.
///
/// Apple Writing Tools provides a system-wide AI rewrite/proofread/summarize
/// experience. For custom text engines (like Tessera's STTextView subclass),
/// the system exposes `NSWritingToolsCoordinator` as the integration point.
///
/// Tessera adopts the full Tier 3 integration: the coordinator manages the
/// bidirectional conversation between Writing Tools and the editor.
/// The delegate methods handle text context delivery, replacement application,
/// and animation coordination.
///
/// Reference:
/// - https://developer.apple.com/documentation/appkit/adding-writing-tools-support-to-a-custom-nsview
/// - https://developer.apple.com/videos/play/wwdc2025/265/
@available(macOS 15.2, *)
@MainActor
public final class TesseraWritingToolsCoordinator: NSObject {

    // MARK: - Dependencies

    /// The text view we're coordinating with. Stored as AnyObject to avoid
    /// a cross-target dependency on TesseraSTTextView (TesseraStudioMac).
    /// Cast to TesseraWritingToolsTextViewProtocol to call protocol methods.
    public weak var textView: AnyObject?

    /// The content manager for reading/writing text.
    public weak var contentManager: TesseraTextContentManager?

    // MARK: - Coordinator

    /// The NSWritingToolsCoordinator. Created lazily once per text view.
    private var _coordinator: NSWritingToolsCoordinator?

    public var coordinator: NSWritingToolsCoordinator {
        if let existing = _coordinator { return existing }
        let c = NSWritingToolsCoordinator(delegate: self)
        _coordinator = c
        return c
    }

    // MARK: - State

    /// Controls whether Writing Tools uses full inline animation (.complete)
    /// or panel-only (.limited). Expose this as a per-block setting:
    /// sensitive blocks should use .none.
    public var writingToolsBehavior: NSWritingToolsBehavior = .complete {
        didSet {
            // Attach/detach coordinator based on behavior
            if let view = textView as? NSView {
                view.writingToolsCoordinator = writingToolsBehavior == .none ? nil : coordinator
            }
        }
    }

    /// The delegate receives callbacks for context building and text replacement.
    public weak var rewriteDelegate: TesseraWritingToolsRewriteDelegate?

    // MARK: - Init

    public init(textView: AnyObject?, contentManager: TesseraTextContentManager?) {
        self.textView = textView
        self.contentManager = contentManager
        super.init()
    }

    /// Activate Writing Tools integration on the text view.
    public func activate() {
        guard let view = textView as? NSView else { return }
        view.writingToolsCoordinator = coordinator
    }

    /// Deactivate Writing Tools (e.g., when the view is dismissed).
    public func deactivate() {
        if let view = textView as? NSView {
            view.writingToolsCoordinator = nil
        }
    }
}

// MARK: - NSWritingToolsCoordinator.Delegate

/// The delegate is @MainActor to match NSWritingToolsCoordinator (SwiftUI actor).
/// Mark the extension @MainActor so all protocol methods satisfy nonisolated requirements.
@available(macOS 15.2, *)
@MainActor
extension TesseraWritingToolsCoordinator: NSWritingToolsCoordinator.Delegate {

    // MARK: - Core required methods

    /// Writing Tools requests text context(s) to operate on.
    /// Provide: NSAttributedString (selection + surrounding paragraphs) + selection NSRange.
    public func writingToolsCoordinator(
        _ coordinator: NSWritingToolsCoordinator,
        requestsContextsFor scope: NSWritingToolsCoordinator.ContextScope,
        completion: @escaping @Sendable ([NSWritingToolsCoordinator.Context]) -> Void
    ) {
        guard let tv = textView as? TesseraWritingToolsTextViewProtocol,
              let contentManager = tv.textContentManager as? NSTextContentStorage,
              let storage = contentManager.textStorage else {
            completion([])
            return
        }

        let fullText = storage
        let selectedRange = tv.selectedRange()

        // Scope determines how much context to include:
        // .userSelection → selection + surrounding text
        // .fullDocument → whole document
        // .visibleArea → currently visible text
        let contextRange: NSRange
        let contextText: NSAttributedString

        switch scope {
        case .userSelection:
            // Include surrounding paragraph for context
            let text = storage.string as NSString
            let selParagraph = findParagraph(containing: selectedRange.location, in: text as String)
            contextRange = NSRange(
                location: max(0, selParagraph.location),
                length: min(selParagraph.length, text.length - max(0, selParagraph.location))
            )
            contextText = fullText.attributedSubstring(from: contextRange)

        case .fullDocument:
            contextRange = NSRange(location: 0, length: fullText.length)
            contextText = fullText

        case .visibleArea:
            // Use the selected paragraph as a proxy for the visible area
            let text = storage.string as NSString
            let selParagraph = findParagraph(containing: selectedRange.location, in: text as String)
            contextRange = NSRange(
                location: max(0, selParagraph.location),
                length: min(selParagraph.length, text.length - max(0, selParagraph.location))
            )
            contextText = fullText.attributedSubstring(from: contextRange)

        @unknown default:
            contextRange = selectedRange
            contextText = fullText.attributedSubstring(from: selectedRange)
        }

        // Build context: the NSRange in contextText that corresponds to the selection
        let context = NSWritingToolsCoordinator.Context(
            attributedString: contextText,
            range: NSRange(
                location: max(0, selectedRange.location - contextRange.location),
                length: min(selectedRange.length, contextText.length)
            )
        )
        completion([context])
    }

    /// Writing Tools proposes a text replacement. Apply it and call completion.
    public func writingToolsCoordinator(
        _ coordinator: NSWritingToolsCoordinator,
        replace range: NSRange,
        in context: NSWritingToolsCoordinator.Context,
        proposedText: NSAttributedString,
        reason: NSWritingToolsCoordinator.TextReplacementReason,
        animationParameters: NSWritingToolsCoordinator.AnimationParameters?,
        completion: @escaping @Sendable (NSAttributedString?) -> Void
    ) {
        // Convert the context-relative range to a document range
        let docRangeStart = context.range.location
        let docRange = NSRange(location: docRangeStart + range.location, length: range.length)

        // Apply replacement via the rewrite delegate (or directly to text storage)
        if let delegate = rewriteDelegate {
            delegate.tesseraWritingToolsCoordinator(
                self,
                applyReplacement: proposedText,
                at: docRange,
                originalContextRange: context.range
            )
        } else if let tv = textView as? TesseraWritingToolsTextViewProtocol,
                  let contentManager = tv.textContentManager as? NSTextContentStorage,
                  let storage = contentManager.textStorage {
            // Fallback: direct storage edit
            storage.replaceCharacters(in: docRange, with: proposedText)
        }

        // Return the applied attributed string so Writing Tools can track the change
        completion(proposedText)
    }

    /// Prepare for a text animation: hide the affected text range so Writing Tools
    /// can show its own preview during the morph.
    public func writingToolsCoordinator(
        _ coordinator: NSWritingToolsCoordinator,
        prepareFor textAnimation: NSWritingToolsCoordinator.TextAnimation,
        for range: NSRange,
        in context: NSWritingToolsCoordinator.Context,
        completion: @escaping @Sendable () -> Void
    ) {
        guard let tv = textView as? TesseraWritingToolsTextViewProtocol,
              let contentManager = tv.textContentManager as? NSTextContentStorage,
              let storage = contentManager.textStorage else {
            completion()
            return
        }

        // Convert context-relative range to document range
        let docRangeStart = context.range.location
        let docRange = NSRange(location: docRangeStart + range.location, length: range.length)

        switch textAnimation {
        case .remove:
            // Fade out: dim the text at the range
            storage.enumerateAttribute(.foregroundColor, in: docRange, options: []) { _, attrRange, _ in
                guard attrRange.location + attrRange.length <= storage.length else { return }
                let mutable = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: attrRange))
                mutable.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: NSRange(location: 0, length: mutable.length))
                storage.replaceCharacters(in: attrRange, with: mutable)
            }

        case .insert:
            // Dim the text at the insertion point
            break

        case .anticipate, .anticipateInactive:
            // Morphing/waiting animation: dim the range during evaluation
            guard docRange.location + docRange.length <= storage.length else {
                completion()
                return
            }
            let mutable = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: docRange))
            mutable.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: NSRange(location: 0, length: mutable.length))
            storage.replaceCharacters(in: docRange, with: mutable)

        default:
            break
        }

        completion()
    }

    /// Animation finished: restore the text to normal appearance.
    public func writingToolsCoordinator(
        _ coordinator: NSWritingToolsCoordinator,
        finish textAnimation: NSWritingToolsCoordinator.TextAnimation,
        for range: NSRange,
        in context: NSWritingToolsCoordinator.Context,
        completion: @escaping @Sendable () -> Void
    ) {
        guard let tv = textView as? TesseraWritingToolsTextViewProtocol,
              let contentManager = tv.textContentManager as? NSTextContentStorage,
              let storage = contentManager.textStorage else {
            completion()
            return
        }

        let docRangeStart = context.range.location
        let docRange = NSRange(location: docRangeStart + range.location, length: range.length)

        // Restore original foreground color (remove the tertiaryLabelColor override)
        // The BlockRenderer will re-render on next paint.
        storage.enumerateAttribute(.foregroundColor, in: docRange, options: []) { _, attrRange, _ in
            guard attrRange.location + attrRange.length <= storage.length else { return }
            let mutable = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: attrRange))
            // Remove the dim override
            mutable.removeAttribute(.foregroundColor, range: NSRange(location: 0, length: mutable.length))
            storage.replaceCharacters(in: attrRange, with: mutable)
        }

        completion()
    }

    /// Session lifecycle: respond to Writing Tools starting/ending.
    public func writingToolsCoordinator(
        _ coordinator: NSWritingToolsCoordinator,
        willChangeTo state: NSWritingToolsCoordinator.State,
        completion: @escaping @Sendable () -> Void
    ) {
        switch state {
        case .inactive:
            // Session ended: clean up any transient state
            break
        case .noninteractive, .interactiveResting, .interactiveStreaming:
            // Session started: optionally pause other editor features
            break
        @unknown default:
            break
        }
        completion()
    }

    // MARK: - Selection management (required)

    public func writingToolsCoordinator(
        _ coordinator: NSWritingToolsCoordinator,
        select ranges: [NSValue],
        in context: NSWritingToolsCoordinator.Context,
        completion: @escaping @Sendable () -> Void
    ) {
        // Tessera tracks selection via STTextView; Writing Tools drives this.
        // We defer to the view's own selection handling.
        completion()
    }

    // MARK: - Bézier paths for proofreading marks (required stubs)

    public func writingToolsCoordinator(
        _ coordinator: NSWritingToolsCoordinator,
        requestsBoundingBezierPathsFor range: NSRange,
        in context: NSWritingToolsCoordinator.Context,
        completion: @escaping @Sendable ([NSBezierPath]) -> Void
    ) {
        completion([])
    }

    public func writingToolsCoordinator(
        _ coordinator: NSWritingToolsCoordinator,
        requestsUnderlinePathsFor range: NSRange,
        in context: NSWritingToolsCoordinator.Context,
        completion: @escaping @Sendable ([NSBezierPath]) -> Void
    ) {
        completion([])
    }

    // MARK: - Preview / effect container (required stubs)

    public func writingToolsCoordinator(
        _ coordinator: NSWritingToolsCoordinator,
        requestsPreviewFor textAnimation: NSWritingToolsCoordinator.TextAnimation,
        of range: NSRange,
        in context: NSWritingToolsCoordinator.Context,
        completion: @escaping @Sendable ([NSTextPreview]?) -> Void
    ) {
        // Tessera relies on the coordinator's default effect container.
        // Provide nil to use the default.
        completion(nil)
    }

    /// Preview for a visible rect area (not a text range). Required by the protocol.
    public func writingToolsCoordinator(
        _ coordinator: NSWritingToolsCoordinator,
        requestsPreviewFor rect: NSRect,
        in context: NSWritingToolsCoordinator.Context,
        completion: @escaping @Sendable (NSTextPreview?) -> Void
    ) {
        completion(nil)
    }

    // MARK: - Helpers

    /// Find the paragraph bounds containing `location` in plain text.
    private nonisolated func findParagraph(containing location: Int, in text: String) -> NSRange {
        let nsText = text as NSString
        var start = location
        var end = location

        // Walk backwards to paragraph start
        while start > 0 && nsText.character(at: start - 1) != 0x0A {  // not '\n'
            start -= 1
        }
        // Walk forward to paragraph end
        while end < nsText.length && nsText.character(at: end) != 0x0A {
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }
}

// MARK: - TesseraWritingToolsRewriteDelegate

/// Called when Writing Tools applies a text replacement.
@available(macOS 15.2, *)
@MainActor
public protocol TesseraWritingToolsRewriteDelegate: AnyObject {
    func tesseraWritingToolsCoordinator(
        _ coordinator: TesseraWritingToolsCoordinator,
        applyReplacement text: NSAttributedString,
        at documentRange: NSRange,
        originalContextRange: NSRange
    )
}
#endif // canImport(AppKit)
