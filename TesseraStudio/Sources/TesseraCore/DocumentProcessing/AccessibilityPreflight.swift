import Foundation

// MARK: - AccessibilityIssue
//
// P2-D item 2.20 (Tagged PDF / PDF-UA). Native checks mirroring LO 7.1's
// own accessibility checker, surfaced BEFORE export rather than
// discovered after: missing image alt text, heading-level jumps (e.g.
// H1 directly to H3 with no H2), a missing document title, and a
// missing document language. Each maps to a real, named Matterhorn
// Protocol 1.1 checkpoint (docs/.scratch/sota-enterprise-report.md
// "2.20 Tagged PDF / PDF-UA") so the message is traceable to the
// contract, not an invented rule.

/// The kind of accessibility problem found. One case per check this
/// wave's contract names; `CaseIterable` so a totality-guard test can
/// pin the set independently (testing-doctrine.md rule 7).
public enum AccessibilityIssueKind: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
    case missingAltText
    case headingLevelJump
    case missingTitle
    case missingLanguage
}

/// How serious a finding is. Every kind below is mapped `.error` today
/// (see `AccessibilityPreflight`'s own doc comment on why) - the
/// distinction exists so a future check with a softer, best-practice-only
/// finding has somewhere to land without a new enum case.
public enum AccessibilityIssueSeverity: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
    case error
    case warning
}

/// One accessibility preflight finding. `blockID` is the jump-to
/// location for a block-scoped issue (missing alt text, a heading-level
/// jump lands on the OFFENDING heading); document-scoped issues (missing
/// title, missing language) carry `nil` since there is no single block
/// to point at.
public struct AccessibilityIssue: Codable, Sendable, Equatable, Hashable {
    public var kind: AccessibilityIssueKind
    public var severity: AccessibilityIssueSeverity
    public var message: String
    public var blockID: UUID?

    public init(
        kind: AccessibilityIssueKind,
        severity: AccessibilityIssueSeverity,
        message: String,
        blockID: UUID? = nil
    ) {
        self.kind = kind
        self.severity = severity
        self.message = message
        self.blockID = blockID
    }
}

// MARK: - AccessibilityPreflight

/// Pure, native accessibility checks over a ``Doc`` - no soffice, no I/O.
/// Every check below maps to one of the four items this wave's contract
/// names explicitly; severities are uniformly `.error` because each
/// checks a real Matterhorn/PDF-UA-1 blocking requirement (full semantic
/// tagging needs a title, a language, alt text on non-text content, and
/// a heading hierarchy with no skipped levels - Matterhorn Protocol 1.1,
/// see this file's header) rather than a softer style preference; a
/// future check with only a best-practice-level finding would use
/// `.warning` instead of a new severity scheme.
///
/// **Document language is NOT backed by a `Doc`/`DocumentMeta` field.**
/// Confirmed against the current data model (`Productivity/Block.swift`):
/// neither `Doc` nor `DocumentMeta` carries a language/locale concept
/// anywhere. Per this item's own CRITICAL SCOPING NOTE ("`<html
/// lang="...">` from whatever document-language concept exists, OR A
/// SENSIBLE DEFAULT"), this file does not invent one on `Doc`/`Block`
/// (both are outside this track's owned file list this wave, and a
/// third parallel track was independently modifying `Block.swift` at
/// the time this was written - see this wave's findings file). Instead
/// `language` is an ordinary parameter the caller supplies when it
/// knows one (from a future per-doc field, a system locale, an explicit
/// agent-tool argument - see `DocAccessibilityCheckTool`); `nil` means
/// "not tracked" and is reported as `.missingLanguage`, which is the
/// HONEST current state of every Tessera document today, not a
/// placeholder that can never fire.
public enum AccessibilityPreflight {

    /// Runs every check and returns the combined issue list, document
    /// order for block-scoped issues. Empty when the document is fully
    /// well-formed (see each check's own doc comment for exactly what
    /// "well-formed" means for that check).
    public static func run(_ doc: Doc, language: String? = nil) -> [AccessibilityIssue] {
        var issues: [AccessibilityIssue] = []
        issues.append(contentsOf: checkTitle(doc))
        issues.append(contentsOf: checkLanguage(language))
        issues.append(contentsOf: checkHeadingLevels(doc.body))
        issues.append(contentsOf: checkImageAltText(doc.body))
        return issues
    }

    // MARK: Missing title (Matterhorn 06-001: document title required)

    /// Well-formed when `doc.title` is non-blank, OR the body's first
    /// heading is non-blank (``Doc/displayTitle``'s own fallback chain -
    /// a doc that leans on its first heading as the title is fine; a doc
    /// that would fall all the way through to the literal "Untitled"
    /// placeholder is not).
    static func checkTitle(_ doc: Doc) -> [AccessibilityIssue] {
        let trimmedTitle = doc.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return [] }
        if let heading = Doc.firstHeadingText(in: doc.body), !heading.isEmpty { return [] }
        return [AccessibilityIssue(
            kind: .missingTitle,
            severity: .error,
            message: "Document has no title and no heading to derive one from - export would fall back to the \"Untitled\" placeholder, which fails Matterhorn 06-001 (a real document title is required)."
        )]
    }

    // MARK: Missing language (Matterhorn 11-001 / PDF/UA natural language requirement)

    /// See this type's own doc comment for why this parameter, not a
    /// `Doc` field, is the check's input.
    static func checkLanguage(_ language: String?) -> [AccessibilityIssue] {
        guard let language, !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [AccessibilityIssue(
                kind: .missingLanguage,
                severity: .error,
                message: "No document language was supplied - PDF/UA requires a declared natural language for the document (Matterhorn 11-001)."
            )]
        }
        return []
    }

    // MARK: Heading-level jumps (Matterhorn 14-002: no skipped heading levels)

    /// Walks every `.heading` block in document order (``DocumentAST/
    /// depthFirstOrder()``, which recurses into `.section`/`.frame`/
    /// `.toggle`/etc. children - a heading nested inside a container is
    /// still part of the document's ONE reading-order sequence, matching
    /// how LO's own checker treats a linear document). A jump is flagged
    /// on the OFFENDING (later, deeper) heading whenever its level is
    /// more than 1 greater than the immediately preceding heading's
    /// level - "H1 directly to H3 with no H2" per the contract's own
    /// example. The very first heading never triggers this check
    /// regardless of its level (there is no preceding heading to jump
    /// from); Tessera does not additionally require every document to
    /// start at H1, since the contract's own example is specifically
    /// about a SKIP, not about the starting level.
    static func checkHeadingLevels(_ ast: DocumentAST) -> [AccessibilityIssue] {
        var issues: [AccessibilityIssue] = []
        var previousLevel: Int?
        for blockID in ast.depthFirstOrder() {
            guard let block = ast.blocks[blockID], block.type == .heading else { continue }
            let level = min(max(block.attributes["level"]?.intValue ?? 1, 1), 6)
            if let previousLevel, level > previousLevel + 1 {
                issues.append(AccessibilityIssue(
                    kind: .headingLevelJump,
                    severity: .error,
                    message: "Heading level jumps from H\(previousLevel) to H\(level) with no intervening level - Matterhorn 14-002 requires no skipped heading levels.",
                    blockID: blockID
                ))
            }
            previousLevel = level
        }
        return issues
    }

    // MARK: Missing image alt text (Matterhorn 13-004: alternate text required)

    /// Walks every `.image` block in document order. `attributes["alt"]`
    /// absent, empty, or whitespace-only all count as missing - matching
    /// `DocumentExporter.renderBlock`'s own `.image` case, which falls
    /// back to the LITERAL placeholder text `"image"` when the attribute
    /// is absent (a real word, not an empty string) precisely so the
    /// exported HTML always has SOME `alt="..."` attribute; this check
    /// operates on the source `Block` data, not the exported HTML, so it
    /// is not fooled by that export-time fallback into missing a real
    /// gap.
    static func checkImageAltText(_ ast: DocumentAST) -> [AccessibilityIssue] {
        var issues: [AccessibilityIssue] = []
        for blockID in ast.depthFirstOrder() {
            guard let block = ast.blocks[blockID], block.type == .image else { continue }
            let alt = block.attributes["alt"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard alt == nil || alt!.isEmpty else { continue }
            issues.append(AccessibilityIssue(
                kind: .missingAltText,
                severity: .error,
                message: "Image has no alt text - Matterhorn 13-004 requires alternate text for non-text content conveying meaning.",
                blockID: blockID
            ))
        }
        return issues
    }
}

// MARK: - PDFAccessibilityOptions

/// Opt-in tagged-PDF / PDF-UA flags threaded through every soffice-backed
/// PDF export path in this codebase (item 2.20's "filter-options
/// plumbing": `DocumentExporter`, `PDFExportBridge`, `LOBridgeDeckIO`,
/// `CalcBridgeFilter`). One shared struct rather than a bare `Bool` per
/// call site so the two LO filter-data keys (`UseTaggedPDF`/
/// `PDFUACompliance`) are named and JSON-encoded in exactly ONE place -
/// see ``filterDataFragments``. Both flags default `false`, matching
/// every existing PDF export caller's behavior before this wave; opting
/// in is always an explicit caller decision.
///
/// **Empirically verified, LO 26.2.5.2, probed 2026-08-16 (this
/// session):** passing ANY explicit FilterData sequence to soffice's
/// `--convert-to 'pdf:<filter>_pdf_Export:{...}'` - regardless of its
/// CONTENT, even `{"UseTaggedPDF":true,"PDFUACompliance":true}` itself -
/// produces an UNTAGGED PDF on this install (`pdfinfo` reports `Tagged:
/// no`), while omitting FilterData entirely produces a TAGGED PDF
/// (`Tagged: yes`, no PDF/UA identification claim either way). Confirmed
/// reproducible across `writer_pdf_Export`, `writer_web_pdf_Export`
/// (the filter Writer's own HTML->PDF path auto-selects), and
/// `calc_pdf_Export`; boolean encoding (`true`/`1`/`"true"`) and adding
/// unrelated keys made no difference. This matches a previously reported
/// LibreOffice issue ("Der Filter writer_pdf_Export ignoriert alle
/// Argumente aus den mitgegebenen FilterData-Properties",
/// ask.libreoffice.org/t/68343) - a LibreOffice CLI defect, not a
/// Tessera code bug. See this wave's findings file
/// (`docs/.scratch/p2-d-findings-4.md`) for the full repro transcript.
/// This struct still implements the flag exactly as LO's own
/// `pdf_params` help documents it (the "get the flag plumbing right"
/// mandate) so the wiring starts working for free the moment an LO
/// patch fixes the underlying defect - no Tessera code change needed.
public struct PDFAccessibilityOptions: Sendable, Equatable, Codable {
    /// LO filter-data `UseTaggedPDF` - full logical structure tree.
    public var useTaggedPDF: Bool
    /// LO filter-data `PDFUACompliance` - the PDF/UA-1 identification
    /// claim. LO's own pdf_params doc: selecting this forces tagging, so
    /// a caller that wants full UA sets both (``pdfUA``); a caller that
    /// wants tagging without the formal UA claim can set only
    /// `useTaggedPDF`. Kept as two independent bools rather than a
    /// single enum for exactly that reason - the plain-tagged-only
    /// combination is real, legal LO filter data a future caller may
    /// want even though none of this wave's own call sites construct it.
    public var pdfUACompliance: Bool

    public init(useTaggedPDF: Bool = false, pdfUACompliance: Bool = false) {
        self.useTaggedPDF = useTaggedPDF
        self.pdfUACompliance = pdfUACompliance
    }

    /// No accessibility options requested - every export path's
    /// pre-2.20 default behavior, unchanged by this wave.
    public static let off = PDFAccessibilityOptions()

    /// The combination this wave's contract asks for end to end
    /// ("UseTaggedPDF=true + PDFUACompliance=true").
    public static let pdfUA = PDFAccessibilityOptions(useTaggedPDF: true, pdfUACompliance: true)

    /// `true` when either flag would add filter-data soffice receives.
    public var isEnabled: Bool { useTaggedPDF || pdfUACompliance }

    /// The `"Key":true` fragments this option set turns on, ready to
    /// splice into a `*_pdf_Export` filter's own `{...}` JSON literal
    /// alongside any filter-specific fragments a caller appends (e.g.
    /// `LOBridgeDeckIO`'s existing `"ExportNotesPages":true`). Empty
    /// when both flags are off.
    public var filterDataFragments: [String] {
        var out: [String] = []
        if useTaggedPDF { out.append("\"UseTaggedPDF\":true") }
        if pdfUACompliance { out.append("\"PDFUACompliance\":true") }
        return out
    }
}

// MARK: - PDFFilterOptions

/// Builds the `filterOptions` string `LibreOfficeConverter.convert(...)`
/// expects (`"filterName:{...}"` - see that method's own doc comment)
/// from a filter name and a list of already-quoted `"Key":value`
/// fragments. One shared builder so every PDF export call site
/// constructs this string the same way instead of hand-interpolating
/// JSON four times.
public enum PDFFilterOptions {
    /// `nil` when `fragments` is empty, so a caller with nothing to say
    /// passes `nil` through to `convert(...)` and gets soffice's own
    /// bare-filter default rather than a pointless empty `{}` - which
    /// matters concretely on this environment (see
    /// `PDFAccessibilityOptions`'s own doc comment: the bare-filter
    /// default is what currently produces a TAGGED pdf on LO 26.2.5.2,
    /// so a caller that has no accessibility options set should not
    /// pay for an explicit-FilterData call at all).
    public static func build(filterName: String, fragments: [String]) -> String? {
        guard !fragments.isEmpty else { return nil }
        return "\(filterName):{\(fragments.joined(separator: ","))}"
    }
}
