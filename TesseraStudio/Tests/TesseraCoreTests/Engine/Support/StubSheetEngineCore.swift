import Foundation
@testable import TesseraCore

// MARK: - StubSheetEngineCore
//
// A minimal, in-memory `SheetEngineCore` conformance for FormulaEngine
// tests that need to evaluate an AST/TokenArray without a full
// `SheetEngine` (dependency graph, undo stack, recalculation). Every
// FormulaEngine test in this cluster that needs cell/range/named-range
// resolution should use this rather than hand-rolling another stub, so
// the evaluation contract under test (implicit intersection, RPN/AST
// equivalence, etc.) is the only thing that varies between test files.
//
// Not a doctrine fixture (no persisted state, nothing Codable) - just a
// plain in-memory dictionary, matching `SheetEngineCore`'s own contract
// of "the subset of SheetEngine needed by the evaluator" (Evaluator.swift).
final class StubSheetEngineCore: SheetEngineCore {
    private(set) var cellsBySheet: [String: [CellAddr: Value]] = [:]
    private(set) var namedRangesByName: [String: Value] = [:]

    /// Set a cell's value on `sheet` (defaults to "Sheet1", matching
    /// `SheetEngine`'s own default sheet name).
    func setCell(_ addr: CellAddr, sheet: String = "Sheet1", _ value: Value) {
        cellsBySheet[sheet, default: [:]][addr] = value
    }

    /// Bind a named range directly to a `Value` (already-resolved - this
    /// stub does not model a live range behind the name, only the
    /// resolved result the evaluator would see).
    func defineNamedRange(_ name: String, _ value: Value) {
        namedRangesByName[name.uppercased()] = value
    }

    func getCellValue(_ addr: CellAddr, sheet: String?) throws -> Value {
        let sheetName = sheet ?? "Sheet1"
        return cellsBySheet[sheetName]?[addr] ?? .null
    }

    func getRangeValues(_ range: RangeRef, fallbackSheet: String) throws -> [Value] {
        let sheetName = range.sheet ?? fallbackSheet
        return range.cells().map { cellsBySheet[sheetName]?[$0] ?? .null }
    }

    func resolveNamedRange(_ name: String, at context: CellAddr, fallbackSheet: String) throws -> Value {
        namedRangesByName[name.uppercased()] ?? .error(.nameInvalid)
    }
}

/// Parses `source` (e.g. `"=A1+B1"`) into its `Formula`, failing the test
/// (via `XCTFail`) rather than throwing, so call sites read as a plain
/// value producer. Every FormulaEngine test in this cluster that needs an
/// AST from formula text should go through this, not a hand-built
/// `FormulaAST` literal, so the AST under test is exactly what the real
/// parser produces.
func parseFormula(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> Formula {
    let result = try FormulaParser(source: source).parse()
    guard let formula = result.formula else {
        throw StubTestError.notAFormula(source)
    }
    return formula
}

enum StubTestError: Error, CustomStringConvertible {
    case notAFormula(String)
    var description: String {
        switch self {
        case .notAFormula(let s): return "\"\(s)\" parsed to a constant, not a formula"
        }
    }
}
