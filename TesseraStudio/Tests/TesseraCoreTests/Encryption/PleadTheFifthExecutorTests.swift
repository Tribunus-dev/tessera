import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Encryption/PleadTheFifthExecutor.swift
// doc comments -- the 9-step wipe sequence, the crypto-shred property at
// step 3 ("destroy_volume_password"), step 5's EXPECTED partialFailure
// after the key is destroyed, and `WipeReport.succeeded`'s explicit
// caveat ("look at step 3 instead of this flag").
//
// SAFETY NOTE (why this file never calls `executor.destroyAll(...)`):
// step 3 ("destroy_volume_password") and step 4 ("destroy_dak") call
// `PleadTheFifthKeychain.deleteEntry(account:)` against the FIXED,
// non-injectable production account names
// (`PleadTheFifthKeychain.volumePasswordAccount` = "volume-password",
// `.dataAccessKeyAccount` = "data-access-key") under the app's real
// Keychain service namespace. The executor's test-only initializer
// injects the volume/sidecar/random-fill/overwrite-pass seams, but there
// is no seam for the Keychain account -- `destroyAll(...)` always
// crypto-shreds the SAME Keychain entry the real, installed app would
// use. On any machine where "Plead the Fifth" has genuinely been set up
// (a real encrypted volume with a real stored password), running
// `destroyAll(...)` in a test would irreversibly destroy that user's
// access to their real encrypted data. There is no way to detect that
// state safely before running, so this file constructs `WipeReport` /
// `WipeStep` values directly (both have an accessible memberwise init;
// see below) and never invokes the actual wipe sequence. This is a
// deliberate, safety-motivated coverage gap -- see the findings file.
final class PleadTheFifthExecutorTests: DoctrineTestCase {

    private func step(_ name: String, _ outcome: PleadTheFifthExecutor.WipeOutcome, reason: String? = nil) -> PleadTheFifthExecutor.WipeStep {
        PleadTheFifthExecutor.WipeStep(name: name, outcome: outcome, durationMs: 1, reason: reason)
    }

    private func report(steps: [PleadTheFifthExecutor.WipeStep], trigger: PleadTheFifthExecutor.TriggerSource = .test) -> PleadTheFifthExecutor.WipeReport {
        PleadTheFifthExecutor.WipeReport(
            startedAt: Date(timeIntervalSince1970: 1000),
            completedAt: Date(timeIntervalSince1970: 1001),
            triggerSource: trigger,
            steps: steps
        )
    }

    // MARK: - WipeReport.succeeded (doc comment: "True when every step
    // completed with success")

    func testSucceededIsTrueWhenAllStepsSucceed() {
        let r = report(steps: [step("a", .success), step("b", .success)])
        XCTAssertTrue(r.succeeded)
    }

    func testSucceededIsFalseWhenAnyStepPartiallyFails() {
        let r = report(steps: [step("a", .success), step("b", .partialFailure)])
        XCTAssertFalse(r.succeeded)
    }

    func testSucceededIsFalseWhenAnyStepAborts() {
        let r = report(steps: [step("a", .success), step("b", .aborted)])
        XCTAssertFalse(r.succeeded)
    }

    func testSucceededIsVacuouslyTrueForNoSteps() {
        XCTAssertTrue(report(steps: []).succeeded)
    }

    // MARK: - Step-5-partial-failure-is-expected documentation, pinned as
    // a value-level fact rather than an executor run: a report whose
    // ONLY partial failure is step 5 with the documented reason string
    // still reports succeeded == false (the caller must special-case
    // step 5, exactly as the doc comment instructs -- "look at step 3
    // instead of this flag").

    func testAStep5OnlyPartialFailureStillMakesSucceededFalse() {
        let r = report(steps: [
            step("destroy_volume_password", .success),
            step("unmount_volume", .partialFailure, reason: "expected: key destroyed"),
        ])
        XCTAssertFalse(r.succeeded, "succeeded is whole-report; callers must read step 3 directly per the doc comment")
        let step3 = r.steps.first { $0.name == "destroy_volume_password" }
        XCTAssertEqual(step3?.outcome, .success)
    }

    // MARK: - TriggerSource / WipeOutcome: exhaustive categorical sets
    // (independent oracle, rule 7)

    func testTriggerSourceHasTheFourDocumentedCases() {
        let expected: Set<String> = ["hotkey", "menu", "covert", "test"]
        let actual: Set<String> = [
            PleadTheFifthExecutor.TriggerSource.hotkey.rawValue,
            PleadTheFifthExecutor.TriggerSource.menu.rawValue,
            PleadTheFifthExecutor.TriggerSource.covert.rawValue,
            PleadTheFifthExecutor.TriggerSource.test.rawValue,
        ]
        XCTAssertEqual(actual, expected)
    }

    func testWipeOutcomeHasTheThreeDocumentedCases() {
        let expected: Set<String> = ["success", "partialFailure", "aborted"]
        let actual: Set<String> = [
            PleadTheFifthExecutor.WipeOutcome.success.rawValue,
            PleadTheFifthExecutor.WipeOutcome.partialFailure.rawValue,
            PleadTheFifthExecutor.WipeOutcome.aborted.rawValue,
        ]
        XCTAssertEqual(actual, expected)
    }

    // MARK: - WipeError

    func testAlreadyRunningErrorDescriptionIsHumanReadable() {
        let error: PleadTheFifthExecutor.WipeError = .alreadyRunning
        XCTAssertEqual(error.errorDescription, "A wipe is already running.")
    }

    // MARK: - Round-trip identity (rule 2)

    func testWipeReportEncodeDecodeIdentity() throws {
        let r = report(steps: [
            step("stop_postgres", .success),
            step("unmount_volume", .partialFailure, reason: "expected: key destroyed"),
        ], trigger: .hotkey)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(r)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PleadTheFifthExecutor.WipeReport.self, from: data)
        XCTAssertEqual(decoded, r)
    }

    func testWipeStepEncodeDecodeIdentityWithNilReason() throws {
        let s = step("exit", .success, reason: nil)
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(PleadTheFifthExecutor.WipeStep.self, from: data)
        XCTAssertEqual(decoded, s)
    }
}
