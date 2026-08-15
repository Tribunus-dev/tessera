//===----------------------------------------------------------------------===//
//  LookupFunctions.swift
//  Tessera Formula Engine
//
//  MATCH / VLOOKUP / HLOOKUP / XLOOKUP / CHOOSE. `INDEX` already existed
//  but is close to unusable without `MATCH`, which is the pairing every
//  model uses to look a value up by key.
//
//  OFFSET / INDIRECT are registered here too (name/arity/volatility
//  metadata only - see the `call` closures below and `Evaluator.evalOffset`/
//  `evalIndirect`, where the real implementation lives): they are the
//  only functions in this registry that resolve a reference against the
//  live sheet rather than computing purely from their already-evaluated
//  `[Value]` arguments.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - 2D view over an argument

/// Row-major view of a range argument. A range reaches a function as one
/// `.array(rows:cols:flat:)`; a scalar is treated as a 1x1 matrix so the
/// lookup functions do not need a separate scalar path.
struct ValueMatrix {
    let rows: Int
    let cols: Int
    let flat: [Value]

    init(_ value: Value) {
        if case .array(let r, let c, let f) = value {
            rows = r
            cols = c
            flat = f
        } else {
            rows = 1
            cols = 1
            flat = [value]
        }
    }

    subscript(row: Int, col: Int) -> Value? {
        guard row >= 0, row < rows, col >= 0, col < cols else { return nil }
        let index = row * cols + col
        guard index >= 0, index < flat.count else { return nil }
        return flat[index]
    }

    /// True when the matrix is a single row or single column, the shape
    /// MATCH and XLOOKUP's lookup array require.
    var isVector: Bool { rows == 1 || cols == 1 }

    var count: Int { flat.count }
}

// MARK: - Comparison

/// Value ordering for lookups. Numbers compare numerically; everything
/// else compares as case-insensitive text, which is Excel's rule for
/// text keys. Mixed number/text ordering is not modelled - Excel sorts
/// numbers before text, and a lookup table mixing them is a modelling
/// error rather than a case worth guessing at.
enum LookupCompare {
    static func equal(_ a: Value, _ b: Value) -> Bool {
        if let x = a.asNumber, let y = b.asNumber { return x == y }
        return a.asString.caseInsensitiveCompare(b.asString) == .orderedSame
    }

    static func lessThan(_ a: Value, _ b: Value) -> Bool {
        if let x = a.asNumber, let y = b.asNumber { return x < y }
        return a.asString.caseInsensitiveCompare(b.asString) == .orderedAscending
    }

    /// Excel wildcard match: `*` any run, `?` one character.
    static func wildcardMatch(_ value: Value, pattern: Value) -> Bool {
        let text = value.asString.lowercased()
        let raw = pattern.asString.lowercased()
        guard raw.contains("*") || raw.contains("?") else {
            return text == raw
        }
        var regex = "^"
        for ch in raw {
            switch ch {
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        regex += "$"
        return text.range(of: regex, options: .regularExpression) != nil
    }
}

// MARK: - Registration

extension FunctionRegistry {

    func registerLookupExtended() {
        registerMatch()
        registerVHLookup()
        registerXLookup()
        registerChoose()
        registerReferenceFunctions()
    }

    // MARK: MATCH

    private func registerMatch() {
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "MATCH",
                description: "Position of a value within a one-row or one-column range.",
                parameters: [
                    FunctionParameter(name: "lookup_value", acceptsRange: false),
                    FunctionParameter(name: "lookup_array"),
                    FunctionParameter(name: "match_type", description: "1 = largest <=, 0 = exact, -1 = smallest >=.", acceptsRange: false, optional: true),
                ]
            ),
            arity: 2...3,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                let needle = args[0]
                let haystack = ValueMatrix(args[1])
                guard haystack.isVector else { return .error(.notAvailable) }
                let matchType = args.count > 2 ? Int(FunctionArgs.number(args[2]) ?? 1) : 1

                switch matchType {
                case 0:
                    for (i, candidate) in haystack.flat.enumerated()
                    where LookupCompare.equal(candidate, needle) {
                        return .number(Double(i + 1))
                    }
                    return .error(.notAvailable)

                case 1:
                    // Ascending data: the largest value <= needle.
                    var best: Int?
                    for (i, candidate) in haystack.flat.enumerated() {
                        if LookupCompare.equal(candidate, needle) { return .number(Double(i + 1)) }
                        if LookupCompare.lessThan(candidate, needle) { best = i }
                    }
                    guard let best else { return .error(.notAvailable) }
                    return .number(Double(best + 1))

                default:
                    // Descending data: the smallest value >= needle.
                    var best: Int?
                    for (i, candidate) in haystack.flat.enumerated() {
                        if LookupCompare.equal(candidate, needle) { return .number(Double(i + 1)) }
                        if LookupCompare.lessThan(needle, candidate) { best = i }
                    }
                    guard let best else { return .error(.notAvailable) }
                    return .number(Double(best + 1))
                }
            }
        ))
    }

    // MARK: VLOOKUP / HLOOKUP

    private func registerVHLookup() {
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "VLOOKUP",
                description: "Looks up a value in the first column of a table and returns a value from another column.",
                parameters: [
                    FunctionParameter(name: "lookup_value", acceptsRange: false),
                    FunctionParameter(name: "table_array"),
                    FunctionParameter(name: "col_index_num", acceptsRange: false),
                    FunctionParameter(name: "range_lookup", description: "TRUE = approximate (default), FALSE = exact.", acceptsRange: false, optional: true),
                ]
            ),
            arity: 3...4,
            call: { args in
                try tableLookup(args, transposed: false)
            }
        ))

        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "HLOOKUP",
                description: "Looks up a value in the first row of a table and returns a value from another row.",
                parameters: [
                    FunctionParameter(name: "lookup_value", acceptsRange: false),
                    FunctionParameter(name: "table_array"),
                    FunctionParameter(name: "row_index_num", acceptsRange: false),
                    FunctionParameter(name: "range_lookup", acceptsRange: false, optional: true),
                ]
            ),
            arity: 3...4,
            call: { args in
                try tableLookup(args, transposed: true)
            }
        ))
    }

    // MARK: XLOOKUP

    private func registerXLookup() {
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "XLOOKUP",
                description: "Searches a range and returns the matching item from a second range.",
                parameters: [
                    FunctionParameter(name: "lookup_value", acceptsRange: false),
                    FunctionParameter(name: "lookup_array"),
                    FunctionParameter(name: "return_array"),
                    FunctionParameter(name: "if_not_found", acceptsRange: false, optional: true),
                    FunctionParameter(name: "match_mode", description: "0 exact, -1 next smaller, 1 next larger, 2 wildcard.", acceptsRange: false, optional: true),
                    FunctionParameter(name: "search_mode", description: "1 first-to-last, -1 last-to-first.", acceptsRange: false, optional: true),
                ]
            ),
            arity: 3...6,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                let needle = args[0]
                let lookup = ValueMatrix(args[1])
                let result = ValueMatrix(args[2])
                guard lookup.isVector, lookup.count == result.count else {
                    return .error(.notAvailable)
                }
                let notFound: Value? = args.count > 3 ? args[3] : nil
                let matchMode = args.count > 4 ? Int(FunctionArgs.number(args[4]) ?? 0) : 0
                let searchMode = args.count > 5 ? Int(FunctionArgs.number(args[5]) ?? 1) : 1

                let order = searchMode == -1
                    ? Array((0..<lookup.count).reversed())
                    : Array(0..<lookup.count)

                // Exact pass first: every mode prefers an exact hit.
                for i in order {
                    let candidate = lookup.flat[i]
                    let hit = matchMode == 2
                        ? LookupCompare.wildcardMatch(candidate, pattern: needle)
                        : LookupCompare.equal(candidate, needle)
                    if hit { return result.flat[i] }
                }

                // Then the directional fallbacks.
                switch matchMode {
                case -1:
                    var best: Int?
                    for i in 0..<lookup.count where LookupCompare.lessThan(lookup.flat[i], needle) {
                        if best == nil || LookupCompare.lessThan(lookup.flat[best!], lookup.flat[i]) { best = i }
                    }
                    if let best { return result.flat[best] }
                case 1:
                    var best: Int?
                    for i in 0..<lookup.count where LookupCompare.lessThan(needle, lookup.flat[i]) {
                        if best == nil || LookupCompare.lessThan(lookup.flat[i], lookup.flat[best!]) { best = i }
                    }
                    if let best { return result.flat[best] }
                default:
                    break
                }

                return notFound ?? .error(.notAvailable)
            }
        ))
    }

    // MARK: CHOOSE

    private func registerChoose() {
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "CHOOSE",
                description: "Selects a value from a list by position.",
                parameters: [
                    FunctionParameter(name: "index_num", acceptsRange: false),
                    FunctionParameter(name: "value1"),
                    FunctionParameter(name: "value2", optional: true, repeatable: true),
                ]
            ),
            arity: 2...255,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                guard let raw = FunctionArgs.number(args[0]) else { return .error(.notAvailable) }
                // Excel truncates toward zero, so 2.9 selects entry 2.
                let index = Int(raw)
                let choices = Array(args.dropFirst())
                guard index >= 1, index <= choices.count else { return .error(.numberInvalid) }
                return choices[index - 1]
            }
        ))
    }

    // MARK: OFFSET / INDIRECT

    /// Registers OFFSET and INDIRECT for name lookup, arity, and
    /// volatility only. `Evaluator.evalFunction` special-cases both
    /// names and never reaches these `call` closures in the live
    /// evaluation path - resolving a reference against the sheet needs
    /// the formula's own AST (OFFSET's `reference` argument) and live
    /// engine access, neither of which `[Value] -> Value` carries. See
    /// `Evaluator.evalOffset`/`evalIndirect` for the real implementation.
    private func registerReferenceFunctions() {
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "OFFSET",
                description: "Returns a reference offset from a starting reference by a number of rows and columns.",
                parameters: [
                    FunctionParameter(name: "reference", description: "The starting reference.", acceptsRange: true),
                    FunctionParameter(name: "rows", description: "Number of rows to shift by.", acceptsRange: false),
                    FunctionParameter(name: "cols", description: "Number of columns to shift by.", acceptsRange: false),
                    FunctionParameter(name: "height", description: "Height of the returned reference. Defaults to the starting reference's own height.", acceptsRange: false, optional: true),
                    FunctionParameter(name: "width", description: "Width of the returned reference. Defaults to the starting reference's own width.", acceptsRange: false, optional: true),
                ],
                volatility: .volatile
            ),
            arity: 3...5,
            call: { _ in .error(.referenceInvalid) }
        ))

        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "INDIRECT",
                description: "Returns the reference named by a text string.",
                parameters: [
                    FunctionParameter(name: "ref_text", description: "An A1-style cell or range reference as text.", acceptsRange: false),
                    FunctionParameter(name: "a1", description: "TRUE or omitted for A1-style (the only style this engine supports).", acceptsRange: false, optional: true),
                ],
                volatility: .volatile
            ),
            arity: 1...2,
            call: { _ in .error(.referenceInvalid) }
        ))
    }
}

// MARK: - Shared VLOOKUP/HLOOKUP body

/// VLOOKUP and HLOOKUP are the same search with the axes swapped.
/// `transposed` selects HLOOKUP (search the first row, return from a row).
private func tableLookup(_ args: [Value], transposed: Bool) throws -> Value {
    if let e = FunctionArgs.firstError(args) { return .error(e) }
    let needle = args[0]
    let table = ValueMatrix(args[1])
    guard let rawIndex = FunctionArgs.number(args[2]) else { return .error(.notAvailable) }
    let index = Int(rawIndex) - 1
    guard index >= 0 else { return .error(.referenceInvalid) }

    // Default TRUE, matching Excel - the source of a great many silent
    // wrong answers, but changing it would silently change results.
    let approximate: Bool = {
        guard args.count > 3 else { return true }
        if case .bool(let b) = args[3] { return b }
        return (FunctionArgs.number(args[3]) ?? 1) != 0
    }()

    let keyCount = transposed ? table.cols : table.rows
    let resultLimit = transposed ? table.rows : table.cols
    guard index < resultLimit else { return .error(.referenceInvalid) }

    func key(_ i: Int) -> Value? { transposed ? table[0, i] : table[i, 0] }
    func result(_ i: Int) -> Value? { transposed ? table[index, i] : table[i, index] }

    if approximate {
        var best: Int?
        for i in 0..<keyCount {
            guard let candidate = key(i) else { continue }
            if LookupCompare.equal(candidate, needle) { return result(i) ?? .error(.referenceInvalid) }
            if LookupCompare.lessThan(candidate, needle) { best = i }
        }
        guard let best, let value = result(best) else { return .error(.notAvailable) }
        return value
    }

    for i in 0..<keyCount {
        guard let candidate = key(i) else { continue }
        if LookupCompare.equal(candidate, needle) {
            return result(i) ?? .error(.referenceInvalid)
        }
    }
    return .error(.notAvailable)
}
