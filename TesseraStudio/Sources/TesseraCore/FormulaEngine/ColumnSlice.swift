//===----------------------------------------------------------------------===//
//  ColumnSlice.swift
//  Tessera Formula Engine
//
//  Arrow-inspired columnar storage for efficient range operations.
//  Instead of calling a closure per cell, functions receive typed slices.
//===----------------------------------------------------------------------===//

import Foundation

/// A materialized column slice — the unit of efficient range operations.
/// Built from a sheet region once, then queried multiple times.
/// This is the Arrow-inspired pattern: typed ContiguousArray columns instead of
/// per-cell callbacks.
public struct ColumnSlice: Sendable {
    /// Numeric values (null = empty/non-numeric)
    public let numbers: ContiguousArray<Double?>
    /// String values
    public let strings: ContiguousArray<String?>
    /// Boolean values
    public let bools: ContiguousArray<Bool?>
    /// Error values
    public let errors: ContiguousArray<ValueError?>
    /// Number of cells
    public let count: Int

    public init(numbers: ContiguousArray<Double?>,
                 strings: ContiguousArray<String?>,
                 bools: ContiguousArray<Bool?>,
                 errors: ContiguousArray<ValueError?>) {
        self.numbers = numbers
        self.strings = strings
        self.bools = bools
        self.errors = errors
        self.count = numbers.count
    }

    public var isEmpty: Bool { count == 0 }

    // MARK: - Aggregate operations

    /// Count of non-empty cells (COUNTA)
    public var countNonEmpty: Int {
        var n = 0
        for i in 0..<count {
            if errors[i] != nil || strings[i] != nil || numbers[i] != nil || bools[i] != nil {
                n += 1
            }
        }
        return n
    }

    /// Count of numeric cells (COUNT)
    public var countNumbers: Int {
        var n = 0
        for i in 0..<count {
            if numbers[i] != nil { n += 1 }
        }
        return n
    }

    /// SUM — ignores non-numeric values
    public func sum() -> Double {
        var total: Double = 0
        for i in 0..<count {
            if let n = numbers[i] { total += n }
        }
        return total
    }

    /// AVERAGE — ignores non-numeric, returns nil if no numbers
    public func average() -> Double? {
        var total: Double = 0
        var n = 0
        for i in 0..<count {
            if let v = numbers[i] { total += v; n += 1 }
        }
        return n > 0 ? total / Double(n) : nil
    }

    /// MAX — nil if no numbers
    public func max() -> Double? {
        var result: Double?
        for i in 0..<count {
            if let n = numbers[i] {
                if let r = result { result = Swift.max(r, n) }
                else { result = n }
            }
        }
        return result
    }

    /// MIN — nil if no numbers
    public func min() -> Double? {
        var result: Double?
        for i in 0..<count {
            if let n = numbers[i] {
                if let r = result { result = Swift.min(r, n) }
                else { result = n }
            }
        }
        return result
    }

    /// PRODUCT — ignores non-numeric, returns 1 if no numbers
    public func product() -> Double {
        var result: Double = 1
        var hasNumber = false
        for i in 0..<count {
            if let n = numbers[i] { result *= n; hasNumber = true }
        }
        return hasNumber ? result : 0
    }

    /// Count of TRUE values
    public var countTrue: Int {
        var n = 0
        for i in 0..<count {
            if bools[i] == true { n += 1 }
        }
        return n
    }

    /// Count of FALSE values
    public var countFalse: Int {
        var n = 0
        for i in 0..<count {
            if bools[i] == false { n += 1 }
        }
        return n
    }

    /// LEN (string length) — applied per cell, returns array of lengths
    public func lengths() -> ContiguousArray<Int?> {
        var result = ContiguousArray<Int?>()
        result.reserveCapacity(count)
        for i in 0..<count {
            if let s = strings[i] {
                result.append(s.count)
            } else {
                result.append(nil)
            }
        }
        return result
    }

    /// TRIM — applied per cell
    public func trimmed() -> ContiguousArray<String?> {
        var result = ContiguousArray<String?>()
        result.reserveCapacity(count)
        for i in 0..<count {
            if let s = strings[i] {
                result.append(s.trimmingCharacters(in: .whitespaces))
            } else {
                result.append(nil)
            }
        }
        return result
    }

    /// UPPER — applied per cell
    public func uppercased() -> ContiguousArray<String?> {
        var result = ContiguousArray<String?>()
        result.reserveCapacity(count)
        for i in 0..<count {
            if let s = strings[i] {
                result.append(s.uppercased())
            } else {
                result.append(nil)
            }
        }
        return result
    }

    /// LOWER — applied per cell
    public func lowercased() -> ContiguousArray<String?> {
        var result = ContiguousArray<String?>()
        result.reserveCapacity(count)
        for i in 0..<count {
            if let s = strings[i] {
                result.append(s.lowercased())
            } else {
                result.append(nil)
            }
        }
        return result
    }

    /// SUMIF: sum of numbers where predicate is true
    public func sumWhere(_ predicate: (Double) -> Bool) -> Double {
        var total: Double = 0
        for i in 0..<count {
            if let n = numbers[i], predicate(n) { total += n }
        }
        return total
    }

    /// COUNTIF: count of cells where predicate is true
    public func countWhere(_ predicate: (Double) -> Bool) -> Int {
        var n = 0
        for i in 0..<count {
            if let v = numbers[i], predicate(v) { n += 1 }
        }
        return n
    }

    /// AVERAGEIF: average of numbers where predicate is true
    public func averageWhere(_ predicate: (Double) -> Bool) -> Double? {
        var total: Double = 0
        var n = 0
        for i in 0..<count {
            if let v = numbers[i], predicate(v) { total += v; n += 1 }
        }
        return n > 0 ? total / Double(n) : nil
    }

    /// MAXIF: maximum of numbers where predicate is true
    public func maxWhere(_ predicate: (Double) -> Bool) -> Double? {
        var result: Double?
        for i in 0..<count {
            if let n = numbers[i], predicate(n) {
                if let r = result { result = Swift.max(r, n) }
                else { result = n }
            }
        }
        return result
    }

    /// MINIF: minimum of numbers where predicate is true
    public func minWhere(_ predicate: (Double) -> Bool) -> Double? {
        var result: Double?
        for i in 0..<count {
            if let n = numbers[i], predicate(n) {
                if let r = result { result = Swift.min(r, n) }
                else { result = n }
            }
        }
        return result
    }

    /// Get raw values as [Value]
    public func asValues() -> [Value] {
        var result: [Value] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            if let e = errors[i] { result.append(.error(e)) }
            else if let n = numbers[i] { result.append(.number(n)) }
            else if let b = bools[i] { result.append(.bool(b)) }
            else if let s = strings[i] { result.append(.string(s)) }
            else { result.append(.null) }
        }
        return result
    }

    /// Create from a flat array of Values
    public init(from values: [Value]) {
        self.count = values.count

        var ns = ContiguousArray<Double?>()
        var ss = ContiguousArray<String?>()
        var bs = ContiguousArray<Bool?>()
        var es = ContiguousArray<ValueError?>()
        ns.reserveCapacity(values.count)
        ss.reserveCapacity(values.count)
        bs.reserveCapacity(values.count)
        es.reserveCapacity(values.count)

        for v in values {
            switch v {
            case .null:          ns.append(nil); ss.append(nil); bs.append(nil); es.append(nil)
            case .number(let n): ns.append(n);  ss.append(nil); bs.append(nil); es.append(nil)
            case .bool(let b):   ns.append(nil); ss.append(nil); bs.append(b);   es.append(nil)
            case .string(let s): ns.append(nil); ss.append(s);  bs.append(nil); es.append(nil)
            case .error(let e):  ns.append(nil); ss.append(nil); bs.append(nil); es.append(e)
            case .date(let d):   ns.append(d.timeIntervalSince1970); ss.append(nil); bs.append(nil); es.append(nil)
            case .array:         ns.append(nil); ss.append(nil); bs.append(nil); es.append(nil)
            }
        }
        self.numbers = ns
        self.strings = ss
        self.bools   = bs
        self.errors  = es
    }

    /// Create a flat row-major slice from a 2D range
    public static func flatten(rows: Int, cols: Int, values: [[Value]]) -> ColumnSlice {
        var flatValues: [Value] = []
        flatValues.reserveCapacity(rows * cols)
        for row in values.prefix(rows) {
            for col in row.prefix(cols) {
                flatValues.append(col)
            }
        }
        return ColumnSlice(from: flatValues)
    }
}
