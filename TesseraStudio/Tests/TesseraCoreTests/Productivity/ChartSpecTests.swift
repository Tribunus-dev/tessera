import XCTest
@testable import TesseraCore

/// Tests for the ChartSpec data model: JSON round-trip for every
/// `ChartKind` case (P1a and P1b), `ChartSeries`/`ChartAxes`/
/// `ChartLegend` documented defaults, and the `Block.chart`
/// `attributes["chart"]` bridge - mirrors `BlockTests.swift`'s
/// Block+Shape / Block+Frame bridge tests.
final class ChartSpecTests: XCTestCase {

    // MARK: - ChartKind round-trip

    func testEveryChartKindRoundTrips() throws {
        let kinds: [ChartKind] = [
            .columnOrBar(orientation: .vertical, stacked: false),
            .columnOrBar(orientation: .vertical, stacked: true),
            .columnOrBar(orientation: .horizontal, stacked: false),
            .columnOrBar(orientation: .horizontal, stacked: true),
            .line,
            .area(stacked: false),
            .area(stacked: true),
            .pie(donut: false),
            .pie(donut: true),
            .scatter,
            // P1b
            .bubble, .net, .columnAndLine, .ofPie, .sparkline,
            .stock(variant: .highLowClose),
            .stock(variant: .openHighLowClose),
            .stock(variant: .volumeHighLowClose),
            .stock(variant: .volumeOpenHighLowClose),
        ]
        for kind in kinds {
            let spec = ChartSpec(kind: kind, series: [ChartSeries(name: "S1", values: [1, 2, 3])])
            let data = try JSONEncoder().encode(spec)
            let decoded = try JSONDecoder().decode(ChartSpec.self, from: data)
            XCTAssertEqual(decoded.kind, kind, "round-trip failed for \(kind)")
            XCTAssertEqual(decoded.series, spec.series)
        }
    }

    func testEveryChartSeriesRoleRoundTrips() throws {
        for role in ChartSeriesRole.allCases {
            let series = ChartSeries(role: role, values: [1, 2])
            let data = try JSONEncoder().encode(series)
            let decoded = try JSONDecoder().decode(ChartSeries.self, from: data)
            XCTAssertEqual(decoded.role, role, "round-trip failed for \(role)")
        }
    }

    // MARK: - Defaults (the gate's "incomplete spec still renders" philosophy)

    func testChartAxesDefaultsToAllNil() {
        let axes = ChartAxes()
        XCTAssertNil(axes.xLabelFormat)
        XCTAssertNil(axes.yLabelFormat)
        XCTAssertNil(axes.xTitle)
        XCTAssertNil(axes.yTitle)
        XCTAssertNil(axes.ySecondaryLabelFormat)
        XCTAssertNil(axes.ySecondaryTitle)
    }

    func testChartLegendDefaultsToAutoVisibility() {
        let legend = ChartLegend()
        XCTAssertNil(legend.isVisible, "nil isVisible is the documented 'auto' state")
        XCTAssertEqual(legend.position, .bottom)
    }

    func testChartSeriesDefaults() {
        let series = ChartSeries()
        XCTAssertNil(series.name)
        XCTAssertEqual(series.role, .value)
        XCTAssertTrue(series.values.isEmpty)
        XCTAssertNil(series.categoryLabels)
        XCTAssertNil(series.usesSecondaryAxis, "nil is the documented 'primary axis' state")
    }

    /// `usesSecondaryAxis` follows `ChartLegend.isVisible`'s own nil-is-
    /// the-common-case idiom: round-trips both the unset and explicit
    /// states, and a JSON payload from before this field existed (no
    /// key at all) still decodes.
    func testUsesSecondaryAxisRoundTripsAndDefaultsToNilForOldJSON() throws {
        for value in [nil, false, true] {
            let series = ChartSeries(role: .value, values: [1], usesSecondaryAxis: value)
            let data = try JSONEncoder().encode(series)
            let decoded = try JSONDecoder().decode(ChartSeries.self, from: data)
            XCTAssertEqual(decoded.usesSecondaryAxis, value)
        }

        let preExistingFieldJSON = Data(#"{"role":"value","values":[1,2]}"#.utf8)
        let decoded = try JSONDecoder().decode(ChartSeries.self, from: preExistingFieldJSON)
        XCTAssertNil(decoded.usesSecondaryAxis)
    }

    func testIncompleteChartSpecUsesDocumentedDefaults() {
        let spec = ChartSpec(kind: .line)
        XCTAssertEqual(spec.axes, ChartAxes())
        XCTAssertEqual(spec.legend, ChartLegend())
        XCTAssertNil(spec.title)
        XCTAssertTrue(spec.series.isEmpty)
    }

    // MARK: - Block + Chart bridge

    func testChartBlockRoundTripsThroughAttributes() {
        let spec = ChartSpec(
            kind: .columnOrBar(orientation: .vertical, stacked: false),
            series: [ChartSeries(name: "Revenue", role: .value, values: [10, 20, 30], categoryLabels: ["Jan", "Feb", "Mar"])],
            title: "Q1"
        )
        var block = Block(type: .chart)
        block.chart = spec
        XCTAssertEqual(block.type, .chart)
        XCTAssertEqual(block.chart, spec)
        XCTAssertNotNil(block.attributes["chart"])

        block.chart = nil
        XCTAssertNil(block.attributes["chart"])
        XCTAssertNil(block.chart)
    }

    func testChartBridgeIsNilForNonChartBlockOrMissingAttribute() {
        XCTAssertNil(Block(type: .paragraph).chart)
        XCTAssertNil(Block(type: .chart).chart, "no attributes[\"chart\"] set yet - treated as 'no chart', not corrupted data")
    }

    func testSettingChartOnNonChartBlockIsANoOp() {
        var block = Block(type: .paragraph)
        block.chart = ChartSpec(kind: .line)
        XCTAssertNil(block.chart)
        XCTAssertNil(block.attributes["chart"])
    }

    func testChartBlockSurvivesDocumentASTRoundTrip() throws {
        var block = Block(type: .chart)
        block.chart = ChartSpec(kind: .pie(donut: true), series: [ChartSeries(values: [1, 2, 3])])
        let doc = DocumentAST(blocks: [block.id: block], rootChildren: [block.id])
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(DocumentAST.self, from: data)
        XCTAssertEqual(decoded.blocks[block.id]?.chart?.kind, .pie(donut: true))
        XCTAssertEqual(decoded.rootChildren, [block.id])
    }
}
