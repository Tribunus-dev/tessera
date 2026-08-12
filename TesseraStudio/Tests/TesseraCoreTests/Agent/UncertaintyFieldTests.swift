import XCTest
@testable import TesseraCore

// Tests for the uncertainty / confidence-band field on ToolResultPayload
// (review #5 of the agent-ux-fatigue Tessera Studio audit). The
// load-bearing contract is the Tian Pan 2026-04-12 split: a `ToolResult`
// must be able to tell the UI "the agent was uncertain and said so"
// distinct from "the agent was confident and was wrong". These tests
// pin:
//   1. the band is set or nil with a documented reason
//   2. the verifier's risk -> band mapping covers every risk value
//   3. the mapping is monotone inverse (low risk -> high confidence,
//      high risk -> low confidence)
//   4. the round-trip from ToolResult -> ToolResultPayload preserves
//      the band (the field survives the storage layer)
final class UncertaintyFieldTests: XCTestCase {

    // MARK: - ConfidenceBand enum

    func testConfidenceBandIsCaseIterableWithThreeValues() {
        // Pin the exhaustive set: low / medium / high. Adding a case is a
        // conscious design decision (the UI's caveat chip vocabulary).
        XCTAssertEqual(ConfidenceBand.allCases.count, 3)
        XCTAssertEqual(ConfidenceBand.allCases, [.low, .medium, .high])
    }

    func testConfidenceBandRawValuesAreStable() {
        // The raw value is the on-disk / wire form. Pin it so a rename
        // does not silently migrate stored payloads.
        XCTAssertEqual(ConfidenceBand.low.rawValue, "low")
        XCTAssertEqual(ConfidenceBand.medium.rawValue, "medium")
        XCTAssertEqual(ConfidenceBand.high.rawValue, "high")
    }

    // MARK: - Verifier risk -> band mapping (TesseraActionVerifier.confidenceBand(for:))

    func testVerifierBandForLowRiskIsHighConfidence() {
        // Idempotent reads, get/list/inspect: the agent trusts the result.
        XCTAssertEqual(TesseraActionVerifier.confidenceBand(for: .low), .high)
    }

    func testVerifierBandForMediumRiskIsMediumConfidence() {
        // Mutations: plausible but not certain. The UI caveat chip is
        // optional in this band (paradox 6, XAI: too many caveats
        // trains the user to skip them all).
        XCTAssertEqual(TesseraActionVerifier.confidenceBand(for: .medium), .medium)
    }

    func testVerifierBandForHighRiskIsLowConfidence() {
        // Destructive verbs: the agent is least sure, the UI must surface
        // the caveat. This is the load-bearing test for the Tian Pan
        // split: a "I did it but I am not sure this is right" signal
        // reaches the UI exactly when the action is most consequential.
        XCTAssertEqual(TesseraActionVerifier.confidenceBand(for: .high), .low)
    }

    func testVerifierBandMappingIsTotalAndMonotoneInverse() {
        // Total: every risk (including .forbidden) has a band (no nil
        // from the verifier). The exhaustive set must be typed; adding
        // a new TesseraActionRisk case should require a deliberate
        // mapping decision.
        for risk in TesseraActionRisk.allCases {
            let band = TesseraActionVerifier.confidenceBand(for: risk)
            XCTAssertNotNil(band, "verifier must emit a band for risk=\(risk)")
        }
        // Monotone inverse on the visible range: as risk rises, confidence
        // falls. .forbidden is excluded from the comparison because in
        // practice the action is rejected before the band is observed;
        // the mapping is still monotone (.forbidden -> .low confidence).
        let lowRisk = TesseraActionVerifier.confidenceBand(for: .low).numericLevel
        let medRisk = TesseraActionVerifier.confidenceBand(for: .medium).numericLevel
        let highRisk = TesseraActionVerifier.confidenceBand(for: .high).numericLevel
        XCTAssertGreaterThan(lowRisk, medRisk)
        XCTAssertGreaterThan(medRisk, highRisk)
    }

    func testVerifierBandForForbiddenRiskIsLowConfidence() {
        // .forbidden is "never permitted regardless of policy" (S4). In
        // practice the action is rejected before the band is ever shown,
        // but the mapping must be exhaustive; pin the value so a future
        // refactor that lifts .forbidden into a higher band fails the
        // test.
        XCTAssertEqual(TesseraActionVerifier.confidenceBand(for: .forbidden), .low)
    }

    // MARK: - ToolResultPayload carries the band

    func testPayloadDefaultIsNilForDeterministicTools() {
        // Default construction = nil band. The documented reason: tools
        // with no uncertainty source (deterministic reads, executor
        // returns) emit nil; the UI treats nil as "no caveat available",
        // not as "the agent was silent about uncertainty".
        let payload = ToolResultPayload(success: true, output: "ok")
        XCTAssertNil(payload.confidenceBand)
    }

    func testPayloadCarriesExplicitBand() {
        // The producer (tool or agent loop) sets the band explicitly.
        let payload = ToolResultPayload(success: true, output: "ok", confidenceBand: .low)
        XCTAssertEqual(payload.confidenceBand, .low)
    }

    func testPayloadCarriesBandEvenOnError() {
        // The band is orthogonal to the success flag. A failed tool call
        // can still be "high confidence it failed" (e.g. file not found
        // from a deterministic read) or "low confidence it failed" (a
        // creative generation that missed the schema). The UI must see
        // both signals.
        let certain = ToolResultPayload(success: false, output: "", error: "ENOENT", confidenceBand: .high)
        let uncertain = ToolResultPayload(success: false, output: "", error: "schema mismatch", confidenceBand: .low)
        XCTAssertEqual(certain.confidenceBand, .high)
        XCTAssertEqual(uncertain.confidenceBand, .low)
        XCTAssertEqual(certain.error, "ENOENT")
        XCTAssertEqual(uncertain.error, "schema mismatch")
    }

    // MARK: - ToolResult -> ToolResultPayload round-trip

    func testToolResultPayloadRoundTripPreservesBand() {
        // The .payload computed property is the storage conversion
        // (TesseraTool.swift:161). It must propagate the band; otherwise
        // SwiftData loses the field on write.
        let result = ToolResult(success: true, output: "ok", confidenceBand: .medium)
        let payload = result.payload
        XCTAssertEqual(payload.confidenceBand, .medium)
        XCTAssertEqual(payload.success, true)
        XCTAssertEqual(payload.output, "ok")
        XCTAssertNil(payload.error)
    }

    func testToolResultOkFactoryDefaultsBandToNil() {
        // .ok is the deterministic-read path; nil is documented.
        let result = ToolResult.ok("done")
        XCTAssertNil(result.confidenceBand)
    }

    func testToolResultFailFactoryDefaultsBandToNil() {
        // .fail is the executor's failure path; nil is documented
        // (the failure mode itself is the signal, the agent's
        // confidence in the failure is the caller's job to add).
        let result = ToolResult.fail("boom")
        XCTAssertNil(result.confidenceBand)
        XCTAssertEqual(result.error, "boom")
    }

    // MARK: - Round-trip via the verifier's risk classifier

    func testDestructiveToolGetsLowBand() {
        // The full chain: tool name -> risk -> band. A delete action
        // gets .low confidence, which the UI must render as a caveat.
        let action = PendingAction(toolName: "delete_file", arguments: [:])
        let risk = try? TesseraActionVerifier.ruleBasedRisk(for: action)
        XCTAssertEqual(risk, .high)
        let band = TesseraActionVerifier.confidenceBand(for: .high)
        XCTAssertEqual(band, .low)
    }

    func testReadOnlyToolGetsHighBand() {
        // A list_models call is low risk, so the agent is high
        // confidence in the result. The UI can suppress the caveat.
        let action = PendingAction(toolName: "list_models", arguments: [:])
        let risk = try? TesseraActionVerifier.ruleBasedRisk(for: action)
        XCTAssertEqual(risk, .low)
        let band = TesseraActionVerifier.confidenceBand(for: .low)
        XCTAssertEqual(band, .high)
    }

    func testUnknownToolDefaultsToMediumRiskAndMediumBand() {
        // The rule-based classifier falls back to .medium for unknown
        // tool names (TesseraActionVerifier.swift:89). The band is
        // .medium in that case: the UI shows an optional caveat, the
        // agent is neither over-confident nor under-confident.
        let action = PendingAction(toolName: "obscure_verb", arguments: [:])
        let risk = try? TesseraActionVerifier.ruleBasedRisk(for: action)
        XCTAssertEqual(risk, .medium)
        let band = TesseraActionVerifier.confidenceBand(for: .medium)
        XCTAssertEqual(band, .medium)
    }

    // MARK: - Codable round-trip (the field survives JSON)

    func testPayloadRoundTripsThroughJSONEncoder() {
        // The field must survive Codable round-trip; SwiftData and the
        // chat history both use JSON.
        let original = ToolResultPayload(
            success: true,
            output: "ok",
            error: nil,
            confidenceBand: .low
        )
        let encoder = JSONEncoder()
        let data = try? encoder.encode(original)
        XCTAssertNotNil(data)
        let decoder = JSONDecoder()
        let restored = try? decoder.decode(ToolResultPayload.self, from: data ?? Data())
        XCTAssertEqual(restored?.confidenceBand, .low)
        XCTAssertEqual(restored?.success, original.success)
        XCTAssertEqual(restored?.output, original.output)
    }

    func testPayloadWithNilBandRoundTripsThroughJSONEncoder() {
        // The nil path is the documented "no uncertainty available"
        // case. It must round-trip too; a missing field after
        // decode would be a silent regression.
        let original = ToolResultPayload(success: false, output: "", error: "x", confidenceBand: nil)
        let data = try? JSONEncoder().encode(original)
        XCTAssertNotNil(data)
        let restored = try? JSONDecoder().decode(ToolResultPayload.self, from: data ?? Data())
        XCTAssertNil(restored?.confidenceBand)
        XCTAssertEqual(restored?.error, "x")
    }
}

// MARK: - Helpers

private extension ConfidenceBand {
    /// Ordinal for the monotone-inverse test. Higher number = higher
    /// confidence. The order is fixed: .high (3) > .medium (2) > .low (1).
    var numericLevel: Int {
        switch self {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }
}
