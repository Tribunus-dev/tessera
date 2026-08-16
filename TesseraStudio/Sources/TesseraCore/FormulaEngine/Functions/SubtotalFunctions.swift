//===----------------------------------------------------------------------===//
//  SubtotalFunctions.swift
//  Tessera Formula Engine
//
//  SUBTOTAL(function_num, ref1, [ref2], ...) - Excel/LO's function_num
//  law is exact and non-negotiable (Microsoft's own reference, quoted
//  in the P2-A 2.7 design contract): function_num 1-11 INCLUDE
//  manually-hidden rows; 101-111 EXCLUDE them; filter-hidden rows are
//  excluded by BOTH bands; hidden COLUMNS are never excluded
//  horizontally; a nested SUBTOTAL call is ignored by the outer one.
//
//  WIRING GAP (documented, not hidden - see this wave's findings file
//  and structured wiringNotes): the generic function-call path this
//  file registers into (`BuiltInFunction.call: ([Value]) throws ->
//  Value`) receives ONLY already-evaluated `Value`s - no sheet, no
//  engine, no row-hidden state. Every other range-aware function that
//  genuinely needs live sheet context (OFFSET, INDIRECT - see
//  Evaluator.swift's "OFFSET / INDIRECT" section) is special-cased
//  BEFORE that generic dispatch, with `Evaluator` querying
//  `SheetEngineCore` directly. SUBTOTAL structurally needs the exact
//  same treatment - manually-hidden-row state, filter-hidden-row
//  state, and a nested-SUBTOTAL-cell marker, none of which
//  `SheetEngineCore` exposes today - but `Evaluator.swift` and
//  `SheetEngineCore` are shared files outside this track's file
//  ownership for this wave (see AGENTS.md's Wave P2-A file-list rule),
//  so that interception is NOT implemented here.
//
//  What IS implemented and fully correct: `SubtotalAggregator`, the
//  pure per-function_num aggregation math (tested directly against
//  hand-built row contexts - see SubtotalFunctionsTests.swift), and
//  this file's `SUBTOTAL` registration, which dispatches through the
//  generic path exactly like any other aggregate function. Reached
//  that way, every candidate cell is necessarily treated as visible
//  and non-nested (the generic path has nothing else to tell it) - so
//  a plain `=SUBTOTAL(9, A1:A10)` with no manually-hidden rows, no
//  active filter, and no nested SUBTOTAL cells in range computes the
//  exactly correct result today. The three context-dependent
//  divergences (1-11 vs 101-111 on a manually-hidden row, filter-
//  hidden exclusion, nested-SUBTOTAL exclusion) need the Evaluator
//  interception described above before they are live.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - SubtotalRowContext

/// One candidate cell within a SUBTOTAL reference range, carrying the
/// three per-ROW facts the function_num law keys off of. Named "row"
/// (not "cell") deliberately: every flag here is determined by which
/// ROW the cell sits in, never by which column - there is no
/// "isColumnHidden" flag anywhere on this type, which is what makes
/// "hidden columns are never excluded horizontally" a structural
/// guarantee of `SubtotalAggregator.evaluate` rather than a runtime
/// check that could be gotten wrong.
///
/// A pure, ready-to-test input shape: see this file's header for how a
/// LIVE evaluation would populate `isManuallyHidden`/`isFilterHidden`/
/// `isNestedSubtotal` (the still-open wiring gap) versus how
/// `SubtotalFunctionsTests.swift` constructs it directly today.
public struct SubtotalRowContext: Sendable, Equatable {
    public var value: Value
    /// Hidden via Format > Hide Row, or an outline-group collapse - NOT
    /// autofilter. Excluded only when `function_num` is 101-111.
    public var isManuallyHidden: Bool
    /// Hidden by an active autofilter/QueryEngine criterion
    /// (`SheetFilterState.hiddenRows` is truth at the Sheets layer -
    /// see QueryEngine.swift). Excluded by BOTH the 1-11 and 101-111
    /// bands - the law's one symmetric case.
    public var isFilterHidden: Bool
    /// True when this row's own formula is itself a SUBTOTAL call.
    /// Always excluded, regardless of `function_num`, so an outer
    /// SUBTOTAL never double-counts an inner one's contribution.
    public var isNestedSubtotal: Bool

    public init(value: Value, isManuallyHidden: Bool = false, isFilterHidden: Bool = false, isNestedSubtotal: Bool = false) {
        self.value = value
        self.isManuallyHidden = isManuallyHidden
        self.isFilterHidden = isFilterHidden
        self.isNestedSubtotal = isNestedSubtotal
    }
}

// MARK: - SubtotalAggregator

/// Pure `function_num` -> aggregation semantics, decoupled from how
/// `rows` got built (a live sheet scan, or a hand-built test fixture -
/// see this file's header). No engine, no sheet, no I/O.
public enum SubtotalAggregator {
    /// `functionNum` must be 1-11 (include manually-hidden rows) or
    /// 101-111 (exclude them); anything else is `#NUM!`, Excel's own
    /// error for an out-of-range SUBTOTAL selector.
    ///
    /// Exclusion order: a nested-SUBTOTAL row is dropped first
    /// (unconditional on `functionNum`), then a filter-hidden row
    /// (also unconditional), then - ONLY for the 101-111 band - a
    /// manually-hidden row. What survives feeds the same `ColumnSlice`
    /// aggregation every other aggregate function in this engine uses
    /// (SUM/AVERAGE/COUNT/... in FunctionRegistry.swift), so SUBTOTAL
    /// can never quietly diverge from what those functions call
    /// "sum"/"count"/... over the same surviving values.
    public static func evaluate(functionNum: Int, rows: [SubtotalRowContext]) -> Value {
        guard let kind = SubtotalFunctionKind(functionNum: functionNum) else {
            return .error(.numberInvalid)
        }
        let excludeManuallyHidden = functionNum >= 101
        let included = rows.filter { row in
            if row.isNestedSubtotal { return false }
            if row.isFilterHidden { return false }
            if excludeManuallyHidden && row.isManuallyHidden { return false }
            return true
        }
        let slice = ColumnSlice(from: included.map { $0.value })

        switch kind {
        case .average:
            guard let avg = slice.average() else { return .error(.divisionByZero) }
            return .number(avg)
        case .count:
            return .number(Double(slice.countNumbers))
        case .countA:
            return .number(Double(slice.countNonEmpty))
        case .max:
            return .number(slice.max() ?? 0)
        case .min:
            return .number(slice.min() ?? 0)
        case .product:
            return .number(slice.product())
        case .sum:
            return .number(slice.sum())
        case .stdDev, .stdDevP, .variance, .varianceP:
            let numbers = slice.numbers.compactMap { $0 }
            guard let result = dispersion(kind, numbers) else { return .error(.divisionByZero) }
            return .number(result)
        }
    }

    /// Sample (STDEV/VAR) divides by n-1 and needs n>=2; population
    /// (STDEVP/VARP) divides by n and needs n>=1. Same formula shape as
    /// StatisticsFunctions.swift's private `variance(_:sample:)` -
    /// duplicated here (not imported: that helper is file-private, and
    /// this file's own layering keeps SUBTOTAL's aggregation
    /// self-contained rather than reaching into another function
    /// file's internals) rather than promoted to shared internal API,
    /// which would be a FunctionRegistry.swift/StatisticsFunctions.swift
    /// edit outside this track's file ownership this wave.
    private static func dispersion(_ kind: SubtotalFunctionKind, _ numbers: [Double]) -> Double? {
        let sample = (kind == .stdDev || kind == .variance)
        let n = numbers.count
        guard n > (sample ? 1 : 0) else { return nil }
        let mean = numbers.reduce(0, +) / Double(n)
        let sumSquares = numbers.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        let v = sumSquares / Double(sample ? n - 1 : n)
        return (kind == .stdDev || kind == .stdDevP) ? v.squareRoot() : v
    }
}

// MARK: - SubtotalFunctionKind

/// The 11 SUBTOTAL aggregation kinds, parsed from either the 1-11 or
/// 101-111 `function_num` band (`SubtotalAggregator.evaluate` is what
/// tells the two bands apart for hidden-row purposes; this type only
/// needs which of the 11 FUNCTIONS was selected).
///
/// Deliberately NOT `QueryEngine.swift`'s `SubtotalAggregationFunction`
/// - that Sheets-layer enum encodes only the always-1-11 band a
/// `SubtotalDescriptor` generates and is Codable/persisted; this
/// FormulaEngine-layer type has to additionally understand the 101-111
/// band a hand-typed formula can use, and the FormulaEngine has no
/// dependency on the Sheets material layer at all (see this module's
/// existing one-directional layering: Materials/Sheets depends on
/// FormulaEngine, never the reverse) - introducing that dependency
/// just to share an 11-case enum would be a bigger structural change
/// than the two-line duplication it would save.
private enum SubtotalFunctionKind: Equatable {
    case average, count, countA, max, min, product, stdDev, stdDevP, sum, variance, varianceP

    init?(functionNum: Int) {
        switch functionNum {
        case 1, 101: self = .average
        case 2, 102: self = .count
        case 3, 103: self = .countA
        case 4, 104: self = .max
        case 5, 105: self = .min
        case 6, 106: self = .product
        case 7, 107: self = .stdDev
        case 8, 108: self = .stdDevP
        case 9, 109: self = .sum
        case 10, 110: self = .variance
        case 11, 111: self = .varianceP
        default: return nil
        }
    }
}

// MARK: - Registration

extension FunctionRegistry {
    /// Registers `SUBTOTAL` for name/arity/signature lookup and generic
    /// dispatch. See this file's header for exactly what the generic
    /// dispatch path can and cannot do for SUBTOTAL's full law.
    func registerSubtotal() {
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "SUBTOTAL",
                description: "Returns a subtotal in a list or database, honoring function_num's manually-hidden-row and nested-SUBTOTAL exclusion rules.",
                parameters: [
                    FunctionParameter(name: "function_num", description: "1-11 includes manually-hidden rows; 101-111 excludes them.", acceptsRange: false),
                    FunctionParameter(name: "ref1", description: "The first range to subtotal.", acceptsRange: true),
                    FunctionParameter(name: "ref2", description: "Additional ranges.", acceptsRange: true, optional: true, repeatable: true),
                ],
                volatility: .notVolatile
            ),
            arity: 2...255,
            call: { args in
                // `args[0]` would trap on an empty call; the `arity:
                // 2...255` above is what the real dispatch path
                // (Evaluator.evalFunction) enforces before ever
                // reaching this closure, but `.call` itself carries no
                // such guarantee to a caller invoking it directly.
                guard !args.isEmpty else { return .error(.notAvailable) }
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                guard let functionNumRaw = FunctionArgs.number(args[0]) else { return .error(.numberInvalid) }
                let refs = Array(args.dropFirst())
                let flattened = ColumnSlice.flattenArrays(refs)
                let rows = flattened.map { SubtotalRowContext(value: $0) }
                return SubtotalAggregator.evaluate(functionNum: Int(functionNumRaw), rows: rows)
            }
        ))
    }
}
