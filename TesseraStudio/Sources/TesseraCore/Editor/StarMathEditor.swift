import Foundation
import SwiftUI

// MARK: - StarMathEditor
//
// Item 2.14 (StarMathEditor - LaTeX-first over SwiftMath, ratified:
// design contract in studio-expansion-design-refinement-2026-08-14.md
// section 5, search "2.14"). `equation.latex` (`Block.attributes
// ["latex"]`) stays the canonical source; this file is the authoring
// SURFACE only - a source editor (plain LaTeX text) + a live preview
// (re-rendered through the EXACT SAME SwiftMath path as
// `BlockRenderer.renderEquation`, via `BlockRenderer.renderLaTeX` -
// see that file) + a fixed symbol palette. NO WYSIWYG structure editor
// in v1, per the design contract's own "no WYSIWYG structure editor in
// v1" line - the user always edits the LaTeX text directly.
//
// **Architecture.** Mirrors `RevisionReviewPanel.swift`'s shape: a
// pure, store-free namespace for the logic that CAN run without
// `DocStore` (`StarMathEquationMutation` below - this file's "ungated
// shadow", testing-doctrine.md rule 11, since `DocStore` has no
// in-memory seam anywhere in this codebase - see
// `RevisionReviewStoreTests.swift`'s own header), an `@Observable
// @MainActor` store class that owns the `DocStore` integration
// (`StarMathEditorStore`), and the SwiftUI view.
//
// **Structural shape.** Mirrors `CodeEditorView.swift`'s own shape (a
// raw-source text editor bound to a view model, forwarding commits via
// a callback) - StarMathEditorView pairs that same raw-source-editing
// pane with a NEW second pane `CodeEditorView` has no equivalent of:
// the live rendered preview, since code has nothing analogous to
// render.
//
// **Commit is explicit, not per-keystroke.** `latex`'s live edits only
// update local state + the debounced preview - NEVER `DocStore`, so
// typing never receipts (testing-doctrine.md's "no receipt without a
// mutation"). `commit()` is the one path that persists, and it
// itself no-ops (testing-doctrine.md rule 1's guard-and-early-return)
// via `StarMathEquationMutation.committing`, which returns `nil` when
// `latex` already matches the block's current attribute - `DocStore
// .setBody` itself has NO such guard (see this track's wiringNotes:
// every call to it persists + receipts unconditionally), so this
// store's OWN dirty-check is load-bearing, not redundant.
//
// **Wiring confirmation (per this track's brief).** Editing an
// equation's LaTeX already goes through the EXISTING generic
// block-attribute-mutation path - `DocStore.setBody(_:for:)`
// (`DocStore.swift:172`, read-only per this wave's constraint, not
// modified here). No new DocStore method, no new Mutation case, no new
// receipt type: `setBody` already appends `DocReceiptType.updateBody`.
//
// **Equation numbering (design contract's own open question,
// resolved "join FieldController").** `FieldController`'s EXISTING
// `.sequence(name:)` `FieldKind` (`FieldController.swift:93,169-181`,
// confirmed already implemented - owned by track C2 this wave, NOT
// modified here) numbers a caption from document order with no stored
// counter. The convention this file adopts: a numbered equation is a
// `.equation` block immediately followed by a SIBLING `.field` block
// (same parent, next index in `children`/`rootChildren`) whose
// `FieldSpec.kind == .sequence(name: EquationNumbering.sequenceName)`
// - e.g. a caption paragraph "Equation " + that field's resolved text
// + ")" laid out around it, or the field block used bare as a running
// counter. This is a document-authoring-time convention, not a new
// attribute on `.equation` itself: `.field`, like `.footnote`/
// `.endnote`, is already a full sibling block type in this codebase
// (see `Block.swift`'s `BlockType.field` doc comment), so reusing that
// existing shape needs no new storage. `EquationNumbering
// .numberingField()` below is the one convenience this file adds - a
// constructor for that sibling block, calling `FieldController`'s
// public API exactly the way any other `.sequence` consumer would
// (see `StarMathEditorTests.swift`'s equation-numbering section for
// the resolution proof across multiple equations in document order).
// Inserting the
// pair (the `.equation` block AND its sibling `.field`) into a live
// document is a DOCUMENT-STRUCTURE operation (`Mutation
// .insertBlocksAfter`), which is the main editor surface's job, not
// this authoring pane's (`StarMathEditor` edits ONE existing
// equation's LaTeX; it does not insert blocks into the tree) - out of
// this file's scope by the same "one surface, one job" boundary
// `RevisionReviewPanel` draws around itself.

// MARK: - StarMathEquationMutation (pure - the ungated shadow)

/// Pure construction of the updated `DocumentAST` for committing a
/// `StarMathEditorStore` edit. See the file header - this is
/// `StarMathEditorStore.commit`'s "ungated shadow" (testing-doctrine.md
/// rule 11): every piece of the commit logic that CAN run without a
/// live `TesseraDataLayer` lives here, fully unit-testable on its own.
public enum StarMathEquationMutation {

    /// Returns `nil` - a no-op, testing-doctrine.md rule 1's
    /// guard-and-early-return - when `blockID` isn't a `.equation`
    /// block in `ast`, or when `latex` already matches its current
    /// `attributes["latex"]`. Otherwise returns the updated
    /// `DocumentAST` with ONLY that block's `attributes["latex"]`
    /// replaced.
    ///
    /// The equation's OTHER attributes (`originalStarMath`/
    /// `originalOMML`/`latexImportBaseline` - see
    /// `EquationImportMapping.swift`) are left untouched: they still
    /// describe the block's original import, which an edit through
    /// this source editor doesn't erase - a future exporter's
    /// `EquationImportMapping.isUnedited(_:)` check is what turns
    /// "edited" into "fall back to LaTeX-only re-serialization," not a
    /// deletion of the preserved original here.
    public static func committing(latex: String, blockID: UUID, in ast: DocumentAST) -> DocumentAST? {
        guard var block = ast.blocks[blockID], block.type == .equation else { return nil }
        guard block.attributes["latex"]?.stringValue != latex else { return nil }
        block.attributes["latex"] = .string(latex)
        var updated = ast
        updated.blocks[blockID] = block
        return updated
    }
}

// MARK: - EquationNumbering

/// The convention documented in the file header: a numbered
/// equation's sibling `.field` block, sharing one `.sequence` series
/// per document via `sequenceName`. See `FieldController.FieldKind
/// .sequence(name:)`.
public enum EquationNumbering {
    /// The `FieldKind.sequence(name:)` name every numbered equation's
    /// sibling `.field` block uses, so every equation in a document
    /// counts against the SAME series regardless of which surface
    /// inserted it.
    public static let sequenceName = "equation"

    /// Builds a fresh, unresolved sibling `.field` block for a numbered
    /// equation - `FieldController.refresh(_:in:)` (called by the same
    /// caller that would refresh any other field, e.g. `DocStore
    /// .refreshFields`) is what actually resolves its ordinal; this
    /// constructor only wires the `FieldSpec`, exactly the shape
    /// `FieldControllerTests.fieldBlock(kind:)` builds for every other
    /// `.sequence` consumer.
    public static func numberingField(id: UUID = UUID()) -> Block {
        var field = Block(id: id, type: .field)
        field.field = FieldSpec(kind: .sequence(name: sequenceName))
        return field
    }
}

// MARK: - StarMathSymbolPalette

/// A fixed catalog of common LaTeX snippets for the palette bar - v1's
/// "your call on the exact catalog, document it" (per this track's
/// brief). Chosen to cover exactly the constructs
/// `EquationImportMapping`'s StarMath/OMML converters also produce
/// (fractions, roots, sup/sub, sum/int/prod, common Greek letters,
/// relations), so a palette insertion and an imported equation always
/// land on LaTeX the SAME renderer already exercises.
public struct StarMathSymbolEntry: Identifiable, Sendable, Hashable {
    public let id: String
    public let label: String
    public let snippet: String

    public init(id: String, label: String, snippet: String) {
        self.id = id
        self.label = label
        self.snippet = snippet
    }
}

public enum StarMathSymbolPalette {
    public static let entries: [StarMathSymbolEntry] = [
        // "a"/"b" placeholders, not empty braces: a `\frac{}{}` with
        // BOTH slots empty rasterizes to a genuinely zero-size image in
        // SwiftMath (confirmed empirically - unlike `\sqrt{}` below,
        // whose radical glyph has its own inherent size even with an
        // empty radicand), which `renderLaTeX`'s own width/height>0
        // guard then correctly reports as unrenderable. Matches the
        // `sum`/`int`/`prod`/`lim` entries' own "real placeholder
        // content, not empty groups" convention below.
        .init(id: "frac", label: "Fraction", snippet: "\\frac{a}{b}"),
        .init(id: "sqrt", label: "Square root", snippet: "\\sqrt{}"),
        .init(id: "nroot", label: "Nth root", snippet: "\\sqrt[n]{}"),
        .init(id: "sup", label: "Superscript", snippet: "^{}"),
        .init(id: "sub", label: "Subscript", snippet: "_{}"),
        .init(id: "sum", label: "Sum", snippet: "\\sum_{i=1}^{n}"),
        .init(id: "int", label: "Integral", snippet: "\\int_{a}^{b}"),
        .init(id: "prod", label: "Product", snippet: "\\prod_{i=1}^{n}"),
        .init(id: "lim", label: "Limit", snippet: "\\lim_{x \\to 0}"),
        .init(id: "alpha", label: "alpha", snippet: "\\alpha"),
        .init(id: "beta", label: "beta", snippet: "\\beta"),
        .init(id: "pi", label: "pi", snippet: "\\pi"),
        .init(id: "infty", label: "Infinity", snippet: "\\infty"),
        .init(id: "pm", label: "Plus/minus", snippet: "\\pm"),
        .init(id: "neq", label: "Not equal", snippet: "\\neq"),
        .init(id: "leq", label: "Less/equal", snippet: "\\leq"),
        .init(id: "geq", label: "Greater/equal", snippet: "\\geq"),
        .init(id: "times", label: "Times", snippet: "\\times"),
        .init(id: "cdot", label: "Cdot", snippet: "\\cdot"),
        .init(id: "matrix", label: "2x2 matrix", snippet: "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}"),
    ]
}

// MARK: - StarMathEditorStore

/// The data + integration layer for the editor pane. `@Observable` so
/// the SwiftUI view can `@Bindable` it, matching `RevisionReviewStore`.
/// Owns the `DocStore` seam; the pure `StarMathEquationMutation` above
/// has none of that and is tested independently (rule 11).
@Observable
@MainActor
public final class StarMathEditorStore {

    private let docStore: DocStore
    public let docID: UUID
    public let blockID: UUID
    private let renderer: BlockRenderer

    /// The document AST snapshot `commit()` mutates against - see
    /// `refresh(from:)`. Starts `.empty`; a host MUST call
    /// `refresh(from:)` with the real document before `commit()` can do
    /// anything (an unrefreshed store's `commit()` is a no-op, since
    /// `blockID` won't be found in `.empty` - never a crash, just
    /// nothing to save yet).
    private var lastKnownAST: DocumentAST = .empty

    /// `latex` as of the last successful `commit()` (or the
    /// constructor's initial value) - the dirty-check baseline.
    /// NEVER mutated by live edits; only `commit()` advances it.
    public private(set) var committedLatex: String

    /// The live-edited buffer, bound directly to the source text
    /// editor. Every change re-renders the preview (debounced) but
    /// touches NEITHER `DocStore` NOR any receipt - see the file
    /// header's "Commit is explicit" section.
    public var latex: String {
        didSet {
            guard latex != oldValue else { return }
            scheduleDebouncedRender()
        }
    }

    /// The live preview, rendered via `BlockRenderer.renderLaTeX` -
    /// the SAME path `BlockRenderer.renderEquation` uses for the
    /// document view, per the design contract's "live preview
    /// (re-renders via the same SwiftMath path as item 2, debounced)".
    public private(set) var preview: NSAttributedString
    public private(set) var lastError: String?

    /// Debounce window before a `latex` edit re-renders the preview.
    /// Injectable (tests pass `0`) so the debounce is exercisable
    /// without a real multi-hundred-millisecond wait.
    public var debounceNanoseconds: UInt64
    private var renderTask: Task<Void, Never>?

    public init(
        docStore: DocStore,
        docID: UUID,
        blockID: UUID,
        latex: String,
        theme: EditorTheme = .light,
        debounceNanoseconds: UInt64 = 300_000_000
    ) {
        self.docStore = docStore
        self.docID = docID
        self.blockID = blockID
        self.committedLatex = latex
        self.latex = latex
        self.renderer = BlockRenderer(theme: theme)
        self.debounceNanoseconds = debounceNanoseconds
        self.preview = renderer.renderLaTeX(latex)
    }

    /// `true` when `latex` has changed since the last commit.
    public var isDirty: Bool { latex != committedLatex }

    /// Refreshes the AST snapshot `commit()` mutates against - call
    /// whenever the host document changes (open, and after any commit
    /// made elsewhere), mirroring `RevisionReviewStore.refresh(from:)`'s
    /// pull-not-push IA (see that file). `commit()` itself also keeps
    /// this snapshot current on a successful persist, so a host that
    /// only ever mutates the document THROUGH this store's own
    /// `commit()` never strictly needs to call this again - it exists
    /// for the case where the document changed some other way (another
    /// block edited, a field refreshed elsewhere) while this pane was
    /// open.
    public func refresh(from ast: DocumentAST) {
        lastKnownAST = ast
    }

    // MARK: - Preview (debounced)

    private func scheduleDebouncedRender() {
        renderTask?.cancel()
        let snapshot = latex
        let nanos = debounceNanoseconds
        renderTask = Task { [weak self] in
            if nanos > 0 {
                try? await Task.sleep(nanoseconds: nanos)
            }
            guard !Task.isCancelled else { return }
            self?.applyRender(snapshot)
        }
    }

    private func applyRender(_ latexAtScheduleTime: String) {
        // A newer edit superseded this one while we were waiting out
        // the debounce window - drop this stale render rather than
        // flashing an out-of-date preview back onto the current text.
        guard latexAtScheduleTime == latex else { return }
        preview = renderer.renderLaTeX(latexAtScheduleTime)
    }

    /// Renders `latex` immediately, bypassing the debounce - the test
    /// seam `StarMathEditorTests` uses instead of racing real wall-clock
    /// sleeps (testing-doctrine.md rule 4: no test should depend on
    /// timing races). Production code never needs to call this; the
    /// `didSet` debounce path is the real one.
    public func renderNow() {
        renderTask?.cancel()
        preview = renderer.renderLaTeX(latex)
    }

    // MARK: - Palette

    /// Appends a palette snippet to the end of the current buffer,
    /// inserting a separating space first when the buffer is non-empty
    /// and doesn't already end in whitespace or an open brace/bracket
    /// (so "x" + "^{}" reads "x^{}", not "x ^{}"). v1 has no
    /// cursor-position-aware insertion (`TextEditor`'s cross-platform
    /// selection API is the missing piece) - append-only is the
    /// documented v1 simplification, not a silently-assumed one.
    public func insertSnippet(_ snippet: String) {
        if latex.isEmpty {
            latex = snippet
            return
        }
        let last = latex.last
        let needsSpace = last != " " && last != "{" && last != "[" && last != "\n"
        latex += (needsSpace ? " " : "") + snippet
    }

    // MARK: - Commit / discard

    /// Persists `latex` via `DocStore.setBody` - the existing generic
    /// block-attribute-mutation path (see the file header's "Wiring
    /// confirmation"), against the AST snapshot `refresh(from:)` last
    /// recorded. A no-op (no `DocStore` call, no receipt) when
    /// `StarMathEquationMutation.committing` returns `nil` - either
    /// `blockID` isn't found/isn't `.equation` in the snapshot, or
    /// `latex` already matches the committed value. Returns `true` iff
    /// a persist actually happened; on success, the snapshot advances
    /// to the persisted AST so a following edit's `commit()` diffs
    /// against the up-to-date state.
    @discardableResult
    public func commit() async -> Bool {
        guard let updated = StarMathEquationMutation.committing(latex: latex, blockID: blockID, in: lastKnownAST) else {
            return false
        }
        do {
            _ = try await docStore.setBody(updated, for: docID)
            committedLatex = latex
            lastKnownAST = updated
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Reverts `latex` to the last committed value, discarding any
    /// unsaved edit.
    public func discard() {
        latex = committedLatex
    }
}

// MARK: - StarMathEditorView

/// The source-editor + live-preview + symbol-palette pane. See the
/// file header for the structural precedent this mirrors
/// (`CodeEditorView`'s raw-source-editing pane, paired here with a
/// live rendered-output pane it has no equivalent of).
public struct StarMathEditorView: View {
    @Bindable public var store: StarMathEditorStore
    public var onCommit: (() -> Void)?
    public var onDiscard: (() -> Void)?

    public init(store: StarMathEditorStore, onCommit: (() -> Void)? = nil, onDiscard: (() -> Void)? = nil) {
        self.store = store
        self.onCommit = onCommit
        self.onDiscard = onDiscard
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sourcePane
                Divider()
                previewPane
            }
            Divider()
            palette
        }
    }

    private var header: some View {
        HStack {
            Text("Equation")
                .font(.headline)
            if store.isDirty {
                Text("Edited")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Discard") {
                store.discard()
                onDiscard?()
            }
            .disabled(!store.isDirty)
            Button("Save") {
                Task {
                    if await store.commit() {
                        onCommit?()
                    }
                }
            }
            .disabled(!store.isDirty)
        }
        .padding(8)
    }

    private var sourcePane: some View {
        TextEditor(text: $store.latex)
            .font(.system(.body, design: .monospaced))
            .frame(minWidth: 220, minHeight: 120)
            .accessibilityLabel("Equation LaTeX source")
    }

    private var previewPane: some View {
        ScrollView {
            VStack {
                if let image = store.preview.soleAttachmentImage {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 320)
                        .padding()
                } else {
                    Text(store.preview.string)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 180, minHeight: 120)
        .accessibilityLabel("Equation preview")
    }

    private var palette: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(StarMathSymbolPalette.entries) { entry in
                    Button(entry.label) {
                        store.insertSnippet(entry.snippet)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(8)
        }
    }
}

// MARK: - Cross-platform Image bridge

extension Image {
    /// `Image(nsImage:)` on macOS, `Image(uiImage:)` on iOS - the one
    /// piece of platform branching `StarMathEditorView` needs, kept
    /// local to this file's own SwiftUI layer (`BlockRenderer.swift`
    /// stays free of any `import SwiftUI`).
    init(platformImage: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: platformImage)
        #elseif canImport(UIKit)
        self.init(uiImage: platformImage)
        #endif
    }
}
