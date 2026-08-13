//===----------------------------------------------------------------------===//
//  FinancialFunctions.swift
//  Tessera Formula Engine
//
//  Time-value-of-money and cash-flow functions: the set every financial
//  model is built from. Excel-compatible in both result and sign
//  convention (money paid out is negative, money received is positive).
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Shared helpers

/// Numeric coercion + error propagation for a function's arguments.
enum FunctionArgs {
    /// First error among `values`, if any. Financial functions return the
    /// precedent's error rather than masking it as #VALUE!/#NUM!.
    static func firstError(_ values: [Value]) -> ValueError? {
        for v in values {
            if case .error(let e) = v { return e }
        }
        return nil
    }

    /// Numeric operand: empty cells count as 0, as in arithmetic.
    static func number(_ v: Value) -> Double? {
        if case .null = v { return 0 }
        return v.asNumber
    }

    /// Flatten ranges and coerce to numbers, DROPPING non-numeric entries.
    /// This matches Excel's aggregate behaviour: text and blanks inside a
    /// cash-flow range are ignored rather than poisoning the result.
    static func numericSeries(_ values: [Value]) -> [Double] {
        ColumnSlice.flattenArrays(values).compactMap { v -> Double? in
            switch v {
            case .number(let n): return n
            case .bool(let b): return b ? 1 : 0
            case .date(let d): return d.timeIntervalSince1970 / 86400.0 + 25569.0
            default: return nil
            }
        }
    }
}

// MARK: - Annuity math

/// The closed-form annuity relationships shared by PMT/PV/FV/NPER.
/// `type` is 0 for end-of-period payments, 1 for beginning-of-period.
enum Annuity {
    /// Future value of an annuity.
    static func fv(rate: Double, nper: Double, pmt: Double, pv: Double, type: Double) -> Double {
        if rate == 0 {
            return -(pv + pmt * nper)
        }
        let growth = pow(1 + rate, nper)
        return -(pv * growth + pmt * (1 + rate * type) * (growth - 1) / rate)
    }

    /// Present value of an annuity.
    static func pv(rate: Double, nper: Double, pmt: Double, fv: Double, type: Double) -> Double {
        if rate == 0 {
            return -(fv + pmt * nper)
        }
        let growth = pow(1 + rate, nper)
        return -(fv + pmt * (1 + rate * type) * (growth - 1) / rate) / growth
    }

    /// Periodic payment.
    static func pmt(rate: Double, nper: Double, pv: Double, fv: Double, type: Double) -> Double {
        if nper == 0 { return .nan }
        if rate == 0 {
            return -(pv + fv) / nper
        }
        let growth = pow(1 + rate, nper)
        return -(pv * growth + fv) / ((1 + rate * type) * (growth - 1) / rate)
    }

    /// Number of periods.
    static func nper(rate: Double, pmt: Double, pv: Double, fv: Double, type: Double) -> Double {
        if rate == 0 {
            if pmt == 0 { return .nan }
            return -(pv + fv) / pmt
        }
        let adjusted = pmt * (1 + rate * type)
        let numerator = adjusted - fv * rate
        let denominator = adjusted + pv * rate
        guard denominator != 0 else { return .nan }
        // Only the RATIO has to be positive for the log to be defined -
        // both terms are commonly negative together (a loan repaid from a
        // negative payment against a negative principal).
        let ratio = numerator / denominator
        guard ratio > 0 else { return .nan }
        return log(ratio) / log(1 + rate)
    }
}

// MARK: - Root finding

/// Newton-Raphson with a bisection fallback, used by RATE / IRR / XIRR.
/// Excel's own iterative functions converge or return #NUM!; the fallback
/// is what keeps a poorly-scaled cash flow from reporting failure when a
/// root does exist in a sane range.
enum RootSolver {
    static let maxIterations = 128
    static let tolerance = 1e-9

    /// Solve f(x) = 0 near `guess`.
    static func solve(guess: Double, f: (Double) -> Double) -> Double? {
        var x = guess
        for _ in 0..<maxIterations {
            let fx = f(x)
            if !fx.isFinite { break }
            if abs(fx) < tolerance { return x }
            // Numerical derivative; the analytic one buys little here and
            // the cash-flow polynomial is cheap to evaluate twice.
            let h = max(1e-7, abs(x) * 1e-7)
            let derivative = (f(x + h) - f(x - h)) / (2 * h)
            if derivative == 0 || !derivative.isFinite { break }
            let next = x - fx / derivative
            if !next.isFinite { break }
            if abs(next - x) < tolerance { return next }
            x = next
        }
        return bisect(f: f)
    }

    /// Scan for a sign change over a wide rate range, then bisect.
    private static func bisect(f: (Double) -> Double) -> Double? {
        var low = -0.9999
        var lowValue = f(low)
        var high = low
        // Walk upward looking for a bracket.
        var step = 0.01
        while high < 1e6 {
            high += step
            let highValue = f(high)
            if lowValue.isFinite, highValue.isFinite, lowValue * highValue < 0 {
                for _ in 0..<maxIterations {
                    let mid = (low + high) / 2
                    let midValue = f(mid)
                    if abs(midValue) < tolerance { return mid }
                    if lowValue * midValue < 0 {
                        high = mid
                    } else {
                        low = mid
                        lowValue = midValue
                    }
                }
                return (low + high) / 2
            }
            low = high
            lowValue = highValue
            step *= 1.5
        }
        return nil
    }
}

// MARK: - Registration

extension FunctionRegistry {

    func registerFinancial() {
        registerAnnuity()
        registerCashFlow()
    }

    // MARK: Annuity family

    private func registerAnnuity() {
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "PMT",
                description: "Payment for a loan based on constant payments and a constant interest rate.",
                parameters: [
                    FunctionParameter(name: "rate", description: "Interest rate per period.", acceptsRange: false),
                    FunctionParameter(name: "nper", description: "Total number of payments.", acceptsRange: false),
                    FunctionParameter(name: "pv", description: "Present value (the principal).", acceptsRange: false),
                    FunctionParameter(name: "fv", description: "Future value after the last payment.", acceptsRange: false, optional: true),
                    FunctionParameter(name: "type", description: "0 = end of period, 1 = beginning.", acceptsRange: false, optional: true),
                ]
            ),
            arity: 3...5,
            call: { args in
                try annuityCall(args) { rate, nper, a, b, type in
                    Annuity.pmt(rate: rate, nper: nper, pv: a, fv: b, type: type)
                }
            }
        ))

        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "PV",
                description: "Present value of an investment.",
                parameters: [
                    FunctionParameter(name: "rate", acceptsRange: false),
                    FunctionParameter(name: "nper", acceptsRange: false),
                    FunctionParameter(name: "pmt", acceptsRange: false),
                    FunctionParameter(name: "fv", acceptsRange: false, optional: true),
                    FunctionParameter(name: "type", acceptsRange: false, optional: true),
                ]
            ),
            arity: 3...5,
            call: { args in
                try annuityCall(args) { rate, nper, a, b, type in
                    Annuity.pv(rate: rate, nper: nper, pmt: a, fv: b, type: type)
                }
            }
        ))

        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "FV",
                description: "Future value of an investment.",
                parameters: [
                    FunctionParameter(name: "rate", acceptsRange: false),
                    FunctionParameter(name: "nper", acceptsRange: false),
                    FunctionParameter(name: "pmt", acceptsRange: false),
                    FunctionParameter(name: "pv", acceptsRange: false, optional: true),
                    FunctionParameter(name: "type", acceptsRange: false, optional: true),
                ]
            ),
            arity: 3...5,
            call: { args in
                try annuityCall(args) { rate, nper, a, b, type in
                    Annuity.fv(rate: rate, nper: nper, pmt: a, pv: b, type: type)
                }
            }
        ))

        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "NPER",
                description: "Number of periods for an investment.",
                parameters: [
                    FunctionParameter(name: "rate", acceptsRange: false),
                    FunctionParameter(name: "pmt", acceptsRange: false),
                    FunctionParameter(name: "pv", acceptsRange: false),
                    FunctionParameter(name: "fv", acceptsRange: false, optional: true),
                    FunctionParameter(name: "type", acceptsRange: false, optional: true),
                ]
            ),
            arity: 3...5,
            call: { args in
                try annuityCall(args) { rate, pmt, pv, fv, type in
                    Annuity.nper(rate: rate, pmt: pmt, pv: pv, fv: fv, type: type)
                }
            }
        ))

        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "RATE",
                description: "Interest rate per period of an annuity.",
                parameters: [
                    FunctionParameter(name: "nper", acceptsRange: false),
                    FunctionParameter(name: "pmt", acceptsRange: false),
                    FunctionParameter(name: "pv", acceptsRange: false),
                    FunctionParameter(name: "fv", acceptsRange: false, optional: true),
                    FunctionParameter(name: "type", acceptsRange: false, optional: true),
                    FunctionParameter(name: "guess", acceptsRange: false, optional: true),
                ]
            ),
            arity: 3...6,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                let n = args.compactMap(FunctionArgs.number)
                guard n.count == args.count, n.count >= 3 else { return .error(.notAvailable) }
                let nper = n[0], pmt = n[1], pv = n[2]
                let fv = n.count > 3 ? n[3] : 0
                let type = n.count > 4 ? n[4] : 0
                let guess = n.count > 5 ? n[5] : 0.1
                let root = RootSolver.solve(guess: guess) { rate in
                    Annuity.fv(rate: rate, nper: nper, pmt: pmt, pv: pv, type: type) - fv
                }
                guard let root, root.isFinite else { return .error(.numberInvalid) }
                return .number(root)
            }
        ))
    }

    // MARK: Cash-flow family

    private func registerCashFlow() {
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "NPV",
                description: "Net present value of a series of periodic cash flows.",
                parameters: [
                    FunctionParameter(name: "rate", description: "Discount rate per period.", acceptsRange: false),
                    FunctionParameter(name: "value1", description: "Cash flow at the end of period 1."),
                    FunctionParameter(name: "value2", optional: true, repeatable: true),
                ]
            ),
            arity: 2...255,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                guard let rate = FunctionArgs.number(args[0]) else { return .error(.notAvailable) }
                if rate == -1 { return .error(.divisionByZero) }
                let flows = FunctionArgs.numericSeries(Array(args.dropFirst()))
                // Excel discounts the FIRST value by one period, not zero.
                var total = 0.0
                for (i, flow) in flows.enumerated() {
                    total += flow / pow(1 + rate, Double(i + 1))
                }
                return .number(total)
            }
        ))

        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "IRR",
                description: "Internal rate of return for a series of periodic cash flows.",
                parameters: [
                    FunctionParameter(name: "values", description: "Cash flows; must include at least one negative and one positive."),
                    FunctionParameter(name: "guess", acceptsRange: false, optional: true),
                ]
            ),
            arity: 1...2,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                let flows = FunctionArgs.numericSeries([args[0]])
                guard flows.count >= 2 else { return .error(.numberInvalid) }
                guard flows.contains(where: { $0 > 0 }), flows.contains(where: { $0 < 0 }) else {
                    return .error(.numberInvalid)
                }
                let guess = args.count > 1 ? (FunctionArgs.number(args[1]) ?? 0.1) : 0.1
                // IRR is the rate where the undiscounted-at-t0 NPV is zero.
                let root = RootSolver.solve(guess: guess) { rate in
                    var total = 0.0
                    for (i, flow) in flows.enumerated() {
                        total += flow / pow(1 + rate, Double(i))
                    }
                    return total
                }
                guard let root, root.isFinite else { return .error(.numberInvalid) }
                return .number(root)
            }
        ))

        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "XNPV",
                description: "Net present value for a schedule of cash flows that is not periodic.",
                parameters: [
                    FunctionParameter(name: "rate", acceptsRange: false),
                    FunctionParameter(name: "values"),
                    FunctionParameter(name: "dates"),
                ]
            ),
            arity: 3...3,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                guard let rate = FunctionArgs.number(args[0]) else { return .error(.notAvailable) }
                let flows = FunctionArgs.numericSeries([args[1]])
                let dates = FunctionArgs.numericSeries([args[2]])
                guard flows.count == dates.count, let start = dates.first else {
                    return .error(.numberInvalid)
                }
                return .number(xnpv(rate: rate, flows: flows, dates: dates, start: start))
            }
        ))

        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "XIRR",
                description: "Internal rate of return for a schedule of cash flows that is not periodic.",
                parameters: [
                    FunctionParameter(name: "values"),
                    FunctionParameter(name: "dates"),
                    FunctionParameter(name: "guess", acceptsRange: false, optional: true),
                ]
            ),
            arity: 2...3,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                let flows = FunctionArgs.numericSeries([args[0]])
                let dates = FunctionArgs.numericSeries([args[1]])
                guard flows.count == dates.count, flows.count >= 2, let start = dates.first else {
                    return .error(.numberInvalid)
                }
                guard flows.contains(where: { $0 > 0 }), flows.contains(where: { $0 < 0 }) else {
                    return .error(.numberInvalid)
                }
                let guess = args.count > 2 ? (FunctionArgs.number(args[2]) ?? 0.1) : 0.1
                let root = RootSolver.solve(guess: guess) { rate in
                    xnpv(rate: rate, flows: flows, dates: dates, start: start)
                }
                guard let root, root.isFinite else { return .error(.numberInvalid) }
                return .number(root)
            }
        ))
    }
}

// MARK: - Free helpers

/// Shared shape for the 3-to-5 argument annuity functions: coerce, apply
/// defaults (fv = 0, type = 0), and reject a non-numeric argument.
private func annuityCall(
    _ args: [Value],
    _ body: (_ rate: Double, _ nper: Double, _ a: Double, _ b: Double, _ type: Double) -> Double
) throws -> Value {
    if let e = FunctionArgs.firstError(args) { return .error(e) }
    let n = args.compactMap(FunctionArgs.number)
    guard n.count == args.count, n.count >= 3 else { return .error(.notAvailable) }
    let fourth = n.count > 3 ? n[3] : 0
    let type = n.count > 4 ? n[4] : 0
    let result = body(n[0], n[1], n[2], fourth, type)
    guard result.isFinite else { return .error(.numberInvalid) }
    return .number(result)
}

/// Present value of dated cash flows, discounted on a 365-day year.
private func xnpv(rate: Double, flows: [Double], dates: [Double], start: Double) -> Double {
    var total = 0.0
    for (i, flow) in flows.enumerated() {
        let years = (dates[i] - start) / 365.0
        total += flow / pow(1 + rate, years)
    }
    return total
}
