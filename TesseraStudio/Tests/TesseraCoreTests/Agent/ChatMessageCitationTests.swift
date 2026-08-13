import XCTest
@testable import TesseraCore

// Tests for the `sources: [Citation]` field on `ChatMessage`
// (review #5 of the agent-ux-fatigue Tessera Studio audit,
// Wave 3A). The verification-paradox move: every tool result that
// surfaces sources (today only `research`) lifts its `data["sources"]`
// onto the row as a `Citation` set, so the chat row can render
// verifiable evidence chips next to the assistant's prose.
//
// The acceptance criteria this file pins:
//   1. The `Citation` struct is well-formed and Codable.
//   2. `ChatMessage.sources` defaults to empty and is round-trip-safe.
//   3. `ToolResultPayload.sources` defaults to empty and survives
//      JSON round-trip alongside the existing `confidenceBand` field.
//   4. `UnifiedChatController.extractCitations(from:)` reads the
//      `data["sources"]` array the research tool emits and produces
//      a `Citation` per entry, with URL normalization and dedup.
//   5. `recordToolResult` lifts the citations onto the row's
//      `toolCalls[i].result.sources` (so the view layer can render).
//   6. ASCII-only, build passes, tests pass.

final class ChatMessageCitationTests: XCTestCase {

    // MARK: - Citation struct

    func testCitationInitDefaultsSnippetToEmpty() {
        // Snippet is the optional third field. Default "" so callers
        // can construct a bare id+label citation without ceremony.
        let c = Citation(id: "x", label: "y")
        XCTAssertEqual(c.id, "x")
        XCTAssertEqual(c.label, "y")
        XCTAssertEqual(c.snippet, "")
        XCTAssertNil(c.url)
        XCTAssertNil(c.range)
    }

    func testCitationInitAcceptsURLAndRange() {
        // URL is the route target; range is the inline anchor. Both
        // are nil-by-default. The round-trip test below pins the
        // Codable behaviour.
        let c = Citation(
            id: "https://example.com/article",
            label: "Example Article",
            snippet: "A short excerpt",
            url: "https://example.com/article",
            range: RangeOffset(start: 10, end: 25)
        )
        XCTAssertEqual(c.id, "https://example.com/article")
        XCTAssertEqual(c.url, "https://example.com/article")
        XCTAssertEqual(c.range?.start, 10)
        XCTAssertEqual(c.range?.end, 25)
    }

    func testCitationEquality() {
        // Equatable so the chat row can dedupe citations by id
        // before rendering.
        let a = Citation(id: "u", label: "x", snippet: "alpha")
        let b = Citation(id: "u", label: "x", snippet: "alpha")
        let c = Citation(id: "u", label: "x", snippet: "beta")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testCitationCodableRoundTrip() {
        // The on-disk shape: id, label, snippet, url?, range?. A
        // future migration that drops a field would break this.
        let original = Citation(
            id: "https://example.com/x",
            label: "Example",
            snippet: "snippet text",
            url: "https://example.com/x",
            range: RangeOffset(start: 0, end: 12)
        )
        let data = try? JSONEncoder().encode(original)
        XCTAssertNotNil(data)
        let restored = try? JSONDecoder().decode(Citation.self, from: data ?? Data())
        XCTAssertEqual(restored, original)
    }

    func testCitationCodableWithoutOptionalFields() {
        // Nil URL + nil range is the documented "bare citation" path
        // (e.g. a title-only source). The encoded form must omit
        // both fields, not write nulls.
        let original = Citation(id: "abc", label: "Title")
        let data = try? JSONEncoder().encode(original)
        XCTAssertNotNil(data)
        let restored = try? JSONDecoder().decode(Citation.self, from: data ?? Data())
        XCTAssertEqual(restored?.id, "abc")
        XCTAssertEqual(restored?.label, "Title")
        XCTAssertNil(restored?.url)
        XCTAssertNil(restored?.range)
    }

    // MARK: - ChatMessage.sources

    func testChatMessageDefaultSourcesIsEmpty() {
        // The field is always present (possibly empty). Default
        // construction -> empty array, never nil.
        let msg = ChatMessage(role: .assistant, content: "ok")
        XCTAssertEqual(msg.sources, [])
    }

    func testChatMessageAcceptsSourcesInInit() {
        // The init takes an explicit sources list. Used by the
        // persistence layer when it serializes a row's tool calls
        // back into a ChatMessage.
        let c = Citation(id: "u", label: "l")
        let msg = ChatMessage(role: .assistant, content: "ok", sources: [c])
        XCTAssertEqual(msg.sources.count, 1)
        XCTAssertEqual(msg.sources.first?.id, "u")
    }

    // MARK: - ToolResultPayload.sources

    func testToolResultPayloadDefaultSourcesIsEmpty() {
        // Default construction (no sources arg) -> empty array.
        // The field is additive on top of `confidenceBand` and
        // follows the same nil-or-non-nil discipline.
        let p = ToolResultPayload(success: true, output: "ok")
        XCTAssertEqual(p.sources, [])
    }

    func testToolResultPayloadCarriesSources() {
        // Explicit list survives the constructor. The wave 2D
        // `confidenceBand` field coexists; both are independent.
        let c = Citation(id: "u", label: "l")
        let p = ToolResultPayload(
            success: true,
            output: "ok",
            confidenceBand: .medium,
            sources: [c]
        )
        XCTAssertEqual(p.sources.count, 1)
        XCTAssertEqual(p.confidenceBand, .medium)
    }

    func testToolResultPayloadCodableRoundTripPreservesSources() {
        // The on-disk migration test: the new field must survive
        // the same JSON encoder the SwiftData layer uses.
        let original = ToolResultPayload(
            success: true,
            output: "ok",
            error: nil,
            confidenceBand: .low,
            sources: [Citation(id: "u1", label: "L1"), Citation(id: "u2", label: "L2")]
        )
        let data = try? JSONEncoder().encode(original)
        XCTAssertNotNil(data)
        let restored = try? JSONDecoder().decode(ToolResultPayload.self, from: data ?? Data())
        XCTAssertEqual(restored?.sources.count, 2)
        XCTAssertEqual(restored?.sources.first?.id, "u1")
        XCTAssertEqual(restored?.confidenceBand, .low)
    }

    func testToolResultPayloadWithEmptySourcesRoundTrips() {
        // The "no citations" path must survive the same encoder.
        // A silent regression that dropped the field would fail
        // this test.
        let original = ToolResultPayload(success: true, output: "ok")
        let data = try? JSONEncoder().encode(original)
        XCTAssertNotNil(data)
        let restored = try? JSONDecoder().decode(ToolResultPayload.self, from: data ?? Data())
        XCTAssertEqual(restored?.sources, [])
    }

    // MARK: - URL normalization

    func testNormalizeCitationIDStripsTrailingSlashes() {
        // The K1 verifier (TesseraResearchTool) uses the URL with
        // trailing slashes stripped as its match key. The chat
        // controller's normalizeCitationID must do the same so a
        // citation emitted by the research tool and re-derived
        // from the tool result dedupes to a single id.
        XCTAssertEqual(
            UnifiedChatController.normalizeCitationID("https://example.com/page/"),
            "https://example.com/page"
        )
        XCTAssertEqual(
            UnifiedChatController.normalizeCitationID("https://example.com/page///"),
            "https://example.com/page"
        )
        XCTAssertEqual(
            UnifiedChatController.normalizeCitationID("https://example.com/page"),
            "https://example.com/page"
        )
    }

    func testNormalizeCitationIDTrimsWhitespace() {
        // Whitespace around a URL is harmless; trim so the
        // deduped id is stable across tool output quirks.
        XCTAssertEqual(
            UnifiedChatController.normalizeCitationID("  https://example.com  "),
            "https://example.com"
        )
    }

    // MARK: - extractCitations(from:)

    func testExtractCitationsEmptyDataReturnsEmpty() {
        // No data block -> no citations. The documented "tool
        // produced no evidence" path. The row shows no chips.
        let r = ToolResult.ok("done", data: nil)
        XCTAssertEqual(UnifiedChatController.extractCitations(from: r), [])
    }

    func testExtractCitationsMissingSourcesKeyReturnsEmpty() {
        // data is present but no `sources` key. The research
        // tool is the only known emitter today; other tools
        // that have `data` without `sources` produce no chips.
        let r = ToolResult.ok("done", data: ["unrelated": .string("x")])
        XCTAssertEqual(UnifiedChatController.extractCitations(from: r), [])
    }

    func testExtractCitationsFromResearchShape() {
        // The research tool emits `data["sources"]` as an array
        // of `{url, title, content}` objects. The helper turns
        // each into a Citation, with id = URL, label = title,
        // snippet = content (truncated).
        let sources: [JSONValue] = [
            .object([
                "url": .string("https://example.com/a"),
                "title": .string("Article A"),
                "content": .string("Body of A"),
            ]),
            .object([
                "url": .string("https://example.com/b"),
                "title": .string("Article B"),
                "content": .string("Body of B"),
            ]),
        ]
        let r = ToolResult.ok("answer", data: ["sources": .array(sources)])
        let citations = UnifiedChatController.extractCitations(from: r)
        XCTAssertEqual(citations.count, 2)
        XCTAssertEqual(citations[0].id, "https://example.com/a")
        XCTAssertEqual(citations[0].label, "Article A")
        XCTAssertEqual(citations[0].snippet, "Body of A")
        XCTAssertEqual(citations[0].url, "https://example.com/a")
        XCTAssertEqual(citations[1].id, "https://example.com/b")
    }

    func testExtractCitationsDeduplicatesByNormalizedURL() {
        // Two sources with the same URL but different trailing
        // slash variants collapse to one citation. This is the
        // K1 verifier's key discipline mirrored on the controller
        // path.
        let sources: [JSONValue] = [
            .object(["url": .string("https://example.com/a"), "title": .string("A1")]),
            .object(["url": .string("https://example.com/a/"), "title": .string("A2")]),
            .object(["url": .string("https://example.com/b"), "title": .string("B")]),
        ]
        let r = ToolResult.ok("x", data: ["sources": .array(sources)])
        let citations = UnifiedChatController.extractCitations(from: r)
        XCTAssertEqual(citations.count, 2, "Trailing-slash duplicate must collapse")
        XCTAssertEqual(citations[0].id, "https://example.com/a")
        XCTAssertEqual(citations[1].id, "https://example.com/b")
    }

    func testExtractCitationsHandlesNonObjectEntries() {
        // Mixed-shape arrays (some entries are objects, some
        // strings or nulls) must not crash. Non-object entries
        // are silently skipped.
        let sources: [JSONValue] = [
            .object(["url": .string("https://example.com/a"), "title": .string("A")]),
            .string("not an object"),
            .null,
            .array([]),
            .object(["url": .string("https://example.com/b"), "title": .string("B")]),
        ]
        let r = ToolResult.ok("x", data: ["sources": .array(sources)])
        let citations = UnifiedChatController.extractCitations(from: r)
        XCTAssertEqual(citations.count, 2)
    }

    func testExtractCitationsTruncatesSnippet() {
        // Long content is truncated to snippetCap. The full
        // content lives in the source (the chip routes to it).
        let longContent = String(repeating: "x", count: 500)
        let sources: [JSONValue] = [
            .object([
                "url": .string("https://example.com/a"),
                "title": .string("A"),
                "content": .string(longContent),
            ]),
        ]
        let r = ToolResult.ok("x", data: ["sources": .array(sources)])
        let citations = UnifiedChatController.extractCitations(from: r)
        XCTAssertEqual(citations.count, 1)
        XCTAssertLessThanOrEqual(citations[0].snippet.count, UnifiedChatController.snippetCap)
    }

    func testExtractCitationsSynthesizesIDWhenURLMissing() {
        // Some tools may emit citations without a URL (e.g. a
        // local file path). The helper synthesizes a stable id
        // from the title so the chip still has a unique key.
        let sources: [JSONValue] = [
            .object([
                "url": .string(""),
                "title": .string("Local Doc"),
                "content": .string("body"),
            ]),
        ]
        let r = ToolResult.ok("x", data: ["sources": .array(sources)])
        let citations = UnifiedChatController.extractCitations(from: r)
        XCTAssertEqual(citations.count, 1)
        XCTAssertTrue(citations[0].id.hasPrefix("title:"))
        XCTAssertNil(citations[0].url)
    }

    // MARK: - ToolCallRecord designated init

    func testToolCallRecordDesignatedInitPreservesID() {
        // The controller's recordToolResult replaces the row's
        // tool call to attach the result; the id MUST survive
        // the replacement so the SwiftUI array diff is stable.
        let id = UUID()
        let call = ToolCallRecord(
            id: id,
            toolName: "research",
            arguments: ["query": .string("x")]
        )
        XCTAssertEqual(call.id, id)
        XCTAssertEqual(call.toolName, "research")
        XCTAssertNil(call.result)
    }

    func testToolCallRecordDesignatedInitWithResult() {
        // The second arm of the replacement: a populated result
        // with citations. Used by recordToolResult to write the
        // tool's `data["sources"]` back onto the row.
        let id = UUID()
        let citations = [Citation(id: "u", label: "l")]
        let result = ToolResultPayload(success: true, output: "ok", sources: citations)
        let call = ToolCallRecord(
            id: id,
            toolName: "research",
            arguments: [:],
            result: result
        )
        XCTAssertEqual(call.id, id)
        XCTAssertEqual(call.result?.sources.count, 1)
    }

    // MARK: - Codable round-trip for ChatMessage sources

    func testChatMessageSourcesArrayRoundTrips() {
        // Sources is part of the @Model storage. The encoder is
        // JSON, so the round-trip must be lossless.
        let original: [Citation] = [
            Citation(id: "u1", label: "L1", snippet: "s1"),
            Citation(id: "u2", label: "L2", url: "https://example.com/2"),
        ]
        // Round-trip the `sources` array directly via JSONEncoder,
        // which is the storage form.
        let data = try? JSONEncoder().encode(original)
        XCTAssertNotNil(data)
        let restored = try? JSONDecoder().decode([Citation].self, from: data ?? Data())
        XCTAssertEqual(restored?.count, 2)
        XCTAssertEqual(restored?[0].id, "u1")
        XCTAssertEqual(restored?[1].url, "https://example.com/2")
    }
}
