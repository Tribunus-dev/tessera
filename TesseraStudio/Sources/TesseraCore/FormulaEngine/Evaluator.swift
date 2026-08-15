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
        let l = try evaluateScalarOperand(left, at: addr, sheet: sheet, depth: depth, engine: engine, env: env)
        let r = try evaluateScalarOperand(right, at: addr, sheet: sheet, depth: depth, engine: engine, env: env)
        // Shared with TokenArrayEvaluator's RPN stack machine
        // (TokenArray.swift) - see BinaryEvaluator's doc comment.
        return BinaryEvaluator.apply(op, l, r)
    }

    // MARK: - Unary Operations

    private func evalUnary(op: UnaryOp, operand: FormulaAST, at addr: CellAddr, sheet: String,
                           depth: Int, engine: SheetEngineCore,
                           env: Environment) throws -> Value {
        let v = try evaluateScalarOperand(operand, at: addr, sheet: sheet, depth: depth, engine: engine, env: env)
        return UnaryEvaluator.apply(op, v)
    }

    // MARK: - Implicit intersection

    /// Evaluate an AST node that a scalar context expects - an
    /// arithmetic/comparison/unary operand, or (from `evalFunction`) a
    /// function argument whose parameter does not accept a range.
    ///
    /// A literal range reference reduces via implicit intersection (`@`
    /// in Excel's modern engine): the single cell at the intersection of
    /// the range and the formula's own row/column. Anything else - a
    /// cell reference, a nested function call, a named range - carries
    /// no absolute sheet position of its own to intersect against and
    /// evaluates normally, matching Excel's restriction of implicit
    /// intersection to a literal range.
    private func evaluateScalarOperand(_ ast: FormulaAST, at addr: CellAddr, sheet: String, depth: Int,
                                       engine: SheetEngineCore, env: Environment) throws -> Value {
        if case .range(let range) = ast {
            return try implicitIntersection(range, at: addr, sheet: sheet, engine: engine)
        }
        return try recursiveEvaluate(ast, at: addr, sheet: sheet, depth: depth + 1, engine: engine, env: env)
    }

    /// Reduce `range` to the single cell at its intersection with `addr`:
    /// a single-column range picks the cell on `addr`'s row, a
    /// single-row range picks the cell on `addr`'s column, and a 2D
    /// range picks `addr` itself only when `addr` falls inside it.
    ///
    /// No intersection -> `.notAvailable`. This engine has no `#VALUE!`
    /// case (see `ValueError` in TypeSystem.swift) - every function's own
    /// "wrong argument shape" error already uses `.notAvailable`, so this
    /// matches that convention instead of inventing a new error case for
    /// one caller. A cross-sheet range has no row/column of `sheet`'s own
    /// to align against, so it never intersects.
    private func implicitIntersection(_ range: RangeRef, at addr: CellAddr, sheet: String,
                                      engine: SheetEngineCore) throws -> Value {
        let targetSheet = range.sheet ?? sheet
        guard targetSheet == sheet else { return .error(.notAvailable) }

        if range.width == 1 {
            guard range.topLeft.row <= addr.row, addr.row <= range.bottomRight.row else { return .error(.notAvailable) }
            return try engine.getCellValue(CellAddr(col: range.topLeft.col, row: addr.row), sheet: targetSheet)
        }
        if range.height == 1 {
            guard range.topLeft.col <= addr.col, addr.col <= range.bottomRight.col else { return .error(.notAvailable) }
            return try engine.getCellValue(CellAddr(col: addr.col, row: range.topLeft.row), sheet: targetSheet)
        }
        guard range.contains(addr) else { return .error(.notAvailable) }
        return try engine.getCellValue(addr, sheet: targetSheet)
    }

    /// Whether the function parameter at `argIndex` accepts a
    /// range/array argument as-is (no implicit-intersection reduction).
    /// An argument beyond the declared parameter list falls back to the
    /// LAST parameter when it is `repeatable` (SUM's trailing
    /// `number2, number3, ...`); a function with no declared parameters
    /// defaults permissive, matching `FunctionParameter`'s own default.
    private func parameterAcceptsRange(_ fn: BuiltInFunction, argIndex: Int) -> Bool {
        let params = fn.signature.parameters
        guard !params.isEmpty else { return true }
        if argIndex < params.count { return params[argIndex].acceptsRange }
        return params.last?.acceptsRange ?? true
    }

    // MARK: - OFFSET / INDIRECT

    /// `OFFSET(reference, rows, cols, [height], [width])` - the value(s)
    /// at `reference` shifted by `rows`/`cols` from its own top-left,
    /// sized `height` x `width` (defaulting to `reference`'s own
    /// dimensions). Special-cased here rather than dispatched through
    /// `FunctionRegistry` (like LET/LAMBDA below): every other function
    /// call flows through `fn.call([Value]) -> Value`, but OFFSET needs
    /// `reference`'s own ABSOLUTE SHEET POSITION - already lost by the
    /// time a `.range` AST evaluates to a flattened `.array` - plus live
    /// engine access to read the shifted target, neither of which that
    /// signature carries.
    ///
    /// `reference` must be a literal cell or range AST node - the only
    /// shape carrying a fixed position to offset from. A reference
    /// produced by a nested function call (including OFFSET/INDIRECT
    /// themselves) or a named range is Excel's fuller "any
    /// reference-returning expression" generality, deliberately cut for
    /// a minimal-but-correct pass: `#REF!`.
    ///
    /// Volatile: `FormulaAST.containsVolatileFunction` already lists
    /// OFFSET by name, so `DependencyGraph` recalculates a formula
    /// containing it on every pass regardless of static precedents -
    /// necessary because its target cell is resolved at evaluation time,
    /// not visible to the graph's own precedent scan.
    private func evalOffset(args: [FormulaAST], at addr: CellAddr, sheet: String, depth: Int,
                            engine: SheetEngineCore, env: Environment) throws -> Value {
        guard args.count >= 3, args.count <= 5 else { return .error(.notAvailable) }
        guard let base = literalReference(args[0], sheet: sheet) else { return .error(.referenceInvalid) }

        let rowsVal = try recursiveEvaluate(args[1], at: addr, sheet: sheet, depth: depth + 1, engine: engine, env: env)
        let colsVal = try recursiveEvaluate(args[2], at: addr, sheet: sheet, depth: depth + 1, engine: engine, env: env)
        guard let rowShift = FunctionArgs.number(rowsVal), let colShift = FunctionArgs.number(colsVal) else {
            return .error(.notAvailable)
        }

        var height = base.height
        var width = base.width
        if args.count >= 4 {
            let hVal = try recursiveEvaluate(args[3], at: addr, sheet: sheet, depth: depth + 1, engine: engine, env: env)
            guard let h = FunctionArgs.number(hVal), h >= 1 else { return .error(.referenceInvalid) }
            height = Int(h)
        }
        if args.count >= 5 {
            let wVal = try recursiveEvaluate(args[4], at: addr, sheet: sheet, depth: depth + 1, engine: engine, env: env)
            guard let w = FunctionArgs.number(wVal), w >= 1 else { return .error(.referenceInvalid) }
            width = Int(w)
        }

        let newCol = base.topLeft.col + Int(colShift)
        let newRow = base.topLeft.row + Int(rowShift)
        guard newCol >= 0, newRow >= 0 else { return .error(.referenceInvalid) }

        let targetSheet = base.sheet ?? sheet
        if height == 1 && width == 1 {
            return try engine.getCellValue(CellAddr(col: newCol, row: newRow), sheet: targetSheet)
        }
        let range = RangeRef(
            sheet: targetSheet,
            topLeft: CellAddr(col: newCol, row: newRow),
            bottomRight: CellAddr(col: newCol + width - 1, row: newRow + height - 1)
        )
        let values = try engine.getRangeValues(range, fallbackSheet: sheet)
        return .array(rows: height, cols: width, flat: values)
    }

    /// The structural (unevaluated) reference a literal `.cell` or
    /// `.range` AST node names - `topLeft == bottomRight` for a single
    /// cell. Nil for anything else (a named-range marker, a function
    /// call, ...): those carry no fixed sheet position for OFFSET to
    /// shift from.
    private func literalReference(_ ast: FormulaAST, sheet: String) -> RangeRef? {
        switch ast {
        case .cell(let ref) where ref.addr.col >= 0 && ref.addr.row >= 0:
            return RangeRef(sheet: ref.sheet ?? sheet, topLeft: ref.addr, bottomRight: ref.addr)
        case .range(let range):
            return RangeRef(sheet: range.sheet ?? sheet, topLeft: range.topLeft, bottomRight: range.bottomRight)
        default:
            return nil
        }
    }

    /// `INDIRECT(ref_text, [a1])` - parses `ref_text` as an A1-style
    /// cell or range reference and returns the value(s) there.
    ///
    /// `a1` (TRUE/omitted = A1 style, FALSE = R1C1) is accepted for
    /// arity but not acted on: `AddressParser` (CellAddr.swift) has no
    /// R1C1 support anywhere in this engine yet, so there is no second
    /// style to switch to. It is still evaluated, so a genuine error
    /// inside it (not the R1C1/A1 choice itself) still propagates like
    /// any other argument's would.
    ///
    /// Volatile for the same reason as OFFSET - see `evalOffset`.
    private func evalIndirect(args: [FormulaAST], at addr: CellAddr, sheet: String, depth: Int,
                              engine: SheetEngineCore, env: Environment) throws -> Value {
        guard args.count == 1 || args.count == 2 else { return .error(.notAvailable) }
        let refVal = try recursiveEvaluate(args[0], at: addr, sheet: sheet, depth: depth + 1, engine: engine, env: env)
        if case .error(let e) = refVal { return .error(e) }
        if args.count == 2 {
            let a1Val = try recursiveEvaluate(args[1], at: addr, sheet: sheet, depth: depth + 1, engine: engine, env: env)
            if case .error(let e) = a1Val, e.isPropagating { return .error(e) }
        }
        let text = refVal.asString

        // `AddressParser`'s range pattern requires a literal ":", so it
        // never matches a bare cell string - trying it first is safe
        // and covers "A1:B5" before falling back to a single cell.
        if let range = try? AddressParser.parseRange(text) {
            let targetSheet = range.sheet ?? sheet
            if range.isSingleCell {
                return try engine.getCellValue(range.topLeft, sheet: targetSheet)
            }
            let values = try engine.getRangeValues(range, fallbackSheet: sheet)
            return .array(rows: range.height, cols: range.width, flat: values)
        }
        if let cell = try? AddressParser.parseCell(text) {
            return try engine.getCellValue(cell.addr, sheet: cell.sheet ?? sheet)
        }
        return .error(.referenceInvalid)
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

        // OFFSET/INDIRECT need reference/engine access the generic
        // `fn.call([Value]) -> Value` dispatch below cannot carry - see
        // `evalOffset`'s doc comment. Both are still registered in
        // `FunctionRegistry` (name/arity/volatility metadata), just not
        // dispatched through it.
        if upper == "OFFSET" {
            return try evalOffset(args: args, at: addr, sheet: sheet, depth: depth, engine: engine, env: env)
        }
        if upper == "INDIRECT" {
            return try evalIndirect(args: args, at: addr, sheet: sheet, depth: depth, engine: engine, env: env)
        }

        // Look up function first: implicit intersection below needs to
        // know, per argument, whether the matching parameter accepts a
        // range - that comes from the function's OWN signature, so the
        // function has to be resolved before its arguments are evaluated.
        guard let fn = functions.lookup(name) else {
            return .error(.nameInvalid)
        }

        // Evaluate arguments, reducing a literal range argument via
        // implicit intersection wherever its parameter does not accept
        // one (`acceptsRange == false`) - see `evaluateScalarOperand`.
        var evaluatedArgs: [Value] = []
        for (i, arg) in args.enumerated() {
            let v: Value
            if !parameterAcceptsRange(fn, argIndex: i) {
                v = try evaluateScalarOperand(arg, at: addr, sheet: sheet, depth: depth, engine: engine, env: env)
            } else {
                v = try recursiveEvaluate(arg, at: addr, sheet: sheet, depth: depth + 1, engine: engine, env: env)
            }
            evaluatedArgs.append(v)
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
