//===----------------------------------------------------------------------===//
//  FunctionRegistry.swift
//  Tessera Formula Engine
//
//  Function signature metadata and dispatcher.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Function Volatility

public enum FunctionVolatility: Sendable {
    case notVolatile
    case volatile  // NOW, TODAY, RAND, OFFSET, INDIRECT, INFO
}

// MARK: - Parameter

public struct FunctionParameter: Equatable, Sendable {
    public let name: String
    public let description: String
    public let acceptsRange: Bool
    public let optional: Bool
    public let repeatable: Bool  // func(a, b, ...)

    public init(name: String, description: String = "",
                acceptsRange: Bool = true,
                optional: Bool = false,
                repeatable: Bool = false) {
        self.name = name
        self.description = description
        self.acceptsRange = acceptsRange
        self.optional = optional
        self.repeatable = repeatable
    }
}

// MARK: - Function Signature

public struct FunctionSignature: Equatable, Sendable {
    public let name: String
    public let description: String
    public let parameters: [FunctionParameter]
    public let volatility: FunctionVolatility

    public init(name: String, description: String = "",
                parameters: [FunctionParameter] = [],
                volatility: FunctionVolatility = .notVolatile) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.volatility = volatility
    }
}

// MARK: - BuiltInFunction

/// A callable built-in function with its signature and implementation.
public struct BuiltInFunction: Sendable {
    public let signature: FunctionSignature
    public let arity: ClosedRange<Int>?  // nil = any, e.g. 1...Int.max for SUM
    public let call: ([Value]) throws -> Value

    public init(signature: FunctionSignature,
                arity: ClosedRange<Int>? = 1...1,
                call: @escaping ([Value]) throws -> Value) {
        self.signature = signature
        self.arity = arity
        self.call = call
    }
}

// MARK: - FunctionRegistry

/// Global registry of built-in Excel functions.
public final class FunctionRegistry: Sendable {
    public static let shared = FunctionRegistry()

    private var functions: [String: BuiltInFunction] = [:]

    private init() {
        registerAll()
    }

    /// Look up a function by name (case-insensitive).
    public func lookup(_ name: String) -> BuiltInFunction? {
        functions[name.uppercased()]
    }

    /// True if the function is registered.
    public func contains(_ name: String) -> Bool {
        lookup(name) != nil
    }

    /// All registered function names.
    public var allNames: [String] {
        Array(functions.keys).sorted()
    }

    /// Register a custom function (overrides built-in).
    public func register(_ fn: BuiltInFunction) {
        functions[fn.signature.name.uppercased()] = fn
    }

    /// Register all built-in functions.
    private func registerAll() {
        registerAggregate()
        registerMath()
        registerLogic()
        registerText()
        registerDate()
        registerType()
        registerLookup()
    }

    // MARK: - Aggregate Functions

    private func registerAggregate() {
        // SUM
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "SUM",
                description: "Adds all the numbers in a range of cells.",
                parameters: [
                    FunctionParameter(name: "number1", description: "The first number or range to add.", acceptsRange: true),
                    FunctionParameter(name: "number2", description: "Additional numbers or ranges.", acceptsRange: true, optional: true, repeatable: true)
                ]
            ),
            arity: 1...255,
            call: { args in
                let slice = ColumnSlice(from: args)
                return .number(slice.sum())
            }
        ))

        // AVERAGE
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "AVERAGE",
                description: "Returns the average of the arguments.",
                parameters: [
                    FunctionParameter(name: "number1", description: "The first range or number.", acceptsRange: true),
                    FunctionParameter(name: "number2", description: "Additional ranges or numbers.", acceptsRange: true, optional: true, repeatable: true)
                ]
            ),
            arity: 1...255,
            call: { args in
                let slice = ColumnSlice(from: args)
                guard let avg = slice.average() else { return .error(.notAvailable) }
                return .number(avg)
            }
        ))

        // COUNT
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "COUNT",
                description: "Counts how many numbers are in the list of arguments.",
                parameters: [
                    FunctionParameter(name: "value1", description: "First range or value.", acceptsRange: true),
                    FunctionParameter(name: "value2", description: "Additional ranges or values.", acceptsRange: true, optional: true, repeatable: true)
                ]
            ),
            arity: 1...255,
            call: { args in
                let slice = ColumnSlice(from: args)
                return .number(Double(slice.countNumbers))
            }
        ))

        // COUNTA
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "COUNTA",
                description: "Counts the number of non-empty values in a range.",
                parameters: [
                    FunctionParameter(name: "value1", description: "First range or value.", acceptsRange: true),
                    FunctionParameter(name: "value2", description: "Additional ranges or values.", acceptsRange: true, optional: true, repeatable: true)
                ]
            ),
            arity: 1...255,
            call: { args in
                let slice = ColumnSlice(from: args)
                return .number(Double(slice.countNonEmpty))
            }
        ))

        // MAX
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "MAX",
                description: "Returns the largest value in a set of values.",
                parameters: [
                    FunctionParameter(name: "number1", description: "First range or number.", acceptsRange: true),
                    FunctionParameter(name: "number2", description: "Additional ranges or numbers.", acceptsRange: true, optional: true, repeatable: true)
                ]
            ),
            arity: 1...255,
            call: { args in
                let slice = ColumnSlice(from: args)
                guard let max = slice.max() else { return .number(0) }
                return .number(max)
            }
        ))

        // MIN
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "MIN",
                description: "Returns the smallest number in a set of values.",
                parameters: [
                    FunctionParameter(name: "number1", description: "First range or number.", acceptsRange: true),
                    FunctionParameter(name: "number2", description: "Additional ranges or numbers.", acceptsRange: true, optional: true, repeatable: true)
                ]
            ),
            arity: 1...255,
            call: { args in
                let slice = ColumnSlice(from: args)
                guard let min = slice.min() else { return .number(0) }
                return .number(min)
            }
        ))

        // PRODUCT
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "PRODUCT",
                description: "Multiplies all the numbers given as arguments.",
                parameters: [
                    FunctionParameter(name: "number1", description: "First number or range.", acceptsRange: true),
                    FunctionParameter(name: "number2", description: "Additional numbers or ranges.", acceptsRange: true, optional: true, repeatable: true)
                ]
            ),
            arity: 1...255,
            call: { args in
                let slice = ColumnSlice(from: args)
                return .number(slice.product())
            }
        ))

        // ABS
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "ABS",
                description: "Returns the absolute value of a number.",
                parameters: [FunctionParameter(name: "number", description: "The number to get the absolute value of.")]
            ),
            arity: 1...1,
            call: { args in
                guard let n = args.first?.asNumber else { return .error(.notAvailable) }
                return .number(abs(n))
            }
        ))

        // ROUND
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "ROUND",
                description: "Rounds a number to a specified number of digits.",
                parameters: [
                    FunctionParameter(name: "number", description: "The number to round."),
                    FunctionParameter(name: "num_digits", description: "The number of digits to round to.")
                ]
            ),
            arity: 2...2,
            call: { args in
                guard args.count == 2,
                      let n = args[0].asNumber,
                      let digits = args[1].asNumber else { return .error(.notAvailable) }
                let multiplier = pow(10.0, digits)
                return .number((n * multiplier).rounded() / multiplier)
            }
        ))

        // SQRT
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "SQRT",
                description: "Returns the square root of a number.",
                parameters: [FunctionParameter(name: "number", description: "The number to get the square root of.")]
            ),
            arity: 1...1,
            call: { args in
                guard let n = args.first?.asNumber else { return .error(.notAvailable) }
                if n < 0 { return .error(.numberInvalid) }
                return .number(sqrt(n))
            }
        ))

        // MOD
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "MOD",
                description: "Returns the remainder after division.",
                parameters: [
                    FunctionParameter(name: "number", description: "The number to divide."),
                    FunctionParameter(name: "divisor", description: "The number to divide by.")
                ]
            ),
            arity: 2...2,
            call: { args in
                guard args.count == 2,
                      let n = args[0].asNumber,
                      let d = args[1].asNumber else { return .error(.notAvailable) }
                if d == 0 { return .error(.divisionByZero) }
                return .number(n.truncatingRemainder(dividingBy: d))
            }
        ))

        // POWER
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "POWER",
                description: "Returns the result of a number raised to a power.",
                parameters: [
                    FunctionParameter(name: "number", description: "The base number."),
                    FunctionParameter(name: "power", description: "The exponent.")
                ]
            ),
            arity: 2...2,
            call: { args in
                guard args.count == 2,
                      let base = args[0].asNumber,
                      let exp = args[1].asNumber else { return .error(.notAvailable) }
                return .number(pow(base, exp))
            }
        ))

        // PI
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "PI",
                description: "Returns the value of Pi.",
                parameters: []
            ),
            arity: 0...0,
            call: { _ in .number(Double.pi) }
        ))

        // TRUE / FALSE
        register(BuiltInFunction(
            signature: FunctionSignature(name: "TRUE", description: "Returns the logical value TRUE."),
            arity: 0...0,
            call: { _ in .bool(true) }
        ))
        register(BuiltInFunction(
            signature: FunctionSignature(name: "FALSE", description: "Returns the logical value FALSE."),
            arity: 0...0,
            call: { _ in .bool(false) }
        ))
    }

    // MARK: - Math Functions

    private func registerMath() {
        // INT
        register(BuiltInFunction(
            signature: FunctionSignature(name: "INT", description: "Rounds a number down to the nearest integer."),
            arity: 1...1,
            call: { args in
                guard let n = args.first?.asNumber else { return .error(.notAvailable) }
                return .number(floor(n))
            }
        ))

        // ROUNDUP
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "ROUNDUP",
                description: "Rounds a number up, away from zero.",
                parameters: [FunctionParameter(name: "number"), FunctionParameter(name: "num_digits")]
            ),
            arity: 2...2,
            call: { args in
                guard args.count == 2,
                      let n = args[0].asNumber,
                      let d = args[1].asNumber else { return .error(.notAvailable) }
                let multiplier = pow(10.0, d)
                return .number(n >= 0 ? ceil(n * multiplier) / multiplier : floor(n * multiplier) / multiplier)
            }
        ))

        // ROUNDDOWN
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "ROUNDDOWN",
                description: "Rounds a number down, toward zero.",
                parameters: [FunctionParameter(name: "number"), FunctionParameter(name: "num_digits")]
            ),
            arity: 2...2,
            call: { args in
                guard args.count == 2,
                      let n = args[0].asNumber,
                      let d = args[1].asNumber else { return .error(.notAvailable) }
                let multiplier = pow(10.0, d)
                return .number(n >= 0 ? floor(n * multiplier) / multiplier : ceil(n * multiplier) / multiplier)
            }
        ))

        // LOG
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "LOG",
                description: "Returns the logarithm of a number.",
                parameters: [
                    FunctionParameter(name: "number"),
                    FunctionParameter(name: "base", optional: true)
                ]
            ),
            arity: 1...2,
            call: { args in
                guard let n = args[0].asNumber, n > 0 else { return .error(.numberInvalid) }
                if args.count == 1 { return .number(log(n)) }
                guard let b = args[1].asNumber, b > 0, b != 1 else { return .error(.numberInvalid) }
                return .number(log(n) / log(b))
            }
        ))

        // LOG10
        register(BuiltInFunction(
            signature: FunctionSignature(name: "LOG10", description: "Returns the base-10 logarithm."),
            arity: 1...1,
            call: { args in
                guard let n = args.first?.asNumber, n > 0 else { return .error(.numberInvalid) }
                return .number(log10(n))
            }
        ))

        // LN
        register(BuiltInFunction(
            signature: FunctionSignature(name: "LN", description: "Returns the natural logarithm."),
            arity: 1...1,
            call: { args in
                guard let n = args.first?.asNumber, n > 0 else { return .error(.numberInvalid) }
                return .number(log(n))
            }
        ))

        // EXP
        register(BuiltInFunction(
            signature: FunctionSignature(name: "EXP", description: "Returns e raised to a power."),
            arity: 1...1,
            call: { args in
                guard let n = args.first?.asNumber else { return .error(.notAvailable) }
                return .number(exp(n))
            }
        ))

        // SIGN
        register(BuiltInFunction(
            signature: FunctionSignature(name: "SIGN", description: "Returns the sign of a number."),
            arity: 1...1,
            call: { args in
                guard let n = args.first?.asNumber else { return .error(.notAvailable) }
                if n > 0 { return .number(1) }
                if n < 0 { return .number(-1) }
                return .number(0)
            }
        ))

        // CEILING
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "CEILING",
                description: "Rounds a number up to the nearest multiple of significance.",
                parameters: [
                    FunctionParameter(name: "number"),
                    FunctionParameter(name: "significance", optional: true)
                ]
            ),
            arity: 1...2,
            call: { args in
                guard let n = args[0].asNumber else { return .error(.notAvailable) }
                let sig = args.count > 1 ? (args[1].asNumber ?? 1) : 1
                if sig == 0 { return .number(0) }
                return .number(ceil(n / abs(sig)) * abs(sig))
            }
        ))

        // FLOOR
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "FLOOR",
                description: "Rounds a number down to the nearest multiple of significance.",
                parameters: [
                    FunctionParameter(name: "number"),
                    FunctionParameter(name: "significance", optional: true)
                ]
            ),
            arity: 1...2,
            call: { args in
                guard let n = args[0].asNumber else { return .error(.notAvailable) }
                let sig = args.count > 1 ? (args[1].asNumber ?? 1) : 1
                if sig == 0 { return .number(0) }
                return .number(floor(n / abs(sig)) * abs(sig))
            }
        ))

        // SUMIF
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "SUMIF",
                description: "Sums the values in a range that meet criteria.",
                parameters: [
                    FunctionParameter(name: "range", description: "The range to evaluate.", acceptsRange: true),
                    FunctionParameter(name: "criteria", description: "The criteria (number, text, or expression)."),
                    FunctionParameter(name: "sum_range", description: "The range to sum.", acceptsRange: true, optional: true)
                ]
            ),
            arity: 2...3,
            call: { args in
                guard args.count >= 2 else { return .error(.notAvailable) }
                // Simplified: SUMIF(range, criteria, [sum_range])
                // args[0] = range, args[1] = criteria, args[2] = sum_range (defaults to range)
                let values = self.flattenArg(args[0])
                let criteria = args[1]
                let sumValues = args.count > 2 ? self.flattenArg(args[2]) : values

                // Simple numeric comparison criteria
                var total: Double = 0
                for i in 0..<Swift.min(values.count, sumValues.count) {
                    let v = sumValues[i]
                    if self.matchesCriteria(values[i], criteria) {
                        if let n = v.asNumber { total += n }
                    }
                }
                return .number(total)
            }
        ))

        // COUNTIF
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "COUNTIF",
                description: "Counts cells that meet a criteria.",
                parameters: [
                    FunctionParameter(name: "range", description: "The range to evaluate.", acceptsRange: true),
                    FunctionParameter(name: "criteria", description: "The criteria.")
                ]
            ),
            arity: 2...2,
            call: { args in
                guard args.count == 2 else { return .error(.notAvailable) }
                let values = self.flattenArg(args[0])
                let criteria = args[1]
                var count = 0
                for v in values {
                    if self.matchesCriteria(v, criteria) { count += 1 }
                }
                return .number(Double(count))
            }
        ))
    }

    // MARK: - Logic Functions

    private func registerLogic() {
        // AND
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "AND",
                description: "Returns TRUE if all arguments are TRUE.",
                parameters: [
                    FunctionParameter(name: "logical1", description: "First condition."),
                    FunctionParameter(name: "logical2", description: "Additional conditions.", optional: true, repeatable: true)
                ]
            ),
            arity: 1...255,
            call: { args in
                for arg in args {
                    if case .bool(false) = arg { return .bool(false) }
                    if case .error(let e) = arg, e.isPropagating { return .error(e) }
                }
                return .bool(true)
            }
        ))

        // OR
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "OR",
                description: "Returns TRUE if any argument is TRUE.",
                parameters: [
                    FunctionParameter(name: "logical1", description: "First condition."),
                    FunctionParameter(name: "logical2", description: "Additional conditions.", optional: true, repeatable: true)
                ]
            ),
            arity: 1...255,
            call: { args in
                for arg in args {
                    if case .bool(true) = arg { return .bool(true) }
                    if case .error(let e) = arg, e.isPropagating { return .error(e) }
                }
                return .bool(false)
            }
        ))

        // NOT
        register(BuiltInFunction(
            signature: FunctionSignature(name: "NOT", description: "Reverses the logic of its argument."),
            arity: 1...1,
            call: { args in
                if case .bool(let b) = args.first { return .bool(!b) }
                if case .error(let e) = args.first, e.isPropagating { return .error(e) }
                return .error(.notAvailable)
            }
        ))

        // IF
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "IF",
                description: "Returns one value if a condition is TRUE, another if FALSE.",
                parameters: [
                    FunctionParameter(name: "logical_test", description: "The condition to test."),
                    FunctionParameter(name: "value_if_true", description: "Value to return if TRUE."),
                    FunctionParameter(name: "value_if_false", description: "Value to return if FALSE.", optional: true)
                ]
            ),
            arity: 2...3,
            call: { args in
                let condition = args[0]
                if case .error(let e) = condition, e.isPropagating { return .error(e) }
                let truthy = condition.asBool
                if truthy {
                    return args.count > 1 ? args[1] : .bool(true)
                } else {
                    return args.count > 2 ? args[2] : .bool(false)
                }
            }
        ))

        // IFERROR
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "IFERROR",
                description: "Returns a value if no error, otherwise returns the value_if_error.",
                parameters: [
                    FunctionParameter(name: "value", description: "The value to check."),
                    FunctionParameter(name: "value_if_error", description: "Value to return if error.")
                ]
            ),
            arity: 2...2,
            call: { args in
                if case .error = args.first { return args[1] }
                return args.first ?? .null
            }
        ))

        // IFNA
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "IFNA",
                description: "Returns a value if not #N/A, otherwise returns the value_if_na.",
                parameters: [
                    FunctionParameter(name: "value", description: "The value to check."),
                    FunctionParameter(name: "value_if_na", description: "Value to return if #N/A.")
                ]
            ),
            arity: 2...2,
            call: { args in
                if case .error(.notAvailable) = args.first { return args[1] }
                return args.first ?? .null
            }
        ))

        // XOR
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "XOR",
                description: "Returns TRUE if an odd number of arguments are TRUE.",
                parameters: [
                    FunctionParameter(name: "logical1", description: "First condition."),
                    FunctionParameter(name: "logical2", description: "Additional conditions.", optional: true, repeatable: true)
                ]
            ),
            arity: 1...255,
            call: { args in
                var trueCount = 0
                for arg in args {
                    if case .bool(true) = arg { trueCount += 1 }
                    if case .error(let e) = arg, e.isPropagating { return .error(e) }
                }
                return .bool(trueCount % 2 == 1)
            }
        ))
    }

    // MARK: - Text Functions

    private func registerText() {
        // CONCATENATE / CONCAT
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "CONCATENATE",
                description: "Joins several text strings into one.",
                parameters: [
                    FunctionParameter(name: "text1", description: "First text string."),
                    FunctionParameter(name: "text2", description: "Additional text strings.", optional: true, repeatable: true)
                ]
            ),
            arity: 1...255,
            call: { args in
                let result = args.map { $0.asString }.joined()
                return .string(result)
            }
        ))
        register(BuiltInFunction(
            signature: FunctionSignature(name: "CONCAT", description: "Joins text strings."),
            arity: 1...255,
            call: { args in
                let result = args.map { $0.asString }.joined()
                return .string(result)
            }
        ))

        // LEN
        register(BuiltInFunction(
            signature: FunctionSignature(name: "LEN", description: "Returns the number of characters in a text string."),
            arity: 1...1,
            call: { args in
                guard let s = args.first?.asString else { return .error(.notAvailable) }
                return .number(Double(s.count))
            }
        ))

        // LEFT
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "LEFT",
                description: "Returns the leftmost characters from a text value.",
                parameters: [
                    FunctionParameter(name: "text", description: "The text string."),
                    FunctionParameter(name: "num_chars", description: "Number of characters.", optional: true)
                ]
            ),
            arity: 1...2,
            call: { args in
                guard let s = args.first?.asString else { return .error(.notAvailable) }
                let n = args.count > 1 ? Int(args[1].asNumber ?? 1) : 1
                if n >= s.count { return .string(s) }
                return .string(String(s.prefix(n)))
            }
        ))

        // RIGHT
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "RIGHT",
                description: "Returns the rightmost characters from a text value.",
                parameters: [
                    FunctionParameter(name: "text", description: "The text string."),
                    FunctionParameter(name: "num_chars", description: "Number of characters.", optional: true)
                ]
            ),
            arity: 1...2,
            call: { args in
                guard let s = args.first?.asString else { return .error(.notAvailable) }
                let n = args.count > 1 ? Int(args[1].asNumber ?? 1) : 1
                if n >= s.count { return .string(s) }
                return .string(String(s.suffix(n)))
            }
        ))

        // MID
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "MID",
                description: "Returns characters from the middle of a text value.",
                parameters: [
                    FunctionParameter(name: "text", description: "The text string."),
                    FunctionParameter(name: "start_num", description: "Start position (1-based)."),
                    FunctionParameter(name: "num_chars", description: "Number of characters.")
                ]
            ),
            arity: 3...3,
            call: { args in
                let s = args[0].asString
                guard !s.isEmpty,
                      let start = args[1].asNumber,
                      let n = args[2].asNumber else { return .error(.notAvailable) }
                let startIdx = Int(start) - 1
                if startIdx < 0 || startIdx >= s.count { return .string("") }
                let endIdx = Swift.min(startIdx + Int(n), s.count)
                return .string(String(s[s.index(s.startIndex, offsetBy: startIdx)..<s.index(s.startIndex, offsetBy: endIdx)]))
            }
        ))

        // TRIM
        register(BuiltInFunction(
            signature: FunctionSignature(name: "TRIM", description: "Removes extra spaces from text."),
            arity: 1...1,
            call: { args in
                guard let s = args.first?.asString else { return .error(.notAvailable) }
                let trimmed = s.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
                return .string(trimmed)
            }
        ))

        // UPPER / LOWER / PROPER
        register(BuiltInFunction(
            signature: FunctionSignature(name: "UPPER", description: "Converts text to uppercase."),
            arity: 1...1,
            call: { args in
                guard let s = args.first?.asString else { return .error(.notAvailable) }
                return .string(s.uppercased())
            }
        ))
        register(BuiltInFunction(
            signature: FunctionSignature(name: "LOWER", description: "Converts text to lowercase."),
            arity: 1...1,
            call: { args in
                guard let s = args.first?.asString else { return .error(.notAvailable) }
                return .string(s.lowercased())
            }
        ))
        register(BuiltInFunction(
            signature: FunctionSignature(name: "PROPER", description: "Capitalizes the first letter of each word."),
            arity: 1...1,
            call: { args in
                guard let s = args.first?.asString else { return .error(.notAvailable) }
                return .string(s.capitalized)
            }
        ))

        // TEXT
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "TEXT",
                description: "Converts a value to text in a specified format.",
                parameters: [
                    FunctionParameter(name: "value", description: "The value."),
                    FunctionParameter(name: "format_text", description: "The format code.")
                ]
            ),
            arity: 2...2,
            call: { args in
                guard let n = args[0].asNumber else { return .error(.notAvailable) }
                let format = args[1].asString
                // Simple format: "0", "0.00", "#,##0"
                if format.contains(".") {
                    let parts = format.split(separator: ".")
                    let intPart = String(Int(n))
                    let decPart = String(Int((n - Double(Int(n))) * pow(10.0, Double(parts[1].count))))
                    return .string("\(intPart).\(decPart)")
                }
                return .string(String(Int(n)))
            }
        ))

        // VALUE
        register(BuiltInFunction(
            signature: FunctionSignature(name: "VALUE", description: "Converts a text string to a number."),
            arity: 1...1,
            call: { args in
                guard let s = args.first?.asString, let n = Double(s) else { return .error(.notAvailable) }
                return .number(n)
            }
        ))

        // REPT
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "REPT",
                description: "Repeats text a given number of times.",
                parameters: [
                    FunctionParameter(name: "text", description: "Text to repeat."),
                    FunctionParameter(name: "times", description: "Number of repetitions.")
                ]
            ),
            arity: 2...2,
            call: { args in
                let s = args[0].asString
                guard !s.isEmpty,
                      let times = args[1].asNumber else { return .error(.notAvailable) }
                let n = max(0, Int(times))
                if n > 32767 { return .error(.numberInvalid) } // Excel limit
                return .string(String(repeating: s, count: n))
            }
        ))
    }

    // MARK: - Date/Time Functions

    private func registerDate() {
        // TODAY
        register(BuiltInFunction(
            signature: FunctionSignature(name: "TODAY", description: "Returns the current date.",
                volatility: .volatile),
            arity: 0...0,
            call: { _ in .date(Date()) }
        ))

        // NOW
        register(BuiltInFunction(
            signature: FunctionSignature(name: "NOW", description: "Returns the current date and time.",
                volatility: .volatile),
            arity: 0...0,
            call: { _ in .date(Date()) }
        ))

        // DATE
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "DATE",
                description: "Returns the serial number for a date.",
                parameters: [
                    FunctionParameter(name: "year"),
                    FunctionParameter(name: "month"),
                    FunctionParameter(name: "day")
                ]
            ),
            arity: 3...3,
            call: { args in
                guard args.count == 3,
                      let year  = args[0].asNumber,
                      let month = args[1].asNumber,
                      let day   = args[2].asNumber else { return .error(.notAvailable) }
                var comps = DateComponents()
                comps.year = Int(year)
                comps.month = Int(month)
                comps.day = Int(day)
                comps.hour = 0
                comps.minute = 0
                comps.second = 0
                guard let date = Calendar.current.date(from: comps) else { return .error(.numberInvalid) }
                return .date(date)
            }
        ))

        // YEAR / MONTH / DAY
        register(BuiltInFunction(
            signature: FunctionSignature(name: "YEAR", description: "Returns the year of a date."),
            arity: 1...1,
            call: { args in
                guard let d = self.excelSerialToDate(args.first?.asNumber) else { return .error(.notAvailable) }
                return .number(Double(Calendar.current.component(.year, from: d)))
            }
        ))
        register(BuiltInFunction(
            signature: FunctionSignature(name: "MONTH", description: "Returns the month of a date."),
            arity: 1...1,
            call: { args in
                guard let d = self.excelSerialToDate(args.first?.asNumber) else { return .error(.notAvailable) }
                return .number(Double(Calendar.current.component(.month, from: d)))
            }
        ))
        register(BuiltInFunction(
            signature: FunctionSignature(name: "DAY", description: "Returns the day of a date."),
            arity: 1...1,
            call: { args in
                guard let d = self.excelSerialToDate(args.first?.asNumber) else { return .error(.notAvailable) }
                return .number(Double(Calendar.current.component(.day, from: d)))
            }
        ))

        // DATEDIF
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "DATEDIF",
                description: "Returns the difference between two dates in years, months, or days.",
                parameters: [
                    FunctionParameter(name: "start_date"),
                    FunctionParameter(name: "end_date"),
                    FunctionParameter(name: "unit", description: "\"Y\", \"M\", \"D\", \"YM\", \"YD\", \"MD\"")
                ]
            ),
            arity: 3...3,
            call: { args in
                guard let start = self.excelSerialToDate(args[0].asNumber),
                      let end   = self.excelSerialToDate(args[1].asNumber) else { return .error(.notAvailable) }
                let unit = args[2].asString.uppercased()
                let cal = Calendar.current
                switch unit {
                case "Y":
                    return .number(Double(cal.dateComponents([.year], from: start, to: end).year ?? 0))
                case "M":
                    return .number(Double(cal.dateComponents([.month], from: start, to: end).month ?? 0))
                case "D":
                    return .number(end.timeIntervalSince(start) / 86400.0)
                case "YM":
                    let components = cal.dateComponents([.month], from: start, to: end)
                    return .number(Double(components.month ?? 0))
                case "YD":
                    let startOfYear = cal.date(from: DateComponents(year: cal.component(.year, from: end), month: 1, day: 1))!
                    return .number(cal.dateComponents([.day], from: startOfYear, to: end).day.map { Double($0) } ?? 0)
                case "MD":
                    let startOfMonth = cal.date(from: DateComponents(
                        year: cal.component(.year, from: end),
                        month: cal.component(.month, from: end),
                        day: 1
                    ))!
                    return .number(Double(cal.dateComponents([.day], from: startOfMonth, to: end).day ?? 0))
                default:
                    return .error(.notAvailable)
                }
            }
        ))

        // DAYS
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "DAYS",
                description: "Returns the number of days between two dates.",
                parameters: [FunctionParameter(name: "end_date"), FunctionParameter(name: "start_date")]
            ),
            arity: 2...2,
            call: { args in
                guard let end = self.excelSerialToDate(args[0].asNumber),
                      let start = self.excelSerialToDate(args[1].asNumber) else { return .error(.notAvailable) }
                return .number((end.timeIntervalSince(start)) / 86400.0)
            }
        ))
    }

    // MARK: - Type Functions

    private func registerType() {
        // ISBLANK
        register(BuiltInFunction(
            signature: FunctionSignature(name: "ISBLANK", description: "Returns TRUE if the value is blank."),
            arity: 1...1,
            call: { args in .bool(args.first?.isBlank == true) }
        ))

        // ISNUMBER
        register(BuiltInFunction(
            signature: FunctionSignature(name: "ISNUMBER", description: "Returns TRUE if the value is a number."),
            arity: 1...1,
            call: { args in .bool(args.first?.isNumeric == true) }
        ))

        // ISTEXT
        register(BuiltInFunction(
            signature: FunctionSignature(name: "ISTEXT", description: "Returns TRUE if the value is text."),
            arity: 1...1,
            call: { args in
                if case .string = args.first { return .bool(true) }
                return .bool(false)
            }
        ))

        // ISLOGICAL
        register(BuiltInFunction(
            signature: FunctionSignature(name: "ISLOGICAL", description: "Returns TRUE if the value is logical."),
            arity: 1...1,
            call: { args in
                if case .bool = args.first { return .bool(true) }
                return .bool(false)
            }
        ))

        // ISERROR
        register(BuiltInFunction(
            signature: FunctionSignature(name: "ISERROR", description: "Returns TRUE if the value is an error."),
            arity: 1...1,
            call: { args in
                if case .error(let e) = args.first { return .bool(e.isPropagating) }
                return .bool(false)
            }
        ))

        // ISNA
        register(BuiltInFunction(
            signature: FunctionSignature(name: "ISNA", description: "Returns TRUE if the value is #N/A."),
            arity: 1...1,
            call: { args in
                if case .error(.notAvailable) = args.first { return .bool(true) }
                return .bool(false)
            }
        ))

        // ISERR
        register(BuiltInFunction(
            signature: FunctionSignature(name: "ISERR", description: "Returns TRUE if the value is any error except #N/A."),
            arity: 1...1,
            call: { args in
                if case .error(let e) = args.first { return .bool(e != .notAvailable && e.isPropagating) }
                return .bool(false)
            }
        ))

        // N (convert to number)
        register(BuiltInFunction(
            signature: FunctionSignature(name: "N", description: "Returns a value converted to a number."),
            arity: 1...1,
            call: { args in
                guard let n = args.first?.asNumber else { return .number(0) }
                return .number(n)
            }
        ))

        // NA
        register(BuiltInFunction(
            signature: FunctionSignature(name: "NA", description: "Returns the error value #N/A."),
            arity: 0...0,
            call: { _ in .error(.notAvailable) }
        ))

        // TYPE
        register(BuiltInFunction(
            signature: FunctionSignature(name: "TYPE", description: "Returns the type of value."),
            arity: 1...1,
            call: { args in
                guard let arg = args.first else { return .number(1) }
                switch arg {
                case .null:         return .number(1)    // Empty
                case .number:       return .number(2)    // Number
                case .string:       return .number(3)   // Text
                case .bool:         return .number(4)    // Logical
                case .error:        return .number(16)   // Error
                case .date, .array: return .number(64)   // Array or other
                }
            }
        ))
    }

    // MARK: - Lookup Functions

    private func registerLookup() {
        // INDEX
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "INDEX",
                description: "Returns a value from a table or array.",
                parameters: [
                    FunctionParameter(name: "array", description: "The array or range.", acceptsRange: true),
                    FunctionParameter(name: "row_num", description: "Row position."),
                    FunctionParameter(name: "col_num", description: "Column position.", optional: true)
                ]
            ),
            arity: 2...3,
            call: { args in
                guard args.count >= 2,
                      let row = args[1].asNumber else { return .error(.referenceInvalid) }
                let rowIdx = Int(row) - 1
                guard rowIdx >= 0 else { return .error(.referenceInvalid) }

                // Flatten the array
                let values = self.flattenArg(args[0])
                let cols = self.estimateCols(from: args[0])
                if cols <= 0 { return .error(.referenceInvalid) }

                let colIdx: Int
                if args.count >= 3 {
                    guard let c = args[2].asNumber else { return .error(.referenceInvalid) }
                    let ci = Int(c) - 1
                    guard ci >= 0 else { return .error(.referenceInvalid) }
                    colIdx = ci
                } else {
                    colIdx = 0
                }

                let flatIdx = rowIdx * cols + colIdx
                if flatIdx < 0 || flatIdx >= values.count { return .error(.referenceInvalid) }
                return values[flatIdx]
            }
        ))

        // ROW / ROWS / COLUMN / COLUMNS
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "ROW",
                description: "Returns the row number of a reference.",
                parameters: [FunctionParameter(name: "reference", optional: true)]
            ),
            arity: 0...1,
            call: { _ in .number(1) } // Placeholder — resolved with actual cell context
        ))
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "ROWS",
                description: "Returns the number of rows in a reference.",
                parameters: [FunctionParameter(name: "array", acceptsRange: true)]
            ),
            arity: 1...1,
            call: { args in
                let values = self.flattenArg(args[0])
                let cols = self.estimateCols(from: args[0])
                if cols <= 0 { return .number(0) }
                return .number(Double(values.count / cols))
            }
        ))
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "COLUMNS",
                description: "Returns the number of columns in a reference.",
                parameters: [FunctionParameter(name: "array", acceptsRange: true)]
            ),
            arity: 1...1,
            call: { args in
                .number(Double(self.estimateCols(from: args[0])))
            }
        ))
    }

    // MARK: - Helpers

    /// Flatten a value (which may be a range/array) into a flat [Value].
    private func flattenArg(_ value: Value) -> [Value] {
        switch value {
        case .array(_, _, let flat): return flat
        default: return [value]
        }
    }

    /// Estimate column count from a value (for INDEX)
    private func estimateCols(from value: Value) -> Int {
        switch value {
        case .array(_, let cols, _): return cols
        default: return 1
        }
    }

    /// Check if a value matches a criteria expression.
    /// Supports: number comparison, text comparison, wildcard "*text*"
    private func matchesCriteria(_ value: Value, _ criteria: Value) -> Bool {
        let critStr = criteria.asString

        // Numeric comparison: ">5", "<=10", "=3", "<>0"
        if critStr.hasPrefix(">=") {
            guard let threshold = Double(critStr.dropFirst(2)), let n = value.asNumber else { return false }
            return n >= threshold
        }
        if critStr.hasPrefix("<=") {
            guard let threshold = Double(critStr.dropFirst(2)), let n = value.asNumber else { return false }
            return n <= threshold
        }
        if critStr.hasPrefix("<>") {
            let crit = String(critStr.dropFirst(2))
            return value.asString != crit
        }
        if critStr.hasPrefix(">") {
            guard let threshold = Double(critStr.dropFirst(1)), let n = value.asNumber else { return false }
            return n > threshold
        }
        if critStr.hasPrefix("<") {
            guard let threshold = Double(critStr.dropFirst(1)), let n = value.asNumber else { return false }
            return n < threshold
        }
        if critStr.hasPrefix("=") {
            let crit = String(critStr.dropFirst(1))
            return value.asString == crit
        }

        // Text comparison (case-insensitive)
        let critUpper = critStr.uppercased()
        if critStr.contains("*") {
            // Wildcard
            let pattern = critStr.uppercased().replacingOccurrences(of: "*", with: ".*")
            let regex = try? NSRegularExpression(pattern: "^\(pattern)$", options: .caseInsensitive)
            let range = NSRange(value.asString.startIndex..., in: value.asString)
            return regex?.firstMatch(in: value.asString.uppercased(), options: [], range: range) != nil
        }

        return value.asString.lowercased() == critStr.lowercased()
    }

    /// Convert Excel serial number to Date.
    private func excelSerialToDate(_ serial: Double?) -> Date? {
        guard let serial = serial else { return nil }
        // Excel serial: days since 1900-01-00 (with leap year bug)
        let excelEpoch = Date(timeIntervalSince1970: -2208988800) // 1899-12-30
        return Calendar.current.date(byAdding: .day, value: Int(serial), to: excelEpoch)
    }
}
