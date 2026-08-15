import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Agent/AgentPersona.swift doc
// comment -- "Tessy is the on-device, privacy-preserving agent...; Sky
// is the cloud intellect Tessy can invoke". Listed as a "healthy surface,
// do not touch" (persona design) in docs/AGENT-UX-FATIGUE-REVIEW.md
// Part 4 -- healthy means don't change the CODE, not "leave it untested"
// per this cluster's brief.
final class AgentPersonaTests: DoctrineTestCase {

    func testExactlyTwoPersonas() {
        // Independent oracle (rule 7): pinned against the doc comment's
        // named pair (Tessy, Sky), not against AgentPersona.allCases.
        XCTAssertEqual(Set(AgentPersona.allCases), [.tessy, .sky])
    }

    func testIdEqualsRawValue() {
        XCTAssertEqual(AgentPersona.tessy.id, "tessy")
        XCTAssertEqual(AgentPersona.sky.id, "sky")
    }

    func testDisplayNames() {
        XCTAssertEqual(AgentPersona.tessy.displayName, "Tessy")
        XCTAssertEqual(AgentPersona.sky.displayName, "Sky")
    }

    func testRoleHintsDistinguishLocalFromCloud() {
        XCTAssertTrue(AgentPersona.tessy.roleHint.lowercased().contains("local"))
        XCTAssertTrue(AgentPersona.sky.roleHint.lowercased().contains("cloud"))
    }

    // MARK: - System prompt fragments carry the privacy-boundary contract

    func testTessySystemPromptFragmentAssertsLocalPrivacyBoundary() {
        let fragment = AgentPersona.tessy.systemPromptFragment
        XCTAssertTrue(fragment.contains("Tessy"))
        XCTAssertTrue(fragment.lowercased().contains("private"))
    }

    func testSkySystemPromptFragmentAssertsRemoteBoundary() {
        let fragment = AgentPersona.sky.systemPromptFragment
        XCTAssertTrue(fragment.contains("Sky"))
        XCTAssertTrue(fragment.lowercased().contains("remote") || fragment.lowercased().contains("cloud"))
    }

    func testSystemPromptFragmentsAreDistinctPerPersona() {
        XCTAssertNotEqual(AgentPersona.tessy.systemPromptFragment, AgentPersona.sky.systemPromptFragment)
    }

    #if canImport(SwiftUI)
    func testTintsAreDistinctPerPersona() {
        XCTAssertNotEqual(AgentPersona.tessy.tint, AgentPersona.sky.tint)
    }

    func testSymbolNamesAreDistinctPerPersona() {
        XCTAssertNotEqual(AgentPersona.tessy.symbolName, AgentPersona.sky.symbolName)
    }
    #endif
}
