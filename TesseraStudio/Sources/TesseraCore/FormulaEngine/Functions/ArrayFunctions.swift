//===----------------------------------------------------------------------===//
//  ArrayFunctions.swift
//  Tessera Formula Engine
//
//  Dynamic-array functions. These return a whole array from one cell;
//  `SheetEngine` spills it into the neighbouring cells and reports
//  `#SPILL!` when something is in the way.
//===----------------------------------------------------------------------===//

import Foundation

extension FunctionRegistry {

    func registerArray() {
        registerSequence()
        registerTranspose()
        registerUnique()
        registerSort()
        registerFilter()
    }

    // MARK: SEQUENCE

    private func registerSequence() {
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "SEQUENCE",
                description: "Generates a list of sequential numbers.",
                parameters: [
                    FunctionParameter(name: "rows", acceptsRange: false),
                    FunctionParameter(name: "columns", acceptsRange: false, optional: true),
                    FunctionParameter(name: "start", acceptsRange: false, optional: true),
                    FunctionParameter(name: "step", acceptsRange: false, optional: true),
                ]
            ),
            arity: 1...4,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                guard let rawRows = FunctionArgs.number(args[0]) else { return .error(.notAvailable) }
                let rows = Int(rawRows)
                let cols = args.count > 1 ? Int(FunctionArgs.number(args[1]) ?? 1) : 1
                let start = args.count > 2 ? (FunctionArgs.number(args[2]) ?? 1) : 1
                let step = args.count > 3 ? (FunctionArgs.number(args[3]) ?? 1) : 1
                guard rows > 0, cols > 0 else { return .error(.numberInvalid) }
                // Guard against a typo claiming the whole sheet.
                guard rows * cols <= 1_000_000 else { return .error(.numberInvalid) }

                var flat: [Value] = []
                flat.reserveCapacity(rows * cols)
                for i in 0..<(rows * cols) {
                    flat.append(.number(start + Double(i) * step))
                }
                return .array(rows: rows, cols: cols, flat: flat)
            }
        ))
    }

    // MARK: TRANSPOSE

    private func registerTranspose() {
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "TRANSPOSE",
                description: "Flips a range from rows to columns.",
                parameters: [FunctionParameter(name: "array")]
            ),
            arity: 1...1,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                let m = ValueMatrix(args[0])
                var flat: [Value] = []
                flat.reserveCapacity(m.count)
                for c in 0..<m.cols {
                    for r in 0..<m.rows {
                        flat.append(m[r, c] ?? .null)
                    }
                }
                return .array(rows: m.cols, cols: m.rows, flat: flat)
            }
        ))
    }

    // MARK: UNIQUE

    private func registerUnique() {
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "UNIQUE",
                description: "Returns the distinct values from a range.",
                parameters: [
                    FunctionParameter(name: "array"),
                    FunctionParameter(name: "by_col", acceptsRange: false, optional: true),
                    FunctionParameter(name: "exactly_once", description: "TRUE returns only values appearing once.", acceptsRange: false, optional: true),
                ]
            ),
            arity: 1...3,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                let m = ValueMatrix(args[0])
                let exactlyOnce = args.count > 2 && truthy(args[2])

                // Count by case-insensitive text key, matching how the
                // lookup family compares values.
                var order: [Value] = []
                var counts: [String: Int] = [:]
                for value in m.flat {
                    let key = value.asString.lowercased()
                    if counts[key] == nil { order.append(value) }
                    counts[key, default: 0] += 1
                }
                let kept = exactlyOnce
                    ? order.filter { counts[$0.asString.lowercased()] == 1 }
                    : order
                guard !kept.isEmpty else { return .error(.notAvailable) }
                // Preserve the source orientation.
                return m.rows == 1 && m.cols > 1
                    ? .array(rows: 1, cols: kept.count, flat: kept)
                    : .array(rows: kept.count, cols: 1, flat: kept)
            }
        ))
    }

    // MARK: SORT

    private func registerSort() {
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "SORT",
                description: "Sorts the contents of a range.",
                parameters: [
                    FunctionParameter(name: "array"),
                    FunctionParameter(name: "sort_index", description: "1-based column to sort by.", acceptsRange: false, optional: true),
                    FunctionParameter(name: "sort_order", description: "1 ascending (default), -1 descending.", acceptsRange: false, optional: true),
                ]
            ),
            arity: 1...3,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                let m = ValueMatrix(args[0])
                let sortIndex = args.count > 1 ? Int(FunctionArgs.number(args[1]) ?? 1) - 1 : 0
                let descending = args.count > 2 && (FunctionArgs.number(args[2]) ?? 1) < 0
                guard sortIndex >= 0, sortIndex < max(m.cols, 1) else { return .error(.numberInvalid) }

                // Sort whole rows so a multi-column range keeps its
                // records intact.
                var rows: [[Value]] = []
                for r in 0..<m.rows {
                    var row: [Value] = []
                    for c in 0..<m.cols { row.append(m[r, c] ?? .null) }
                    rows.append(row)
                }
                rows.sort { lhs, rhs in
                    let a = lhs.count > sortIndex ? lhs[sortIndex] : .null
                    let b = rhs.count > sortIndex ? rhs[sortIndex] : .null
                    if LookupCompare.equal(a, b) { return false }
                    return descending
                        ? LookupCompare.lessThan(b, a)
                        : LookupCompare.lessThan(a, b)
                }
                return .array(rows: m.rows, cols: m.cols, flat: rows.flatMap { $0 })
            }
        ))
    }

    // MARK: FILTER

    private func registerFilter() {
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "FILTER",
                description: "Returns the rows of a range that meet a condition.",
                parameters: [
                    FunctionParameter(name: "array"),
                    FunctionParameter(name: "include", description: "A column of TRUE/FALSE, one per row."),
                    FunctionParameter(name: "if_empty", acceptsRange: false, optional: true),
                ]
            ),
            arity: 2...3,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                let m = ValueMatrix(args[0])
                let mask = ValueMatrix(args[1])
                guard mask.count == m.rows || mask.count == m.count else {
                    return .error(.notAvailable)
                }

                var kept: [Value] = []
                var keptRows = 0
                for r in 0..<m.rows {
                    let flag = mask.count == m.rows ? mask.flat[r] : mask[r, 0]
                    guard let flag, truthy(flag) else { continue }
                    keptRows += 1
                    for c in 0..<m.cols { kept.append(m[r, c] ?? .null) }
                }
                guard keptRows > 0 else {
                    // Excel returns #CALC! for an empty filter; the closest
                    // error this engine models is #N/A unless the caller
                    // supplied an if_empty fallback.
                    return args.count > 2 ? args[2] : .error(.notAvailable)
                }
                return .array(rows: keptRows, cols: m.cols, flat: kept)
            }
        ))
    }
}

/// Excel truthiness for a flag argument: TRUE, or any non-zero number.
private func truthy(_ value: Value) -> Bool {
    if case .bool(let b) = value { return b }
    if let n = value.asNumber { return n != 0 }
    return false
}
