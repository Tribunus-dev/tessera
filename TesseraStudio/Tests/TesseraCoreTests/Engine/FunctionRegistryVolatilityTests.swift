import XCTest
@testable import TesseraCore

// Contract source: studio-expansion-design-refinement-2026-08-14.md
// section 4, Calc cluster, item "1.21 dynamic-array completion":
// "Register OFFSET/INDIRECT as volatile (they are volatile-listed but
// unregistered today - a live correctness gap)" and, from the same
// item's design-recommendations list (sota-calc-report.md
// recommendation 7 / "Volatile-array verdict"): "DROP
// FunctionVolatility.array (plan row 20). No surveyed engine has the
// axis... If a per-formula 'always recalc array' bit is ever needed, it
// rides the TokenArray ... not the function registry." That is a
// ratified thou-shalt-not (doctrine rule 5: traps stay pinned).
final class FunctionRegistryVolatilityTests: DoctrineTestCase {

    // MARK: - Trap: FunctionVolatility must stay a closed two-case enum

    /// `FunctionVolatility` is NOT `CaseIterable`, so there is no runtime
    /// enumeration to assert against; the guard here is the switch
    /// itself. It is written EXHAUSTIVE, with no `default:` branch - if
    /// a third case (in particular the ratified-dropped `.array`) is
    /// ever added to `FunctionVolatility`, this file fails to COMPILE,
    /// which is the doctrine rule-5 guard for a closed enum: the trap is
    /// pinned by the type system, not by a runtime assertion that could
    /// silently stop firing.
    func testFunctionVolatilityStaysExactlyNotVolatileAndVolatile() {
        func describe(_ v: FunctionVolatility) -> String {
            switch v {
            case .notVolatile: return "notVolatile"
            case .volatile: return "volatile"
            // NO default case: adding `.array` (or any other case) to
            // FunctionVolatility must fail this file's compilation.
            }
        }
        XCTAssertEqual(describe(.notVolatile), "notVolatile")
        XCTAssertEqual(describe(.volatile), "volatile")
    }

    // MARK: - OFFSET/INDIRECT carry the volatile flag in the registry

    /// The specific, named gap-closure item: OFFSET/INDIRECT must be
    /// registered in `FunctionRegistry` with `volatility: .volatile` on
    /// their `FunctionSignature` - not merely present in
    /// `FormulaAST.containsVolatileFunction`'s hardcoded name list (a
    /// separate, AST-level mechanism the contract also names but does
    /// not treat as sufficient on its own).
    func testOFFSETIsRegisteredWithVolatileMetadata() {
        guard let fn = FunctionRegistry.shared.lookup("OFFSET") else {
            return XCTFail("OFFSET must be registered in FunctionRegistry")
        }
        guard case .volatile = fn.signature.volatility else {
            return XCTFail("OFFSET's FunctionSignature.volatility must be .volatile")
        }
    }

    func testINDIRECTIsRegisteredWithVolatileMetadata() {
        guard let fn = FunctionRegistry.shared.lookup("INDIRECT") else {
            return XCTFail("INDIRECT must be registered in FunctionRegistry")
        }
        guard case .volatile = fn.signature.volatility else {
            return XCTFail("INDIRECT's FunctionSignature.volatility must be .volatile")
        }
    }

    func testOFFSETLookupIsCaseInsensitive() {
        XCTAssertNotNil(FunctionRegistry.shared.lookup("offset"))
        XCTAssertTrue(FunctionRegistry.shared.contains("Offset"))
    }

    // MARK: - AST-level volatile name list (FormulaAST.containsVolatileFunction)
    //
    // Independent oracle (doctrine rule 7): this list is hardcoded here
    // from the doc comment on `FormulaAST.containsVolatileFunction`
    // ("NOW, TODAY, RAND, OFFSET, INDIRECT") plus the two additional
    // names the implementation's own array literal names
    // (RANDBETWEEN, INFO) - NOT read off `containsVolatileFunction`'s
    // switch body and echoed back, which would make this test validate
    // itself. Sourced from studio-expansion-design-refinement-2026-08-14
    // .md's "register OFFSET/INDIRECT/INFO volatility through one
    // mechanism (today it is a hardcoded list in
    // FormulaAST.containsVolatile - fine, but 1.21's tests must pin it)".

    private static let expectedVolatileNames: Set<String> = [
        "NOW", "TODAY", "RAND", "RANDBETWEEN", "OFFSET", "INDIRECT", "INFO",
    ]

    func testEveryDocumentedVolatileFunctionMarksItsASTVolatile() throws {
        for name in Self.expectedVolatileNames {
            let ast = FormulaAST.function(name: name, args: [])
            XCTAssertTrue(
                ast.containsVolatileFunction,
                "\(name) is on the contract's volatile list but containsVolatileFunction reports false"
            )
        }
    }

    func testAnOrdinaryFunctionDoesNotMarkASTVolatile() {
        let ast = FormulaAST.function(name: "SUM", args: [.number(1)])
        XCTAssertFalse(ast.containsVolatileFunction)
    }

    func testVolatileFunctionNestedInsideArithmeticStillMarksASTVolatile() {
        let ast = FormulaAST.binary(
            op: .add,
            left: .number(1),
            right: .function(name: "TODAY", args: [])
        )
        XCTAssertTrue(ast.containsVolatileFunction)
    }
}
