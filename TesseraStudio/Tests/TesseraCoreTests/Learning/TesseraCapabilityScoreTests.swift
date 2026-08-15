import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Learning/TesseraCapabilityContracts.swift
// doc comment -- "generalCompetence is a GUARD axis (hard regression
// constraint), not a trade-off weight", the weighted-sum lens over
// `optimizationAxisNames` only, and the Pareto-dominance lens ("self
// dominates other across ALL axes: >= on every axis, > on at least one").
// No design doc covers this subsystem (per this cluster's contract-source
// fallback instructions); the source doc comments are the contract.
final class TesseraCapabilityScoreTests: DoctrineTestCase {

    // MARK: - vector / subscript

    func testVectorOrderMatchesAxisNamesOrder() {
        let score = TesseraCapabilityScore(mechanical: 1, apiCurrency: 2, hardTail: 3, personalStyle: 4, generalCompetence: 5)
        XCTAssertEqual(score.vector, [1, 2, 3, 4, 5])
        XCTAssertEqual(TesseraCapabilityScore.axisNames, ["mechanical", "apiCurrency", "hardTail", "personalStyle", "generalCompetence"])
    }

    func testSubscriptReadsEachNamedAxis() {
        let score = TesseraCapabilityScore(mechanical: 1, apiCurrency: 2, hardTail: 3, personalStyle: 4, generalCompetence: 5)
        for (name, expected) in zip(TesseraCapabilityScore.axisNames, score.vector) {
            XCTAssertEqual(score[name], expected)
        }
    }

    func testSubscriptOfUnknownAxisNameIsZero() {
        let score = TesseraCapabilityScore(mechanical: 9)
        XCTAssertEqual(score["not_a_real_axis"], 0)
    }

    func testDefaultInitIsAllZeros() {
        XCTAssertEqual(TesseraCapabilityScore().vector, [0, 0, 0, 0, 0])
    }

    // MARK: - optimizationAxisNames excludes the guard axis

    func testOptimizationAxisNamesExcludesGeneralCompetence() {
        XCTAssertEqual(TesseraCapabilityScore.optimizationAxisNames, ["mechanical", "apiCurrency", "hardTail", "personalStyle"])
        XCTAssertFalse(TesseraCapabilityScore.optimizationAxisNames.contains("generalCompetence"))
    }

    // MARK: - weightedSum: hand-computed fixtures (rule 9)

    func testWeightedSumWithUnitWeightsIsTheMeanOfTheFourOptimizationAxes() {
        let score = TesseraCapabilityScore(mechanical: 4, apiCurrency: 8, hardTail: 0, personalStyle: 4, generalCompetence: 100)
        // (4 + 8 + 0 + 4) / 4 = 4. generalCompetence (100) must NOT
        // participate -- it's the guard axis.
        XCTAssertEqual(score.weightedSum(weights: [:]), 4.0, accuracy: 0.0001)
    }

    func testWeightedSumHonorsPerAxisWeights() {
        let score = TesseraCapabilityScore(mechanical: 10, apiCurrency: 0, hardTail: 0, personalStyle: 0)
        // weight 1 on mechanical, weight 0 elsewhere present in the map
        // (defaulting the rest to 1.0 per the doc comment's `weights[axis] ?? 1.0`).
        let weights = ["mechanical": 3.0, "apiCurrency": 0.0, "hardTail": 0.0, "personalStyle": 0.0]
        // sum = 3*10 + 0*0 + 0*0 + 0*0 = 30; weightTotal = 3+0+0+0 = 3 -> 30/3 = 10
        XCTAssertEqual(score.weightedSum(weights: weights), 10.0, accuracy: 0.0001)
    }

    func testWeightedSumOfAllZeroWeightsIsZeroNotDivisionByZero() {
        let score = TesseraCapabilityScore(mechanical: 5, apiCurrency: 5, hardTail: 5, personalStyle: 5)
        let weights: [String: Double] = ["mechanical": 0, "apiCurrency": 0, "hardTail": 0, "personalStyle": 0]
        XCTAssertEqual(score.weightedSum(weights: weights), 0.0)
    }

    // MARK: - dominates: Pareto lens (rule 9 property test)

    func testDominatesRequiresGreaterOrEqualOnEveryAxis() {
        let better = TesseraCapabilityScore(mechanical: 2, apiCurrency: 2, hardTail: 2, personalStyle: 2, generalCompetence: 2)
        let worse = TesseraCapabilityScore(mechanical: 1, apiCurrency: 1, hardTail: 1, personalStyle: 1, generalCompetence: 1)
        XCTAssertTrue(better.dominates(worse))
        XCTAssertFalse(worse.dominates(better))
    }

    func testDominatesRequiresStrictlyBetterOnAtLeastOneAxis() {
        let a = TesseraCapabilityScore(mechanical: 1, apiCurrency: 1, hardTail: 1, personalStyle: 1, generalCompetence: 1)
        let identical = TesseraCapabilityScore(mechanical: 1, apiCurrency: 1, hardTail: 1, personalStyle: 1, generalCompetence: 1)
        XCTAssertFalse(a.dominates(identical), "equal on every axis is not domination")
    }

    func testDominatesIsFalseWhenAnyAxisIsWorse() {
        // Better on 4 axes, worse on the 5th -> not dominating.
        let mixed = TesseraCapabilityScore(mechanical: 2, apiCurrency: 2, hardTail: 2, personalStyle: 2, generalCompetence: 0)
        let baseline = TesseraCapabilityScore(mechanical: 1, apiCurrency: 1, hardTail: 1, personalStyle: 1, generalCompetence: 1)
        XCTAssertFalse(mixed.dominates(baseline))
    }

    func testDominanceIsIrreflexive() {
        // Property: a score never dominates itself (no axis is strictly
        // better than itself).
        let score = TesseraCapabilityScore(mechanical: 3, apiCurrency: 3, hardTail: 3, personalStyle: 3, generalCompetence: 3)
        XCTAssertFalse(score.dominates(score))
    }

    func testDominanceIsAntisymmetric() {
        // Property: if a dominates b, b cannot dominate a.
        let a = TesseraCapabilityScore(mechanical: 5, apiCurrency: 1, hardTail: 1, personalStyle: 1, generalCompetence: 1)
        let b = TesseraCapabilityScore(mechanical: 1, apiCurrency: 1, hardTail: 1, personalStyle: 1, generalCompetence: 1)
        XCTAssertTrue(a.dominates(b))
        XCTAssertFalse(b.dominates(a))
    }

    // MARK: - passesGuard: the collapse guard on generalCompetence only

    func testPassesGuardTriviallyPassesWithNilBaseline() {
        let score = TesseraCapabilityScore(generalCompetence: 0)
        XCTAssertTrue(score.passesGuard(baseline: nil, epsilon: 0))
    }

    func testPassesGuardPassesWhenAtOrAboveBaselineMinusEpsilon() {
        let baseline = TesseraCapabilityScore(generalCompetence: 10)
        let score = TesseraCapabilityScore(generalCompetence: 9)
        XCTAssertTrue(score.passesGuard(baseline: baseline, epsilon: 1))
        XCTAssertFalse(score.passesGuard(baseline: baseline, epsilon: 0.5))
    }

    func testPassesGuardIgnoresAllOtherAxes() {
        // A collapse on mechanical/apiCurrency/etc must NOT trip the
        // guard -- only generalCompetence is checked.
        let baseline = TesseraCapabilityScore(mechanical: 10, generalCompetence: 5)
        let collapsedElsewhere = TesseraCapabilityScore(mechanical: 0, generalCompetence: 5)
        XCTAssertTrue(collapsedElsewhere.passesGuard(baseline: baseline, epsilon: 0))
    }

    // MARK: - Round-trip identity (rule 2)

    func testEncodeDecodeIdentity() throws {
        let score = TesseraCapabilityScore(mechanical: 1.5, apiCurrency: -2, hardTail: 0, personalStyle: 3.25, generalCompetence: 100)
        let data = try JSONEncoder().encode(score)
        let decoded = try JSONDecoder().decode(TesseraCapabilityScore.self, from: data)
        XCTAssertEqual(decoded, score)
    }

    func testDecodesFromLegacyJSONWithAllFiveKeys() throws {
        let json = Data(#"{"mechanical":1,"apiCurrency":2,"hardTail":3,"personalStyle":4,"generalCompetence":5}"#.utf8)
        let decoded = try JSONDecoder().decode(TesseraCapabilityScore.self, from: json)
        XCTAssertEqual(decoded.vector, [1, 2, 3, 4, 5])
    }
}
