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
    public func evaluate(_ ast: FormulaAST, at addr: CellAddr, engine: SheetEngineCore) throws -> Value {
        try recursiveEvaluate(ast, at: addr, depth: 0, engine: engine)
    }

    // MARK: - Recursive Evaluation

    private func recursiveEvaluate(_ ast: FormulaAST, at addr: CellAddr,
                                  depth: Int, engine: SheetEngineCore) throws -> Value {
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
                return try engine.resolveNamedRange(name, at: addr)
            }
            return try engine.getCellValue(ref.addr, sheet: ref.sheet)

        case .range(let range):
            // Evaluate to array
            let values = try engine.getRangeValues(range)
            return .array(rows: range.height, cols: range.width, flat: values)

        case .binary(let op, let left, let right):
            return try evalBinary(op: op, left: left, right: right, at: addr, depth: depth, engine: engine)

        case .unary(let op, let operand):
            return try evalUnary(op: op, operand: operand, at: addr, depth: depth, engine: engine)

        case .function(let name, let args):
            return try evalFunction(name: name, args: args, at: addr, depth: depth, engine: engine)

        case .arrayLiteral(let rows):
            var flat: [Value] = []
            for row in rows {
                for cell in row {
                    flat.append(try recursiveEvaluate(cell, at: addr, depth: depth + 1, engine: engine))
                }
            }
            return .array(rows: rows.count, cols: rows.first?.count ?? 0, flat: flat)
        }
    }

    // MARK: - Binary Operations

    private func evalBinary(op: BinaryOp, left: FormulaAST, right: FormulaAST,
                            at addr: CellAddr, depth: Int,
                            engine: SheetEngineCore) throws -> Value {
        let l = try recursiveEvaluate(left, at: addr, depth: depth + 1, engine: engine)
        let r = try recursiveEvaluate(right, at: addr, depth: depth + 1, engine: engine)

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
        if let l = lhs.asNumber, let r = rhs.asNumber {
            return .number(op(l, r))
        }
        if let l = lhs.asNumber, let r = rhs.asNumber {
            return .number(op(l, r))
        }
        // String + number coercion
        if case .string(let s) = lhs, let r = rhs.asNumber {
            if let l = Double(s) { return .number(op(l, r)) }
        }
        if case .string(let s) = rhs, let l = lhs.asNumber {
            if let r = Double(s) { return .number(op(l, r)) }
        }
        return .error(.notAvailable)
    }

    private func evalDivide(_ lhs: Value, _ rhs: Value) -> Value {
        guard let l = lhs.asNumber, let r = rhs.asNumber else { return .error(.notAvailable) }
        if r == 0 { return .error(.divisionByZero) }
        return .number(l / r)
    }

    private func evalPower(_ lhs: Value, _ rhs: Value) -> Value {
        guard let l = lhs.asNumber, let r = rhs.asNumber else { return .error(.notAvailable) }
        return .number(pow(l, r))
    }

    // MARK: - Unary Operations

    private func evalUnary(op: UnaryOp, operand: FormulaAST, at addr: CellAddr,
                           depth: Int, engine: SheetEngineCore) throws -> Value {
        let v = try recursiveEvaluate(operand, at: addr, depth: depth + 1, engine: engine)

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

    private func evalFunction(name: String, args: [FormulaAST], at addr: CellAddr,
                               depth: Int, engine: SheetEngineCore) throws -> Value {
        // Evaluate arguments first
        var evaluatedArgs: [Value] = []
        for arg in args {
            let v = try recursiveEvaluate(arg, at: addr, depth: depth + 1, engine: engine)
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
    func getRangeValues(_ range: RangeRef) throws -> [Value]
    func resolveNamedRange(_ name: String, at context: CellAddr) throws -> Value
}
