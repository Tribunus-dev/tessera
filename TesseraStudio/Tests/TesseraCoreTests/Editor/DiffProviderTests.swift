import XCTest
@testable import TesseraCore

// MARK: - DiffProviderTests
//
// Contract: DiffProvider.swift's own doc comments - "RewriteMode... Mirrors
// the Apple Writing Tools preset tones." `DiffProvider`/`GhostTextProvider`
// (the peer protocol in this directory) are pure `@MainActor` protocol
// declarations with no default implementations - there is no behavior at
// this layer to assert beyond the one concrete value type this file ships
// (`RewriteMode`), so this suite covers that type only. (Noted in
// docs/.scratch/test-rewrite-findings-writer.md: GhostTextProvider.swift
// ships no test file for the same reason - a protocol with zero
// conformances/defaults in this file has no testable surface of its own.)

final class DiffProviderTests: DoctrineTestCase {

    // MARK: - systemPrompt per case (independent oracle, doctrine rule 7)

    func testSystemPromptForEveryCaseMatchesItsDocumentedTone() {
        XCTAssertTrue(RewriteMode.friendly.systemPrompt.lowercased().contains("friendly"))
        XCTAssertTrue(RewriteMode.professional.systemPrompt.lowercased().contains("professional"))
        XCTAssertTrue(RewriteMode.concise.systemPrompt.lowercased().contains("concise"))
        XCTAssertTrue(RewriteMode.improve.systemPrompt.lowercased().contains("improve"))
        XCTAssertFalse(RewriteMode.custom.systemPrompt.isEmpty)
    }

    func testEveryCaseHasANonEmptyDistinctSystemPrompt() {
        let prompts = RewriteMode.allCases.map(\.systemPrompt)
        XCTAssertTrue(prompts.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(prompts).count, prompts.count, "every mode must have its own distinct prompt")
    }

    // MARK: - CaseIterable totality (independent oracle)

    private static let expectedRawValues: Set<String> = ["friendly", "professional", "concise", "improve", "custom"]

    func testRewriteModeCaseIterableMatchesThePinnedList() {
        XCTAssertEqual(Set(RewriteMode.allCases.map(\.rawValue)), Self.expectedRawValues)
    }

    // MARK: - Round-trip identity (doctrine rule 2)

    func testRewriteModeEncodeDecodeIdentity() throws {
        // RewriteMode declares Sendable/CaseIterable/Codable only (no
        // Equatable/Hashable) - compare via rawValue rather than `==`.
        for mode in RewriteMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(RewriteMode.self, from: data)
            XCTAssertEqual(decoded.rawValue, mode.rawValue)
        }
    }
}
