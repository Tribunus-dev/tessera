//===----------------------------------------------------------------------===//
//  StatisticsFunctions.swift
//  Tessera Formula Engine
//
//  Dispersion and order statistics. The sample/population distinction
//  is the one that matters here: STDEV divides by n-1, STDEVP by n, and
//  using the wrong one is a quiet, plausible-looking error.
//===----------------------------------------------------------------------===//

import Foundation

extension FunctionRegistry {

    func registerStatistics() {
        registerDispersion()
        registerOrderStatistics()
        registerCorrelation()
    }

    // MARK: Variance / standard deviation

    private func registerDispersion() {
        register(statFunction(
            name: "VAR",
            description: "Estimates variance from a sample (divides by n-1)."
        ) { numbers in
            variance(numbers, sample: true)
        })

        register(statFunction(
            name: "VARP",
            description: "Calculates variance of an entire population (divides by n)."
        ) { numbers in
            variance(numbers, sample: false)
        })

        register(statFunction(
            name: "STDEV",
            description: "Estimates standard deviation from a sample (divides by n-1)."
        ) { numbers in
            variance(numbers, sample: true).map(sqrt)
        })

        register(statFunction(
            name: "STDEVP",
            description: "Calculates standard deviation of an entire population (divides by n)."
        ) { numbers in
            variance(numbers, sample: false).map(sqrt)
        })

        register(statFunction(
            name: "MEDIAN",
            description: "Returns the middle value of the given numbers."
        ) { numbers in
            guard !numbers.isEmpty else { return nil }
            let sorted = numbers.sorted()
            let mid = sorted.count / 2
            // Even counts average the two middle values.
            return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        })
    }

    // MARK: Order statistics

    private func registerOrderStatistics() {
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "PERCENTILE",
                description: "The k-th percentile of a range, interpolating between values.",
                parameters: [
                    FunctionParameter(name: "array"),
                    FunctionParameter(name: "k", description: "Between 0 and 1 inclusive.", acceptsRange: false),
                ]
            ),
            arity: 2...2,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                let numbers = FunctionArgs.numericSeries([args[0]]).sorted()
                guard !numbers.isEmpty, let k = FunctionArgs.number(args[1]) else {
                    return .error(.numberInvalid)
                }
                guard k >= 0, k <= 1 else { return .error(.numberInvalid) }
                return .number(percentile(numbers, k: k))
            }
        ))

        register(rankFunction(name: "LARGE", description: "The k-th largest value.", largest: true))
        register(rankFunction(name: "SMALL", description: "The k-th smallest value.", largest: false))
    }

    private func rankFunction(name: String, description: String, largest: Bool) -> BuiltInFunction {
        BuiltInFunction(
            signature: FunctionSignature(
                name: name,
                description: description,
                parameters: [
                    FunctionParameter(name: "array"),
                    FunctionParameter(name: "k", description: "1-based rank.", acceptsRange: false),
                ]
            ),
            arity: 2...2,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                let numbers = FunctionArgs.numericSeries([args[0]])
                guard let rawK = FunctionArgs.number(args[1]) else { return .error(.numberInvalid) }
                let k = Int(rawK)
                guard k >= 1, k <= numbers.count else { return .error(.numberInvalid) }
                let sorted = largest ? numbers.sorted(by: >) : numbers.sorted()
                return .number(sorted[k - 1])
            }
        )
    }

    // MARK: Correlation

    private func registerCorrelation() {
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "CORREL",
                description: "The correlation coefficient of two ranges.",
                parameters: [
                    FunctionParameter(name: "array1"),
                    FunctionParameter(name: "array2"),
                ]
            ),
            arity: 2...2,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                let xs = FunctionArgs.numericSeries([args[0]])
                let ys = FunctionArgs.numericSeries([args[1]])
                guard xs.count == ys.count, xs.count >= 2 else { return .error(.notAvailable) }

                let n = Double(xs.count)
                let meanX = xs.reduce(0, +) / n
                let meanY = ys.reduce(0, +) / n
                var covariance = 0.0
                var varianceX = 0.0
                var varianceY = 0.0
                for i in 0..<xs.count {
                    let dx = xs[i] - meanX
                    let dy = ys[i] - meanY
                    covariance += dx * dy
                    varianceX += dx * dx
                    varianceY += dy * dy
                }
                // A constant series has no correlation to report.
                guard varianceX > 0, varianceY > 0 else { return .error(.divisionByZero) }
                return .number(covariance / sqrt(varianceX * varianceY))
            }
        ))
    }

    /// Shared shape for the aggregate statistics: flatten ranges, drop
    /// non-numeric entries, and report #NUM! when the result is undefined
    /// (an empty set, or a single value for a sample statistic).
    private func statFunction(
        name: String,
        description: String,
        compute: @escaping ([Double]) -> Double?
    ) -> BuiltInFunction {
        BuiltInFunction(
            signature: FunctionSignature(
                name: name,
                description: description,
                parameters: [
                    FunctionParameter(name: "number1"),
                    FunctionParameter(name: "number2", optional: true, repeatable: true),
                ]
            ),
            arity: 1...255,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                guard let result = compute(FunctionArgs.numericSeries(args)) else {
                    return .error(.numberInvalid)
                }
                return .number(result)
            }
        )
    }
}

// MARK: - Free helpers

/// Sample variance divides by n-1, population variance by n.
private func variance(_ numbers: [Double], sample: Bool) -> Double? {
    let n = numbers.count
    guard n > (sample ? 1 : 0) else { return nil }
    let mean = numbers.reduce(0, +) / Double(n)
    let sumSquares = numbers.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
    return sumSquares / Double(sample ? n - 1 : n)
}

/// Linear interpolation between the two straddling ranks, matching
/// Excel's inclusive PERCENTILE.
private func percentile(_ sorted: [Double], k: Double) -> Double {
    guard sorted.count > 1 else { return sorted[0] }
    let position = k * Double(sorted.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = Swift.min(lower + 1, sorted.count - 1)
    let fraction = position - Double(lower)
    return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
}
