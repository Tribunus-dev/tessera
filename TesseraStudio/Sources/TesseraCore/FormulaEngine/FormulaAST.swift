//===----------------------------------------------------------------------===//
//  FormulaAST.swift
//  Tessera Formula Engine
//
//  Immutable AST nodes for formula expressions.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - FormulaAST

/// Immutable AST node for a formula expression.
public indirect enum FormulaAST: Equatable, Sendable, CustomStringConvertible {
    case number(Double)
    case string(String)
    case bool(Bool)
    case error(ValueError)
    case null
    case cell(CellRef)
    case range(RangeRef)
    case binary(op: BinaryOp, left: FormulaAST, right: FormulaAST)
    case unary(op: UnaryOp, operand: FormulaAST)
    case function(name: String, args: [FormulaAST])
    case arrayLiteral([[FormulaAST]])

    public var description: String {
        switch self {
        case .number(let n): return n.description
        case .string(let s): return "\"\(s)\""
        case .bool(let b):   return b ? "TRUE" : "FALSE"
        case .error(let e):  return e.displayString
        case .null:          return "NULL"
        case .cell(let r):   return r.description
        case .range(let r):  return r.description
        case .binary(let op, let l, let r):
            return "(\(l) \(op.rawValue) \(r))"
        case .unary(let op, let o):
            return "(\(op.rawValue)\(o))"
        case .function(let name, let args):
            let argsStr = args.map { $0.description }.joined(separator: ", ")
            return "\(name)(\(argsStr))"
        case .arrayLiteral(let rows):
            let rowStrs = rows.map { row in
                row.map { $0.description }.joined(separator: ", ")
            }
            return "{ " + rowStrs.joined(separator: "; ") + " }"
        }
    }

    /// Collect all cell references in this AST
    public func collectCells() -> Set<CellRef> {
        var cells = Set<CellRef>()
        collectCells(into: &cells)
        return cells
    }

    private func collectCells(into set: inout Set<CellRef>) {
        switch self {
        case .cell(let r): set.insert(r)
        case .range(let r):
            for addr in r.cells() {
                set.insert(CellRef(addr: addr))
            }
        case .binary(_, let l, let r):
            l.collectCells(into: &set)
            r.collectCells(into: &set)
        case .unary(_, let o):
            o.collectCells(into: &set)
        case .function(_, let args):
            for arg in args { arg.collectCells(into: &set) }
        case .arrayLiteral(let rows):
            for row in rows { for cell in row { cell.collectCells(into: &set) } }
        default:
            break
        }
    }

    /// Collect all range references in this AST
    public func collectRanges() -> Set<RangeRef> {
        var ranges = Set<RangeRef>()
        collectRanges(into: &ranges)
        return ranges
    }

    private func collectRanges(into set: inout Set<RangeRef>) {
        switch self {
        case .range(let r): set.insert(r)
        case .binary(_, let l, let r):
            l.collectRanges(into: &set)
            r.collectRanges(into: &set)
        case .unary(_, let o):
            o.collectRanges(into: &set)
        case .function(_, let args):
            for arg in args { arg.collectRanges(into: &set) }
        case .arrayLiteral(let rows):
            for row in rows { for cell in row { cell.collectRanges(into: &set) } }
        default:
            break
        }
    }

    /// Collect all named ranges in this AST
    public func collectNamedRanges() -> Set<String> {
        var names = Set<String>()
        collectNamedRanges(into: &names)
        return names
    }

    private func collectNamedRanges(into set: inout Set<String>) {
        switch self {
        case .cell(let r):
            // Cells with no name → not named ranges
            break
        case .function(let name, let args):
            if !args.isEmpty { /* function name, not a named range */ }
            for arg in args { arg.collectNamedRanges(into: &set) }
        case .binary(_, let l, let r):
            l.collectNamedRanges(into: &set)
            r.collectNamedRanges(into: &set)
        case .unary(_, let o):
            o.collectNamedRanges(into: &set)
        case .arrayLiteral(let rows):
            for row in rows { for cell in row { cell.collectNamedRanges(into: &set) } }
        default:
            break
        }
    }

    /// Collect all function names in this AST
    public func collectFunctionNames() -> Set<String> {
        var names = Set<String>()
        collectFunctionNames(into: &names)
        return names
    }

    private func collectFunctionNames(into set: inout Set<String>) {
        switch self {
        case .function(let name, let args):
            set.insert(name)
            for arg in args { arg.collectFunctionNames(into: &set) }
        case .binary(_, let l, let r):
            l.collectFunctionNames(into: &set)
            r.collectFunctionNames(into: &set)
        case .unary(_, let o):
            o.collectFunctionNames(into: &set)
        case .arrayLiteral(let rows):
            for row in rows { for cell in row { cell.collectFunctionNames(into: &set) } }
        default:
            break
        }
    }

    /// True if the AST contains a volatile function (NOW, TODAY, RAND, OFFSET, INDIRECT)
    public var containsVolatileFunction: Bool {
        switch self {
        case .function(let name, _):
            let volatile = ["NOW", "TODAY", "RAND", "RANDBETWEEN", "OFFSET", "INDIRECT", "INFO"]
            return volatile.contains(name.uppercased())
        case .binary(_, let l, let r):
            return l.containsVolatileFunction || r.containsVolatileFunction
        case .unary(_, let o):
            return o.containsVolatileFunction
        case .function(_, let args):
            return args.contains { $0.containsVolatileFunction }
        case .arrayLiteral(let rows):
            return rows.flatMap { $0 }.contains { $0.containsVolatileFunction }
        default:
            return false
        }
    }
}

// MARK: - Formula

/// A formula with source tracking, unique identity, and AST.
public struct Formula: Equatable, Sendable, CustomStringConvertible {
    public let id: UUID
    public let source: String          // original text: "=SUM(A1:A10)"
    public let ast: FormulaAST
    public let functionNames: Set<String>
    public let referencedCells: Set<CellRef>
    public let referencedRanges: Set<RangeRef>
    public let referencedNames: Set<String>
    public let isVolatile: Bool

    public init(source: String, ast: FormulaAST) {
        self.id = UUID()
        self.source = source
        self.ast = ast
        self.functionNames = ast.collectFunctionNames()
        self.referencedCells = ast.collectCells()
        self.referencedRanges = ast.collectRanges()
        self.referencedNames = ast.collectNamedRanges()
        self.isVolatile = ast.containsVolatileFunction
    }

    public var description: String { source }

    /// All cells this formula depends on (from ranges expanded)
    public var allPrecedents: Set<CellAddr> {
        var addrs = Set<CellAddr>()
        for cell in referencedCells { addrs.insert(cell.addr) }
        for range in referencedRanges {
            for addr in range.cells() { addrs.insert(addr) }
        }
        return addrs
    }
}

// MARK: - Formula Parse Result

public enum FormulaParseResult {
    case value(Value)           // constant expression
    case formula(Formula)       // actual formula

    public var formula: Formula? {
        if case .formula(let f) = self { return f }
        return nil
    }

    public var value: Value? {
        if case .value(let v) = self { return v }
        return nil
    }
}
