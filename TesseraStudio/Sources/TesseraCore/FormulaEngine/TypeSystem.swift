//===----------------------------------------------------------------------===//
//  TypeSystem.swift
//  Tessera Formula Engine
//
//  Value enum, coercion rules, Excel error types, serialization.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Value

/// The value type system mirrors Excel's. Every cell holds exactly one Value.
public enum Value: Equatable, Sendable, CustomStringConvertible {
    case null
    case number(Double)
    case bool(Bool)
    case string(String)
    case error(ValueError)
    case date(Date)
    case array(rows: Int, cols: Int, flat: [Value])

    public var description: String {
        switch self {
        case .null:        return ""
        case .number(let n): return n.description
        case .bool(let b):  return b ? "TRUE" : "FALSE"
        case .string(let s): return s
        case .error(let e):  return e.displayString
        case .date(let d):  return ISO8601DateFormatter().string(from: d)
        case .array:        return "{...}"
        }
    }

    /// True if the value is considered empty (blank cell)
    public var isBlank: Bool {
        switch self {
        case .null:         return true
        case .string(let s): return s.isEmpty
        default:            return false
        }
    }

    /// True if the value is a number (or can be coerced to one)
    public var isNumeric: Bool {
        switch self {
        case .number, .bool, .date: return true
        case .string(let s): return Double(s) != nil
        default: return false
        }
    }

    /// Coerce to Double if possible
    public var asNumber: Double? {
        switch self {
        case .number(let n): return n
        case .bool(let b):   return b ? 1.0 : 0.0
        case .string(let s): return Double(s)
        case .date(let d):   return d.timeIntervalSince1970 / 86400.0 + 25569.0 // Excel epoch offset
        default:              return nil
        }
    }

    /// Coerce to String
    public var asString: String {
        switch self {
        case .null:         return ""
        case .number(let n): return formatNumber(n)
        case .bool(let b):  return b ? "TRUE" : "FALSE"
        case .string(let s): return s
        case .error(let e):  return e.displayString
        case .date(let d):  return formatDate(d)
        case .array:        return "{...}"
        }
    }

    /// Coerce to Bool — Excel's truthy rules
    public var asBool: Bool {
        switch self {
        case .bool(let b):  return b
        case .number(let n): return n != 0.0
        case .string(let s): return !s.isEmpty
        case .null:         return false
        default:             return false
        }
    }

    private func formatNumber(_ n: Double) -> String {
        if n == n.rounded() && abs(n) < 1e15 {
            return String(format: "%.0f", n)
        }
        return n.description
    }

    private func formatDate(_ d: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: d)
    }

    // MARK: - Serialization (for MCP / checkpointing)

    public struct Serialized: Codable, Equatable, Sendable {
        public let type: String
        public let value: AnyCodableValue?

        public init(from value: Value) {
            switch value {
            case .null:
                self.type = "null"
                self.value = nil
            case .number(let n):
                self.type = "number"
                self.value = AnyCodableValue(n)
            case .bool(let b):
                self.type = "bool"
                self.value = AnyCodableValue(b)
            case .string(let s):
                self.type = "string"
                self.value = AnyCodableValue(s)
            case .error(let e):
                self.type = "error"
                self.value = AnyCodableValue(e.rawValue)
            case .date(let d):
                self.type = "date"
                self.value = AnyCodableValue(ISO8601DateFormatter().string(from: d))
            case .array(let rows, let cols, let flat):
                self.type = "array"
                self.value = AnyCodableValue(flat.map { Serialized(from: $0) })
            }
        }

        public var unwrap: Value {
            guard let value = self.value else {
                if type == "null" { return .null }
                return .error(.null)
            }
            switch type {
            case "null":    return .null
            case "number":  return .number(value.asDouble ?? 0)
            case "bool":    return .bool(value.asBool ?? false)
            case "string":  return .string(value.asString ?? "")
            case "error":   return .error(ValueError(rawValue: value.asString ?? "#VALUE!") ?? .null)
            case "date":    return .date(ISO8601DateFormatter().date(from: value.asString ?? "") ?? Date())
            case "array":   return .null // arrays need special handling
            default:         return .error(.null)
            }
        }
    }

    public func serialized() -> [String: Any] {
        switch self {
        case .null:          return ["type": "null"]
        case .number(let n): return ["type": "number", "value": n]
        case .bool(let b):   return ["type": "bool", "value": b]
        case .string(let s): return ["type": "string", "value": s]
        case .error(let e):  return ["type": "error", "error": e.displayString, "rawValue": e.rawValue]
        case .date(let d):   return ["type": "date", "value": ISO8601DateFormatter().string(from: d)]
        case .array(let r, let c, let flat):
            return ["type": "array", "rows": r, "cols": c, "flat": flat.map { $0.serialized() }]
        }
    }
}

/// Box for encoding arbitrary JSON-compatible values
public struct AnyCodableValue: Codable, Equatable, Sendable {
    public let double: Double?
    public let bool: Bool?
    public let string: String?
    public let array: [AnyCodableValue]?

    public init(_ value: Any) {
        if let d = value as? Double {
            self.double = d; self.bool = nil; self.string = nil; self.array = nil
        } else if let i = value as? Int {
            self.double = Double(i); self.bool = nil; self.string = nil; self.array = nil
        } else if let b = value as? Bool {
            self.double = nil; self.bool = b; self.string = nil; self.array = nil
        } else if let s = value as? String {
            self.double = nil; self.bool = nil; self.string = s; self.array = nil
        } else if let a = value as? [Any] {
            self.double = nil; self.bool = nil; self.string = nil
            self.array = a.map { AnyCodableValue($0) }
        } else {
            self.double = nil; self.bool = nil; self.string = nil; self.array = nil
        }
    }

    public var asDouble: Double? { double }
    public var asBool: Bool? { bool }
    public var asString: String? { string }
    public var asArray: [AnyCodableValue]? { array }
}

// MARK: - ValueError

/// Excel error codes — propagate through formula chains
public enum ValueError: Equatable, Sendable, RawRepresentable, Hashable {
    case divisionByZero   // #DIV/0!
    case notAvailable      // #N/A
    case nullReference     // #NULL!
    case numberInvalid     // #NUM!
    case referenceInvalid   // #REF!
    case nameInvalid       // #NAME?
    case spill             // #SPILL!
    case null              // #NULL! (alias)
    case gettingData       // #GETTING_DATA

    public var displayString: String {
        switch self {
        case .divisionByZero:   return "#DIV/0!"
        case .notAvailable:     return "#N/A"
        case .nullReference:   return "#NULL!"
        case .numberInvalid:    return "#NUM!"
        case .referenceInvalid: return "#REF!"
        case .nameInvalid:     return "#NAME?"
        case .spill:           return "#SPILL!"
        case .null:            return "#NULL!"
        case .gettingData:     return "#GETTING_DATA"
        }
    }

    public var rawValue: String { displayString }

    public init?(rawValue: String) {
        switch rawValue {
        case "#DIV/0!", "#DIV/0":     self = .divisionByZero
        case "#N/A", "#NA":           self = .notAvailable
        case "#NULL!", "#NULL":       self = .nullReference
        case "#NUM!", "#NUM":         self = .numberInvalid
        case "#REF!", "#REF":         self = .referenceInvalid
        case "#NAME?", "#NAME":       self = .nameInvalid
        case "#SPILL!", "#SPILL":     self = .spill
        case "#NULL!":                self = .null
        case "#GETTING_DATA":         self = .gettingData
        default:                      return nil
        }
    }

    /// Errors that propagate (short-circuit the formula chain)
    public var isPropagating: Bool {
        switch self {
        case .divisionByZero, .numberInvalid, .referenceInvalid,
             .nameInvalid, .notAvailable, .gettingData:
            return true
        case .nullReference, .spill, .null:
            return false
        }
    }
}

// MARK: - Type Coercion

/// Excel's implicit type coercion rules
public enum TypeCoercion {
    /// Coerce `other` to the numeric type of `self` for binary operations.
    /// Returns nil if coercion is impossible (-> #VALUE!)
    public static func coerce(_ lhs: Value, _ rhs: Value, op: BinaryOp) -> (Value, Value)? {
        // Boolean + number in arithmetic context: TRUE=1, FALSE=0
        if op.isArithmetic {
            if case .bool(let l) = lhs, case .number = rhs {
                return (.number(l ? 1.0 : 0.0), rhs)
            }
            if case .number = lhs, case .bool(let r) = rhs {
                return (lhs, .number(r ? 1.0 : 0.0))
            }
            if case .bool(let l) = lhs, case .bool(let r) = rhs {
                return (.number(l ? 1.0 : 0.0), .number(r ? 1.0 : 0.0))
            }
        }

        // String + anything → string concatenation
        if op == .concat {
            let l = lhs.asString
            let r = rhs.asString
            return (.string(l), .string(r))
        }

        // Numeric coercion: string → number
        if case .string(let ls) = lhs, case .number = rhs {
            if let n = Double(ls) { return (.number(n), rhs) }
            return nil
        }
        if case .number = lhs, case .string(let rs) = rhs {
            if let n = Double(rs) { return (lhs, .number(n)) }
            return nil
        }
        if case .string(let ls) = lhs, case .string(let rs) = rhs {
            if let ln = Double(ls), let rn = Double(rs) {
                return (.number(ln), .number(rn))
            }
        }

        return (lhs, rhs)
    }
}

// MARK: - BinaryOp

public enum BinaryOp: String, Sendable, CaseIterable {
    case add     = "+"
    case subtract = "-"
    case multiply = "*"
    case divide  = "/"
    case power   = "^"
    case concat  = "&"
    case equal   = "="
    case notEqual = "<>"
    case less    = "<"
    case greater = ">"
    case lessOrEqual  = "<="
    case greaterOrEqual = ">="
    case rangeOp = ":"
    case intersect = " "  // implicit intersection

    /// Precedence from Excel's 18-level table
    public var precedence: Int {
        switch self {
        case .rangeOp, .intersect: return 1
        case .power:               return 3
        case .multiply, .divide:   return 4
        case .add, .subtract:      return 5
        case .concat:              return 6
        case .equal, .notEqual, .less, .greater, .lessOrEqual, .greaterOrEqual: return 7
        }
    }

    public var isArithmetic: Bool {
        switch self {
        case .add, .subtract, .multiply, .divide, .power: return true
        default: return false
        }
    }

    public static func from(_ str: String) -> BinaryOp? {
        switch str {
        case "+":  return .add
        case "-":  return .subtract
        case "*":  return .multiply
        case "/":  return .divide
        case "^":  return .power
        case "&":  return .concat
        case "=":  return .equal
        case "<>": return .notEqual
        case "<":  return .less
        case ">":  return .greater
        case "<=": return .lessOrEqual
        case ">=": return .greaterOrEqual
        case ":":  return .rangeOp
        default:   return nil
        }
    }
}

// MARK: - UnaryOp

public enum UnaryOp: String, Sendable {
    case negate  = "-"
    case positive = "+"
    case percent  = "%"

    public static func from(_ str: String) -> UnaryOp? {
        switch str {
        case "-": return .negate
        case "+": return .positive
        case "%": return .percent
        default:  return nil
        }
    }
}

// MARK: - Comparison

public enum Comparison {
    public static func compare(_ lhs: Value, _ rhs: Value, op: BinaryOp) -> Bool {
        switch op {
        case .equal:
            return compareEqual(lhs, rhs)
        case .notEqual:
            return !compareEqual(lhs, rhs)
        case .less:
            return compareNumeric(lhs, rhs) < 0
        case .greater:
            return compareNumeric(lhs, rhs) > 0
        case .lessOrEqual:
            return compareNumeric(lhs, rhs) <= 0
        case .greaterOrEqual:
            return compareNumeric(lhs, rhs) >= 0
        default:
            return false
        }
    }

    private static func compareEqual(_ lhs: Value, _ rhs: Value) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):       return true
        case (.null, _), (_, .null): return false
        case (.number(let l), .number(let r)): return l == r
        case (.string(let l), .string(let r)): return l == r
        case (.bool(let l), .bool(let r)):     return l == r
        default: return false
        }
    }

    private static func compareNumeric(_ lhs: Value, _ rhs: Value) -> Int {
        let l = lhs.asNumber
        let r = rhs.asNumber
        switch (l, r) {
        case (let l?, let r?):
            if l < r { return -1 }
            if l > r { return  1 }
            return 0
        case (nil, nil): return 0
        case (nil, _):   return -1
        case (_, nil):   return  1
        }
    }
}
