//===----------------------------------------------------------------------===//
//  ChartRenderer.swift
//  Tessera Studio
//
//  Pure function ChartSpec -> CGContext drawing commands - peer of
//  ShapeRenderer.swift the way ChartSpec is a peer of Shape.
//  CoreGraphics, not Swift Charts (architect decision, see
//  studio-expansion-plan.md's chart-engine entry).
//
//  One shared core (nice-number scales/ticks, category bands, legend
//  layout, palette, axis-label drawing) backs all twelve kinds - P1a's
//  `.columnOrBar`/`.line`/`.area`/`.pie`/`.scatter` and P1b's
//  `.bubble`/`.net`/`.stock`/`.columnAndLine`/`.ofPie`/`.sparkline`.
//  Each P1b kind is exactly one orthogonal mechanism layered on that
//  SAME core, per the gate's staging rationale: bubble adds a radius
//  scale to scatter's positioning, net adds a polar coordinate mapping
//  next to the linear one, stock adds OHLC glyphs, columnAndLine adds
//  a second independently-scaled axis, ofPie composes the existing
//  pie and column paths, sparkline is a chrome-suppressed preset of
//  the line path. None of them is a second rendering pipeline.
//===----------------------------------------------------------------------===//

import Foundation
import CoreGraphics
import CoreText

// MARK: - ChartNiceScale

/// A niced numeric axis scale: the "nice" `[min, max]` domain and the
/// step between ticks, computed once by ``ChartRenderer/ticks(min:max:targetCount:)``
/// and shared by tick-label drawing and gridline placement so both
/// agree on the same axis.
public struct ChartNiceScale: Sendable, Hashable {
    public let min: Double
    public let max: Double
    public let step: Double
    public let tickValues: [Double]

    public init(min: Double, max: Double, step: Double, tickValues: [Double]) {
        self.min = min
        self.max = max
        self.step = step
        self.tickValues = tickValues
    }
}

// MARK: - ChartRenderer

/// Stateless and side-effect-free, matching `ShapeRenderer`: every
/// chart renders independently into the context/rect it's given.
public struct ChartRenderer: Sendable {

    public init() {}

    private static let palette: [String] = [
        "#4C72B0", "#DD8452", "#55A868", "#C44E52",
        "#8172B2", "#937860", "#DA8BC3", "#8C8C8C",
    ]

    private static let axisLabelMargin: CGFloat = 44
    private static let categoryLabelMargin: CGFloat = 22

    // MARK: - Entry point

    /// Renders `spec` into `context`, confined to `rect`. Draws the
    /// title, then an auto-legend when `spec.legend.isVisible` is `nil`
    /// and `spec.series.count > 1` (the gate's own defaults rule), then
    /// dispatches to the kind that matches `spec.kind`.
    ///
    /// `.sparkline` is the one exception to that title/legend chrome:
    /// per its own doc comment it is a chrome-free preset, so both
    /// steps are skipped for it regardless of what `spec.title`/
    /// `spec.legend` say, and `renderSparkline` gets the full `rect`
    /// rather than a chrome-carved `area`.
    public func render(_ spec: ChartSpec, in context: CGContext, rect: CGRect) {
        context.saveGState()
        defer { context.restoreGState() }
        guard rect.width > 2, rect.height > 2 else { return }

        let isSparkline: Bool
        if case .sparkline = spec.kind { isSparkline = true } else { isSparkline = false }

        var area = rect
        if !isSparkline, let title = spec.title, !title.isEmpty {
            let titleRect = CGRect(x: area.minX, y: area.minY, width: area.width, height: 20)
            drawText(title, in: titleRect, fontSize: 14, colorHex: "#1A1A1A", alignment: .center, context: context)
            area.origin.y += 22
            area.size.height -= 22
        }

        let valueSeries = spec.series.filter { $0.role == .value }
        // Visibility follows the spec's own field doc literally
        // ("series.count > 1", not "plotted-series.count > 1"); the
        // legend's CONTENT below only ever lists what actually got
        // plotted.
        let legendVisible = !isSparkline && (spec.legend.isVisible ?? (spec.series.count > 1))
        if legendVisible {
            let items = legendItems(for: spec, valueSeries: valueSeries)
            if !items.isEmpty {
                area = layoutLegend(items, position: spec.legend.position, in: context, rect: area)
            }
        }
        guard area.width > 2, area.height > 2 else { return }

        switch spec.kind {
        case .columnOrBar(let orientation, let stacked):
            renderColumnOrBar(spec, valueSeries: valueSeries, orientation: orientation, stacked: stacked, in: context, rect: area)
        case .line:
            renderLine(spec, valueSeries: valueSeries, in: context, rect: area)
        case .area(let stacked):
            renderAreaKind(spec, valueSeries: valueSeries, stacked: stacked, in: context, rect: area)
        case .pie(let donut):
            renderPie(spec, valueSeries: valueSeries, donut: donut, in: context, rect: area)
        case .scatter:
            renderScatter(spec, valueSeries: valueSeries, in: context, rect: area)
        case .bubble:
            renderBubble(spec, valueSeries: valueSeries, in: context, rect: area)
        case .net:
            renderNet(spec, valueSeries: valueSeries, in: context, rect: area)
        case .stock(let variant):
            renderStock(spec, variant: variant, in: context, rect: area)
        case .columnAndLine:
            renderColumnAndLine(spec, valueSeries: valueSeries, in: context, rect: area)
        case .ofPie:
            renderOfPie(spec, valueSeries: valueSeries, in: context, rect: area)
        case .sparkline:
            // isSparkline suppressed all chrome above, so area == rect.
            renderSparkline(valueSeries: valueSeries, in: context, rect: area)
        }
    }

    // MARK: - Nice numbers / ticks

    /// D3-style "nice numbers": given a data domain and a target tick
    /// count, picks a step from the 1-2-5-per-decade family (1, 2, 5,
    /// 10, 20, 50, 100, ...) that is the smallest step whose ticks
    /// cover the domain in at most `targetCount` intervals, then
    /// expands `[min, max]` outward to whole multiples of that step
    /// (Heckbert's "Nice Numbers for Graph Labels"). Pure - no
    /// dependency on a `CGContext` or `ChartSpec` - so it is unit
    /// testable against hand-computed fixtures without rendering
    /// anything. `min == max` (a single-value or empty series) is not
    /// an error: it degrades to a fixed +/-1 pad so every downstream
    /// division stays zero-free without callers special-casing it.
    public static func ticks(min: Double, max: Double, targetCount: Int = 5) -> ChartNiceScale {
        let count = Swift.max(targetCount, 1)
        let lo = Swift.min(min, max)
        let hi = Swift.max(min, max)

        guard hi > lo else {
            return ChartNiceScale(min: lo - 1, max: lo + 1, step: 1, tickValues: [lo - 1, lo, lo + 1])
        }

        let range = hi - lo
        let rawStep = range / Double(count)
        let magnitude = pow(10, floor(log10(rawStep)))
        let fraction = rawStep / magnitude  // always in [1, 10)

        let niceFraction: Double
        if fraction <= 1 { niceFraction = 1 }
        else if fraction <= 2 { niceFraction = 2 }
        else if fraction <= 5 { niceFraction = 5 }
        else { niceFraction = 10 }
        let step = niceFraction * magnitude

        // Guard against float drift landing just off an exact multiple
        // of `step` (e.g. `hi / step` producing 4.999999999999999 for a
        // domain edge that is mathematically exactly 5): nudge TOWARD
        // the rounding direction each bound already wants, not away
        // from it - floor(lo/step) wants to round DOWN, so a value that
        // drifted slightly below its true integer needs a nudge UP
        // before flooring; ceil(hi/step) wants to round UP, so a value
        // that drifted slightly above its true integer needs a nudge
        // DOWN before ceiling.
        let epsilon = step * 1e-9
        let niceMin = ((lo / step) + epsilon).rounded(.down) * step
        let niceMax = ((hi / step) - epsilon).rounded(.up) * step

        var values: [Double] = []
        var v = niceMin
        while v <= niceMax + epsilon {
            // Snap to a clean multiple of `step` - kills the binary-
            // float drift that plain repeated addition (0.1 + 0.2 ...)
            // would otherwise accumulate over many ticks.
            values.append((v / step).rounded() * step)
            v += step
        }
        return ChartNiceScale(min: niceMin, max: niceMax, step: step, tickValues: values)
    }

    // MARK: - Column / Bar (the .columnOrBar unification)

    /// Shared by both orientations: one data walk (with stacking
    /// accumulation) computes each bar's (band, offset, value-start,
    /// value-end); only the final `barRect` closure differs between
    /// vertical (value axis = Y) and horizontal (value axis = X) - the
    /// duplication the gate's own reconciliation note asked to avoid
    /// by unifying column/bar into one case with an orientation flag.
    private func renderColumnOrBar(
        _ spec: ChartSpec, valueSeries: [ChartSeries], orientation: ChartOrientation, stacked: Bool,
        in context: CGContext, rect: CGRect
    ) {
        guard !valueSeries.isEmpty else { return }
        let count = valueSeries.map(\.values.count).max() ?? 0
        guard count > 0 else { return }
        let plot = axisInsetPlotArea(rect)
        guard plot.width > 1, plot.height > 1 else { return }

        let labels = categoryLabels(for: spec, count: count)
        let domain = valueDomain(valueSeries: valueSeries, stacked: stacked, includeZero: true)
        let scale = Self.ticks(min: domain.min, max: domain.max, targetCount: 5)
        drawValueAxisTicks(scale, orientation: orientation, formatCode: axisFormatCode(spec.axes, orientation: orientation), context: context, plot: plot)
        drawCategoryLabels(labels, orientation: orientation, context: context, plot: plot)

        let bandLength = orientation == .vertical ? plot.width / CGFloat(count) : plot.height / CGFloat(count)
        let seriesSlots = stacked ? 1 : Swift.max(valueSeries.count, 1)
        let barThickness = (bandLength * 0.7) / CGFloat(seriesSlots)

        func barRect(bandIndex: Int, offset: CGFloat, valueStart: Double, valueEnd: Double) -> CGRect {
            let bandOrigin = bandLength * 0.15 + offset
            switch orientation {
            case .vertical:
                let x = plot.minX + CGFloat(bandIndex) * bandLength + bandOrigin
                let y0 = valueToY(valueStart, scale: scale, plot: plot)
                let y1 = valueToY(valueEnd, scale: scale, plot: plot)
                return CGRect(x: x, y: Swift.min(y0, y1), width: barThickness, height: Swift.max(abs(y1 - y0), 0.5))
            case .horizontal:
                let y = plot.minY + CGFloat(bandIndex) * bandLength + bandOrigin
                let x0 = valueToX(valueStart, scale: scale, plot: plot)
                let x1 = valueToX(valueEnd, scale: scale, plot: plot)
                return CGRect(x: Swift.min(x0, x1), y: y, width: Swift.max(abs(x1 - x0), 0.5), height: barThickness)
            }
        }

        var positiveCumulative = [Double](repeating: 0, count: count)
        var negativeCumulative = [Double](repeating: 0, count: count)
        for (seriesIndex, series) in valueSeries.enumerated() {
            context.setFillColor(Self.color(forIndex: seriesIndex))
            for i in 0..<Swift.min(count, series.values.count) {
                let value = series.values[i]
                let start: Double
                let end: Double
                if stacked {
                    if value >= 0 {
                        start = positiveCumulative[i]
                        positiveCumulative[i] += value
                        end = positiveCumulative[i]
                    } else {
                        end = negativeCumulative[i]
                        negativeCumulative[i] += value
                        start = negativeCumulative[i]
                    }
                } else {
                    start = 0
                    end = value
                }
                let offset = stacked ? 0 : CGFloat(seriesIndex) * barThickness
                context.fill(barRect(bandIndex: i, offset: offset, valueStart: start, valueEnd: end))
            }
        }
    }

    // MARK: - Line

    private func renderLine(_ spec: ChartSpec, valueSeries: [ChartSeries], in context: CGContext, rect: CGRect) {
        guard !valueSeries.isEmpty else { return }
        let count = valueSeries.map(\.values.count).max() ?? 0
        guard count > 0 else { return }
        let plot = axisInsetPlotArea(rect)
        guard plot.width > 1, plot.height > 1 else { return }

        let labels = categoryLabels(for: spec, count: count)
        // Unlike the bar family, a line chart does not force a zero
        // baseline - LO/Excel both auto-scale a line's Y axis to the
        // data range, not to [0, max].
        let domain = valueDomain(valueSeries: valueSeries, stacked: false, includeZero: false)
        let scale = Self.ticks(min: domain.min, max: domain.max, targetCount: 5)
        drawValueAxisTicks(scale, orientation: .vertical, formatCode: axisFormatCode(spec.axes, orientation: .vertical), context: context, plot: plot)
        drawCategoryLabels(labels, orientation: .vertical, context: context, plot: plot)

        for (seriesIndex, series) in valueSeries.enumerated() {
            drawLinePath(series.values, count: count, scale: scale, plot: plot, color: Self.color(forIndex: seriesIndex), lineWidth: 2, context: context)
        }
    }

    /// One series' polyline, y-mapped through `scale`, x-banded by
    /// `count` the same way `renderLine` bands its categories. Shared
    /// by `renderLine`, `renderColumnAndLine`'s line group, and
    /// `renderSparkline` - the P1b sparkline kind's own contract is
    /// literally "reuse the line drawing code", not a second path.
    private func drawLinePath(_ values: [Double], count: Int, scale: ChartNiceScale, plot: CGRect, color: CGColor, lineWidth: CGFloat, context: CGContext) {
        guard !values.isEmpty else { return }
        let path = CGMutablePath()
        for i in 0..<Swift.min(count, values.count) {
            let point = CGPoint(x: categoryCenter(index: i, count: count, plot: plot), y: valueToY(values[i], scale: scale, plot: plot))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.addPath(path)
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.strokePath()
    }

    // MARK: - Area

    private func renderAreaKind(_ spec: ChartSpec, valueSeries: [ChartSeries], stacked: Bool, in context: CGContext, rect: CGRect) {
        guard !valueSeries.isEmpty else { return }
        let count = valueSeries.map(\.values.count).max() ?? 0
        guard count > 0 else { return }
        let plot = axisInsetPlotArea(rect)
        guard plot.width > 1, plot.height > 1 else { return }

        let labels = categoryLabels(for: spec, count: count)
        let domain = valueDomain(valueSeries: valueSeries, stacked: stacked, includeZero: true)
        let scale = Self.ticks(min: domain.min, max: domain.max, targetCount: 5)
        drawValueAxisTicks(scale, orientation: .vertical, formatCode: axisFormatCode(spec.axes, orientation: .vertical), context: context, plot: plot)
        drawCategoryLabels(labels, orientation: .vertical, context: context, plot: plot)

        var baselineCumulative = [Double](repeating: 0, count: count)
        for (seriesIndex, series) in valueSeries.enumerated() {
            guard !series.values.isEmpty else { continue }
            var topPoints: [CGPoint] = []
            var bottomPoints: [CGPoint] = []
            for i in 0..<Swift.min(count, series.values.count) {
                let x = categoryCenter(index: i, count: count, plot: plot)
                let base = stacked ? baselineCumulative[i] : 0
                let top = base + series.values[i]
                if stacked { baselineCumulative[i] = top }
                topPoints.append(CGPoint(x: x, y: valueToY(top, scale: scale, plot: plot)))
                bottomPoints.append(CGPoint(x: x, y: valueToY(base, scale: scale, plot: plot)))
            }
            guard let first = topPoints.first else { continue }
            let path = CGMutablePath()
            path.move(to: first)
            topPoints.dropFirst().forEach { path.addLine(to: $0) }
            bottomPoints.reversed().forEach { path.addLine(to: $0) }
            path.closeSubpath()

            let color = Self.color(forIndex: seriesIndex)
            context.addPath(path)
            context.setFillColor(color.copy(alpha: 0.55) ?? color)
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(color)
            context.setLineWidth(1.5)
            context.strokePath()
        }
    }

    // MARK: - Pie / Donut

    private func renderPie(_ spec: ChartSpec, valueSeries: [ChartSeries], donut: Bool, in context: CGContext, rect: CGRect) {
        // A pie plots exactly one ring: the first .value series' values
        // are the slice magnitudes. Additional .value series are
        // ignored here (a real "second ring" is the P1b .ofPie kind,
        // not something this kind silently grows into).
        guard let series = valueSeries.first, !series.values.isEmpty else { return }
        let values = series.values.map { Swift.max($0, 0) }
        let total = values.reduce(0, +)
        guard total > 0 else { return }

        let diameter = Swift.min(rect.width, rect.height) * 0.85
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = diameter / 2
        let innerRadius = donut ? outerRadius * 0.55 : 0

        var startAngle = -Double.pi / 2  // 12 o'clock, matching every office chart's pie start.
        for (index, value) in values.enumerated() {
            let sweep = (value / total) * 2 * Double.pi
            let endAngle = startAngle + sweep
            let path = CGMutablePath()
            if innerRadius > 0 {
                path.addArc(center: center, radius: outerRadius, startAngle: CGFloat(startAngle), endAngle: CGFloat(endAngle), clockwise: false)
                path.addArc(center: center, radius: innerRadius, startAngle: CGFloat(endAngle), endAngle: CGFloat(startAngle), clockwise: true)
                path.closeSubpath()
            } else {
                path.move(to: center)
                path.addArc(center: center, radius: outerRadius, startAngle: CGFloat(startAngle), endAngle: CGFloat(endAngle), clockwise: false)
                path.closeSubpath()
            }
            context.addPath(path)
            context.setFillColor(Self.color(forIndex: index))
            context.fillPath()
            startAngle = endAngle
        }
    }

    // MARK: - Scatter

    private func renderScatter(_ spec: ChartSpec, valueSeries: [ChartSeries], in context: CGContext, rect: CGRect) {
        guard !valueSeries.isEmpty else { return }
        let plot = axisInsetPlotArea(rect)
        guard plot.width > 1, plot.height > 1 else { return }

        let xValues = scatterXValues(spec, valueSeries: valueSeries)
        guard !xValues.isEmpty else { return }

        let xScale = Self.ticks(min: xValues.min() ?? 0, max: xValues.max() ?? 1, targetCount: 5)
        let yDomain = valueDomain(valueSeries: valueSeries, stacked: false, includeZero: false)
        let yScale = Self.ticks(min: yDomain.min, max: yDomain.max, targetCount: 5)

        drawValueAxisTicks(yScale, orientation: .vertical, formatCode: axisFormatCode(spec.axes, orientation: .vertical), context: context, plot: plot)
        drawValueAxisTicks(xScale, orientation: .horizontal, formatCode: axisFormatCode(spec.axes, orientation: .horizontal), context: context, plot: plot)

        for (seriesIndex, series) in valueSeries.enumerated() {
            context.setFillColor(Self.color(forIndex: seriesIndex))
            for i in 0..<Swift.min(xValues.count, series.values.count) {
                let x = valueToX(xValues[i], scale: xScale, plot: plot)
                let y = valueToY(series.values[i], scale: yScale, plot: plot)
                context.fillEllipse(in: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
            }
        }
    }

    /// A `.category`-role series (when present) supplies the shared X
    /// values for every `.value` series - the XY-scatter convention
    /// (one X column, N Y columns). Absent one, points fall back to
    /// their own index as X, which still renders a sane scatter for a
    /// spec that only supplies Y data. Shared by `renderScatter` and
    /// `renderBubble` - bubble's x/y positioning IS scatter's, per the
    /// gate's own "bubble reuses scatter's core" framing.
    private func scatterXValues(_ spec: ChartSpec, valueSeries: [ChartSeries]) -> [Double] {
        let categorySeries = spec.series.first { $0.role == .category }
        if let categorySeries, !categorySeries.values.isEmpty {
            return categorySeries.values
        }
        let count = valueSeries.map(\.values.count).max() ?? 0
        return (0..<count).map(Double.init)
    }

    // MARK: - Bubble

    /// Scatter's own x/y positioning (`scatterXValues`, the same
    /// helper `renderScatter` uses) plus a third dimension: the first
    /// `.size`-role series maps to marker radius via `bubbleRadius`.
    /// No size series, or a size series with a zero/negative max,
    /// falls back to a fixed dot - the bubble degrades to a plain
    /// scatter rather than drawing invisible zero-radius circles.
    private func renderBubble(_ spec: ChartSpec, valueSeries: [ChartSeries], in context: CGContext, rect: CGRect) {
        guard !valueSeries.isEmpty else { return }
        let plot = axisInsetPlotArea(rect)
        guard plot.width > 1, plot.height > 1 else { return }

        let xValues = scatterXValues(spec, valueSeries: valueSeries)
        guard !xValues.isEmpty else { return }

        let sizeSeries = spec.series.first { $0.role == .size }
        let sizeMax = sizeSeries?.values.reduce(0) { Swift.max($0, $1) } ?? 0

        let xScale = Self.ticks(min: xValues.min() ?? 0, max: xValues.max() ?? 1, targetCount: 5)
        let yDomain = valueDomain(valueSeries: valueSeries, stacked: false, includeZero: false)
        let yScale = Self.ticks(min: yDomain.min, max: yDomain.max, targetCount: 5)

        drawValueAxisTicks(yScale, orientation: .vertical, formatCode: axisFormatCode(spec.axes, orientation: .vertical), context: context, plot: plot)
        drawValueAxisTicks(xScale, orientation: .horizontal, formatCode: axisFormatCode(spec.axes, orientation: .horizontal), context: context, plot: plot)

        for (seriesIndex, series) in valueSeries.enumerated() {
            let color = Self.color(forIndex: seriesIndex)
            for i in 0..<Swift.min(xValues.count, series.values.count) {
                let x = valueToX(xValues[i], scale: xScale, plot: plot)
                let y = valueToY(series.values[i], scale: yScale, plot: plot)
                let radius: CGFloat
                if let sizeSeries, i < sizeSeries.values.count, sizeMax > 0 {
                    radius = Self.bubbleRadius(sizeSeries.values[i], maxValue: sizeMax)
                } else {
                    radius = 5
                }
                let bubbleRect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                context.setFillColor(color.copy(alpha: 0.6) ?? color)
                context.fillEllipse(in: bubbleRect)
                context.setStrokeColor(color)
                context.setLineWidth(1)
                context.strokeEllipse(in: bubbleRect)
            }
        }
    }

    /// Sqrt-area bubble scale: radius is proportional to `sqrt(value)`,
    /// not `value` directly, so a bubble's AREA (not its diameter)
    /// scales linearly with the data value - the standard bubble-chart
    /// convention. `value <= 0` (including the whole-series-is-zero
    /// case `maxValue <= 0`) maps to a zero radius rather than a
    /// negative or divide-by-zero one.
    public static func bubbleRadius(_ value: Double, maxValue: Double, maxRadius: CGFloat = 20) -> CGFloat {
        guard maxValue > 0, value > 0 else { return 0 }
        let t = sqrt(Swift.min(value, maxValue) / maxValue)
        return maxRadius * CGFloat(t)
    }

    // MARK: - Net (radar/spider)

    /// A polar transform of the SAME category/value series model
    /// `renderLine`/`renderColumnOrBar` use: each category becomes an
    /// angular position via `netAngle`, each series becomes a closed
    /// polygon connecting its values' radial positions via `ticks`'
    /// SAME niced scale, just mapped to a radius instead of a y-pixel.
    /// Concentric rings at each tick value (rather than the linear
    /// gridlines `drawValueAxisTicks` draws) are this kind's own radial
    /// analogue of an axis - drawn inline here rather than folded into
    /// `drawValueAxisTicks`, since a ring is a category-gon, not a
    /// straight line, and that one shape doesn't earn a third
    /// orientation case in the shared axis drawer.
    private func renderNet(_ spec: ChartSpec, valueSeries: [ChartSeries], in context: CGContext, rect: CGRect) {
        guard !valueSeries.isEmpty else { return }
        let count = valueSeries.map(\.values.count).max() ?? 0
        guard count > 0 else { return }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let maxRadius = Swift.min(rect.width, rect.height) / 2 * 0.72
        guard maxRadius > 1 else { return }

        let domain = valueDomain(valueSeries: valueSeries, stacked: false, includeZero: true)
        let scale = Self.ticks(min: domain.min, max: domain.max, targetCount: 4)

        func point(angle: Double, radius: CGFloat) -> CGPoint {
            CGPoint(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius)
        }
        func radiusFor(_ value: Double) -> CGFloat {
            let t = (value - scale.min) / (scale.max - scale.min)
            return CGFloat(Swift.max(t, 0)) * maxRadius
        }

        context.setStrokeColor(CGColor(gray: 0.85, alpha: 1))
        context.setLineWidth(0.5)
        for tick in scale.tickValues where tick > scale.min {
            let ringRadius = radiusFor(tick)
            let ring = CGMutablePath()
            for i in 0...count {
                let p = point(angle: Self.netAngle(index: i % count, count: count), radius: ringRadius)
                if i == 0 { ring.move(to: p) } else { ring.addLine(to: p) }
            }
            context.addPath(ring)
            context.strokePath()
        }

        let labels = categoryLabels(for: spec, count: count)
        for i in 0..<count {
            let labelPoint = point(angle: Self.netAngle(index: i, count: count), radius: maxRadius + 12)
            drawText(labels[i], in: CGRect(x: labelPoint.x - 24, y: labelPoint.y - 6, width: 48, height: 12), fontSize: 9, colorHex: "#444444", alignment: .center, context: context)
        }

        for (seriesIndex, series) in valueSeries.enumerated() {
            guard !series.values.isEmpty else { continue }
            let path = CGMutablePath()
            for i in 0..<Swift.min(count, series.values.count) {
                let p = point(angle: Self.netAngle(index: i, count: count), radius: radiusFor(series.values[i]))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            context.addPath(path)
            context.setStrokeColor(Self.color(forIndex: seriesIndex))
            context.setLineWidth(2)
            context.strokePath()
        }
    }

    /// The angular position of category `index` of `count`, evenly
    /// spaced around a full circle starting at 12 o'clock (`-pi/2`,
    /// matching `renderPie`'s own start angle) and proceeding
    /// clockwise in screen space. `count <= 0` degrades to 12 o'clock
    /// rather than dividing by zero.
    public static func netAngle(index: Int, count: Int) -> Double {
        guard count > 0 else { return -Double.pi / 2 }
        return -Double.pi / 2 + (2 * Double.pi * Double(index) / Double(count))
    }

    // MARK: - Stock (OHLC)

    /// OHLC glyphs: a vertical high-low range line, with a left tick
    /// for open (only on the two OHLC variants - HLC has no open data
    /// to tick) and a right tick for close (every variant). The two
    /// volume variants render this SAME glyph, omitting only the
    /// volume sub-plot a real Excel/LO volume-stock chart would add
    /// beneath it - a deliberate, documented simplification (see
    /// ``ChartStockVariant``'s own doc comment), not a silent gap.
    private func renderStock(_ spec: ChartSpec, variant: ChartStockVariant, in context: CGContext, rect: CGRect) {
        guard let highSeries = spec.series.first(where: { $0.role == .high }),
              let lowSeries = spec.series.first(where: { $0.role == .low }),
              !highSeries.values.isEmpty, !lowSeries.values.isEmpty
        else { return }
        let closeSeries = spec.series.first { $0.role == .close }
        let openSeries = spec.series.first { $0.role == .open }

        let count = Swift.min(highSeries.values.count, lowSeries.values.count)
        guard count > 0 else { return }
        let plot = axisInsetPlotArea(rect)
        guard plot.width > 1, plot.height > 1 else { return }

        var domainValues = Array(highSeries.values.prefix(count)) + Array(lowSeries.values.prefix(count))
        if let closeSeries { domainValues += closeSeries.values }
        if let openSeries { domainValues += openSeries.values }
        let scale = Self.ticks(min: domainValues.min() ?? 0, max: domainValues.max() ?? 1, targetCount: 5)

        let labels = categoryLabels(for: spec, count: count)
        drawValueAxisTicks(scale, orientation: .vertical, formatCode: axisFormatCode(spec.axes, orientation: .vertical), context: context, plot: plot)
        drawCategoryLabels(labels, orientation: .vertical, context: context, plot: plot)

        let showsOpenTick = variant == .openHighLowClose || variant == .volumeOpenHighLowClose
        let bandLength = plot.width / CGFloat(count)
        let tickLength = Swift.min(bandLength * 0.35, 8)

        context.setStrokeColor(Self.color(forIndex: 0))
        context.setLineWidth(1.5)
        for i in 0..<count {
            let x = categoryCenter(index: i, count: count, plot: plot)
            context.move(to: CGPoint(x: x, y: valueToY(highSeries.values[i], scale: scale, plot: plot)))
            context.addLine(to: CGPoint(x: x, y: valueToY(lowSeries.values[i], scale: scale, plot: plot)))
            if showsOpenTick, let openSeries, i < openSeries.values.count {
                let y = valueToY(openSeries.values[i], scale: scale, plot: plot)
                context.move(to: CGPoint(x: x - tickLength, y: y))
                context.addLine(to: CGPoint(x: x, y: y))
            }
            if let closeSeries, i < closeSeries.values.count {
                let y = valueToY(closeSeries.values[i], scale: scale, plot: plot)
                context.move(to: CGPoint(x: x, y: y))
                context.addLine(to: CGPoint(x: x + tickLength, y: y))
            }
        }
        context.strokePath()
    }

    // MARK: - Column and Line

    /// Two series groups sharing the category axis, split by
    /// `ChartSeries.usesSecondaryAxis`: the "not set" group renders as
    /// zero-baselined columns against the primary axis (this kind's
    /// own inline column-drawing, not `renderColumnOrBar` - that
    /// method's stacking/orientation machinery is more than a single
    /// unstacked-vertical column group needs here), the "set" group
    /// renders as a line against an independently-scaled secondary
    /// axis via the SAME `drawLinePath` `renderLine` uses. Both groups
    /// share one `plot` rect and one category-band layout - the
    /// "sharing the category axis" part of the kind's own name.
    private func renderColumnAndLine(_ spec: ChartSpec, valueSeries: [ChartSeries], in context: CGContext, rect: CGRect) {
        guard !valueSeries.isEmpty else { return }
        let count = valueSeries.map(\.values.count).max() ?? 0
        guard count > 0 else { return }

        let columnSeries = valueSeries.filter { !($0.usesSecondaryAxis ?? false) }
        let lineSeries = valueSeries.filter { $0.usesSecondaryAxis ?? false }
        let hasSecondary = !lineSeries.isEmpty

        let rightMargin: CGFloat = hasSecondary ? Self.axisLabelMargin : 8
        let plot = CGRect(
            x: rect.minX + Self.axisLabelMargin,
            y: rect.minY + 4,
            width: Swift.max(rect.width - Self.axisLabelMargin - rightMargin, 0),
            height: Swift.max(rect.height - Self.categoryLabelMargin - 4, 0)
        )
        guard plot.width > 1, plot.height > 1 else { return }

        let labels = categoryLabels(for: spec, count: count)
        drawCategoryLabels(labels, orientation: .vertical, context: context, plot: plot)

        if !columnSeries.isEmpty {
            let primaryDomain = valueDomain(valueSeries: columnSeries, stacked: false, includeZero: true)
            let primaryScale = Self.ticks(min: primaryDomain.min, max: primaryDomain.max, targetCount: 5)
            drawValueAxisTicks(primaryScale, orientation: .vertical, formatCode: spec.axes.yLabelFormat, context: context, plot: plot)

            let bandLength = plot.width / CGFloat(count)
            let barThickness = (bandLength * 0.6) / CGFloat(columnSeries.count)
            for (seriesIndex, series) in columnSeries.enumerated() {
                context.setFillColor(Self.color(forIndex: seriesIndex))
                for i in 0..<Swift.min(count, series.values.count) {
                    let x = plot.minX + CGFloat(i) * bandLength + bandLength * 0.2 + CGFloat(seriesIndex) * barThickness
                    let y0 = valueToY(0, scale: primaryScale, plot: plot)
                    let y1 = valueToY(series.values[i], scale: primaryScale, plot: plot)
                    context.fill(CGRect(x: x, y: Swift.min(y0, y1), width: barThickness, height: Swift.max(abs(y1 - y0), 0.5)))
                }
            }
        }

        if hasSecondary {
            let secondaryDomain = valueDomain(valueSeries: lineSeries, stacked: false, includeZero: false)
            let secondaryScale = Self.ticks(min: secondaryDomain.min, max: secondaryDomain.max, targetCount: 5)
            drawSecondaryValueAxisTicks(secondaryScale, formatCode: spec.axes.ySecondaryLabelFormat, context: context, plot: plot)
            for (seriesIndex, series) in lineSeries.enumerated() {
                drawLinePath(series.values, count: count, scale: secondaryScale, plot: plot, color: Self.color(forIndex: columnSeries.count + seriesIndex), lineWidth: 2, context: context)
            }
        }
    }

    /// The secondary y-axis's tick labels, drawn on the RIGHT edge of
    /// `plot` (mirroring `drawValueAxisTicks`'s vertical-orientation
    /// labels, which draw on the left) - no gridlines, so a chart with
    /// both axes doesn't double up on horizontal lines at two
    /// generally-different tick spacings.
    private func drawSecondaryValueAxisTicks(_ scale: ChartNiceScale, formatCode: String?, context: CGContext, plot: CGRect) {
        let format = formatCode.map(NumberFormatEngine.parse) ?? NumberFormat.general
        for tick in scale.tickValues {
            let y = valueToY(tick, scale: scale, plot: plot)
            let label = NumberFormatEngine.format(tick, using: format)
            drawText(label, in: CGRect(x: plot.maxX + 4, y: y - 6, width: 38, height: 12), fontSize: 9, colorHex: "#666666", alignment: .left, context: context)
        }
    }

    // MARK: - Of Pie

    /// A pie plus a detail breakout, composed from the two rendering
    /// paths that already exist rather than any new primitive drawing
    /// code: the main ring is a `renderPie` call restricted to the
    /// first `.value` series (matching `renderPie`'s own "only the
    /// first series plots" rule, so the detail series below never
    /// leaks into the main wedges), and the breakout is a
    /// `renderColumnOrBar` call over synthetic single-value series -
    /// one series per detail part, all sharing category-band 0, so its
    /// existing per-series stacking accumulation draws them as one
    /// stacked column. No second `.value` series -> falls back to a
    /// plain pie (the "of pie" mechanism is purely additive).
    private func renderOfPie(_ spec: ChartSpec, valueSeries: [ChartSeries], in context: CGContext, rect: CGRect) {
        guard let mainSeries = valueSeries.first, !mainSeries.values.isEmpty else { return }
        guard valueSeries.count > 1, let detailSeries = valueSeries.dropFirst().first, !detailSeries.values.isEmpty else {
            renderPie(spec, valueSeries: valueSeries, donut: false, in: context, rect: rect)
            return
        }

        let pieRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width * 0.55, height: rect.height)
        let detailRect = CGRect(x: rect.minX + rect.width * 0.6, y: rect.minY, width: rect.width * 0.4, height: rect.height)

        renderPie(spec, valueSeries: [mainSeries], donut: false, in: context, rect: pieRect)

        let parts = detailSeries.values.enumerated().map { index, value in
            ChartSeries(name: "Part \(index + 1)", role: .value, values: [value], categoryLabels: index == 0 ? ["Detail"] : nil)
        }
        let detailSpec = ChartSpec(kind: .columnOrBar(orientation: .vertical, stacked: true), series: parts, legend: ChartLegend(isVisible: false))
        renderColumnOrBar(detailSpec, valueSeries: parts, orientation: .vertical, stacked: true, in: context, rect: detailRect)
    }

    // MARK: - Sparkline

    /// Literally `drawLinePath` - the SAME per-series polyline drawing
    /// `renderLine` uses - with no axis ticks, gridlines, or category
    /// labels, and a 2pt inset instead of `axisInsetPlotArea`'s
    /// 44pt-margin plot area. "a cell-sized no-chrome preset of the
    /// SAME renderer" (gate's honest-reconciliation paragraph),
    /// verbatim: not a second drawing path, and the chrome suppression
    /// (title/legend) is handled one level up in `render` itself so
    /// this method never has to know about `spec.title`/`spec.legend`.
    private func renderSparkline(valueSeries: [ChartSeries], in context: CGContext, rect: CGRect) {
        guard !valueSeries.isEmpty else { return }
        let count = valueSeries.map(\.values.count).max() ?? 0
        guard count > 0 else { return }
        let plot = rect.insetBy(dx: 2, dy: 2)
        guard plot.width > 1, plot.height > 1 else { return }

        let domain = valueDomain(valueSeries: valueSeries, stacked: false, includeZero: false)
        let scale = Self.ticks(min: domain.min, max: domain.max, targetCount: 3)
        for (seriesIndex, series) in valueSeries.enumerated() {
            drawLinePath(series.values, count: count, scale: scale, plot: plot, color: Self.color(forIndex: seriesIndex), lineWidth: 1.25, context: context)
        }
    }

    // MARK: - Shared: scale coordinate mapping

    /// Vertical value axis: `plot.maxY` is the zero/baseline edge, y
    /// decreases upward as `value` increases - matching this
    /// codebase's documented origin-top-left, y-down convention
    /// (`ShapeGeometry`'s own doc comment).
    private func valueToY(_ value: Double, scale: ChartNiceScale, plot: CGRect) -> CGFloat {
        let t = (value - scale.min) / (scale.max - scale.min)
        return plot.maxY - CGFloat(t) * plot.height
    }

    /// Horizontal value axis (bar orientation, or scatter's X): value
    /// increases rightward from `plot.minX`.
    private func valueToX(_ value: Double, scale: ChartNiceScale, plot: CGRect) -> CGFloat {
        let t = (value - scale.min) / (scale.max - scale.min)
        return plot.minX + CGFloat(t) * plot.width
    }

    private func categoryCenter(index: Int, count: Int, plot: CGRect) -> CGFloat {
        guard count > 0 else { return plot.midX }
        let band = plot.width / CGFloat(count)
        return plot.minX + band * (CGFloat(index) + 0.5)
    }

    // MARK: - Shared: domain / category inference

    /// Resolves category-axis labels: the first series `categoryLabels`
    /// whose count matches `count` wins (role-agnostic - a `.category`-
    /// role series' own `values` are for scatter's X, but its
    /// `categoryLabels`, if any, are just as valid a label source as a
    /// `.value` series'). Falls back to 1-based numeric labels so every
    /// chart has SOME category label rather than an empty axis.
    private func categoryLabels(for spec: ChartSpec, count: Int) -> [String] {
        if let labels = spec.series.compactMap(\.categoryLabels).first(where: { $0.count == count }) {
            return labels
        }
        return (1...Swift.max(count, 1)).map(String.init)
    }

    /// `includeZero` forces the zero baseline into the domain (every
    /// bar/area chart's convention: a bar's length is measured FROM
    /// zero). Stacked domains always include zero regardless of the
    /// flag - a stack's own baseline is the definition of zero.
    private func valueDomain(valueSeries: [ChartSeries], stacked: Bool, includeZero: Bool) -> (min: Double, max: Double) {
        guard !valueSeries.isEmpty else { return (0, 1) }
        if stacked {
            let count = valueSeries.map(\.values.count).max() ?? 0
            guard count > 0 else { return (0, 1) }
            var positive = [Double](repeating: 0, count: count)
            var negative = [Double](repeating: 0, count: count)
            for series in valueSeries {
                for i in 0..<Swift.min(count, series.values.count) {
                    let v = series.values[i]
                    if v >= 0 { positive[i] += v } else { negative[i] += v }
                }
            }
            return (Swift.min(0, negative.min() ?? 0), Swift.max(0, positive.max() ?? 0))
        }
        let all = valueSeries.flatMap(\.values)
        guard !all.isEmpty else { return (0, 1) }
        var minV = all.min() ?? 0
        var maxV = all.max() ?? 0
        if includeZero {
            minV = Swift.min(minV, 0)
            maxV = Swift.max(maxV, 0)
        }
        if minV == maxV { maxV = minV + 1 }
        return (minV, maxV)
    }

    /// `orientation` here means "which physical axis holds the value
    /// data" (vertical => Y is the value axis; horizontal => X is) -
    /// the same meaning `drawValueAxisTicks` uses, so a bar chart's
    /// (horizontal) value axis correctly reads `xLabelFormat`.
    private func axisFormatCode(_ axes: ChartAxes, orientation: ChartOrientation) -> String? {
        orientation == .vertical ? axes.yLabelFormat : axes.xLabelFormat
    }

    // MARK: - Shared: axis drawing

    private func axisInsetPlotArea(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + Self.axisLabelMargin,
            y: rect.minY + 4,
            width: Swift.max(rect.width - Self.axisLabelMargin - 8, 0),
            height: Swift.max(rect.height - Self.categoryLabelMargin - 4, 0)
        )
    }

    private func drawValueAxisTicks(
        _ scale: ChartNiceScale, orientation: ChartOrientation, formatCode: String?,
        context: CGContext, plot: CGRect
    ) {
        let format = formatCode.map(NumberFormatEngine.parse) ?? NumberFormat.general
        for tick in scale.tickValues {
            let label = NumberFormatEngine.format(tick, using: format)
            context.setStrokeColor(CGColor(gray: 0.85, alpha: 1))
            context.setLineWidth(0.5)
            switch orientation {
            case .vertical:
                let y = valueToY(tick, scale: scale, plot: plot)
                context.move(to: CGPoint(x: plot.minX, y: y))
                context.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.strokePath()
                drawText(label, in: CGRect(x: plot.minX - 42, y: y - 6, width: 38, height: 12), fontSize: 9, colorHex: "#666666", alignment: .right, context: context)
            case .horizontal:
                let x = valueToX(tick, scale: scale, plot: plot)
                context.move(to: CGPoint(x: x, y: plot.minY))
                context.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.strokePath()
                drawText(label, in: CGRect(x: x - 20, y: plot.maxY + 4, width: 40, height: 12), fontSize: 9, colorHex: "#666666", alignment: .center, context: context)
            }
        }
    }

    private func drawCategoryLabels(_ labels: [String], orientation: ChartOrientation, context: CGContext, plot: CGRect) {
        let count = labels.count
        guard count > 0 else { return }
        switch orientation {
        case .vertical:
            let band = plot.width / CGFloat(count)
            for (i, label) in labels.enumerated() {
                let x = plot.minX + band * (CGFloat(i) + 0.5)
                drawText(label, in: CGRect(x: x - band / 2, y: plot.maxY + 4, width: band, height: 14), fontSize: 9, colorHex: "#444444", alignment: .center, context: context)
            }
        case .horizontal:
            let band = plot.height / CGFloat(count)
            for (i, label) in labels.enumerated() {
                let y = plot.minY + band * (CGFloat(i) + 0.5)
                drawText(label, in: CGRect(x: plot.minX - 42, y: y - 6, width: 38, height: 12), fontSize: 9, colorHex: "#444444", alignment: .right, context: context)
            }
        }
    }

    // MARK: - Shared: legend

    private struct LegendItem {
        let label: String
        let colorIndex: Int
    }

    /// Legend entries mirror what's actually visible: per-series for
    /// every kind except `.pie`, where the meaningful "series" a
    /// reader identifies by color is each SLICE, not the one value
    /// series that holds them all.
    private func legendItems(for spec: ChartSpec, valueSeries: [ChartSeries]) -> [LegendItem] {
        if case .pie = spec.kind, let series = valueSeries.first {
            let labels = categoryLabels(for: spec, count: series.values.count)
            return labels.enumerated().map { LegendItem(label: $0.element, colorIndex: $0.offset) }
        }
        return valueSeries.enumerated().map { index, series in
            LegendItem(label: series.name ?? "Series \(index + 1)", colorIndex: index)
        }
    }

    /// Draws the legend along `position`'s edge of `rect` and returns
    /// the remaining rect for the plot itself - the legend always
    /// carves out a fixed strip rather than sizing to its own content,
    /// keeping the plot area predictable regardless of series-name
    /// length.
    private func layoutLegend(_ items: [LegendItem], position: LegendPosition, in context: CGContext, rect: CGRect) -> CGRect {
        let stripSize: CGFloat = (position == .top || position == .bottom) ? 20 : 100
        let legendRect: CGRect
        let remaining: CGRect
        switch position {
        case .top:
            legendRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: stripSize)
            remaining = CGRect(x: rect.minX, y: rect.minY + stripSize, width: rect.width, height: rect.height - stripSize)
        case .bottom:
            legendRect = CGRect(x: rect.minX, y: rect.maxY - stripSize, width: rect.width, height: stripSize)
            remaining = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - stripSize)
        case .leading:
            legendRect = CGRect(x: rect.minX, y: rect.minY, width: stripSize, height: rect.height)
            remaining = CGRect(x: rect.minX + stripSize, y: rect.minY, width: rect.width - stripSize, height: rect.height)
        case .trailing:
            legendRect = CGRect(x: rect.maxX - stripSize, y: rect.minY, width: stripSize, height: rect.height)
            remaining = CGRect(x: rect.minX, y: rect.minY, width: rect.width - stripSize, height: rect.height)
        }

        let swatch: CGFloat = 10
        let rowHeight: CGFloat = 16
        for (index, item) in items.enumerated() {
            let swatchRect: CGRect
            let labelRect: CGRect
            if position == .top || position == .bottom {
                let itemWidth = legendRect.width / CGFloat(Swift.max(items.count, 1))
                let x = legendRect.minX + CGFloat(index) * itemWidth
                swatchRect = CGRect(x: x + 4, y: legendRect.minY + (stripSize - swatch) / 2, width: swatch, height: swatch)
                labelRect = CGRect(x: x + 4 + swatch + 4, y: legendRect.minY, width: Swift.max(itemWidth - swatch - 12, 0), height: stripSize)
            } else {
                let y = legendRect.minY + CGFloat(index) * rowHeight + 4
                swatchRect = CGRect(x: legendRect.minX + 4, y: y, width: swatch, height: swatch)
                labelRect = CGRect(x: legendRect.minX + 4 + swatch + 4, y: y - 3, width: Swift.max(legendRect.width - swatch - 12, 0), height: rowHeight)
            }
            context.setFillColor(Self.color(forIndex: item.colorIndex))
            context.fill(swatchRect)
            drawText(item.label, in: labelRect, fontSize: 9, colorHex: "#333333", alignment: .left, context: context)
        }

        return remaining
    }

    // MARK: - Shared: palette

    private static func color(forIndex index: Int) -> CGColor {
        parseHex(palette[index % palette.count]) ?? CGColor(gray: 0.5, alpha: 1)
    }

    /// `#RRGGBB` or `#RRGGBBAA`, matching `Shape`'s `colorHex`
    /// convention. A small local parser rather than reaching into
    /// `ShapeRenderer`'s own private one (different file, private
    /// access) - same ~15 lines that convention already accepts
    /// duplicating per renderer.
    private static func parseHex(_ hex: String) -> CGColor? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            return CGColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        }
        return CGColor(
            red: CGFloat((value >> 24) & 0xFF) / 255,
            green: CGFloat((value >> 16) & 0xFF) / 255,
            blue: CGFloat((value >> 8) & 0xFF) / 255,
            alpha: CGFloat(value & 0xFF) / 255
        )
    }

    // MARK: - Shared: text

    private enum ChartTextAlignment {
        case left, center, right
    }

    /// Draws one line of text via CoreText directly into `context`,
    /// vertically and horizontally centered on `rect` per `alignment`.
    /// `ShapeRenderer` punts on text entirely (shape-on-text belongs to
    /// `BlockRenderer`'s text-layout stack); a chart's axis/legend/
    /// title labels have no such stack to defer to, so this renderer
    /// owns a minimal CoreText path instead. The translate+flip below
    /// assumes the incoming context is already top-left-origin/y-down
    /// (this codebase's documented convention, see `ShapeGeometry`) -
    /// CoreText's own glyph space is y-up, so drawing it unflipped into
    /// a y-down context would render upside down.
    private func drawText(_ text: String, in rect: CGRect, fontSize: CGFloat, colorHex: String, alignment: ChartTextAlignment, context: CGContext) {
        guard rect.width > 1, rect.height > 1, !text.isEmpty else { return }
        let color = Self.parseHex(colorHex) ?? CGColor(gray: 0, alpha: 1)
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        guard bounds.width > 0 else { return }

        let originX: CGFloat
        switch alignment {
        case .left: originX = rect.minX
        case .center: originX = rect.minX + Swift.max((rect.width - bounds.width) / 2, 0)
        case .right: originX = rect.maxX - bounds.width
        }

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: originX - bounds.minX, y: rect.midY + bounds.height / 2 + bounds.minY)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
