import Foundation
#if canImport(IOKit.ps)
import IOKit.ps
#endif

/// Fires a recurring idle drafter-training pass on the
/// learning.trainingIntervalHours cadence. Each sweep checks the auto-train
/// setting and the power gate, then hands the run to the orchestrator -
/// whose own gates (trace count, model path, driver binary) decide whether
/// the driver actually runs. This scheduler never bypasses those gates, and
/// a skipped pass is persisted and surfaced like any other outcome, so the
/// dashboard always shows the honest state of the flywheel.
public final class TesseraTrainingScheduler: @unchecked Sendable {
    private let orchestrator: TesseraTrainingOrchestrator
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    /// Terminal hook for each sweep that reaches the orchestrator (including
    /// skips), so the UI layer can refresh or notify. Called on an arbitrary
    /// thread with the terminal record.
    public var onFinished: (@Sendable (TesseraTrainingOrchestrator.TrainingRecord) -> Void)?

    public init(orchestrator: TesseraTrainingOrchestrator) {
        self.orchestrator = orchestrator
    }

    /// Launch the recurring loop. Idempotent: calling it while already
    /// running is a no-op. Each iteration sleeps trainingIntervalHours then
    /// sweeps; the loop runs until stop() cancels it.
    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                let hours = TesseraSettings.learningTrainingIntervalHours
                try? await Task.sleep(nanoseconds: UInt64(hours) * 3_600 * 1_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.sweep()
            }
        }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        task?.cancel()
        task = nil
    }

    /// One idle training pass. Returns the terminal record when the sweep
    /// reached the orchestrator, nil when a scheduler-level gate (auto-train
    /// off, on-power requirement) stopped it before any state was touched.
    @discardableResult
    public func sweep() async -> TesseraTrainingOrchestrator.TrainingRecord? {
        guard TesseraSettings.learningAutoTrain else { return nil }
        if TesseraSettings.learningOnPowerOnly && !isOnPower() {
            print("[tessera.training] idle sweep: skipped, not on power (learning.onPowerOnly=true)")
            return nil
        }
        let record = await orchestrator.run()
        print("[tessera.training] idle sweep: \(record.outcome.rawValue) - \(record.note)")
        onFinished?(record)
        return record
    }

    /// Whether the given training outcome is postable via the
    /// shared ``TesseraNotificationBudget`` in the current
    /// dev-mode state. Review #3 of the agent-ux-fatigue audit
    /// drops `.dryRun` from the postable set (the skill "anti-
    /// pattern: a notification that is not actionable in 15-30
    /// minutes"); the dev-mode flag is the test-friendly escape
    /// hatch. The onFinished hook fires for all outcomes so the
    /// dashboard still receives the honest state; the budget is
    /// the gate that drops .dryRun unless devMode is on.
    public func isOutcomePostable(
        _ outcome: TesseraTrainingOrchestrator.TrainingOutcome
    ) async -> Bool {
        let devModeOn = await TesseraNotificationBudget.shared.isDevMode()
        if TesseraNotificationBudget.devModeOnlyOutcomes.contains(outcome.rawValue) {
            return devModeOn
        }
        return true
    }

    // MARK: - Power gate

    /// Same power gate as TesseraAdaptationScheduler (design 4.5): AC or UPS
    /// counts as powered, battery does not. Degrades OPEN where the power
    /// source cannot be queried, so training is never blocked forever by a
    /// missing answer.
    func isOnPower() -> Bool {
        #if os(macOS) && canImport(IOKit.ps)
        guard let infoRef = IOPSCopyPowerSourcesInfo() else { return true }
        let info = infoRef.takeRetainedValue()
        guard let typeRef = IOPSGetProvidingPowerSourceType(info) else { return true }
        let type = typeRef.takeRetainedValue() as String
        // kIOPSBatteryPowerKey ("Battery Power") is not exported to Swift; the
        // literal is its documented value. Anything else (AC / UPS) is powered.
        return type != "Battery Power"
        #else
        return true
        #endif
    }
}
