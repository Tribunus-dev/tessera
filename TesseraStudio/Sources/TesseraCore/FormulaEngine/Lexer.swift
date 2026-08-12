//===----------------------------------------------------------------------===//
//  Lexer.swift
//  Tessera Formula Engine
//
//  Tokenizer for Excel-compatible formula expressions.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Token

public enum Token: Equatable, Sendable, CustomStringConvertible {
    case formulaMarker          // the "=" at the start
    case number(Double)
    case string(String)        // "quoted string"
    case boolLiteral(Bool)     // TRUE, FALSE
    case errorLiteral(ValueError)
    case cellRef(CellRef)
    case rangeRef(RangeRef)
    case namedRange(String)
    case funcName(String)
    case lparen              // (
    case rparen              // )
    case lbracket            // {
    case rbracket            // }
    case comma               // ,
    case semicolon           // ; (union in some locales, argument separator in others)
    case colon               // : (range operator)
    case bang                // ! (sheet separator)
    case dot                 // . (named range separator)
    case amp                 // & (concatenation)
    case caret               // ^ (power)
    case star                // *
    case slash               // /
    case minus               // -
    case plus                // +
    case percent              // %
    case lt                  // <
    case gt                  // >
    case lte                  // <=
    case gte                  // >=
    case eq                  // =
    case neq                 // <>  (must check before < and >)
    case ampersand           // &  (concat)
    case eof

    public var description: String {
        switch self {
        case .formulaMarker:   return "="
        case .number(let n):  return "\(n)"
        case .string(let s):   return "\"\(s)\""
        case .boolLiteral(let b): return b ? "TRUE" : "FALSE"
        case .errorLiteral(let e): return e.displayString
        case .cellRef(let r): return r.description
        case .rangeRef(let r): return r.description
        case .namedRange(let n): return n
        case .funcName(let f): return "\(f)("
        case .lparen:  return "("
        case .rparen:  return ")"
        case .lbracket: return "{"
        case .rbracket: return "}"
        case .comma:    return ","
        case .semicolon: return ";"
        case .colon:    return ":"
        case .bang:     return "!"
        case .dot:      return "."
        case .amp:      return "&"
        case .caret:    return "^"
        case .star:     return "*"
        case .slash:    return "/"
        case .minus:    return "-"
        case .plus:     return "+"
        case .percent:  return "%"
        case .lt:       return "<"
        case .gt:       return ">"
        case .lte:      return "<="
        case .gte:      return ">="
        case .eq:       return "="
        case .neq:      return "<>"
        case .ampersand: return "&"
        case .eof:      return "<EOF>"
        }
    }

    /// True for tokens that terminate an operand (start a new one)
    public var isOperandTerminator: Bool {
        switch self {
        case .number, .string, .boolLiteral, .errorLiteral,
             .cellRef, .rangeRef, .namedRange, .rparen, .rbracket:
            return true
        default:
            return false
        }
    }

    /// True for tokens that can follow an operand without a binary operator (implicit intersection)
    public var isOperandFollower: Bool {
        switch self {
        case .cellRef, .rangeRef, .namedRange: return true
        default: return false
        }
    }
}

// MARK: - Lexer

public final class Lexer {
    private let source: String
    private var pos: String.Index
    private var currentLine: Int = 1
    private var currentCol: Int = 1

    public init(source: String) {
        self.source = source.hasPrefix("=") ? String(source.dropFirst()) : source
        self.pos = self.source.startIndex
    }

    public struct LexError: Error, LocalizedError {
        public let position: Int
        public let line: Int
        public let column: Int
        public let message: String

        public var errorDescription: String? {
            "Lexer error at line \(line), col \(column): \(message)"
        }
    }

    public func tokenize() throws -> [Token] {
        var tokens: [Token] = []

        while !isAtEnd {
            skipWhitespace()
            if isAtEnd { break }

            let startLine = currentLine
            let startCol  = currentCol
            let tok = try scanToken()

            if case .eof = tok { break }
            tokens.append(tok)
        }

        tokens.append(.eof)
        return tokens
    }

    private var isAtEnd: Bool { pos >= source.endIndex }

    private var currentChar: Character? {
        isAtEnd ? nil : source[pos]
    }

    private func advance() -> Character {
        let ch = source[pos]
        pos = source.index(after: pos)
        if ch == "\n" {
            currentLine += 1
            currentCol = 1
        } else {
            currentCol += 1
        }
        return ch
    }

    private func peek(_ offset: Int = 0) -> Character? {
        let idx = source.index(pos, offsetBy: offset, limitedBy: source.endIndex) ?? source.endIndex
        return idx < source.endIndex ? source[idx] : nil
    }

    private func advanceIf(_ ch: Character) -> Bool {
        guard currentChar == ch else { return false }
        _ = advance()
        return true
    }

    private func skipWhitespace() {
        while let ch = currentChar, ch.isWhitespace && ch != "\n" {
            _ = advance()
        }
    }

    private func scanToken() throws -> Token {
        let startLine = currentLine
        let startCol  = currentCol
        let ch = currentChar!

        switch ch {
        // Single-char operators
        case "+": _ = advance(); return .plus
        case "-": _ = advance(); return .minus
        case "*": _ = advance(); return .star
        case "/": _ = advance(); return .slash
        case "^": _ = advance(); return .caret
        case "%": _ = advance(); return .percent
        case "(": _ = advance(); return .lparen
        case ")": _ = advance(); return .rparen
        case "{": _ = advance(); return .lbracket
        case "}": _ = advance(); return .rbracket
        case ",": _ = advance(); return .comma
        case ";": _ = advance(); return .semicolon
        case ":": _ = advance(); return .colon
        case "!": _ = advance(); return .bang
        case ".": _ = advance(); return .dot
        case "&": _ = advance(); return .ampersand
        case "$": return try scanDollarRef()
        case "'": return try scanQuotedSheetRef()
        case "\"": return try scanString()
        case "#": return try scanError()
        case "=": _ = advance(); return .eq
        case "<": return try scanLt()
        case ">": return try scanGt()
        default:
            if ch.isNumber { return try scanNumber() }
            if ch.isLetter || ch == "_" { return try scanIdentifier() }
            throw LexError(position: startCol, line: startLine, column: startCol,
                           message: "Unexpected character '\(ch)'")
        }
    }

    // $A1, A$1, $A$1
    private func scanDollarRef() throws -> Token {
        _ = advance() // consume $
        guard let ch = currentChar else {
            throw LexError(position: currentCol, line: currentLine, column: currentCol,
                           message: "Unexpected end after $")
        }
        if ch.isLetter {
            return try scanCellRef(colAbsolute: true)
        }
        throw LexError(position: currentCol, line: currentLine, column: currentCol,
                       message: "Unexpected '$'")
    }

    // 'Sheet Name'!A1
    private func scanQuotedSheetRef() throws -> Token {
        _ = advance() // consume opening '
        var sheetName = ""
        while let ch = currentChar, ch != "'" {
            if ch == "\n" {
                throw LexError(position: currentCol, line: currentLine, column: currentCol,
                               message: "Unterminated sheet name")
            }
            if ch == "'", peek() == "'" {
                sheetName.append("'")
                _ = advance(); _ = advance()
            } else {
                sheetName.append(ch)
                _ = advance()
            }
        }
        guard currentChar == "'" else {
            throw LexError(position: currentCol, line: currentLine, column: currentCol,
                           message: "Unterminated sheet name")
        }
        _ = advance() // consume closing '

        guard currentChar == "!" else {
            throw LexError(position: currentCol, line: currentLine, column: currentCol,
                           message: "Expected '!' after sheet name")
        }
        _ = advance() // consume !

        // Now scan the cell ref with the sheet prefix
        return try scanCellRef(sheet: sheetName)
    }

    // Numbers: 3.14, .5, 1e10, 1.5e-3
    private func scanNumber() throws -> Token {
        var digits = ""

        // Integer part
        while let ch = currentChar, ch.isNumber {
            digits.append(ch)
            _ = advance()
        }

        // Decimal part
        if currentChar == "." {
            let next = peek(1)
            if let n = next, n.isNumber {
                digits.append(advance()) // consume .
                while let ch = currentChar, ch.isNumber {
                    digits.append(ch)
                    _ = advance()
                }
            }
        }

        // Exponent
        if let ch = currentChar, ch == "e" || ch == "E" {
            let next = peek(1)
            if let n = next, n.isNumber || n == "+" || n == "-" {
                digits.append(advance())
                if let sign = currentChar, sign == "+" || sign == "-" {
                    digits.append(advance())
                }
                while let ch = currentChar, ch.isNumber {
                    digits.append(ch)
                    _ = advance()
                }
            }
        }

        guard let value = Double(digits) else {
            throw LexError(position: currentCol - digits.count, line: currentLine, column: currentCol - digits.count,
                           message: "Invalid number: \(digits)")
        }

        return .number(value)
    }

    // Strings: "hello ""world"""
    private func scanString() throws -> Token {
        _ = advance() // consume opening "
        var content = ""
        while let ch = currentChar, ch != "\"" {
            if ch == "\n" {
                throw LexError(position: currentCol, line: currentLine, column: currentCol,
                               message: "Unterminated string literal")
            }
            if ch == "\"", peek() == "\"" {
                content.append("\"")
                _ = advance(); _ = advance()
            } else {
                content.append(ch)
                _ = advance()
            }
        }
        guard currentChar == "\"" else {
            throw LexError(position: currentCol, line: currentLine, column: currentCol,
                           message: "Unterminated string literal")
        }
        _ = advance() // consume closing "
        return .string(content)
    }

    // Error literals: #DIV/0!, #NAME?, etc.
    private func scanError() throws -> Token {
        var errorStr = ""
        while let ch = currentChar, ch != " " && ch != ")" && ch != "+" && ch != "-" && ch != "*" && ch != "/" {
            errorStr.append(ch)
            _ = advance()
        }
        if let err = ValueError(rawValue: errorStr) {
            return .errorLiteral(err)
        }
        return .namedRange(errorStr) // unknown #word → treat as named range
    }

    // <, <=, <>
    private func scanLt() throws -> Token {
        _ = advance()
        if currentChar == "=" {
            _ = advance()
            return .lte
        }
        if currentChar == ">" {
            _ = advance()
            return .neq
        }
        return .lt
    }

    // >, >=
    private func scanGt() throws -> Token {
        _ = advance()
        if currentChar == "=" {
            _ = advance()
            return .gte
        }
        return .gt
    }

    // Identifiers: cell refs, named ranges, function names, TRUE/FALSE
    private func scanIdentifier() throws -> Token {
        var name = ""
        while let ch = currentChar,
              ch.isLetter || ch.isNumber || ch == "_" || ch == "." {
            name.append(ch)
            _ = advance()
        }

        let upper = name.uppercased()

        // Boolean literals
        if upper == "TRUE"  { return .boolLiteral(true) }
        if upper == "FALSE" { return .boolLiteral(false) }

        // Check what's next: ( → function, : or alphanumeric → could be range/named
        skipWhitespace()
        let next = currentChar

        if next == "(" {
            // Function call
            _ = advance() // consume (
            // Put back the lparen as a separate token
            return .funcName(upper)
        }

        if next == ":" {
            // Range operator: A1:B5
            return try scanRangeRef(prefix: name)
        }

        // Named range or cell ref — defer to parser
        return .namedRange(upper)
    }

    // A1:B5, $A1:B$5, etc.
    private func scanCellRef(colAbsolute: Bool = false, sheet: String? = nil) throws -> Token {
        // Column letters
        var colPart = ""
        while let ch = currentChar, ch.isLetter {
            colPart.append(ch)
            _ = advance()
        }
        guard let colNum = CellAddr.colNumber(for: colPart) else {
            throw LexError(position: currentCol - colPart.count, line: currentLine,
                           column: currentCol - colPart.count,
                           message: "Invalid column '\(colPart)'")
        }

        // Row number
        var rowPart = ""
        if currentChar == "$" {
            _ = advance()
        }
        while let ch = currentChar, ch.isNumber {
            rowPart.append(ch)
            _ = advance()
        }
        guard let rowNum = Int(rowPart), rowNum > 0 else {
            throw LexError(position: currentCol - rowPart.count, line: currentLine,
                           column: currentCol - rowPart.count,
                           message: "Invalid row '\(rowPart)'")
        }

        let addr = CellAddr(col: colNum, row: rowNum - 1)
        let ref = CellRef(sheet: sheet, col: colNum, row: rowNum - 1,
                          colAbsolute: colAbsolute, rowAbsolute: false)
        _ = ref // silence unused

        return .cellRef(ref)
    }

    // Name:range or Name:Name — a range reference
    private func scanRangeRef(prefix: String) throws -> Token {
        // prefix is the first ref, consume ':', then scan second ref
        _ = advance() // consume :

        var name2 = ""
        while let ch = currentChar,
              ch.isLetter || ch.isNumber || ch == "_" || ch == "." {
            name2.append(ch)
            _ = advance()
        }

        let upper1 = prefix.uppercased()
        let upper2 = name2.uppercased()

        let topLeft = try AddressParser.parseCell(upper1).addr
        let bottomRight = try AddressParser.parseCell(upper2).addr

        let tl = CellAddr(col: Swift.min(topLeft.col, bottomRight.col),
                          row: Swift.min(topLeft.row, bottomRight.row))
        let br = CellAddr(col: Swift.max(topLeft.col, bottomRight.col),
                          row: Swift.max(topLeft.row, bottomRight.row))

        return .rangeRef(RangeRef(sheet: nil, topLeft: tl, bottomRight: br))
    }
}
