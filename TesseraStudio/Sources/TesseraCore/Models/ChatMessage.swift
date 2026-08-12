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
public struct ToolResultPayload: Codable, Sendable {
    public let success: Bool
    public let output: String
    public let error: String?
    public let confidenceBand: ConfidenceBand?

    public init(
        success: Bool,
        output: String,
        error: String? = nil,
        confidenceBand: ConfidenceBand? = nil
    ) {
        self.success = success
        self.output = output
        self.error = error
        self.confidenceBand = confidenceBand
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

    public init(
        role: ChatRole,
        content: String,
        toolCalls: [ToolCallRecord] = [],
        conversationID: UUID = UUID(),
        speaker: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.timestamp = Date()
        self.conversationID = conversationID
        self.speaker = speaker
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
