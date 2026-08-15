import XCTest
@testable import TesseraCore

// Contract source: `TypeSystem.swift`'s `BinaryOp.precedence` doc
// comment documents a previously-shipped, previously-FIXED bug as a
// ratified correction: "Excel documents these the other way round (1 =
// tightest), and transcribing that order directly inverted every
// relationship: `+` outranked `*`, so `=1+2*3` produced 9 instead of 7."
// That is exactly doctrine rule 5's "traps stay pinned": a real,
// previously-shipped defect with a permanent regression test, not a
// behavior reverse-engineered from today's code. The same doc comment
// also states the right-associativity of `^` ("`2^3^2` is `2^(3^2)`")
// and the full precedence ladder (comparison < concat < add/subtract <
// multiply/divide < power), which the remaining cases pin.
final class ParserPrecedenceTests: DoctrineTestCase {

    private func eval(_ source: String) throws -> Value {
        let formula = try parseFormula(source)
        return try Evaluator().evaluate(
            formula.ast, at: CellAddr(col: 0, row: 0), sheet: "Sheet1", engine: StubSheetEngineCore()
        )
    }

    /// The exact regression named in the doc comment.
    func testMultiplicationBindsTighterThanAddition() throws {
        XCTAssertEqual(try eval("=1+2*3"), .number(7), "must NOT be 9 (the fixed 1-vs-9 defect)")
    }

    func testPowerIsRightAssociative() throws {
        // 2^(3^2) = 2^9 = 512, NOT (2^3)^2 = 64.
        XCTAssertEqual(try eval("=2^3^2"), .number(512))
    }

    func testPowerBindsTighterThanMultiplication() throws {
        // 2*3^2 = 2*9 = 18, NOT (2*3)^2 = 36.
        XCTAssertEqual(try eval("=2*3^2"), .number(18))
    }

    func testConcatenationBindsLooserThanAddition() throws {
        // (1+2)&"x" = "3x", not 1&(2&"x").
        XCTAssertEqual(try eval("=1+2&\"x\""), .string("3x"))
    }

    func testComparisonBindsLoosestOfAll() throws {
        // (1+1)=2 -> TRUE, not 1+(1=2) (which would be a type mismatch anyway).
        XCTAssertEqual(try eval("=1+1=2"), .bool(true))
    }

    func testUnaryMinusAppliesBeforeMultiplication() throws {
        XCTAssertEqual(try eval("=-2*3"), .number(-6))
    }

    func testParenthesesOverrideEveryPrecedenceRule() throws {
        XCTAssertEqual(try eval("=(1+2)*3"), .number(9))
    }
}
