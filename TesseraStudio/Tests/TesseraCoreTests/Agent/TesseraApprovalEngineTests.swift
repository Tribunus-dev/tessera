import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Agent/TesseraApprovalEngine.swift
// doc comments -- override storage/fallback semantics, `requestApproval`'s
// per-ApprovalLevel dispatch table, `requestApprovalForced` bypassing the
// tool's configured level, and `safetyCheck`'s circuit-breaker fold-in
// ("a tripped breaker rejects outright").
//
// `TesseraApprovalEngine` persists overrides to `UserDefaults.standard`
// under a fixed key (not injectable), so every test that touches
// `setOverride`/`clearOverride` cleans up after itself to keep the suite
// deterministic (rule 4) regardless of run order or other clusters
// sharing the same process.
@MainActor
final class TesseraApprovalEngineTests: DoctrineTestCase {

    private static let storageKey = "tessera.approval.overrides"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
        super.tearDown()
    }

    /// Polls (instead of a single fixed sleep) until `engine.pendingRequest`
    /// is non-nil or `timeoutSeconds` elapses, so the parking tests below
    /// are not flaky on a slow CI machine.
    private func waitForPendingRequest(on engine: TesseraApprovalEngine, timeoutSeconds: Double = 5) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while engine.pendingRequest == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - level(for:default:): override falls back to the supplied default

    func testLevelFallsBackToDefaultWhenNoOverrideSet() {
        let engine = TesseraApprovalEngine()
        XCTAssertEqual(engine.level(for: "some_tool", default: .auto), .auto)
    }

    func testSetOverrideWinsOverTheSuppliedDefault() {
        let engine = TesseraApprovalEngine()
        engine.setOverride(.denied, for: "some_tool")
        XCTAssertEqual(engine.level(for: "some_tool", default: .auto), .denied)
    }

    func testClearOverrideRevertsToTheSuppliedDefault() {
        let engine = TesseraApprovalEngine()
        engine.setOverride(.denied, for: "some_tool")
        engine.clearOverride(for: "some_tool")
        XCTAssertEqual(engine.level(for: "some_tool", default: .auto), .auto)
    }

    func testOverridesPersistAcrossEngineInstancesViaUserDefaults() {
        let first = TesseraApprovalEngine()
        first.setOverride(.notify, for: "persisted_tool")
        let second = TesseraApprovalEngine()
        XCTAssertEqual(second.level(for: "persisted_tool", default: .auto), .notify)
    }

    // MARK: - requestApproval: dispatch table per ApprovalLevel

    func testRequestApprovalAutoLevelResolvesTrueWithoutParking() async {
        let engine = TesseraApprovalEngine()
        engine.setOverride(.auto, for: "auto_tool")
        let approved = await engine.requestApproval(toolName: "auto_tool", arguments: [:])
        XCTAssertTrue(approved)
        XCTAssertNil(engine.pendingRequest)
    }

    func testRequestApprovalNotifyLevelResolvesTrueWithoutParking() async {
        let engine = TesseraApprovalEngine()
        engine.setOverride(.notify, for: "notify_tool")
        let approved = await engine.requestApproval(toolName: "notify_tool", arguments: [:])
        XCTAssertTrue(approved)
        XCTAssertNil(engine.pendingRequest)
    }

    func testRequestApprovalDeniedLevelResolvesFalseWithoutParking() async {
        let engine = TesseraApprovalEngine()
        engine.setOverride(.denied, for: "denied_tool")
        let approved = await engine.requestApproval(toolName: "denied_tool", arguments: [:])
        XCTAssertFalse(approved)
        XCTAssertNil(engine.pendingRequest)
    }

    func testRequestApprovalPromptLevelParksAndResolvesOnResolvePending() async {
        let engine = TesseraApprovalEngine()
        engine.setOverride(.prompt, for: "prompt_tool")
        let task = Task { await engine.requestApproval(toolName: "prompt_tool", arguments: [:]) }
        // Give the parked continuation a moment to publish pendingRequest.
        await waitForPendingRequest(on: engine)
        XCTAssertNotNil(engine.pendingRequest)
        XCTAssertEqual(engine.pendingRequest?.toolName, "prompt_tool")
        engine.resolvePending(approved: true)
        let approved = await task.value
        XCTAssertTrue(approved)
        XCTAssertNil(engine.pendingRequest)
    }

    func testResolvePendingFalsePropagatesDenial() async {
        let engine = TesseraApprovalEngine()
        engine.setOverride(.prompt, for: "prompt_tool")
        let task = Task { await engine.requestApproval(toolName: "prompt_tool", arguments: [:]) }
        await waitForPendingRequest(on: engine)
        engine.resolvePending(approved: false)
        let approved = await task.value
        XCTAssertFalse(approved)
    }

    // MARK: - requestApprovalForced: ignores the tool's configured level

    func testRequestApprovalForcedAlwaysParksEvenWhenLevelIsAuto() async {
        let engine = TesseraApprovalEngine()
        engine.setOverride(.auto, for: "auto_tool")
        let task = Task { await engine.requestApprovalForced(toolName: "auto_tool", arguments: [:]) }
        await waitForPendingRequest(on: engine)
        XCTAssertNotNil(engine.pendingRequest, "forced approval must park even for an auto-level tool")
        engine.resolvePending(approved: true)
        let approved = await task.value
        XCTAssertTrue(approved)
    }

    // MARK: - onPendingChange hook fires on park and on resolve

    func testOnPendingChangeFiresWithTheRequestOnParkAndNilOnResolve() async {
        let engine = TesseraApprovalEngine()
        engine.setOverride(.prompt, for: "prompt_tool")
        var seen: [Bool] = [] // true = non-nil request published, false = nil
        engine.onPendingChange = { request in
            seen.append(request != nil)
        }
        let task = Task { await engine.requestApproval(toolName: "prompt_tool", arguments: [:]) }
        await waitForPendingRequest(on: engine)
        engine.resolvePending(approved: true)
        _ = await task.value
        XCTAssertEqual(seen, [true, false])
    }

    // MARK: - safetyCheck: circuit breaker rejects outright when tripped

    func testSafetyCheckRejectsOutrightWhenCircuitBreakerIsTripped() {
        let engine = TesseraApprovalEngine()
        engine.circuitBreaker.record(denied: true)
        engine.circuitBreaker.record(denied: true)
        engine.circuitBreaker.record(denied: true)
        XCTAssertTrue(engine.circuitBreaker.isTripped)
        let check = engine.safetyCheck(
            for: PendingAction(toolName: "list_models"),
            sandboxEnforceable: false
        )
        XCTAssertEqual(check, .reject)
    }

    func testSafetyCheckUsesToolDefaultLevelAsFallback() {
        let engine = TesseraApprovalEngine()
        // No override set; toolDefaultLevel: .auto + a low-risk read
        // action -> autoApprove (TesseraSafetyDecision fail-safe rule).
        let check = engine.safetyCheck(
            for: PendingAction(toolName: "list_models"),
            sandboxEnforceable: false,
            toolDefaultLevel: .auto
        )
        XCTAssertEqual(check, .autoApprove)
    }

    func testSafetyCheckToolDefaultPromptForcesAskUserEvenAtLowRisk() {
        let engine = TesseraApprovalEngine()
        let check = engine.safetyCheck(
            for: PendingAction(toolName: "list_models"),
            sandboxEnforceable: false,
            toolDefaultLevel: .prompt
        )
        XCTAssertEqual(check, .askUser)
    }

    func testSafetyCheckAnAskUserOutcomeNeverRecordsToTheCircuitBreakerEvenRepeatedly() {
        // Doc comment: "the breaker records an outcome only when the
        // policy is the final authority (autoApprove or reject); for
        // askUser the decision is deferred to the user". A discriminating
        // test: if askUser outcomes were (incorrectly) recorded as
        // denials, 3+ consecutive calls would trip the breaker's
        // consecutive-denial rule. They must not.
        let engine = TesseraApprovalEngine()
        for _ in 0..<5 {
            let check = engine.safetyCheck(
                for: PendingAction(toolName: "list_models"),
                sandboxEnforceable: false,
                toolDefaultLevel: .prompt
            )
            XCTAssertEqual(check, .askUser)
        }
        XCTAssertFalse(engine.circuitBreaker.isTripped)
    }
}
