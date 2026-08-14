import Foundation

// MARK: - SheetNamedRange

/// A named range as persisted in a `Sheet` document - the on-disk
/// mirror of the formula engine's own `NamedRange`
/// (`FormulaEngine/SheetEngine.swift`), which lives only in the live
/// `SheetEngine`'s in-memory state and is lost the moment the app
/// quits. `SheetWorkbook.hydrate(from:)` is the boundary: it registers
/// every persisted `SheetNamedRange` into the engine via
/// `defineName`, and a product-layer mutation
/// (`SheetStore.defineNamedRange`/`undefineNamedRange`) is what keeps
/// this field in sync afterward.
///
/// Stores plain `Int` coordinates rather than embedding `RangeRef`/
/// `CellAddr` directly: neither conforms to `Codable`, and
/// `CellAddr`'s initializer has a non-negative precondition that a
/// synthesized decoder would bypass entirely (it sets stored
/// properties straight from decoded JSON, not through the memberwise
/// init) - corrupt or hand-edited JSON with a negative coordinate
/// would crash the app instead of failing to decode. `rangeRef`
/// re-validates before constructing one.
public struct SheetNamedRange: Codable, Sendable, Hashable {
    /// The caller's original spelling, for display - lookup elsewhere
    /// is case-insensitive (matching `SheetEngine.defineName`'s own
    /// convention; see its doc comment for why).
    public var name: String
    /// `nil` = unscoped, resolves against whichever sheet the formula
    /// referencing it lives on.
    public var sheet: String?
    public var topLeftCol: Int
    public var topLeftRow: Int
    public var bottomRightCol: Int
    public var bottomRightRow: Int

    public init(
        name: String,
        sheet: String? = nil,
        topLeftCol: Int,
        topLeftRow: Int,
        bottomRightCol: Int,
        bottomRightRow: Int
    ) {
        self.name = name
        self.sheet = sheet
        self.topLeftCol = topLeftCol
        self.topLeftRow = topLeftRow
        self.bottomRightCol = bottomRightCol
        self.bottomRightRow = bottomRightRow
    }

    public init(name: String, range: RangeRef) {
        self.name = name
        self.sheet = range.sheet
        self.topLeftCol = range.topLeft.col
        self.topLeftRow = range.topLeft.row
        self.bottomRightCol = range.bottomRight.col
        self.bottomRightRow = range.bottomRight.row
    }

    /// `nil` if any coordinate is negative - malformed data (e.g. a
    /// hand-edited document) rather than something worth crashing on.
    public var rangeRef: RangeRef? {
        guard topLeftCol >= 0, topLeftRow >= 0, bottomRightCol >= 0, bottomRightRow >= 0 else { return nil }
        return RangeRef(
            sheet: sheet,
            topLeft: CellAddr(col: topLeftCol, row: topLeftRow),
            bottomRight: CellAddr(col: bottomRightCol, row: bottomRightRow)
        )
    }
}

extension Sheet {
    /// `namedRanges ?? [:]`, so every call site can treat the optional
    /// field as a non-optional value instead of re-deriving the "nil
    /// means none defined" rule at each use - same convention as
    /// `effectiveProtection`.
    public var effectiveNamedRanges: [String: SheetNamedRange] {
        namedRanges ?? [:]
    }

    /// A copy with `range` defined under `name` (case-insensitive:
    /// re-defining an existing name, in any case, replaces it rather
    /// than erroring - unlike `SheetEngine.defineName`, which is the
    /// live-engine, single-workbook-session guard against silently
    /// clobbering a name a formula is already resolving through;
    /// this is the at-rest document, where "replace" is the expected
    /// meaning of the user editing a named range's definition again).
    public func settingNamedRange(_ name: String, range: RangeRef) -> Sheet {
        var updated = self
        var ranges = effectiveNamedRanges
        ranges[name.uppercased()] = SheetNamedRange(name: name, range: range)
        updated.namedRanges = ranges
        return updated
    }

    /// A copy with `name`'s definition removed (case-insensitive). A
    /// no-op if `name` isn't defined.
    public func removingNamedRange(_ name: String) -> Sheet {
        var updated = self
        var ranges = effectiveNamedRanges
        ranges.removeValue(forKey: name.uppercased())
        updated.namedRanges = ranges
        return updated
    }
}
