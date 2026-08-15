import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Learning/TesseraEgressGuard.swift
// doc comment (runtime-traces spec sections 8, 9, 12.5) -- "Fail-closed:
// anything that is not plainly allowed is dropped." Calibration records
// (no `provenance` field) pass; replay records pass ONLY with the exact
// stamp `"provenance":"replay"` + `"replayed_from":"runtime"`; `runtime`
// and `s2s` provenances are local-only and always drop.
final class TesseraEgressGuardTests: DoctrineTestCase {

    func testEmptyLineIsNotAllowed() {
        XCTAssertFalse(TesseraEgressGuard.allows(""))
        XCTAssertFalse(TesseraEgressGuard.allows("   "))
    }

    func testCalibrationLineWithNoProvenanceFieldIsAllowed() {
        let line = #"{"loss":0.42,"step":10}"#
        XCTAssertTrue(TesseraEgressGuard.allows(line))
    }

    func testReplayLineWithTheExactPromotionStampIsAllowed() {
        let line = #"{"provenance":"replay","replayed_from":"runtime","sid":"x"}"#
        XCTAssertTrue(TesseraEgressGuard.allows(line))
    }

    func testRuntimeProvenanceIsAlwaysBlockedEvenIfPresentedAsReplay() {
        let line = #"{"provenance":"runtime"}"#
        XCTAssertFalse(TesseraEgressGuard.allows(line))
    }

    func testS2SProvenanceIsAlwaysBlocked() {
        let line = #"{"provenance":"s2s"}"#
        XCTAssertFalse(TesseraEgressGuard.allows(line))
    }

    func testReplayWithoutTheReplayedFromRuntimeStampIsBlocked() {
        let line = #"{"provenance":"replay"}"#
        XCTAssertFalse(TesseraEgressGuard.allows(line), "the stamp must be exact: provenance=replay AND replayed_from=runtime")
    }

    func testReplayWithWrongReplayedFromValueIsBlocked() {
        let line = #"{"provenance":"replay","replayed_from":"somewhere-else"}"#
        XCTAssertFalse(TesseraEgressGuard.allows(line))
    }

    func testUnknownProvenanceValueIsBlocked() {
        let line = #"{"provenance":"mystery"}"#
        XCTAssertFalse(TesseraEgressGuard.allows(line))
    }

    func testUnparseableJSONWithAProvenanceSubstringIsBlocked() {
        // Fail-closed: the string mentions "provenance" but is not valid
        // JSON, so it must drop rather than pass through un-parsed.
        let line = #"not valid json but mentions "provenance" anyway"#
        XCTAssertFalse(TesseraEgressGuard.allows(line))
    }

    func testWhitespaceAroundTheLineIsTrimmedBeforeChecking() {
        let line = "  \n{\"loss\":0.1}\n  "
        XCTAssertTrue(TesseraEgressGuard.allows(line))
    }

    func testProvenanceFieldAsNonStringValueIsBlocked() {
        let line = #"{"provenance":123}"#
        XCTAssertFalse(TesseraEgressGuard.allows(line))
    }
}
