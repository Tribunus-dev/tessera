import Foundation
@testable import TesseraCore

/// Answers every approval gate an engine raises, so a test driving
/// ``TesseraAgentLoop`` cannot hang.
///
/// The loop's `askUser` branch parks on a continuation that only
/// `resolvePending` resumes. A test with no responder installed does
/// not fail - it suspends forever, with no stack to sample and no
/// XCTest timeout to catch it, and takes the whole suite down with it.
/// That is exactly how `AgentCursorPayloadTests` stalled every run.
///
/// Any test that runs a loop over a tool the safety spine gates
/// (anything `mutating` - "write", "send", "run", ... - is medium risk
/// and asks, whatever the tool's approval level says) must install one
/// of these, or assert on the gate itself.
@MainActor
final class ApprovalAutoResponder {
    /// Tool names of every gate answered, in order.
    private(set) var answered: [String] = []

    private let approve: Bool

    /// Installs itself on `engine`. The closure holds this responder
    /// strongly and the engine weakly, so the responder stays alive for
    /// the engine's lifetime without a cycle - a caller may discard the
    /// return value and the gate still gets answered.
    init(engine: TesseraApprovalEngine, approve: Bool = true) {
        self.approve = approve
        engine.onPendingChange = { [weak engine] request in
            guard let engine, let request else { return }
            self.answered.append(request.toolName)
            engine.resolvePending(approved: self.approve)
        }
    }

    var didAnswer: Bool { !answered.isEmpty }
}
