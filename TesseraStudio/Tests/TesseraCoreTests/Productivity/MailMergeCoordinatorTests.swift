import XCTest
@testable import TesseraCore

// MARK: - MailMergeCoordinatorTests
//
// Contract: sota-p2-core-report.md's "2.4 MailMergeCoordinator -
// restatement (ratified; decision row 16)" + studio-expansion-design-
// refinement-2026-08-14.md 5's "2.21 Mail-merge wizard + 2.4
// coordinator" + this track's own brief (item 5's four required cases:
// N-records -> N-docs with correct substitution; a name absent from a
// record degrades gracefully; the merge_run tool's own coverage lives in
// MailMergeToolsTests.swift) + MailMergeCoordinator.swift's own file
// header for the pure/I-O-shell split and the design calls recorded
// there and in docs/.scratch/p2-c-findings-2.md.
//
// GATING (doctrine rule 11): the two PURE halves (`records(from:)`,
// `mergedDocs(template:records:clock:)`, `mergeFieldNames(in:)`,
// `sanitizedFilename`, `sourceHash`) need no store and are fully covered
// UNGATED below - this is the wave's own "ungated shadow" for `run(...)`,
// which needs a live `DocStore`/`SheetStore` (no in-memory/fake seam
// exists for either anywhere in this codebase - `DocStoreTests.swift`'s
// own file header) AND shells out to `/usr/bin/textutil` via
// `DocumentExporter.export` (the same method `DocumentExporterTests.
// swift` explicitly keeps out of its own default-suite coverage: "export
// ... shell out to /usr/bin/textutil and AppKit and are explicitly OUT
// of scope here"). `run(...)`'s own tests below reuse the SAME
// `TESSERA_DB_INTEGRATION=1` gate `DocStoreTests` established rather
// than inventing a second gate variable.

final class MailMergeCoordinatorTests: DoctrineTestCase {

    private let fixedClock: () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }

    // MARK: - Fixtures

    /// A template `Doc` with two `.mergeField` placeholders
    /// (FirstName/LastName) plus one ordinary paragraph, matching a
    /// real merge letter's shape: static prose + placeholders, not
    /// placeholders alone.
    private func templateDoc(id: UUID = UUID()) -> Doc {
        let greetingID = UUID()
        let firstNameID = UUID()
        let lastNameID = UUID()
        var ast = DocumentAST()
        ast.blocks[greetingID] = Block(id: greetingID, type: .paragraph, content: [InlineRun(text: "Dear ")])
        var firstField = Block(id: firstNameID, type: .field)
        firstField.field = FieldSpec(kind: .mergeField(name: "FirstName"))
        ast.blocks[firstNameID] = firstField
        var lastField = Block(id: lastNameID, type: .field)
        lastField.field = FieldSpec(kind: .mergeField(name: "LastName"))
        ast.blocks[lastNameID] = lastField
        ast.rootChildren = [greetingID, firstNameID, lastNameID]
        return Doc(id: id, title: "Merge Letter", body: ast)
    }

    /// A 3-record Sheet: columns FirstName/LastName, matching
    /// `templateDoc()`'s two placeholders. Row 2 (Grace/nil) is missing
    /// a LastName VALUE (empty cell, not a missing column) to exercise
    /// blank-not-crash at the RECORD level too, distinct from the
    /// name-absent-from-record-map case covered at the FieldController
    /// layer already.
    private func contactsSheet() -> Sheet {
        var sheet = Sheet.makeBlank(title: "Contacts", rows: 3, cols: 2)
        sheet.columns = [
            SheetColumn(label: "FirstName", type: .text),
            SheetColumn(label: "LastName", type: .text),
        ]
        sheet = sheet.settingCellText(row: 0, col: 0, "Ada")
        sheet = sheet.settingCellText(row: 0, col: 1, "Lovelace")
        sheet = sheet.settingCellText(row: 1, col: 0, "Alan")
        sheet = sheet.settingCellText(row: 1, col: 1, "Turing")
        sheet = sheet.settingCellText(row: 2, col: 0, "Grace")
        // row 2 col 1 left blank on purpose.
        return sheet
    }

    // MARK: - records(from:): Sheet grid -> [[String: String]]

    func testRecordsFromSheetProducesOneRecordPerRowKeyedByColumnLabel() {
        let records = MailMergeCoordinator.records(from: contactsSheet())
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0], ["FirstName": "Ada", "LastName": "Lovelace"])
        XCTAssertEqual(records[1], ["FirstName": "Alan", "LastName": "Turing"])
        XCTAssertEqual(records[2], ["FirstName": "Grace", "LastName": ""])
    }

    func testRecordsFromSheetWithNoColumnsReturnsEmpty() {
        let sheet = Sheet.makeBlank(title: "Empty", rows: 3, cols: 0)
        XCTAssertEqual(MailMergeCoordinator.records(from: sheet), [])
    }

    func testRecordsFromSheetWithNoRowsReturnsEmpty() {
        var sheet = Sheet.makeBlank(title: "Empty", rows: 0, cols: 2)
        sheet.columns = [SheetColumn(label: "FirstName"), SheetColumn(label: "LastName")]
        XCTAssertEqual(MailMergeCoordinator.records(from: sheet), [])
    }

    /// This track's own documented call (docs/.scratch/p2-c-findings-2.md):
    /// a blank column label (after trimming) cannot match any
    /// `.mergeField(name:)` - it is skipped rather than keyed by "".
    func testRecordsFromSheetSkipsBlankColumnLabels() {
        var sheet = Sheet.makeBlank(title: "Contacts", rows: 1, cols: 2)
        sheet.columns = [SheetColumn(label: "FirstName"), SheetColumn(label: "   ")]
        sheet = sheet.settingCellText(row: 0, col: 0, "Ada")
        sheet = sheet.settingCellText(row: 0, col: 1, "Lovelace")
        let records = MailMergeCoordinator.records(from: sheet)
        XCTAssertEqual(records, [["FirstName": "Ada"]])
    }

    /// This track's own documented call: a duplicate label after
    /// trimming has the LATER (higher-index) column win, matching plain
    /// `[key: value]` last-write-wins dictionary-literal semantics.
    func testRecordsFromSheetDuplicateColumnLabelLaterColumnWins() {
        var sheet = Sheet.makeBlank(title: "Dup", rows: 1, cols: 2)
        sheet.columns = [SheetColumn(label: "Name"), SheetColumn(label: "Name")]
        sheet = sheet.settingCellText(row: 0, col: 0, "first-column-value")
        sheet = sheet.settingCellText(row: 0, col: 1, "second-column-value")
        let records = MailMergeCoordinator.records(from: sheet)
        XCTAssertEqual(records, [["Name": "second-column-value"]])
    }

    // MARK: - mergedDocs: N records -> N docs, correct field substitution
    //
    // This is item 5's headline required case: "MailMergeCoordinator
    // produces exactly N output Docs for N records with correct field
    // substitution (hand-built 2-3 record fixture)."

    func testMergedDocsProducesExactlyOneDocPerRecordWithCorrectSubstitution() {
        let template = templateDoc()
        let records = MailMergeCoordinator.records(from: contactsSheet())
        let merged = MailMergeCoordinator.mergedDocs(template: template, records: records, clock: fixedClock)

        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(mergedFieldText(merged[0], name: "FirstName"), "Ada")
        XCTAssertEqual(mergedFieldText(merged[0], name: "LastName"), "Lovelace")
        XCTAssertEqual(mergedFieldText(merged[1], name: "FirstName"), "Alan")
        XCTAssertEqual(mergedFieldText(merged[1], name: "LastName"), "Turing")
        XCTAssertEqual(mergedFieldText(merged[2], name: "FirstName"), "Grace")
        XCTAssertEqual(mergedFieldText(merged[2], name: "LastName"), "", "a blank source cell substitutes an empty string, not a crash")
    }

    /// Every merged Doc is a FRESH document, never the template and
    /// never a sibling - mail merge fans out to N NEW outputs.
    func testMergedDocsEachOutputHasAFreshDistinctID() {
        let template = templateDoc()
        let records = MailMergeCoordinator.records(from: contactsSheet())
        let merged = MailMergeCoordinator.mergedDocs(template: template, records: records, clock: fixedClock)
        let ids = Set(merged.map { $0.id })
        XCTAssertEqual(ids.count, merged.count, "every output Doc must have a distinct id")
        XCTAssertFalse(ids.contains(template.id), "an output Doc must never reuse the template's own id")
    }

    /// Static prose (the "Dear " paragraph) survives the merge
    /// unchanged - only `.field` blocks are touched.
    func testMergedDocsPreservesNonFieldContentVerbatim() {
        let template = templateDoc()
        let records = MailMergeCoordinator.records(from: contactsSheet())
        let merged = MailMergeCoordinator.mergedDocs(template: template, records: records, clock: fixedClock)
        for doc in merged {
            let paragraphText = doc.body.rootChildren
                .compactMap { doc.body.blocks[$0] }
                .first { $0.type == .paragraph }?
                .content.map { $0.text }.joined()
            XCTAssertEqual(paragraphText, "Dear ")
        }
    }

    func testMergedDocsWithZeroRecordsProducesZeroDocs() {
        let template = templateDoc()
        let merged = MailMergeCoordinator.mergedDocs(template: template, records: [], clock: fixedClock)
        XCTAssertEqual(merged, [])
    }

    /// A `.mergeField` name with NO entry anywhere in the record
    /// (distinct from an entry with an empty value, covered above)
    /// degrades to an empty substitution - item 5's "a template with a
    /// mergeField name absent from a given record degrades gracefully"
    /// case, exercised through the coordinator's own public surface
    /// rather than only at the `FieldController` unit level.
    func testMergedDocsWithFieldNameAbsentFromRecordSubstitutesEmptyString() {
        let template = templateDoc()
        // This record has FirstName but no LastName key at all.
        let merged = MailMergeCoordinator.mergedDocs(template: template, records: [["FirstName": "Ada"]], clock: fixedClock)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(mergedFieldText(merged[0], name: "FirstName"), "Ada")
        XCTAssertEqual(mergedFieldText(merged[0], name: "LastName"), "")
    }

    private func mergedFieldText(_ doc: Doc, name: String) -> String? {
        for id in doc.body.depthFirstOrder() {
            guard let block = doc.body.blocks[id], block.type == .field,
                  let spec = block.field, case .mergeField(let fieldName) = spec.kind,
                  fieldName == name
            else { continue }
            return block.content.map { $0.text }.joined()
        }
        return nil
    }

    // MARK: - mergeFieldNames(in:): template detection for the wizard's field chips

    func testMergeFieldNamesReturnsEveryDistinctNameInDocumentOrder() {
        let names = MailMergeCoordinator.mergeFieldNames(in: templateDoc())
        XCTAssertEqual(names, ["FirstName", "LastName"])
    }

    func testMergeFieldNamesDeduplicatesRepeatedPlaceholders() {
        var ast = DocumentAST()
        let firstID = UUID()
        let secondID = UUID()
        var firstBlock = Block(id: firstID, type: .field)
        firstBlock.field = FieldSpec(kind: .mergeField(name: "FirstName"))
        var secondBlock = Block(id: secondID, type: .field)
        secondBlock.field = FieldSpec(kind: .mergeField(name: "FirstName"))
        ast.blocks[firstID] = firstBlock
        ast.blocks[secondID] = secondBlock
        ast.rootChildren = [firstID, secondID]
        let names = MailMergeCoordinator.mergeFieldNames(in: Doc(body: ast))
        XCTAssertEqual(names, ["FirstName"], "the same placeholder used twice must not produce two chips")
    }

    func testMergeFieldNamesIgnoresOtherFieldKinds() {
        var ast = DocumentAST()
        let dateID = UUID()
        var dateBlock = Block(id: dateID, type: .field)
        dateBlock.field = FieldSpec(kind: .date)
        ast.blocks[dateID] = dateBlock
        ast.rootChildren = [dateID]
        XCTAssertEqual(MailMergeCoordinator.mergeFieldNames(in: Doc(body: ast)), [])
    }

    func testMergeFieldNamesOnTemplateWithNoFieldsReturnsEmpty() {
        XCTAssertEqual(MailMergeCoordinator.mergeFieldNames(in: Doc(body: .empty)), [])
    }

    // MARK: - sourceHash: deterministic content addressing

    func testSourceHashIsDeterministicForTheSameRecords() {
        let records = [["FirstName": "Ada"], ["FirstName": "Alan"]]
        XCTAssertEqual(MailMergeCoordinator.sourceHash(records: records), MailMergeCoordinator.sourceHash(records: records))
    }

    func testSourceHashDiffersForDifferentRecords() {
        let a = MailMergeCoordinator.sourceHash(records: [["FirstName": "Ada"]])
        let b = MailMergeCoordinator.sourceHash(records: [["FirstName": "Alan"]])
        XCTAssertNotEqual(a, b)
    }

    func testSourceHashUsesTheSameShaPrefixConventionAsContentHash() {
        let hash = MailMergeCoordinator.sourceHash(records: [["FirstName": "Ada"]])
        XCTAssertTrue(hash.hasPrefix("sha256:"), "must match DocumentAST.contentHash()'s own \"sha256:<hex>\" format")
    }

    // MARK: - sanitizedFilename

    func testSanitizedFilenameStripsPathSeparatorsAndCollapsesWhitespace() {
        XCTAssertEqual(MailMergeCoordinator.sanitizedFilename("Q3 Report: Client/Vendor"), "Q3 Report Client Vendor")
    }

    func testSanitizedFilenameFallsBackToUntitledWhenFullyStripped() {
        XCTAssertEqual(MailMergeCoordinator.sanitizedFilename("///"), "Untitled")
        XCTAssertEqual(MailMergeCoordinator.sanitizedFilename(""), "Untitled")
    }
}

// MARK: - MailMergeCoordinatorRunTests (gated I/O shell)

final class MailMergeCoordinatorRunTests: DoctrineTestCase {
    override var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.probe }

    private func requireDBIntegration() throws {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip("gated: set TESSERA_DB_INTEGRATION=1 to run MailMergeCoordinator.run(...) against a live Postgres/Valkey - see DocStoreTests.swift for the same gate. The happy-path test below ALSO shells out to /usr/bin/textutil via DocumentExporter.export - the same carve-out DocumentExporterTests.swift documents for that method, reused here rather than inventing a second gate.")
        }
    }

    private func makeCoordinator() async throws -> (coordinator: MailMergeCoordinator, docStore: DocStore, sheetStore: SheetStore) {
        let dataLayer = TesseraDataLayer()
        _ = await dataLayer.start()
        let docStore = DocStore(dataLayer: dataLayer)
        let sheetStore = SheetStore(dataLayer: dataLayer)
        return (MailMergeCoordinator(docStore: docStore, sheetStore: sheetStore), docStore, sheetStore)
    }

    // MARK: - Denial paths: fail closed with a named reason, no partial state

    func testRunThrowsTemplateNotFoundForAnUnknownTemplateID() async throws {
        try requireDBIntegration()
        let (coordinator, _, sheetStore) = try await makeCoordinator()
        var sheet = Sheet(title: "Contacts")
        sheet.columns = [SheetColumn(label: "FirstName")]
        _ = try await sheetStore.upsert(sheet)

        do {
            _ = try await coordinator.run(
                templateDocID: UUID(),
                sourceEntityID: sheet.id,
                outputFormat: .pdf,
                destinationDirectory: FileManager.default.temporaryDirectory
            )
            XCTFail("expected templateNotFound")
        } catch let error as MailMergeCoordinatorError {
            guard case .templateNotFound = error else {
                return XCTFail("expected .templateNotFound, got \(error)")
            }
        }
    }

    func testRunThrowsSourceNotFoundForAnUnknownSourceID() async throws {
        try requireDBIntegration()
        let (coordinator, docStore, _) = try await makeCoordinator()
        let doc = try await docStore.upsert(Doc(title: "Template"))

        do {
            _ = try await coordinator.run(
                templateDocID: doc.id,
                sourceEntityID: UUID(),
                outputFormat: .pdf,
                destinationDirectory: FileManager.default.temporaryDirectory
            )
            XCTFail("expected sourceNotFound")
        } catch let error as MailMergeCoordinatorError {
            guard case .sourceNotFound = error else {
                return XCTFail("expected .sourceNotFound, got \(error)")
            }
        }
    }

    func testRunThrowsNoRecordsForASourceWithZeroRows() async throws {
        try requireDBIntegration()
        let (coordinator, docStore, sheetStore) = try await makeCoordinator()
        let doc = try await docStore.upsert(Doc(title: "Template"))
        var sheet = Sheet.makeBlank(title: "Empty", rows: 0, cols: 1)
        sheet.columns = [SheetColumn(label: "FirstName")]
        let storedSheet = try await sheetStore.upsert(sheet)

        do {
            _ = try await coordinator.run(
                templateDocID: doc.id,
                sourceEntityID: storedSheet.id,
                outputFormat: .pdf,
                destinationDirectory: FileManager.default.temporaryDirectory
            )
            XCTFail("expected noRecords")
        } catch let error as MailMergeCoordinatorError {
            guard case .noRecords = error else {
                return XCTFail("expected .noRecords, got \(error)")
            }
        }
    }

    // MARK: - Happy path: N records -> N persisted Docs, each with its own doc_upsert receipt

    func testRunPersistsOneOutputDocPerRecordEachWithExactlyOneUpsertReceipt() async throws {
        try requireDBIntegration()
        let (coordinator, docStore, sheetStore) = try await makeCoordinator()

        var ast = DocumentAST()
        let fieldID = UUID()
        var field = Block(id: fieldID, type: .field)
        field.field = FieldSpec(kind: .mergeField(name: "FirstName"))
        ast.blocks[fieldID] = field
        ast.rootChildren = [fieldID]
        let template = try await docStore.upsert(Doc(title: "Template", body: ast))

        var sheet = Sheet.makeBlank(title: "Contacts", rows: 2, cols: 1)
        sheet.columns = [SheetColumn(label: "FirstName")]
        sheet = sheet.settingCellText(row: 0, col: 0, "Ada")
        sheet = sheet.settingCellText(row: 1, col: 0, "Alan")
        let storedSheet = try await sheetStore.upsert(sheet)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mail-merge-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // No extra `withDoctrineTimeout` wrap needed: this class already
        // overrides `doctrineTimeoutSeconds` to `.probe` above, which
        // covers this whole test via the class-level watchdog.
        let result = try await coordinator.run(
            templateDocID: template.id,
            sourceEntityID: storedSheet.id,
            outputFormat: .pdf,
            destinationDirectory: tempDir
        )

        XCTAssertEqual(result.recordCount, 2)
        XCTAssertEqual(result.outputDocIDs.count, 2)
        XCTAssertEqual(result.outputURLs.count, 2)
        XCTAssertTrue(result.sourceHash.hasPrefix("sha256:"))

        for id in result.outputDocIDs {
            let receipts = try await docStore.receipts(forDoc: id)
            XCTAssertEqual(
                receipts.filter { $0.receiptType == DocReceiptType.upsert.rawValue }.count, 1,
                "each output Doc must carry exactly one doc_upsert receipt through the existing DocStore.upsert path"
            )
        }
        for url in result.outputURLs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
