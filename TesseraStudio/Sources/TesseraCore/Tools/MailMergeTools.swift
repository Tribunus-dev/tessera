import Foundation

//===----------------------------------------------------------------------===//
//  MailMergeTools.swift
//  Tessera Studio
//
//  The agent's access to `MailMergeCoordinator` (P2-C item 2.4). One
//  tool, `merge_run`, over the SAME endpoint the merge wizard SwiftUI
//  sheet calls - "coordinator-first stands" (studio-expansion-design-
//  refinement-2026-08-14.md 5, "2.21 Mail-merge wizard + 2.4
//  coordinator"). Output is documents/PDFs only; this file has no
//  SMTP/email-sending capability, matching `MailMergeCoordinator.swift`'s
//  own file header.
//===----------------------------------------------------------------------===//

// MARK: - MailMergeToolContext

/// Where `merge_run` finds the coordinator to act on. Same shape as
/// `SheetToolContext` (Tools/SheetTools.swift): empty by default so a
/// build with no productivity data layer wired doesn't crash; the app
/// installs the live coordinator once its `TesseraDataLayer` starts and
/// clears it when the surface tears down.
///
/// `MailMergeCoordinator` needs a real `DocStore`/`SheetStore` pair (no
/// in-memory/fake seam exists for either - see `MailMergeCoordinator.
/// swift`'s own header), so it cannot be constructed lazily the way
/// `SheetToolContext.workbook` is; it is installed once, ready-made, by
/// whoever owns the app-level `TesseraDataLayer` lifecycle - the same
/// reason `TesseraToolRegistry.default` cannot construct `MailMergeRunTool`
/// with a store argument itself (see this wave's wiringNotes).
public final class MailMergeToolContext: @unchecked Sendable {
    public static let shared = MailMergeToolContext()

    private let lock = NSLock()
    private var _coordinator: MailMergeCoordinator?

    public init() {}

    public var coordinator: MailMergeCoordinator? {
        get { lock.lock(); defer { lock.unlock() }; return _coordinator }
        set { lock.lock(); defer { lock.unlock() }; _coordinator = newValue }
    }

    /// Install (or, with `nil`, clear) the live coordinator.
    public func install(_ coordinator: MailMergeCoordinator?) {
        self.coordinator = coordinator
    }
}

enum MailMergeToolError: LocalizedError, Equatable {
    case noCoordinator

    var errorDescription: String? {
        switch self {
        case .noCoordinator:
            return "Mail merge is not available. Open a Docs or Sheets surface first."
        }
    }
}

// MARK: - merge_run

/// Agent tool: run a mail merge. **Tier2** (`ApprovalLevel.prompt` -
/// `TesseraTier.tier2.displayName` is "Tier 2 (approval)",
/// Agent/TesseraTier.swift) per the design contract's own "fan-out blast
/// radius" reasoning (studio-expansion-design-refinement-2026-08-14.md
/// 5): a single call can create many new documents at once, so it asks
/// first even though any ONE output is itself ordinary/reversible
/// (trash/delete like any other Doc) - the SPREAD across N new
/// documents is what earns the extra gate, the same "bulk >N" shape
/// `TesseraTier`'s own canonical table names for tier2 (Agent/
/// TesseraTier.swift's doc comment).
public struct MailMergeRunTool: TesseraTool {
    public let name = "merge_run"
    public let description = """
        Run a mail merge: fan one template document out to N output documents, one per record \
        in a record source (currently a Sheet). Output is documents/PDFs only - this tool NEVER \
        sends email; once the files exist, use the mail client (or the user) to send them. A \
        template's placeholders are `.mergeField` fields whose name matches a source column's \
        header exactly (case-sensitive); a record missing a given field substitutes an empty \
        string rather than failing the whole run.
        """
    public let defaultApprovalLevel = ApprovalLevel.prompt

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "template_doc_id": SchemaProperty(
                type: "string",
                description: "UUID of the template Doc containing .mergeField placeholders."
            ),
            "source_entity_id": SchemaProperty(
                type: "string",
                description: "UUID of the record source (a Sheet); one grid row becomes one merged output document."
            ),
            "output_format": SchemaProperty(
                type: "string",
                description: "One of: docx, pdf, odt. Default pdf.",
                enumValues: ["docx", "pdf", "odt"],
                defaultValue: "pdf"
            ),
            "destination_directory": SchemaProperty(
                type: "string",
                description: "Folder to write the output files into. Defaults to the user's Documents folder."
            ),
        ],
        required: ["template_doc_id", "source_entity_id"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        // Argument validation happens before the coordinator check, so a
        // malformed request is always rejected the same way regardless
        // of whether a coordinator happens to be installed - see this
        // file's own tests (denial path: malformed arguments "fails
        // before touching the coordinator").
        guard let templateIDString = arguments["template_doc_id"]?.stringValue,
              let templateID = UUID(uuidString: templateIDString) else {
            return .fail("template_doc_id must be a UUID")
        }
        guard let sourceIDString = arguments["source_entity_id"]?.stringValue,
              let sourceID = UUID(uuidString: sourceIDString) else {
            return .fail("source_entity_id must be a UUID")
        }
        let formatRaw = arguments["output_format"]?.stringValue ?? "pdf"
        guard let format = DocumentExporter.ExportFormat(rawValue: formatRaw) else {
            let allowed = DocumentExporter.ExportFormat.allCases.map(\.rawValue).joined(separator: ", ")
            return .fail("output_format must be one of: \(allowed)")
        }
        guard let coordinator = MailMergeToolContext.shared.coordinator else {
            return .fail(MailMergeToolError.noCoordinator.errorDescription ?? "no coordinator")
        }
        let destinationDirectory: URL
        if let dir = arguments["destination_directory"]?.stringValue, !dir.isEmpty {
            destinationDirectory = URL(fileURLWithPath: dir, isDirectory: true)
        } else {
            destinationDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        }

        do {
            let result = try await coordinator.run(
                templateDocID: templateID,
                sourceEntityID: sourceID,
                outputFormat: format,
                destinationDirectory: destinationDirectory
            )
            return .ok(
                "Mail merge complete: \(result.recordCount) record(s) -> \(result.outputURLs.count) \(format.rawValue.uppercased()) file(s) in \(destinationDirectory.path).",
                data: [
                    "record_count": .number(Double(result.recordCount)),
                    "output_doc_ids": .array(result.outputDocIDs.map { .string($0.uuidString) }),
                    "output_paths": .array(result.outputURLs.map { .string($0.path) }),
                    "source_hash": .string(result.sourceHash),
                ]
            )
        } catch {
            return .fail(error.localizedDescription)
        }
    }
}
