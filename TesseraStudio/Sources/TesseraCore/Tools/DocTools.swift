import Foundation

//===----------------------------------------------------------------------===//
//  DocTools.swift
//  Tessera Studio
//
//  The agent's access to Writer forms (P2-D item 2.15). This is the
//  FIRST file at this path - the `doc_*` tool namespace `docs/agent-
//  tools-surface.md` describes did not exist yet in this codebase (a
//  directory listing confirmed it before this file was written); this
//  wave creates it rather than extending anything. Two tools:
//  `doc_form_fields_list` (tier0, read) and `doc_form_fill` (tier1,
//  per-entity write) - the exact pair sota-enterprise-report.md's 2.15
//  design position names ("Tools/tiers: doc_form_fields_list tier0;
//  doc_form_fill tier1 - it mutates content, but it is the canonical
//  bounded, schema-validated write (one receipt per call, per-field
//  before/after payload)").
//
//  `defaultApprovalLevel` mirrors the existing `sheet_read`/`sheet_write`
//  precedent for the same tier pair (`Tools/SheetTools.swift`):
//  `.auto` for the tier0 read, `.prompt` for the tier1 write -
//  `TesseraTier`'s own label ("tier1: ... notify") is a SEPARATE audit-log
//  dimension computed from action-class + risk
//  (`TesseraSafetyDecision.tier(forActionClass:)`), not a direct
//  `ApprovalLevel` mapping; `.prompt` here is the same choice
//  `SheetWriteTool` (also a tier1 per-entity write per the tools-surface
//  doc's own tier table) already made.
//
//  **No `DocStore` import.** `DocStore.swift` is withheld from this
//  track this wave (see this wave's own brief) and has no
//  `fillForm(blockID:value:for:)` method yet. `DocToolContext` below
//  follows `SheetToolContext`/`MailMergeToolContext`'s own established
//  shape for exactly this situation: a closure-based seam
//  (`loader`/`filler`) installed by whoever owns the app-level
//  `TesseraDataLayer` lifecycle once the real `DocStore` method exists -
//  see this wave's wiringNotes for the exact method this seam is meant
//  to wrap.
//===----------------------------------------------------------------------===//

// MARK: - DocToolContext

/// Where the doc form tools find a live document to read/fill.
///
/// Empty by default: with no Docs surface open (or `DocStore.fillForm`
/// not yet wired - see file header), the tools report that rather than
/// inventing a document. Same shape as `SheetToolContext`/
/// `MailMergeToolContext`: the app installs the live closures when its
/// data layer starts and clears them when it tears down.
public final class DocToolContext: @unchecked Sendable {
    public static let shared = DocToolContext()

    /// Loads the live `Doc` for a given id, or `nil` when none exists.
    /// Backs `doc_form_fields_list`'s read and `doc_form_fill`'s
    /// post-fill re-read (see `DocFormFillTool.execute`).
    public typealias DocLoader = @Sendable (_ docID: UUID) async throws -> Doc?

    /// Fills one content control and persists the result exactly as
    /// `DocStore.fillForm(blockID:value:for:)` will once wired (see this
    /// wave's wiringNotes): runs `FormController.fill`, persists ONLY
    /// when the returned block actually differs from the stored one,
    /// and appends exactly one `.fillForm` receipt keyed by the
    /// control's tag with a before/after payload. Throws when `docID`
    /// or `blockID` does not resolve to a fillable content control -
    /// this closure's own error type is whatever the real `DocStore`
    /// throws once installed (this file does not invent one).
    public typealias FormFiller = @Sendable (_ blockID: UUID, _ value: String, _ docID: UUID) async throws -> Doc

    private let lock = NSLock()
    private var _loader: DocLoader?
    private var _filler: FormFiller?

    public init() {}

    public var loader: DocLoader? {
        get { lock.lock(); defer { lock.unlock() }; return _loader }
        set { lock.lock(); defer { lock.unlock() }; _loader = newValue }
    }

    public var filler: FormFiller? {
        get { lock.lock(); defer { lock.unlock() }; return _filler }
        set { lock.lock(); defer { lock.unlock() }; _filler = newValue }
    }

    /// Install (or, with nils, clear) the live loader/filler.
    public func install(loader: DocLoader?, filler: FormFiller?) {
        self.loader = loader
        self.filler = filler
    }
}

/// Shared value resolution for both tools below: `FormController.
/// resolvedValue(for:hostBlock:)` first (locally filled state), falling
/// back to `FormBindingResolver.resolve(_:in:)` against the doc's own
/// `preservedParts` when the control is data-bound and nothing has been
/// locally filled yet. Neither `FormController` function does this
/// itself - `resolvedValue`/`formData` only see a `DocumentAST`, never
/// a `Doc`, so they structurally cannot reach `preservedParts` (see
/// this wave's findings file, p2-d-findings-2.md, item 4); this is the
/// one place both tools have a full `Doc` in hand to compose the two.
enum DocFormToolSupport {
    static func effectiveValue(for control: ContentControl, hostBlock: Block?, preservedParts: PreservedParts?) -> String? {
        if let local = FormController.resolvedValue(for: control, hostBlock: hostBlock) {
            return local
        }
        guard control.binding != nil, let preservedParts else { return nil }
        return FormBindingResolver.resolve(control, in: preservedParts)
    }
}

enum DocToolError: LocalizedError, Equatable {
    case noContext
    case docNotFound

    var errorDescription: String? {
        switch self {
        case .noContext:
            return "Document form tools are not available. Open a Docs surface first."
        case .docNotFound:
            return "No document found with that id."
        }
    }
}

// MARK: - doc_form_fields_list

/// Agent tool: list every content-control form field in a document.
/// **Tier0** (`ApprovalLevel.auto`) - read-only, matching
/// `SheetReadTool`'s own tier0/`.auto` pairing.
public struct DocFormFieldsListTool: TesseraTool {
    public let name = "doc_form_fields_list"
    public let description = """
        List every content-control form field in a document, in document order. Each entry reports \
        its block id (needed by doc_form_fill), tag, kind (richText/plainText/comboBox/dropDownList/\
        datePicker/checkBox/picture), title, placeholder, current resolved value (nil if never \
        filled), and whether it is bound to a custom-XML data source. Read-only.
        """
    public let defaultApprovalLevel = ApprovalLevel.auto

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "doc_id": SchemaProperty(
                type: "string",
                description: "UUID of the document to inspect."
            ),
        ],
        required: ["doc_id"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        // Argument validation before the context check - malformed input
        // is rejected the same way regardless of whether a loader
        // happens to be installed, matching MailMergeRunTool's own
        // documented ordering.
        guard let docIDString = arguments["doc_id"]?.stringValue, let docID = UUID(uuidString: docIDString) else {
            return .fail("doc_id must be a UUID")
        }
        guard let loader = DocToolContext.shared.loader else {
            return .fail(DocToolError.noContext.errorDescription ?? "no context")
        }
        guard let doc = try await loader(docID) else {
            return .fail(DocToolError.docNotFound.errorDescription ?? "not found")
        }

        let fields = FormController.formFields(in: doc.body)
        guard !fields.isEmpty else {
            return .ok("No content-control form fields in this document.", data: ["fields": .array([])])
        }

        var lines: [String] = []
        var entries: [JSONValue] = []
        for (blockID, control) in fields {
            let resolved = DocFormToolSupport.effectiveValue(for: control, hostBlock: doc.body.blocks[blockID], preservedParts: doc.preservedParts)
            lines.append("\(control.tag) [\(control.kind.rawValue)] (\(blockID.uuidString)) = \(resolved ?? "<unfilled>")")
            entries.append(.object([
                "blockID": .string(blockID.uuidString),
                "tag": .string(control.tag),
                "kind": .string(control.kind.rawValue),
                "title": control.title.map(JSONValue.string) ?? .null,
                "placeholder": control.placeholder.map(JSONValue.string) ?? .null,
                "value": resolved.map(JSONValue.string) ?? .null,
                "bound": .bool(control.binding != nil),
            ]))
        }
        return .ok(lines.joined(separator: "\n"), data: ["fields": .array(entries)])
    }
}

// MARK: - doc_form_fill

/// Agent tool: fill one content control's value. **Tier1**
/// (`ApprovalLevel.prompt`) - it mutates content, matching
/// `SheetWriteTool`'s own tier1/`.prompt` pairing; per the design
/// contract, this stays available even on a document protected for
/// filling in forms only (2.15's ratified "denial-by-protection"
/// default - see this wave's wiringNotes; not enforced by this file,
/// which has no notion of document protection yet).
public struct DocFormFillTool: TesseraTool {
    public let name = "doc_form_fill"
    public let description = """
        Fill one content-control form field, addressed by its block id (from doc_form_fields_list). \
        Plain-text and rich-text controls replace the host block's own text. Combo box, drop-down \
        list, date picker, checkbox, and picture controls store the value on the control itself \
        without touching any surrounding text: checkbox requires exactly "true" or "false"; \
        drop-down list requires an exact match against the control's own list items (combo box \
        accepts free text). A locked control, or a value that fails the kind's own validation, is a \
        no-op: zero receipts, unchanged document. One receipt per successful call.
        """
    public let defaultApprovalLevel = ApprovalLevel.prompt

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "doc_id": SchemaProperty(
                type: "string",
                description: "UUID of the document."
            ),
            "block_id": SchemaProperty(
                type: "string",
                description: "UUID of the block hosting the content control (see doc_form_fields_list)."
            ),
            "value": SchemaProperty(
                type: "string",
                description: "The value to fill: literal text for plain/rich text; \"true\"/\"false\" for a checkbox; an exact list item for a drop-down list; free text for a combo box; a date-text or picture-reference string for date picker/picture."
            ),
        ],
        required: ["doc_id", "block_id", "value"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let docIDString = arguments["doc_id"]?.stringValue, let docID = UUID(uuidString: docIDString) else {
            return .fail("doc_id must be a UUID")
        }
        guard let blockIDString = arguments["block_id"]?.stringValue, let blockID = UUID(uuidString: blockIDString) else {
            return .fail("block_id must be a UUID")
        }
        guard let value = arguments["value"]?.stringValue else {
            return .fail("value must be a string")
        }
        guard let filler = DocToolContext.shared.filler else {
            return .fail(DocToolError.noContext.errorDescription ?? "no context")
        }

        do {
            let doc = try await filler(blockID, value, docID)
            guard let control = doc.body.blocks[blockID]?.contentControl else {
                return .fail("block \(blockID.uuidString) has no content control after fill")
            }
            let resolved = DocFormToolSupport.effectiveValue(for: control, hostBlock: doc.body.blocks[blockID], preservedParts: doc.preservedParts)
            return .ok(
                "Filled '\(control.tag)' [\(control.kind.rawValue)] = \(resolved ?? "<unfilled>")",
                data: [
                    "docID": .string(doc.id.uuidString),
                    "blockID": .string(blockID.uuidString),
                    "tag": .string(control.tag),
                    "value": resolved.map(JSONValue.string) ?? .null,
                ]
            )
        } catch {
            return .fail(error.localizedDescription)
        }
    }
}
