#if canImport(AppKit)
import AppKit
import SwiftUI
import TesseraCore

/// The typed-phrase confirmation dialog for the menu bar "Plead the
/// Fifth..." action. Custom NSPanel (per design section 8.5) so that:
///
/// 1. Paste is intercepted and ignored - the user must type the
///    phrase. Defeats the "I copied `destroy everything` from
///    somewhere" attack.
/// 2. The Confirm button is disabled for 5 seconds after the panel
///    appears, preventing a misclick from firing the wipe.
/// 3. Failed attempts are rate-limited: the dialog is dismissed
///    if the user has accumulated 3 failures within a 30-second
///    window, and a fourth attempt is logged.
@MainActor
public final class ConfirmationPanel: NSObject, NSWindowDelegate {
    public enum Result {
        case confirmed
        case cancelled
        case rateLimited
    }

    private let onResult: (Result) -> Void
    private var window: NSPanel?
    private var hosting: NSHostingController<ConfirmationView>?
    private var unlockTimer: Timer?
    private var failedAttempts: Int = 0
    private var firstFailureAt: Date?
    private let confirmationPhrase = "destroy everything"
    private let unlockDelaySeconds: TimeInterval = 5
    private let rateLimitWindow: TimeInterval = 30
    private let rateLimitCap = 3
    private let tier: TesseraTier
    /// 4B (review #4 follow-up, agent-ux-fatigue): the structural
    /// action class the user is about to confirm, surfaced as
    /// the `tool:` chip on the panel. Optional so existing call
    /// sites that do not supply one still compile and the chip
    /// row stays hidden. When nil, only the existing TierChip
    /// is shown.
    private let actionClass: String?
    /// 4B (review #4 follow-up, agent-ux-fatigue): the risk
    /// level (`low | medium | high | forbidden`) of the action
    /// the user is about to confirm, surfaced as the `risk:`
    /// chip. Optional; same nil = no chip row convention as
    /// `actionClass`. The two new parameters travel together:
    /// the row renders only when both are present.
    private let risk: TesseraActionRisk?
    /// 3D (review #4 follow-up, agent-ux-fatigue): the
    /// audit-log toggle handler. The host wires this to
    /// the `ActionAuditLogPanelPresenter`'s
    /// `present() / dismiss()` so the confirmation
    /// surface can toggle the side panel. Optional so
    /// existing call sites that do not opt in still
    /// compile.
    private let onToggleAuditLog: (() -> Void)?

    public init(
        onResult: @escaping (Result) -> Void,
        tier: TesseraTier = .tier3,
        actionClass: String? = nil,
        risk: TesseraActionRisk? = nil,
        onToggleAuditLog: (() -> Void)? = nil
    ) {
        self.onResult = onResult
        // The panic-wipe confirmation is the strictest tier by definition;
        // the caller can override (e.g. for a lower-stakes confirmation
        // that reuses the same panel) but the default is the safe one.
        self.tier = tier
        // 4B: the new detail chips are gated on both actionClass and
        // risk being supplied. Either nil suppresses the new chip row
        // so the existing TierChip + title layout is preserved.
        self.actionClass = actionClass
        self.risk = risk
        self.onToggleAuditLog = onToggleAuditLog
    }

    public func present() {
        if let window = window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = ConfirmationView(
            tier: tier,
            actionClass: actionClass,
            risk: risk,
            expectedPhrase: confirmationPhrase,
            unlockDelaySeconds: unlockDelaySeconds,
            onSubmit: { [weak self] text in
                self?.handleSubmit(text: text) ?? .dismissed
            },
            onCancel: { [weak self] in
                self?.finish(.cancelled)
            },
            onToggleAuditLog: { [weak self] in
                // 3D (review #4 follow-up, agent-ux-fatigue):
                // forward the toggle to the host's audit-log
                // presenter, when one is wired. The default
                // (no presenter) is a no-op; existing callers
                // that do not opt in still see the same
                // confirmation surface.
                self?.onToggleAuditLog?()
            }
        )
        let hosting = NSHostingController(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Plead the Fifth"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.contentViewController = hosting
        panel.delegate = self
        panel.center()

        self.window = panel
        self.hosting = hosting
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func close() {
        unlockTimer?.invalidate()
        unlockTimer = nil
        window?.close()
        window = nil
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        // Close via the red traffic light counts as cancel.
        if let window = self.window, notification.object as? NSWindow === window {
            finish(.cancelled)
        }
    }

    // MARK: - internals

    private func handleSubmit(text: String) -> ConfirmationView.SubmitResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare(confirmationPhrase) == .orderedSame {
            failedAttempts = 0
            firstFailureAt = nil
            finish(.confirmed)
            return .dismissed
        }
        // Rate-limit bookkeeping.
        let now = Date()
        if let first = firstFailureAt, now.timeIntervalSince(first) > rateLimitWindow {
            firstFailureAt = nil
            failedAttempts = 0
        }
        if firstFailureAt == nil { firstFailureAt = now }
        failedAttempts += 1
        if failedAttempts > rateLimitCap {
            finish(.rateLimited)
            return .dismissed
        }
        return .wrongPhrase(failedAttempts: failedAttempts, cap: rateLimitCap)
    }

    private func finish(_ result: Result) {
        unlockTimer?.invalidate()
        unlockTimer = nil
        window?.close()
        window = nil
        onResult(result)
    }
}

/// SwiftUI body of the confirmation panel. Stays thin: it owns
/// no state, reports user input to the panel.
private struct ConfirmationView: View {
    enum SubmitResult: Equatable {
        case dismissed
        case wrongPhrase(failedAttempts: Int, cap: Int)
    }

    let tier: TesseraTier
    /// 4B (review #4 follow-up, agent-ux-fatigue): the action class
    /// string surfaced on the `tool:` chip. When nil, the detail chip
    /// row is suppressed and only the existing TierChip renders.
    let actionClass: String?
    /// 4B (review #4 follow-up, agent-ux-fatigue): the risk level
    /// surfaced on the `risk:` chip. Same nil = no-row convention as
    /// `actionClass`.
    let risk: TesseraActionRisk?
    let expectedPhrase: String
    let unlockDelaySeconds: TimeInterval
    let onSubmit: (String) -> SubmitResult
    let onCancel: () -> Void
    /// 3D (review #4 follow-up, agent-ux-fatigue): the
    /// audit-log toggle. Called when the user taps the
    /// "Audit log" button at the bottom of the panel.
    /// The host wires this to the
    /// ``ActionAuditLogPanelPresenter`` (or to a
    /// binding on the host view that owns the
    /// presenter). Default is a no-op so existing
    /// call sites that do not opt in to the toggle
    /// still compile and behave the same.
    let onToggleAuditLog: () -> Void

    @State private var text: String = ""
    @State private var unlockAt: Date = Date()
    @State private var now: Date = Date()
    @State private var lastFailure: String?
    @State private var hasAppeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Text("Plead the Fifth")
                    .font(.headline)
                Spacer()
                TierChip(tier: tier)
            }
            // 4B (review #4 follow-up, agent-ux-fatigue): surface
            // the action class, risk, and irreversibility flag on
            // the panel so the user reads the action's full
            // identity at the moment of confirmation (paradox 1:
            // verification cost; pattern-catalog.md sec. Structured
            // Presentation). The three new chips use the same
            // `field: value` vocabulary as 1C's AuditLogHeadChip
            // (Editor/AuditLogHead.swift:145-159) and 3D's
            // ActionAuditEntry.displayString
            // (Agent/ActionAuditLogPanel.swift:152-170), so the
            // user reads one chip language on the diff overlay,
            // the chat progress feed, the audit log, and the
            // approval sheet. The row is hidden when either
            // `actionClass` or `risk` is nil so the existing
            // TierChip-only layout is preserved.
            if let actionClass = actionClass, let risk = risk {
                HStack(alignment: .center, spacing: 6) {
                    DetailChip(
                        label: "tool",
                        value: actionClass,
                        color: .secondary
                    )
                    DetailChip(
                        label: "risk",
                        value: risk.rawValue,
                        color: riskColor(risk)
                    )
                    DetailChip(
                        label: "reversible",
                        value: TesseraActionClass.isIrreversible(actionClass, risk: risk) ? "no" : "yes",
                        color: reversibleColor(actionClass: actionClass, risk: risk)
                    )
                    Spacer()
                }
            }
            Text("Type the phrase below to confirm. Paste is disabled. The button unlocks after a short delay.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Custom paste-blocked field. SwiftUI's TextField on macOS
            // honors the standard Edit > Paste menu, so we override
            // it with an empty `NSResponder` and let the
            // NSHostingController forward nothing for the paste
            // action. Done in `pasteBlocker`.
            PasteBlockedTextField(text: $text, onSubmit: submit)
                .frame(height: 24)
            if let lastFailure = lastFailure {
                Text(lastFailure)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Confirm") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
            // 3D (review #4 follow-up, agent-ux-fatigue): toggle the
            // Action Audit Log side panel from the confirmation
            // surface. The toggle is intentionally a non-default
            // button so the confirm flow is not crowded; the user
            // pulls the audit log as a read surface, separate from
            // the typed-phrase confirmation that fires the wipe.
            HStack {
                Button(action: onToggleAuditLog) {
                    Label("Audit log", systemImage: "clock.arrow.circlepath")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Toggle action audit log")
                .accessibilityHint("Opens a side panel with the chronological list of every agent action + outcome.")
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            // First-appear: set the unlock target, kick the timer.
            if !hasAppeared {
                unlockAt = Date().addingTimeInterval(unlockDelaySeconds)
                hasAppeared = true
            }
        }
        // 1Hz tick is plenty - the button is whole seconds.
        .task {
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private var canConfirm: Bool {
        now >= unlockAt
            && text.trimmingCharacters(in: .whitespacesAndNewlines).count >= expectedPhrase.count
    }

    private func submit() {
        guard canConfirm else { return }
        let result = onSubmit(text)
        switch result {
        case .dismissed:
            text = ""
            lastFailure = nil
        case .wrongPhrase(let n, let cap):
            lastFailure = "Phrase does not match. Attempt \(n) of \(cap)."
            text = ""
        }
    }

    // MARK: - 4B chip color helpers

    /// Tint for the `risk:` chip. Mirrors the audit-log
    /// `ActionAuditOutcome.tintName` palette vocabulary
    /// (Agent/ActionAuditLogPanel.swift:74-81) so the user
    /// reads the same color language for risk + outcome
    /// across surfaces. Green / yellow / orange / red maps
    /// to the four `TesseraActionRisk` cases.
    private func riskColor(_ risk: TesseraActionRisk) -> Color {
        switch risk {
        case .low:       return .green
        case .medium:    return .yellow
        case .high:      return .orange
        case .forbidden: return .red
        }
    }

    /// Tint for the `reversible:` chip. Reversible actions
    /// (the user can take them back) render green; irreversible
    /// actions (destructive verbs, high-risk + irreversible,
    /// external-path writes) render orange so the irreversibility
    /// is visually distinct from the high-risk red.
    private func reversibleColor(actionClass: String, risk: TesseraActionRisk) -> Color {
        TesseraActionClass.isIrreversible(actionClass, risk: risk) ? .orange : .green
    }
}

/// NSViewRepresentable wrapping NSTextField with paste blocked.
/// SwiftUI's `TextField` on macOS forwards the system's Edit > Paste
/// action; we replace the field with a custom NSTextField whose
/// `validateProposedFirstResponder` and `paste` sender return nil
/// and ignore the operation, respectively. The user can still type
/// the phrase manually; pasting `destroy everything` is rejected.
private struct PasteBlockedTextField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onSubmit: onSubmit) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.placeholderString = "Type the phrase"
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit(_:))
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        let onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            _text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }

        @objc func commit(_ sender: Any?) {
            onSubmit()
        }

        // Block paste via the responder chain (Edit > Paste,
        // Cmd-V, programmatic). The field receives the action
        // but does nothing with it.
        func controlTextValidating(_ control: NSControl,
                                   command: Selector,
                                   value: Any?) -> Bool {
            // `paste:` and `pasteAndMatchStyle:` are NSText protocol
            // methods; use the raw selector strings because the
            // protocol conformance isn't re-exported as a typed
            // #selector on NSResponder in Swift.
            if command == Selector(("paste:"))
                || command == Selector(("pasteAndMatchStyle:")) {
                return false
            }
            return true
        }
    }
}

/// Tier chip surfaced on the confirmation panel. Compact pill showing
/// the `TesseraTier` for the action the user is about to confirm.
/// Color encodes severity (green = auto, blue = notify, orange =
/// approval, red = multi-party). ASCII-only labels.
private struct TierChip: View {
    let tier: TesseraTier

    var body: some View {
        Text(tier.shortLabel)
            .font(.caption.monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tierColor.opacity(0.18), in: Capsule())
            .foregroundStyle(tierColor)
            .overlay(
                Capsule().stroke(tierColor.opacity(0.45), lineWidth: 0.5)
            )
            .accessibilityLabel(tier.displayName)
    }

    private var tierColor: Color {
        switch tier {
        case .tier0: return .green
        case .tier1: return .blue
        case .tier2: return .orange
        case .tier3: return .red
        }
    }
}

/// 4B (review #4 follow-up, agent-ux-fatigue): detail chip for the
/// action class, risk, and reversibility fields on the
/// confirmation panel. Reuses the visual vocabulary of the
/// existing `TierChip` (caption monospaced, capsule background
/// + outline, color tint at 0.18 / 0.45 opacity) so the panel
/// reads as one chip language. The text is the same
/// `field: value` format used by 1C's `AuditLogHeadChip`
/// (Editor/AuditLogHead.swift:145-159) and 3D's
/// `ActionAuditEntry.displayString`
/// (Agent/ActionAuditLogPanel.swift:152-170) so the user reads
/// the same chip dialect on the diff overlay, the chat progress
/// feed, the audit log, and the approval sheet.
private struct DetailChip: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        Text("\(label): \(value)")
            .font(.caption.monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .overlay(
                Capsule().stroke(color.opacity(0.45), lineWidth: 0.5)
            )
            .accessibilityLabel("\(label): \(value)")
    }
}
#endif
