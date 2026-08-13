//===----------------------------------------------------------------------===//
//  CriteriaFunctions.swift
//  Tessera Formula Engine
//
//  Multi-criteria aggregates (SUMIFS / COUNTIFS / AVERAGEIFS) and
//  SUMPRODUCT. The single-criteria SUMIF and COUNTIF already existed;
//  real models are almost always filtering on more than one column.
//===----------------------------------------------------------------------===//

import Foundation

extension FunctionRegistry {

    func registerCriteria() {
        registerMultiCriteria()
        registerSumProduct()
    }

    // MARK: SUMIFS / COUNTIFS / AVERAGEIFS

    private func registerMultiCriteria() {
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "SUMIFS",
                description: "Adds the cells that meet every criterion.",
                parameters: [
                    FunctionParameter(name: "sum_range"),
                    FunctionParameter(name: "criteria_range1"),
                    FunctionParameter(name: "criteria1", acceptsRange: false),
                    FunctionParameter(name: "criteria_range2", optional: true, repeatable: true),
                ]
            ),
            // sum_range plus at least one (range, criteria) pair.
            arity: 3...255,
            call: { [weak self] args in
                guard let self else { return .error(.nameInvalid) }
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                let target = ValueMatrix(args[0])
                guard let rows = self.matchingIndices(pairs: Array(args.dropFirst()), count: target.count) else {
                    return .error(.notAvailable)
                }
                var total = 0.0
                for i in rows {
                    if let n = target.flat[i].asNumber { total += n }
                }
                return .number(total)
            }
        ))

        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "COUNTIFS",
                description: "Counts the cells that meet every criterion.",
                parameters: [
                    FunctionParameter(name: "criteria_range1"),
                    FunctionParameter(name: "criteria1", acceptsRange: false),
                    FunctionParameter(name: "criteria_range2", optional: true, repeatable: true),
                ]
            ),
            arity: 2...255,
            call: { [weak self] args in
                guard let self else { return .error(.nameInvalid) }
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                let first = ValueMatrix(args[0])
                guard let rows = self.matchingIndices(pairs: args, count: first.count) else {
                    return .error(.notAvailable)
                }
                return .number(Double(rows.count))
            }
        ))

        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "AVERAGEIFS",
                description: "Averages the cells that meet every criterion.",
                parameters: [
                    FunctionParameter(name: "average_range"),
                    FunctionParameter(name: "criteria_range1"),
                    FunctionParameter(name: "criteria1", acceptsRange: false),
                ]
            ),
            arity: 3...255,
            call: { [weak self] args in
                guard let self else { return .error(.nameInvalid) }
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                let target = ValueMatrix(args[0])
                guard let rows = self.matchingIndices(pairs: Array(args.dropFirst()), count: target.count) else {
                    return .error(.notAvailable)
                }
                let numbers = rows.compactMap { target.flat[$0].asNumber }
                guard !numbers.isEmpty else { return .error(.divisionByZero) }
                return .number(numbers.reduce(0, +) / Double(numbers.count))
            }
        ))
    }

    /// Indices satisfying EVERY (range, criteria) pair.
    ///
    /// `pairs` is a flat list alternating range, criteria. Every criteria
    /// range must be the same length as the aggregated range - Excel
    /// requires it, and a mismatch is a modelling error rather than
    /// something to silently truncate.
    private func matchingIndices(pairs: [Value], count: Int) -> [Int]? {
        guard !pairs.isEmpty, pairs.count % 2 == 0 else { return nil }

        var conditions: [(ValueMatrix, Value)] = []
        var index = 0
        while index + 1 < pairs.count {
            let range = ValueMatrix(pairs[index])
            guard range.count == count else { return nil }
            conditions.append((range, pairs[index + 1]))
            index += 2
        }

        return (0..<count).filter { i in
            conditions.allSatisfy { range, criteria in
                matchesCriteria(range.flat[i], criteria)
            }
        }
    }

    // MARK: SUMPRODUCT

    private func registerSumProduct() {
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "SUMPRODUCT",
                description: "Multiplies corresponding entries and sums the products.",
                parameters: [
                    FunctionParameter(name: "array1"),
                    FunctionParameter(name: "array2", optional: true, repeatable: true),
                ]
            ),
            arity: 1...255,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                let matrices = args.map(ValueMatrix.init)
                guard let width = matrices.first?.count, width > 0 else { return .error(.notAvailable) }
                guard matrices.allSatisfy({ $0.count == width }) else { return .error(.notAvailable) }

                var total = 0.0
                for i in 0..<width {
                    // Non-numeric entries count as zero, matching Excel:
                    // a text label inside the range must not poison the
                    // whole product.
                    var product = 1.0
                    for m in matrices {
                        product *= m.flat[i].asNumber ?? 0
                    }
                    total += product
                }
                return .number(total)
            }
        ))
    }
}
