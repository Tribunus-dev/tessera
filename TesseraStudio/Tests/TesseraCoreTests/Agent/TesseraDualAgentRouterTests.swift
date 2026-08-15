import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Agent/TesseraDualAgentRouter.swift
// doc comments -- "useTessy = sensitive || !complex; useSky = complex"
// (an explicit formula quoted from the ported Linux heuristic), the
// sensitive/complex keyword sets, the 120-char complexity threshold, and
// the `@tessy`/`@sky`/`@both` explicit override parsing.
final class TesseraDualAgentRouterTests: DoctrineTestCase {

    // MARK: - isSensitive / isComplex primitives

    func testSensitiveKeywordDetected() {
        XCTAssertTrue(DualAgentRouter.isSensitive("what's on my calendar today"))
    }

    func testNoSensitiveKeywordIsNotSensitive() {
        XCTAssertFalse(DualAgentRouter.isSensitive("explain how quicksort works"))
    }

    func testSensitiveKeywordDetectionIsCaseInsensitive() {
        XCTAssertTrue(DualAgentRouter.isSensitive("My private notes"))
    }

    func testComplexKeywordDetected() {
        XCTAssertTrue(DualAgentRouter.isComplex("please explain this code"))
    }

    func testShortPlainMessageIsNotComplex() {
        XCTAssertFalse(DualAgentRouter.isComplex("hello"))
    }

    func testMessageOverLengthThresholdIsComplexRegardlessOfKeywords() {
        let longMessage = String(repeating: "a", count: 121)
        XCTAssertFalse(longMessage.contains(" "), "sanity: no keyword substrings present")
        XCTAssertTrue(DualAgentRouter.isComplex(longMessage))
    }

    func testMessageAtExactlyTheLengthThresholdIsNotComplex() {
        // ">" not ">=" per the doc comment ("Length past which"); 120
        // chars exactly is not yet past the threshold.
        let message = String(repeating: "a", count: 120)
        XCTAssertFalse(DualAgentRouter.isComplex(message))
    }

    // MARK: - route(keywordsFor:): useTessy = sensitive || !complex

    func testSensitiveAndSimpleRoutesToTessyOnly() {
        let decision = DualAgentRouter.route(keywordsFor: "remind me about my dentist appointment")
        XCTAssertTrue(decision.useTessy)
        XCTAssertFalse(decision.isTeamUp)
    }

    func testNonSensitiveSimpleRoutesToTessyOnly() {
        let decision = DualAgentRouter.route(keywordsFor: "hello there")
        XCTAssertTrue(decision.useTessy)
        XCTAssertFalse(decision.useSky)
    }

    func testNonSensitiveComplexRoutesToSkyOnly() {
        let decision = DualAgentRouter.route(keywordsFor: "please analyze this algorithm's complexity")
        XCTAssertFalse(decision.useTessy)
        XCTAssertTrue(decision.useSky)
    }

    func testSensitiveAndComplexIsTeamUp() {
        // sensitive ("my") AND complex ("explain") -> useTessy=true (via
        // sensitive), useSky=true (via complex) -> isTeamUp.
        let decision = DualAgentRouter.route(keywordsFor: "explain my private calendar conflicts")
        XCTAssertTrue(decision.useTessy)
        XCTAssertTrue(decision.useSky)
        XCTAssertTrue(decision.isTeamUp)
    }

    // MARK: - route(for:): explicit override prefixes

    func testAtTessyOverrideForcesTessyOnlyAndStripsThePrefix() {
        let (decision, prompt) = DualAgentRouter.route(for: "@tessy analyze this deeply")
        XCTAssertEqual(decision, DualAgentRoutingDecision(useTessy: true, useSky: false))
        XCTAssertEqual(prompt, "analyze this deeply")
    }

    func testAtSkyOverrideForcesSkyOnlyAndStripsThePrefix() {
        let (decision, prompt) = DualAgentRouter.route(for: "@sky what's my private schedule")
        XCTAssertEqual(decision, DualAgentRoutingDecision(useTessy: false, useSky: true))
        XCTAssertEqual(prompt, "what's my private schedule")
    }

    func testAtBothOverrideForcesTeamUpAndStripsThePrefix() {
        let (decision, prompt) = DualAgentRouter.route(for: "@both hello")
        XCTAssertEqual(decision, DualAgentRoutingDecision(useTessy: true, useSky: true))
        XCTAssertTrue(decision.isTeamUp)
        XCTAssertEqual(prompt, "hello")
    }

    func testOverridePrefixIsCaseInsensitive() {
        let (decision, prompt) = DualAgentRouter.route(for: "@TESSY hi")
        XCTAssertEqual(decision, DualAgentRoutingDecision(useTessy: true, useSky: false))
        XCTAssertEqual(prompt, "hi")
    }

    func testNoOverridePrefixFallsBackToKeywordClassifier() {
        let (decision, prompt) = DualAgentRouter.route(for: "hello there")
        XCTAssertEqual(decision, DualAgentRouter.route(keywordsFor: "hello there"))
        XCTAssertEqual(prompt, "hello there")
    }

    func testRouteForTrimsLeadingAndTrailingWhitespaceBeforeClassifying() {
        let (_, prompt) = DualAgentRouter.route(for: "   hello there   ")
        XCTAssertEqual(prompt, "hello there")
    }

    // MARK: - DualAgentRoutingDecision.isTeamUp

    func testIsTeamUpRequiresBothFlagsTrue() {
        XCTAssertTrue(DualAgentRoutingDecision(useTessy: true, useSky: true).isTeamUp)
        XCTAssertFalse(DualAgentRoutingDecision(useTessy: true, useSky: false).isTeamUp)
        XCTAssertFalse(DualAgentRoutingDecision(useTessy: false, useSky: true).isTeamUp)
        XCTAssertFalse(DualAgentRoutingDecision(useTessy: false, useSky: false).isTeamUp)
    }
}
