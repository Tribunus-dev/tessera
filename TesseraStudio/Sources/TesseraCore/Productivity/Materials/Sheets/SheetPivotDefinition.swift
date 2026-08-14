import Foundation

// MARK: - SheetPivotAggregation

/// How a `.dataFields` entry rolls up multiple source rows into one
/// pivot cell.
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
}

// MARK: - SheetPivotDataField

/// One value column summarized into the pivot's data area.
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

// MARK: - SheetPivotDefinition

/// A pivot table definition bound to a source range on a `Sheet`.
///
/// This is the lightweight "pivot list" registry `studio-expansion-plan
/// .md`'s 0.1 row calls for - it persists WHICH pivots a document has
/// and HOW they're configured (source range, row/column/filter fields,
/// data aggregations), not the computed pivot output itself. The full
/// computation engine (`PivotTableStore`, UNO `ScDPObject` parity) is
/// explicitly Phase 2 work; this model is what it will read from and
/// eventually replace, the same relationship `SheetValidationRule` has
/// to the input layer that will one day check against it.
public struct SheetPivotDefinition: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String

    // Source range.
    public var sheet: String?
    public var topLeftCol: Int
    public var topLeftRow: Int
    public var bottomRightCol: Int
    public var bottomRightRow: Int

    /// Field names grouped down the pivot's rows, outermost first.
    public var rowFields: [String]
    /// Field names grouped across the pivot's columns, outermost first.
    public var columnFields: [String]
    /// Value columns summarized into the pivot body.
    public var dataFields: [SheetPivotDataField]
    /// Field names used to filter source rows before grouping, without
    /// appearing in the row/column layout themselves.
    public var filterFields: [String]

    /// Where a computed pivot table would be written. `nil` sheet means
    /// "same sheet as the source range" - `PivotTableStore` owns
    /// actually placing it there; this is just the persisted intent.
    public var outputSheet: String?
    public var outputTopLeftCol: Int?
    public var outputTopLeftRow: Int?

    public init(
        id: UUID = UUID(),
        name: String,
        sheet: String? = nil,
        topLeftCol: Int,
        topLeftRow: Int,
        bottomRightCol: Int,
        bottomRightRow: Int,
        rowFields: [String] = [],
        columnFields: [String] = [],
        dataFields: [SheetPivotDataField] = [],
        filterFields: [String] = [],
        outputSheet: String? = nil,
        outputTopLeftCol: Int? = nil,
        outputTopLeftRow: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.sheet = sheet
        self.topLeftCol = topLeftCol
        self.topLeftRow = topLeftRow
        self.bottomRightCol = bottomRightCol
        self.bottomRightRow = bottomRightRow
        self.rowFields = rowFields
        self.columnFields = columnFields
        self.dataFields = dataFields
        self.filterFields = filterFields
        self.outputSheet = outputSheet
        self.outputTopLeftCol = outputTopLeftCol
        self.outputTopLeftRow = outputTopLeftRow
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
