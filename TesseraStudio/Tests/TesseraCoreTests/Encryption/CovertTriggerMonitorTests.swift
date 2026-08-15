import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Encryption/CovertTriggerMonitor.swift
// doc comments (threat model section 9.1/9.3): minPhraseLength (8+),
// observedTextOverhead (phrase.length + 4), case-insensitive substring
// match, cooldownSeconds default 5.
//
// SAFETY NOTE (why this file never calls `setPhrase`/`loadFromKeychain`
// on a real monitor): `CovertTriggerMonitor.setPhrase` persists to the
// SAME Keychain account (`covertTriggerPhrase`, under
// `TesseraSecretStore.service`) the real running app uses -- there is no
// per-instance or injectable account name. On a developer machine that
// has "Plead the Fifth" configured for real, calling `setPhrase` in a
// test would silently overwrite (and a paired `deleteVolumePassword`-
// style cleanup would destroy) the user's actual covert-trigger phrase.
// This file only exercises `testObserve(candidate:text:)` (explicitly
// documented as "no state change") and the read-only/pure surfaces of a
// FRESH (never-`setPhrase`d) `CovertTriggerMonitor()` instance, never
// `.shared`. See the findings file for this explicit scope decision.
final class CovertTriggerMonitorTests: DoctrineTestCase {

    func testMinPhraseLengthConstantIsEight() {
        XCTAssertEqual(CovertTriggerMonitor.minPhraseLength, 8)
    }

    func testObservedTextOverheadConstantIsFour() {
        XCTAssertEqual(CovertTriggerMonitor.observedTextOverhead, 4)
    }

    func testFreshMonitorHasDefaultCooldownOfFiveSeconds() async {
        let monitor = CovertTriggerMonitor()
        let cooldown = await monitor.cooldownSeconds
        XCTAssertEqual(cooldown, 5)
    }

    func testFreshMonitorIsUnarmedAndHasEmptyPhrase() async {
        let monitor = CovertTriggerMonitor()
        let armed = await monitor.isArmed
        let phrase = await monitor.phrase
        XCTAssertFalse(armed)
        XCTAssertEqual(phrase, "")
    }

    func testObserveOnAFreshUnarmedMonitorNeverFires() async {
        // isArmed is false (empty phrase), so observe() must short-circuit
        // before ever touching the Keychain or the cooldown clock.
        let monitor = CovertTriggerMonitor()
        let fired = await monitor.observe(text: "this is a long enough sentence to pass the overhead check")
        XCTAssertFalse(fired)
    }

    // MARK: - testObserve(candidate:text:): pure preview, no state change
    // (doc comment: "Runs the same matching rules as observe(text:)...
    // No state change.")

    func testTestObserveRejectsCandidateShorterThanMinLength() async {
        let monitor = CovertTriggerMonitor()
        let matched = await monitor.testObserve(candidate: "short", text: "short and some more padding text")
        XCTAssertFalse(matched)
    }

    func testTestObserveRejectsWhenObservedTextIsNotLongEnoughPastThePhrase() async {
        let monitor = CovertTriggerMonitor()
        let phrase = "correcthorsebattery" // 19 chars, >= minPhraseLength
        // text.utf16.count must be > phraseLen + 4; here text == phrase
        // exactly, so it must be rejected.
        let matched = await monitor.testObserve(candidate: phrase, text: phrase)
        XCTAssertFalse(matched)
    }

    func testTestObserveMatchesCaseInsensitiveSubstring() async {
        let monitor = CovertTriggerMonitor()
        let phrase = "correcthorsebattery"
        let text = "before CORRECTHORSEBATTERY after padding"
        let matched = await monitor.testObserve(candidate: phrase, text: text)
        XCTAssertTrue(matched)
    }

    func testTestObserveRejectsWhenPhraseIsAbsentFromText() async {
        let monitor = CovertTriggerMonitor()
        let matched = await monitor.testObserve(candidate: "correcthorsebattery", text: "totally unrelated padded text here")
        XCTAssertFalse(matched)
    }

    func testTestObserveDoesNotMutateTheMonitorsArmedState() async {
        let monitor = CovertTriggerMonitor()
        _ = await monitor.testObserve(candidate: "correcthorsebattery", text: "correcthorsebattery plus padding text")
        // "No state change" per the doc comment: the monitor is still
        // unarmed (its real `phrase` was never touched by testObserve).
        let armed = await monitor.isArmed
        let phrase = await monitor.phrase
        XCTAssertFalse(armed)
        XCTAssertEqual(phrase, "")
    }

    // MARK: - setOnFire: pure wiring, safe to exercise on a fresh instance
    // (never actually fires because the monitor is unarmed).

    func testSetOnFireStoresTheHandlerWithoutInvokingIt() async {
        let monitor = CovertTriggerMonitor()
        final class FireFlag: @unchecked Sendable {
            var fired = false
        }
        let flag = FireFlag()
        await monitor.setOnFire { flag.fired = true }
        XCTAssertFalse(flag.fired, "setOnFire must only store the handler, never invoke it")
    }
}
