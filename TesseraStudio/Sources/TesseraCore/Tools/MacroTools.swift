import Foundation

//===----------------------------------------------------------------------===//
//  MacroTools.swift
//  Tessera Studio
//
//  The agent's access to `MacroCompatLayer` (P2-D item 2.13). Three
//  tools: `macro_list` (tier0), `macro_read` (tier0), `macro_translate`
//  (tier1, writes a stored playbook artifact). There is NO `macro_run`
//  tool at any tier, ever - this file parses, decompresses, outlines,
//  and translates; it never executes a byte of VBA. That is a hard line
//  per the design contract's own wording, not a scope note.
//
//  **No `DocStore` import.** `DocStore.swift` is withheld from this
//  track this wave (see this wave's own brief) and has no
//  `translateMacro(for:outlines:)` method yet. `MacroToolContext` below
//  follows `DocToolContext`'s own closure-seam shape (Tools/DocTools.swift,
//  written by a parallel track THIS SAME WAVE against the exact same
//  "DocStore is withheld" constraint) rather than holding a raw
//  `DocStore` reference: `loader`/`translator` closures, installed by
//  whoever owns the app-level `TesseraDataLayer` lifecycle once the real
//  `DocStore` method exists - see this wave's wiringNotes for the exact
//  method signature this seam is meant to wrap.
//===----------------------------------------------------------------------===//

// MARK: - MacroToolContext

/// Where the macro tools find a live document's preserved VBA project and
/// where `macro_translate` persists its playbook artifact.
///
/// Empty by default: with no Docs surface open (or `DocStore.translateMacro`
/// not yet wired - see file header), the tools report that rather than
/// inventing a document. Lock-guarded, `install(_:)`/nil-clear, resolved
/// lazily at `execute()` time - the same shape `MailMergeToolContext`/
/// `DocToolContext` already establish.
public final class MacroToolContext: @unchecked Sendable {
    public static let shared = MacroToolContext()

    /// Loads the live `Doc` for a given id, or `nil` when none exists.
    /// Backs every tool in this file: `macro_list`/`macro_read` read the
    /// doc's `preservedParts` directly; `macro_translate` loads it first
    /// to run the pipeline, then hands the derived outlines to
    /// `translator` rather than writing anything itself.
    public typealias DocLoader = @Sendable (_ docID: UUID) async throws -> Doc?

    /// Persists a translated playbook and appends exactly one
    /// `.translateMacro` receipt, exactly as
    /// `DocStore.translateMacro(for:outlines:)` will once wired (see this
    /// wave's wiringNotes). Takes the ALREADY-PARSED outlines (this file
    /// runs steps a-c of the pipeline itself via `MacroCompatLayer`, pure
    /// and store-free) so the eventual `DocStore` method is pure glue:
    /// translate + persist + receipt, matching `regenerateToc`/
    /// `setMasterDocSpec`'s own shape in that store. Never executes
    /// anything - only writes the derived playbook artifact.
    public typealias MacroTranslator = @Sendable (_ docID: UUID, _ outlines: [VBAModuleOutline]) async throws -> Doc

    private let lock = NSLock()
    private var _loader: DocLoader?
    private var _translator: MacroTranslator?

    public init() {}

    public var loader: DocLoader? {
        get { lock.lock(); defer { lock.unlock() }; return _loader }
        set { lock.lock(); defer { lock.unlock() }; _loader = newValue }
    }

    public var translator: MacroTranslator? {
        get { lock.lock(); defer { lock.unlock() }; return _translator }
        set { lock.lock(); defer { lock.unlock() }; _translator = newValue }
    }

    /// Install (or, with nils, clear) the live loader/translator.
    public func install(loader: DocLoader?, translator: MacroTranslator?) {
        self.loader = loader
        self.translator = translator
    }
}

enum MacroToolError: LocalizedError, Equatable {
    case noContext
    case docNotFound
    case noTranslator

    var errorDescription: String? {
        switch self {
        case .noContext:
            return "Macro tools are not available. Open a Docs surface first."
        case .docNotFound:
            return "No document found with that id."
        case .noTranslator:
            return "Macro translation is not available. Open a Docs surface first."
        }
    }
}

// MARK: - Shared: doc -> outlines

/// Loads a doc, confirms/extracts its preserved `vbaProject.bin` (this
/// wave's landed infrastructure only reaches `Doc`/`.word` end to end -
/// see this wave's findings file for the Excel/PowerPoint gap), and runs
/// steps (b)-(c) of the pipeline. Shared by all three tools below so the
/// "no preserved project" / "no extractable modules" failure messages
/// are worded identically everywhere they can occur.
private func loadModuleOutlines(docID: UUID, loader: MacroToolContext.DocLoader) async throws -> (Doc, [VBAModuleOutline]) {
    guard let doc = try await loader(docID) else {
        throw MacroToolError.docNotFound
    }
    let bytes = try MacroCompatLayer.preservedVBAProjectBytes(in: doc.preservedParts, hostKind: .word)
    let outlines = try MacroCompatLayer.moduleOutlines(fromVBAProjectBin: bytes)
    return (doc, outlines)
}

// MARK: - macro_list

/// Agent tool: list every preserved VBA module's name and Sub/Function
/// signatures for a document. **Tier0** (`ApprovalLevel.auto`) -
/// read-only, matching `macro_read`'s own tier and `SheetReadTool`'s
/// tier0/`.auto` pairing.
public struct MacroListTool: TesseraTool {
    public let name = "macro_list"
    public let description = """
        List every VBA module preserved in a document's macro project (Word .docm only in this \
        release - see doc_id), with each module's name and Sub/Function signatures (name + parameter \
        list). Read-only: no module source, no execution. Use macro_read for one module's full \
        outline and decompressed source text.
        """
    public let defaultApprovalLevel = ApprovalLevel.auto

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "doc_id": SchemaProperty(
                type: "string",
                description: "UUID of the document whose preserved macro project should be listed."
            ),
        ],
        required: ["doc_id"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let docIDString = arguments["doc_id"]?.stringValue, let docID = UUID(uuidString: docIDString) else {
            return .fail("doc_id must be a UUID")
        }
        guard let loader = MacroToolContext.shared.loader else {
            return .fail(MacroToolError.noContext.errorDescription ?? "no context")
        }

        do {
            let (_, outlines) = try await loadModuleOutlines(docID: docID, loader: loader)
            var lines: [String] = []
            var entries: [JSONValue] = []
            for outline in outlines {
                let signatures = outline.subroutines.map { routine -> String in
                    "\(routine.kind.rawValue) \(routine.name)(\(routine.parameters.joined(separator: ", ")))"
                }
                lines.append("\(outline.moduleName): \(signatures.joined(separator: "; "))")
                entries.append(.object([
                    "moduleName": .string(outline.moduleName),
                    "subroutines": .array(outline.subroutines.map { routine in
                        .object([
                            "kind": .string(routine.kind.rawValue),
                            "name": .string(routine.name),
                            "parameters": .array(routine.parameters.map(JSONValue.string)),
                        ])
                    }),
                ]))
            }
            return .ok(lines.joined(separator: "\n"), data: ["modules": .array(entries)])
        } catch let error as MacroToolError {
            return .fail(error.errorDescription ?? "macro tool error")
        } catch let error as MacroCompatLayerError {
            return .fail(String(describing: error))
        }
    }
}

// MARK: - macro_read

/// Agent tool: read one preserved VBA module's full outline and
/// decompressed source text. **Tier0** (`ApprovalLevel.auto`) -
/// read-only.
public struct MacroReadTool: TesseraTool {
    public let name = "macro_read"
    public let description = """
        Read one VBA module from a document's preserved macro project (Word .docm only in this \
        release): its full outline (Sub/Function signatures, leading doc comment, called-API census) \
        plus the module's decompressed source text, unaltered. Read-only: source is returned for \
        review, never executed.
        """
    public let defaultApprovalLevel = ApprovalLevel.auto

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "doc_id": SchemaProperty(
                type: "string",
                description: "UUID of the document whose preserved macro project should be read."
            ),
            "module_name": SchemaProperty(
                type: "string",
                description: "Name of the module to read (see macro_list)."
            ),
        ],
        required: ["doc_id", "module_name"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let docIDString = arguments["doc_id"]?.stringValue, let docID = UUID(uuidString: docIDString) else {
            return .fail("doc_id must be a UUID")
        }
        guard let moduleName = arguments["module_name"]?.stringValue, !moduleName.isEmpty else {
            return .fail("module_name must be a non-empty string")
        }
        guard let loader = MacroToolContext.shared.loader else {
            return .fail(MacroToolError.noContext.errorDescription ?? "no context")
        }

        do {
            let (doc, outlines) = try await loadModuleOutlines(docID: docID, loader: loader)
            guard let outline = outlines.first(where: { $0.moduleName == moduleName }) else {
                return .fail("no module named '\(moduleName)' in this document's macro project")
            }
            // Re-locate this SAME module's raw source text - the outline
            // alone doesn't carry it (VBAModuleOutline is signature-level
            // only), so this re-runs the cheap decompression step for
            // just the one requested module rather than caching source
            // text alongside every outline in `loadModuleOutlines`.
            let bytes = try MacroCompatLayer.preservedVBAProjectBytes(in: doc.preservedParts, hostKind: .word)
            let sourceText = try Self.sourceText(forModule: moduleName, inVBAProjectBin: bytes)

            let signatures = outline.subroutines.map { routine -> String in
                let returnClause = routine.returnType.map { " As \($0)" } ?? ""
                return "\(routine.kind.rawValue) \(routine.name)(\(routine.parameters.joined(separator: ", ")))\(returnClause)"
            }
            let summaryLine = "\(outline.moduleName): \(signatures.joined(separator: "; "))"
            return .ok(
                summaryLine,
                data: [
                    "moduleName": .string(outline.moduleName),
                    "docComment": outline.docComment.map(JSONValue.string) ?? .null,
                    "calledAPIs": .array(outline.calledAPIs.map(JSONValue.string)),
                    "subroutines": .array(outline.subroutines.map { routine in
                        .object([
                            "kind": .string(routine.kind.rawValue),
                            "name": .string(routine.name),
                            "parameters": .array(routine.parameters.map(JSONValue.string)),
                            "returnType": routine.returnType.map(JSONValue.string) ?? .null,
                            "visibility": routine.visibility.map(JSONValue.string) ?? .null,
                            "isStatic": .bool(routine.isStatic),
                        ])
                    }),
                    "sourceText": .string(sourceText ?? ""),
                ]
            )
        } catch let error as MacroToolError {
            return .fail(error.errorDescription ?? "macro tool error")
        } catch let error as MacroCompatLayerError {
            return .fail(String(describing: error))
        }
    }

    private static func sourceText(forModule moduleName: String, inVBAProjectBin data: Data) throws -> String? {
        let streams: [String: Data]
        do {
            streams = try CFBFReader.streams(in: data, underStorage: "VBA")
        } catch let error as CFBFReaderError {
            throw MacroCompatLayerError.cfbf(error)
        }
        for streamName in streams.keys where MacroCompatLayer.isModuleStream(named: streamName) {
            guard let streamData = streams[streamName],
                  let sourceText = MacroCompatLayer.decompressedSourceText(fromModuleStream: streamData) else { continue }
            let outline = VBAOutlineParser.parse(source: sourceText, fallbackModuleName: streamName)
            if outline.moduleName == moduleName {
                return sourceText
            }
        }
        return nil
    }
}

// MARK: - macro_translate

/// Agent tool: run the full pipeline (decompress + outline) over every
/// preserved VBA module in a document and PRODUCE a stored playbook
/// artifact - never executes anything. **Tier1** (`ApprovalLevel.prompt`)
/// - it writes derived content, matching `DocFormFillTool`'s own
/// tier1/`.prompt` pairing for a per-entity write; `TesseraTier.tier1`'s
/// own label is "Tier 1 (notify)", a separate audit-log dimension from
/// `ApprovalLevel` (`TesseraSafetyDecision.tier(forActionClass:)`
/// computes that from action-class + risk, not from this property
/// directly - see `DocTools.swift`'s own header comment for the same
/// distinction made explicit).
public struct MacroTranslateTool: TesseraTool {
    public let name = "macro_translate"
    public let description = """
        Translate a document's preserved VBA macro project (Word .docm only in this release) into a \
        stored playbook artifact: per module, a human-readable summary of what it declares and calls, \
        plus non-executable migration suggestions for any recognized Win32/VBA automation APIs \
        (Shell, CreateObject, etc). This tool NEVER executes any macro code - it only decompresses, \
        outlines, and writes the derived playbook. One receipt per call, covering every module \
        translated in this run (or just module_name, if given).
        """
    public let defaultApprovalLevel = ApprovalLevel.prompt

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "doc_id": SchemaProperty(
                type: "string",
                description: "UUID of the document whose preserved macro project should be translated."
            ),
            "module_name": SchemaProperty(
                type: "string",
                description: "Translate only this module. Omit to translate every preserved module."
            ),
        ],
        required: ["doc_id"]
    )

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let docIDString = arguments["doc_id"]?.stringValue, let docID = UUID(uuidString: docIDString) else {
            return .fail("doc_id must be a UUID")
        }
        guard let loader = MacroToolContext.shared.loader else {
            return .fail(MacroToolError.noContext.errorDescription ?? "no context")
        }
        guard let translator = MacroToolContext.shared.translator else {
            return .fail(MacroToolError.noTranslator.errorDescription ?? "no translator")
        }

        do {
            let (_, allOutlines) = try await loadModuleOutlines(docID: docID, loader: loader)
            let outlines: [VBAModuleOutline]
            if let moduleName = arguments["module_name"]?.stringValue, !moduleName.isEmpty {
                guard let match = allOutlines.first(where: { $0.moduleName == moduleName }) else {
                    return .fail("no module named '\(moduleName)' in this document's macro project")
                }
                outlines = [match]
            } else {
                outlines = allOutlines
            }

            let doc = try await translator(docID, outlines)
            let playbooks = MacroCompatLayer.translate(outlines)
            return .ok(
                "Translated \(playbooks.count) module(s) into a stored playbook. No macro code was executed.",
                data: [
                    "docID": .string(doc.id.uuidString),
                    "moduleNames": .array(playbooks.map { .string($0.sourceModuleName) }),
                    "playbooks": .array(playbooks.map { playbook in
                        .object([
                            "sourceModuleName": .string(playbook.sourceModuleName),
                            "humanSummary": .string(playbook.humanSummary),
                            "suggestedToolCalls": .array(playbook.suggestedToolCalls.map(JSONValue.string)),
                            "calledAPIs": .array(playbook.calledAPIs.map(JSONValue.string)),
                        ])
                    }),
                ]
            )
        } catch let error as MacroToolError {
            return .fail(error.errorDescription ?? "macro tool error")
        } catch let error as MacroCompatLayerError {
            return .fail(String(describing: error))
        } catch {
            return .fail(error.localizedDescription)
        }
    }
}
