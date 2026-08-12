import XCTest
@testable import TesseraCore

/// Tests for the onboarding first-goal persistence (review #1 of the
/// agent-ux-fatigue Tessera Studio audit). The chat controller seeds the
/// first send with this value and clears it; tests pin the round-trip
/// through UserDefaults so the data model stays small and predictable.
final class FirstGoalPersistenceTests: XCTestCase {

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: TesseraSettingsKey.firstGoal)
        UserDefaults.standard.removeObject(forKey: TesseraSettingsKey.onboardingCompletedAt)
        try await super.tearDown()
    }

    func testDefaultIsEmpty() {
        UserDefaults.standard.removeObject(forKey: TesseraSettingsKey.firstGoal)
        XCTAssertEqual(TesseraSettings.firstGoal, "")
    }

    func testSetThenReadRoundTrips() {
        TesseraSettings.setFirstGoal("Triage my email into 3 buckets.")
        XCTAssertEqual(TesseraSettings.firstGoal, "Triage my email into 3 buckets.")
    }

    func testSetEmptyClearsTheValue() {
        TesseraSettings.setFirstGoal("Some first goal.")
        XCTAssertEqual(TesseraSettings.firstGoal, "Some first goal.")
        TesseraSettings.setFirstGoal("")
        XCTAssertEqual(TesseraSettings.firstGoal, "")
    }

    func testKeyIsNamespacedUnderTesseraSettingsPrefix() {
        // A regression guard: the key should live under the tessera
        // settings namespace, not a stray global. Other settings follow
        // the same convention.
        XCTAssertTrue(
            TesseraSettingsKey.firstGoal.hasPrefix("tessera.settings."),
            "firstGoal key should be namespaced under tessera.settings.*, got \(TesseraSettingsKey.firstGoal)"
        )
    }

    func testRegisteredDefaultIsEmpty() {
        TesseraSettings.registerDefaults()
        let value = UserDefaults.standard.string(forKey: TesseraSettingsKey.firstGoal)
        // After registration, an unset value should resolve to the
        // registered default of "" (empty string). The getter itself
        // also handles nil; the registration is the visible contract.
        XCTAssertTrue(value == nil || value == "")
    }

    func testOnboardingCompletedAtKeyIsNamespaced() {
        XCTAssertTrue(
            TesseraSettingsKey.onboardingCompletedAt.hasPrefix("tessera.settings."),
            "onboardingCompletedAt key should be namespaced under tessera.settings.*, got \(TesseraSettingsKey.onboardingCompletedAt)"
        )
    }

    @MainActor
    func testControllerReadsAndConsumesFirstGoal() async {
        TesseraSettings.setFirstGoal("Help me write a spec for the next release.")
        let controller = UnifiedChatController()
        XCTAssertEqual(controller.firstGoal, "Help me write a spec for the next release.")

        // After the first send, the controller clears the persisted value
        // so the seed applies exactly once. We invoke `recordOnboardingCompletion`
        // first because the controller's emit path checks for the start
        // timestamp; without it the time-to-first-message event still
        // fires but with onboarding_completed_at="" metadata.
        controller.recordOnboardingCompletion(at: Date())
        // Drive a synchronous path: `send` requires isRunning == false.
        // We don't have a real provider wired here, so the graph run will
        // be a no-op async task. The firstGoal is consumed synchronously
        // in runTurn, so the cleared value is observable immediately
        // after the send (the controller's firstGoal becomes nil before
        // the task awaits).
        controller.send("Hello")
        // The persisted value should be cleared by the time send() returns.
        XCTAssertEqual(TesseraSettings.firstGoal, "")
        XCTAssertNil(controller.firstGoal)
    }

    @MainActor
    func testRecordOnboardingCompletionIsIdempotent() {
        TesseraSettings.registerDefaults()
        UserDefaults.standard.removeObject(forKey: TesseraSettingsKey.onboardingCompletedAt)
        let controller = UnifiedChatController()
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let second = Date(timeIntervalSince1970: 1_800_000_000)
        controller.recordOnboardingCompletion(at: first)
        controller.recordOnboardingCompletion(at: second)
        XCTAssertEqual(controller.onboardingCompletedAt, first)
        let stored = UserDefaults.standard.double(forKey: TesseraSettingsKey.onboardingCompletedAt)
        XCTAssertEqual(stored, first.timeIntervalSince1970, accuracy: 1e-6)
    }
}
