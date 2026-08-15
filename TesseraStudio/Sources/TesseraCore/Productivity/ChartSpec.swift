//===----------------------------------------------------------------------===//
//  ChartSpec.swift
//  Tessera Studio
//
//  The chart data model - peer of Shape.swift, the way ChartRenderer is
//  a peer of ShapeRenderer. Series-typed (kind + series with roles +
//  axes + legend), OOXML/ODF-shaped, deliberately NOT a Vega-Lite
//  mark/encoding grammar: office chart XML is a series list, and a
//  grammar forces lossy inference in both round-trip directions
//  (design-refinement doc section 3, Gate 3). Only Vega-Lite's
//  DEFAULTS philosophy is adopted here - an incomplete spec still
//  renders sensibly; the inference itself lives in ``ChartRenderer``,
//  not this file, matching Shape/ShapeRenderer's own division of labor
//  (data model stays a plain value type, the renderer owns behavior).
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - ChartOrientation

/// Differentiates column (vertical bars) from bar (horizontal bars) -
/// per Gate 3's own reconciliation note ("Column/Bar: orientation
/// flag"), modeled as one axis flag on
/// ``ChartKind/columnOrBar(orientation:stacked:)`` rather than two
/// duplicate cases, so ``ChartRenderer`` walks a chart's data once and
/// only the final coordinate mapping (which physical axis is the value
/// axis) differs by orientation.
public enum ChartOrientation: String, Codable, Sendable, Hashable, CaseIterable {
    case vertical
    case horizontal
}

// MARK: - ChartKind

/// The chart type catalog. P1a implements full rendering for
/// `columnOrBar`, `line`, `area`, `pie`, `scatter` - the dominant
/// families, exercising the entire shared scale/tick/legend/palette
/// core (studio-expansion-design-refinement-2026-08-14.md section 3,
/// Gate 3 staging). P1b (this wave) adds `bubble`, `net`, `stock`,
/// `columnAndLine`, `ofPie`, `sparkline` - each one orthogonal
/// mechanism layered on that SAME unchanged core (a third numeric
/// role, a polar coordinate mapping, OHLC glyphs, a secondary axis, a
/// pie+column composition, a chromeless preset), per the gate's own
/// staging rationale. No new ``ChartRenderer`` architecture; see that
/// file's rendering methods for each mechanism.
public enum ChartKind: Codable, Sendable, Hashable {
    /// Column (vertical bars) or bar (horizontal bars) - see
    /// ``ChartOrientation``.
    case columnOrBar(orientation: ChartOrientation, stacked: Bool)
    case line
    case area(stacked: Bool)
    /// `donut: true` punches a hole in the center; the hole's radius
    /// ratio is ``ChartRenderer``'s presentation concern, not stored
    /// on the spec.
    case pie(donut: Bool)
    case scatter
    /// Scatter (x/y positioning) plus a third numeric dimension: the
    /// first ``ChartSeriesRole/size`` series maps to marker radius via
    /// ``ChartRenderer/bubbleRadius(_:maxValue:maxRadius:)``.
    case bubble
    /// Radar/spider chart: a polar transform of the same category/
    /// value series model - each category an angular position, each
    /// series a polygon connecting its values' radial positions. See
    /// ``ChartRenderer/netAngle(index:count:)``.
    case net
    /// OHLC chart; see ``ChartStockVariant`` for the 4 standard
    /// subtypes. Plots the ``ChartSeriesRole/high``/``ChartSeriesRole/low``/
    /// ``ChartSeriesRole/open``/``ChartSeriesRole/close`` series.
    case stock(variant: ChartStockVariant)
    /// Two series groups sharing the category axis: series with
    /// ``ChartSeries/usesSecondaryAxis`` unset/false render as columns
    /// against ``ChartAxes``' primary y-axis fields, series with it set
    /// render as a line against ``ChartAxes``'s secondary y-axis fields.
    case columnAndLine
    /// A pie plus a detail breakout: the second `.value` series (if
    /// present) is the composition of the first series' exploded
    /// wedge, drawn as a stacked-column detail chart alongside the
    /// main pie. No second series -> renders as a plain pie.
    case ofPie
    /// A cell-sized, chrome-free preset of the line renderer: no
    /// title, legend, axes, or category labels - see
    /// ``ChartRenderer/render(_:in:rect:)``'s early chrome-suppression
    /// check.
    case sparkline
}

// MARK: - ChartStockVariant

/// The 4 standard OOXML/ODF stock-chart subtypes. `.highLowClose` and
/// `.openHighLowClose` render real OHLC glyphs; the two volume variants
/// render the SAME price glyph as their non-volume counterpart without
/// a separate volume sub-plot - a deliberate, documented simplification
/// (P1b item's own report), not a silent gap.
public enum ChartStockVariant: String, Codable, Sendable, Hashable, CaseIterable {
    case highLowClose
    case openHighLowClose
    case volumeHighLowClose
    case volumeOpenHighLowClose
}

// MARK: - ChartSeriesRole

/// What a ``ChartSeries``' `values` represent. `.value` is the common
/// case (one plotted series). `.category` is reserved for a series
/// that supplies shared axis positions instead of its own plotted
/// magnitude - e.g. the shared X column of an XY scatter, consumed by
/// ``ChartRenderer`` rather than plotted itself. `.size` is the P1b
/// bubble kind's third dimension, mapped to marker radius. `.open`,
/// `.high`, `.low`, `.close` are the P1b stock kind's four OHLC
/// components - one series per component (matched to each other by
/// index), not one series per data point, keeping every kind's data
/// series-typed the same way.
public enum ChartSeriesRole: String, Codable, Sendable, Hashable, CaseIterable {
    case category
    case value
    case size
    case open
    case high
    case low
    case close
}

// MARK: - ChartSeries

public struct ChartSeries: Codable, Sendable, Hashable {
    public var name: String?
    public var role: ChartSeriesRole
    public var values: [Double]
    /// Per-value display labels (pie slice names, category-axis
    /// ticks). Matched to `values` by index; a mismatched count is
    /// ignored by ``ChartRenderer``, which falls back to numeric
    /// labels rather than mis-pairing a label with the wrong value.
    public var categoryLabels: [String]?
    /// `nil` (same as `false`) plots this series against the shared/
    /// primary value axis; `true` plots it against ``ChartAxes``'s
    /// secondary y-axis fields instead - `ChartLegend.isVisible`'s same
    /// "nil is the common case, no migration needed for old specs"
    /// idiom. Only ``ChartKind/columnAndLine`` consults this field:
    /// its two series groups ARE exactly "not `usesSecondaryAxis`"
    /// (columns) vs "`usesSecondaryAxis`" (line). Every other kind
    /// ignores it.
    public var usesSecondaryAxis: Bool?

    public init(
        name: String? = nil,
        role: ChartSeriesRole = .value,
        values: [Double] = [],
        categoryLabels: [String]? = nil,
        usesSecondaryAxis: Bool? = nil
    ) {
        self.name = name
        self.role = role
        self.values = values
        self.categoryLabels = categoryLabels
        self.usesSecondaryAxis = usesSecondaryAxis
    }
}

// MARK: - ChartAxes

/// Axis configuration. Every field is optional, and `nil` renders with
/// an inferred default (auto-scaled niced domain, plain numeric tick
/// labels, no title) - per the gate's defaults philosophy, an
/// incomplete spec still renders, not only a fully-populated one.
public struct ChartAxes: Codable, Sendable, Hashable {
    /// A ``NumberFormatEngine`` format code (e.g. `"#,##0.00"`),
    /// resolved via `NumberFormatEngine.format` at render time - not
    /// resolved or cached here, so the same stored spec re-renders
    /// correctly if the engine's locale changes.
    public var xLabelFormat: String?
    public var yLabelFormat: String?
    public var xTitle: String?
    public var yTitle: String?
    /// ``ChartKind/columnAndLine``'s secondary y-axis (its line group)
    /// - the same format/title split as the primary `yLabelFormat`/
    /// `yTitle` pair, just for the second independently-scaled axis.
    /// Ignored by every other kind.
    public var ySecondaryLabelFormat: String?
    public var ySecondaryTitle: String?

    public init(
        xLabelFormat: String? = nil,
        yLabelFormat: String? = nil,
        xTitle: String? = nil,
        yTitle: String? = nil,
        ySecondaryLabelFormat: String? = nil,
        ySecondaryTitle: String? = nil
    ) {
        self.xLabelFormat = xLabelFormat
        self.yLabelFormat = yLabelFormat
        self.xTitle = xTitle
        self.yTitle = yTitle
        self.ySecondaryLabelFormat = ySecondaryLabelFormat
        self.ySecondaryTitle = ySecondaryTitle
    }
}

// MARK: - LegendPosition

public enum LegendPosition: String, Codable, Sendable, Hashable, CaseIterable {
    case top
    case bottom
    case leading
    case trailing
}

// MARK: - ChartLegend

public struct ChartLegend: Codable, Sendable, Hashable {
    /// `nil` means "auto: shown when `series.count > 1`" (Vega-Lite's
    /// defaults philosophy, per the gate) - resolved by
    /// ``ChartRenderer``, not here, so the rule can't drift between
    /// two call sites.
    public var isVisible: Bool?
    public var position: LegendPosition

    public init(isVisible: Bool? = nil, position: LegendPosition = .bottom) {
        self.isVisible = isVisible
        self.position = position
    }
}

// MARK: - ChartSpec

/// One chart's full data + presentation spec - peer of ``Shape``, the
/// way a chart is a peer of a vector shape on the same Draw/Impress
/// canvas. Stored on a `.chart` block via `attributes["chart"]`; see
/// `Block.chart`.
public struct ChartSpec: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var kind: ChartKind
    public var series: [ChartSeries]
    public var axes: ChartAxes
    public var legend: ChartLegend
    public var title: String?

    public init(
        id: UUID = UUID(),
        kind: ChartKind,
        series: [ChartSeries] = [],
        axes: ChartAxes = ChartAxes(),
        legend: ChartLegend = ChartLegend(),
        title: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.series = series
        self.axes = axes
        self.legend = legend
        self.title = title
    }
}
