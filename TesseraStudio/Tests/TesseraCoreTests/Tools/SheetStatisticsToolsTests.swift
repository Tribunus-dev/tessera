import XCTest
@testable import TesseraCore

// MARK: - SheetStatisticsToolsTests
//
// Contract: this cluster's own derived 18-item stub (SheetStatisticsTools.swift's
// file header + docs/.scratch/p2-a-findings-4.md), plus the landed math each
// tool delegates to (StatisticsFunctions.swift / FunctionRegistry.swift) for
// the hand-computed fixture numbers below. Per testing-doctrine.md rule 9
// ("math gets fixtures AND properties"), every tool gets at least one
// hand-computed fixture case; a few also get a cheap property/invariant
// check. Per rule 7 ("independent oracles"), the 18-name totality test below
// pins its own hardcoded name list rather than deriving it from the tools
// array it is checking.
//
// These tools are pure reads (`.auto` approval, no mutation, no receipt) -
// SheetToolContext.shared is the only shared/global state they touch, so
// every test installs its own fixture SheetEngine and `tearDown()` clears it
// so no test leaks its workbook into the next (SheetToolContext.shared is a
// process-wide singleton - see SheetTools.swift's own doc comment on why it
// exists).

final class SheetStatisticsToolsTests: DoctrineTestCase {

    override func tearDown() {
        SheetToolContext.shared.install(nil)
        super.tearDown()
    }

    // MARK: - Fixture helpers

    /// Installs a fresh engine with `values` written column-major starting
    /// at A1 (A1, A2, ... An), and installs it as the active workbook.
    @discardableResult
    private func installFixture(_ values: [Double], column: Int = 0) -> SheetEngine {
        let engine = SheetEngine()
        for (i, v) in values.enumerated() {
            engine.setValue(sheet: nil, addr: CellAddr(col: column, row: i), value: .number(v))
        }
        SheetToolContext.shared.install(engine)
        return engine
    }

    private func number(_ result: ToolResult, key: String = "result") -> Double? {
        result.data?[key]?.numberValue
    }

    // MARK: - Totality (doctrine rule 7: independent oracle)

    func testAllEighteenToolsExposeTheDerivedContractStubNamesAtAutoApproval() {
        let tools: [any TesseraTool] = [
            SheetStatMeanTool(), SheetStatMedianTool(), SheetStatModeTool(),
            SheetStatStandardDeviationTool(), SheetStatStandardDeviationPopulationTool(),
            SheetStatVarianceTool(), SheetStatVariancePopulationTool(),
            SheetStatRangeTool(), SheetStatQuartilesTool(), SheetStatIQRTool(),
            SheetStatCorrelationTool(), SheetStatLinearRegressionTool(),
            SheetStatRankTool(), SheetStatPercentileTool(), SheetStatZScoreTool(),
            SheetStatLargeTool(), SheetStatSmallTool(), SheetStatCountTool(),
        ]
        // Pinned independently of the array above - the file header's own
        // derived 18-item contract stub, not re-derived from the tools.
        let expectedNames: Set<String> = [
            "sheet_stat_mean", "sheet_stat_median", "sheet_stat_mode",
            "sheet_stat_stdev", "sheet_stat_stdev_population",
            "sheet_stat_variance", "sheet_stat_variance_population",
            "sheet_stat_range", "sheet_stat_quartiles", "sheet_stat_iqr",
            "sheet_stat_correlation", "sheet_stat_linear_regression",
            "sheet_stat_rank", "sheet_stat_percentile", "sheet_stat_zscore",
            "sheet_stat_large", "sheet_stat_small", "sheet_stat_count",
        ]
        XCTAssertEqual(tools.count, 18, "the contract stub names exactly 18 tools")
        XCTAssertEqual(Set(tools.map(\.name)), expectedNames)
        for tool in tools {
            XCTAssertEqual(tool.defaultApprovalLevel, .auto, "\(tool.name) is a pure read - must run unprompted")
            XCTAssertFalse(tool.description.isEmpty, "\(tool.name) needs a description")
        }
    }

    // MARK: - No workbook (denial-path equivalent for a read tool)

    func testMeanFailsCleanlyWithNoWorkbookInstalled() async throws {
        SheetToolContext.shared.install(nil)
        let result = try await SheetStatMeanTool().execute(arguments: ["reference": .string("A1:A5")])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, SheetToolError.noWorkbook.errorDescription)
    }

    // MARK: - Missing arguments

    func testMeanFailsCleanlyWithMissingReference() async throws {
        installFixture([1, 2, 3])
        let result = try await SheetStatMeanTool().execute(arguments: [:])
        XCTAssertFalse(result.success)
    }

    func testCorrelationFailsCleanlyWithMissingRangeY() async throws {
        installFixture([1, 2, 3])
        let result = try await SheetStatCorrelationTool().execute(arguments: ["rangeX": .string("A1:A3")])
        XCTAssertFalse(result.success)
    }

    // MARK: - Fixture: A1:A5 = [1, 2, 3, 4, 5]

    func testMeanOfOneThroughFive() async throws {
        installFixture([1, 2, 3, 4, 5])
        let result = try await SheetStatMeanTool().execute(arguments: ["reference": .string("A1:A5")])
        XCTAssertTrue(result.success)
        XCTAssertEqual(number(result), 3.0)
    }

    func testMedianOfOneThroughFive() async throws {
        installFixture([1, 2, 3, 4, 5])
        let result = try await SheetStatMedianTool().execute(arguments: ["reference": .string("A1:A5")])
        XCTAssertEqual(number(result), 3.0)
    }

    func testSampleVarianceAndStdevOfOneThroughFive() async throws {
        installFixture([1, 2, 3, 4, 5])
        let variance = try await SheetStatVarianceTool().execute(arguments: ["reference": .string("A1:A5")])
        let stdev = try await SheetStatStandardDeviationTool().execute(arguments: ["reference": .string("A1:A5")])
        XCTAssertEqual(number(variance)!, 2.5, accuracy: 1e-9)
        XCTAssertEqual(number(stdev)!, 2.5.squareRoot(), accuracy: 1e-9)
        // Property: stdev == sqrt(variance), independently of the fixture.
        XCTAssertEqual(number(stdev)!, number(variance)!.squareRoot(), accuracy: 1e-9)
    }

    func testPopulationVarianceAndStdevOfOneThroughFive() async throws {
        installFixture([1, 2, 3, 4, 5])
        let variance = try await SheetStatVariancePopulationTool().execute(arguments: ["reference": .string("A1:A5")])
        let stdev = try await SheetStatStandardDeviationPopulationTool().execute(arguments: ["reference": .string("A1:A5")])
        XCTAssertEqual(number(variance)!, 2.0, accuracy: 1e-9)
        XCTAssertEqual(number(stdev)!, 2.0.squareRoot(), accuracy: 1e-9)
    }

    func testRangeOfOneThroughFive() async throws {
        installFixture([1, 2, 3, 4, 5])
        let result = try await SheetStatRangeTool().execute(arguments: ["reference": .string("A1:A5")])
        XCTAssertEqual(number(result), 4.0)
    }

    func testCountOfOneThroughFive() async throws {
        installFixture([1, 2, 3, 4, 5])
        let result = try await SheetStatCountTool().execute(arguments: ["reference": .string("A1:A5")])
        XCTAssertEqual(number(result), 5.0)
    }

    func testQuartilesOfOneThroughFive() async throws {
        installFixture([1, 2, 3, 4, 5])
        let result = try await SheetStatQuartilesTool().execute(arguments: ["reference": .string("A1:A5")])
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?["q1"]?.numberValue, 2.0)
        XCTAssertEqual(result.data?["q2"]?.numberValue, 3.0)
        XCTAssertEqual(result.data?["q3"]?.numberValue, 4.0)
    }

    func testIQROfOneThroughFive() async throws {
        installFixture([1, 2, 3, 4, 5])
        let result = try await SheetStatIQRTool().execute(arguments: ["reference": .string("A1:A5")])
        // Q3 (4) - Q1 (2), matching testQuartilesOfOneThroughFive above.
        XCTAssertEqual(number(result), 2.0)
    }

    func testPercentileZeroAndOneMatchMinAndMax() async throws {
        installFixture([1, 2, 3, 4, 5])
        let p0 = try await SheetStatPercentileTool().execute(arguments: ["reference": .string("A1:A5"), "k": .number(0)])
        let p1 = try await SheetStatPercentileTool().execute(arguments: ["reference": .string("A1:A5"), "k": .number(1)])
        // Property: PERCENTILE(0) == min, PERCENTILE(1) == max.
        XCTAssertEqual(number(p0), 1.0)
        XCTAssertEqual(number(p1), 5.0)
    }

    func testLargeAndSmallOfOneThroughFive() async throws {
        installFixture([1, 2, 3, 4, 5])
        let large1 = try await SheetStatLargeTool().execute(arguments: ["reference": .string("A1:A5"), "k": .number(1)])
        let small1 = try await SheetStatSmallTool().execute(arguments: ["reference": .string("A1:A5"), "k": .number(1)])
        XCTAssertEqual(number(large1), 5.0)
        XCTAssertEqual(number(small1), 1.0)
    }

    func testRankDescendingAndAscendingOfFourInOneThroughFive() async throws {
        installFixture([1, 2, 3, 4, 5])
        let descending = try await SheetStatRankTool().execute(arguments: ["reference": .string("A1:A5"), "value": .number(4)])
        let ascending = try await SheetStatRankTool().execute(arguments: ["reference": .string("A1:A5"), "value": .number(4), "order": .string("ascending")])
        // Descending (default): only 5 is larger -> rank 2.
        XCTAssertEqual(descending.data?["rank"]?.numberValue, 2.0)
        // Ascending: 1,2,3 are smaller -> rank 4.
        XCTAssertEqual(ascending.data?["rank"]?.numberValue, 4.0)
    }

    func testRankFailsCleanlyWhenValueNotInRange() async throws {
        installFixture([1, 2, 3, 4, 5])
        let result = try await SheetStatRankTool().execute(arguments: ["reference": .string("A1:A5"), "value": .number(42)])
        XCTAssertFalse(result.success)
    }

    func testZScoreOfFourInOneThroughFive() async throws {
        installFixture([1, 2, 3, 4, 5])
        let result = try await SheetStatZScoreTool().execute(arguments: ["reference": .string("A1:A5"), "value": .number(4)])
        // mean = 3, sample stdev = sqrt(2.5) -> z = 1 / sqrt(2.5).
        XCTAssertEqual(number(result)!, 1.0 / 2.5.squareRoot(), accuracy: 1e-9)
    }

    // MARK: - Fixture: mode with a real repeat

    func testModeOfRepeatedValues() async throws {
        installFixture([2, 4, 4, 4, 5, 5, 7, 9])
        let result = try await SheetStatModeTool().execute(arguments: ["reference": .string("A1:A8")])
        XCTAssertTrue(result.success)
        XCTAssertEqual(number(result), 4.0)
        XCTAssertEqual(result.data?["occurrences"]?.numberValue, 3.0)
    }

    func testModeFailsCleanlyWhenNothingRepeats() async throws {
        installFixture([1, 2, 3, 4, 5])
        let result = try await SheetStatModeTool().execute(arguments: ["reference": .string("A1:A5")])
        XCTAssertFalse(result.success)
    }

    // MARK: - Two-range fixtures: correlation + linear regression

    func testCorrelationAndLinearRegressionOfAPerfectLine() async throws {
        let engine = SheetEngine()
        // A1:A5 = 1..5 ("x"), B1:B5 = 2,4,6,8,10 ("y" = 2x exactly).
        for i in 0..<5 {
            engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: i), value: .number(Double(i + 1)))
            engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: i), value: .number(Double(2 * (i + 1))))
        }
        SheetToolContext.shared.install(engine)

        let correlation = try await SheetStatCorrelationTool().execute(arguments: [
            "rangeX": .string("A1:A5"), "rangeY": .string("B1:B5"),
        ])
        XCTAssertEqual(number(correlation)!, 1.0, accuracy: 1e-9)

        let regression = try await SheetStatLinearRegressionTool().execute(arguments: [
            "rangeX": .string("A1:A5"), "rangeY": .string("B1:B5"),
        ])
        XCTAssertTrue(regression.success)
        // Broken into intermediate `let`s (rather than a chained
        // `regression.data?["slope"]?.numberValue!` inline in the
        // XCTAssertEqual call): the compiler failed to solve the
        // FloatingPoint generic parameter through that deep an optional
        // chain ending in a force-unwrap inside a generic call's
        // argument list ("cannot convert value of type 'Double?' to
        // expected argument type 'Double'", pointing at the chain itself
        // - a real pre-existing build break in this landed test file,
        // fixed here as part of the P2-A centralized wiring pass's
        // build-error sweep). `XCTUnwrap` also gives a clearer failure
        // message than a bare `!` would on a genuinely-missing key.
        let slope = try XCTUnwrap(regression.data?["slope"]?.numberValue)
        let intercept = try XCTUnwrap(regression.data?["intercept"]?.numberValue)
        XCTAssertEqual(slope, 2.0, accuracy: 1e-9)
        XCTAssertEqual(intercept, 0.0, accuracy: 1e-9)
    }

    func testLinearRegressionFailsCleanlyOnConstantX() async throws {
        let engine = SheetEngine()
        for i in 0..<5 {
            engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: i), value: .number(7)) // constant x
            engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: i), value: .number(Double(i)))
        }
        SheetToolContext.shared.install(engine)
        let result = try await SheetStatLinearRegressionTool().execute(arguments: [
            "rangeX": .string("A1:A5"), "rangeY": .string("B1:B5"),
        ])
        XCTAssertFalse(result.success)
    }

    // MARK: - Sheet-qualified reference

    func testMeanReadsFromANamedNonActiveSheet() async throws {
        let engine = SheetEngine()
        engine.createSheet(name: "Data")
        engine.setValue(sheet: "Data", addr: CellAddr(col: 0, row: 0), value: .number(10))
        engine.setValue(sheet: "Data", addr: CellAddr(col: 0, row: 1), value: .number(20))
        SheetToolContext.shared.install(engine)

        let result = try await SheetStatMeanTool().execute(arguments: [
            "reference": .string("A1:A2"), "sheet": .string("Data"),
        ])
        XCTAssertEqual(number(result), 15.0)
    }

    // MARK: - Schema shape

    func testCorrelationSchemaRequiresBothRanges() {
        let schema = SheetStatCorrelationTool().parameters
        XCTAssertEqual(Set(schema.required ?? []), ["rangeX", "rangeY"])
    }

    func testPercentileSchemaRequiresReferenceAndK() {
        let schema = SheetStatPercentileTool().parameters
        XCTAssertEqual(Set(schema.required ?? []), ["reference", "k"])
    }
}
