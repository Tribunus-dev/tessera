import Foundation

// MARK: - EquationImportMapping
//
// Item 2.14 (StarMathEditor - LaTeX-first over SwiftMath), the import
// half of the design contract: "import maps ODF StarMath 5.0
// annotations and OMML to LaTeX, preserving originals for unedited
// round-trip."
//
// `equation.latex` (`Block.attributes["latex"]`) stays the ONE
// canonical field every consumer reads (`BlockRenderer.renderEquation`,
// `DocumentExporter`'s `.equation` case, `StarMathEditor`) - this file
// never becomes a second source of truth. The ORIGINAL non-LaTeX
// source (the exact StarMath text or OMML XML a document arrived
// with) is preserved verbatim alongside it, under its OWN attribute
// key (`originalStarMathKey` / `originalOMMLKey`), never merged into
// "latex" - see `equationBlock(fromStarMath:)`/`(fromOMML:)`.
//
// **The "unedited round-trip" mechanism.** A future export path wants
// to write back the ORIGINAL StarMath/OMML byte-for-byte when the
// user never touched the equation, and fall back to a fresh LaTeX-only
// re-serialization only once they've actually edited it through
// `StarMathEditor`. This file has no signal for "the user edited this"
// on its own (it only ever runs at IMPORT time) - so it also records
// `importBaselineKey`: the LaTeX THIS FILE produced at import time.
// `isUnedited(_:)` compares the block's CURRENT `latex` against that
// baseline; equal means unedited (the future exporter should prefer
// the preserved original), different means the user changed the LaTeX
// (fall back to LaTeX-only re-serialization). This mirrors
// `FieldController.FieldSpec.dirty`'s own shape: a stored baseline the
// CALLER compares against, not a boolean this file invents new
// machinery to keep in sync as `latex` changes out from under it.
//
// **This file ships a pure conversion function, no I/O.** Per this
// wave's file list: "no I/O bridge file is in your list this wave, so
// wire it as a standalone testable function; a future I/O wave calls
// it." `starMathToLaTeX`/`ommlToLaTeX` take a string, return a string -
// no `FlatODFReader`/`WriterBridgeFilter` wiring here.
//
// **SCOPE (honesty, testing-doctrine.md rule 10).** Neither grammar is
// implemented to full spec coverage - both converters cover a
// well-documented, representative common subset, grounded in real
// LibreOffice/OOXML reference material (not guessed syntax), matching
// item 2.14's own "Effort M" sizing rather than a full parser-generator
// project:
//
//   StarMath 5.0 (LibreOffice Math "Command Reference", Math Guide
//   appendix A - https://books.libreoffice.org/en/MG252/MG25206-CommandReference.html):
//   `over` (fraction), `sqrt {}`/`nroot {}{}` (roots), `^`/`_` and the
//   word forms `sup`/`sub` (super/subscript), `sum`/`int`/`prod` with
//   `from`/`to` limits, `%name` Greek letters (`%alpha`, `%GAMMA`),
//   `<>`/`neq`, `<=`/`leslant`, `>=`/`geslant`, `+-`/`plusminus`,
//   `times`, `cdot`, `div`, `infinity`, and `{}` grouping. Multi-token
//   UNBRACED `from`/`to` limits (`sum from k = 1 to n ...`) are not
//   disambiguated - the fixtures use explicit braces around multi-token
//   limits (`sum from {k=1} to {n} ...`), which is itself valid
//   StarMath and is what LibreOffice's own `.fodt`/`.fods` save format
//   always emits (LO round-trips through explicit braces), so the
//   actually-covered case is real machine-generated documents, not
//   every hand-typed shorthand a human might type into the Math editor.
//
//   OMML (ECMA-376 / OOXML math; datypic.com schema reference -
//   https://www.datypic.com/sc/ooxml/e-m_oMath.html,
//   http://www.datypic.com/sc/ooxml/e-m_rad-1.html,
//   http://www.datypic.com/sc/ooxml/e-m_nary-1.html): `m:oMath` root,
//   `m:r`/`m:t` (text runs), `m:f` (`m:num`/`m:den`), `m:sSup`/`m:sSub`/
//   `m:sSubSup`, `m:rad` (`m:deg`/`m:e`, `m:radPr/m:degHide` for a bare
//   `sqrt`), `m:nary` (`m:naryPr/m:chr` + `m:sub`/`m:sup`/`m:e`, for
//   sum/integral/product), `m:d` (delimiter/paren wrapper). Unrecognized
//   wrapper elements (`m:acc`, `m:box`, `m:groupChr`, ...) degrade to
//   their concatenated children rather than vanishing, so text content
//   still surfaces even where the specific math structure doesn't.
public enum EquationImportMapping {

    /// Attribute key holding the original StarMath 5.0 source verbatim,
    /// set only when a `.equation` block was imported via
    /// `equationBlock(fromStarMath:)`.
    public static let originalStarMathKey = "originalStarMath"
    /// Attribute key holding the original OMML XML verbatim, set only
    /// when a `.equation` block was imported via `equationBlock(fromOMML:)`.
    public static let originalOMMLKey = "originalOMML"
    /// Attribute key holding the LaTeX THIS FILE produced at import
    /// time - the `isUnedited(_:)` dirty-check baseline. See the file
    /// header's "unedited round-trip mechanism" section.
    public static let importBaselineKey = "latexImportBaseline"

    // MARK: - Block construction (the future I/O wave's entry point)

    /// Builds a new `.equation` block from a StarMath 5.0 source
    /// string: converts it to LaTeX (the canonical field), preserves
    /// the original StarMath verbatim, and records the import
    /// baseline. See the file header.
    public static func equationBlock(fromStarMath starMath: String, id: UUID = UUID()) -> Block {
        let latex = starMathToLaTeX(starMath)
        var block = Block(id: id, type: .equation)
        block.attributes["latex"] = .string(latex)
        block.attributes[originalStarMathKey] = .string(starMath)
        block.attributes[importBaselineKey] = .string(latex)
        return block
    }

    /// Builds a new `.equation` block from an OMML XML fragment (a
    /// `w:oMath`/`m:oMath` element and its descendants): converts it to
    /// LaTeX, preserves the original OMML verbatim, and records the
    /// import baseline. See the file header.
    public static func equationBlock(fromOMML omml: String, id: UUID = UUID()) -> Block {
        let latex = ommlToLaTeX(omml)
        var block = Block(id: id, type: .equation)
        block.attributes["latex"] = .string(latex)
        block.attributes[originalOMMLKey] = .string(omml)
        block.attributes[importBaselineKey] = .string(latex)
        return block
    }

    /// `true` when `block`'s CURRENT `attributes["latex"]` still
    /// matches the baseline recorded at import time - the signal a
    /// future exporter uses to prefer the preserved original over a
    /// fresh LaTeX-only re-serialization. `true` (unedited) for a block
    /// with no recorded baseline (never imported through this mapping):
    /// conservative default - nothing to preserve, nothing to treat as
    /// edited either.
    public static func isUnedited(_ block: Block) -> Bool {
        guard let baseline = block.attributes[importBaselineKey]?.stringValue else { return true }
        return block.attributes["latex"]?.stringValue == baseline
    }

    // MARK: - StarMath 5.0 -> LaTeX

    /// Converts a StarMath 5.0 formula string to LaTeX. Never throws;
    /// unrecognized tokens pass through literally rather than being
    /// dropped (best-effort, matching this file's degrade-gracefully
    /// posture - see the header's scope note).
    public static func starMathToLaTeX(_ source: String) -> String {
        let tokens = StarMathTokenizer.tokenize(source)
        var parser = StarMathParser(tokens: tokens)
        return parser.parseExpression()
    }

    // MARK: - OMML -> LaTeX

    /// Converts an OMML XML fragment to LaTeX. Never throws: malformed
    /// XML (or XML with no recognizable `oMath` content) degrades to
    /// the ORIGINAL source string unchanged, a safe, honest fallback -
    /// matching `BlockRenderer.renderLaTeX`'s own "malformed data
    /// doesn't crash" contract downstream (an unparseable "LaTeX"
    /// string just becomes THAT renderer's visible error indicator,
    /// not a crash here).
    public static func ommlToLaTeX(_ xml: String) -> String {
        guard let data = xml.data(using: .utf8) else { return xml }
        let builder = OMMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else { return xml }
        return OMMLConverter.convert(root)
    }
}

// MARK: - StarMath tokenizer

/// A StarMath token. `{`/`}`/`^`/`_` are always their own token, even
/// glued to adjacent characters (`a^2` tokenizes as `a`, `^`, `2`);
/// everything else splits on whitespace - see the file header's scope
/// note on why this is sufficient for the covered (braced,
/// space-separated) subset.
enum StarMathToken: Equatable {
    case openBrace
    case closeBrace
    case caret
    case underscore
    case word(String)
}

enum StarMathTokenizer {
    static func tokenize(_ source: String) -> [StarMathToken] {
        var tokens: [StarMathToken] = []
        var current = ""
        func flush() {
            if !current.isEmpty {
                tokens.append(.word(current))
                current = ""
            }
        }
        for ch in source {
            switch ch {
            case " ", "\t", "\n", "\r":
                flush()
            case "{":
                flush(); tokens.append(.openBrace)
            case "}":
                flush(); tokens.append(.closeBrace)
            case "^":
                flush(); tokens.append(.caret)
            case "_":
                flush(); tokens.append(.underscore)
            default:
                current.append(ch)
            }
        }
        flush()
        return tokens
    }
}

// MARK: - StarMath parser (token stream -> LaTeX string)

/// Hand-rolled recursive-descent parser over `[StarMathToken]`,
/// producing LaTeX text directly (no intermediate AST - the LaTeX
/// target is itself brace-delimited and command-based, close enough to
/// the source shape that a direct transducer is the simpler, equally
/// correct choice for this file's covered subset). See the file header
/// for the exact grammar covered.
struct StarMathParser {
    private let tokens: [StarMathToken]
    private var pos = 0

    init(tokens: [StarMathToken]) {
        self.tokens = tokens
    }

    private var current: StarMathToken? {
        pos < tokens.count ? tokens[pos] : nil
    }

    private mutating func advance() {
        pos += 1
    }

    private mutating func matchWord(_ word: String) -> Bool {
        if case .word(let w) = current, w.caseInsensitiveCompare(word) == .orderedSame {
            advance()
            return true
        }
        return false
    }

    /// `Expr := Term` - kept as its own entry point (rather than callers
    /// using `parseTerm` directly) purely so every recursive call site
    /// below reads as "parse a full sub-expression," matching the
    /// vocabulary of a standard recursive-descent grammar; there's no
    /// production above `Term` today. `over` is NOT handled at this
    /// level - see `tryParseFactor`'s doc comment for why.
    mutating func parseExpression() -> String {
        parseTerm()
    }

    /// `Term := Factor*` - horizontal concatenation (juxtaposition),
    /// space-joined in the LaTeX output.
    private mutating func parseTerm() -> String {
        var parts: [String] = []
        while let part = tryParseFactor() {
            parts.append(part)
        }
        return parts.joined(separator: " ")
    }

    /// `Factor := Atom (('^' | 'sup') Sup | ('_' | 'sub') Sub | 'over'
    /// Factor)*` - postfix super/subscript AND the `over` (fraction)
    /// infix operator, both handled at THIS level, not `Term`'s or
    /// `Expr`'s.
    ///
    /// **Why `over` binds here, not at `Expr` level.** `over`'s real
    /// StarMath precedence sits ABOVE addition (`{a} over {b} + c` is
    /// `\frac{a}{b} + c`, not `\frac{a}{b+c}`) - it binds to its
    /// immediate neighbors, not to an entire accumulated `Term`. An
    /// earlier version of this parser split at `Expr` level
    /// (`Term ('over' Term)?`) and broke on exactly this shape: for
    /// `"x = {a} over {b}"`, `Term` for the left side would already
    /// have consumed "x", "=", AND "{a}" as three concatenated
    /// factors BEFORE `Expr` ever saw "over", producing the wrong
    /// `\frac{x = a}{b}` instead of `x = \frac{a}{b}`. Handling `over`
    /// as a postfix on the single preceding `Factor` (mirroring `^`/
    /// `_`'s own postfix shape) fixes this: "x" and "=" stay separate,
    /// earlier factors in the `Term`, and only the `{a}` immediately
    /// before "over" becomes the fraction's numerator.
    private mutating func tryParseFactor() -> String? {
        guard var result = tryParseAtom() else { return nil }
        while true {
            if matchSupMarker() {
                result += "^{\(parseSupSubOperand())}"
            } else if matchSubMarker() {
                result += "_{\(parseSupSubOperand())}"
            } else if matchWord("over") {
                let right = tryParseAtom() ?? ""
                result = "\\frac{\(result)}{\(right)}"
            } else {
                break
            }
        }
        return result
    }

    /// `true` (and consumes) for either the `^` token or the word form
    /// `sup` - checked and consumed as ONE atomic step so a `matchWord`
    /// side effect can never leak into the caller's separate `.caret`
    /// check (the bug this two-step form avoids: evaluating `current ==
    /// .caret || matchWord("sup")` would already have advanced past
    /// "sup" by the time a second `current == .caret` check ran).
    private mutating func matchSupMarker() -> Bool {
        if current == .caret { advance(); return true }
        return matchWord("sup")
    }

    private mutating func matchSubMarker() -> Bool {
        if current == .underscore { advance(); return true }
        return matchWord("sub")
    }

    /// The operand of a `^`/`_`: a braced group if present, else a
    /// single atom (so `a^2` and `a^{2}` both work).
    private mutating func parseSupSubOperand() -> String {
        if current == .openBrace {
            advance()
            let inner = parseExpression()
            if current == .closeBrace { advance() }
            return inner
        }
        return tryParseAtom() ?? ""
    }

    /// `Atom := Group | 'sqrt' Group | 'nroot' Group Group |
    ///          ('sum'|'int'|'prod') ('from' Operand)? ('to' Operand)? |
    ///          'lim' ('from' Operand)? | '%'name | symbol | word`
    private mutating func tryParseAtom() -> String? {
        switch current {
        case .openBrace:
            advance()
            let inner = parseExpression()
            if current == .closeBrace { advance() }
            // NOT re-wrapped in "{...}" here: LaTeX braces are pure
            // (invisible) grouping - they render identically present
            // or absent except where a COMMAND's argument syntax
            // requires them, and every such site in this file
            // (`\frac{}{}`, `\sqrt{}`, `^{}`/`_{}`) already adds its
            // own braces explicitly around whatever this function
            // returns. Re-wrapping here too would double them up (e.g.
            // `{a} over {b}` would emit `\frac{{a}}{{b}}` - harmless to
            // a LaTeX renderer, but needless noise `over`'s own
            // handling in `tryParseFactor` shouldn't have to strip
            // back off).
            return inner
        case .word(let w):
            return parseWordAtom(w)
        case .caret, .underscore, .closeBrace, nil:
            return nil
        }
    }

    private mutating func parseWordAtom(_ w: String) -> String {
        let lower = w.lowercased()
        switch lower {
        case "sqrt":
            advance()
            return "\\sqrt" + parseRequiredGroup()
        case "nroot":
            advance()
            let degree = StarMathParser.stripBraces(parseRequiredGroup())
            let radicand = parseRequiredGroup()
            return "\\sqrt[\(degree)]" + radicand
        case "sum", "int", "prod":
            advance()
            let command = lower == "sum" ? "\\sum" : (lower == "int" ? "\\int" : "\\prod")
            var out = command
            if matchWord("from") { out += "_{\(parseSupSubOperand())}" }
            if matchWord("to") { out += "^{\(parseSupSubOperand())}" }
            return out
        case "lim":
            advance()
            var out = "\\lim"
            if matchWord("from") { out += "_{\(parseSupSubOperand())}" }
            return out
        default:
            if w.hasPrefix("%") {
                advance()
                return StarMathParser.greekLatex(for: String(w.dropFirst()))
            }
            if let mapped = StarMathParser.symbolTable[lower] {
                advance()
                return mapped
            }
            advance()
            return w
        }
    }

    /// A required `{...}` group (sqrt/nroot's argument). Missing braces
    /// degrade to wrapping the next single atom, or an empty group -
    /// never a crash on malformed StarMath.
    private mutating func parseRequiredGroup() -> String {
        guard current == .openBrace else {
            if let atom = tryParseAtom() { return "{" + atom + "}" }
            return "{}"
        }
        advance()
        let inner = parseExpression()
        if current == .closeBrace { advance() }
        return "{" + inner + "}"
    }

    private static func stripBraces(_ s: String) -> String {
        guard s.hasPrefix("{"), s.hasSuffix("}"), s.count >= 2 else { return s }
        return String(s.dropFirst().dropLast())
    }

    /// Relation/operator words with no `^`/`_`/grouping role of their
    /// own - a flat word -> LaTeX-macro table.
    private static let symbolTable: [String: String] = [
        "<>": "\\neq", "neq": "\\neq",
        "<=": "\\leq", "leslant": "\\leq",
        ">=": "\\geq", "geslant": "\\geq",
        "+-": "\\pm", "plusminus": "\\pm",
        "times": "\\times",
        "cdot": "\\cdot",
        "div": "\\div",
        "infinity": "\\infty",
    ]

    /// `%name` Greek letters: `%pi` -> `\pi`, `%GAMMA` -> `\Gamma`
    /// (StarMath's own convention - all-caps selects the LaTeX
    /// capital-Greek macro, matching `%ALPHA`/`%alpha` both being
    /// valid Greek-letter forms in the Math Guide). `%infinity` is a
    /// documented alternate spelling of the bare `infinity` keyword,
    /// so it's special-cased ahead of the generic capitalization rule
    /// (which would otherwise produce the non-existent `\infinity`
    /// macro instead of `\infty`).
    private static func greekLatex(for name: String) -> String {
        guard !name.isEmpty else { return "\\%" }
        if name.caseInsensitiveCompare("infinity") == .orderedSame { return "\\infty" }
        if name == name.uppercased() {
            return "\\" + name.prefix(1).uppercased() + name.dropFirst().lowercased()
        }
        return "\\" + name.lowercased()
    }
}

// MARK: - OMML tree (XMLParser SAX callbacks -> a tiny generic tree)

/// A minimal generic XML element tree, scoped to this file's own OMML
/// conversion need (element name incl. prefix, attributes, ordered
/// element children, own leaf text). Mirrors the stack-of-open-frames
/// SAX-to-tree technique `FlatODFReader.swift`'s `FlatODFTreeBuilder`
/// established for this codebase (see that file), simplified: OMML
/// fragments are equation-sized, not whole-document-sized, so this
/// doesn't need that type's `office:binary-data` diversion or
/// mixed-content mid-element text/element interleaving - text runs
/// (`m:t`) are always OMML leaves.
final class OMMLNode {
    let name: String
    let attributes: [String: String]
    var children: [OMMLNode] = []
    var text: String = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }
}

final class OMMLTreeBuilder: NSObject, XMLParserDelegate {
    private var stack: [OMMLNode] = []
    private(set) var root: OMMLNode?

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = OMMLNode(name: elementName, attributes: attributeDict)
        stack.last?.children.append(node)
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { return }
        stack.last?.text += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        guard let finished = stack.popLast() else { return }
        if stack.isEmpty { root = finished }
    }
}

// MARK: - OMML -> LaTeX conversion

enum OMMLConverter {
    static func convert(_ node: OMMLNode) -> String {
        let mathRoot = localName(node.name) == "oMath" ? node : (findMathRoot(node) ?? node)
        return convertChildren(mathRoot)
    }

    private static func findMathRoot(_ node: OMMLNode) -> OMMLNode? {
        for child in node.children {
            if localName(child.name) == "oMath" { return child }
            if let found = findMathRoot(child) { return found }
        }
        return nil
    }

    /// Strips the `m:`/`w:`-style namespace prefix `XMLParser` hands
    /// back verbatim (`shouldProcessNamespaces = false`, matching
    /// `FlatODFReader`'s own choice and reason - see that file).
    private static func localName(_ qualified: String) -> String {
        guard let idx = qualified.firstIndex(of: ":") else { return qualified }
        return String(qualified[qualified.index(after: idx)...])
    }

    private static func firstChild(_ node: OMMLNode, named name: String) -> OMMLNode? {
        node.children.first { localName($0.name) == name }
    }

    private static func convertChildren(_ node: OMMLNode) -> String {
        node.children.compactMap(convertElement).joined(separator: " ")
    }

    private static func convertElement(_ node: OMMLNode) -> String? {
        switch localName(node.name) {
        case "r":
            if let t = firstChild(node, named: "t") { return escapeRun(t.text) }
            let inner = convertChildren(node)
            return inner.isEmpty ? nil : inner
        case "t":
            return escapeRun(node.text)
        case "f":
            let num = firstChild(node, named: "num").map(convertChildren) ?? ""
            let den = firstChild(node, named: "den").map(convertChildren) ?? ""
            return "\\frac{\(num)}{\(den)}"
        case "rad":
            let e = firstChild(node, named: "e").map(convertChildren) ?? ""
            let degNode = firstChild(node, named: "deg")
            let degText = degNode.map(convertChildren) ?? ""
            let degHidden = firstChild(node, named: "radPr").map { pr in
                pr.children.contains { localName($0.name) == "degHide" }
            } ?? false
            if degHidden || degText.trimmingCharacters(in: .whitespaces).isEmpty {
                return "\\sqrt{\(e)}"
            }
            return "\\sqrt[\(degText)]{\(e)}"
        case "sSup":
            let e = firstChild(node, named: "e").map(convertChildren) ?? ""
            let sup = firstChild(node, named: "sup").map(convertChildren) ?? ""
            return "\(e)^{\(sup)}"
        case "sSub":
            let e = firstChild(node, named: "e").map(convertChildren) ?? ""
            let sub = firstChild(node, named: "sub").map(convertChildren) ?? ""
            return "\(e)_{\(sub)}"
        case "sSubSup":
            let e = firstChild(node, named: "e").map(convertChildren) ?? ""
            let sub = firstChild(node, named: "sub").map(convertChildren) ?? ""
            let sup = firstChild(node, named: "sup").map(convertChildren) ?? ""
            return "\(e)_{\(sub)}^{\(sup)}"
        case "nary":
            let pr = firstChild(node, named: "naryPr")
            let chr = pr.flatMap { firstChild($0, named: "chr") }
            let symbol = chr?.attributes["m:val"] ?? chr?.attributes["val"]
            var out = naryCommand(for: symbol)
            let sub = firstChild(node, named: "sub").map(convertChildren) ?? ""
            let sup = firstChild(node, named: "sup").map(convertChildren) ?? ""
            if !sub.trimmingCharacters(in: .whitespaces).isEmpty { out += "_{\(sub)}" }
            if !sup.trimmingCharacters(in: .whitespaces).isEmpty { out += "^{\(sup)}" }
            let e = firstChild(node, named: "e").map(convertChildren) ?? ""
            return e.isEmpty ? out : out + " " + e
        case "d":
            let inner = convertChildren(node)
            return "\\left(\(inner)\\right)"
        default:
            // Unrecognized wrapper (m:oMathPara, m:acc, m:box, m:groupChr,
            // ...) - descend into children so text content still
            // surfaces rather than silently vanishing (this file's
            // degrade-gracefully posture, see the file header).
            let inner = convertChildren(node)
            return inner.isEmpty ? nil : inner
        }
    }

    private static func naryCommand(for chr: String?) -> String {
        switch chr {
        case "\u{2211}": return "\\sum" // SUM (Sigma)
        case "\u{222B}": return "\\int" // INTEGRAL
        case "\u{220F}": return "\\prod" // PRODUCT (Pi)
        default: return "\\sum"
        }
    }

    /// LaTeX-escapes the few characters math mode treats specially so
    /// a literal `%`/`&`/`#`/`$` inside an OMML text run doesn't
    /// corrupt the surrounding LaTeX structure; OOXML's own minus-sign
    /// glyph (U+2212, distinct from ASCII hyphen) normalizes to `-`.
    private static func escapeRun(_ text: String) -> String {
        var out = ""
        for ch in text {
            switch ch {
            case "%", "&", "#", "$": out += "\\" + String(ch)
            case "\u{2212}": out += "-"
            default: out.append(ch)
            }
        }
        return out
    }
}
