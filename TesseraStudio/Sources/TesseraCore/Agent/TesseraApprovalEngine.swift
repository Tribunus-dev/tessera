import Foundation
import Observation

/// Approval levels for tool execution.
public enum ApprovalLevel: String, Codable, CaseIterable, Sendable {
    /// Execute without user interaction.
    case auto
    /// Execute and show a notification after the fact.
    case notify
    /// Require explicit user approval before execution.
    case prompt
    /// Never execute; the tool is disabled.
    case denied
}

/// Manages per-tool approval levels and user overrides.
/// The prompt level triggers an ApprovalSheet in the UI.
@Observable
@MainActor
public final class TesseraApprovalEngine {
    /// User overrides keyed by tool name. Falls back to the tool's default.
    public private(set) var overrides: [String: ApprovalLevel] = [:]

    /// Pending approval request (drives the ApprovalSheet presentation).
    public private(set) var pendingRequest: PendingApproval?

    /// Fired whenever ``pendingRequest`` changes: non-nil when a gate is
    /// waiting on the user, nil once it resolves. The owner bridges this
    /// to the surface that presents the sheet.
    ///
    /// Load-bearing, not decoration: `requestApprovalForced` parks a
    /// continuation that only ``resolvePending`` can resume, so an engine
    /// whose pending request never reaches a surface blocks its agent
    /// loop forever.
    public var onPendingChange: (@MainActor (PendingApproval?) -> Void)?

    /// Callback continuation for the pending request.
    private var continuation: CheckedContinuation<Bool, Never>?

    public struct PendingApproval: Identifiable {
        public let id = UUID()
        public let toolName: String
        public let arguments: [String: JSONValue]
        public let level: ApprovalLevel
    }

    public init() {
        loadOverrides()
    }

    /// The effective approval level for a tool.
    public func level(for toolName: String, default defaultLevel: ApprovalLevel) -> ApprovalLevel {
        overrides[toolName] ?? defaultLevel
    }

    /// Set a user override for a tool.
    public func setOverride(_ level: ApprovalLevel, for toolName: String) {
        overrides[toolName] = level
        saveOverrides()
    }

    /// Remove a user override, reverting to the tool's default.
    public func clearOverride(for toolName: String) {
        overrides.removeValue(forKey: toolName)
        saveOverrides()
    }

    /// Request approval for a tool call. Returns true if approved.
    public func requestApproval(toolName: String, arguments: [String: JSONValue]) async -> Bool {
        let tool = TesseraToolRegistry.default.tool(named: toolName)
        let defaultLevel = tool?.defaultApprovalLevel ?? .prompt
        let level = level(for: toolName, default: defaultLevel)

        switch level {
        case .auto:
            return true
        case .notify:
            // In production: post a local notification
            return true
        case .denied:
            return false
        case .prompt:
            return await park(toolName: toolName, arguments: arguments, level: level)
        }
    }

    /// Prompt the user unconditionally, ignoring the tool's configured level.
    /// Used when the safety spine (15.5) has returned `askUser`: the layered
    /// gate has decided this specific action needs confirmation (e.g. it is
    /// medium-risk or not sandbox-contained), and that verdict must win even
    /// for a tool the user generally sets to auto/notify. Routing this through
    /// `requestApproval` would silently auto-approve and defeat the gate.
    public func requestApprovalForced(toolName: String, arguments: [String: JSONValue]) async -> Bool {
        await park(toolName: toolName, arguments: arguments, level: .prompt)
    }

    /// Called by the ApprovalSheet when the user responds.
    public func resolvePending(approved: Bool) {
        let cont = continuation
        continuation = nil
        pendingRequest = nil
        cont?.resume(returning: approved)
        onPendingChange?(nil)
    }

    /// Suspend the caller until `resolvePending` runs, publishing the
    /// request first. The single path that sets ``pendingRequest``, so
    /// every parked continuation has a matching observer notification.
    ///
    /// A request arriving while one is already parked denies the older
    /// one rather than dropping its continuation: one agent loop awaits
    /// its gate before issuing the next, so this is unreachable today,
    /// but leaking a continuation here would hang the loop with no way
    /// back.
    private func park(
        toolName: String,
        arguments: [String: JSONValue],
        level: ApprovalLevel
    ) async -> Bool {
        if let stale = continuation {
            continuation = nil
            stale.resume(returning: false)
        }
        // Cancellation must resolve the gate. A `CheckedContinuation` is
        // not cancellation-aware, so without this a run stopped while an
        // approval is pending stays suspended forever: `isRunning` sticks
        // true, the stream never finishes, and the caller's for-await
        // never returns. That is exactly what the inline stop button
        // does - cancel the task mid-run.
        //
        // Cancelling denies: a stopped run must not go on to execute the
        // action the user was still being asked about.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                // Already cancelled before we parked - resume at once
                // rather than install a continuation nothing will
                // resume.
                guard !Task.isCancelled else {
                    cont.resume(returning: false)
                    return
                }
                self.continuation = cont
                let request = PendingApproval(
                    toolName: toolName,
                    arguments: arguments,
                    level: level
                )
                self.pendingRequest = request
                self.onPendingChange?(request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolvePending(approved: false)
            }
        }
    }

    // MARK: - Safety spine

    /// Denial circuit-breaker shared across the loop (S3).
    public let circuitBreaker = TesseraDenialCircuitBreaker()

    /// Learned-permission ratchet (autonomy-calibration-design.md). Defaults
    /// to a no-op that passes the base decision through unchanged; the real
    /// service is installed by `TesseraLearningServices.installDefaults`.
    public var autonomy: any TesseraAutonomyStoring = TesseraNoopAutonomyService()

    /// Layered safety gate (S2/S3/S4). Verifies the action, computes the
    /// layered-permission check, and folds in the circuit-breaker: a tripped
    /// breaker rejects outright. The breaker records an outcome only when the
    /// policy is the final authority (autoApprove or reject); for `askUser`
    /// the decision is deferred to the user, so the loop records the user's
    /// verdict instead. This keeps each action to exactly one breaker outcome
    /// and stops a premature "not denied" from masking a later user denial.
    /// - Parameter toolDefaultLevel: the level the TOOL declares. A user
    ///   override still wins; this is only the fallback. Passing the
    ///   declared level is what makes `defaultApprovalLevel` mean
    ///   anything: hardcoding `.prompt` here gated every tool that had
    ///   no explicit override, so a headless run (no UI, no responder)
    ///   parked on the gate forever.
    public func safetyCheck(
        for action: PendingAction,
        permissionProfile: TesseraPermissionProfile = .standard,
        sandboxEnforceable: Bool,
        toolDefaultLevel: ApprovalLevel = .prompt,
        verifier: any ActionVerifying = TesseraActionVerifier()
    ) -> TesseraSafetyCheck {
        if circuitBreaker.isTripped {
            return .reject
        }
        let decision = verifier.verify(action)
        let check = TesseraSafetyDecision(
            approvalPolicy: level(for: action.toolName, default: toolDefaultLevel),
            permissionProfile: permissionProfile,
            sandboxEnforceable: sandboxEnforceable,
            actionRisk: decision.riskLevel
        ).check
        if check != .askUser {
            circuitBreaker.record(denied: check == .reject)
        }
        return check
    }

    /// Autonomy-aware gate check (autonomy-calibration-design.md section 7).
    /// Wraps `safetyCheck` (steps 1-3, 5) and applies the learned-permission
    /// ratchet (steps 4, 6). `sessionID` scopes the YOLO branch (section 10).
    /// Returns the resolved verdict plus provenance.
    public func gateCheck(
        for action: PendingAction,
        permissionProfile: TesseraPermissionProfile = .standard,
        sandboxEnforceable: Bool,
        sessionID: String = "",
        toolDefaultLevel: ApprovalLevel = .prompt,
        verifier: any ActionVerifying = TesseraActionVerifier()
    ) -> TesseraGateResolution {
        let base = safetyCheck(
            for: action,
            permissionProfile: permissionProfile,
            sandboxEnforceable: sandboxEnforceable,
            toolDefaultLevel: toolDefaultLevel,
            verifier: verifier
        )
        let risk = (try? TesseraActionVerifier.ruleBasedRisk(for: action)) ?? .medium
        let actionClass = autonomy.classify(action)
        return autonomy.resolve(
            base: base,
            actionClass: actionClass,
            risk: risk,
            sandboxEnforceable: sandboxEnforceable,
            sessionID: sessionID
        )
    }

    /// Record a gate outcome to the learned-permission ratchet and emit an
    /// approval receipt (section 14). Called by the agent loop after each
    /// gate decision.
    @discardableResult
    public func recordOutcome(
        action: PendingAction,
        risk: TesseraActionRisk,
        sandboxed: Bool,
        decision: TesseraSafetyCheck,
        userChoice: TesseraUserChoice,
        source: String,
        sessionID: String
    ) -> TesseraLearningReceipt {
        autonomy.record(
            action: action,
            risk: risk,
            sandboxed: sandboxed,
            decision: decision,
            userChoice: userChoice,
            source: source,
            sessionID: sessionID
        )
    }

    // MARK: - Persistence

    private static let storageKey = "tessera.approval.overrides"

    private func saveOverrides() {
        let raw = overrides.mapValues(\.rawValue)
        UserDefaults.standard.set(raw, forKey: Self.storageKey)
    }

    private func loadOverrides() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: String] else { return }
        overrides = raw.compactMapValues { ApprovalLevel(rawValue: $0) }
    }
}
