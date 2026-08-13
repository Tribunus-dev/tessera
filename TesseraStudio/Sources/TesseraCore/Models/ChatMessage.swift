import Foundation
import SwiftData

public enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
    case system
    case tool
}

/// A single tool call recorded within a chat message.
public struct ToolCallRecord: Codable, Sendable, Identifiable {
    public let id: UUID
    public let toolName: String
    public let arguments: [String: JSONValue]
    public let result: ToolResultPayload?
    public let timestamp: Date

    public init(toolName: String, arguments: [String: JSONValue], result: ToolResultPayload? = nil) {
        self.id = UUID()
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.timestamp = Date()
    }

    /// Designated init for the Wave 3A tool-result update path: the
    /// controller already has a tool call row (with a stable `id` it
    /// generated when the call began) and needs to attach the result
    /// without re-rolling the id. Without this init, the SwiftUI
    /// array-replace would orphan the call's id and the chat row
    /// would render the tool call twice (once with `result: nil`,
    /// once with the result). Pinning the id keeps the row stable.
    public init(
        id: UUID,
        toolName: String,
        arguments: [String: JSONValue],
        result: ToolResultPayload? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.timestamp = timestamp
    }
}

// MARK: - Citation (Wave 3A, review #5)

/// One grounded source backing an agent claim. Surfaced as a
/// verifiable chip on the chat row and lifted to the persistent
/// `ChatMessage.sources` set so the citation list survives across
/// runs and is queryable from the audit log.
///
/// **Id key.** `id` is the stable, URL-normalized identifier. For
/// the `research` tool (the only tool that produces citations today)
/// this is the source URL, normalized via
/// `TesseraResearchTool.normalizeURL` so trailing-slash variants
/// collapse to one citation. Tools that produce non-URL citations
/// (e.g. a local file path) synthesize a stable key from
/// `(tool, path)`.
///
/// **Label.** The visible text the chat row renders. For research
/// citations this is the page title; long titles are truncated by
/// the row, not here.
///
/// **Snippet.** A short excerpt of the source content. The row
/// shows it on chip-tap (or on expand). Empty when the source has
/// no body (e.g. a link without retrieved content).
///
/// **URL.** The route target. The row's tap handler calls the
/// existing receipts-coordinator / web-routing open path; the
/// `Citation` itself does not own the routing logic. Nil for
/// non-URL citations (local file path) -- the row uses `id` as
/// the tap target in that case.
///
/// **Range.** Optional inline-anchor range. Reserved for a future
/// "snip the source" affordance where the citation chip scrolls
/// the row's prose to the exact phrase the agent quoted. nil today
/// -- the chip routes to the source, not into the row.
public struct Citation: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let label: String
    public let snippet: String
    public let url: String?
    /// Optional inline-anchor range, stored as `(start, end)`
    /// UTF-16 offsets rather than `Range<String.Index>` (which is
    /// not `Codable`). The host row owns the host string and is
    /// the one that converts the offsets back to indices on read.
    /// nil = "no inline anchor". The custom `Codable` conformance
    /// below keeps the on-disk shape migration-safe: the four
    /// headline fields (id, label, snippet, url) plus an optional
    /// `range` block.
    public let range: RangeOffset?

    public init(
        id: String,
        label: String,
        snippet: String = "",
        url: String? = nil,
        range: RangeOffset? = nil
    ) {
        self.id = id
        self.label = label
        self.snippet = snippet
        self.url = url
        self.range = range
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, snippet, url, range
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.label = try c.decode(String.self, forKey: .label)
        self.snippet = try c.decode(String.self, forKey: .snippet)
        self.url = try c.decodeIfPresent(String.self, forKey: .url)
        self.range = try c.decodeIfPresent(RangeOffset.self, forKey: .range)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(snippet, forKey: .snippet)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(range, forKey: .range)
    }
}

/// Codable mirror of a `Range<String.Index>`. The offsets are
/// UTF-16 distances from the host string's `startIndex`; converting
/// back to `Range<String.Index>` requires the host string (handled
/// by the row, not the citation). nil offsets are equivalent to
/// nil range.
public struct RangeOffset: Codable, Sendable, Equatable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

/// Categorical agent confidence in a tool result. The Tian Pan 2026-04-12
/// trust-calibration split: the UI must distinguish "the agent was uncertain
/// and said so" from "the agent was confident and was wrong". Categorical
/// bands are more robust to model miscalibration than numeric percentages
/// (research: some LLMs exhibit expected calibration error of 0.726 with
/// 23% accuracy; see agent-ux-fatigue pattern-catalog.md "Confidence
/// Signal"). UI consumer: any surface that displays a `ToolResultPayload`
/// should render `.low` as a visible caveat chip.
public enum ConfidenceBand: String, Codable, Sendable, CaseIterable {
    case low
    case medium
    case high
}

/// Codable payload for a tool result stored in SwiftData.
///
/// `confidenceBand` is the categorical counterpart to the binary
/// `success` flag. A `.low` band with `success: true` is a "I did it but
/// I am not sure this is right" signal; `nil` means the tool produced
/// no uncertainty (deterministic reads, executor returns, or the agent
/// has not yet wired a per-tool confidence source). The field is set on
/// every emission: a non-nil band is a positive claim about the agent's
/// confidence, `nil` is the documented "no uncertainty available" path.
///
/// `sources` is the per-tool-call citation set (Wave 3A,
/// agent-ux-fatigue review #5). The `research` tool emits one
/// `Citation` per curated source; other tools that surface evidence
/// (e.g. a `read_file` over a doc with citations) may add to the list.
/// `[]` is the documented "no citations" path; non-empty is a positive
/// claim that the tool produced a cited answer. The field is additive
/// on top of the `confidenceBand` wave (2D): both are independent
/// optional claims and the UI can render them side-by-side.
public struct ToolResultPayload: Codable, Sendable {
    public let success: Bool
    public let output: String
    public let error: String?
    public let confidenceBand: ConfidenceBand?
    public let sources: [Citation]

    public init(
        success: Bool,
        output: String,
        error: String? = nil,
        confidenceBand: ConfidenceBand? = nil,
        sources: [Citation] = []
    ) {
        self.success = success
        self.output = output
        self.error = error
        self.confidenceBand = confidenceBand
        self.sources = sources
    }
}

@Model
public final class ChatMessage {
    public var role: ChatRole
    public var content: String
    public var toolCalls: [ToolCallRecord]
    public var timestamp: Date
    public var conversationID: UUID
    /// Which assistant persona produced this message in the dual-agent
    /// surface (Tessy vs Sky). nil for user/system/tool messages and for
    /// assistant messages from the single-agent Playground. Stored as the
    /// raw value so SwiftData migrations are additive (optional + default nil).
    public var speaker: String?
    /// The citation set backing this message (Wave 3A, review #5).
    /// Lifted from the tool-call provenance: every tool result that
    /// surfaces sources (e.g. `research`) contributes to the list. The
    /// field is additive on top of `speaker`; `[]` is the documented
    /// "no citations" path. A non-empty list is a positive claim that
    /// the agent's claim is grounded in verifiable evidence. The chat
    /// row renders the first 3 as chips and expands on tap (Wave 3A
    /// default), mirroring the audit-log HEAD chip's fieldCap
    /// discipline (review #5).
    public var sources: [Citation]

    public init(
        role: ChatRole,
        content: String,
        toolCalls: [ToolCallRecord] = [],
        conversationID: UUID = UUID(),
        speaker: String? = nil,
        sources: [Citation] = []
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.timestamp = Date()
        self.conversationID = conversationID
        self.speaker = speaker
        self.sources = sources
    }
}

@Model
public final class RunRecord {
    public var modelName: String
    public var runtime: TesseraRuntime
    public var configJSON: String
    public var metricsJSON: String
    public var timestamp: Date
    public var durationSeconds: Double
    public var status: RunStatus

    public init(
        modelName: String,
        runtime: TesseraRuntime,
        config: [String: JSONValue] = [:],
        metrics: [String: JSONValue] = [:],
        durationSeconds: Double = 0,
        status: RunStatus = .running
    ) {
        self.modelName = modelName
        self.runtime = runtime
        self.configJSON = (try? JSONEncoder().encode(config)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        self.metricsJSON = (try? JSONEncoder().encode(metrics)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        self.timestamp = Date()
        self.durationSeconds = durationSeconds
        self.status = status
    }

    public var config: [String: JSONValue] {
        guard let data = configJSON.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: JSONValue].self, from: data)) ?? [:]
    }

    public var metrics: [String: JSONValue] {
        guard let data = metricsJSON.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: JSONValue].self, from: data)) ?? [:]
    }
}

public enum RunStatus: String, Codable, Sendable {
    case running
    case completed
    case failed
    case cancelled
}
