import XCTest
@testable import TesseraCore

final class DualAgentRouterTests: XCTestCase {
    func testSensitiveKeywordsRouteToTessyOnly() {
        let cases = [
            "remember my dentist appointment",
            "show my personal notes",
            "check my email for the Q3 thread",
            "what's on my calendar today",
            "keep this private",
            "edit the contact for Ada"
        ]
        for prompt in cases {
            let d = DualAgentRouter.route(keywordsFor: prompt)
            XCTAssertTrue(d.useTessy, "expected Tessy for sensitive prompt: \(prompt)")
            XCTAssertFalse(d.useSky, "Sky must not fire for sensitive prompt: \(prompt)")
        }
    }

    func testComplexNonSensitiveRoutesToSkyOnly() {
        let cases = [
            "explain quantum computing in detail",
            "analyze the time complexity of merge sort",
            "write a Python function to reverse a linked list",
            String(repeating: "a", count: 130) // length heuristic
        ]
        for prompt in cases {
            let d = DualAgentRouter.route(keywordsFor: prompt)
            XCTAssertTrue(d.useSky, "expected Sky for complex prompt")
            XCTAssertFalse(d.useTessy, "Tessy should not fire for non-sensitive complex prompt")
        }
    }

    func testSimpleNonSensitiveRoutesToTessyOnly() {
        let d = DualAgentRouter.route(keywordsFor: "hello")
        XCTAssertTrue(d.useTessy)
        XCTAssertFalse(d.useSky)
    }

    func testSensitiveAndComplexTeamsUp() {
        // "my" makes it sensitive; "summarize" + length make it complex.
        let prompt = "summarize my Q3 notes and explain the revenue trends with steps"
        let d = DualAgentRouter.route(keywordsFor: prompt)
        XCTAssertTrue(d.useTessy, "sensitive -> Tessy always")
        XCTAssertTrue(d.useSky, "complex -> Sky")
        XCTAssertTrue(d.isTeamUp)
    }

    func testOverrideAtTessyForcesTessyOnly() {
        let (d, prompt) = DualAgentRouter.route(for: "@tessy explain quantum computing in detail")
        XCTAssertTrue(d.useTessy)
        XCTAssertFalse(d.useSky)
        XCTAssertEqual(prompt, "explain quantum computing in detail")
    }

    func testOverrideAtSkyForcesSkyOnly() {
        let (d, prompt) = DualAgentRouter.route(for: "@sky remember my dentist appointment")
        XCTAssertTrue(d.useSky)
        XCTAssertFalse(d.useTessy, "@sky must override the sensitive-keyword rule")
        XCTAssertEqual(prompt, "remember my dentist appointment")
    }

    func testOverrideAtBothForcesTeamUp() {
        let (d, prompt) = DualAgentRouter.route(for: "@both hello")
        XCTAssertTrue(d.useTessy)
        XCTAssertTrue(d.useSky)
        XCTAssertTrue(d.isTeamUp)
        XCTAssertEqual(prompt, "hello")
    }

    func testNoOverrideFallsBackToKeywordClassifier() {
        let (d, prompt) = DualAgentRouter.route(for: "remember my notes")
        XCTAssertFalse(d.useSky)
        XCTAssertTrue(d.useTessy)
        XCTAssertEqual(prompt, "remember my notes")
    }

    func testPromptIsTrimmed() {
        let (_, prompt) = DualAgentRouter.route(for: "   hello world   ")
        XCTAssertEqual(prompt, "hello world")
    }
}

final class AgentPersonaTests: XCTestCase {
    func testDisplayNames() {
        XCTAssertEqual(AgentPersona.tessy.displayName, "Tessy")
        XCTAssertEqual(AgentPersona.sky.displayName, "Sky")
    }

    func testSystemPromptFragmentsAreNonEmpty() {
        XCTAssertFalse(AgentPersona.tessy.systemPromptFragment.isEmpty)
        XCTAssertFalse(AgentPersona.sky.systemPromptFragment.isEmpty)
    }

    func testTessyPromptMentionsLocal() {
        let f = AgentPersona.tessy.systemPromptFragment.lowercased()
        XCTAssertTrue(f.contains("local") || f.contains("device"))
    }

    func testSkyPromptMentionsCloud() {
        let f = AgentPersona.sky.systemPromptFragment.lowercased()
        XCTAssertTrue(f.contains("cloud") || f.contains("remote"))
    }

    func testRawValueRoundTrip() {
        for p in AgentPersona.allCases {
            XCTAssertEqual(AgentPersona(rawValue: p.rawValue), p)
        }
    }
}
