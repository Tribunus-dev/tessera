import Foundation

//===----------------------------------------------------------------------===//
//  AccessibilityTools.swift
//  Tessera Studio
//
//  The agent's access to `AccessibilityPreflight` (P2-D item 2.20). One
//  tool, `doc_accessibility_check` - tier0/read-only/no-receipt, per this
//  wave's own scoping decision: the contract's literal wording assumes
//  doc_export/sheet_export/slide_export already exist as agent tools and
//  just need a new "accessibility: pdfua" argument, but no such export
//  tools exist anywhere in this codebase yet (export today is a
//  SwiftUI-level user action only - DocumentExporter/DeckExportCoordinator/
//  ExportView). Building three new full export agent tools is a much
//  bigger scope than "add a parameter" and is not named as its own item
//  anywhere in this wave's contract, so this wave stops at wiring the
//  accessibility/pdf-ua option at the underlying export(...)-family
//  METHOD level (see DocumentExporter.swift/PDFExportBridge.swift/
//  LOBridgeDeckIO.swift/CalcBridgeFilter.swift) and adds ONLY this one
//  genuinely new agent tool. Recorded for architect ratification in this
//  wave's findings file (docs/.scratch/p2-d-findings-4.md).
//
//  Own file, own context - separate from `Tools/DocTools.swift`'s
//  `DocToolContext` (that file is item 2.15's own new file, being
//  written concurrently by a parallel track this same wave; touching it
//  risks a collision, and this file's tool has nothing to do with form
//  fields). Same "own file per material's agent surface" shape as
//  `Tools/MailMergeTools.swift`/`Tools/SheetTools.swift`.
//===----------------------------------------------------------------------===//

// MARK: - DocAccessibilityToolContext

/// Where `doc_accessibility_check` finds the store to read a `Doc` from.
/// Same shape as `MailMergeToolContext`/`SheetToolContext`: empty by
/// default so a build with no productivity data layer wired doesn't
/// crash; the app installs the live store once the Docs surface's
/// `TesseraDataLayer` starts and clears it when the surface tears down.
public final class DocAccessibilityToolContext: @unchecked Sendable {
    public static let shared = DocAccessibilityToolContext()

    private let lock = NSLock()
    private var _docStore: DocStore?

    public init() {}

    public var docStore: DocStore? {
        get { lock.lock(); defer { lock.unlock() }; return _docStore }
        set { lock.lock(); defer { lock.unlock() }; _docStore = newValue }
    }

    /// Install (or, with `nil`, clear) the live store.
    public func install(_ docStore: DocStore?) {
        self.docStore = docStore
    }
}

enum DocAccessibilityToolError: LocalizedError, Equatable {
    case noStore

    var errorDescription: String? {
        switch self {
        case .noStore:
            return "Document accessibility check is not available. Open a Docs surface first."
        }
    }
}

// MARK: - doc_accessibility_check

/// Agent tool: run `AccessibilityPreflight` over a document and return
/// its issue list. **Tier0** (`ApprovalLevel.auto`) - read-only, appends
/// no receipt, matching the tier table's own rule ("`ApprovalLevel.auto`
/// -> tier0 = all read tools, no receipts",
/// `docs/.scratch/sota-enterprise-report.md`). Meant to run BEFORE an
/// export, not after - the whole point of a preflight.
public struct DocAccessibilityCheckTool: TesseraTool {
    public let name = "doc_accessibility_check"
    public let description = """
        Run an accessibility preflight over a document: missing image alt text, heading-level \
        jumps (e.g. H1 directly to H3 with no H2), a missing document title, and a missing \
        document language. Read-only, no receipt. Run this BEFORE exporting a tagged/PDF-UA PDF \
        so issues are fixed before export rather than discovered after. Tessera does not yet \
        store a per-document language, so omitting `language` always reports a missingLanguage \
        finding - pass it when the caller knows the document's language.
        """
    public let defaultApprovalLevel = ApprovalLevel.auto

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "doc_id": SchemaProperty(
                type: "string",
                description: "UUID of the Doc to check."
            ),
            "language": SchemaProperty(
                type: "string",
                description: "BCP-47 language tag for the document (e.g. \"en\", \"es-MX\"), if known."
            ),
        ],
        required: ["doc_id"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        // Argument validation happens before the store check, so a
        // malformed request is always rejected the same way regardless
        // of whether a store happens to be installed - see
        // MailMergeTools.swift's own tests for the precedent this
        // ordering follows.
        guard let idString = arguments["doc_id"]?.stringValue, let docID = UUID(uuidString: idString) else {
            return .fail("doc_id must be a UUID")
        }
        guard let store = DocAccessibilityToolContext.shared.docStore else {
            return .fail(DocAccessibilityToolError.noStore.errorDescription ?? "no store")
        }
        do {
            guard let doc = try await store.get(id: docID) else {
                return .fail("no document with id \(idString)")
            }
            let language = arguments["language"]?.stringValue
            let issues = AccessibilityPreflight.run(doc, language: language)
            let issuesJSON: [JSONValue] = issues.map { issue in
                .object([
                    "kind": .string(issue.kind.rawValue),
                    "severity": .string(issue.severity.rawValue),
                    "message": .string(issue.message),
                    "blockID": issue.blockID.map { JSONValue.string($0.uuidString) } ?? .null,
                ])
            }
            let summary = issues.isEmpty
                ? "No accessibility issues found."
                : "\(issues.count) accessibility issue(s) found: \(issues.map { $0.kind.rawValue }.joined(separator: ", "))."
            return .ok(
                summary,
                data: [
                    "issues": .array(issuesJSON),
                    "issue_count": .number(Double(issues.count)),
                ]
            )
        } catch {
            return .fail(error.localizedDescription)
        }
    }
}
