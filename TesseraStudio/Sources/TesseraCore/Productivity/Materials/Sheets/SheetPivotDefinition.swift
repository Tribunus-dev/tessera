import Foundation

// MARK: - SheetPivotAggregation

/// How a `.dataFields` entry rolls up multiple source rows into one
/// pivot cell. Grew from 9 to 12 cases at P2-A 2.2a (`.median`,
/// `.stdDevP`, `.varianceP` appended) - additive, existing raw values
/// unchanged, so persisted JSON using the original 9 still decodes.
public enum SheetPivotAggregation: String, Codable, Sendable, Hashable, CaseIterable {
    case sum
    case count
    case countNumbers
    case average
    case min
    case max
    case product
    case stdDev
    case variance
    /// The middle value of the sorted numeric set (P2-A 2.2a).
    case median
    /// Population standard deviation (divides by N, not N-1) - distinct
    /// from `.stdDev`, which is the sample statistic (P2-A 2.2a).
    case stdDevP
    /// Population variance (divides by N, not N-1) - distinct from
    /// `.variance`, the sample statistic (P2-A 2.2a).
    case varianceP
}

// MARK: - SheetPivotDataField

/// One value column summarized into the pivot's data area. This is the
/// LEGACY (pre-2.2a) shape, kept as the wire representation
/// `SheetPivotDefinition.dataFields` still reads and writes - see that
/// type's Codable extension for how it relates to the new
/// ``SheetPivotField`` model. Not used internally as storage anymore;
/// `SheetPivotField(orientation: .data)` is the source of truth.
public struct SheetPivotDataField: Codable, Sendable, Hashable {
    /// A source column header (`Sheet.columns`' `name`, not a
    /// spreadsheet letter) - pivots group by column identity, the way
    /// a user picks "Region" or "Revenue" from a field list, not by
    /// raw grid position.
    public var fieldName: String
    public var aggregation: SheetPivotAggregation

    public init(fieldName: String, aggregation: SheetPivotAggregation) {
        self.fieldName = fieldName
        self.aggregation = aggregation
    }
}

// MARK: - SheetPivotFieldOrientation

/// Which axis of the pivot a field belongs to - `ScDPObject` parity
/// name `DataPilotFieldOrientation`. `.hidden` is a field known to the
/// source range that currently sits in none of the four active axes
/// (the field-list "unused fields" bucket).
public enum SheetPivotFieldOrientation: String, Codable, Sendable, Hashable, CaseIterable {
    case row
    case column
    case page
    case data
    case hidden
}

// MARK: - SheetPivotFieldMember

/// One explicit member (distinct source value) of a field, carrying
/// its own visibility. Only currently consulted by
/// `PivotTableStore`'s page-filtering stage for a `.page`-oriented
/// field: a non-empty `members` list there is the "which value(s) are
/// selected" state, matching a LO/Excel page-field dropdown. For every
/// other orientation this is round-trip-only at P2a (present so P2b's
/// row/column member filter+order UI has a field to write into, not
/// yet read by the pipeline).
public struct SheetPivotFieldMember: Codable, Sendable, Hashable {
    /// The member's display text - compared against a cell's rendered
    /// text (`PivotTableStore`'s own `displayText(_:)`, mirroring
    /// `QueryEngine`'s `SheetFilterRowInput.displayText` convention),
    /// not `CellValue` structural equality, so a numeric field's
    /// member name ("2024") still matches a `.number(2024)` cell.
    public var name: String
    public var visible: Bool

    public init(name: String, visible: Bool = true) {
        self.name = name
        self.visible = visible
    }
}

// MARK: - SheetPivotFieldLayoutMode / SheetPivotFieldLayout

/// Row/column output layout - `ScDPObject` parity name
/// `DataPilotFieldLayoutInfo`'s layout mode. `.outline`/`.compact` are
/// P2b additions (`PivotTableStore`'s pipeline, see its own doc
/// comment for exactly what each mode changes), appended the same
/// additive way `SheetPivotAggregation` grew from 9 to 12 cases - never
/// a `_v2` enum swap. Existing `.tabular` raw value unchanged, so a
/// P2a-written `layout` keeps decoding identically.
public enum SheetPivotFieldLayoutMode: String, Codable, Sendable, Hashable, CaseIterable {
    case tabular
    /// Per-field subtotal rows (`subtotals`/`subtotalAuto`) are live -
    /// see `PivotTableStore`'s subtotal-insertion pass. Row-header
    /// columns stay one-per-level, same as `.tabular`.
    case outline
    /// Same subtotal-row behavior as `.outline`, PLUS - when the
    /// OUTERMOST row field carries this mode - every row-field level
    /// collapses into a single indented "Row Labels" column
    /// (`PivotResultGrid.headerColumnCount == 1`). See
    /// `PivotTableStore`'s doc comment for the exact scope call: a
    /// table-wide effective mode read off `rowFields.first`, not a
    /// per-level collapse (mixing collapsed and per-level columns
    /// within one grid has no coherent rendering).
    case compact
}

/// Per-field layout knobs. `PivotTableStore`'s P2a pipeline always
/// built `.tabular` output regardless of `mode`; P2b's pipeline reads
/// `mode` for real (see ``SheetPivotFieldLayoutMode``'s doc comment) -
/// `addEmptyLine` remains round-trip-only (no rendering concept for a
/// blank spacer row exists yet); `subtotalsAtTop` is live wherever
/// subtotal-row insertion is (mode != `.tabular`).
public struct SheetPivotFieldLayout: Codable, Sendable, Hashable {
    public var mode: SheetPivotFieldLayoutMode
    public var addEmptyLine: Bool
    public var subtotalsAtTop: Bool

    public init(
        mode: SheetPivotFieldLayoutMode = .tabular,
        addEmptyLine: Bool = false,
        subtotalsAtTop: Bool = true
    ) {
        self.mode = mode
        self.addEmptyLine = addEmptyLine
        self.subtotalsAtTop = subtotalsAtTop
    }
}

// MARK: - SheetPivotFieldSort (P2b step "sort")

/// Which member-ordering strategy a row/column field's distinct group
/// keys use, `ScDPSaveDimension.sortInfo` parity. `.name` is the P2a
/// default behavior (`QueryEngine`'s mixed-type order over the raw
/// member value) - a field with `sort == nil` behaves identically to
/// P2a, so this is purely additive.
public enum SheetPivotSortMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// By the member's own value, `QueryEngine`'s mixed-type order.
    case name
    /// By a `.data` field's aggregated value for that member -
    /// `dataFieldName` names which one. `PivotTableStore` sorts by the
    /// SINGLE-FIELD aggregate (that member's own rows, not a full
    /// multi-level joint aggregate) - see that file's doc comment for
    /// the scope call.
    case data
    /// By the field's own `members` array order (declared order,
    /// unsorted values fall back to `.name` order after every declared
    /// member).
    case manual
}

/// One field's sort configuration. `ascending: false` reverses
/// `QueryEngine`'s own comparison, matching `SheetSortCondition`'s
/// existing convention.
public struct SheetPivotFieldSort: Codable, Sendable, Hashable {
    public var mode: SheetPivotSortMode
    public var ascending: Bool
    /// The `.data` field to sort by when `mode == .data`. Ignored for
    /// every other mode.
    public var dataFieldName: String?

    public init(mode: SheetPivotSortMode = .name, ascending: Bool = true, dataFieldName: String? = nil) {
        self.mode = mode
        self.ascending = ascending
        self.dataFieldName = dataFieldName
    }
}

// MARK: - SheetPivotFieldAutoShow (P2b step "autoShow")

public enum SheetPivotAutoShowDirection: String, Codable, Sendable, Hashable, CaseIterable {
    case top
    case bottom
}

/// Top/bottom-N cutoff over a field's distinct members, ranked by a
/// `.data` field's aggregate - `ScDPSaveDimension.autoShowInfo` parity.
/// Per the design contract ("autoShow reuses landed top-N cutoffs"),
/// `PivotTableStore` implements this by constructing a
/// `SheetFilterCriteria(kind: .top, ...)` (`QueryEngine.swift`) over
/// the per-member aggregates and reusing its existing cutoff-based
/// `rowsFailing(in:)` - not a second top-N implementation.
public struct SheetPivotFieldAutoShow: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var direction: SheetPivotAutoShowDirection
    /// N items - always a count, never a percent (unlike
    /// `SheetFilterCriteria.topIsPercent`; a pivot autoShow is always
    /// item-count based in Excel/LO).
    public var itemCount: Int
    /// Which `.data` field's aggregate ranks the members.
    public var dataFieldName: String

    public init(enabled: Bool = true, direction: SheetPivotAutoShowDirection = .top, itemCount: Int = 10, dataFieldName: String) {
        self.enabled = enabled
        self.direction = direction
        self.itemCount = itemCount
        self.dataFieldName = dataFieldName
    }
}

// MARK: - SheetPivotReferenceMode (P2b step "reference" / show-data-as)

/// A `.data` field's "Show Values As" transform, `ScDPSaveDimension
/// .referenceValue` parity. **Scope call (recorded for architect
/// ratification - see this track's findings file):** the design
/// contract names this field only as "referenceValue (show-data-as)"
/// with no enumerated mode list. LO/Excel's real vocabulary is much
/// larger (difference-from/running-total/rank/index, each needing a
/// caller-chosen base field + base item). Bounded here to the four
/// modes that need no base-field/base-item selection - the same
/// "grand total" / "row total" / "column total" concepts
/// `SheetPivotDefinition.columnGrand`/`rowGrand` already compute, just
/// expressed as a ratio instead of raw sum. `.normal` (the default,
/// nil-equivalent) is the P2a behavior: the aggregate's own value,
/// unchanged.
public enum SheetPivotReferenceMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// No transform - the aggregate's own computed value (P2a behavior).
    case normal
    case percentOfGrandTotal
    case percentOfRowTotal
    case percentOfColumnTotal
}

// MARK: - PivotGroupSpec (P2b design contract step 4)

/// The interval granularities a `.date` group can bucket by -
/// `ScDPDimensionSaveData`'s date-grouping checkboxes (Excel/LO both
/// offer exactly these seven). `PivotGroupSpec.date(by:)` takes a SET
/// (multi-select, matching that real UI) rather than one case - see
/// `PivotTableStore.dateGroupLabel(for:by:)` for how multiple selected
/// granularities combine into one label.
public enum PivotDateGroupInterval: String, Codable, Sendable, Hashable, CaseIterable {
    case seconds, minutes, hours, days, months, quarters, years
}

/// One named bucket of an explicit `.members` grouping - `table:
/// data-pilot-group`'s ODF shape (a group name + the raw member
/// display-texts it collects).
public struct PivotMemberGroup: Codable, Sendable, Hashable {
    public var name: String
    /// Display-text values (matching `SheetPivotFieldMember.name`'s own
    /// display-text convention) collected into this group.
    public var members: [String]

    public init(name: String, members: [String]) {
        self.name = name
        self.members = members
    }
}

/// How a field's raw source values collapse into synthetic group keys
/// before group-key derivation - `ScDPDimensionSaveData` parity
/// (design contract step 4). Auto-synthesized `Codable` (Swift 5.5+
/// enum-with-payload synthesis, the same convention `ShapePathSegment`
/// already uses in this codebase) - a brand-new field
/// (`SheetPivotField.group`), so there is no legacy wire shape to stay
/// compatible with.
public enum PivotGroupSpec: Codable, Sendable, Hashable {
    /// Buckets a numeric field into `[start + k*step, start +
    /// (k+1)*step)` runs; a value below `start` falls into the first
    /// bucket's "< start" catch-all, a value >= `end` into the last
    /// bucket's "end+" catch-all - see `PivotTableStore
    /// .numericGroupLabel(for:start:end:step:)` for the exact label
    /// text.
    case numeric(start: Double, end: Double, step: Double)
    /// Buckets a date field by the selected granularities combined
    /// into one label - see `PivotDateGroupInterval`'s doc comment.
    case date(by: Set<PivotDateGroupInterval>)
    /// Explicit named groups over declared member values. A raw value
    /// matching none of `groups`' members passes through UNGROUPED
    /// (its own value), matching Excel/LO's "grouped and ungrouped
    /// items coexist" behavior when not every member is assigned.
    case members([PivotMemberGroup])
}

// MARK: - SheetPivotField

/// One field's placement and behavior within a pivot - `ScDPObject`
/// parity name `ScDPSaveDimension`. Replaces the P0 registry's bare
/// `rowFields`/`columnFields`/`dataFields`/`filterFields` `[String]`
/// arrays as `SheetPivotDefinition`'s real storage; those four arrays
/// still exist as computed, derived-never-stored legacy views (see
/// `SheetPivotDefinition`'s `Codable` extension) so old JSON keeps
/// decoding and old readers keep working through a future P3.
///
/// **P2a/P2b split** (design contract `sota-p2-core-report.md` #2.2,
/// "Slices" line - read before changing this type): P2a shipped
/// `fieldName`/`orientation`/`function`/`subtotals`/`subtotalAuto`/
/// `showEmpty`/`repeatItemLabels`/`layout`/`members` and
/// `PivotTableStore`'s tabular-layout + grand-total pipeline built on
/// top of them. P2b adds `sort`, `autoShow`, `reference` ("show values
/// as" modes), and `group` (`PivotGroupSpec`, design contract step 4) -
/// each a pure-additive `Optional` property, exactly like this type's
/// own P0 -> P2a evolution: a P2a-written `SheetPivotField` simply
/// decodes these new keys as absent/nil (auto-synthesized `Decodable`
/// handles a missing key for an `Optional` stored property with no
/// custom code), so every P2a fixture/test keeps decoding identically.
/// See the P2-A findings file for the P2a-era reasoning and this
/// track's findings file for the P2b field shapes.
public struct SheetPivotField: Codable, Sendable, Hashable {
    public var fieldName: String
    public var orientation: SheetPivotFieldOrientation
    /// The aggregation this field summarizes with when
    /// `orientation == .data`. Nil for every other orientation; also a
    /// valid (if unusual) transient state for a `.data` field before a
    /// function is chosen - `PivotTableStore` treats nil as `.sum`
    /// (`ScDPObject`'s own default), matching Excel/LO.
    public var function: SheetPivotAggregation?
    /// Extra per-field subtotal rows shown alongside (or instead of)
    /// the automatic one - `ScDPObject`'s `SubTotalFuncs`. Round-trip
    /// only at P2a: `PivotTableStore`'s pipeline computes the overall
    /// grand total row/column but never inserts a per-group subtotal
    /// row (that is closer to outline-mode rendering, P2b scope).
    public var subtotals: [SheetPivotAggregation]
    /// Whether the field's single automatic subtotal is shown (P2a:
    /// round-trip only, see `subtotals`'s note above).
    public var subtotalAuto: Bool
    /// "Show items with no data" - round-trip only at P2a: nothing yet
    /// declares a field's full member set independently of what
    /// appears in the filtered source range (P2b's `PivotGroupSpec`/
    /// declared-members work gives this a mechanism to act on).
    public var showEmpty: Bool
    /// When false (the default), a row/column field's label is shown
    /// once at the top of its group and left blank on the group's
    /// continuation rows/columns; when true, the label repeats on
    /// every row/column. `PivotTableStore` honors this for real (see
    /// its group-header-blanking logic) - unlike the other flags
    /// above, this is fully implemented at P2a.
    public var repeatItemLabels: Bool
    public var layout: SheetPivotFieldLayout?
    /// Explicit member state - see ``SheetPivotFieldMember``'s doc
    /// comment for exactly which orientation `PivotTableStore` reads
    /// this on at P2a.
    public var members: [SheetPivotFieldMember]
    /// P2b: member-ordering override - see ``SheetPivotFieldSort``. Nil
    /// behaves exactly like P2a (`QueryEngine` mixed-type order,
    /// ascending).
    public var sort: SheetPivotFieldSort?
    /// P2b: top/bottom-N member cutoff - see ``SheetPivotFieldAutoShow``.
    /// Nil (or `enabled == false`) shows every member, matching P2a.
    public var autoShow: SheetPivotFieldAutoShow?
    /// P2b: "show values as" transform for a `.data` field - see
    /// ``SheetPivotReferenceMode``. Nil (or `.normal`) is the P2a
    /// behavior: the aggregate's own value, untransformed.
    public var reference: SheetPivotReferenceMode?
    /// P2b: collapses this field's raw source values into synthetic
    /// group buckets before group-key derivation - see
    /// ``PivotGroupSpec``. Nil means "no grouping" (P2a behavior: the
    /// raw member value IS the group key).
    public var group: PivotGroupSpec?

    public init(
        fieldName: String,
        orientation: SheetPivotFieldOrientation,
        function: SheetPivotAggregation? = nil,
        subtotals: [SheetPivotAggregation] = [],
        subtotalAuto: Bool = true,
        showEmpty: Bool = false,
        repeatItemLabels: Bool = false,
        layout: SheetPivotFieldLayout? = nil,
        members: [SheetPivotFieldMember] = [],
        sort: SheetPivotFieldSort? = nil,
        autoShow: SheetPivotFieldAutoShow? = nil,
        reference: SheetPivotReferenceMode? = nil,
        group: PivotGroupSpec? = nil
    ) {
        self.fieldName = fieldName
        self.orientation = orientation
        self.function = function
        self.subtotals = subtotals
        self.subtotalAuto = subtotalAuto
        self.showEmpty = showEmpty
        self.repeatItemLabels = repeatItemLabels
        self.layout = layout
        self.members = members
        self.sort = sort
        self.autoShow = autoShow
        self.reference = reference
        self.group = group
    }
}

// MARK: - SheetPivotTableStyleInfo

/// Style/banding flags for a pivot's rendered output - `ScDPObject`'s
/// `PivotTableStyleInfo` parity, expressed with the same field
/// vocabulary OOXML's `pivotTableStyleInfo` element uses
/// (name/showRowHeaders/showColHeaders/showRowStripes/showColStripes/
/// showLastColumn) since that is the concrete, spec-named shape this
/// track's design contract pointed at ("matching `PivotTableStyleInfo`'s
/// real LO shape" - see the P2-A findings file). Round-trip/rendering
/// metadata only - `PivotTableStore` is a pure compute engine and never
/// reads this, matching `filterButton`/`drillDown`'s own "UI-only,
/// never read by the engine" convention on `SheetPivotDefinition`.
///
/// P2a shipped this as a `{ styleName: String? }` placeholder; the
/// custom `Codable` below keeps a P2a-encoded payload (missing every
/// new key) decoding to this type's documented defaults, the same
/// additive-decode contract `SheetPivotDefinition`'s own `Codable`
/// extension uses.
public struct SheetPivotTableStyleInfo: Codable, Sendable, Hashable {
    public var styleName: String?
    public var showRowHeaders: Bool
    public var showColumnHeaders: Bool
    public var showRowStripes: Bool
    public var showColumnStripes: Bool
    public var showLastColumn: Bool

    public init(
        styleName: String? = nil,
        showRowHeaders: Bool = true,
        showColumnHeaders: Bool = true,
        showRowStripes: Bool = false,
        showColumnStripes: Bool = false,
        showLastColumn: Bool = false
    ) {
        self.styleName = styleName
        self.showRowHeaders = showRowHeaders
        self.showColumnHeaders = showColumnHeaders
        self.showRowStripes = showRowStripes
        self.showColumnStripes = showColumnStripes
        self.showLastColumn = showLastColumn
    }

    private enum CodingKeys: String, CodingKey {
        case styleName, showRowHeaders, showColumnHeaders, showRowStripes, showColumnStripes, showLastColumn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        styleName = try c.decodeIfPresent(String.self, forKey: .styleName)
        showRowHeaders = try c.decodeIfPresent(Bool.self, forKey: .showRowHeaders) ?? true
        showColumnHeaders = try c.decodeIfPresent(Bool.self, forKey: .showColumnHeaders) ?? true
        showRowStripes = try c.decodeIfPresent(Bool.self, forKey: .showRowStripes) ?? false
        showColumnStripes = try c.decodeIfPresent(Bool.self, forKey: .showColumnStripes) ?? false
        showLastColumn = try c.decodeIfPresent(Bool.self, forKey: .showLastColumn) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(styleName, forKey: .styleName)
        try c.encode(showRowHeaders, forKey: .showRowHeaders)
        try c.encode(showColumnHeaders, forKey: .showColumnHeaders)
        try c.encode(showRowStripes, forKey: .showRowStripes)
        try c.encode(showColumnStripes, forKey: .showColumnStripes)
        try c.encode(showLastColumn, forKey: .showLastColumn)
    }
}

// MARK: - SheetPivotDefinition

/// A pivot table definition bound to a source range on a `Sheet`.
///
/// Through P0 this was a registry-only model: it persisted WHICH
/// pivots a document has and HOW they're configured, with no
/// computation behind it. P2-A 2.2a adds `PivotTableStore.swift`
/// (`Materials/Sheets/PivotTableStore.swift`), the pure compute engine
/// that turns a `Sheet` + this definition into a `PivotResultGrid`.
/// `SheetStore` remains the only writer of that grid into a sheet's
/// output range - this type and `PivotTableStore` both stay
/// persistence-free.
public struct SheetPivotDefinition: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String

    // Source range.
    public var sheet: String?
    public var topLeftCol: Int
    public var topLeftRow: Int
    public var bottomRightCol: Int
    public var bottomRightRow: Int

    /// The pivot's real field list (P2-A 2.2a) - source of truth for
    /// `rowFields`/`columnFields`/`dataFields`/`filterFields` below,
    /// which are now derived views, not independent storage. See the
    /// `Codable` extension for the legacy-decode/dual-encode contract.
    public var fields: [SheetPivotField]

    /// Where a computed pivot table would be written. `nil` sheet means
    /// "same sheet as the source range" - `PivotTableStore` computes
    /// the grid; `SheetStore` owns actually placing it there; this is
    /// just the persisted intent.
    public var outputSheet: String?
    public var outputTopLeftCol: Int?
    public var outputTopLeftRow: Int?

    // Table-level options (P2-A 2.2a design contract step 3).
    /// Whether a "Grand Total" column is appended to the right.
    public var columnGrand: Bool
    /// Whether a "Grand Total" row is appended at the bottom.
    public var rowGrand: Bool
    /// Skip source rows where every in-play field's cell is `.empty`
    /// before grouping. `PivotTableStore` honors this for real at P2a.
    public var ignoreEmptyRows: Bool
    /// Round-trip only at P2a - see the P2-A findings file.
    public var repeatIfEmpty: Bool
    /// UI-only: show the field-header filter-dropdown affordance.
    /// `PivotTableStore` is a pure compute engine and never reads this.
    public var filterButton: Bool
    /// UI-only: allow double-click drill-down to source rows.
    /// `PivotTableStore` never reads this.
    public var drillDown: Bool
    /// Display label for the grand total row/column; nil means the
    /// conventional "Grand Total".
    public var grandTotalName: String?
    public var styleInfo: SheetPivotTableStyleInfo?

    public init(
        id: UUID = UUID(),
        name: String,
        sheet: String? = nil,
        topLeftCol: Int,
        topLeftRow: Int,
        bottomRightCol: Int,
        bottomRightRow: Int,
        fields: [SheetPivotField] = [],
        outputSheet: String? = nil,
        outputTopLeftCol: Int? = nil,
        outputTopLeftRow: Int? = nil,
        columnGrand: Bool = true,
        rowGrand: Bool = true,
        ignoreEmptyRows: Bool = false,
        repeatIfEmpty: Bool = false,
        filterButton: Bool = true,
        drillDown: Bool = true,
        grandTotalName: String? = nil,
        styleInfo: SheetPivotTableStyleInfo? = nil
    ) {
        self.id = id
        self.name = name
        self.sheet = sheet
        self.topLeftCol = topLeftCol
        self.topLeftRow = topLeftRow
        self.bottomRightCol = bottomRightCol
        self.bottomRightRow = bottomRightRow
        self.fields = fields
        self.outputSheet = outputSheet
        self.outputTopLeftCol = outputTopLeftCol
        self.outputTopLeftRow = outputTopLeftRow
        self.columnGrand = columnGrand
        self.rowGrand = rowGrand
        self.ignoreEmptyRows = ignoreEmptyRows
        self.repeatIfEmpty = repeatIfEmpty
        self.filterButton = filterButton
        self.drillDown = drillDown
        self.grandTotalName = grandTotalName
        self.styleInfo = styleInfo
    }

    // MARK: - Legacy derived views (doctrine rule 3: derived, never stored)

    /// Field names grouped down the pivot's rows, outermost first.
    /// Derived from `fields`; see the type header.
    public var rowFields: [String] {
        fields.filter { $0.orientation == .row }.map { $0.fieldName }
    }
    /// Field names grouped across the pivot's columns, outermost first.
    public var columnFields: [String] {
        fields.filter { $0.orientation == .column }.map { $0.fieldName }
    }
    /// Value columns summarized into the pivot body. A `.data` field
    /// with no `function` set reads as `.sum` here, matching
    /// `PivotTableStore`'s own nil-function default.
    public var dataFields: [SheetPivotDataField] {
        fields.filter { $0.orientation == .data }.map {
            SheetPivotDataField(fieldName: $0.fieldName, aggregation: $0.function ?? .sum)
        }
    }
    /// Field names used to filter source rows before grouping, without
    /// appearing in the row/column layout themselves - the legacy name
    /// for what `SheetPivotField.orientation == .page` fields are now.
    public var filterFields: [String] {
        fields.filter { $0.orientation == .page }.map { $0.fieldName }
    }

    /// `nil` if any source coordinate is negative - see
    /// `SheetNamedRange`'s doc comment for why this validates rather
    /// than constructing `CellAddr` directly.
    public var sourceRangeRef: RangeRef? {
        guard topLeftCol >= 0, topLeftRow >= 0, bottomRightCol >= 0, bottomRightRow >= 0 else { return nil }
        return RangeRef(
            sheet: sheet,
            topLeft: CellAddr(col: topLeftCol, row: topLeftRow),
            bottomRight: CellAddr(col: bottomRightCol, row: bottomRightRow)
        )
    }
}

// MARK: - SheetPivotDefinition + Codable

extension SheetPivotDefinition: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, sheet
        case topLeftCol, topLeftRow, bottomRightCol, bottomRightRow
        case fields
        case rowFields, columnFields, dataFields, filterFields
        case outputSheet, outputTopLeftCol, outputTopLeftRow
        case columnGrand, rowGrand, ignoreEmptyRows, repeatIfEmpty
        case filterButton, drillDown, grandTotalName, styleInfo
    }

    /// Reads the new `fields` shape when present; otherwise synthesizes
    /// it from the legacy `rowFields`/`columnFields`/`dataFields`/
    /// `filterFields` arrays - the P0-era shape, exercised by the
    /// pinned `sheet-pivot-definition-p0.json` fixture, which this
    /// initializer must keep decoding to identical `rowFields`/
    /// `columnFields`/`dataFields`/`filterFields` semantics forever.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        sheet = try c.decodeIfPresent(String.self, forKey: .sheet)
        topLeftCol = try c.decode(Int.self, forKey: .topLeftCol)
        topLeftRow = try c.decode(Int.self, forKey: .topLeftRow)
        bottomRightCol = try c.decode(Int.self, forKey: .bottomRightCol)
        bottomRightRow = try c.decode(Int.self, forKey: .bottomRightRow)
        outputSheet = try c.decodeIfPresent(String.self, forKey: .outputSheet)
        outputTopLeftCol = try c.decodeIfPresent(Int.self, forKey: .outputTopLeftCol)
        outputTopLeftRow = try c.decodeIfPresent(Int.self, forKey: .outputTopLeftRow)
        columnGrand = try c.decodeIfPresent(Bool.self, forKey: .columnGrand) ?? true
        rowGrand = try c.decodeIfPresent(Bool.self, forKey: .rowGrand) ?? true
        ignoreEmptyRows = try c.decodeIfPresent(Bool.self, forKey: .ignoreEmptyRows) ?? false
        repeatIfEmpty = try c.decodeIfPresent(Bool.self, forKey: .repeatIfEmpty) ?? false
        filterButton = try c.decodeIfPresent(Bool.self, forKey: .filterButton) ?? true
        drillDown = try c.decodeIfPresent(Bool.self, forKey: .drillDown) ?? true
        grandTotalName = try c.decodeIfPresent(String.self, forKey: .grandTotalName)
        styleInfo = try c.decodeIfPresent(SheetPivotTableStyleInfo.self, forKey: .styleInfo)

        if let decodedFields = try c.decodeIfPresent([SheetPivotField].self, forKey: .fields) {
            fields = decodedFields
        } else {
            let legacyRowFields = try c.decodeIfPresent([String].self, forKey: .rowFields) ?? []
            let legacyColumnFields = try c.decodeIfPresent([String].self, forKey: .columnFields) ?? []
            let legacyDataFields = try c.decodeIfPresent([SheetPivotDataField].self, forKey: .dataFields) ?? []
            let legacyFilterFields = try c.decodeIfPresent([String].self, forKey: .filterFields) ?? []
            fields = Self.synthesizeFields(
                rowFields: legacyRowFields,
                columnFields: legacyColumnFields,
                dataFields: legacyDataFields,
                filterFields: legacyFilterFields
            )
        }
    }

    /// Writes BOTH the new `fields` shape and the legacy split-array
    /// shape, the latter derived from `fields` at encode time (never
    /// independently stored, so the two can never drift - doctrine
    /// rule 3). Deliberately NOT `CommentThread`'s "only decode reads
    /// both shapes, encode writes only the new one" pattern: the design
    /// contract calls for a dual-write specifically, through a future
    /// P3 that drops the legacy keys once every reader has moved on.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(sheet, forKey: .sheet)
        try c.encode(topLeftCol, forKey: .topLeftCol)
        try c.encode(topLeftRow, forKey: .topLeftRow)
        try c.encode(bottomRightCol, forKey: .bottomRightCol)
        try c.encode(bottomRightRow, forKey: .bottomRightRow)
        try c.encode(fields, forKey: .fields)
        try c.encode(rowFields, forKey: .rowFields)
        try c.encode(columnFields, forKey: .columnFields)
        try c.encode(dataFields, forKey: .dataFields)
        try c.encode(filterFields, forKey: .filterFields)
        try c.encodeIfPresent(outputSheet, forKey: .outputSheet)
        try c.encodeIfPresent(outputTopLeftCol, forKey: .outputTopLeftCol)
        try c.encodeIfPresent(outputTopLeftRow, forKey: .outputTopLeftRow)
        try c.encode(columnGrand, forKey: .columnGrand)
        try c.encode(rowGrand, forKey: .rowGrand)
        try c.encode(ignoreEmptyRows, forKey: .ignoreEmptyRows)
        try c.encode(repeatIfEmpty, forKey: .repeatIfEmpty)
        try c.encode(filterButton, forKey: .filterButton)
        try c.encode(drillDown, forKey: .drillDown)
        try c.encodeIfPresent(grandTotalName, forKey: .grandTotalName)
        try c.encodeIfPresent(styleInfo, forKey: .styleInfo)
    }

    private static func synthesizeFields(
        rowFields: [String],
        columnFields: [String],
        dataFields: [SheetPivotDataField],
        filterFields: [String]
    ) -> [SheetPivotField] {
        var result: [SheetPivotField] = []
        result += rowFields.map { SheetPivotField(fieldName: $0, orientation: .row) }
        result += columnFields.map { SheetPivotField(fieldName: $0, orientation: .column) }
        result += dataFields.map {
            SheetPivotField(fieldName: $0.fieldName, orientation: .data, function: $0.aggregation)
        }
        result += filterFields.map { SheetPivotField(fieldName: $0, orientation: .page) }
        return result
    }
}

// MARK: - Sheet + pivot definitions

extension Sheet {
    /// `pivotDefinitions ?? []`, matching `effectiveValidationRules`/
    /// `effectiveConditionalFormats`'s "nil means none" convention.
    public var effectivePivotDefinitions: [SheetPivotDefinition] {
        pivotDefinitions ?? []
    }

    /// A copy with `definition` appended.
    public func addingPivotDefinition(_ definition: SheetPivotDefinition) -> Sheet {
        var updated = self
        updated.pivotDefinitions = effectivePivotDefinitions + [definition]
        return updated
    }

    /// A copy with the definition matching `id` removed. A no-op if no
    /// definition has that id.
    public func removingPivotDefinition(_ id: UUID) -> Sheet {
        var updated = self
        updated.pivotDefinitions = effectivePivotDefinitions.filter { $0.id != id }
        return updated
    }
}
