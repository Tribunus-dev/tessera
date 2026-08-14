import XCTest
@testable import TesseraCore

/// `TokenArray` (P0 0.2b): the compiled RPN peer of `FormulaAST`. The
/// load-bearing property under test is EQUIVALENCE - for every formula
/// that compiles, `TokenArrayEvaluator` must produce exactly the same
/// `Value` the existing, production `Evaluator` (AST walk) produces,
/// for the same cells. That's checked directly (both evaluators run
/// against the same live `SheetEngine`), not asserted from reading the
/// code.
final class TokenArrayTests: XCTestCase {

    private var engine: SheetEngine!
    private let astEvaluator = Evaluator()

    override func setUp() {
        super.setUp()
        engine = SheetEngine()
    }

    // MARK: - Equivalence with the AST evaluator

    private func assertSameResult(
        _ source: String,
        anchor: CellAddr = CellAddr(col: 5, row: 5),
        sheet: String = "Sheet1",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let parser = try FormulaParser(source: source)
        let result = try parser.parse()
        guard let formula = result.formula else {
            XCTFail("\(source) parsed as a plain value, not a formula", file: file, line: line)
            return
        }
        let astResult = try astEvaluator.evaluate(formula.ast, at: anchor, sheet: sheet, engine: engine)

        guard let compiled = TokenArrayCompiler.compile(formula.ast, anchor: anchor) else {
            XCTFail("\(source) failed to compile to a TokenArray", file: file, line: line)
            return
        }
        let rpnResult = try TokenArrayEvaluator.evaluate(
            compiled, anchor: anchor, sheet: sheet, functions: .shared, engine: engine
        )
        XCTAssertEqual(rpnResult, astResult, "\(source): RPN result diverged from the AST evaluator", file: file, line: line)
    }

    func testArithmetic() throws {
        try assertSameResult("=1+2*3-4/2")
        try assertSameResult("=2^10")
        try assertSameResult("=-5+3")
        try assertSameResult("=50%")
    }

    func testComparisonsAndConcat() throws {
        try assertSameResult("=1<2")
        try assertSameResult("=\"a\"=\"a\"")
        try assertSameResult("=\"foo\"&\"bar\"")
        try assertSameResult("=5<>5")
    }

    func testDivisionByZero() throws {
        try assertSameResult("=1/0")
    }

    func testCellReferences() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .number(10))
        engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: 0), value: .number(20))
        try assertSameResult("=A1+B1")
        try assertSameResult("=A1*2")
    }

    func testAbsoluteAndRelativeMix() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .number(100))
        engine.setValue(sheet: nil, addr: CellAddr(col: 2, row: 2), value: .number(3))
        try assertSameResult("=$A$1+C3", anchor: CellAddr(col: 5, row: 5))
        // Same formula, different anchor - the absolute ref must still
        // resolve to A1 regardless of where the formula itself lives.
        try assertSameResult("=$A$1+C3", anchor: CellAddr(col: 8, row: 1))
    }

    func testRangeFunctions() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .number(1))
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 1), value: .number(2))
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 2), value: .number(3))
        try assertSameResult("=SUM(A1:A3)")
        try assertSameResult("=AVERAGE(A1:A3)")
        try assertSameResult("=COUNT(A1:A3)")
    }

    func testNestedFunctions() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .number(-5))
        try assertSameResult("=IF(A1<0, ABS(A1), A1)")
        try assertSameResult("=MAX(1, 2, MIN(3, 4))")
    }

    func testNamedRange() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .number(42))
        XCTAssertTrue(engine.defineName("Rate", range: RangeRef(
            topLeft: CellAddr(col: 0, row: 0), bottomRight: CellAddr(col: 0, row: 0)
        ), sheet: nil))
        try assertSameResult("=Rate*2")
    }

    func testCrossSheetReference() throws {
        engine.createSheet(name: "Data")
        engine.setValue(sheet: "Data", addr: CellAddr(col: 0, row: 0), value: .number(7))
        try assertSameResult("=Data!A1*3")
    }

    func testErrorPropagation() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: 0), value: .error(.divisionByZero))
        try assertSameResult("=A1+1")
    }

    func testEmptyCellArithmeticTreatsBlankAsZero() throws {
        try assertSameResult("=Z9+1")
    }

    // MARK: - Compiler scope (what does NOT compile)

    func testLetDoesNotCompile() throws {
        let result = try FormulaParser(source: "=LET(x, 5, x*2)").parse()
        guard let formula = result.formula else { return XCTFail("expected a formula") }
        XCTAssertNil(TokenArrayCompiler.compile(formula.ast, anchor: CellAddr(col: 0, row: 0)))
    }

    func testLambdaDoesNotCompile() throws {
        let result = try FormulaParser(source: "=LAMBDA(x, x*2)(21)").parse()
        guard let formula = result.formula else { return XCTFail("expected a formula") }
        XCTAssertNil(TokenArrayCompiler.compile(formula.ast, anchor: CellAddr(col: 0, row: 0)))
    }

    func testArrayLiteralDoesNotCompile() throws {
        let result = try FormulaParser(source: "={1,2;3,4}").parse()
        guard let formula = result.formula else { return XCTFail("expected a formula") }
        XCTAssertNil(TokenArrayCompiler.compile(formula.ast, anchor: CellAddr(col: 0, row: 0)))
    }

    func testOrdinaryFunctionStillCompiles() throws {
        let result = try FormulaParser(source: "=SUM(A1:A3)").parse()
        guard let formula = result.formula else { return XCTFail("expected a formula") }
        XCTAssertNotNil(TokenArrayCompiler.compile(formula.ast, anchor: CellAddr(col: 0, row: 0)))
    }

    // MARK: - Shared shape (the actual "shared formula groups" property)

    func testSameRelativeShapeAtDifferentAnchorsCompilesEqual() throws {
        // =A1+B1 at anchor B2, and =A2+B2 at anchor B3, both say "one
        // cell left of me" and "the cell directly above me" - the
        // whole point of relative encoding.
        let source1 = "=A1+B1"
        let anchor1 = CellAddr(col: 1, row: 1) // B2
        let ast1 = try FormulaParser(source: source1).parse().formula!.ast
        let compiled1 = TokenArrayCompiler.compile(ast1, anchor: anchor1)!

        let source2 = "=A2+B2"
        let anchor2 = CellAddr(col: 1, row: 2) // B3
        let ast2 = try FormulaParser(source: source2).parse().formula!.ast
        let compiled2 = TokenArrayCompiler.compile(ast2, anchor: anchor2)!

        XCTAssertEqual(compiled1.groupKey, compiled2.groupKey)
    }

    func testDifferentShapeCompilesUnequal() throws {
        let ast1 = try FormulaParser(source: "=A1+B1").parse().formula!.ast
        let compiled1 = TokenArrayCompiler.compile(ast1, anchor: CellAddr(col: 1, row: 1))!

        let ast2 = try FormulaParser(source: "=A1*B1").parse().formula!.ast
        let compiled2 = TokenArrayCompiler.compile(ast2, anchor: CellAddr(col: 1, row: 1))!

        XCTAssertNotEqual(compiled1.groupKey, compiled2.groupKey)
    }

    func testAbsoluteReferenceShapeIsAnchorIndependent() throws {
        let ast = try FormulaParser(source: "=$A$1*2").parse().formula!.ast
        let compiledA = TokenArrayCompiler.compile(ast, anchor: CellAddr(col: 5, row: 5))!
        let compiledB = TokenArrayCompiler.compile(ast, anchor: CellAddr(col: 9, row: 0))!
        XCTAssertEqual(compiledA.groupKey, compiledB.groupKey, "an absolute ref doesn't move, so the shape is identical regardless of anchor")
    }

    // MARK: - Out-of-bounds resolution

    func testRelativeReferenceOffSheetEdgeProducesRefError() throws {
        // Anchor at A1; a formula referencing "one cell to the left" of
        // A1 (relative offset -1) resolves to column -1, which
        // CellAddr refuses to represent.
        let anchor = CellAddr(col: 0, row: 0)
        let ref = RelativeCellRef(sheet: nil, col: .relative(offset: -1), row: .relative(offset: 0))
        let array = TokenArray(tokens: [.cellRef(ref)])
        let result = try TokenArrayEvaluator.evaluate(array, anchor: anchor, sheet: "Sheet1", functions: .shared, engine: engine)
        XCTAssertEqual(result, .error(.referenceInvalid))
    }

    // MARK: - SharedFormulaGroups

    func testInternReturnsSameIDForEqualShapes() {
        let groups = SharedFormulaGroups()
        let a = TokenArray(tokens: [.number(1), .number(2), .binaryOp(.add)])
        let b = TokenArray(tokens: [.number(1), .number(2), .binaryOp(.add)])
        XCTAssertEqual(groups.intern(a), groups.intern(b))
    }

    func testInternReturnsDifferentIDForDifferentShapes() {
        let groups = SharedFormulaGroups()
        let a = TokenArray(tokens: [.number(1), .number(2), .binaryOp(.add)])
        let b = TokenArray(tokens: [.number(1), .number(2), .binaryOp(.multiply)])
        XCTAssertNotEqual(groups.intern(a), groups.intern(b))
    }

    func testReferenceCountTracksInternsAndReleases() {
        let groups = SharedFormulaGroups()
        let a = TokenArray(tokens: [.number(1)])
        let id = groups.intern(a)
        XCTAssertEqual(groups.referenceCount(for: id), 1)
        groups.intern(a)
        XCTAssertEqual(groups.referenceCount(for: id), 2)
        groups.release(id)
        XCTAssertEqual(groups.referenceCount(for: id), 1)
        groups.release(id)
        XCTAssertEqual(groups.referenceCount(for: id), 0)
        XCTAssertNil(groups.tokenArray(for: id), "a fully-released group is forgotten")
    }

    func testGroupCountReflectsDistinctShapes() {
        let groups = SharedFormulaGroups()
        XCTAssertEqual(groups.groupCount, 0)
        groups.intern(TokenArray(tokens: [.number(1)]))
        groups.intern(TokenArray(tokens: [.number(1)])) // same shape
        groups.intern(TokenArray(tokens: [.number(2)])) // different shape
        XCTAssertEqual(groups.groupCount, 2)
    }
}
