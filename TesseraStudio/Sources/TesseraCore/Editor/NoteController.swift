import Foundation

//===----------------------------------------------------------------------===//
//  NoteController.swift
//  Tessera Studio
//
//  Insert/delete lifecycle for footnote/endnote body blocks (P1 item 1.2
//  shipped the BlockType.footnote/.endnote cases, DocumentMeta.notes, and
//  deriveNoteNumbering() - but no insert/delete API and no receipts; P2-0
//  closes that gap).
//
//  Pure and stateless, matching RevisionController/FieldController in the
//  same wave family (Productivity/Editor/): `insertNote`/`deleteNote` take
//  a `DocumentAST` and return a new one plus an outcome value shaped for a
//  receipt; neither touches `DocStore`. `DocStore.insertNote`/`.deleteNote`
//  are the one place that both calls this and appends the
//  `doc_note_inserted`/`doc_note_deleted` receipt (see DocStore.swift).
//
//  **Note bodies live in `DocumentMeta.notes`, never in `ast.blocks`.**
//  Block.swift's own doc comment on `DocumentMeta.notes` is explicit about
//  this ("out-of-flow ... registered in DocumentMeta.notes ... NOT placed
//  inline in the document's reading flow"); `insertNote` follows that
//  contract exactly - the new `.footnote`/`.endnote` block goes into
//  `ast.meta.notes`, never `ast.blocks`.
//
//  **The reference marker is a real InlineRun, not a synthetic one.**
//  `insertNote` splices a new `InlineRun(text: referenceMarkerText,
//  annotations: [.noteRef(noteID)])` into the anchor block's own `content`
//  at a UTF-16 offset - the same splice-by-offset shape
//  `DocumentSearchIndex.splice` uses for find/replace, so a mid-run
//  insertion still preserves every other run's annotations untouched.
//  `referenceMarkerText` is never a rendered number: the 1..n shown to the
//  reader is DERIVED (`DocumentAST.deriveNoteNumbering()`), never stored -
//  so the marker run's own text is deliberately a fixed non-numeric
//  placeholder.
//
//  **Deleting a note removes the registry entry AND every dangling
//  in-text reference.** A `.noteRef(noteID)` run left behind after its
//  target note is gone would derive to nothing (`deriveNoteNumbering`
//  already skips unregistered ids) but would still sit in the document as
//  a stale, unexplained annotation forever, so `deleteNote` also strips
//  the annotation (and, when that was the run's only content, the run
//  itself) from every block that referenced it - a full "the reference
//  never happened" cleanup, matching `RevisionController.removeSubtree`'s
//  "gone means gone" philosophy for its own removal case.
//===----------------------------------------------------------------------===//

// MARK: - NoteInsertOutcome

/// The result of one `NoteController.insertNote` call. Shaped for a
/// `DocStore` integration to turn directly into a `doc_note_inserted`
/// receipt - `receiptType`/`payload` mirror `RevisionResolution`'s own
/// receipt-emission boundary: this type has no Store dependency and does
/// not append anything itself.
public struct NoteInsertOutcome: Sendable, Equatable {
    public let noteID: UUID
    public let kind: BlockType
    public let anchorBlockID: UUID
    public let offset: Int

    public init(noteID: UUID, kind: BlockType, anchorBlockID: UUID, offset: Int) {
        self.noteID = noteID
        self.kind = kind
        self.anchorBlockID = anchorBlockID
        self.offset = offset
    }

    public var receiptType: String { DocReceiptType.insertNote.rawValue }

    public var payload: [String: JSONValue] {
        [
            "noteID": .string(noteID.uuidString),
            "kind": .string(kind.rawValue),
            "anchorBlockID": .string(anchorBlockID.uuidString),
            "offset": .number(Double(offset)),
        ]
    }
}

// MARK: - NoteDeleteOutcome

/// The result of one `NoteController.deleteNote` call. See
/// `NoteInsertOutcome`'s doc comment for the receipt-shaping rationale.
public struct NoteDeleteOutcome: Sendable, Equatable {
    public let noteID: UUID
    public let kind: BlockType
    public let referencesRemoved: Int

    public init(noteID: UUID, kind: BlockType, referencesRemoved: Int) {
        self.noteID = noteID
        self.kind = kind
        self.referencesRemoved = referencesRemoved
    }

    public var receiptType: String { DocReceiptType.deleteNote.rawValue }

    public var payload: [String: JSONValue] {
        [
            "noteID": .string(noteID.uuidString),
            "kind": .string(kind.rawValue),
            "referencesRemoved": .number(Double(referencesRemoved)),
        ]
    }
}

// MARK: - NoteController

/// Pure insert/delete resolution over `DocumentAST`'s existing
/// `.footnote`/`.endnote` blocks - peer of `RevisionController`/
/// `FieldController`: a plain namespace of static functions, no state, no
/// `DocStore` dependency. See the file header for the full design.
public enum NoteController {

    /// Placeholder text every newly-inserted reference marker run
    /// carries. Never the rendered number - see file header. A thin-space
    /// glyph so the un-numbered marker still occupies real, selectable
    /// text for `BlockRenderer.applyAnnotation(.noteRef:)`'s superscript
    /// styling to apply to, rather than being a fully empty run.
    public static let referenceMarkerText = "\u{2002}"

    /// Insert a new `.footnote`/`.endnote` body block, register it in
    /// `ast.meta.notes`, and splice a `.noteRef` marker run into
    /// `anchorBlockID`'s own `content` at UTF-16 `offset`.
    ///
    /// `nil` (a safe no-op signal for the caller) when `kind` isn't
    /// `.footnote`/`.endnote`, `anchorBlockID` isn't in the document, or
    /// `offset` falls outside `[0, anchor's own content text length]` -
    /// an invalid anchor per this file's contract.
    public static func insertNote(
        kind: BlockType,
        anchorBlockID: UUID,
        at offset: Int,
        noteText: String,
        in ast: DocumentAST
    ) -> (ast: DocumentAST, outcome: NoteInsertOutcome)? {
        guard kind == .footnote || kind == .endnote else { return nil }
        guard let anchorBlock = ast.blocks[anchorBlockID] else { return nil }
        let contentLength = anchorBlock.content.reduce(0) { $0 + $1.text.utf16.count }
        guard offset >= 0, offset <= contentLength else { return nil }

        var result = ast
        let noteID = UUID()
        result.meta.notes[noteID] = Block(id: noteID, type: kind, content: [InlineRun(text: noteText)])

        var block = anchorBlock
        block.content = insertMarker(into: block.content, at: offset, noteID: noteID)
        result.blocks[anchorBlockID] = block

        return (result, NoteInsertOutcome(noteID: noteID, kind: kind, anchorBlockID: anchorBlockID, offset: offset))
    }

    /// Remove `noteID` from `ast.meta.notes` and strip every
    /// `.noteRef(noteID)` reference from the document's blocks.
    ///
    /// `nil` (a safe no-op signal for the caller) when `noteID` isn't
    /// registered in `ast.meta.notes`.
    public static func deleteNote(
        noteID: UUID,
        in ast: DocumentAST
    ) -> (ast: DocumentAST, outcome: NoteDeleteOutcome)? {
        guard let note = ast.meta.notes[noteID] else { return nil }
        var result = ast
        result.meta.notes.removeValue(forKey: noteID)

        var referencesRemoved = 0
        for (blockID, block) in result.blocks {
            let (newContent, removedHere) = removingReferences(to: noteID, from: block.content)
            guard removedHere > 0 else { continue }
            var updated = block
            updated.content = newContent
            result.blocks[blockID] = updated
            referencesRemoved += removedHere
        }

        return (result, NoteDeleteOutcome(noteID: noteID, kind: note.type, referencesRemoved: referencesRemoved))
    }

    // MARK: - Content splicing

    /// Splits `content`'s run containing UTF-16 `offset` (or inserts
    /// cleanly between runs at an exact boundary) and inserts a new
    /// marker run carrying `.noteRef(noteID)` there. Mirrors
    /// `DocumentSearchIndex.splice`'s boundary-aware run-splitting shape.
    /// `offset == 0` on empty `content` produces a single-run result.
    private static func insertMarker(into content: [InlineRun], at offset: Int, noteID: UUID) -> [InlineRun] {
        let marker = InlineRun(text: referenceMarkerText, annotations: [.noteRef(noteID)])
        guard !content.isEmpty else { return [marker] }

        var result: [InlineRun] = []
        var cursor = 0
        var inserted = false
        for run in content {
            let runLength = run.text.utf16.count
            let runStart = cursor
            let runEnd = cursor + runLength
            cursor = runEnd

            if !inserted, offset >= runStart, offset <= runEnd {
                if offset == runStart {
                    result.append(marker)
                    result.append(run)
                } else if offset == runEnd {
                    result.append(run)
                    result.append(marker)
                } else {
                    let head = utf16Substring(run.text, from: 0, to: offset - runStart)
                    let tail = utf16Substring(run.text, from: offset - runStart, to: runLength)
                    result.append(InlineRun(text: head, annotations: run.annotations))
                    result.append(marker)
                    result.append(InlineRun(text: tail, annotations: run.annotations))
                }
                inserted = true
                continue
            }
            result.append(run)
        }
        if !inserted { result.append(marker) } // offset landed past every run's own end
        return result
    }

    /// Strips every `.noteRef(noteID)` annotation from `content`'s runs.
    /// A run that carried other annotations too, or non-placeholder text,
    /// is KEPT with just the one annotation gone; a run left with no
    /// annotations AND exactly the placeholder marker text is dropped
    /// entirely - see file header's "gone means gone" note.
    private static func removingReferences(
        to noteID: UUID,
        from content: [InlineRun]
    ) -> (content: [InlineRun], removedCount: Int) {
        var result: [InlineRun] = []
        var removedCount = 0
        for run in content {
            guard run.annotations.contains(where: { isNoteRef($0, matching: noteID) }) else {
                result.append(run)
                continue
            }
            removedCount += 1
            let remainingAnnotations = run.annotations.filter { !isNoteRef($0, matching: noteID) }
            if remainingAnnotations.isEmpty, run.text == referenceMarkerText {
                continue // drop the now-empty placeholder run entirely
            }
            result.append(InlineRun(text: run.text, annotations: remainingAnnotations))
        }
        return (result, removedCount)
    }

    /// `annotation == .noteRef(noteID)` - written as an explicit helper
    /// (not `if case .noteRef(noteID) = annotation`) because a bare
    /// identifier in enum-pattern position is a NEW binding in Swift, not
    /// an equality check against the outer `noteID`; this function is the
    /// one place that distinction is spelled out for the whole file.
    private static func isNoteRef(_ annotation: InlineRun.Annotation, matching noteID: UUID) -> Bool {
        if case .noteRef(let id) = annotation { return id == noteID }
        return false
    }

    private static func utf16Substring(_ s: String, from utf16Start: Int, to utf16End: Int) -> String {
        let start = String.Index(utf16Offset: utf16Start, in: s)
        let end = String.Index(utf16Offset: utf16End, in: s)
        return String(s[start..<end])
    }
}
