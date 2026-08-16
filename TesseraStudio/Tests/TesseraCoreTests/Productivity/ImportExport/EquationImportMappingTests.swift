import XCTest
@testable import TesseraCore

// MARK: - EquationImportMappingTests
//
// Contract: item 2.14's design contract - "import maps ODF StarMath
// 5.0 annotations and OMML to LaTeX, preserving originals for
// unedited round-trip." This track's item 6 test list: "StarMath ->
// LaTeX and OMML -> LaTeX conversion for a handful of real-world
// fixture strings ... or construct minimal-but-realistic ones and
// state that choice honestly in findings."
//
// FIXTURE PROVENANCE (doctrine rule 10's honesty requirement - see
// this wave's findings file for the sources): the StarMath fixtures
// use syntax straight from the LibreOffice Math "Command Reference"
// (Math Guide appendix A) and its `nroot`/`sum from/to` worked
// examples; the quadratic-formula StarMath is a direct StarMath
// transliteration of SwiftMath's own README LaTeX example, so the two
// fixture sets (StarMath here, LaTeX in BlockRendererEquationTests)
// describe the SAME formula for cross-checking. The OMML fixtures are
// constructed by hand from the ECMA-376/OOXML math schema (m:oMath/
// m:f/m:rad/m:nary/m:sSup - datypic.com's schema reference), not
// captured from a real .docx - EquationImportMapping.swift's own
// header states this explicitly too.

final class EquationImportMappingTests: DoctrineTestCase {

    // MARK: - StarMath 5.0 -> LaTeX

    func testStarMathFractionOverConvertsToLatexFrac() {
        XCTAssertEqual(EquationImportMapping.starMathToLaTeX("a over b"), "\\frac{a}{b}")
    }

    func testStarMathBracedFractionConvertsToLatexFrac() {
        XCTAssertEqual(EquationImportMapping.starMathToLaTeX("{a+b} over {c}"), "\\frac{a+b}{c}")
    }

    func testStarMathSqrtConvertsToLatexSqrt() {
        XCTAssertEqual(EquationImportMapping.starMathToLaTeX("sqrt {9}"), "\\sqrt{9}")
    }

    func testStarMathNrootConvertsToLatexBracketedSqrt() {
        XCTAssertEqual(EquationImportMapping.starMathToLaTeX("nroot {3}{8}"), "\\sqrt[3]{8}")
    }

    func testStarMathCaretSuperscriptConvertsToLatexSuperscript() {
        XCTAssertEqual(EquationImportMapping.starMathToLaTeX("x^2 + y^2 = z^2"), "x^{2} + y^{2} = z^{2}")
    }

    func testStarMathUnderscoreSubscriptConvertsToLatexSubscript() {
        XCTAssertEqual(EquationImportMapping.starMathToLaTeX("a_1 + a_2"), "a_{1} + a_{2}")
    }

    func testStarMathSumFromToConvertsToLatexSumWithLimits() {
        XCTAssertEqual(EquationImportMapping.starMathToLaTeX("sum from {k=1} to {n} a_k"), "\\sum_{k=1}^{n} a_{k}")
    }

    func testStarMathIntFromToConvertsToLatexIntegralWithLimits() {
        XCTAssertEqual(EquationImportMapping.starMathToLaTeX("int from {a} to {b} f(x)"), "\\int_{a}^{b} f(x)")
    }

    func testStarMathGreekLowercaseConvertsToLatexGreekMacro() {
        XCTAssertEqual(EquationImportMapping.starMathToLaTeX("%alpha + %pi"), "\\alpha + \\pi")
    }

    func testStarMathGreekUppercaseConvertsToLatexCapitalizedGreekMacro() {
        // %GAMMA (unlike %BETA) has a real, distinct LaTeX macro
        // (\Gamma) - see EquationImportMapping.swift's greekLatex doc
        // comment for the known limitation on Greek capitals that
        // coincide with Latin letters (Alpha/Beta/...).
        XCTAssertEqual(EquationImportMapping.starMathToLaTeX("%GAMMA"), "\\Gamma")
    }

    func testStarMathInfinityKeywordConvertsToLatexInftyMacro() {
        XCTAssertEqual(EquationImportMapping.starMathToLaTeX("sum from {1} to infinity 2^{-n}"), "\\sum_{1}^{\\infty} 2^{-n}")
    }

    func testStarMathNotEqualRelationConvertsToLatexNeq() {
        XCTAssertEqual(EquationImportMapping.starMathToLaTeX("a <> b"), "a \\neq b")
    }

    func testStarMathPlusMinusConvertsToLatexPm() {
        XCTAssertEqual(EquationImportMapping.starMathToLaTeX("a +- b"), "a \\pm b")
    }

    /// A direct StarMath transliteration of the quadratic formula -
    /// cross-checked against `BlockRendererEquationTests`'s LaTeX
    /// fixture for the same formula (see this file's header note).
    func testStarMathQuadraticFormulaConvertsToExpectedLatex() {
        let latex = EquationImportMapping.starMathToLaTeX("x = {-b +- sqrt {b^2 - 4ac}} over {2a}")
        XCTAssertEqual(latex, "x = \\frac{-b \\pm \\sqrt{b^{2} - 4ac}}{2a}")
    }

    // MARK: - OMML -> LaTeX

    private let ommlNamespaceOpen = "<m:oMath xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\">"

    func testOMMLFractionConvertsToLatexFrac() {
        let xml = """
        \(ommlNamespaceOpen)
          <m:f>
            <m:fPr><m:type m:val="bar"/></m:fPr>
            <m:num><m:r><m:t>a</m:t></m:r></m:num>
            <m:den><m:r><m:t>b</m:t></m:r></m:den>
          </m:f>
        </m:oMath>
        """
        XCTAssertEqual(EquationImportMapping.ommlToLaTeX(xml), "\\frac{a}{b}")
    }

    func testOMMLRadicalWithHiddenDegreeConvertsToLatexSqrt() {
        let xml = """
        \(ommlNamespaceOpen)
          <m:rad>
            <m:radPr><m:degHide m:val="1"/></m:radPr>
            <m:deg/>
            <m:e><m:r><m:t>9</m:t></m:r></m:e>
          </m:rad>
        </m:oMath>
        """
        XCTAssertEqual(EquationImportMapping.ommlToLaTeX(xml), "\\sqrt{9}")
    }

    func testOMMLRadicalWithVisibleDegreeConvertsToLatexBracketedSqrt() {
        let xml = """
        \(ommlNamespaceOpen)
          <m:rad>
            <m:radPr/>
            <m:deg><m:r><m:t>3</m:t></m:r></m:deg>
            <m:e><m:r><m:t>8</m:t></m:r></m:e>
          </m:rad>
        </m:oMath>
        """
        XCTAssertEqual(EquationImportMapping.ommlToLaTeX(xml), "\\sqrt[3]{8}")
    }

    func testOMMLSuperscriptConvertsToLatexSuperscript() {
        let xml = """
        \(ommlNamespaceOpen)
          <m:sSup>
            <m:sSupPr/>
            <m:e><m:r><m:t>x</m:t></m:r></m:e>
            <m:sup><m:r><m:t>2</m:t></m:r></m:sup>
          </m:sSup>
        </m:oMath>
        """
        XCTAssertEqual(EquationImportMapping.ommlToLaTeX(xml), "x^{2}")
    }

    func testOMMLSubSupConvertsToLatexSubscriptThenSuperscript() {
        let xml = """
        \(ommlNamespaceOpen)
          <m:sSubSup>
            <m:e><m:r><m:t>x</m:t></m:r></m:e>
            <m:sub><m:r><m:t>i</m:t></m:r></m:sub>
            <m:sup><m:r><m:t>2</m:t></m:r></m:sup>
          </m:sSubSup>
        </m:oMath>
        """
        XCTAssertEqual(EquationImportMapping.ommlToLaTeX(xml), "x_{i}^{2}")
    }

    func testOMMLNarySumWithLimitsConvertsToLatexSum() {
        let xml = """
        \(ommlNamespaceOpen)
          <m:nary>
            <m:naryPr>
              <m:chr m:val="\u{2211}"/>
              <m:limLoc m:val="undOvr"/>
            </m:naryPr>
            <m:sub><m:r><m:t>i=1</m:t></m:r></m:sub>
            <m:sup><m:r><m:t>n</m:t></m:r></m:sup>
            <m:e><m:r><m:t>i</m:t></m:r></m:e>
          </m:nary>
        </m:oMath>
        """
        XCTAssertEqual(EquationImportMapping.ommlToLaTeX(xml), "\\sum_{i=1}^{n} i")
    }

    func testOMMLNaryIntegralConvertsToLatexInt() {
        let xml = """
        \(ommlNamespaceOpen)
          <m:nary>
            <m:naryPr><m:chr m:val="\u{222B}"/></m:naryPr>
            <m:sub><m:r><m:t>a</m:t></m:r></m:sub>
            <m:sup><m:r><m:t>b</m:t></m:r></m:sup>
            <m:e><m:r><m:t>f(x)</m:t></m:r></m:e>
          </m:nary>
        </m:oMath>
        """
        XCTAssertEqual(EquationImportMapping.ommlToLaTeX(xml), "\\int_{a}^{b} f(x)")
    }

    func testOMMLPlainTextRunPassesThroughUnchanged() {
        let xml = "\(ommlNamespaceOpen)<m:r><m:t>a+b=c</m:t></m:r></m:oMath>"
        XCTAssertEqual(EquationImportMapping.ommlToLaTeX(xml), "a+b=c")
    }

    // MARK: - Malformed input degrades gracefully (never throws/crashes)

    func testMalformedOMMLXMLFallsBackToTheOriginalSourceString() {
        let malformed = "<m:oMath><m:r><m:t>unterminated"
        XCTAssertEqual(EquationImportMapping.ommlToLaTeX(malformed), malformed)
    }

    func testEmptyOMMLStringFallsBackGracefully() {
        XCTAssertEqual(EquationImportMapping.ommlToLaTeX(""), "")
    }

    func testUnrecognizedStarMathWordsPassThroughLiterallyRatherThanBeingDropped() {
        // "foobar" is not a recognized StarMath keyword or symbol -
        // best-effort pass-through, per the file header's degrade-
        // gracefully posture (never silently drop content).
        XCTAssertEqual(EquationImportMapping.starMathToLaTeX("foobar + 1"), "foobar + 1")
    }

    // MARK: - Block construction + the "unedited round-trip" baseline mechanism

    func testEquationBlockFromStarMathStoresLatexAndPreservesOriginal() {
        let block = EquationImportMapping.equationBlock(fromStarMath: "a over b")
        XCTAssertEqual(block.type, .equation)
        XCTAssertEqual(block.attributes["latex"]?.stringValue, "\\frac{a}{b}")
        XCTAssertEqual(block.attributes[EquationImportMapping.originalStarMathKey]?.stringValue, "a over b")
        XCTAssertEqual(block.attributes[EquationImportMapping.importBaselineKey]?.stringValue, "\\frac{a}{b}")
    }

    func testEquationBlockFromOMMLStoresLatexAndPreservesOriginal() {
        let xml = "\(ommlNamespaceOpen)<m:r><m:t>x</m:t></m:r></m:oMath>"
        let block = EquationImportMapping.equationBlock(fromOMML: xml)
        XCTAssertEqual(block.attributes["latex"]?.stringValue, "x")
        XCTAssertEqual(block.attributes[EquationImportMapping.originalOMMLKey]?.stringValue, xml)
    }

    func testIsUneditedIsTrueImmediatelyAfterImport() {
        let block = EquationImportMapping.equationBlock(fromStarMath: "sqrt {9}")
        XCTAssertTrue(EquationImportMapping.isUnedited(block))
    }

    func testIsUneditedIsFalseAfterTheLatexAttributeChanges() {
        var block = EquationImportMapping.equationBlock(fromStarMath: "sqrt {9}")
        block.attributes["latex"] = .string("\\sqrt{16}") // simulates a StarMathEditor edit
        XCTAssertFalse(EquationImportMapping.isUnedited(block))
    }

    func testIsUneditedIsTrueForABlockNeverImportedThroughThisMapping() {
        var block = Block(type: .equation)
        block.attributes["latex"] = .string("x^2")
        XCTAssertTrue(EquationImportMapping.isUnedited(block), "no recorded baseline means nothing to treat as edited")
    }
}
