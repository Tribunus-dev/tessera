import XCTest
import Foundation
@testable import TesseraCore

// MARK: - ChartSpecTests
//
// Value-type round-trip tests (doctrine rule 2) for ChartSpec.swift,
// which lives at Sources/TesseraCore/Productivity/ChartSpec.swift (not
// under Materials/) - placed here per this cluster's brief ("a sensible
// new location... .../Slides/ChartSpecTests.swift"). Contract source:
// studio-expansion-design-refinement-2026-08-14.md section 3 "Gate 3 -
// ChartRenderer staging" (series-typed ChartSpec; P1a six core
// families + P1b five long-tail).

final class ChartSpecTests: DoctrineTestCase {

    // MARK: - ChartKind round trip - every case, including associated values

    func testEveryChartKindCaseEncodeDecodeIsIdentity() throws {
        let kinds: [ChartKind] = [
            .columnOrBar(orientation: .vertical, stacked: false),
            .columnOrBar(orientation: .horizontal, stacked: true),
            .line,
            .area(stacked: true),
            .pie(donut: true),
            .pie(donut: false),
            .scatter,
            .bubble,
            .net,
            .stock(variant: .openHighLowClose),
            .columnAndLine,
            .ofPie,
            .sparkline,
        ]
        for kind in kinds {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(ChartKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }

    func testChartStockVariantHasExactlyTheFourDocumentedCases() {
        let expected: Set<String> = ["highLowClose", "openHighLowClose", "volumeHighLowClose", "volumeOpenHighLowClose"]
        XCTAssertEqual(Set(ChartStockVariant.allCases.map(\.rawValue)), expected)
    }

    // MARK: - ChartSeries round trip

    func testChartSeriesEncodeDecodeIsIdentityWithAllFieldsSet() throws {
        let series = ChartSeries(
            name: "Revenue",
            role: .value,
            values: [1, 2, 3.5],
            categoryLabels: ["Q1", "Q2", "Q3"],
            usesSecondaryAxis: true
        )
        let data = try JSONEncoder().encode(series)
        let decoded = try JSONDecoder().decode(ChartSeries.self, from: data)
        XCTAssertEqual(decoded, series)
    }

    func testChartSeriesDefaultsMatchTheDocumentedNilIsCommonCaseConvention() {
        let series = ChartSeries()
        XCTAssertNil(series.name)
        XCTAssertEqual(series.role, .value)
        XCTAssertEqual(series.values, [])
        XCTAssertNil(series.categoryLabels)
        XCTAssertNil(series.usesSecondaryAxis)
    }

    // MARK: - ChartAxes / ChartLegend round trip

    func testChartAxesEncodeDecodeIsIdentity() throws {
        let axes = ChartAxes(
            xLabelFormat: "#,##0",
            yLabelFormat: "0.00%",
            xTitle: "Quarter",
            yTitle: "Revenue",
            ySecondaryLabelFormat: "0",
            ySecondaryTitle: "Units"
        )
        let data = try JSONEncoder().encode(axes)
        let decoded = try JSONDecoder().decode(ChartAxes.self, from: data)
        XCTAssertEqual(decoded, axes)
    }

    func testChartLegendDefaultIsBottomPositionWithNilVisibility() {
        let legend = ChartLegend()
        XCTAssertNil(legend.isVisible)
        XCTAssertEqual(legend.position, .bottom)
    }

    // MARK: - ChartSpec (whole aggregate) round trip

    func testChartSpecEncodeDecodeIsIdentity() throws {
        let spec = ChartSpec(
            kind: .columnOrBar(orientation: .vertical, stacked: false),
            series: [
                ChartSeries(name: "Categories", role: .category, values: [], categoryLabels: ["A", "B", "C"]),
                ChartSeries(name: "Sales", role: .value, values: [10, 20, 30]),
            ],
            axes: ChartAxes(xTitle: "Category", yTitle: "Sales"),
            legend: ChartLegend(isVisible: true, position: .trailing),
            title: "Quarterly Sales"
        )
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(ChartSpec.self, from: data)
        XCTAssertEqual(decoded, spec)
    }

    func testChartSpecWithMinimalDefaultsEncodeDecodeIsIdentity() throws {
        let spec = ChartSpec(kind: .sparkline)
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(ChartSpec.self, from: data)
        XCTAssertEqual(decoded, spec)
        XCTAssertEqual(decoded.series, [])
        XCTAssertNil(decoded.title)
    }

    // MARK: - ChartSeriesRole vocabulary (independent oracle, rule 7)

    func testChartSeriesRoleHasExactlyTheSevenDocumentedRoles() {
        let expected: Set<String> = ["category", "value", "size", "open", "high", "low", "close"]
        XCTAssertEqual(Set(ChartSeriesRole.allCases.map(\.rawValue)), expected)
    }
}
