//===----------------------------------------------------------------------===//
//  SheetStatisticsTools.swift
//  Tessera Studio
//
//  Agent-tool wrappers for Calc's "statistics wizard" (P2 item 2.8,
//  studio-expansion-plan.md row: "Statistics wizards (18 agent-tool
//  wrappers)"). No further design doc names the exact 18, so this file
//  derives the list from the plan's own wording plus the landed
//  StatisticsFunctions.swift set, per testing-doctrine.md's "derive a
//  contract stub from the best available evidence, record it for
//  architect ratification" rule - this block IS that record (mirrored
//  in docs/.scratch/p2-a-findings-4.md). Ratify or amend before P2-B.
//
//  DERIVED 18-ITEM CONTRACT STUB:
//    mean, median, mode, stdev (sample), stdev_population, variance
//    (sample), variance_population, range, quartiles (Q1/Q2/Q3), iqr,
//    correlation, linear_regression (slope+intercept), rank,
//    percentile, zscore, large, small, count.
//  This is the descriptive + order-statistic + two-variable set a
//  spreadsheet "Statistics" wizard typically offers (Excel's Analysis
//  ToolPak / LO Calc's Statistics function category), scoped to what
//  the LANDED FormulaEngine can answer without a new hypothesis-testing
//  engine - t-test/ANOVA/chi-square are OUT of scope: nothing in the
//  plan's "18" names them, and they would need new distribution math
//  this wave does not license.
//
//  REUSE, NOT REIMPLEMENTATION. Every tool whose function is already
//  registered - AVERAGE, MEDIAN, STDEV, STDEVP, VAR, VARP, PERCENTILE,
//  LARGE, SMALL, CORREL, COUNT, MAX, MIN (FunctionRegistry.swift +
//  StatisticsFunctions.swift) - calls the LANDED evaluator against a
//  formula string (`SheetStatisticsSupport.evaluateFormula`), never
//  recomputing the math in Swift; see `SheetReadTool`/`SheetDescribeTool`
//  in SheetTools.swift for the range-reading pattern this reuses.
//  range/quartiles/iqr/linear_regression/zscore have no registered
//  function of their own but are built by COMPOSING landed functions
//  (MAX-MIN; PERCENTILE at .25/.5/.75; slope = CORREL * stdev(y)/stdev(x),
//  intercept = mean(y) - slope*mean(x); zscore = (value - mean)/stdev) -
//  still zero new numerical code, only arithmetic glue between results.
//  Only MODE and RANK have no landed function AND no landed composition
//  (StatisticsFunctions.swift registers no MODE; no RANK/RANK.EQ exists
//  anywhere in FunctionRegistry.swift) - those two read raw range values
//  themselves and implement the missing math directly inside this file,
//  exactly as instructed for functions StatisticsFunctions.swift does
//  not register. Per the wave's structural constraint, this file does
//  NOT touch StatisticsFunctions.swift, FunctionRegistry.swift,
//  SheetStore.swift, or TesseraToolRegistry.swift - the 18 struct names
//  below are listed in this track's wiringNotes for the centralized
//  pass to add to `TesseraToolRegistry.default`.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Shared support

/// Support shared by every tool in this file. Reuses `SheetToolSupport`
/// (SheetTools.swift) for workbook lookup and range parsing rather than
/// duplicating it - see that file's own doc comments for the address
/// parsing contract.
enum SheetStatisticsSupport {

    /// `sheet`, when given, wraps `reference` as a single-quoted sheet
    /// qualifier (`'Sheet Name'!A1:A10`), escaping embedded quotes the
    /// way `Lexer.scanQuotedSheetRef` expects (`''` -> literal `'`). Nil
    /// `sheet` returns `reference` unqualified, so it resolves against
    /// the workbook's active sheet - matching every other sheet tool's
    /// `sheet` parameter (SheetReadTool/SheetWriteTool/SheetDescribeTool).
    static func qualifiedReference(_ reference: String, sheet: String?) -> String {
        guard let sheet else { return reference }
        let escaped = sheet.replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'!\(reference)"
    }

    /// Parse + evaluate a formula string against the live workbook via
    /// the landed `Evaluator` - the same evaluation path
    /// `SheetEngine.setFormula` uses, minus the write and minus the
    /// dependency-graph/undo bookkeeping a real cell write needs. Never
    /// touches `document.blocks`: `SheetEngine`'s own conformance to
    /// `SheetEngineCore` (`getCellValue`/`getRangeValues`/
    /// `resolveNamedRange`) takes the engine's lock independently per
    /// call, so it is safe to call from outside the engine's own locked
    /// context - see `SheetEngine.evaluatorBridge`'s doc comment for why
    /// that bridge exists ONLY for calls already holding the lock, which
    /// this is not.
    static func evaluateFormula(_ formula: String, engine: SheetEngine) throws -> Value {
        let parser = try FormulaParser(source: formula)
        switch try parser.parse() {
        case .value(let constant):
            return constant
        case .formula(let parsed):
            return try engine.evaluator.evaluate(
                parsed.ast, at: CellAddr(col: 0, row: 0), sheet: engine.activeSheet, engine: engine
            )
        }
    }

    /// Read a range as raw numeric values, dropping non-numeric cells -
    /// the same coercion the formula engine's aggregate functions apply
    /// internally. Reimplemented here ONLY because MODE/RANK have no
    /// registered function to delegate to (see the file header).
    static func readNumbers(reference: String, sheet: String?, engine: SheetEngine) throws -> [Double] {
        let grid = try SheetToolSupport.addresses(for: reference).cells
        var numbers: [Double] = []
        for row in grid {
            for addr in row {
                if let n = engine.getValue(sheet: sheet, addr: addr).asNumber {
                    numbers.append(n)
                }
            }
        }
        return numbers
    }

    /// Format an evaluated `Value` as a `ToolResult`. `#ERROR!` values
    /// (undefined variance on a single point, a non-numeric range, ...)
    /// surface as a tool failure rather than a "successful" NaN-shaped
    /// result, matching `SheetWriteTool`'s address-failure reporting.
    static func toolResult(_ value: Value, reference: String, extraData: [String: JSONValue] = [:]) -> ToolResult {
        switch value {
        case .error(let e):
            return .fail("Could not compute over '\(reference)': \(e.displayString)")
        case .number(let n):
            var data: [String: JSONValue] = ["reference": .string(reference), "result": .number(n)]
            for (k, v) in extraData { data[k] = v }
            return .ok(value.asString, data: data)
        default:
            return .fail("Unexpected non-numeric result for '\(reference)': \(value.asString)")
        }
    }

    /// Shared `execute()` body for a single-range tool whose function is
    /// already landed: parse `reference`/optional `sheet`, evaluate
    /// `functionCall(qualifiedReference)` as a formula, format the
    /// result. Used by every tool below whose underlying function
    /// exists in the FormulaEngine today.
    static func singleRangeResult(
        arguments: [String: JSONValue],
        functionCall: (String) -> String
    ) -> ToolResult {
        guard let reference = arguments["reference"]?.stringValue else {
            return .fail("Missing 'reference'.")
        }
        let sheet = arguments["sheet"]?.stringValue
        let engine: SheetEngine
        do { engine = try SheetToolSupport.workbook() } catch { return .fail(error.localizedDescription) }
        let qualified = qualifiedReference(reference, sheet: sheet)
        let formula = "=" + functionCall(qualified)
        do {
            let value = try evaluateFormula(formula, engine: engine)
            return toolResult(value, reference: reference)
        } catch {
            return .fail("Could not evaluate over '\(reference)': \(error.localizedDescription)")
        }
    }

    /// Shared schema for the plain "one range, one sheet" tools.
    static let rangeSchema = JSONSchema(
        type: "object",
        properties: [
            "reference": SchemaProperty(type: "string", description: "A range like A1:A20, or a single cell."),
            "sheet": SchemaProperty(type: "string", description: "Sheet name. Defaults to the active sheet."),
        ],
        required: ["reference"]
    )
}

// MARK: - sheet_stat_mean

/// Arithmetic mean of a range. Delegates to the landed `AVERAGE`.
public struct SheetStatMeanTool: TesseraTool {
    public let name = "sheet_stat_mean"
    public let description = "Arithmetic mean (average) of a range of numbers."
    public let defaultApprovalLevel = ApprovalLevel.auto
    public var parameters: JSONSchema { SheetStatisticsSupport.rangeSchema }

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        SheetStatisticsSupport.singleRangeResult(arguments: arguments) { "AVERAGE(\($0))" }
    }
}

// MARK: - sheet_stat_median

/// Middle value of a range. Delegates to the landed `MEDIAN`.
public struct SheetStatMedianTool: TesseraTool {
    public let name = "sheet_stat_median"
    public let description = "The middle value of a range of numbers (average of the two middle values for an even count)."
    public let defaultApprovalLevel = ApprovalLevel.auto
    public var parameters: JSONSchema { SheetStatisticsSupport.rangeSchema }

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        SheetStatisticsSupport.singleRangeResult(arguments: arguments) { "MEDIAN(\($0))" }
    }
}

// MARK: - sheet_stat_mode

/// Most frequently occurring value in a range. NOT a registered
/// FormulaEngine function (StatisticsFunctions.swift has no MODE) - this
/// tool reads the range itself and computes it. Matches Excel's
/// MODE/MODE.SNGL: the SMALLEST value among the most-frequent ones, and
/// `#N/A` (here, a tool failure) when nothing repeats.
public struct SheetStatModeTool: TesseraTool {
    public let name = "sheet_stat_mode"
    public let description = """
        The most frequently occurring value in a range. When several \
        values tie for most frequent, returns the smallest of them \
        (`allModes` in the structured result lists every tied value). \
        Fails if no value repeats.
        """
    public let defaultApprovalLevel = ApprovalLevel.auto
    public var parameters: JSONSchema { SheetStatisticsSupport.rangeSchema }

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let reference = arguments["reference"]?.stringValue else {
            return .fail("Missing 'reference'.")
        }
        let sheet = arguments["sheet"]?.stringValue
        let engine: SheetEngine
        do { engine = try SheetToolSupport.workbook() } catch { return .fail(error.localizedDescription) }
        let numbers: [Double]
        do { numbers = try SheetStatisticsSupport.readNumbers(reference: reference, sheet: sheet, engine: engine) }
        catch { return .fail("Could not parse reference '\(reference)'.") }

        var counts: [Double: Int] = [:]
        for n in numbers { counts[n, default: 0] += 1 }
        guard let maxCount = counts.values.max(), maxCount > 1 else {
            return .fail("No value repeats in '\(reference)' - MODE is undefined.")
        }
        let allModes = counts.filter { $0.value == maxCount }.map(\.key).sorted()
        let primary = allModes[0]
        return .ok(Value.number(primary).asString, data: [
            "reference": .string(reference),
            "result": .number(primary),
            "allModes": .array(allModes.map { .number($0) }),
            "occurrences": .number(Double(maxCount)),
        ])
    }
}

// MARK: - sheet_stat_stdev

/// Sample standard deviation (divides by n-1). Delegates to `STDEV`.
public struct SheetStatStandardDeviationTool: TesseraTool {
    public let name = "sheet_stat_stdev"
    public let description = "Sample standard deviation of a range (divides by n-1). Use sheet_stat_stdev_population for a whole-population dataset."
    public let defaultApprovalLevel = ApprovalLevel.auto
    public var parameters: JSONSchema { SheetStatisticsSupport.rangeSchema }

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        SheetStatisticsSupport.singleRangeResult(arguments: arguments) { "STDEV(\($0))" }
    }
}

// MARK: - sheet_stat_stdev_population

/// Population standard deviation (divides by n). Delegates to `STDEVP`.
public struct SheetStatStandardDeviationPopulationTool: TesseraTool {
    public let name = "sheet_stat_stdev_population"
    public let description = "Population standard deviation of a range (divides by n). Use sheet_stat_stdev when the range is only a sample."
    public let defaultApprovalLevel = ApprovalLevel.auto
    public var parameters: JSONSchema { SheetStatisticsSupport.rangeSchema }

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        SheetStatisticsSupport.singleRangeResult(arguments: arguments) { "STDEVP(\($0))" }
    }
}

// MARK: - sheet_stat_variance

/// Sample variance (divides by n-1). Delegates to `VAR`.
public struct SheetStatVarianceTool: TesseraTool {
    public let name = "sheet_stat_variance"
    public let description = "Sample variance of a range (divides by n-1). Use sheet_stat_variance_population for a whole-population dataset."
    public let defaultApprovalLevel = ApprovalLevel.auto
    public var parameters: JSONSchema { SheetStatisticsSupport.rangeSchema }

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        SheetStatisticsSupport.singleRangeResult(arguments: arguments) { "VAR(\($0))" }
    }
}

// MARK: - sheet_stat_variance_population

/// Population variance (divides by n). Delegates to `VARP`.
public struct SheetStatVariancePopulationTool: TesseraTool {
    public let name = "sheet_stat_variance_population"
    public let description = "Population variance of a range (divides by n). Use sheet_stat_variance when the range is only a sample."
    public let defaultApprovalLevel = ApprovalLevel.auto
    public var parameters: JSONSchema { SheetStatisticsSupport.rangeSchema }

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        SheetStatisticsSupport.singleRangeResult(arguments: arguments) { "VARP(\($0))" }
    }
}

// MARK: - sheet_stat_range

/// Spread of a range: max - min. Composed from the landed `MAX`/`MIN` in
/// a single formula string - no registered RANGE function, but no new
/// math either.
public struct SheetStatRangeTool: TesseraTool {
    public let name = "sheet_stat_range"
    public let description = "The spread of a range of numbers: the largest value minus the smallest."
    public let defaultApprovalLevel = ApprovalLevel.auto
    public var parameters: JSONSchema { SheetStatisticsSupport.rangeSchema }

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        SheetStatisticsSupport.singleRangeResult(arguments: arguments) { "MAX(\($0))-MIN(\($0))" }
    }
}

// MARK: - sheet_stat_quartiles

/// Q1/median/Q3 of a range. Composed from three landed `PERCENTILE`
/// evaluations (Excel's QUARTILE(range, q) == PERCENTILE(range, q/4));
/// no QUARTILE function is registered, but no new math either.
public struct SheetStatQuartilesTool: TesseraTool {
    public let name = "sheet_stat_quartiles"
    public let description = "The first quartile (Q1), median (Q2), and third quartile (Q3) of a range of numbers, using linear-interpolation percentiles."
    public let defaultApprovalLevel = ApprovalLevel.auto
    public var parameters: JSONSchema { SheetStatisticsSupport.rangeSchema }

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let reference = arguments["reference"]?.stringValue else {
            return .fail("Missing 'reference'.")
        }
        let sheet = arguments["sheet"]?.stringValue
        let engine: SheetEngine
        do { engine = try SheetToolSupport.workbook() } catch { return .fail(error.localizedDescription) }
        let qualified = SheetStatisticsSupport.qualifiedReference(reference, sheet: sheet)
        do {
            let q1 = try SheetStatisticsSupport.evaluateFormula("=PERCENTILE(\(qualified),0.25)", engine: engine)
            let q2 = try SheetStatisticsSupport.evaluateFormula("=PERCENTILE(\(qualified),0.5)", engine: engine)
            let q3 = try SheetStatisticsSupport.evaluateFormula("=PERCENTILE(\(qualified),0.75)", engine: engine)
            guard let n1 = q1.asNumber, let n2 = q2.asNumber, let n3 = q3.asNumber else {
                return .fail("Could not compute quartiles over '\(reference)'.")
            }
            return .ok("Q1=\(Value.number(n1).asString) Q2=\(Value.number(n2).asString) Q3=\(Value.number(n3).asString)", data: [
                "reference": .string(reference),
                "q1": .number(n1),
                "q2": .number(n2),
                "q3": .number(n3),
            ])
        } catch {
            return .fail("Could not evaluate over '\(reference)': \(error.localizedDescription)")
        }
    }
}

// MARK: - sheet_stat_iqr

/// Interquartile range: Q3 - Q1. Composed from two landed `PERCENTILE`
/// calls in one formula string.
public struct SheetStatIQRTool: TesseraTool {
    public let name = "sheet_stat_iqr"
    public let description = "The interquartile range (Q3 - Q1) of a range of numbers - a spread measure less sensitive to outliers than the full range."
    public let defaultApprovalLevel = ApprovalLevel.auto
    public var parameters: JSONSchema { SheetStatisticsSupport.rangeSchema }

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        SheetStatisticsSupport.singleRangeResult(arguments: arguments) {
            "PERCENTILE(\($0),0.75)-PERCENTILE(\($0),0.25)"
        }
    }
}

// MARK: - sheet_stat_correlation

/// Pearson correlation coefficient of two equal-length ranges. Delegates
/// to the landed `CORREL`.
public struct SheetStatCorrelationTool: TesseraTool {
    public let name = "sheet_stat_correlation"
    public let description = "The Pearson correlation coefficient (-1 to 1) between two equal-length ranges of numbers."
    public let defaultApprovalLevel = ApprovalLevel.auto

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "rangeX": SchemaProperty(type: "string", description: "First range, e.g. A1:A20."),
            "rangeY": SchemaProperty(type: "string", description: "Second range, same length as rangeX, e.g. B1:B20."),
            "sheet": SchemaProperty(type: "string", description: "Sheet name for both ranges. Defaults to the active sheet."),
        ],
        required: ["rangeX", "rangeY"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let rangeX = arguments["rangeX"]?.stringValue else { return .fail("Missing 'rangeX'.") }
        guard let rangeY = arguments["rangeY"]?.stringValue else { return .fail("Missing 'rangeY'.") }
        let sheet = arguments["sheet"]?.stringValue
        let engine: SheetEngine
        do { engine = try SheetToolSupport.workbook() } catch { return .fail(error.localizedDescription) }
        let qx = SheetStatisticsSupport.qualifiedReference(rangeX, sheet: sheet)
        let qy = SheetStatisticsSupport.qualifiedReference(rangeY, sheet: sheet)
        do {
            let value = try SheetStatisticsSupport.evaluateFormula("=CORREL(\(qx),\(qy))", engine: engine)
            return SheetStatisticsSupport.toolResult(value, reference: "\(rangeX), \(rangeY)")
        } catch {
            return .fail("Could not evaluate correlation over '\(rangeX)'/'\(rangeY)': \(error.localizedDescription)")
        }
    }
}

// MARK: - sheet_stat_linear_regression

/// Simple linear regression (least squares) of y on x: slope + intercept.
/// No SLOPE/INTERCEPT/LINEST function is registered, but the values are
/// composed entirely from landed functions: slope = CORREL(y,x) *
/// STDEV(y)/STDEV(x); intercept = AVERAGE(y) - slope*AVERAGE(x) (the
/// standard OLS identity - either both STDEV or both STDEVP work, the
/// n-1/n factor cancels in the ratio). Zero new statistical code, only
/// arithmetic glue between five evaluator calls.
public struct SheetStatLinearRegressionTool: TesseraTool {
    public let name = "sheet_stat_linear_regression"
    public let description = "Simple linear regression (least squares) of rangeY on rangeX: returns slope and intercept for y = slope*x + intercept."
    public let defaultApprovalLevel = ApprovalLevel.auto

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "rangeX": SchemaProperty(type: "string", description: "Independent variable range, e.g. A1:A20."),
            "rangeY": SchemaProperty(type: "string", description: "Dependent variable range, same length as rangeX, e.g. B1:B20."),
            "sheet": SchemaProperty(type: "string", description: "Sheet name for both ranges. Defaults to the active sheet."),
        ],
        required: ["rangeX", "rangeY"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let rangeX = arguments["rangeX"]?.stringValue else { return .fail("Missing 'rangeX'.") }
        guard let rangeY = arguments["rangeY"]?.stringValue else { return .fail("Missing 'rangeY'.") }
        let sheet = arguments["sheet"]?.stringValue
        let engine: SheetEngine
        do { engine = try SheetToolSupport.workbook() } catch { return .fail(error.localizedDescription) }
        let qx = SheetStatisticsSupport.qualifiedReference(rangeX, sheet: sheet)
        let qy = SheetStatisticsSupport.qualifiedReference(rangeY, sheet: sheet)
        do {
            let correl = try SheetStatisticsSupport.evaluateFormula("=CORREL(\(qy),\(qx))", engine: engine)
            let stdevY = try SheetStatisticsSupport.evaluateFormula("=STDEV(\(qy))", engine: engine)
            let stdevX = try SheetStatisticsSupport.evaluateFormula("=STDEV(\(qx))", engine: engine)
            let meanY = try SheetStatisticsSupport.evaluateFormula("=AVERAGE(\(qy))", engine: engine)
            let meanX = try SheetStatisticsSupport.evaluateFormula("=AVERAGE(\(qx))", engine: engine)
            guard let r = correl.asNumber, let sy = stdevY.asNumber, let sx = stdevX.asNumber,
                  let my = meanY.asNumber, let mx = meanX.asNumber, sx != 0 else {
                return .fail("Could not compute linear regression over '\(rangeX)'/'\(rangeY)' (constant x, or a non-numeric range).")
            }
            let slope = r * (sy / sx)
            let intercept = my - slope * mx
            return .ok("slope=\(Value.number(slope).asString) intercept=\(Value.number(intercept).asString)", data: [
                "rangeX": .string(rangeX),
                "rangeY": .string(rangeY),
                "slope": .number(slope),
                "intercept": .number(intercept),
            ])
        } catch {
            return .fail("Could not evaluate linear regression over '\(rangeX)'/'\(rangeY)': \(error.localizedDescription)")
        }
    }
}

// MARK: - sheet_stat_rank

/// 1-based rank of a value within a range. No RANK/RANK.EQ function is
/// registered - reads the range itself and computes it. Ties share a
/// rank (Excel RANK.EQ semantics): rank = 1 + count of strictly-better
/// values.
public struct SheetStatRankTool: TesseraTool {
    public let name = "sheet_stat_rank"
    public let description = """
        The 1-based rank of a value within a range of numbers. Descending \
        order by default (largest = rank 1), matching Excel's RANK \
        default; pass order "ascending" for smallest = rank 1. Tied \
        values share the same rank.
        """
    public let defaultApprovalLevel = ApprovalLevel.auto

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "reference": SchemaProperty(type: "string", description: "The data range, e.g. A1:A20."),
            "value": SchemaProperty(type: "number", description: "The value to rank. Must be present in the range."),
            "order": SchemaProperty(type: "string", description: "\"ascending\" or \"descending\" (default).", enumValues: ["ascending", "descending"], defaultValue: "descending"),
            "sheet": SchemaProperty(type: "string", description: "Sheet name. Defaults to the active sheet."),
        ],
        required: ["reference", "value"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let reference = arguments["reference"]?.stringValue else { return .fail("Missing 'reference'.") }
        guard let target = arguments["value"]?.numberValue else { return .fail("Missing 'value'.") }
        let ascending = arguments["order"]?.stringValue == "ascending"
        let sheet = arguments["sheet"]?.stringValue
        let engine: SheetEngine
        do { engine = try SheetToolSupport.workbook() } catch { return .fail(error.localizedDescription) }
        let numbers: [Double]
        do { numbers = try SheetStatisticsSupport.readNumbers(reference: reference, sheet: sheet, engine: engine) }
        catch { return .fail("Could not parse reference '\(reference)'.") }

        guard numbers.contains(target) else {
            return .fail("Value \(Value.number(target).asString) was not found in '\(reference)'.")
        }
        let better = ascending ? numbers.filter { $0 < target }.count : numbers.filter { $0 > target }.count
        let rank = better + 1
        return .ok("\(rank)", data: [
            "reference": .string(reference),
            "value": .number(target),
            "rank": .number(Double(rank)),
        ])
    }
}

// MARK: - sheet_stat_percentile

/// The k-th percentile of a range (0..1, linear interpolation).
/// Delegates to the landed `PERCENTILE`.
public struct SheetStatPercentileTool: TesseraTool {
    public let name = "sheet_stat_percentile"
    public let description = "The k-th percentile of a range of numbers, interpolating between values. k is between 0 and 1 inclusive (0.25 = 25th percentile)."
    public let defaultApprovalLevel = ApprovalLevel.auto

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "reference": SchemaProperty(type: "string", description: "A range like A1:A20."),
            "k": SchemaProperty(type: "number", description: "Percentile rank, between 0 and 1 inclusive.", minimum: 0, maximum: 1),
            "sheet": SchemaProperty(type: "string", description: "Sheet name. Defaults to the active sheet."),
        ],
        required: ["reference", "k"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let k = arguments["k"]?.numberValue else { return .fail("Missing 'k'.") }
        return SheetStatisticsSupport.singleRangeResult(arguments: arguments) { "PERCENTILE(\($0),\(k))" }
    }
}

// MARK: - sheet_stat_zscore

/// Standard score of a value against a range's mean/stdev. No
/// STANDARDIZE function is registered - composed from the landed
/// `AVERAGE`/`STDEV`, plus trivial arithmetic.
public struct SheetStatZScoreTool: TesseraTool {
    public let name = "sheet_stat_zscore"
    public let description = "The z-score (standard score) of a value against a range: (value - mean) / sample standard deviation."
    public let defaultApprovalLevel = ApprovalLevel.auto

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "reference": SchemaProperty(type: "string", description: "The data range, e.g. A1:A20."),
            "value": SchemaProperty(type: "number", description: "The value to standardize."),
            "sheet": SchemaProperty(type: "string", description: "Sheet name. Defaults to the active sheet."),
        ],
        required: ["reference", "value"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let reference = arguments["reference"]?.stringValue else { return .fail("Missing 'reference'.") }
        guard let target = arguments["value"]?.numberValue else { return .fail("Missing 'value'.") }
        let sheet = arguments["sheet"]?.stringValue
        let engine: SheetEngine
        do { engine = try SheetToolSupport.workbook() } catch { return .fail(error.localizedDescription) }
        let qualified = SheetStatisticsSupport.qualifiedReference(reference, sheet: sheet)
        do {
            let mean = try SheetStatisticsSupport.evaluateFormula("=AVERAGE(\(qualified))", engine: engine)
            let stdev = try SheetStatisticsSupport.evaluateFormula("=STDEV(\(qualified))", engine: engine)
            guard let m = mean.asNumber, let s = stdev.asNumber, s != 0 else {
                return .fail("Could not compute a z-score over '\(reference)' (undefined mean/stdev, or stdev is zero).")
            }
            let z = (target - m) / s
            return .ok(Value.number(z).asString, data: [
                "reference": .string(reference),
                "value": .number(target),
                "result": .number(z),
            ])
        } catch {
            return .fail("Could not evaluate over '\(reference)': \(error.localizedDescription)")
        }
    }
}

// MARK: - sheet_stat_large

/// The k-th largest value in a range. Delegates to the landed `LARGE`.
public struct SheetStatLargeTool: TesseraTool {
    public let name = "sheet_stat_large"
    public let description = "The k-th largest value in a range of numbers (k=1 is the largest)."
    public let defaultApprovalLevel = ApprovalLevel.auto

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "reference": SchemaProperty(type: "string", description: "A range like A1:A20."),
            "k": SchemaProperty(type: "number", description: "1-based rank from the top.", minimum: 1),
            "sheet": SchemaProperty(type: "string", description: "Sheet name. Defaults to the active sheet."),
        ],
        required: ["reference", "k"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let k = arguments["k"]?.numberValue else { return .fail("Missing 'k'.") }
        return SheetStatisticsSupport.singleRangeResult(arguments: arguments) { "LARGE(\($0),\(Int(k)))" }
    }
}

// MARK: - sheet_stat_small

/// The k-th smallest value in a range. Delegates to the landed `SMALL`.
public struct SheetStatSmallTool: TesseraTool {
    public let name = "sheet_stat_small"
    public let description = "The k-th smallest value in a range of numbers (k=1 is the smallest)."
    public let defaultApprovalLevel = ApprovalLevel.auto

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "reference": SchemaProperty(type: "string", description: "A range like A1:A20."),
            "k": SchemaProperty(type: "number", description: "1-based rank from the bottom.", minimum: 1),
            "sheet": SchemaProperty(type: "string", description: "Sheet name. Defaults to the active sheet."),
        ],
        required: ["reference", "k"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let k = arguments["k"]?.numberValue else { return .fail("Missing 'k'.") }
        return SheetStatisticsSupport.singleRangeResult(arguments: arguments) { "SMALL(\($0),\(Int(k)))" }
    }
}

// MARK: - sheet_stat_count

/// Count of numeric cells in a range. Delegates to the landed `COUNT`.
public struct SheetStatCountTool: TesseraTool {
    public let name = "sheet_stat_count"
    public let description = "The number of numeric values in a range (matches how many data points the other statistics tools would use)."
    public let defaultApprovalLevel = ApprovalLevel.auto
    public var parameters: JSONSchema { SheetStatisticsSupport.rangeSchema }

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        SheetStatisticsSupport.singleRangeResult(arguments: arguments) { "COUNT(\($0))" }
    }
}
