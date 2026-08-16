import Foundation

// MARK: - VBASubroutineSignature

/// One `Sub`/`Function` declaration line's worth of signal - name and
/// parameter list, never the body. Per the design contract's own
/// wording ("not full statement-level parsing"), `Property Get/Let/Set`
/// procedures are intentionally NOT recognized - the contract names
/// `Sub`/`Function` only, and a named escape hatch (a real ANTLR4
/// grammar) already exists for anyone who needs full fidelity later.
public struct VBASubroutineSignature: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case sub = "Sub"
        case function = "Function"
    }

    public var kind: Kind
    public var name: String
    /// Raw parameter text per parameter (e.g. `"ByRef arr() As Variant"`),
    /// not further decomposed into name/type/modifier - "light" parsing.
    public var parameters: [String]
    /// `Function`'s own `As <Type>` clause; always `nil` for `Sub`
    /// (VBA `Sub`s have no return type).
    public var returnType: String?
    /// `"Public"` / `"Private"` / `"Friend"`, or `nil` when the
    /// declaration omits a visibility keyword (VBA's default is Public).
    public var visibility: String?
    public var isStatic: Bool

    public init(
        kind: Kind,
        name: String,
        parameters: [String],
        returnType: String? = nil,
        visibility: String? = nil,
        isStatic: Bool = false
    ) {
        self.kind = kind
        self.name = name
        self.parameters = parameters
        self.returnType = returnType
        self.visibility = visibility
        self.isStatic = isStatic
    }
}

// MARK: - VBAModuleOutline

/// The light outline `VBAOutlineParser.parse` produces from one already
/// MS-OVBA-decompressed module's source text. Deliberately NOT a full
/// grammar tree - module name, routine signatures, a leading doc-comment
/// block, and a called-API census, per the design contract's own scope
/// line.
public struct VBAModuleOutline: Codable, Sendable, Hashable {
    public var moduleName: String
    public var subroutines: [VBASubroutineSignature]
    /// The module's leading comment block (before the first real code
    /// line), if any - see `VBAOutlineParser.moduleDocComment` for the
    /// exact extraction rule. `nil` when the module has no such header.
    public var docComment: String?
    /// Recognizable Win32/VBA API call patterns found anywhere in the
    /// module's source (`VBAOutlineParser.apiCensusPatterns` is the fixed,
    /// documented, non-exhaustive list) - "a useful signal for the
    /// translation step, not a security boundary" per the design
    /// contract's own wording. Order matches the fixed list, so it is
    /// deterministic across calls on identical source.
    public var calledAPIs: [String]

    public init(
        moduleName: String,
        subroutines: [VBASubroutineSignature],
        docComment: String?,
        calledAPIs: [String]
    ) {
        self.moduleName = moduleName
        self.subroutines = subroutines
        self.docComment = docComment
        self.calledAPIs = calledAPIs
    }
}

// MARK: - VBAOutlineParser

/// A LIGHT outline parse over already-decompressed VBA module source
/// text - module name, `Sub`/`Function` signatures, a leading doc-comment
/// block, and a called-API census. Explicitly NOT a full VBA grammar: no
/// statement-level parsing, no expression evaluation, no control-flow
/// awareness. Pure: `String` in, `VBAModuleOutline` out, never throws -
/// absence of a recognizable pattern is not an error for a scanner this
/// light, it just means that field comes back empty/nil.
public enum VBAOutlineParser {

    /// Parses one module's decompressed source text into its outline.
    /// `fallbackModuleName` is used when the source has no
    /// `Attribute VB_Name = "..."` line (the VBE-generated line that
    /// normally carries the module's real name) - typically the OLE
    /// stream's own name, supplied by the caller (`MacroCompatLayer`).
    public static func parse(source: String, fallbackModuleName: String) -> VBAModuleOutline {
        let lines = source.components(separatedBy: .newlines)
        return VBAModuleOutline(
            moduleName: Self.moduleName(from: lines) ?? fallbackModuleName,
            subroutines: Self.subroutineSignatures(in: lines),
            docComment: Self.moduleDocComment(from: lines),
            calledAPIs: Self.calledAPICensus(in: source)
        )
    }

    // MARK: - Module name

    private static let vbNameRegex = try! NSRegularExpression(
        pattern: #"^\s*Attribute\s+VB_Name\s*=\s*"([^"]*)"\s*$"#,
        options: [.caseInsensitive]
    )

    static func moduleName(from lines: [String]) -> String? {
        for line in lines {
            if let name = Self.firstCapture(vbNameRegex, in: line, group: 1) {
                return name
            }
        }
        return nil
    }

    // MARK: - Sub/Function signatures

    private static let subroutineStartRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:(Public|Private|Friend)\s+)?(?:(Static)\s+)?(Sub|Function)\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("#,
        options: [.caseInsensitive]
    )

    private static let returnTypeRegex = try! NSRegularExpression(
        pattern: #"^\s*As\s+([A-Za-z_][A-Za-z0-9_.]*)"#,
        options: [.caseInsensitive]
    )

    /// Scans every line for a `Sub`/`Function` declaration start. Only
    /// single-line signatures are recognized - a signature split across
    /// lines via VBA's ` _` continuation is a documented "light parser"
    /// limitation (the routine is still recorded, with an empty
    /// parameter list, rather than silently dropped).
    static func subroutineSignatures(in lines: [String]) -> [VBASubroutineSignature] {
        var results: [VBASubroutineSignature] = []
        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = subroutineStartRegex.firstMatch(in: line, range: range) else { continue }
            guard let kindText = Self.captured(match, group: 3, in: line),
                  let kind = VBASubroutineSignature.Kind(rawValue: kindText.prefix(1).uppercased() + kindText.dropFirst().lowercased()) else { continue }
            guard let name = Self.captured(match, group: 4, in: line) else { continue }
            let visibility = Self.captured(match, group: 1, in: line)
            let isStatic = Self.captured(match, group: 2, in: line) != nil

            guard let fullRange = Range(match.range, in: line) else { continue }
            let afterOpenParen = fullRange.upperBound

            guard let (paramsText, afterCloseParen) = Self.matchingParams(in: line, afterOpenParen: afterOpenParen) else {
                results.append(VBASubroutineSignature(kind: kind, name: name, parameters: [], returnType: nil, visibility: visibility, isStatic: isStatic))
                continue
            }
            let parameters = Self.splitParameters(paramsText)
            let remainder = String(line[afterCloseParen...])
            let returnType = kind == .function ? Self.firstCapture(returnTypeRegex, in: remainder, group: 1) : nil
            results.append(VBASubroutineSignature(kind: kind, name: name, parameters: parameters, returnType: returnType, visibility: visibility, isStatic: isStatic))
        }
        return results
    }

    /// Depth-aware scan for the parenthesis matching the one just before
    /// `afterOpenParen` - a plain `[^)]*` regex would stop at the FIRST
    /// `)`, which is wrong the moment a parameter uses an array type
    /// (`arr()`). Returns `nil` (rather than throwing - this is a light
    /// parser, not a validator) when no matching close paren exists on
    /// this same line.
    private static func matchingParams(in line: String, afterOpenParen: String.Index) -> (String, String.Index)? {
        var depth = 1
        var index = afterOpenParen
        let start = afterOpenParen
        while index < line.endIndex {
            let c = line[index]
            if c == "(" {
                depth += 1
            } else if c == ")" {
                depth -= 1
                if depth == 0 {
                    return (String(line[start..<index]), line.index(after: index))
                }
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// Splits a parameter list on top-level commas (depth-aware, so a
    /// default-value expression's own parens/commas don't fragment a
    /// single parameter), trimming whitespace on each entry.
    private static func splitParameters(_ text: String) -> [String] {
        let trimmedWhole = text.trimmingCharacters(in: .whitespaces)
        guard !trimmedWhole.isEmpty else { return [] }
        var parts: [String] = []
        var depth = 0
        var current = ""
        for c in trimmedWhole {
            if c == "(" {
                depth += 1
                current.append(c)
            } else if c == ")" {
                depth -= 1
                current.append(c)
            } else if c == "," && depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(c)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    // MARK: - Module doc comment

    private static let attributeLineRegex = try! NSRegularExpression(
        pattern: #"^Attribute\s+VB_"#,
        options: [.caseInsensitive]
    )

    /// The module's leading comment block: every `'`-prefixed comment
    /// line (and blank line) from the top of the source up to - but not
    /// including - the first line that is neither blank, nor a VBE
    /// `Attribute VB_*` metadata line, nor a comment. `nil` when no
    /// comment line was found before that point.
    static func moduleDocComment(from lines: [String]) -> String? {
        var commentLines: [String] = []
        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if Self.firstCapture(attributeLineRegex, in: trimmed, group: 0) != nil { continue }
            if trimmed.hasPrefix("'") {
                commentLines.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            break
        }
        guard !commentLines.isEmpty else { return nil }
        return commentLines.joined(separator: "\n")
    }

    // MARK: - Called-API census

    /// Fixed, documented, non-exhaustive list of recognizable Win32/VBA
    /// automation call patterns - "a useful signal for the translation
    /// step, not a security boundary" (design contract's own wording).
    /// Order here is the order results come back in.
    static let apiCensusPatterns: [String] = [
        "Shell",
        "ShellExecute",
        "WinExec",
        "CreateObject",
        "GetObject",
        "Environ",
        "Kill",
        "FileCopy",
        "URLDownloadToFile",
        "SendKeys",
        "RegRead",
        "RegWrite",
        "RegDelete",
    ]

    private static let declareLibRegex = try! NSRegularExpression(
        pattern: #"\bDeclare\s+(?:PtrSafe\s+)?(?:Function|Sub)\s+\w+\s+Lib\b"#,
        options: [.caseInsensitive]
    )

    static func calledAPICensus(in source: String) -> [String] {
        var found: [String] = []
        for name in apiCensusPatterns {
            // Matches BOTH call styles VBA allows: `Name(...)` (used in an
            // expression) and the bare statement form with no parens at
            // all (`Shell "cmd.exe"`, common for Sub-shaped calls whose
            // return value is discarded) - just a word-boundary match on
            // the identifier itself, per the design contract's own "a
            // simple scan... not a security boundary" framing (a literal
            // named "Shell" is an acceptable false positive here).
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: name))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            if Self.firstCapture(regex, in: source, group: 0) != nil {
                found.append(name)
            }
        }
        // A Win32 API `Declare` is a DECLARATION, not a call site - kept
        // as its own distinct entry rather than folded into the list
        // above, and always reported last.
        if Self.firstCapture(declareLibRegex, in: source, group: 0) != nil {
            found.append("Declare ... Lib (Win32 API)")
        }
        return found
    }

    // MARK: - NSRegularExpression helpers

    private static func firstCapture(_ regex: NSRegularExpression, in text: String, group: Int) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return Self.captured(match, group: group, in: text)
    }

    private static func captured(_ match: NSTextCheckingResult, group: Int, in text: String) -> String? {
        guard group < match.numberOfRanges else { return nil }
        let nsRange = match.range(at: group)
        guard nsRange.location != NSNotFound, let range = Range(nsRange, in: text) else { return nil }
        return String(text[range])
    }
}
