import XCTest
import CoreGraphics
@testable import TesseraCore

/// Test contract (studio-expansion-design-refinement-2026-08-14.md
/// section 3, Gate 3): every (kind x stacking x variant) combination
/// among the 6 P1a kinds renders into an offscreen `CGContext` with no
/// fallback path (no crash, no silent no-op), and
/// `ChartRenderer.ticks(min:max:targetCount:)` yields 1-2-5 steps for
/// hand-computed domain/target-count fixtures. Black-box, same
/// approach as `ShapeRendererTests`: most assertions only need the
/// render call to complete; one pixel-content check (mirroring
/// `ShapeRendererTests.testFilledRectPaintsItsInteriorColor`) confirms
/// a chart isn't a silent no-op.
final class ChartRendererTests: XCTestCase {

    // MARK: - Fixtures

    private func makeContext(width: Int, height: Int) -> CGContext {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    private func pixel(_ context: CGContext, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = (y * context.bytesPerRow) + (x * 4)
        return (data[offset], data[offset + 1], data[offset + 2])
    }

    private func twoSeriesSpec(kind: ChartKind, title: String? = "Q1 Revenue") -> ChartSpec {
        ChartSpec(
            kind: kind,
            series: [
                ChartSeries(name: "North", role: .value, values: [10, 25, 15, 30], categoryLabels: ["Jan", "Feb", "Mar", "Apr"]),
                ChartSeries(name: "South", role: .value, values: [5, 12, 20, 8]),
            ],
            axes: ChartAxes(yLabelFormat: "#,##0", xTitle: "Month", yTitle: "Revenue"),
            title: title
        )
    }

    // MARK: - No-crash: every (kind x stacking x variant) among the 6 P1a kinds

    func testColumnVerticalUnstackedRenders() {
        let context = makeContext(width: 320, height: 220)
        ChartRenderer().render(twoSeriesSpec(kind: .columnOrBar(orientation: .vertical, stacked: false)), in: context, rect: CGRect(x: 0, y: 0, width: 320, height: 220))
    }

    func testColumnVerticalStackedRenders() {
        let context = makeContext(width: 320, height: 220)
        ChartRenderer().render(twoSeriesSpec(kind: .columnOrBar(orientation: .vertical, stacked: true)), in: context, rect: CGRect(x: 0, y: 0, width: 320, height: 220))
    }

    func testBarHorizontalUnstackedRenders() {
        let context = makeContext(width: 320, height: 220)
        ChartRenderer().render(twoSeriesSpec(kind: .columnOrBar(orientation: .horizontal, stacked: false)), in: context, rect: CGRect(x: 0, y: 0, width: 320, height: 220))
    }

    func testBarHorizontalStackedRenders() {
        let context = makeContext(width: 320, height: 220)
        ChartRenderer().render(twoSeriesSpec(kind: .columnOrBar(orientation: .horizontal, stacked: true)), in: context, rect: CGRect(x: 0, y: 0, width: 320, height: 220))
    }

    func testLineRenders() {
        let context = makeContext(width: 320, height: 220)
        ChartRenderer().render(twoSeriesSpec(kind: .line), in: context, rect: CGRect(x: 0, y: 0, width: 320, height: 220))
    }

    func testAreaUnstackedRenders() {
        let context = makeContext(width: 320, height: 220)
        ChartRenderer().render(twoSeriesSpec(kind: .area(stacked: false)), in: context, rect: CGRect(x: 0, y: 0, width: 320, height: 220))
    }

    func testAreaStackedRenders() {
        let context = makeContext(width: 320, height: 220)
        ChartRenderer().render(twoSeriesSpec(kind: .area(stacked: true)), in: context, rect: CGRect(x: 0, y: 0, width: 320, height: 220))
    }

    func testPieRenders() {
        let context = makeContext(width: 220, height: 220)
        let spec = ChartSpec(kind: .pie(donut: false), series: [ChartSeries(role: .value, values: [10, 20, 30, 40], categoryLabels: ["A", "B", "C", "D"])])
        ChartRenderer().render(spec, in: context, rect: CGRect(x: 0, y: 0, width: 220, height: 220))
    }

    func testDonutRenders() {
        let context = makeContext(width: 220, height: 220)
        let spec = ChartSpec(kind: .pie(donut: true), series: [ChartSeries(role: .value, values: [10, 20, 30, 40], categoryLabels: ["A", "B", "C", "D"])])
        ChartRenderer().render(spec, in: context, rect: CGRect(x: 0, y: 0, width: 220, height: 220))
    }

    func testScatterRenders() {
        let context = makeContext(width: 320, height: 220)
        let spec = ChartSpec(
            kind: .scatter,
            series: [
                ChartSeries(role: .category, values: [1, 2, 3, 4, 5]),
                ChartSeries(name: "Trial 1", role: .value, values: [2.1, 3.4, 2.8, 5.0, 4.2]),
            ]
        )
        ChartRenderer().render(spec, in: context, rect: CGRect(x: 0, y: 0, width: 320, height: 220))
    }

    func testScatterWithoutCategorySeriesFallsBackToIndexRenders() {
        let context = makeContext(width: 320, height: 220)
        let spec = ChartSpec(kind: .scatter, series: [ChartSeries(role: .value, values: [2.1, 3.4, 2.8, 5.0])])
        ChartRenderer().render(spec, in: context, rect: CGRect(x: 0, y: 0, width: 320, height: 220))
    }

    // MARK: - No-crash: P1b placeholder kinds

    func testEveryP1bKindRendersAnHonestPlaceholderInsteadOfCrashing() {
        let p1bKinds: [ChartKind] = [.bubble, .net, .stock, .columnAndLine, .ofPie, .sparkline]
        for kind in p1bKinds {
            let context = makeContext(width: 200, height: 150)
            ChartRenderer().render(twoSeriesSpec(kind: kind, title: nil), in: context, rect: CGRect(x: 0, y: 0, width: 200, height: 150))
        }
    }

    // MARK: - No-crash: edge inputs

    func testEmptySeriesDoesNotCrash() {
        let context = makeContext(width: 200, height: 150)
        let spec = ChartSpec(kind: .columnOrBar(orientation: .vertical, stacked: false), series: [])
        ChartRenderer().render(spec, in: context, rect: CGRect(x: 0, y: 0, width: 200, height: 150))
    }

    func testSingleValueDomainDoesNotCrash() {
        let context = makeContext(width: 200, height: 150)
        let spec = ChartSpec(kind: .line, series: [ChartSeries(role: .value, values: [7])])
        ChartRenderer().render(spec, in: context, rect: CGRect(x: 0, y: 0, width: 200, height: 150))
    }

    func testZeroSizeRectDoesNotCrash() {
        let context = makeContext(width: 10, height: 10)
        ChartRenderer().render(twoSeriesSpec(kind: .line), in: context, rect: .zero)
    }

    // MARK: - Content sanity (welcome, not required, per the test contract)

    func testColumnChartPaintsSomethingOtherThanTheBlankBackground() {
        let width = 300, height = 200
        let context = makeContext(width: width, height: height)
        let spec = ChartSpec(
            kind: .columnOrBar(orientation: .vertical, stacked: false),
            series: [ChartSeries(role: .value, values: [10, 20, 30], categoryLabels: ["Jan", "Feb", "Mar"])]
        )
        ChartRenderer().render(spec, in: context, rect: CGRect(x: 0, y: 0, width: width, height: height))

        var foundNonWhite = false
        outer: for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                let p = pixel(context, x: x, y: y)
                if p.r < 240 || p.g < 240 || p.b < 240 {
                    foundNonWhite = true
                    break outer
                }
            }
        }
        XCTAssertTrue(foundNonWhite, "a non-empty column chart must paint something - a blank canvas would mean a silent no-op")
    }

    // MARK: - ticks(): hand-computed 1-2-5 fixtures

    private func assertTicks(_ scale: ChartNiceScale, min: Double, max: Double, step: Double, values: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(scale.min, min, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(scale.max, max, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(scale.step, step, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(scale.tickValues.count, values.count, file: file, line: line)
        for (got, want) in zip(scale.tickValues, values) {
            XCTAssertEqual(got, want, accuracy: 1e-9, file: file, line: line)
        }
    }

    /// [0, 100], target 5: rawStep = 20, fraction = 2.0 -> the "2" rung
    /// of the 1-2-5 family, step = 20.
    func testTicksFixtureA_ZeroToHundred() {
        let scale = ChartRenderer.ticks(min: 0, max: 100, targetCount: 5)
        assertTicks(scale, min: 0, max: 100, step: 20, values: [0, 20, 40, 60, 80, 100])
    }

    /// [3, 27], target 5: rawStep = 4.8, fraction = 4.8 -> the "5" rung,
    /// step = 5; the niced domain expands past both raw bounds.
    func testTicksFixtureB_ThreeToTwentySeven() {
        let scale = ChartRenderer.ticks(min: 3, max: 27, targetCount: 5)
        assertTicks(scale, min: 0, max: 30, step: 5, values: [0, 5, 10, 15, 20, 25, 30])
    }

    /// [0, 1000], target 4: rawStep = 250, fraction = 2.5 -> the "5"
    /// rung (smallest of {1,2,5,10} >= 2.5), step = 500.
    func testTicksFixtureC_ZeroToThousandTargetFour() {
        let scale = ChartRenderer.ticks(min: 0, max: 1000, targetCount: 4)
        assertTicks(scale, min: 0, max: 1000, step: 500, values: [0, 500, 1000])
    }

    /// [-50, 50], target 5: symmetric negative/positive domain, same
    /// "2" rung as fixture A (fraction = 2.0), step = 20.
    func testTicksFixtureD_NegativeFiftyToFifty() {
        let scale = ChartRenderer.ticks(min: -50, max: 50, targetCount: 5)
        assertTicks(scale, min: -60, max: 60, step: 20, values: [-60, -40, -20, 0, 20, 40, 60])
    }

    func testTicksHandlesDegenerateDomainWithoutCrashing() {
        let scale = ChartRenderer.ticks(min: 5, max: 5, targetCount: 5)
        XCTAssertGreaterThan(scale.max, scale.min)
        XCTAssertFalse(scale.tickValues.isEmpty)
        XCTAssertTrue(scale.tickValues.contains(5))
    }

    func testTicksToleratesNonPositiveTargetCount() {
        let scale = ChartRenderer.ticks(min: 0, max: 10, targetCount: 0)
        XCTAssertGreaterThan(scale.max, scale.min)
        XCTAssertFalse(scale.tickValues.isEmpty)
    }
}
