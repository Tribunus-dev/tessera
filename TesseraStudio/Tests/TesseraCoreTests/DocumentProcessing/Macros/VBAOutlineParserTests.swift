import XCTest
@testable import TesseraCore

// MARK: - VBAOutlineParserTests
//
// Contract: this track's brief (P2-D item 2.13, "VBAOutlineParser.swift:
// a LIGHT outline parse over decompressed module source - module names,
// Sub/Function signatures (name + parameter list, not full statement-
// level parsing), any doc-comment-style leading comments, and a
// called-API census... Pure function: source text -> a VBAModuleOutline
// value type"). Fixtures are hand-written VBA module source text (this
// agent's own, not extracted from any real macro) - a scanner this
// light needs no real-file provenance the way the binary decompressor
// does; the fixtures exist purely to exercise the documented extraction
// rules.

final class VBAOutlineParserTests: DoctrineTestCase {

    // MARK: - Module name

    func testParseExtractsModuleNameFromAttributeVBName() {
        let source = "Attribute VB_Name = \"Module1\"\nSub Foo()\nEnd Sub\n"
        let outline = VBAOutlineParser.parse(source: source, fallbackModuleName: "fallback")
        XCTAssertEqual(outline.moduleName, "Module1")
    }

    func testParseFallsBackToSuppliedNameWhenNoAttributeVBNameLine() {
        let source = "Sub Baz()\nEnd Sub\n"
        let outline = VBAOutlineParser.parse(source: source, fallbackModuleName: "StreamName1")
        XCTAssertEqual(outline.moduleName, "StreamName1")
    }

    // MARK: - Sub/Function signatures

    func testParseExtractsSubAndFunctionSignaturesWithParametersAndReturnType() {
        let source = """
        Attribute VB_Name = "Module1"
        Public Sub Foo(x As Integer, ByRef arr() As Variant)
            Dim y As Long
        End Sub

        Private Function Bar() As String
            Bar = "hi"
        End Function
        """
        let outline = VBAOutlineParser.parse(source: source, fallbackModuleName: "fallback")
        XCTAssertEqual(outline.subroutines.count, 2)

        let foo = outline.subroutines[0]
        XCTAssertEqual(foo.kind, .sub)
        XCTAssertEqual(foo.name, "Foo")
        XCTAssertEqual(foo.parameters, ["x As Integer", "ByRef arr() As Variant"])
        XCTAssertEqual(foo.visibility, "Public")
        XCTAssertNil(foo.returnType)
        XCTAssertFalse(foo.isStatic)

        let bar = outline.subroutines[1]
        XCTAssertEqual(bar.kind, .function)
        XCTAssertEqual(bar.name, "Bar")
        XCTAssertEqual(bar.parameters, [])
        XCTAssertEqual(bar.visibility, "Private")
        XCTAssertEqual(bar.returnType, "String")
    }

    func testParseHandlesArrayParameterWithEmptyParensCorrectly() {
        // A naive `[^)]*)` regex would stop at the FIRST `)` (the
        // array's own empty parens) and mis-parse the parameter list -
        // this is exactly the depth-aware scan's own reason to exist.
        let source = "Sub Foo(arr() As Variant, n As Long)\nEnd Sub\n"
        let outline = VBAOutlineParser.parse(source: source, fallbackModuleName: "x")
        XCTAssertEqual(outline.subroutines.first?.parameters, ["arr() As Variant", "n As Long"])
    }

    func testParseRecognizesStaticModifier() {
        let source = "Public Static Sub Foo()\nEnd Sub\n"
        let outline = VBAOutlineParser.parse(source: source, fallbackModuleName: "x")
        XCTAssertEqual(outline.subroutines.first?.isStatic, true)
    }

    func testParseDefaultsVisibilityToNilWhenOmitted() {
        let source = "Sub Foo()\nEnd Sub\n"
        let outline = VBAOutlineParser.parse(source: source, fallbackModuleName: "x")
        XCTAssertNil(outline.subroutines.first?.visibility)
    }

    func testParseFindsNoSubroutinesInAModuleWithNone() {
        let source = "Attribute VB_Name = \"Empty\"\nDim x As Integer\n"
        let outline = VBAOutlineParser.parse(source: source, fallbackModuleName: "x")
        XCTAssertEqual(outline.subroutines, [])
    }

    func testParseIgnoresPropertyProcedures() {
        // Explicitly out of scope per the design contract's own "not
        // full statement-level parsing" - only Sub/Function.
        let source = "Property Get Foo() As Long\nFoo = 1\nEnd Property\n"
        let outline = VBAOutlineParser.parse(source: source, fallbackModuleName: "x")
        XCTAssertEqual(outline.subroutines, [])
    }

    // MARK: - Module doc comment

    func testParseExtractsLeadingCommentBlockAsDocComment() {
        let source = """
        Attribute VB_Name = "Module1"
        ' Does a thing.
        ' Second line.
        Public Sub Foo()
        End Sub
        """
        let outline = VBAOutlineParser.parse(source: source, fallbackModuleName: "x")
        XCTAssertEqual(outline.docComment, "Does a thing.\nSecond line.")
    }

    func testParseReturnsNilDocCommentWhenNoLeadingComment() {
        let source = "Sub Baz()\nEnd Sub\n"
        let outline = VBAOutlineParser.parse(source: source, fallbackModuleName: "x")
        XCTAssertNil(outline.docComment)
    }

    // MARK: - Called-API census

    func testParseFindsShellCalledWithoutParentheses() {
        // `Shell "cmd.exe"` (statement form, no parens) is common,
        // realistic VBA - the census must not require a trailing `(`.
        let source = "Sub Foo()\n    Shell \"cmd.exe\"\nEnd Sub\n"
        let outline = VBAOutlineParser.parse(source: source, fallbackModuleName: "x")
        XCTAssertEqual(outline.calledAPIs, ["Shell"])
    }

    func testParseFindsCreateObjectCalledWithParentheses() {
        let source = "Sub Foo()\n    Set o = CreateObject(\"Word.Application\")\nEnd Sub\n"
        let outline = VBAOutlineParser.parse(source: source, fallbackModuleName: "x")
        XCTAssertEqual(outline.calledAPIs, ["CreateObject"])
    }

    func testParseFindsDeclareLibAsItsOwnDistinctEntry() {
        let source = "Declare Function GetTickCount Lib \"kernel32\" () As Long\nSub Quiet()\nEnd Sub\n"
        let outline = VBAOutlineParser.parse(source: source, fallbackModuleName: "x")
        XCTAssertEqual(outline.calledAPIs, ["Declare ... Lib (Win32 API)"])
    }

    func testParseReturnsEmptyCalledAPIsWhenNoneRecognized() {
        let source = "Sub DoNothing()\n    Dim x As Integer\n    x = 1\nEnd Sub\n"
        let outline = VBAOutlineParser.parse(source: source, fallbackModuleName: "x")
        XCTAssertEqual(outline.calledAPIs, [])
    }

    func testParseDoesNotFalsePositiveOnAPINameAsSubstringOfLongerIdentifier() {
        // "Environment" contains "Environ" but must not match - word
        // boundaries, not substring search.
        let source = "Sub Foo()\n    Dim Environment As String\nEnd Sub\n"
        let outline = VBAOutlineParser.parse(source: source, fallbackModuleName: "x")
        XCTAssertEqual(outline.calledAPIs, [])
    }

    func testParseCalledAPICensusOrderMatchesFixedListOrder() {
        let source = "Sub Foo()\n    RegRead \"x\"\n    Shell \"y\"\nEnd Sub\n"
        let outline = VBAOutlineParser.parse(source: source, fallbackModuleName: "x")
        // Shell precedes RegRead in VBAOutlineParser.apiCensusPatterns,
        // so it must come first in the result regardless of source order.
        XCTAssertEqual(outline.calledAPIs, ["Shell", "RegRead"])
    }
}
