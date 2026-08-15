import XCTest
import CryptoKit
@testable import TesseraCore

// MARK: - ReceiptExportServiceTests
//
// Contract: ReceiptExportService.swift's own doc comments on each build
// helper - `buildMarkdownSummary`: "Each receipt is a section with the
// timestamp, actor, summary, and mutations list"; `slugify`/`makeFilename`
// (used by the export UI's save panel); `flattenAST`: "headings are
// prefixed with the corresponding number of # characters."
//
// SCOPE: `ReceiptExportService.export(...)` shells out to a live
// `TesseraDataLayer`/`DocumentStore` (and, for `.file` exports, a Python
// subprocess bridge) - that end-to-end path has no seam either (same gap
// as DocStore/DocumentStore, see docs/.scratch/test-rewrite-findings-
// writer.md) and is out of scope here. Every helper this file DOES test
// (`buildMarkdownSummary`/`buildSignedJSONBundle`/`buildC2PADocument`/
// `flattenAST`/`makeFilename`/`slugify`) is pure formatting logic that
// needs no I/O - constructing a `ReceiptExportService` itself performs no
// network/DB work (only `.start()`/`.export(...)` do), so these run as a
// completely ordinary, ungated unit test.

final class ReceiptExportServiceTests: DoctrineTestCase {

    private func makeService() -> ReceiptExportService {
        let dataLayer = TesseraDataLayer() // never started - no I/O
        let documentStore = DocumentStore(dataLayer: dataLayer)
        let signer = ReceiptSigner(signingKey: Curve25519.Signing.PrivateKey())
        return ReceiptExportService(documentStore: documentStore, dataLayer: dataLayer, signer: signer)
    }

    private func signedReceipt(summary: String, mutations: [Mutation] = [], actor: Actor = .user(UUID())) throws -> Receipt {
        let signer = ReceiptSigner(signingKey: Curve25519.Signing.PrivateKey())
        // Fixed, whole-second timestamp (doctrine rule 4: no bare
        // Date() in fixtures) - a sub-second Date() would round-trip
        // through the .iso8601 encoder used elsewhere in this file
        // with its fractional seconds truncated, breaking any
        // encode-decode identity comparison against the original.
        return try signer.sign(
            documentID: UUID(), mutations: mutations, priorReceiptID: nil, actor: actor,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - slugify

    func testSlugifyLowercasesAndReplacesNonAlphanumericWithDashes() {
        XCTAssertEqual(ReceiptExportService.slugify("My Great Doc!"), "my-great-doc")
    }

    func testSlugifyCollapsesConsecutiveDashesAndTrimsEdges() {
        XCTAssertEqual(ReceiptExportService.slugify("  --Weird///Title--  "), "weird-title")
    }

    func testSlugifyOfEmptyOrAllPunctuationDefaultsToDocument() {
        XCTAssertEqual(ReceiptExportService.slugify(""), "document")
        XCTAssertEqual(ReceiptExportService.slugify("!!!"), "document")
    }

    func testSlugifyTruncatesTo64Characters() {
        let longTitle = String(repeating: "a", count: 200)
        XCTAssertEqual(ReceiptExportService.slugify(longTitle).count, 64)
    }

    // MARK: - makeFilename

    func testMakeFilenameForSignedJSONIncludesAuditSuffixAndDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let name = ReceiptExportService.makeFilename(documentTitle: "My Doc", format: .signedJSON, now: now)
        XCTAssertTrue(name.hasPrefix("my-doc-audit-"))
        XCTAssertTrue(name.hasSuffix(".json"))
    }

    func testMakeFilenameForC2PADocumentUsesC2PASuffix() {
        let name = ReceiptExportService.makeFilename(documentTitle: "My Doc", format: .c2paDocument)
        XCTAssertTrue(name.hasPrefix("my-doc-c2pa"))
    }

    // MARK: - buildMarkdownSummary: content assertions (doctrine rule 8)

    func testBuildMarkdownSummaryIncludesTitleReceiptCountAndPerReceiptFields() throws {
        let service = makeService()
        let receipt = try signedReceipt(summary: "did a thing", mutations: [.deleteBlock(blockID: UUID())])
        let data = service.buildMarkdownSummary(documentTitle: "Quarterly Report", chain: [receipt])
        let markdown = String(data: data, encoding: .utf8)!

        XCTAssertTrue(markdown.contains("# Quarterly Report"))
        XCTAssertTrue(markdown.contains("1 receipt"))
        // signedReceipt's `summary:` parameter is a call-site label only
        // - ReceiptSigner.sign has no summary override, it always
        // derives Receipt.summary from composeSummary(for: mutations),
        // which for a single mutation is that mutation's own
        // shortDescription ("delete block", asserted below) - so the
        // literal "did a thing" string never appears in real output.
        XCTAssertTrue(markdown.contains(receipt.summary), "the receipt's actual composed summary must appear")
        XCTAssertTrue(markdown.contains(receipt.id.uuidString))
        XCTAssertTrue(markdown.contains("delete block"), "the mutation's shortDescription must appear in the mutations list")
    }

    func testBuildMarkdownSummaryPluralizesReceiptCountCorrectly() throws {
        let service = makeService()
        let r1 = try signedReceipt(summary: "one")
        let r2 = try signedReceipt(summary: "two")
        let data = service.buildMarkdownSummary(documentTitle: "Doc", chain: [r1, r2])
        let markdown = String(data: data, encoding: .utf8)!
        XCTAssertTrue(markdown.contains("2 receipts"))
    }

    func testBuildMarkdownSummaryNotesNonDocumentReceiptsWithNoMutations() throws {
        let service = makeService()
        let exportReceipt = try signedReceipt(summary: "Exported 1 receipt as Signed JSON bundle", mutations: [])
        let data = service.buildMarkdownSummary(documentTitle: "Doc", chain: [exportReceipt])
        let markdown = String(data: data, encoding: .utf8)!
        XCTAssertTrue(markdown.contains("_(none — non-document receipt, e.g. export)_"))
    }

    func testBuildMarkdownSummaryShowsAgentActorWithModelAndPromptHash() throws {
        let service = makeService()
        let receipt = try signedReceipt(summary: "agent edit", actor: .agent(UUID(), model: "claude-5", promptHash: "abcdef1234567890"))
        let data = service.buildMarkdownSummary(documentTitle: "Doc", chain: [receipt])
        let markdown = String(data: data, encoding: .utf8)!
        XCTAssertTrue(markdown.contains("claude-5"))
    }

    func testBuildMarkdownSummaryNotesVoidedReceipts() throws {
        let service = makeService()
        var receipt = try signedReceipt(summary: "will be undone")
        let voidingID = UUID()
        receipt.voidedBy = voidingID
        let data = service.buildMarkdownSummary(documentTitle: "Doc", chain: [receipt])
        let markdown = String(data: data, encoding: .utf8)!
        XCTAssertTrue(markdown.contains(voidingID.uuidString))
    }

    // MARK: - buildSignedJSONBundle: self-contained, decodes back to the same chain

    func testBuildSignedJSONBundleDecodesBackToTheSameReceiptChain() throws {
        let service = makeService()
        let documentID = UUID()
        let receipt = try signedReceipt(summary: "x")
        let data = try service.buildSignedJSONBundle(documentID: documentID, chain: [receipt], documentTitle: "Doc")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SignedExportBundle.self, from: data)
        XCTAssertEqual(decoded.documentID, documentID)
        XCTAssertEqual(decoded.receiptCount, 1)
        XCTAssertEqual(decoded.chain, [receipt])
    }

    // MARK: - buildC2PADocument: embeds the last manifest, flattens the body

    func testBuildC2PADocumentEmbedsTheLastReceiptsManifestWhenPresent() throws {
        let service = makeService()
        let receipt = try signedReceipt(summary: "x")
        XCTAssertNotNil(receipt.c2paManifest, "sign() always produces a manifest")
        let data = try service.buildC2PADocument(documentID: UUID(), documentTitle: "Doc", chain: [receipt], ast: .empty)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(C2PADocumentEnvelope.self, from: data)
        XCTAssertNotNil(envelope.embeddedManifest)
    }

    func testBuildC2PADocumentHasNilEmbeddedManifestWhenChainIsEmpty() throws {
        let service = makeService()
        let data = try service.buildC2PADocument(documentID: UUID(), documentTitle: "Doc", chain: [], ast: .empty)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(C2PADocumentEnvelope.self, from: data)
        XCTAssertNil(envelope.embeddedManifest)
    }

    // MARK: - flattenAST: markdown-ish rendering (fixtures, doctrine rule 9)

    func testFlattenASTPrefixesHeadingsWithHashesMatchingTheirLevel() {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .heading, attributes: ["level": .number(2)], content: [InlineRun(text: "Section")])
        ast.rootChildren = [id]
        XCTAssertTrue(ReceiptExportService.flattenAST(ast).contains("## Section"))
    }

    func testFlattenASTRendersListItemsWithDashPrefix() {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .listItem, content: [InlineRun(text: "item one")])
        ast.rootChildren = [id]
        XCTAssertTrue(ReceiptExportService.flattenAST(ast).contains("- item one"))
    }

    func testFlattenASTRendersDividerAsThreeDashes() {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .divider)
        ast.rootChildren = [id]
        XCTAssertTrue(ReceiptExportService.flattenAST(ast).contains("---"))
    }

    func testFlattenASTRendersCodeBlockWithTripleBacktickFences() {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .codeBlock, content: [InlineRun(text: "let x = 1")])
        ast.rootChildren = [id]
        let flattened = ReceiptExportService.flattenAST(ast)
        XCTAssertTrue(flattened.contains("```\nlet x = 1\n```"))
    }
}
