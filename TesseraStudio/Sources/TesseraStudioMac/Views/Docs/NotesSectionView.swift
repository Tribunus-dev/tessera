import SwiftUI
import TesseraCore

// MARK: - NotesSectionView
//
// The real footnote/endnote rendering surface (P2-0 item 2).
// `BlockRenderer.renderNotePlaceholder` is explicitly NOT this surface -
// its own doc comment says a `.footnote`/`.endnote` block is "not
// normally walked as a top-level content block" and the placeholder only
// exists so the renderer's switch stays exhaustive. Per the design
// contract (studio-expansion-design-refinement-2026-08-14.md, 1.2
// footnote/endnote): "v1 renders an endnotes section + popover;
// bottom-of-page placement waits for the paginator - TextKit 2
// exclusion-path reservation is documented crash-prone and is explicitly
// not attempted." True glyph-level anchoring inside
// `TesseraTextContentManager`'s own text flow needs that same paginator
// context (and lives outside this track's file list - Views/Docs/ only);
// these two views are the closest a file-scoped SwiftUI surface gets:
// real interactive rendering (not a bracketed placeholder string), keyed
// to the same `deriveNoteNumbering()` order the reader sees, reachable
// from `DocDetailView`.

// MARK: - NoteReference

/// One footnote/endnote in-text reference, with its derived number and
/// the block that carries the `.noteRef` marker - everything a rendering
/// surface needs to show "[n]" and jump back to the reference.
struct NoteReference: Identifiable, Hashable {
    /// The note's own id (also the key into `DocumentMeta.notes`).
    var id: UUID { noteID }
    let noteID: UUID
    let anchorBlockID: UUID
    let number: Int
}

// MARK: - NoteReferenceCollector

/// Walks a `DocumentAST` for `.noteRef` annotations of one `kind`
/// (`.footnote` or `.endnote`), pairing each with the anchor block that
/// carries the FIRST occurrence and the number
/// `DocumentAST.deriveNoteNumbering()` derived for it - the same
/// dedup-by-first-occurrence rule `deriveNoteNumbering()` itself uses, so
/// this collector never disagrees with the numbering the popover/section
/// displays.
enum NoteReferenceCollector {
    static func references(in document: DocumentAST, kind: BlockType) -> [NoteReference] {
        let numbering = document.deriveNoteNumbering()
        let numbers = kind == .footnote ? numbering.footnotes : numbering.endnotes
        guard !numbers.isEmpty else { return [] }

        var seen: Set<UUID> = []
        var refs: [NoteReference] = []
        for blockID in document.depthFirstOrder() {
            guard let block = document.blocks[blockID] else { continue }
            for run in block.content {
                for annotation in run.annotations {
                    guard case .noteRef(let noteID) = annotation else { continue }
                    guard let number = numbers[noteID], !seen.contains(noteID) else { continue }
                    seen.insert(noteID)
                    refs.append(NoteReference(noteID: noteID, anchorBlockID: blockID, number: number))
                }
            }
        }
        return refs.sorted { $0.number < $1.number }
    }

    /// `document.meta.notes[noteID]`'s own plain text, or "" when the id
    /// isn't registered (a dangling reference - see
    /// `deriveNoteNumbering()`'s own doc comment; this collector never
    /// produces a `NoteReference` for one, but callers rendering directly
    /// from `meta.notes` fall back to "" rather than crashing).
    static func noteText(_ noteID: UUID, in document: DocumentAST) -> String {
        document.meta.notes[noteID]?.content.map(\.text).joined() ?? ""
    }
}

// MARK: - EndnotesSectionView

/// A dedicated end-of-document section listing every endnote in derived
/// numbered order - the "endnotes section" half of the 1.2 design
/// contract. Renders nothing (an empty view) when the document has no
/// endnote references, matching `linkedSection`'s own "nothing to show"
/// convention in `DocDetailView`.
public struct EndnotesSectionView: View {
    public let document: DocumentAST
    public let onNavigate: (UUID) -> Void

    public init(document: DocumentAST, onNavigate: @escaping (UUID) -> Void) {
        self.document = document
        self.onNavigate = onNavigate
    }

    private var references: [NoteReference] {
        NoteReferenceCollector.references(in: document, kind: .endnote)
    }

    public var body: some View {
        if !references.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Endnotes").font(.headline)
                    Spacer()
                    Text("\(references.count)")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(.quaternarySystemFill))
                        .cornerRadius(4)
                }
                ForEach(references) { ref in
                    EndnoteRow(
                        number: ref.number,
                        text: NoteReferenceCollector.noteText(ref.noteID, in: document),
                        onNavigate: { onNavigate(ref.anchorBlockID) }
                    )
                }
            }
        }
    }
}

private struct EndnoteRow: View {
    let number: Int
    let text: String
    let onNavigate: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).")
                .font(.caption).foregroundStyle(.secondary)
                .frame(minWidth: 20, alignment: .trailing)
            Text(text.isEmpty ? "(empty)" : text)
                .font(.callout)
                .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                .textSelection(.enabled)
            Spacer()
            Button(action: onNavigate) {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
            .help("Go to reference \(number)")
            .accessibilityLabel("Go to endnote reference \(number)")
        }
    }
}

// MARK: - FootnoteReferencesStrip

/// A row of tappable footnote markers, one per footnote reference in
/// document order, each opening a popover with the note's own content -
/// the "popover" half of the 1.2 design contract. "Anchored near its
/// reference mark" is approximated at document-flow granularity (the
/// strip sits directly under the editor body, not at the true glyph
/// position of each reference - that needs paginator + text-view
/// integration outside this track's files, per this file's own header).
/// Renders nothing when the document has no footnote references.
public struct FootnoteReferencesStrip: View {
    public let document: DocumentAST
    public let onNavigate: (UUID) -> Void

    @State private var openNoteID: UUID?

    public init(document: DocumentAST, onNavigate: @escaping (UUID) -> Void) {
        self.document = document
        self.onNavigate = onNavigate
    }

    private var references: [NoteReference] {
        NoteReferenceCollector.references(in: document, kind: .footnote)
    }

    public var body: some View {
        if !references.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Footnotes").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(references) { ref in
                            FootnoteMarker(
                                reference: ref,
                                document: document,
                                isOpen: openNoteID == ref.noteID,
                                onToggle: { openNoteID = (openNoteID == ref.noteID) ? nil : ref.noteID },
                                onNavigate: {
                                    onNavigate(ref.anchorBlockID)
                                    openNoteID = nil
                                }
                            )
                        }
                    }
                }
            }
        }
    }
}

/// One footnote marker chip + its popover. A separate view (rather than
/// inline in `FootnoteReferencesStrip`'s `ForEach`) so `@State
/// isPresented` binding plumbing stays local to one marker instead of a
/// shared dictionary of `Bool`s.
private struct FootnoteMarker: View {
    let reference: NoteReference
    let document: DocumentAST
    let isOpen: Bool
    let onToggle: () -> Void
    let onNavigate: () -> Void

    private var text: String {
        NoteReferenceCollector.noteText(reference.noteID, in: document)
    }

    var body: some View {
        Button(action: onToggle) {
            Text("\(reference.number)")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .help(text.isEmpty ? "Footnote \(reference.number)" : text)
        .accessibilityLabel("Footnote \(reference.number)")
        .popover(isPresented: Binding(get: { isOpen }, set: { if !$0 { onToggle() } })) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Footnote \(reference.number)").font(.headline)
                Text(text.isEmpty ? "(empty)" : text)
                    .font(.callout)
                    .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                    .textSelection(.enabled)
                Button("Go to reference", action: onNavigate)
                    .buttonStyle(.link)
            }
            .padding()
            .frame(width: 260)
        }
    }
}
