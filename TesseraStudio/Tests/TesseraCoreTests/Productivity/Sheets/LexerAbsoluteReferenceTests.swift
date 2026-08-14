import XCTest
@testable import TesseraCore

/// `Lexer.scanCellRef`'s `$`-absolute handling for formula cell
/// references (`$A1`, `A$1`, `$A$1`) - distinct from `AddressParser`,
/// a separate component with its own `colAbsolute`/`rowAbsolute` bug
/// fixed earlier (see AddressParserTests.swift): this is the path an
/// actual formula string goes through end to end.
///
/// Black-box at the `FormulaParser` level, matching
/// `LexerSheetQualifierTests.swift`'s convention - not `Lexer`'s
/// private token stream, which the parser and evaluator never see
/// directly.
@MainActor
final class LexerAbsoluteReferenceTests: XCTestCase {

    private func cellRef(_ source: String) throws -> CellRef {
        let result = try FormulaParser(source: source).parse()
        guard let formula = result.formula else {
            XCTFail("\(source) parsed as a plain value, not a formula")
            throw FormulaParser.ParseError.invalidExpression("not a formula")
        }
        guard case .cell(let ref) = formula.ast else {
            XCTFail("\(source) did not parse to a bare cell reference, got \(formula.ast)")
            throw FormulaParser.ParseError.invalidExpression("not a cell ref")
        }
        return ref
    }

    func testColOnlyAbsolute() throws {
        let ref = try cellRef("=$A1")
        XCTAssertTrue(ref.colAbsolute)
        XCTAssertFalse(ref.rowAbsolute)
    }

    /// The bug this file exists to pin: `scanCellRef` correctly
    /// CONSUMED a `$` immediately before the row digits (advancing
    /// past it so parsing didn't break), but then hard-coded
    /// `rowAbsolute: false` in the `CellRef` it built regardless -
    /// found via TokenArrayCompiler's relative-offset encoding, which
    /// needs `rowAbsolute` to be accurate to compile `$A$1` as a
    /// position that doesn't move with the formula's anchor. Before
    /// the fix, "=$A$1" parsed identically to "=$A1" - the row `$` was
    /// silently swallowed with no effect.
    func testRowOnlyAbsolute() throws {
        let ref = try cellRef("=A$1")
        XCTAssertFalse(ref.colAbsolute)
        XCTAssertTrue(ref.rowAbsolute)
    }

    func testBothAbsolute() throws {
        let ref = try cellRef("=$A$1")
        XCTAssertTrue(ref.colAbsolute)
        XCTAssertTrue(ref.rowAbsolute)
    }

    func testNeitherAbsolute() throws {
        let ref = try cellRef("=A1")
        XCTAssertFalse(ref.colAbsolute)
        XCTAssertFalse(ref.rowAbsolute)
    }

    /// A sheet-qualified reference with a row-only `$` (no column `$`,
    /// so this doesn't touch the pre-existing "$ right after the sheet
    /// prefix throws" limitation `LexerSheetQualifierTests.swift`'s
    /// testDollarAbsoluteAfterBangIsAPreExistingSharedLimitation
    /// already pins) still exercises the same fixed code path.
    func testRowOnlyAbsoluteWithSheetQualifier() throws {
        let ref = try cellRef("=Sheet1!A$1")
        XCTAssertFalse(ref.colAbsolute)
        XCTAssertTrue(ref.rowAbsolute)
        XCTAssertEqual(ref.sheet, "Sheet1")
    }
}
