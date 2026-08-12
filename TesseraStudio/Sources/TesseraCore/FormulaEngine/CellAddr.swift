//===----------------------------------------------------------------------===//
//  CellAddr.swift
//  Tessera Formula Engine
//
//  CellRef, RangeRef, address parsing, column number ↔ letter conversion.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - CellAddr

/// A zero-based cell coordinate — internal representation.
public struct CellAddr: Hashable, Sendable, CustomStringConvertible {
    public let col: Int   // 0-based (0 = column A)
    public let row: Int   // 0-based (0 = row 1)

    public init(col: Int, row: Int) {
        precondition(col >= 0 && row >= 0, "CellAddr must be non-negative")
        self.col = col
        self.row = row
    }

    public var description: String {
        "\(colLetter)\(row + 1)"
    }

    /// Human-readable column letter, e.g. 0 → "A", 25 → "Z", 26 → "AA"
    public var colLetter: String {
        CellAddr.colLetter(for: col)
    }

    /// Convert to an absolute string, e.g. "$A$1"
    public var absolute: String {
        "$\(colLetter)$\(row + 1)"
    }

    /// Linear offset within a sheet (row-major), for cache key
    public func offset(width: Int) -> Int {
        row * width + col
    }

    public static func offset(col: Int, row: Int, width: Int) -> Int {
        row * width + col
    }

    /// Column letter from number: 0→A, 25→Z, 26→AA, 27→AB ...
    public static func colLetter(for col: Int) -> String {
        var n = col
        var result = ""
        while n >= 0 {
            result = String(UnicodeScalar(65 + n % 26)!) + result
            n = n / 26 - 1
            if n < 0 { break }
        }
        return result
    }

    /// Column number from letter: "A"→0, "Z"→25, "AA"→26, "AB"→27 ...
    public static func colNumber(for letter: String) -> Int? {
        var result = 0
        for ch in letter.uppercased() {
            guard let ascii = ch.asciiValue, ascii >= 65, ascii <= 90 else { return nil }
            result = result * 26 + Int(ascii - 65) + 1
        }
        return result - 1
    }
}

// MARK: - CellRef

/// A cell reference as found in a formula — may include sheet qualifier, absolute markers.
/// Examples: "A1", "$B$5", "Sheet2!C3", "'My Sheet'!$D7", "'[Book.xlsx]Sheet1'!$E$8"
public struct CellRef: Hashable, Sendable, CustomStringConvertible {
    public let sheet: String?       // nil = same sheet
    public let colAbsolute: Bool
    public let rowAbsolute: Bool
    public let addr: CellAddr

    public init(sheet: String? = nil, colAbsolute: Bool = false, rowAbsolute: Bool = false, addr: CellAddr) {
        self.sheet = sheet
        self.colAbsolute = colAbsolute
        self.rowAbsolute = rowAbsolute
        self.addr = addr
    }

    public init(sheet: String? = nil, col: Int, row: Int,
                colAbsolute: Bool = false, rowAbsolute: Bool = false) {
        self.sheet = sheet
        self.colAbsolute = colAbsolute
        self.rowAbsolute = rowAbsolute
        self.addr = CellAddr(col: col, row: row)
    }

    public var description: String {
        var s = sheet.map { "\($0)!" } ?? ""
        s += colAbsolute ? "$\(addr.colLetter)" : addr.colLetter
        s += rowAbsolute ? "$\(addr.row + 1)" : "\(addr.row + 1)"
        return s
    }

    /// Whether this ref refers to a different sheet
    public var isExternal: Bool {
        guard let sheet = sheet else { return false }
        return sheet.contains("[") || !sheet.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Resolves absolute/relative refs against a base position (for copying formulas)
    public func resolved(baseCol: Int, baseRow: Int) -> CellRef {
        CellRef(
            sheet: sheet,
            col: colAbsolute ? addr.col : addr.col - baseCol + addr.col,
            row: rowAbsolute ? addr.row : addr.row - baseRow + addr.row,
            colAbsolute: colAbsolute,
            rowAbsolute: rowAbsolute
        )
    }
}

// MARK: - RangeRef

/// A rectangular range, e.g. "A1:B10", "Sheet2!$C$5:$D$15"
public struct RangeRef: Hashable, Sendable, CustomStringConvertible {
    public let sheet: String?
    public let topLeft: CellAddr
    public let bottomRight: CellAddr

    public init(sheet: String? = nil, topLeft: CellAddr, bottomRight: CellAddr) {
        self.sheet = sheet
        self.topLeft = topLeft
        self.bottomRight = bottomRight
    }

    public var width:  Int { bottomRight.col - topLeft.col + 1 }
    public var height: Int { bottomRight.row - topLeft.row + 1 }
    public var isSingleCell: Bool { topLeft == bottomRight }

    public var description: String {
        let s = sheet.map { "\($0)!" } ?? ""
        return "\(s)\(topLeft.colLetter)\(topLeft.row + 1):\(bottomRight.colLetter)\(bottomRight.row + 1)"
    }

    /// Iterate all cells in row-major order
    public func cells() -> [CellAddr] {
        var result: [CellAddr] = []
        for row in topLeft.row...bottomRight.row {
            for col in topLeft.col...bottomRight.col {
                result.append(CellAddr(col: col, row: row))
            }
        }
        return result
    }

    /// Iterate all cells with their row-major index
    public func enumeratedCells() -> [(index: Int, addr: CellAddr)] {
        var result: [(Int, CellAddr)] = []
        var idx = 0
        for row in topLeft.row...bottomRight.row {
            for col in topLeft.col...bottomRight.col {
                result.append((idx, CellAddr(col: col, row: row)))
                idx += 1
            }
        }
        return result
    }

    /// Check if a cell is within this range
    public func contains(_ addr: CellAddr) -> Bool {
        addr.col >= topLeft.col && addr.col <= bottomRight.col &&
        addr.row >= topLeft.row && addr.row <= bottomRight.row
    }
}

// MARK: - Address Parser

/// Parses cell and range address strings into typed structs.
public enum AddressParser {
    private static let cellPattern = try! NSRegularExpression(
        // Groups: 1=sheet(!), 2=$col, 3=col, 4=$row, 5=row
        pattern: #"^((?:'[^']*'|[^\s!])+!)?(\\$?)([A-Za-z]+)(\\$?)(\d+)$"#,
        options: []
    )

    private static let rangePattern = try! NSRegularExpression(
        pattern: #"^((?:'[^']*'|[^\s!])+!)?(\\$?[A-Za-z]+\\$?\d+):(\\$?[A-Za-z]+\\$?\d+)$"#,
        options: []
    )

    public enum ParseError: Error, LocalizedError {
        case invalidCell(String)
        case invalidRange(String)
        case invalidSheetName(String)

        public var errorDescription: String? {
            switch self {
            case .invalidCell(let s):  return "Invalid cell reference: \(s)"
            case .invalidRange(let s): return "Invalid range reference: \(s)"
            case .invalidSheetName(let s): return "Invalid sheet name: \(s)"
            }
        }
    }

    /// Parse a cell reference string: "A1", "$B5", "Sheet2!C3", "'My Sheet'!$D$7"
    public static func parseCell(_ s: String) throws -> CellRef {
        let s = s.trimmingCharacters(in: .whitespaces)
        let range = NSRange(s.startIndex..., in: s)

        guard let match = cellPattern.firstMatch(in: s, options: [], range: range) else {
            throw ParseError.invalidCell(s)
        }

        // Extract sheet
        var sheet: String? = nil
        if match.range(at: 1).location != NSNotFound,
           let sheetRange = Range(match.range(at: 1), in: s) {
            var sheetStr = String(s[sheetRange])
            sheetStr.removeLast() // remove trailing !
            sheet = unescapeSheetName(sheetStr)
        }

        // Extract absolute flags and values
        let colAbsolute = match.range(at: 2).location != NSNotFound
        let rowAbsolute = match.range(at: 4).location != NSNotFound

        guard let colRange = Range(match.range(at: 3), in: s),
              let rowRange = Range(match.range(at: 5), in: s),
              let colNum = CellAddr.colNumber(for: String(s[colRange])),
              let rowNum = Int(s[rowRange]) else {
            throw ParseError.invalidCell(s)
        }

        return CellRef(
            sheet: sheet,
            col: colNum,
            row: rowNum - 1,
            colAbsolute: colAbsolute,
            rowAbsolute: rowAbsolute
        )
    }

    /// Parse a range reference string: "A1:B10", "Sheet2!$C$5:$D$15"
    public static func parseRange(_ s: String) throws -> RangeRef {
        let s = s.trimmingCharacters(in: .whitespaces)
        let range = NSRange(s.startIndex..., in: s)

        guard let match = rangePattern.firstMatch(in: s, options: [], range: range) else {
            throw ParseError.invalidRange(s)
        }

        // Extract sheet
        var sheet: String? = nil
        if match.range(at: 1).location != NSNotFound,
           let sheetRange = Range(match.range(at: 1), in: s) {
            var sheetStr = String(s[sheetRange])
            sheetStr.removeLast()
            sheet = unescapeSheetName(sheetStr)
        }

        guard let tlRange = Range(match.range(at: 2), in: s),
              let brRange = Range(match.range(at: 3), in: s) else {
            throw ParseError.invalidRange(s)
        }

        let topLeft    = try parseCell(String(s[tlRange]))
        let bottomRight = try parseCell(String(s[brRange]))

        // Normalize: always put smaller addr at top-left
        let tlAddr = CellAddr(
            col: Swift.min(topLeft.addr.col, bottomRight.addr.col),
            row: Swift.min(topLeft.addr.row, bottomRight.addr.row)
        )
        let brAddr = CellAddr(
            col: Swift.max(topLeft.addr.col, bottomRight.addr.col),
            row: Swift.max(topLeft.addr.row, bottomRight.addr.row)
        )

        return RangeRef(sheet: sheet ?? topLeft.sheet, topLeft: tlAddr, bottomRight: brAddr)
    }

    /// Unescape sheet names: 'Sheet''s Name' → Sheet's Name
    private static func unescapeSheetName(_ s: String) -> String {
        if s.hasPrefix("'") && s.hasSuffix("'") {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return s
    }

    /// Escaped form of a sheet name
    public static func escapeSheetName(_ s: String) -> String {
        if s.contains("'") || s.contains("!") || s.contains("[") || s.contains("]") {
            let escaped = s.replacingOccurrences(of: "'", with: "''")
            return "'\(escaped)'"
        }
        return s
    }

    /// Parse either a cell or range reference
    public static func parse(_ s: String) throws -> Either<CellRef, RangeRef> {
        if let cell = try? parseCell(s) {
            return .a(cell)
        }
        return .b(try parseRange(s))
    }

    public enum Either<A, B> {
        case a(A)
        case b(B)
    }
}
