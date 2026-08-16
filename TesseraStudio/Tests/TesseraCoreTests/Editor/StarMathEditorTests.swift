import XCTest
@testable import TesseraCore

// MARK: - StarMathEditorTests
//
// Contract: item 2.14's design contract + this track's item 6 test
// list: "equation numbering via the existing .sequence FieldKind
// resolves correctly across multiple equations in document order."
// Plus StarMathEditor.swift's own file header for the commit/dirty-
// check/debounce contracts.
//
// GATING (doctrine rule 11): `StarMathEquationMutation` (pure) and
// `EquationNumbering`/`StarMathSymbolPalette` (pure data) are tested
// fully ungated below - no DocStore, no live DB. `StarMathEditorStore
// .commit()`'s end-to-end persistence is gated on
// TESSERA_DB_INTEGRATION=1 (DocStore has no in-memory seam anywhere in
// this codebase - see RevisionReviewStoreTests.swift's own header,
// copied verbatim here), because the logic it exercises beyond
// `StarMathEquationMutation` (already fully covered above) is a single
// straight-through call to `DocStore.setBody`.

final class StarMathEditorTests: DoctrineTestCase {

    // MARK: - Fixtures

    private func equationBlock(id: UUID = UUID(), latex: String) -> Block {
        var block = Block(id: id, type: .equation)
        block.attributes["latex"] = .string(latex)
        return block
    }

    private func astWithEquation(id: UUID = UUID(), latex: String) -> (ast: DocumentAST, id: UUID) {
        var ast = DocumentAST()
        ast.blocks[id] = equationBlock(id: id, latex: latex)
        ast.rootChildren = [id]
        return (ast, id)
    }

    // MARK: - StarMathEquationMutation.committing (pure - the ungated shadow)

    func testCommittingReplacesOnlyTheLatexAttribute() throws {
        let equationID = UUID()
        var ast = DocumentAST()
        var block = equationBlock(id: equationID, latex: "a^2")
        block.attributes["color"] = .string("blue") // an unrelated attribute must survive untouched
        ast.blocks[equationID] = block
        ast.rootChildren = [equationID]

        let updated = try XCTUnwrap(StarMathEquationMutation.committing(latex: "b^2", blockID: equationID, in: ast))
        let updatedBlock = try XCTUnwrap(updated.blocks[equationID])
        XCTAssertEqual(updatedBlock.attributes["latex"]?.stringValue, "b^2")
        XCTAssertEqual(updatedBlock.attributes["color"]?.stringValue, "blue")
    }

    func testCommittingPreservesImportProvenanceAttributes() throws {
        let block = EquationImportMapping.equationBlock(fromStarMath: "a over b")
        var ast = DocumentAST()
        ast.blocks[block.id] = block
        ast.rootChildren = [block.id]

        let updated = try XCTUnwrap(StarMathEquationMutation.committing(latex: "\\frac{a}{c}", blockID: block.id, in: ast))
        let updatedBlock = try XCTUnwrap(updated.blocks[block.id])
        XCTAssertEqual(updatedBlock.attributes[EquationImportMapping.originalStarMathKey]?.stringValue, "a over b",
                       "the preserved original must survive an unrelated latex edit")
        XCTAssertFalse(EquationImportMapping.isUnedited(updatedBlock), "latex now diverges from the import baseline")
    }

    func testCommittingIsANoOpWhenLatexIsUnchanged() {
        let (ast, id) = astWithEquation(latex: "a^2")
        let updated = StarMathEquationMutation.committing(latex: "a^2", blockID: id, in: ast)
        XCTAssertNil(updated, "no receipt without a mutation - identical latex must be a no-op")
    }

    func testCommittingIsANoOpWhenBlockIDIsNotInTheDocument() {
        let (ast, _) = astWithEquation(latex: "a^2")
        let updated = StarMathEquationMutation.committing(latex: "b^2", blockID: UUID(), in: ast)
        XCTAssertNil(updated)
    }

    func testCommittingIsANoOpWhenTheBlockIsNotAnEquation() {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .paragraph, content: [InlineRun(text: "not an equation")])
        ast.rootChildren = [id]
        let updated = StarMathEquationMutation.committing(latex: "a^2", blockID: id, in: ast)
        XCTAssertNil(updated)
    }

    // MARK: - EquationNumbering (joins the EXISTING FieldController.sequence)

    func testNumberingFieldBuildsASequenceFieldSpecUsingTheSharedSeriesName() {
        let field = EquationNumbering.numberingField()
        XCTAssertEqual(field.type, .field)
        XCTAssertEqual(field.field?.kind, .sequence(name: EquationNumbering.sequenceName))
    }

    /// The resolution proof: N numbered equations, each with its own
    /// sibling `.field(.sequence(name: "equation"))` block per this
    /// file's documented convention, resolve to 1..N in DOCUMENT
    /// ORDER via `FieldController.refresh` - the EXISTING public API,
    /// called exactly as `FieldControllerTests`'s own
    /// `testSequenceFieldNumbersFromDocumentOrderAmongSameName` calls
    /// it for any other `.sequence` series. `FieldController.swift`
    /// itself is untouched by this track.
    func testMultipleNumberedEquationsResolveInDocumentOrderViaFieldController() {
        let fixedClock: () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }
        var ast = DocumentAST()

        let eq1 = equationBlock(latex: "a^2")
        let field1 = EquationNumbering.numberingField()
        let eq2 = equationBlock(latex: "b^2")
        let field2 = EquationNumbering.numberingField()
        let eq3 = equationBlock(latex: "c^2")
        let field3 = EquationNumbering.numberingField()

        for block in [eq1, field1, eq2, field2, eq3, field3] {
            ast.blocks[block.id] = block
        }
        // Document order: equation, its numbering field, equation, its
        // numbering field, ... - the sibling-pair convention this
        // file's header documents.
        ast.rootChildren = [eq1.id, field1.id, eq2.id, field2.id, eq3.id, field3.id]

        let resolved1 = FieldController.refresh(field1, in: ast, clock: fixedClock)
        let resolved2 = FieldController.refresh(field2, in: ast, clock: fixedClock)
        let resolved3 = FieldController.refresh(field3, in: ast, clock: fixedClock)

        XCTAssertEqual(resolved1.content.first?.text, "1")
        XCTAssertEqual(resolved2.content.first?.text, "2")
        XCTAssertEqual(resolved3.content.first?.text, "3")
    }

    /// A `.sequence(name: "equation")` field must NOT share its
    /// counter with an unrelated `.sequence` series (e.g. "Figure") -
    /// `FieldController`'s own per-name scoping, exercised through
    /// this file's convention.
    func testEquationNumberingSeriesIsIndependentOfOtherSequenceSeries() {
        let fixedClock: () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }
        var ast = DocumentAST()
        var figureField = Block(type: .field)
        figureField.field = FieldSpec(kind: .sequence(name: "Figure"))
        let eqField = EquationNumbering.numberingField()
        ast.blocks[figureField.id] = figureField
        ast.blocks[eqField.id] = eqField
        ast.rootChildren = [figureField.id, eqField.id]

        let resolvedEquation = FieldController.refresh(eqField, in: ast, clock: fixedClock)
        XCTAssertEqual(resolvedEquation.content.first?.text, "1", "the equation series must not inherit Figure's count")
    }

    // MARK: - StarMathSymbolPalette (v1 catalog)

    func testSymbolPaletteEntriesHaveUniqueIDs() {
        let ids = StarMathSymbolPalette.entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate palette entry ids")
    }

    func testSymbolPaletteIsNonEmpty() {
        XCTAssertFalse(StarMathSymbolPalette.entries.isEmpty)
    }

    func testEverySymbolPaletteSnippetRendersWithoutProducingAnErrorIndicator() {
        // Every palette snippet is inserted into an OTHERWISE EMPTY
        // buffer in this check (the palette's own job is to hand back
        // valid LaTeX fragments; whether the surrounding formula stays
        // valid after insertion is the user's concern, same as any
        // text editor's snippet-insertion feature).
        let renderer = BlockRenderer(theme: .light)
        for entry in StarMathSymbolPalette.entries {
            // A few entries (bare "^{}"/"_{}") aren't valid as a
            // STANDALONE formula - SwiftMath requires a preceding
            // atom for sup/sub. Those two are the documented exception;
            // every other entry must stand alone without erroring.
            guard entry.id != "sup", entry.id != "sub" else { continue }
            let attributed = renderer.renderLaTeX(entry.snippet)
            XCTAssertNotNil(attributed.soleAttachmentImage, "\(entry.id) (\(entry.snippet)) produced an error indicator instead of rendering")
        }
    }

    // MARK: - StarMathEditorStore: dirty tracking + palette insertion (no DocStore needed)

    @MainActor
    private func makeStoreForPureBehavior() -> (store: StarMathEditorStore, docID: UUID, blockID: UUID) {
        let docID = UUID()
        let blockID = UUID()
        let docStore = DocStore(dataLayer: TesseraDataLayer())
        let store = StarMathEditorStore(docStore: docStore, docID: docID, blockID: blockID, latex: "a^2", debounceNanoseconds: 0)
        return (store, docID, blockID)
    }

    @MainActor
    func testStoreStartsNotDirty() {
        let (store, _, _) = makeStoreForPureBehavior()
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(store.committedLatex, "a^2")
    }

    @MainActor
    func testEditingLatexMarksTheStoreDirty() {
        let (store, _, _) = makeStoreForPureBehavior()
        store.latex = "b^2"
        XCTAssertTrue(store.isDirty)
    }

    @MainActor
    func testDiscardRevertsToTheCommittedLatexAndClearsDirty() {
        let (store, _, _) = makeStoreForPureBehavior()
        store.latex = "b^2"
        store.discard()
        XCTAssertEqual(store.latex, "a^2")
        XCTAssertFalse(store.isDirty)
    }

    @MainActor
    func testInsertSnippetAppendsWithASeparatingSpaceWhenNeeded() {
        let (store, _, _) = makeStoreForPureBehavior()
        store.latex = "a"
        store.insertSnippet("\\sqrt{}")
        XCTAssertEqual(store.latex, "a \\sqrt{}")
    }

    @MainActor
    func testInsertSnippetDoesNotAddASpaceAfterAnOpenBrace() {
        let (store, _, _) = makeStoreForPureBehavior()
        store.latex = "\\frac{"
        store.insertSnippet("a")
        XCTAssertEqual(store.latex, "\\frac{a")
    }

    @MainActor
    func testInsertSnippetOnAnEmptyBufferSetsItDirectly() {
        let (store, _, _) = makeStoreForPureBehavior()
        store.latex = ""
        store.insertSnippet("\\alpha")
        XCTAssertEqual(store.latex, "\\alpha")
    }

    // MARK: - StarMathEditorStore: preview rendering (renderNow bypasses the debounce -
    // doctrine rule 4, no test should race a real wall-clock sleep)

    @MainActor
    func testRenderNowProducesAnImageForWellFormedLatex() {
        let (store, _, _) = makeStoreForPureBehavior()
        store.latex = "\\frac{1}{2}"
        store.renderNow()
        XCTAssertNotNil(store.preview.soleAttachmentImage)
    }

    @MainActor
    func testRenderNowProducesAnErrorIndicatorForMalformedLatex() {
        let (store, _, _) = makeStoreForPureBehavior()
        store.latex = "\\frac{1"
        store.renderNow()
        XCTAssertNil(store.preview.soleAttachmentImage)
        XCTAssertTrue(store.preview.string.contains("[Equation error:"))
    }

    // MARK: - StarMathEditorStore.commit(): the no-op path (ungated - no DocStore call happens)

    @MainActor
    func testCommitWithoutARefreshIsANoOpAgainstTheEmptyDefaultSnapshot() async {
        let (store, _, _) = makeStoreForPureBehavior()
        store.latex = "b^2" // dirty, but no refresh(from:) was ever called
        let didCommit = await store.commit()
        XCTAssertFalse(didCommit, "commit() against the default .empty snapshot must no-op, never crash or fabricate a DocStore call")
        XCTAssertTrue(store.isDirty, "a no-op commit must not clear the dirty flag")
    }

    @MainActor
    func testCommitIsANoOpWhenLatexMatchesTheRefreshedSnapshot() async {
        let (store, _, blockID) = makeStoreForPureBehavior()
        let (ast, _) = astWithEquation(id: blockID, latex: "a^2")
        store.refresh(from: ast)
        // store.latex is already "a^2" (the constructor's initial value) - unchanged.
        let didCommit = await store.commit()
        XCTAssertFalse(didCommit)
    }

    // MARK: - StarMathEditorStore.commit(): end-to-end persistence (DB-gated shadow)
    //
    // Gating rationale: see this file's header + RevisionReviewStoreTests.swift's
    // own header - DocStore has no in-memory seam in this codebase.

    private func requireDBIntegration() throws {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip("gated: set TESSERA_DB_INTEGRATION=1 to run StarMathEditorStore.commit() against a live Postgres/Valkey")
        }
    }

    @MainActor
    func testCommitPersistsTheNewLatexAndAppendsExactlyOneReceipt() async throws {
        try requireDBIntegration()
        let dataLayer = TesseraDataLayer()
        _ = await dataLayer.start()
        let docStore = DocStore(dataLayer: dataLayer)

        let docID = UUID()
        let blockID = UUID()
        let (ast, _) = astWithEquation(id: blockID, latex: "a^2")
        _ = try await docStore.upsert(Doc(id: docID, title: "StarMathEditor Test", body: ast))

        let store = StarMathEditorStore(docStore: docStore, docID: docID, blockID: blockID, latex: "a^2", debounceNanoseconds: 0)
        store.refresh(from: ast)
        store.latex = "b^2"

        let before = try await docStore.receipts(forDoc: docID)
        let didCommit = await store.commit()
        let after = try await docStore.receipts(forDoc: docID)

        XCTAssertTrue(didCommit)
        XCTAssertEqual(after.count - before.count, 1, "commit() must append exactly one receipt (no receipt without a mutation, no more than one per mutation)")
        XCTAssertFalse(store.isDirty)

        let reloaded = try await docStore.get(id: docID)
        XCTAssertEqual(reloaded?.body.blocks[blockID]?.attributes["latex"]?.stringValue, "b^2")
    }

    @MainActor
    func testCommitNoOpAppendsZeroReceipts() async throws {
        try requireDBIntegration()
        let dataLayer = TesseraDataLayer()
        _ = await dataLayer.start()
        let docStore = DocStore(dataLayer: dataLayer)

        let docID = UUID()
        let blockID = UUID()
        let (ast, _) = astWithEquation(id: blockID, latex: "a^2")
        _ = try await docStore.upsert(Doc(id: docID, title: "StarMathEditor No-Op Test", body: ast))

        let store = StarMathEditorStore(docStore: docStore, docID: docID, blockID: blockID, latex: "a^2", debounceNanoseconds: 0)
        store.refresh(from: ast)
        // latex left unchanged - a no-op commit.

        let before = try await docStore.receipts(forDoc: docID)
        let didCommit = await store.commit()
        let after = try await docStore.receipts(forDoc: docID)

        XCTAssertFalse(didCommit)
        XCTAssertEqual(after.count, before.count, "a no-op commit must append zero receipts and persist nothing")
    }
}
