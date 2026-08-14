import XCTest
@testable import TesseraCore

/// `Lexer.scanIdentifier` learning to recognize an UNQUOTED
/// sheet-qualified reference (`Sheet1!A1`), not just the quoted form
/// (`'Sheet1'!A1`, `scanQuotedSheetRef`).
///
/// Before this, `scanIdentifier` scanned the bare name, checked what
/// followed for `(` (function) or `:` (range), and otherwise emitted
/// `.namedRange` - with no case for `!`. So `Sheet1!A1` silently became
/// a named-range lookup for "SHEET1", dropping "!A1" from the token
/// stream entirely, and the same reference inside a function call threw
/// (the `!` arrived where `)` was expected). Confirmed by compiling and
/// running the real Lexer/Parser standalone before this fix landed.
///
/// Black-box at the `FormulaParser` level, matching how a formula
/// actually gets parsed end to end - not `Lexer`'s private token
/// stream, which the parser and evaluator never see directly.
@MainActor
final class LexerSheetQualifierTests: XCTestCase {

    private func parse(_ source: String) throws -> Formula {
        let result = try FormulaParser(source: source).parse()
        guard let formula = result.formula else {
            XCTFail("\(source) parsed as a plain value, not a formula")
            throw FormulaParser.ParseError.invalidExpression("not a formula")
        }
        return formula
    }

    func testUnquotedSingleCellReference() throws {
        let f = try parse("=Sheet1!A1*2")
        XCTAssertEqual(f.referencedCells, [CellRef(sheet: "Sheet1", col: 0, row: 0)])
        XCTAssertEqual(f.ast, .binary(op: .multiply,
            left: .cell(CellRef(sheet: "Sheet1", col: 0, row: 0)),
            right: .number(2)))
    }

    func testUnquotedRangeReference() throws {
        let f = try parse("=SUM(Data!A1:B5)")
        XCTAssertEqual(f.referencedRanges.count, 1)
        let range = try XCTUnwrap(f.referencedRanges.first)
        XCTAssertEqual(range.sheet, "Data")
        // Every expanded cell must carry the range's sheet, not the
        // formula's own sheet - the FormulaAST.collectCells() range-sheet
        // bug this same effort fixed alongside the graph rewrite.
        XCTAssertEqual(f.referencedCells.count, 10)
        XCTAssertTrue(f.referencedCells.allSatisfy { $0.sheet == "Data" })
    }

    /// The unquoted and quoted forms must produce IDENTICAL ASTs for
    /// the same reference - two spellings of the same thing, not two
    /// different behaviors.
    func testUnquotedMatchesQuotedForSimpleNames() throws {
        let unquoted = try parse("=Sheet1!A1*2")
        let quoted = try parse("='Sheet1'!A1*2")
        XCTAssertEqual(unquoted.ast, quoted.ast)
    }

    /// A space between the sheet name and "!" is tolerated, matching
    /// the existing lenient whitespace handling before "(" and ":".
    func testWhitespaceBeforeBangIsTolerated() throws {
        let f = try parse("=Sheet1 !A1")
        XCTAssertEqual(f.referencedCells, [CellRef(sheet: "Sheet1", col: 0, row: 0)])
    }

    /// A named range with no "!" must still resolve as a named range,
    /// not get swept up by the new sheet-qualifier branch.
    func testPlainNamedRangeIsUnaffected() throws {
        let f = try parse("=MyNamedRange")
        guard case .cell(let ref) = f.ast else {
            return XCTFail("expected a named-range marker cell node")
        }
        XCTAssertEqual(ref.addr, .namedRangeMarker)
        XCTAssertEqual(ref.sheet, "$MYNAMEDRANGE")
    }

    /// A bare, unqualified range (no sheet at all) must still parse
    /// exactly as before - the new branch only fires on "!".
    func testUnqualifiedRangeIsUnaffected() throws {
        let f = try parse("=SUM(A1:B5)")
        let range = try XCTUnwrap(f.referencedRanges.first)
        XCTAssertNil(range.sheet)
    }

    func testBooleanLiteralsAreUnaffected() throws {
        XCTAssertEqual(try FormulaParser(source: "=TRUE").parse().value, .bool(true))
        XCTAssertEqual(try FormulaParser(source: "=FALSE").parse().value, .bool(false))
    }

    /// A known, PRE-EXISTING, shared limitation - not a regression this
    /// fix introduces. Both the quoted and unquoted sheet-qualifier
    /// paths call `scanCellRef(sheet:)` directly, which never checks
    /// for a `$` immediately after the sheet prefix (only `scanDollarRef`,
    /// entered when `$` is the very first character of a token, handles
    /// column-absolute markers). Pinned here so a future fix to one
    /// path doesn't silently leave the other behind.
    func testDollarAbsoluteAfterBangIsAPreExistingSharedLimitation() {
        XCTAssertThrowsError(try parse("=Sheet1!$A$1"))
        XCTAssertThrowsError(try parse("='Sheet1'!$A$1"))
    }
}
