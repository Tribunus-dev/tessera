//===----------------------------------------------------------------------===//
//  Parser.swift
//  Tessera Formula Engine
//
//  Pratt parser for Excel-compatible formula expressions.
//  Handles operator precedence, implicit intersection, named ranges.
//===----------------------------------------------------------------------===//

import Foundation

public final class FormulaParser {
    private var tokens: [Token]
    private var pos: Int = 0

    public enum ParseError: Error, LocalizedError {
        case unexpectedToken(Token, expected: String)
        case unexpectedEndOfInput
        case invalidExpression(String)
        case tooManyTokens
        case maxDepthExceeded

        public var errorDescription: String? {
            switch self {
            case .unexpectedToken(let tok, let expected):
                return "Unexpected token \(tok), expected \(expected)"
            case .unexpectedEndOfInput:
                return "Unexpected end of formula"
            case .invalidExpression(let msg):
                return "Invalid expression: \(msg)"
            case .tooManyTokens:
                return "Formula too complex"
            case .maxDepthExceeded:
                return "Formula too deeply nested"
            }
        }
    }

    public init(tokens: [Token]) {
        self.tokens = tokens
    }

    /// Parse from a string
    public convenience init(source: String) throws {
        let lexer = Lexer(source: source)
        self.init(tokens: try lexer.tokenize())
    }

    // MARK: - Public API

    public func parse() throws -> FormulaParseResult {
        // Single value (no leading "=") or constant expression
        if tokens.isEmpty || (tokens.count == 1 && tokens[0] != .formulaMarker) {
            let expr = try parseExpression()
            if let const = constantValue(expr) { return .value(const) }
            return .formula(Formula(source: sourceFor(tokens), ast: expr))
        }

        // "=" marker → formula
        if tokens[pos] == .formulaMarker {
            pos += 1
        }

        let expr = try parseExpression()

        if pos < tokens.count && tokens[pos] != .eof {
            // Might be a comparison at top level
            if let op = comparisonOp(for: tokens[pos]) {
                let right = try parseComparisonRest(expr, minPrec: op.precedence)
                return .formula(Formula(source: sourceFor(tokens), ast: right))
            }
        }

        // Check if it's a constant (no cells/ranges/functions)
        if let const = constantValue(expr) {
            return .value(const)
        }

        return .formula(Formula(source: sourceFor(tokens), ast: expr))
    }

    /// Parse expecting a formula (not a constant)
    public func parseFormula() throws -> Formula {
        let result = try parse()
        switch result {
        case .formula(let f): return f
        case .value(let v):
            // Constant expression wrapped in a no-op formula
            return Formula(source: "=\(v.description)", ast: .number(0))
        }
    }

    // MARK: - Pratt Parser

    /// Minimum precedence constants
    private static let MIN_PREC = 0

    /// Parse expression with minimum precedence
    private func parseExpression(minPrec: Int = MIN_PREC) throws -> FormulaAST {
        var left = try parseUnary() ?? parsePrimary()

        while true {
            // Check for comparison operators
            if let op = comparisonOp(for: tokens[pos]) {
                if op.precedence < minPrec { break }
                let nextPrec = op.precedence + 1 // right-associative for comparisons
                _ = advance()
                let right = try parseExpression(minPrec: nextPrec)
                left = .binary(op: op, left: left, right: right)
                continue
            }

            // Range operator
            if tokens[pos] == .colon {
                // Check if this is part of a range (cell:cell)
                if let lCell = extractCellRef(from: left) {
                    _ = advance()
                    guard let rightRef = try? parseCellRef() else {
                        throw ParseError.invalidExpression("Expected cell reference after ':'")
                    }
                    let tl = CellAddr(col: Swift.min(lCell.addr.col, rightRef.addr.col),
                                      row: Swift.min(lCell.addr.row, rightRef.addr.row))
                    let br = CellAddr(col: Swift.max(lCell.addr.col, rightRef.addr.col),
                                      row: Swift.max(lCell.addr.row, rightRef.addr.row))
                    left = .range(RangeRef(sheet: lCell.sheet ?? rightRef.sheet,
                                           topLeft: tl, bottomRight: br))
                    continue
                }
            }

            // Binary arithmetic
            if let op = arithmeticOp(for: tokens[pos]) {
                if op.precedence < minPrec { break }
                let nextPrec = op.precedence // left-associative
                _ = advance()
                let right = try parseExpression(minPrec: nextPrec)
                left = .binary(op: op, left: left, right: right)
                continue
            }

            break
        }

        return left
    }

    private func parseComparisonRest(_ left: FormulaAST, minPrec: Int) throws -> FormulaAST {
        guard let op = comparisonOp(for: tokens[pos]) else { return left }
        _ = advance()
        let right = try parseExpression(minPrec: op.precedence + 1)
        return .binary(op: op, left: left, right: right)
    }

    private func parseUnary() throws -> FormulaAST? {
        if tokens[pos] == .minus {
            _ = advance()
            let operand = try parseExpression(minPrec: 10)
            return .unary(op: .negate, operand: operand)
        }
        if tokens[pos] == .plus {
            _ = advance()
            let operand = try parseExpression(minPrec: 10)
            return .unary(op: .positive, operand: operand)
        }
        if tokens[pos] == .percent {
            _ = advance()
            let operand = try parsePrimary()
            return .unary(op: .percent, operand: operand)
        }
        return nil
    }

    private func parsePrimary() throws -> FormulaAST {
        let tok = current

        switch tok {
        case .number(let n):
            _ = advance()
            return .number(n)

        case .string(let s):
            _ = advance()
            return .string(s)

        case .boolLiteral(let b):
            _ = advance()
            return .bool(b)

        case .errorLiteral(let e):
            _ = advance()
            return .error(e)

        case .lbracket:
            return try parseArrayLiteral()

        case .funcName(let name):
            return try parseFunctionCall(name)

        case .lparen:
            _ = advance()
            let inner = try parseExpression()
            try expect(.rparen, message: "')'")
            _ = advance()
            return inner

        case .cellRef(let ref):
            _ = advance()
            return .cell(ref)

        case .rangeRef(let ref):
            _ = advance()
            return .range(ref)

        case .namedRange(let name):
            _ = advance()
            // Defer named range resolution to evaluation time
            // The parser creates a cell ref with the name as sheet (null sheet = local named range)
            // We use a special marker: cell ref with empty sheet → named range
            return .cell(CellRef(sheet: "$\(name)", addr: CellAddr(col: -1, row: -1)))

        case .eof:
            throw ParseError.unexpectedEndOfInput

        default:
            throw ParseError.unexpectedToken(tok, expected: "value, cell reference, or function")
        }
    }

    private func parseFunctionCall(_ name: String) throws -> FormulaAST {
        // We've already consumed the funcName token (which consumed the '(')
        var args: [FormulaAST] = []

        // Handle empty function call: FUNC()
        if tokens[pos] == .rparen {
            _ = advance()
            return .function(name: name, args: args)
        }

        // Parse arguments
        while true {
            args.append(try parseExpression())

            if tokens[pos] == .comma || tokens[pos] == .semicolon {
                _ = advance()
                continue
            }

            break
        }

        try expect(.rparen, message: "')' after function arguments")
        _ = advance()

        return .function(name: name, args: args)
    }

    private func parseArrayLiteral() throws -> FormulaAST {
        try expect(.lbracket, message: "'{'")
        _ = advance()

        var rows: [[FormulaAST]] = []
        while tokens[pos] != .rbracket && tokens[pos] != .eof {
            var row: [FormulaAST] = []
            while tokens[pos] != .comma && tokens[pos] != .semicolon && tokens[pos] != .rbracket && tokens[pos] != .eof {
                row.append(try parseExpression())
            }
            rows.append(row)

            if tokens[pos] == .comma || tokens[pos] == .semicolon {
                _ = advance()
                continue
            }
            break
        }

        try expect(.rbracket, message: "'}'")
        _ = advance()

        return .arrayLiteral(rows)
    }

    // MARK: - Helpers

    private var current: Token { tokens.indices.contains(pos) ? tokens[pos] : .eof }

    @discardableResult
    private func advance() -> Token {
        let tok = current
        if pos < tokens.count { pos += 1 }
        return tok
    }

    private func expect(_ tok: Token, message: String) throws {
        if current != tok {
            throw ParseError.unexpectedToken(current, expected: message)
        }
    }

    private func arithmeticOp(for tok: Token) -> BinaryOp? {
        switch tok {
        case .plus:   return .add
        case .minus:  return .subtract
        case .star:   return .multiply
        case .slash:  return .divide
        case .caret:  return .power
        case .ampersand: return .concat
        case .colon:  return .rangeOp
        default: return nil
        }
    }

    private func comparisonOp(for tok: Token) -> BinaryOp? {
        switch tok {
        case .eq:   return .equal
        case .neq:  return .notEqual
        case .lt:   return .less
        case .gt:   return .greater
        case .lte:  return .lessOrEqual
        case .gte:  return .greaterOrEqual
        default: return nil
        }
    }

    private func extractCellRef(from ast: FormulaAST) -> CellRef? {
        if case .cell(let ref) = ast { return ref }
        return nil
    }

    private func parseCellRef() throws -> CellRef {
        // Called after consuming ':' — the next token should be a cell ref
        let tok = current
        switch tok {
        case .cellRef(let ref):
            _ = advance()
            return ref
        case .namedRange(let name):
            _ = advance()
            // Treat named range as a single-cell ref (deferred to evaluation)
            return CellRef(sheet: "$\(name)", addr: CellAddr(col: -1, row: -1))
        default:
            throw ParseError.unexpectedToken(tok, expected: "cell reference")
        }
    }

    private func sourceFor(_ tokens: [Token]) -> String {
        tokens.filter { if case .eof = $0 { return false }; return true }
               .map { $0.description }
               .joined(separator: " ")
    }

    /// If the given AST is a literal constant, return its Value; otherwise nil.
    private func constantValue(_ ast: FormulaAST) -> Value? {
        switch ast {
        case .number(let n):  return .number(n)
        case .string(let s):  return .string(s)
        case .bool(let b):    return .bool(b)
        case .error(let e):   return .error(e)
        case .null:           return .null
        default:              return nil
        }
    }
}

// MARK: - Convenience

public extension FormulaParser {
    /// Parse a formula string, returning the Formula or throwing.
    static func parse(_ source: String) throws -> Formula {
        try FormulaParser(source: source).parseFormula()
    }

    /// Parse and return either a constant value or a formula.
    static func parseResult(_ source: String) throws -> FormulaParseResult {
        try FormulaParser(source: source).parse()
    }
}
