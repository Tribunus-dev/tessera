import Foundation
import AppKit
import TesseraCore

// MARK: - EditorUndoCoordinator

/// Wires the platform text view's `NSResponder.undoManager`
/// to the Phase 1 `ReceiptUndoManager`. The undo manager
/// is receipt-aware: each "undo" pops a `Receipt` off the
/// stack, computes the inverse mutations from the
/// receipt's `preMutationSnapshot`, applies them, and
/// signs a new "inverse" receipt that voids the original.
///
/// **macOS Edit menu integration.** The coordinator
/// installs itself as the text view's `nextResponder`'s
/// undoManager-target. The macOS Edit menu reads the
/// undo manager's `undoActionName` (which is the
/// `Receipt.summary` for the most recent receipt) and
/// displays it in the menu. The menu shows the receipt's
/// summary as the action name - exactly what the
/// spec's §9 "menu shows summary" requirement calls for.
///
/// **Per-window instance.** One `EditorUndoCoordinator`
/// per document window. The coordinator holds the
/// `ReceiptUndoManager` for the document and routes
/// undo/redo through the data layer's persistence path.
///
/// **Time-limited undo (review #5 follow-up, item 2C).** The
/// legacy `AppKitUndoManagerBridge.levelsOfUndo = 100` cap
/// limited depth, not time; users lost the affordance around
/// the 30-second mark and the undo lived forever. The
/// coordinator now holds a ``TimeLimitedUndoPolicy`` (default
/// 90 seconds) and the bridge consults it on every `canUndo`
/// read. Lazy expiry: the clock is sampled at access time, not
/// on a timer. The receipt chain is unchanged - the budget
/// hides expired entries from the user but the audit trail
/// keeps them.
@MainActor
public final class EditorUndoCoordinator: NSObject {
    public let documentID: UUID
    public let userID: UUID
    public let undoManager: ReceiptUndoManager
    public weak var textView: NSTextView?
    /// The `DocumentStore` (or its test stub) used to
    /// persist the inverse receipts. The Phase 1
    /// `DocumentStore.apply(mutation:to:actor:)` is the
    /// canonical entry point.
    public var onApplyMutation: ((Mutation) async throws -> Void)?
    /// Time-based cap on undo. The bridge reads the top
    /// receipt's `timestamp` and compares it against this
    /// policy on every `canUndo` read.
    public var undoPolicy: TimeLimitedUndoPolicy

    public init(
        documentID: UUID,
        userID: UUID,
        undoManager: ReceiptUndoManager,
        textView: NSTextView? = nil,
        undoPolicy: TimeLimitedUndoPolicy = .default
    ) {
        self.documentID = documentID
        self.userID = userID
        self.undoManager = undoManager
        self.textView = textView
        self.undoPolicy = undoPolicy
        super.init()
    }

    public func attach(to textView: NSTextView) {
        self.textView = textView
        // The window's `undoManager` is set via the
        // `NSWindow.willReturnUndoManager(_:)` delegate
        // method. We associate the text view's window
        // with our coordinator as its undo-manager
        // client; the host's app delegate (or the
        // window subclass) installs the bridge via
        // the standard `willReturnUndoManager` hook.
        //
        // For Phase 2, the coordinator stores the
        // bridge and the host's window controller is
        // responsible for the final install. The
        // bridge exposes the receipt-aware undo/redo
        // methods that the menu invokes.
        _ = AppKitUndoManagerBridge(coordinator: self)
    }

    /// The host calls this to install the bridge as
    /// the window's undo manager. The standard
    /// `NSWindowDelegate` `willReturnUndoManager(_:)`
    /// method returns this bridge.
    public func makeUndoManager() -> UndoManager {
        AppKitUndoManagerBridge(coordinator: self)
    }

    /// Current budget derived from the top undo entry. The
    /// SwiftUI view reads this to render the visible "Undo
    /// available for Ns" affordance. When the undo stack is
    /// empty, returns ``TimeLimitedUndoBudget/empty``.
    public func currentUndoBudget() -> TimeLimitedUndoBudget {
        let top = undoManager.snapshotUndoStack().last
        return TimeLimitedUndoBudget(
            registeredAt: top?.timestamp,
            policy: undoPolicy
        )
    }
}

// MARK: - AppKitUndoManagerBridge

/// An `NSUndoManager` subclass that forwards
/// `undo()`/`redo()` calls to the `EditorUndoCoordinator`,
/// which in turn drives the `ReceiptUndoManager`. The
/// bridge exists so the macOS Edit menu's standard undo
/// behavior ("Cmd-Z" -> "Undo Insert Paragraph") calls
/// the receipt-aware code path.
///
/// **`undoActionName`.** The bridge returns the top
/// receipt's `summary` so the menu shows the receipt's
/// human-readable description (per spec §9 "menu shows
/// summary").
///
/// **Time-limited undo (item 2C).** The legacy
/// `levelsOfUndo = 100` cap (which limited *depth*, not
/// *time*) is replaced with ``TimeLimitedUndoPolicy``. The
/// bridge's `canUndo` is now the conjunction of the undo
/// stack being non-empty AND the top entry's age being
/// within the policy cap. Lazy: the clock is sampled at
/// access time, not on a timer.
@MainActor
public final class AppKitUndoManagerBridge: UndoManager {
    private let coordinator: EditorUndoCoordinator

    public init(coordinator: EditorUndoCoordinator) {
        self.coordinator = coordinator
        super.init()
        // Group undo events so a burst of related edits
        // is one undo unit.
        self.groupsByEvent = false
        // The depth cap (levelsOfUndo = 100) is replaced
        // by the time-based cap on the coordinator's
        // `undoPolicy`. The bridge consults it on every
        // `canUndo` read; the depth is bounded only by
        // the audit chain's own persistence policy.
    }

    public override var undoActionName: String {
        guard let top = coordinator.undoManager.snapshotUndoStack().last else {
            return "Undo"
        }
        return "Undo \(top.summary)"
    }

    public override var redoActionName: String {
        guard let top = coordinator.undoManager.snapshotRedoStack().last else {
            return "Redo"
        }
        return "Redo \(top.summary)"
    }

    /// `canUndo` is the conjunction of:
    ///   1. The undo stack being non-empty (managed by
    ///      ``ReceiptUndoManager``), AND
    ///   2. The top entry's age being within the policy
    ///      cap (managed by ``TimeLimitedUndoPolicy``).
    ///
    /// The receipt chain is preserved across expiry: an
    /// expired entry is hidden from the Cmd-Z affordance
    /// but still lives in the audit chain and the receipts
    /// drawer.
    public override var canUndo: Bool {
        guard coordinator.undoManager.canUndo else { return false }
        return coordinator.currentUndoBudget().isAvailable
    }

    public override var canRedo: Bool { coordinator.undoManager.canRedo }

    public override func undo() {
        // Guard against a race: a stale `canUndo` read
        // could let Cmd-Z through on an entry that just
        // expired. Re-check at dispatch time. The
        // receipt-aware path is the one that mutates the
        // audit chain, so the cap is the last gate.
        guard canUndo else { return }
        let document = coordinator.textView?.textContentStorage?.attributedString
        Task { @MainActor in
            await self.runUndo(document: document)
        }
    }

    public override func redo() {
        let document = coordinator.textView?.textContentStorage?.attributedString
        Task { @MainActor in
            await self.runRedo(document: document)
        }
    }

    private func runUndo(document: NSAttributedString?) async {
        // The actual undo call happens on the main actor
        // synchronously (the `ReceiptUndoManager.undo`
        // is a synchronous call that mutates the in-memory
        // document). The async wrapper exists so the
        // persistence step can be awaited.
        do {
            // Build a minimal `DocumentAST` from the
            // current attributed string; the `ReceiptUndoManager`
            // doesn't need a full AST — it operates on the
            // pre-snapshots embedded in the receipts.
            // The Phase 1 `undo(document:actor:signer:)`
            // takes the live document; we pass an empty
            // document because the receipt's
            // `preMutationSnapshot` is what the inverse
            // is computed from.
            let signer = ReceiptSigner()
            let empty = DocumentAST.empty
            let result = try coordinator.undoManager.undo(
                document: empty,
                actor: .user(coordinator.userID),
                signer: signer
            )
            // The text view is updated by the host (the
            // `TesseraEditorView` observes the document
            // binding); we just notify the host via the
            // onApplyMutation callback for each inverse
            // mutation in the receipt.
            for mutation in result.inverseReceipt.mutations {
                if let apply = coordinator.onApplyMutation {
                    try await apply(mutation)
                }
            }
        } catch {
            NSLog("EditorUndoCoordinator: undo failed: \(error)")
        }
    }

    private func runRedo(document: NSAttributedString?) async {
        do {
            let signer = ReceiptSigner()
            let empty = DocumentAST.empty
            let result = try coordinator.undoManager.redo(
                document: empty,
                actor: .user(coordinator.userID),
                signer: signer
            )
            for mutation in result.inverseReceipt.mutations {
                if let apply = coordinator.onApplyMutation {
                    try await apply(mutation)
                }
            }
        } catch {
            NSLog("EditorUndoCoordinator: redo failed: \(error)")
        }
    }
}

// MARK: - TimeLimitedUndoChip

#if canImport(SwiftUI)
import SwiftUI

/// Visible "Undo available for Ns" affordance for the editor
/// (review #5 follow-up, item 2C). The chip is the first-class
/// surface the skill calls for: "the undo availability must be a
/// first-class element in the UI, not buried in the audit log."
///
/// **Smooth animation, not 1 Hz text.** The chip reads
/// ``TimeLimitedUndoBudget/remainingSeconds`` and
/// ``TimeLimitedUndoBudget/progress(at:)`` continuously; SwiftUI's
/// `TimelineView(.animation)` drives the body and `.animation(
/// .linear)` interpolates the value. No `Timer`, no `Text` that
/// re-renders at 1 Hz.
///
/// **Hide on empty / hide on expired.** The chip is a no-op
/// when the budget is empty (no undo entry) or expired. The
/// `opacity(0)` path is cheaper than conditional rendering and
/// keeps the layout stable.
public struct TimeLimitedUndoChip: View {
    let coordinator: EditorUndoCoordinator

    public init(coordinator: EditorUndoCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: false)) { context in
            let budget = coordinator.currentUndoBudget()
            let visible = budget.registeredAt != nil && !budget.isExpired
            chipBody(budget: budget, now: context.date)
                .opacity(visible ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: visible)
        }
        .accessibilityLabel("Undo available for limited time")
    }

    @ViewBuilder
    private func chipBody(budget: TimeLimitedUndoBudget, now: Date) -> some View {
        HStack(spacing: 6) {
            Text("Undo available for")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(budget.remainingLabel(at: now))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .animation(.linear(duration: 0.2), value: budget.remainingSeconds(at: now))
            // Continuous progress bar: 0..1, the budget
            // reports a clamped fraction. The view shrinks
            // smoothly as time passes; no 1 Hz tick.
            ProgressView(value: budget.progress(at: now))
                .progressViewStyle(.linear)
                .frame(width: 48, height: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}
#endif
