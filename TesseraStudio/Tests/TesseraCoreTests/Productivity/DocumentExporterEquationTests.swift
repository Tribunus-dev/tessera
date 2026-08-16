import XCTest
@testable import TesseraCore

// MARK: - DocumentExporterEquationTests
//
// Contract: item 2.14's design contract - DocumentExporter's own
// `.equation` HTML export case, improved from the placeholder
// `<code>$latex$</code>` (per this track's item 2 brief: "improve the
// existing '.equation' HTML export case"). `textutil`'s HTML->DOCX/ODT
// pipeline (DocumentExporter.swift's own header) has no MathML support,
// so the export target is an embedded base64 PNG `<img>`, the same
// shape `.image` blocks already export - see `renderEquationHTML`'s
// doc comment. Scope matches `DocumentExporterTests.swift`'s own header:
// only `htmlPreview` (pure, no I/O) is exercised here.

final class DocumentExporterEquationTests: DoctrineTestCase {

    private let exporter = DocumentExporter()

    private func docWithEquation(latex: String) -> Doc {
        let id = UUID()
        var ast = DocumentAST()
        var block = Block(id: id, type: .equation)
        block.attributes["latex"] = .string(latex)
        ast.blocks[id] = block
        ast.rootChildren = [id]
        return Doc(title: "Equation Export Test", body: ast)
    }

    // MARK: - Determinism (doctrine rule 4)

    func testHtmlPreviewOfAnEquationIsDeterministicAcrossTwoIndependentPasses() throws {
        let doc = docWithEquation(latex: "\\frac{1}{2}")
        let first = try exporter.htmlPreview(doc)
        let second = try exporter.htmlPreview(doc)
        XCTAssertEqual(first, second)
    }

    // MARK: - Content: well-formed LaTeX renders an embedded <img>, not the old placeholder

    func testWellFormedEquationRendersAnEmbeddedBase64PNGImgTag() throws {
        let doc = docWithEquation(latex: "x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}")
        let html = try exporter.htmlPreview(doc)
        XCTAssertTrue(html.contains("<img src=\"data:image/png;base64,"), html)
        XCTAssertFalse(html.contains("<code>$"), "the old literal-$latex$ placeholder must be gone for a well-formed formula")
    }

    func testEmbeddedImageTagCarriesNonZeroWidthAndHeightAttributes() throws {
        let doc = docWithEquation(latex: "\\pi r^2")
        let html = try exporter.htmlPreview(doc)
        guard let widthRange = html.range(of: "width=\""), let heightRange = html.range(of: "height=\"") else {
            return XCTFail("expected width/height attributes on the embedded <img>: \(html)")
        }
        let widthTail = html[widthRange.upperBound...]
        let width = Int(widthTail.prefix(while: { $0.isNumber })) ?? 0
        let heightTail = html[heightRange.upperBound...]
        let height = Int(heightTail.prefix(while: { $0.isNumber })) ?? 0
        XCTAssertGreaterThan(width, 0)
        XCTAssertGreaterThan(height, 0)
    }

    // MARK: - Malformed / empty LaTeX degrades to the old literal placeholder (never throws)

    func testMalformedLatexFallsBackToTheLiteralPlaceholderNotACrash() throws {
        let doc = docWithEquation(latex: "\\frac{1")
        let html = try exporter.htmlPreview(doc)
        XCTAssertTrue(html.contains("<code>$\\frac{1$</code>"), html)
        XCTAssertFalse(html.contains("data:image/png"))
    }

    func testEmptyLatexRendersTheEmptyEquationPlaceholder() throws {
        let doc = docWithEquation(latex: "")
        let html = try exporter.htmlPreview(doc)
        XCTAssertTrue(html.contains("<code>[Empty equation]</code>"), html)
    }

    // MARK: - Missing attribute degrades to the empty placeholder, matching BlockRenderer's contract

    func testMissingLatexAttributeDegradesToTheEmptyPlaceholder() throws {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .equation) // no attributes["latex"]
        ast.rootChildren = [id]
        let html = try exporter.htmlPreview(Doc(title: "t", body: ast))
        XCTAssertTrue(html.contains("<code>[Empty equation]</code>"), html)
    }
}
