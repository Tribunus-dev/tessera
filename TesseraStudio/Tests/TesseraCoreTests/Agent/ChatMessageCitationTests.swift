import XCTest
@testable import TesseraCore

// EXACT file/name per docs/PROJECT-STATUS.md's own listed path for this
// contract (Wave 3A, item 3A) even though `ChatMessage.swift` physically
// lives in `Sources/TesseraCore/Models/` -- Citation/RangeOffset/
// ConfidenceBand/ChatMessage.sources/ToolResultPayload.sources are
// agent-surface contracts per AGENTS.md's "Citation + uncertainty on chat
// + tool results (Waves 2-3, items 2D and 3A)" section.
//
// Contract sources:
// - Sources/TesseraCore/Models/ChatMessage.swift doc comments (Citation,
//   RangeOffset, ConfidenceBand, ToolResultPayload, ChatMessage.sources).
// - Sources/TesseraCore/Agent/UnifiedChatController.swift's
//   `extractCitations(from:)` / `normalizeCitationID(_:)` doc comments --
//   "the same shape the research tool emits", URL-normalization dedup,
//   snippet cap.
final class ChatMessageCitationTests: DoctrineTestCase {

    // MARK: - Citation: round-trip identity (rule 2)

    func testCitationEncodeDecodeIdentityWithAllFieldsPresent() throws {
        let citation = Citation(
            id: "https://example.com/a",
            label: "Example A",
            snippet: "an excerpt",
            url: "https://example.com/a",
            range: RangeOffset(start: 2, end: 9)
        )
        let data = try JSONEncoder().encode(citation)
        let decoded = try JSONDecoder().decode(Citation.self, from: data)
        XCTAssertEqual(decoded, citation)
    }

    func testCitationEncodeDecodeIdentityWithOptionalFieldsNil() throws {
        let citation = Citation(id: "local:1", label: "Local file")
        let data = try JSONEncoder().encode(citation)
        let decoded = try JSONDecoder().decode(Citation.self, from: data)
        XCTAssertEqual(decoded, citation)
        XCTAssertNil(decoded.url)
        XCTAssertNil(decoded.range)
    }

    func testCitationDecodesFromLegacyJSONMissingOptionalFields() throws {
        // Pin the on-disk shape: only the four required-looking fields
        // present, url/range absent entirely (not merely null).
        let json = Data(#"{"id":"x","label":"X","snippet":""}"#.utf8)
        let decoded = try JSONDecoder().decode(Citation.self, from: json)
        XCTAssertEqual(decoded, Citation(id: "x", label: "X", snippet: ""))
    }

    func testCitationDefaultSnippetIsEmptyString() {
        let citation = Citation(id: "x", label: "X")
        XCTAssertEqual(citation.snippet, "")
    }

    // MARK: - RangeOffset: round-trip identity (rule 2)

    func testRangeOffsetEncodeDecodeIdentity() throws {
        let range = RangeOffset(start: 3, end: 11)
        let data = try JSONEncoder().encode(range)
        let decoded = try JSONDecoder().decode(RangeOffset.self, from: data)
        XCTAssertEqual(decoded, range)
    }

    // MARK: - ConfidenceBand: round-trip + exhaustive categorical set

    func testConfidenceBandEncodeDecodeIdentity() throws {
        for band in ConfidenceBand.allCases {
            let data = try JSONEncoder().encode(band)
            let decoded = try JSONDecoder().decode(ConfidenceBand.self, from: data)
            XCTAssertEqual(decoded, band)
        }
    }

    func testConfidenceBandIsExactlyLowMediumHigh() {
        // Independent oracle (rule 7): pinned against AGENTS.md's named
        // set ("low | medium | high"), not against ConfidenceBand.allCases.
        XCTAssertEqual(Set(ConfidenceBand.allCases.map(\.rawValue)), ["low", "medium", "high"])
    }

    // MARK: - ToolResultPayload: round-trip identity (rule 2)

    func testToolResultPayloadEncodeDecodeIdentityWithSourcesAndBand() throws {
        let payload = ToolResultPayload(
            success: true,
            output: "3 results",
            error: nil,
            confidenceBand: .medium,
            sources: [Citation(id: "u1", label: "One", snippet: "s1", url: "https://a")]
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ToolResultPayload.self, from: data)
        XCTAssertEqual(decoded.success, payload.success)
        XCTAssertEqual(decoded.output, payload.output)
        XCTAssertEqual(decoded.confidenceBand, payload.confidenceBand)
        XCTAssertEqual(decoded.sources, payload.sources)
    }

    func testToolResultPayloadDefaultsAreEmptySourcesAndNilBand() {
        let payload = ToolResultPayload(success: true, output: "ok")
        XCTAssertEqual(payload.sources, [])
        XCTAssertNil(payload.confidenceBand)
    }

    func testToolResultPayloadDecodesFromLegacyJSONWithNoSourcesField() {
        // Pin the pre-3A on-disk shape (before `sources` existed): decode
        // must succeed and default `sources` to [].
        let json = Data(#"{"success":true,"output":"ok"}"#.utf8)
        let decoded = try? JSONDecoder().decode(ToolResultPayload.self, from: json)
        XCTExpectFailure("SUSPECTED CODE BUG: ToolResultPayload.sources is a non-Optional [Citation] with no custom Decodable init, so Swift's synthesized decoder requires the \"sources\" key and throws keyNotFound on pre-3A on-disk JSON instead of defaulting to [] - confidenceBand (a genuine Optional) does correctly default via decodeIfPresent, sources does not - see findings") {
            XCTAssertNotNil(decoded, "legacy JSON missing the sources field (added in item 3A) must still decode")
        }
    }

    // MARK: - ChatMessage.sources (SwiftData @Model, plain-object construction)

    func testChatMessageDefaultsToEmptySources() {
        let message = ChatMessage(role: .assistant, content: "hi")
        XCTAssertEqual(message.sources, [])
    }

    func testChatMessageCarriesSuppliedSources() {
        let citation = Citation(id: "u1", label: "One")
        let message = ChatMessage(role: .assistant, content: "hi", sources: [citation])
        XCTAssertEqual(message.sources, [citation])
    }

    // MARK: - UnifiedChatController.extractCitations(from:): the citation
    // provenance path (AGENTS.md: "UnifiedChatController.swift (emits
    // citations from the tool-call provenance)")

    func testExtractCitationsIsEmptyWhenResultHasNoData() {
        let result = ToolResult.ok("no data")
        XCTAssertEqual(UnifiedChatController.extractCitations(from: result), [])
    }

    func testExtractCitationsIsEmptyWhenDataHasNoSourcesKey() {
        let result = ToolResult.ok("x", data: ["other": .string("y")])
        XCTAssertEqual(UnifiedChatController.extractCitations(from: result), [])
    }

    func testExtractCitationsIsEmptyWhenSourcesIsNotAnArray() {
        let result = ToolResult.ok("x", data: ["sources": .string("not-an-array")])
        XCTAssertEqual(UnifiedChatController.extractCitations(from: result), [])
    }

    func testExtractCitationsParsesUrlTitleContentShape() {
        let sourceObject = JSONValue.object([
            "url": .string("https://example.com/page"),
            "title": .string("Page Title"),
            "content": .string("the body excerpt"),
        ])
        let result = ToolResult.ok("done", data: ["sources": .array([sourceObject])])
        let citations = UnifiedChatController.extractCitations(from: result)
        XCTAssertEqual(citations.count, 1)
        XCTAssertEqual(citations[0].id, "https://example.com/page")
        XCTAssertEqual(citations[0].label, "Page Title")
        XCTAssertEqual(citations[0].snippet, "the body excerpt")
        XCTAssertEqual(citations[0].url, "https://example.com/page")
    }

    func testExtractCitationsMissingUrlFallsBackToTitlePrefixedID() {
        let sourceObject = JSONValue.object(["title": .string("No URL Here")])
        let result = ToolResult.ok("done", data: ["sources": .array([sourceObject])])
        let citations = UnifiedChatController.extractCitations(from: result)
        XCTAssertEqual(citations.count, 1)
        XCTAssertEqual(citations[0].id, "title:No URL Here")
        XCTAssertNil(citations[0].url, "no url field present -> url is nil, not empty string")
    }

    func testExtractCitationsWithNoUrlAndNoTitleStillProducesATitleColonEmptyID() {
        // baseID becomes "title:" + "" = "title:", which is non-empty, so
        // the skip-when-id-is-empty guard does NOT fire here -- this pins
        // the exact boundary (a source with neither url nor title is kept
        // with a degenerate "title:" id, not silently dropped).
        let sourceObject = JSONValue.object(["content": .string("body with no url or title")])
        let result = ToolResult.ok("done", data: ["sources": .array([sourceObject])])
        let citations = UnifiedChatController.extractCitations(from: result)
        XCTAssertEqual(citations.count, 1)
        XCTAssertEqual(citations[0].id, "title:")
        XCTAssertEqual(citations[0].label, "")
    }

    func testExtractCitationsDeduplicatesTrailingSlashVariants() {
        let a = JSONValue.object(["url": .string("https://example.com/page/"), "title": .string("A")])
        let b = JSONValue.object(["url": .string("https://example.com/page"), "title": .string("B")])
        let result = ToolResult.ok("done", data: ["sources": .array([a, b])])
        let citations = UnifiedChatController.extractCitations(from: result)
        XCTAssertEqual(citations.count, 1, "trailing-slash and non-trailing-slash variants collapse to one citation")
        XCTAssertEqual(citations[0].id, "https://example.com/page")
        XCTAssertEqual(citations[0].label, "A", "first-seen wins the dedup")
    }

    func testExtractCitationsSkipsNonObjectArrayEntries() {
        let result = ToolResult.ok("done", data: ["sources": .array([.string("not an object"), .null])])
        XCTAssertEqual(UnifiedChatController.extractCitations(from: result), [])
    }

    func testExtractCitationsSnippetIsTruncatedToTheDocumentedCap() {
        let longContent = String(repeating: "x", count: 500)
        let sourceObject = JSONValue.object(["url": .string("https://example.com/p"), "title": .string("T"), "content": .string(longContent)])
        let result = ToolResult.ok("done", data: ["sources": .array([sourceObject])])
        let citations = UnifiedChatController.extractCitations(from: result)
        XCTAssertEqual(citations.count, 1)
        XCTAssertEqual(citations[0].snippet.count, UnifiedChatController.snippetCap)
        XCTAssertEqual(citations[0].snippet, String(repeating: "x", count: UnifiedChatController.snippetCap))
    }

    func testExtractCitationsSnippetUnderTheCapIsNotTruncated() {
        let sourceObject = JSONValue.object(["url": .string("https://example.com/p"), "title": .string("T"), "content": .string("short")])
        let result = ToolResult.ok("done", data: ["sources": .array([sourceObject])])
        let citations = UnifiedChatController.extractCitations(from: result)
        XCTAssertEqual(citations[0].snippet, "short")
    }

    func testExtractCitationsPreservesMultipleDistinctSources() {
        let a = JSONValue.object(["url": .string("https://a.example.com"), "title": .string("A")])
        let b = JSONValue.object(["url": .string("https://b.example.com"), "title": .string("B")])
        let result = ToolResult.ok("done", data: ["sources": .array([a, b])])
        let citations = UnifiedChatController.extractCitations(from: result)
        XCTAssertEqual(citations.map(\.id), ["https://a.example.com", "https://b.example.com"])
    }
}
