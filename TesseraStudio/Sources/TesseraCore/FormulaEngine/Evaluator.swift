//===----------------------------------------------------------------------===//
//  Evaluator.swift
//  Tessera Formula Engine
//
//  Recursive evaluator with call-stack depth limit and volatile function support.
//===----------------------------------------------------------------------===//

import Foundation

public final class Evaluator {
    public struct Config {
        public var maxCallDepth: Int = 50
        public var deterministicConfig: DeterministicConfig?

        public init() {}
    }

    public let config: Config
    private let functions: FunctionRegistry

    public init(config: Config = Config(), functions: FunctionRegistry = .shared) {
        self.config = config
        self.functions = functions
    }

    // MARK: - Public API

    /// Evaluate a formula AST at a given cell address.
    ///
    /// `sheet` is the sheet the formula ITSELF lives on - not the
    /// workbook's active sheet. An unqualified reference inside the
    /// formula (`=A1`, no `Sheet!` prefix) resolves against `sheet`; a
    /// qualified one (`=Sheet2!A1`) resolves against whatever it names.
    /// Passing the active sheet here instead of the formula's own sheet
    /// is exactly the bug this parameter exists to prevent: a formula on
    /// an inactive sheet would read the ACTIVE sheet's cells for every
    /// unqualified reference it makes.
    public func evaluate(_ ast: FormulaAST, at addr: CellAddr, sheet: String, engine: SheetEngineCore) throws -> Value {
        try recursiveEvaluate(ast, at: addr, sheet: sheet, depth: 0, engine: engine, env: [:])
    }

    /// Names bound by `LET` (and LAMBDA parameters at call time). Looked
    /// up before named ranges, so an inner binding shadows an outer one.
    public typealias Environment = [String: Value]

    // MARK: - Recursive Evaluation

    private func recursiveEvaluate(_ ast: FormulaAST, at addr: CellAddr, sheet: String,
                                  depth: Int, engine: SheetEngineCore,
                                  env: Environment) throws -> Value {
        if depth > config.maxCallDepth {
            return .error(.numberInvalid)
        }

        switch ast {
        case .number(let n):
            return .number(n)

        case .string(let s):
            return .string(s)

        case .bool(let b):
            return .bool(b)

        case .error(let e):
            return .error(e)

        case .null:
            return .null

        case .cell(let ref):
            // Resolve named range or cell ref
            if ref.addr.col < 0 && ref.addr.row < 0 {
                // Named range marker — resolve at evaluation time
                let name = String(ref.sheet?.dropFirst() ?? "")
                // A LET binding shadows a workbook named range, so an
                // inner name always wins over an outer one.
                if let bound = env[name.uppercased()] { return bound }
                return try engine.resolveNamedRange(name, at: addr, fallbackSheet: sheet)
            }
            // ref.sheet is nil for an unqualified reference - "same sheet
            // as this formula", i.e. `sheet`, not the workbook's active
            // sheet.
            return try engine.getCellValue(ref.addr, sheet: ref.sheet ?? sheet)

        case .range(let range):
            // Evaluate to array. Same resolution rule as .cell: an
            // unqualified range resolves against the formula's own sheet.
            let values = try engine.getRangeValues(range, fallbackSheet: sheet)
            return .array(rows: range.height, cols: range.width, flat: values)

        case .binary(let op, let left, let right):
            return try evalBinary(op: op, left: left, right: right, at: addr, sheet: sheet, depth: depth, engine: engine, env: env)

        case .unary(let op, let operand):
            return try evalUnary(op: op, operand: operand, at: addr, sheet: sheet, depth: depth, engine: engine, env: env)

        case .function(let name, let args):
            return try evalFunction(name: name, args: args, at: addr, sheet: sheet, depth: depth, engine: engine, env: env)

        case .arrayLiteral(let rows):
            var flat: [Value] = []
            for row in rows {
                for cell in row {
                    flat.append(try recursiveEvaluate(cell, at: addr, sheet: sheet, depth: depth + 1, engine: engine, env: env))
                }
            }
            return .array(rows: rows.count, cols: rows.first?.count ?? 0, flat: flat)
        }
    }

    // MARK: - Binary Operations

    private func evalBinary(op: BinaryOp, left: FormulaAST, right: FormulaAST,
                            at addr: CellAddr, sheet: String, depth: Int,
                            engine: SheetEngineCore, env: Environment) throws -> Value {
        let l = try recursiveEvaluate(left, at: addr, sheet: sheet, depth: depth + 1, engine: engine, env: env)
        let r = try recursiveEvaluate(right, at: addr, sheet: sheet, depth: depth + 1, engine: engine, env: env)

        switch op {
        case .add:
            return evalArithmetic(l, r, op: +)
        case .subtract:
            return evalArithmetic(l, r, op: -)
        case .multiply:
            return evalArithmetic(l, r, op: *)
        case .divide:
            return evalDivide(l, r)
        case .power:
            return evalPower(l, r)
        case .concat:
            return .string(l.asString + r.asString)
        case .equal:
            return .bool(l.asString == r.asString)
        case .notEqual:
            return .bool(l.asString != r.asString)
        case .less:
            return .bool(Comparison.compare(l, r, op: .less))
        case .greater:
            return .bool(Comparison.compare(l, r, op: .greater))
        case .lessOrEqual:
            return .bool(Comparison.compare(l, r, op: .lessOrEqual))
        case .greaterOrEqual:
            return .bool(Comparison.compare(l, r, op: .greaterOrEqual))
        case .rangeOp, .intersect:
            return l // Range operator handled at parse level
        }
    }

    private func evalArithmetic(_ lhs: Value, _ rhs: Value, op: (Double, Double) -> Double) -> Value {
        if let e = propagatedError(lhs, rhs) { return .error(e) }
        guard let l = arithmeticOperand(lhs), let r = arithmeticOperand(rhs) else {
            return .error(.notAvailable)
        }
        return .number(op(l, r))
    }

    private func evalDivide(_ lhs: Value, _ rhs: Value) -> Value {
        if let e = propagatedError(lhs, rhs) { return .error(e) }
        guard let l = arithmeticOperand(lhs), let r = arithmeticOperand(rhs) else {
            return .error(.notAvailable)
        }
        if r == 0 { return .error(.divisionByZero) }
        return .number(l / r)
    }

    /// An error in either operand is the result of the whole expression.
    /// Without this a precedent's `#DIV/0!` reached a dependent cell as a
    /// bare non-numeric operand and was reported as `#N/A`, losing the
    /// original cause the user needs in order to find the broken cell.
    private func propagatedError(_ lhs: Value, _ rhs: Value) -> ValueError? {
        if case .error(let e) = lhs { return e }
        if case .error(let e) = rhs { return e }
        return nil
    }

    /// Numeric coercion for arithmetic operands. An empty cell counts as
    /// 0, matching Excel: `=A1+A2` over two blank cells is 0, not `#N/A`.
    /// `asNumber` already coerces numbers, booleans, dates, and numeric
    /// strings.
    private func arithmeticOperand(_ v: Value) -> Double? {
        if case .null = v { return 0 }
        return v.asNumber
    }

    private func evalPower(_ lhs: Value, _ rhs: Value) -> Value {
        guard let l = lhs.asNumber, let r = rhs.asNumber else { return .error(.notAvailable) }
        return .number(pow(l, r))
    }

    // MARK: - Unary Operations

    private func evalUnary(op: UnaryOp, operand: FormulaAST, at addr: CellAddr, sheet: String,
                           depth: Int, engine: SheetEngineCore,
                           env: Environment) throws -> Value {
        let v = try recursiveEvaluate(operand, at: addr, sheet: sheet, depth: depth + 1, engine: engine, env: env)

        switch op {
        case .negate:
            guard let n = v.asNumber else { return .error(.notAvailable) }
            return .number(-n)
        case .positive:
            guard let n = v.asNumber else { return .error(.notAvailable) }
            return .number(n)
        case .percent:
            guard let n = v.asNumber else { return .error(.notAvailable) }
            return .number(n / 100.0)
        }
    }

    // MARK: - Function Calls

    private func evalFunction(name: String, args: [FormulaAST], at addr: CellAddr, sheet: String,
                               depth: Int, engine: SheetEngineCore,
                               env: Environment) throws -> Value {
        let upper = name.uppercased()

        // LET and LAMBDA bind NAMES, so they have to be handled before
        // the arguments are evaluated - evaluating `x` in `LET(x, 5, ...)`
        // would try to resolve it as a named range and fail.
        if upper == "LET" {
            return try evalLet(args: args, at: addr, sheet: sheet, depth: depth, engine: engine, env: env)
        }
        if upper == "LAMBDA" {
            return evalLambdaDefinition(args: args)
        }
        // A name bound to a LAMBDA is callable, which is how a LAMBDA is
        // actually used: LET(dbl, LAMBDA(x, x*2), dbl(21)).
        if case .lambda(let params, let body)? = env[upper] {
            return try applyLambda(
                params: params, body: body, args: args,
                at: addr, sheet: sheet, depth: depth, engine: engine, env: env
            )
        }

        // Evaluate arguments first
        var evaluatedArgs: [Value] = []
        for arg in args {
            let v = try recursiveEvaluate(arg, at: addr, sheet: sheet, depth: depth + 1, engine: engine, env: env)
            evaluatedArgs.append(v)
        }

        // Look up function
        guard let fn = functions.lookup(name) else {
            return .error(.nameInvalid)
        }

        // Check arity
        if let arity = fn.arity {
            if !arity.contains(evaluatedArgs.count) {
                return .error(.notAvailable)
            }
        }

        // Call
        return try fn.call(evaluatedArgs)
    }

    // MARK: - LET / LAMBDA

    /// The NAME a binding argument introduces.
    ///
    /// A bare identifier parses to a named-range marker (a `.cell` whose
    /// address is negative and whose sheet carries `$name`). For a
    /// binding we want that name, not whatever it would resolve to.
    /// Returns nil when the argument is not a plain identifier - e.g.
    /// `LET(A1, ...)`, which Excel also rejects because the name would
    /// be ambiguous with a cell reference.
    private func bindingName(_ ast: FormulaAST) -> String? {
        guard case .cell(let ref) = ast,
              ref.addr.col < 0, ref.addr.row < 0,
              let marker = ref.sheet else { return nil }
        let name = String(marker.dropFirst())
        return name.isEmpty ? nil : name.uppercased()
    }

    /// `LET(name1, value1, [name2, value2, ...], calculation)`.
    ///
    /// Each value is evaluated in the scope built so far, so a later
    /// binding can refer to an earlier one. The final argument is the
    /// expression the whole call returns.
    private func evalLet(args: [FormulaAST], at addr: CellAddr, sheet: String, depth: Int,
                         engine: SheetEngineCore, env: Environment) throws -> Value {
        // (name, value) pairs plus one calculation: an odd count, >= 3.
        guard args.count >= 3, args.count % 2 == 1 else { return .error(.notAvailable) }

        var scope = env
        var index = 0
        while index + 2 < args.count {
            guard let name = bindingName(args[index]) else { return .error(.nameInvalid) }
            scope[name] = try recursiveEvaluate(
                args[index + 1], at: addr, sheet: sheet, depth: depth + 1, engine: engine, env: scope
            )
            index += 2
        }
        return try recursiveEvaluate(
            args[args.count - 1], at: addr, sheet: sheet, depth: depth + 1, engine: engine, env: scope
        )
    }

    /// `LAMBDA(param1, ..., calculation)` - builds the function value.
    /// The body stays unevaluated until the LAMBDA is applied.
    private func evalLambdaDefinition(args: [FormulaAST]) -> Value {
        guard let body = args.last, args.count >= 1 else { return .error(.notAvailable) }
        var params: [String] = []
        for parameter in args.dropLast() {
            guard let name = bindingName(parameter) else { return .error(.nameInvalid) }
            params.append(name)
        }
        return .lambda(params: params, body: body)
    }

    /// Apply a LAMBDA. Arguments are evaluated in the CALLER's scope,
    /// then bound to the parameter names for the body.
    ///
    /// Recursion is bounded by `config.maxCallDepth`, so a LAMBDA that
    /// calls itself without a base case returns `#NUM!` rather than
    /// running away.
    private func applyLambda(params: [String], body: FormulaAST, args: [FormulaAST],
                             at addr: CellAddr, sheet: String, depth: Int,
                             engine: SheetEngineCore, env: Environment) throws -> Value {
        guard params.count == args.count else { return .error(.notAvailable) }
        var scope = env
        for (i, parameter) in params.enumerated() {
            scope[parameter] = try recursiveEvaluate(
                args[i], at: addr, sheet: sheet, depth: depth + 1, engine: engine, env: env
            )
        }
        return try recursiveEvaluate(body, at: addr, sheet: sheet, depth: depth + 1, engine: engine, env: scope)
    }
}

// MARK: - DeterministicConfig

public struct DeterministicConfig: Sendable {
    /// Fixed clock seed — NOW()/TODAY() return values derived from this
    public var clockSeed: UInt64 = 0
    /// Fixed RNG seed — RAND() returns deterministic pseudo-random
    public var rngSeed: UInt64 = 0
    /// Timezone for date functions
    public var timezone: String = "UTC"
    /// RNG state (internal)
    internal var rngState: UInt64 = 0

    public init() {}

    /// Advance the RNG and return the next value in [0, 1)
    internal mutating func nextRandom() -> Double {
        if rngState == 0 { rngState = rngSeed == 0 ? 1 : rngSeed }
        // xorshift64
        var x = rngState
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        rngState = x
        return Double(x & 0x7FFFFFFFFFFFFFFF) / Double(0x7FFFFFFFFFFFFFFF)
    }
}

// MARK: - SheetEngineCore (evaluator context protocol)

/// The subset of SheetEngine needed by the evaluator.
/// This protocol lets us avoid circular dependencies.
public protocol SheetEngineCore {
    func getCellValue(_ addr: CellAddr, sheet: String?) throws -> Value
    /// `fallbackSheet` is the sheet of the formula making the request -
    /// used when `range.sheet` is nil (an unqualified range reference).
    func getRangeValues(_ range: RangeRef, fallbackSheet: String) throws -> [Value]
    /// `fallbackSheet` is the sheet of the formula making the request -
    /// used when the named range itself has no explicit sheet
    /// restriction, mirroring `getRangeValues`'s `fallbackSheet`.
    func resolveNamedRange(_ name: String, at context: CellAddr, fallbackSheet: String) throws -> Value
}
