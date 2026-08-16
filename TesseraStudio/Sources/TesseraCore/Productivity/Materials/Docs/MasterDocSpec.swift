import Foundation

//===----------------------------------------------------------------------===//
//  MasterDocSpec.swift
//  Tessera Studio
//
//  Master-document assembly for Writer (P2-C item 2.11,
//  studio-expansion-design-refinement-2026-08-14.md's Writer cluster;
//  design contract detail in docs/.scratch/sota-p2-core-report.md
//  section "2.11 Master documents"). The evidence is unambiguous
//  (Word master documents corrupt structurally; LO's .odm is the same
//  idea, niche; both sources steer users away from live subdocument
//  editing): this is a BUILD MANIFEST, not an editing surface. `parts`
//  stay independent `Doc`s forever; the master body is optional front
//  matter; there is no sync-back, no live transclusion, no `.odm`.
//
//  `MasterDocSpec` is an additive optional spec meant to live ON `Doc`
//  (`Doc.swift` is NOT in this track's file list this wave - see
//  `MasterDocController`'s doc comment and this wave's wiringNotes for
//  the exact field the centralized pass adds). This file is
//  self-contained: the type, its pure "did the spec actually change"
//  helper (item 5), and the pure assembly engine (item 6) that
//  concatenates part ASTs into one in-memory `Doc` for the EXISTING
//  `DocumentExporter.export(_:to:destination:)` to consume - this file
//  never touches `DocumentExporter.swift`'s public API.
//
//  Pure and stateless throughout, matching FieldController/
//  RevisionController/TocController/StyleRegistry in this same wave
//  family: nothing here touches `DocStore`. A future `DocStore`
//  integration (`setMasterDocSpec(_:for:)`, see wiringNotes) is the
//  one place that both calls `MasterDocController.applyingSpec` and
//  appends the `doc_master_parts_changed` receipt - only when
//  `result.changed` is `true`.
//
//  **Design calls made here that the contract names but doesn't fully
//  pin down (recorded here AND in this wave's findings file for
//  architect ratification):**
//
//  1. **Break representation.** `partBreak` (`.pageBreak`/
//     `.sectionBreak`) is materialized as a `.divider` block (the
//     existing, already-fully-supported break primitive - contributes
//     no `plainText`, renders as `<hr>` in `DocumentExporter`) tagged
//     `attributes["partBreak"]` with the break kind's raw value. NOT
//     `.section` (which carries real multi-column/page-break
//     semantics via `DocumentMeta.sections`/`SectionStore`): wiring a
//     full `DocumentSection` registry entry per part boundary is a
//     heavier mechanism than an "effort S, data-only" item calls for.
//     A future pass can upgrade the break block to a real `.section`
//     without changing this file's public surface.
//  2. **Style-registry merge.** "Master wins on name collision":
//     master's own registry seeds the merge; a part style whose NAME
//     already exists in the merged registry is DROPPED and every
//     `styleRef` pointing at it (on that part's own blocks) is
//     remapped to the surviving style's id - see
//     `mergeStyleRegistries`. LIMITATION: a KEPT part style's own
//     `basedOn`/`next` pointing at a style that got dropped in the
//     SAME merge is not itself rewritten (no test in this wave's
//     required list exercises a colliding-AND-inherited-from style;
//     flagged in findings as a known gap for a future pass, not
//     silently swept under "master wins").
//  3. **`continuousNumbering`'s scope.** The contract says "re-derive
//     note/sequence numbering ... call it, don't reimplement". Two
//     different derivations are actually in play:
//       - Footnote/endnote numbering (`DocumentAST.deriveNoteNumbering()`)
//         is ALWAYS derived fresh from whatever single `DocumentAST` a
//         caller hands it - there is no "per part" concept inside that
//         pure function. Once parts are concatenated into ONE merged
//         `DocumentAST` (which happens unconditionally - assembly
//         always produces one merged `Doc`), a consumer calling
//         `deriveNoteNumbering()` on it gets continuous 1..n note
//         numbers ACROSS the whole assembled document regardless of
//         `continuousNumbering`. This is an accepted, documented
//         consequence of the "one merged AST, no live transclusion"
//         architecture, not a bug to chase.
//       - `.field(.sequence(name:))` blocks (`FieldController`) DO
//         carry STORED/cached resolved text, so this IS a real,
//         controllable choice: `continuousNumbering == true` re-runs
//         `FieldController.refresh` for every `.sequence` field over
//         the FULL merged AST (continuous numbering across part
//         boundaries, since `FieldController`'s own document-order
//         counting now sees every part's sequence blocks as one
//         sequence); `continuousNumbering == false` leaves each part's
//         already-cached field content exactly as it was resolved
//         independently (each part keeps whatever numbering it had on
//         its own, unmodified by assembly). Only `.sequence` fields
//         are touched - `.date`/`.time`/`.author`/etc. are left alone
//         either way, since the contract's line names "note/sequence
//         numbering" specifically, not every field kind.
//  4. **Dangling part / absent front matter.** A part UUID that
//     `resolvePart` cannot resolve is skipped (never appended to the
//     assembled body) and named in `AssemblyResult.skippedPartIDs` -
//     never a crash, never a silently-missing gap in the numbering.
//     An empty (`.empty`-bodied) master `Doc` contributes NO front
//     matter and NO leading break; parts are concatenated directly.
//===----------------------------------------------------------------------===//

// MARK: - MasterDocSpec

/// An additive, optional assembly manifest meant to live on `Doc`
/// (`nil` = "not a master document" - see the file header for the
/// exact `Doc.swift` field this wave's centralized pass adds).
public struct MasterDocSpec: Codable, Sendable, Hashable {
    /// How consecutive parts (and the optional front-matter body) are
    /// separated in the assembled document - see the file header's
    /// "break representation" note.
    public enum PartBreak: String, Codable, Sendable, Hashable, CaseIterable {
        case pageBreak
        case sectionBreak
    }

    /// The part `Doc`s' own ids, in assembly order. Also mirrored into
    /// the owning `Doc`'s EXISTING `linkedEntityIDs` for the graph -
    /// see `MasterDocController.mirroringParts`.
    public var parts: [UUID]
    /// `true` re-derives `.sequence` field numbering continuously
    /// across every part boundary at assembly time; `false` leaves
    /// each part's own independently-resolved numbering untouched -
    /// see the file header's "continuousNumbering's scope" note.
    public var continuousNumbering: Bool
    public var partBreak: PartBreak

    public init(parts: [UUID] = [], continuousNumbering: Bool = true, partBreak: PartBreak = .pageBreak) {
        self.parts = parts
        self.continuousNumbering = continuousNumbering
        self.partBreak = partBreak
    }
}

// MARK: - MasterDocSpecChangeResult

/// The result of one `MasterDocController.applyingSpec` call - the
/// item-5 half of this file. Shaped for a future `DocStore`
/// integration to turn directly into a receipt, mirroring
/// `RevisionResolution`/`TocRegenerationResult`'s own boundary: this
/// type does not append anything itself.
public struct MasterDocSpecChangeResult: Sendable, Equatable {
    public let docID: UUID
    public let spec: MasterDocSpec
    /// `false` when `spec` is identical to the previously-stored spec
    /// (including "both nil" via the caller passing the same value
    /// twice) - the signal a `DocStore` integration uses to skip the
    /// mutation + receipt entirely.
    public let changed: Bool
    public let receiptType: String

    public init(docID: UUID, spec: MasterDocSpec, changed: Bool, receiptType: String = DocReceiptType.changeMasterParts.rawValue) {
        self.docID = docID
        self.spec = spec
        self.changed = changed
        self.receiptType = receiptType
    }

    public var payload: [String: JSONValue] {
        [
            "docID": .string(docID.uuidString),
            "partCount": .number(Double(spec.parts.count)),
            "continuousNumbering": .bool(spec.continuousNumbering),
            "partBreak": .string(spec.partBreak.rawValue),
        ]
    }
}

// MARK: - MasterDocAssemblyResult

/// The result of one `MasterDocController.assemble` call - the item-6
/// half of this file. `doc` is a complete, in-memory `Doc` ready to
/// hand to the EXISTING `DocumentExporter.export(_:to:destination:)`
/// (or `.htmlPreview(_:)`) unchanged - assembly mints no new `Doc` id
/// beyond the master's own, and no persistence happens here.
public struct MasterDocAssemblyResult: Sendable, Equatable {
    public let doc: Doc
    /// Part ids from `spec.parts` that `resolvePart` could not
    /// resolve (a deleted/missing `Doc`) - skipped, never a crash.
    public let skippedPartIDs: [UUID]
    /// Each successfully-resolved part's OWN `contentHash()` at
    /// assembly time, keyed by part id - the "per-part contentHash
    /// provenance" the design contract's receipt line calls for.
    public let partContentHashes: [UUID: String]

    public init(doc: Doc, skippedPartIDs: [UUID], partContentHashes: [UUID: String]) {
        self.doc = doc
        self.skippedPartIDs = skippedPartIDs
        self.partContentHashes = partContentHashes
    }

    /// Provenance to attach to whatever receipt the caller fires for
    /// the export/assembly action itself. Assembly does NOT mint its
    /// own receipt type - the design contract: "export rides existing
    /// export receipts with per-part contentHash provenance."
    public var provenancePayload: [String: JSONValue] {
        [
            "skippedPartIDs": .array(skippedPartIDs.map { .string($0.uuidString) }),
            "partContentHashes": .object(partContentHashes.reduce(into: [String: JSONValue]()) { acc, entry in
                acc[entry.key.uuidString] = .string(entry.value)
            }),
        ]
    }
}

// MARK: - MasterDocController

/// Pure master-document spec-diffing (item 5) and assembly (item 6) -
/// peer of `FieldController`/`RevisionController`/`TocController`: a
/// plain namespace of static functions, no state, no `DocStore`
/// dependency. See the file header for the full design.
public enum MasterDocController {

    // MARK: - Item 5: spec mutation

    /// `newSpec` compared against whatever spec (if any) was
    /// previously stored - a plain `!=` check exposed as a named
    /// result so `DocStore.setMasterDocSpec` doesn't need its own
    /// comparison, mirroring `FieldController.refresh`'s "plain `!=`
    /// check" boundary.
    public static func applyingSpec(_ newSpec: MasterDocSpec, over previousSpec: MasterDocSpec?, docID: UUID) -> MasterDocSpecChangeResult {
        MasterDocSpecChangeResult(docID: docID, spec: newSpec, changed: newSpec != previousSpec)
    }

    /// `linkedEntityIDs` with `parts` mirrored in - see
    /// `MasterDocSpec.parts`'s doc comment. Removes any id that was a
    /// part under `previousParts` but no longer is (a part removed
    /// from the spec), appends any NEW part not already present, and
    /// leaves every other (non-master-doc) link exactly where it was -
    /// "mirrored", not "replaced wholesale".
    public static func mirroringParts(_ parts: [UUID], previousParts: [UUID], into linkedEntityIDs: [UUID]) -> [UUID] {
        let droppedParts = Set(previousParts).subtracting(parts)
        var result = linkedEntityIDs.filter { !droppedParts.contains($0) }
        let existing = Set(result)
        for part in parts where !existing.contains(part) {
            result.append(part)
        }
        return result
    }

    // MARK: - Item 6: assembly

    /// Concatenates `masterDoc.body` (optional front matter) with
    /// every resolvable part in `spec.parts` order, separated by a
    /// break block per `spec.partBreak` - see the file header for the
    /// full design and its recorded judgment calls. Returns a complete
    /// `Doc` (same `id`/`title` as `masterDoc`, body replaced by the
    /// merged AST) ready for the existing exporter; never persists,
    /// never mints a receipt itself.
    public static func assemble(
        masterDoc: Doc,
        spec: MasterDocSpec,
        resolvePart: (UUID) -> Doc?
    ) -> MasterDocAssemblyResult {
        var skippedPartIDs: [UUID] = []
        var resolvedParts: [(id: UUID, doc: Doc)] = []
        for partID in spec.parts {
            if let partDoc = resolvePart(partID) {
                resolvedParts.append((partID, partDoc))
            } else {
                skippedPartIDs.append(partID)
            }
        }

        let (mergedStyles, partRemaps) = mergeStyleRegistries(
            master: masterDoc.body.meta.styles,
            parts: resolvedParts.map { $0.doc.body.meta.styles }
        )

        var merged = DocumentAST()
        merged.meta = masterDoc.body.meta
        merged.meta.styles = mergedStyles

        appendSegment(masterDoc.body, remap: [:], partBreak: spec.partBreak, into: &merged)

        var partContentHashes: [UUID: String] = [:]
        for (index, entry) in resolvedParts.enumerated() {
            appendSegment(entry.doc.body, remap: partRemaps[index], partBreak: spec.partBreak, into: &merged)
            if let hash = try? entry.doc.body.contentHash() {
                partContentHashes[entry.id] = hash
            }
        }

        if spec.continuousNumbering {
            merged = reresolvingSequenceFields(in: merged)
        }

        var assembledDoc = masterDoc
        assembledDoc.body = merged

        return MasterDocAssemblyResult(doc: assembledDoc, skippedPartIDs: skippedPartIDs, partContentHashes: partContentHashes)
    }

    // MARK: - Assembly internals

    /// Appends `ast`'s own root content (with `remap` applied to every
    /// block's `styleRef`, and its notes/sections merged in) to
    /// `merged`, preceded by a break block IFF `merged` already carries
    /// content - see the file header's "break representation" note.
    /// A no-op when `ast` has no root content at all (an empty front
    /// matter contributes neither content nor a stray leading break).
    private static func appendSegment(
        _ ast: DocumentAST,
        remap: [UUID: UUID],
        partBreak: MasterDocSpec.PartBreak,
        into merged: inout DocumentAST
    ) {
        guard !ast.rootChildren.isEmpty else { return }
        if !merged.rootChildren.isEmpty {
            let breakBlock = Block(type: .divider, attributes: ["partBreak": .string(partBreak.rawValue)])
            merged.blocks[breakBlock.id] = breakBlock
            merged.rootChildren.append(breakBlock.id)
        }
        for (id, block) in ast.blocks {
            merged.blocks[id] = remapStyleRef(block, remap: remap)
        }
        merged.rootChildren.append(contentsOf: ast.rootChildren)
        for (noteID, noteBlock) in ast.meta.notes {
            merged.meta.notes[noteID] = remapStyleRef(noteBlock, remap: remap)
        }
        for (sectionID, section) in ast.meta.sections {
            merged.meta.sections[sectionID] = section
        }
    }

    private static func remapStyleRef(_ block: Block, remap: [UUID: UUID]) -> Block {
        guard let ref = block.styleRef, let mapped = remap[ref] else { return block }
        var result = block
        result.styleRef = mapped
        return result
    }

    /// Merges `master`'s style registry with each part registry, in
    /// part order. Master's own styles seed the merge (registered
    /// first), so "master wins on name collision" falls naturally out
    /// of first-registration winning; see the file header's
    /// "style-registry merge" note for the documented `basedOn`
    /// rewrite limitation. Returns the merged registry plus, per part
    /// (same order/count as `parts`), a `[oldStyleID: survivingStyleID]`
    /// remap for every DROPPED part style.
    private static func mergeStyleRegistries(
        master: [UUID: StyleDefinition],
        parts: [[UUID: StyleDefinition]]
    ) -> (registry: [UUID: StyleDefinition], remaps: [[UUID: UUID]]) {
        var merged = master
        var nameToID: [String: UUID] = [:]
        for (id, style) in master { nameToID[style.name] = id }

        var remaps: [[UUID: UUID]] = []
        for part in parts {
            var remap: [UUID: UUID] = [:]
            for (id, style) in part {
                if let survivingID = nameToID[style.name] {
                    remap[id] = survivingID
                } else {
                    merged[id] = style
                    nameToID[style.name] = id
                }
            }
            remaps.append(remap)
        }
        return (merged, remaps)
    }

    /// Re-resolves every `.field(.sequence(name:))` block's cached
    /// content against `ast` AS A WHOLE (so `FieldController`'s own
    /// document-order counting spans every part) - the
    /// `continuousNumbering == true` half of the file header's
    /// "continuousNumbering's scope" note. Every OTHER field kind is
    /// left exactly as assembled (untouched), and `ast` (not the
    /// in-progress result) is used as the resolution context for every
    /// call since `FieldController.refresh`'s sequence counting only
    /// inspects block type/kind, never content - the fixed context is
    /// safe regardless of write order.
    private static func reresolvingSequenceFields(in ast: DocumentAST) -> DocumentAST {
        var result = ast
        for id in ast.depthFirstOrder() {
            guard let block = ast.blocks[id], block.type == .field, let spec = block.field else { continue }
            guard case .sequence = spec.kind else { continue }
            result.blocks[id] = FieldController.refresh(block, in: ast)
        }
        return result
    }
}
