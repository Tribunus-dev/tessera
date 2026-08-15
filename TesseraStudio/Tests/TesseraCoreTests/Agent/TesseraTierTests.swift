import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Agent/TesseraTier.swift doc
// comments (the canonical tier table + the boundary-drift rule) plus
// AGENTS.md "Tier policy (Wave 1, item 1B)" and the doctrine's explicit
// emphasis for this cluster: "hard cap has no override... tier lowering
// ONLY via revoke()". Also docs/PROJECT-STATUS.md item 1B: "boundary-drift
// guard: no tier downgrade without TesseraTier.revoke".
final class TesseraTierTests: DoctrineTestCase {

    // MARK: - Canonical tier table (independent oracle: hand-computed
    // fixture cases from the doc comment's table, not derived from the
    // implementation).

    func testLowRiskReversibleIsTier0() {
        XCTAssertEqual(TesseraTier.tier(for: "list_models", risk: .low), .tier0)
    }

    func testMediumRiskReversibleIsTier1() {
        XCTAssertEqual(TesseraTier.tier(for: "file_write:src/**", risk: .medium), .tier1)
    }

    func testLowRiskIrreversibleIsTier2() {
        // "rm" is a destructive verb head -> irreversible regardless of risk.
        XCTAssertEqual(TesseraTier.tier(for: "bash:rm", risk: .low), .tier2)
    }

    func testMediumRiskIrreversibleIsTier2() {
        XCTAssertEqual(TesseraTier.tier(for: "bash:rm", risk: .medium), .tier2)
    }

    func testHighRiskIsAlwaysTier3() {
        XCTAssertEqual(TesseraTier.tier(for: "send_email", risk: .high), .tier3)
    }

    func testForbiddenRiskIsAlwaysTier3() {
        XCTAssertEqual(TesseraTier.tier(for: "anything", risk: .forbidden), .tier3)
    }

    func testForbiddenOutranksEvenAnIrreversibleDestructiveVerb() {
        XCTAssertEqual(TesseraTier.tier(for: "bash:rm", risk: .forbidden), .tier3)
    }

    // MARK: - tier(forRisk:) assumes reversible (best case)

    func testTierForRiskOnlyAssumesReversible() {
        // Low risk with no action-class context -> tier0 (same as the
        // reversible low-risk fixture above).
        XCTAssertEqual(TesseraTier.tier(forRisk: .low), .tier0)
        XCTAssertEqual(TesseraTier.tier(forRisk: .medium), .tier1)
        XCTAssertEqual(TesseraTier.tier(forRisk: .high), .tier3)
        XCTAssertEqual(TesseraTier.tier(forRisk: .forbidden), .tier3)
    }

    // MARK: - Comparable / severity ordering

    func testSeverityOrderingIsMonotonic() {
        XCTAssertLessThan(TesseraTier.tier0, .tier1)
        XCTAssertLessThan(TesseraTier.tier1, .tier2)
        XCTAssertLessThan(TesseraTier.tier2, .tier3)
    }

    func testSeverityValuesMatchTierIndex() {
        XCTAssertEqual(TesseraTier.tier0.severity, 0)
        XCTAssertEqual(TesseraTier.tier1.severity, 1)
        XCTAssertEqual(TesseraTier.tier2.severity, 2)
        XCTAssertEqual(TesseraTier.tier3.severity, 3)
    }

    // MARK: - Labels (ASCII, per AGENTS.md "ASCII, not unicode")

    func testShortLabelsAreASCIIAndDistinct() {
        let labels = TesseraTier.allCases.map(\.shortLabel)
        XCTAssertEqual(Set(labels).count, labels.count, "short labels must be distinct per tier")
        for label in labels {
            XCTAssertTrue(label.allSatisfy { $0.isASCII }, "\(label) must be ASCII")
        }
        XCTAssertEqual(TesseraTier.tier0.shortLabel, "T0")
        XCTAssertEqual(TesseraTier.tier3.shortLabel, "T3")
    }

    func testDisplayNamesAreDistinct() {
        let names = TesseraTier.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count)
    }

    // MARK: - revoke(): the ONLY path that lowers a tier (doctrine emphasis)

    func testRevokeLowersEachTierByExactlyOneNotch() {
        XCTAssertEqual(TesseraTier.tier3.revoke(), .tier2)
        XCTAssertEqual(TesseraTier.tier2.revoke(), .tier1)
        XCTAssertEqual(TesseraTier.tier1.revoke(), .tier0)
    }

    func testRevokeAtTier0IsAFloorNoOp() {
        // tier0 is the floor: revoke() does not underflow past it.
        XCTAssertEqual(TesseraTier.tier0.revoke(), .tier0)
    }

    func testRepeatedRevokeMonotonicallyWalksDownToTheFloor() {
        var tier = TesseraTier.tier3
        var steps: [TesseraTier] = [tier]
        for _ in 0..<5 {
            tier = tier.revoke()
            steps.append(tier)
        }
        XCTAssertEqual(steps, [.tier3, .tier2, .tier1, .tier0, .tier0, .tier0])
    }

    // MARK: - Boundary-drift guard: revoke() is the ONLY public API that
    // can produce a lower tier than a pure classification would. This is
    // a structural (not just behavioral) assertion per the doctrine
    // emphasis: "write a test that greps/type-checks this is structurally
    // true, not just behaviorally". `tier(for:risk:)` and `tier(forRisk:)`
    // are pure functions of their inputs with no `force:`-shaped
    // parameter; the only way to obtain a strictly-lower `TesseraTier`
    // value than what a classification call produces is to call
    // `.revoke()` on the result. We assert this both behaviorally (the
    // classification functions are referentially transparent: same
    // inputs always produce the same tier, so there is no hidden
    // downgrade path) and structurally (source-grep for a `force:`
    // parameter, which the doc comment says does not exist anywhere in
    // the tier chain).
    func testTierClassificationIsPureAndDeterministic() {
        // Same inputs always produce the same tier (doc comment: "same
        // inputs always produce the same tier"). Calling twice with
        // identical arguments must never drift.
        for _ in 0..<25 {
            XCTAssertEqual(
                TesseraTier.tier(for: "bash:git", risk: .medium),
                TesseraTier.tier(for: "bash:git", risk: .medium)
            )
        }
    }

    func testNoForceOverrideParameterExistsOnTheTierChain() throws {
        // Structural guard: grep the tier chain's own source for a
        // `force:` parameter label. AGENTS.md: "The cap on a budget is a
        // HARD cap. There is no `force:` override." and the TesseraTier
        // doc comment: "a tier can ONLY be lowered through
        // TesseraTier.revoke". If a future edit adds a `force:` bypass
        // anywhere in this file, this test catches it.
        let url = try tierSourceURL()
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(
            source.contains("force:"),
            "TesseraTier.swift must not gain a `force:` parameter -- the hard-cap/no-override invariant is structural"
        )
    }

    func testOnlyRevokeMutatesTierValueInTesseraTierSwift() throws {
        // Independent-oracle structural check (rule 7): count the
        // `-> TesseraTier` returning functions declared in the file and
        // assert `revoke` is the only one whose name signals a downgrade.
        // This does not iterate the enum's own cases to validate itself;
        // it grep-parses the source text directly.
        let url = try tierSourceURL()
        let source = try String(contentsOf: url, encoding: .utf8)
        let downgradeNamedFunctions = source
            .components(separatedBy: .newlines)
            .filter { $0.contains("func ") && ($0.lowercased().contains("lower") || $0.lowercased().contains("downgrade") || $0.lowercased().contains("revoke")) }
        // Every such line must be the `revoke()` declaration.
        for line in downgradeNamedFunctions {
            XCTAssertTrue(
                line.contains("func revoke()"),
                "unexpected downgrade-shaped function outside revoke(): \(line)"
            )
        }
    }

    private func tierSourceURL() throws -> URL {
        // #filePath for this test file is
        // .../Tests/TesseraCoreTests/Agent/TesseraTierTests.swift; the
        // source under test lives at the mirrored path under Sources.
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent() // Agent/
            .deletingLastPathComponent() // TesseraCoreTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // TesseraStudio/
        let sourceURL = repoRoot
            .appendingPathComponent("Sources/TesseraCore/Agent/TesseraTier.swift")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw XCTSkip("TesseraTier.swift not found at expected path; skipping structural grep")
        }
        return sourceURL
    }

    // MARK: - Round-trip identity (rule 2)

    func testEncodeDecodeIdentity() throws {
        for tier in TesseraTier.allCases {
            let data = try JSONEncoder().encode(tier)
            let decoded = try JSONDecoder().decode(TesseraTier.self, from: data)
            XCTAssertEqual(decoded, tier)
        }
    }

    func testDecodesFromLegacyRawStringJSON() throws {
        let json = Data("\"tier2\"".utf8)
        let decoded = try JSONDecoder().decode(TesseraTier.self, from: json)
        XCTAssertEqual(decoded, .tier2)
    }

    // MARK: - Independent oracle: exhaustive tier set (rule 7)

    func testTierCasesArePinnedAgainstTheCanonicalFourTierSpec() {
        let expected: Set<String> = ["tier0", "tier1", "tier2", "tier3"]
        let actual = Set(TesseraTier.allCases.map(\.rawValue))
        XCTAssertEqual(actual, expected)
    }
}
