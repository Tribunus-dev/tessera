import Foundation
import CryptoKit

//===----------------------------------------------------------------------===//
//  MailMergeCoordinator.swift
//  Tessera Studio
//
//  P2-C item 2.4 (ratified restatement - studio-expansion-design-
//  refinement-2026-08-14.md 5, "2.21 Mail-merge wizard + 2.4 coordinator";
//  full contract in docs/.scratch/sota-p2-core-report.md, "2.4
//  MailMergeCoordinator - restatement (ratified; decision row 16)"):
//
//    "Single coordinator endpoint over linkedEntityIDs-referenced data
//    sources; mergeField joins the existing FieldKind enum (reserved by
//    name - not a new BlockType); merge_run tier2, fans one template +
//    record set out to documents/PDFs - never SMTP; receipts carry
//    source hash + record count; the 2.21 wizard (S, after 2.4) is a
//    guided sheet over this same endpoint."
//
//  ONE endpoint, TWO callers: `Tools/MailMergeTools.swift`'s `merge_run`
//  agent tool and the merge wizard SwiftUI sheet both call `run(...)`
//  below - neither reimplements the fan-out.
//
//  Merge OUTPUT IS DOCUMENTS/PDFS ONLY. This file has no SMTP client, no
//  mail-sending capability, no notion of a recipient email address -
//  "merge to documents, never to SMTP" (the design contract's own
//  words); the mail client owns sending, entirely out of scope here.
//
//  SHAPE: split into a PURE half and an I/O-SHELL half, matching how
//  `DocStore` itself delegates to pure engines (`FieldController`,
//  `RevisionController`, ...) rather than inlining their logic - and
//  matching `BezierPathController`'s own precedent file header
//  ("PURE ... never touches [the store] itself") that this wave's brief
//  points at for a controller/engine's shape:
//
//    - PURE, `static`, no store access: `records(from:)` (Sheet grid ->
//      one `[String: String]` per row) and `mergedDocs(template:records:
//      clock:)` (template + records -> N merged `Doc` values, via
//      `FieldController.refresh`'s existing cache-and-substitute
//      mechanism - see that file's own `mergeRecord` doc comment; no
//      parallel substitution path). Fully covered WITHOUT a database -
//      this wave's testing-doctrine.md rule 11 "ungated shadow", since
//      neither `DocStore` nor `SheetStore` has an in-memory/fake seam
//      anywhere in this codebase (`DocStoreTests.swift`'s own file
//      header) and both are gated on `TESSERA_DB_INTEGRATION=1`.
//    - I/O SHELL, instance method `run(...)`: loads the template `Doc`
//      and the record-source `Sheet` through the real stores, calls the
//      two pure halves above, persists each merged `Doc` via the
//      EXISTING `DocStore.upsert(_:)` (each output gets its own
//      ordinary `doc_upsert` receipt through the path that already
//      exists - no new DocStore surface needed for THAT part), and
//      exports each through the EXISTING
//      `DocumentExporter.export(_:to:destination:)`. Gated the same way
//      `DocStoreTests` is, for the same reason.
//
//  V1 DATA-SOURCE SCOPE: Sheet only. `Doc.linkedEntityIDs` can point at
//  any graph entity; this coordinator only knows how to pull records out
//  of a `Sheet` - `SheetColumn.label` names a field, `Sheet.cellText
//  (row:col:)` supplies its value, one grid row is one record. `Sheet`
//  is "the obvious first one" per this item's own design-contract
//  wording. NOT supported at v1, and why:
//    - A `Doc` as a data source (e.g. a table block inside another Doc)
//      - no established "this Doc's table IS a record set" convention
//      exists yet anywhere else in this codebase to build on.
//    - `SheetWorkbook` (the full Calc engine, multi-sheet, formulas,
//      typed cells) - a heavier surface than "walk labeled columns, read
//      text" needs; the plain `Sheet` grid's `cellText(row:col:)` is a
//      stable, already-public read path and is enough for mail merge.
//  Adding a second source type later is additive (a new `records(from:)`
//  overload feeding the SAME `mergedDocs`), not a rewrite.
//
//  MERGE-OPERATION RECEIPT (`doc_mail_merge_run`, `DocReceiptType.
//  runMailMerge`, already pre-landed by this wave's opener commit):
//  NOT emitted by this file. It needs a `DocStore` method this track
//  cannot add - `DocStore.swift` is withheld this wave to avoid a
//  same-file collision across the wave's 4 parallel tracks. `run(...)`
//  below computes and returns everything that method will need
//  (`sourceHash`, `recordCount`, `templateDocID`) and marks the exact
//  call site with a `// TODO(wiring)` comment. See this wave's findings
//  file (`docs/.scratch/p2-c-findings-2.md`) and wiringNotes for the
//  exact method signature + payload keys the centralized wiring pass
//  should add. Every OUTPUT document's own `doc_upsert` receipt already
//  fires normally through the existing `DocStore.upsert(_:)` path below -
//  this gap is ONLY the one extra operation-level audit entry, not a
//  hole in per-document auditability.
//===----------------------------------------------------------------------===//

// MARK: - MailMergeCoordinator

public struct MailMergeCoordinator: Sendable {

    private let docStore: DocStore
    private let sheetStore: SheetStore
    private let exporter: DocumentExporter

    public init(dataLayer: TesseraDataLayer, exporter: DocumentExporter = DocumentExporter()) {
        self.docStore = DocStore(dataLayer: dataLayer)
        self.sheetStore = SheetStore(dataLayer: dataLayer)
        self.exporter = exporter
    }

    /// Test/DI seam: build directly from already-constructed stores
    /// rather than a `TesseraDataLayer`, so a caller that already holds
    /// a `DocStore`/`SheetStore` pair (the app's own wiring, or a gated
    /// integration test matching `DocStoreTests`' own `makeStore()`
    /// pattern) doesn't have to reconstruct a second one over the same
    /// data layer.
    public init(docStore: DocStore, sheetStore: SheetStore, exporter: DocumentExporter = DocumentExporter()) {
        self.docStore = docStore
        self.sheetStore = sheetStore
        self.exporter = exporter
    }

    // MARK: - Pure: record extraction (Sheet -> [[String: String]])

    /// One `[String: String]` per grid row, keyed by `SheetColumn.label`
    /// (trimmed; a column with a blank label after trimming is skipped -
    /// it cannot match any `.mergeField(name:)`, which always names a
    /// non-empty field). A duplicate label after trimming has its LATER
    /// (higher-index) column win, matching `Dictionary`'s own last-
    /// write-wins semantics for a literal `[key: value]` build - not a
    /// contract this item's design doc specifies either way, so this is
    /// this track's own call, recorded in the findings file. Returns `[]`
    /// for a sheet with no columns or no rows - a genuine "nothing to
    /// merge" case `run(...)` turns into a clear error rather than
    /// silently producing zero output documents.
    public static func records(from sheet: Sheet) -> [[String: String]] {
        guard !sheet.columns.isEmpty, sheet.rowCount > 0 else { return [] }
        return (0..<sheet.rowCount).map { row in
            var record: [String: String] = [:]
            for (col, column) in sheet.columns.enumerated() {
                let label = column.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { continue }
                record[label] = sheet.cellText(row: row, col: col)
            }
            return record
        }
    }

    // MARK: - Pure: field substitution (template + records -> N merged Docs)

    /// One merged `Doc` per entry in `records`, each a FRESH document
    /// (new `id`, matching mail merge's own semantics - N NEW outputs,
    /// the template is never overwritten). Every `.field` block in
    /// `template.body` is re-resolved via `FieldController.refresh`
    /// passing that record as `mergeRecord` - reusing FieldController's
    /// existing refresh-and-cache mechanism exactly as the design
    /// contract requires ("reuse FieldController's existing
    /// refresh-and-cache mechanism rather than a parallel substitution
    /// path - it already exists for every other field kind"), so a
    /// template mixing `.mergeField` with `.date`/`.sequence` fields
    /// gets ALL of them resolved in the same pass, not just the merge
    /// fields.
    public static func mergedDocs(
        template: Doc,
        records: [[String: String]],
        clock: @escaping () -> Date = Date.init
    ) -> [Doc] {
        records.map { record in mergedDoc(template: template, record: record, clock: clock) }
    }

    private static func mergedDoc(template: Doc, record: [String: String], clock: () -> Date) -> Doc {
        var body = template.body
        for id in template.body.blocks.keys {
            guard let block = template.body.blocks[id], block.type == .field else { continue }
            // `in: template.body` (the ORIGINAL, unmutated ast) on every
            // call within this same merged doc: field kinds that count
            // across the tree (`.sequence(name:)`) need a stable ast to
            // walk, and this loop only ever rewrites a `.field` block's
            // own `content`/`dirty` in place - structure never changes,
            // so re-deriving against the original is equivalent to (and
            // simpler than) threading the in-progress `body`.
            body.blocks[id] = FieldController.refresh(block, in: template.body, clock: clock, mergeRecord: record)
        }
        let now = clock()
        return Doc(
            title: template.title,
            body: body,
            coverImageURL: template.coverImageURL,
            iconEmoji: template.iconEmoji,
            tags: template.tags,
            createdAt: now,
            updatedAt: now
        )
    }

    /// Every distinct `.mergeField(name:)` name referenced in `doc`'s
    /// body, in first-occurrence document order (`depthFirstOrder()`).
    /// Used by the merge wizard (2.21) to render "one field chip per
    /// detected `.mergeField` name in the template" without duplicates.
    public static func mergeFieldNames(in doc: Doc) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for id in doc.body.depthFirstOrder() {
            guard let block = doc.body.blocks[id], block.type == .field,
                  let spec = block.field, case .mergeField(let name) = spec.kind
            else { continue }
            if seen.insert(name).inserted { names.append(name) }
        }
        return names
    }

    // MARK: - I/O shell: run a full merge

    /// Load the template + the record source, merge, persist each
    /// output `Doc`, export each to `outputFormat` under
    /// `destinationDirectory`. Throws `MailMergeCoordinatorError` for
    /// every "nothing to merge" case (template/source not found, source
    /// has zero usable records) rather than silently producing a
    /// zero-document result - the caller (agent tool or wizard) always
    /// gets a definite success-with-N-outputs or a named failure.
    @discardableResult
    public func run(
        templateDocID: UUID,
        sourceEntityID: UUID,
        outputFormat: DocumentExporter.ExportFormat,
        destinationDirectory: URL,
        clock: @escaping () -> Date = Date.init
    ) async throws -> MailMergeRunResult {
        guard let template = try await docStore.get(id: templateDocID) else {
            throw MailMergeCoordinatorError.templateNotFound(id: templateDocID)
        }
        guard let sheet = try await sheetStore.get(id: sourceEntityID) else {
            throw MailMergeCoordinatorError.sourceNotFound(id: sourceEntityID)
        }
        let records = Self.records(from: sheet)
        guard !records.isEmpty else {
            throw MailMergeCoordinatorError.noRecords(sourceEntityID: sourceEntityID)
        }
        let merged = Self.mergedDocs(template: template, records: records, clock: clock)

        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        var outputDocIDs: [UUID] = []
        var outputURLs: [URL] = []
        outputDocIDs.reserveCapacity(merged.count)
        outputURLs.reserveCapacity(merged.count)
        for (index, doc) in merged.enumerated() {
            // Existing public method: this IS the per-output doc_upsert
            // receipt the design contract says "already fires normally" -
            // no new DocStore surface needed for this half.
            let stored = try await docStore.upsert(doc)
            outputDocIDs.append(stored.id)
            let filename = "\(Self.sanitizedFilename(stored.displayTitle))-\(index + 1).\(outputFormat.fileExtension)"
            let destination = destinationDirectory.appendingPathComponent(filename)
            let url = try await exporter.export(stored, to: outputFormat, destination: destination)
            outputURLs.append(url)
        }

        let sourceHash = Self.sourceHash(records: records)

        // The merge OPERATION's own audit entry - distinct from each
        // output Doc's own doc_upsert receipt already fired above.
        try await docStore.recordMailMerge(sourceHash: sourceHash, recordCount: records.count, for: templateDocID)

        return MailMergeRunResult(
            templateDocID: templateDocID,
            sourceEntityID: sourceEntityID,
            outputDocIDs: outputDocIDs,
            outputURLs: outputURLs,
            sourceHash: sourceHash,
            recordCount: records.count
        )
    }

    // MARK: - Helpers

    /// SHA-256 over a canonical (sorted-keys) JSON encoding of `records`,
    /// formatted `"sha256:<hex>"` - the same format
    /// `DocumentAST.contentHash()`/`CodeFile.computeChecksum(of:)` use,
    /// so the receipt chain has one consistent content-addressing shape
    /// (see those two files' own doc comments).
    static func sourceHash(records: [[String: String]]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // A plain `[[String: String]]` always encodes deterministically
        // under `.sortedKeys` (no floating-point/Date/UUID nondeterminism
        // in this shape), so `try!` here can only fail on a JSONEncoder
        // bug, not on this function's own input.
        let data = try! encoder.encode(records)
        var hasher = SHA256()
        hasher.update(data: data)
        let digest = hasher.finalize()
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A filesystem-safe stem for an export filename: strips path
    /// separators and other characters that would either break the path
    /// or get silently mangled by the filesystem, collapses runs of
    /// whitespace, and falls back to "Untitled" for an all-stripped
    /// title (matching `Doc.displayTitle`'s own "Untitled" fallback
    /// convention).
    static func sanitizedFilename(_ title: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let stripped = title.unicodeScalars.map { disallowed.contains($0) ? Character(" ") : Character($0) }
        let collapsed = String(stripped)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? "Untitled" : collapsed
    }
}

// MARK: - MailMergeRunResult

public struct MailMergeRunResult: Sendable, Equatable {
    public let templateDocID: UUID
    public let sourceEntityID: UUID
    /// One id per output document, same order as `outputURLs` and same
    /// order as the source records (`records(from:)`'s row order).
    public let outputDocIDs: [UUID]
    public let outputURLs: [URL]
    /// `"sha256:<hex>"` over the record set actually merged - the value
    /// the pending `DocStore.recordMailMerge` call (see this file's
    /// `run(...)` TODO) will carry as the receipt's `sourceHash` payload
    /// key.
    public let sourceHash: String
    public let recordCount: Int

    public init(
        templateDocID: UUID,
        sourceEntityID: UUID,
        outputDocIDs: [UUID],
        outputURLs: [URL],
        sourceHash: String,
        recordCount: Int
    ) {
        self.templateDocID = templateDocID
        self.sourceEntityID = sourceEntityID
        self.outputDocIDs = outputDocIDs
        self.outputURLs = outputURLs
        self.sourceHash = sourceHash
        self.recordCount = recordCount
    }
}

// MARK: - MailMergeCoordinatorError

public enum MailMergeCoordinatorError: Error, Sendable, Equatable, LocalizedError {
    case templateNotFound(id: UUID)
    case sourceNotFound(id: UUID)
    case noRecords(sourceEntityID: UUID)

    public var errorDescription: String? {
        switch self {
        case .templateNotFound(let id):
            return "Mail merge template not found: \(id.uuidString)"
        case .sourceNotFound(let id):
            return "Mail merge data source not found: \(id.uuidString)"
        case .noRecords(let sourceEntityID):
            return "Mail merge data source has no rows to merge: \(sourceEntityID.uuidString)"
        }
    }
}
