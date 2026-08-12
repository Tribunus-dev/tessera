import Foundation

// MARK: - ExtractedContext

/// Structured context extracted from an email body by Granite.
/// Stored as JSON in the email body JSON under the `"_context"` key.
public struct ExtractedEmailContext: Codable, Sendable, Equatable {
    /// Action items mentioned in the email.
    public var actionItems: [ActionItem]
    /// Explicit deadlines.
    public var deadlines: [Deadline]
    /// Project names and ticket IDs.
    public var projects: [ProjectReference]
    /// One of: positive, neutral, negative, mixed, or unknown.
    public var sentiment: String
    /// Key decisions made or stated.
    public var keyDecisions: [String]
    /// The raw LLM response, kept for traceability.
    public var rawResponse: String

    public struct ActionItem: Codable, Sendable, Equatable {
        public var who: String?
        public var what: String
        public var when: String?
    }

    public struct Deadline: Codable, Sendable, Equatable {
        public var description: String
        public var dateISO: String?
    }

    public struct ProjectReference: Codable, Sendable, Equatable {
        public var name: String
        public var ticketID: String?
    }

    public init(
        actionItems: [ActionItem] = [],
        deadlines: [Deadline] = [],
        projects: [ProjectReference] = [],
        sentiment: String = "unknown",
        keyDecisions: [String] = [],
        rawResponse: String = ""
    ) {
        self.actionItems = actionItems
        self.deadlines = deadlines
        self.projects = projects
        self.sentiment = sentiment
        self.keyDecisions = keyDecisions
        self.rawResponse = rawResponse
    }
}

// MARK: - EmailContextExtractor

/// Runs Granite locally on email bodies to extract structured personal context:
/// action items, deadlines, project references, sentiment, and key decisions.
/// The extracted ``ExtractedEmailContext`` is stored back in the email body JSON
/// under the `"_context"` key.
///
/// **Privacy guarantee.** The LLM runs on-device. No email content leaves the
/// machine. ``EmailStore`` is unaware of the context structure — it stores
/// and retrieves the body JSON. Incremental re-extraction runs on changed
/// emails only.
///
/// **Storage budget.** ~500 bytes per email. For 10k emails: ~5 MB added
/// to the body JSONB column.
public actor EmailContextExtractor {

    // MARK: - Error

    public enum ExtractorError: Error, Sendable, Equatable {
        case llmUnavailable
        case extractionFailed(String)
        case parseFailed(String)
        case emailNotFound(UUID)
    }

    // MARK: - State

    /// The LLM provider. Must be a local provider (LlamaLLMProvider) to satisfy
    /// the on-device privacy guarantee.
    private let llmProvider: any LLMProvider
    private let emailStore: EmailStore

    // MARK: - Init

    public init(llmProvider: any LLMProvider, emailStore: EmailStore) {
        self.llmProvider = llmProvider
        self.emailStore = emailStore
    }

    // MARK: - Extract

    /// Extract context from a single email.
    public func extract(for emailID: UUID) async throws -> ExtractedEmailContext {
        guard let email = try await emailStore.get(id: emailID) else {
            throw ExtractorError.emailNotFound(emailID)
        }

        let body = extractPlainText(from: email.bodyPlain)
        guard !body.isEmpty else {
            return ExtractedEmailContext()
        }

        let prompt = buildPrompt(body: body)
        let system = extractionSystemPrompt()

        do {
            let response = try await llmProvider.complete(
                system: system,
                messages: [LLMMessage(role: "user", content: prompt)],
                tools: []
            )

            let rawText = response.content
            let context = try parseContext(from: rawText)
            return context

        } catch {
            throw ExtractorError.extractionFailed(String(describing: error))
        }
    }

    /// Batch-extract context for a list of email IDs. Runs sequentially
    /// to avoid flooding the LLM.
    public func extractBatch(emailIDs: [UUID]) async -> [Result<UUID, Error>] {
        var results: [Result<UUID, Error>] = []
        for id in emailIDs {
            do {
                let context = try await extract(for: id)
                try await writeContext(context, for: id)
                results.append(.success(id))
            } catch {
                results.append(.failure(error))
            }
        }
        return results
    }

    // MARK: - Write back

    /// Write the extracted context into the email body JSON under `"_context"`.
    /// Re-encodes the full EmailMessage since bodyPlain holds the JSON string.
    private func writeContext(_ context: ExtractedEmailContext, for emailID: UUID) async throws {
        guard var email = try await emailStore.get(id: emailID) else {
            throw ExtractorError.emailNotFound(emailID)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let contextData = try encoder.encode(context)

        // Parse existing body JSON stored in bodyPlain.
        var bodyJSON: [String: Any] = [:]
        if let bodyData = email.bodyPlain.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            bodyJSON = parsed
        }

        let contextJSON = try JSONSerialization.jsonObject(with: contextData) as? [String: Any] ?? [:]
        bodyJSON["_context"] = contextJSON

        let updatedBodyData = try JSONSerialization.data(withJSONObject: bodyJSON)
        let updatedBodyString = String(data: updatedBodyData, encoding: .utf8) ?? email.bodyPlain

        // Re-encode the full EmailMessage with updated body.
        email.bodyPlain = updatedBodyString
        _ = try await emailStore.upsert(email)
    }

    // MARK: - Prompt construction

    private func buildPrompt(body: String) -> String {
        """
        Extract structured information from the following email body.
        Respond ONLY with a JSON object matching this schema:
        {
          "actionItems": [{"who": "...", "what": "...", "when": "..."}],
          "deadlines": [{"description": "...", "dateISO": "..."}],
          "projects": [{"name": "...", "ticketID": "..."}],
          "sentiment": "positive|neutral|negative|mixed|unknown",
          "keyDecisions": ["..."],
          "rawResponse": "..."
        }

        Rules:
        - Extract action items only if there is an explicit assignment ("you should...", "can you...", "please").
        - Parse date references to ISO 8601 (YYYY-MM-DD) where possible.
        - Extract ticket IDs (e.g. JIRA-123, GH-456, PROJ-789).
        - sentiment: positive (requests/thanks), negative (complaints/cancellations), neutral (updates), mixed, unknown.
        - keyDecisions: only explicit conclusions ("we decided...", "the plan is...").

        Email body:
        \(body)
        """
    }

    private func extractionSystemPrompt() -> String {
        """
        You are a precise email analysis assistant. You extract action items,
        deadlines, project references, sentiment, and key decisions from emails.
        You respond only with valid JSON matching the requested schema.
        Never include explanation, preamble, or commentary — only the JSON object.
        """
    }

    // MARK: - Parse

    private func parseContext(from rawText: String) throws -> ExtractedEmailContext {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences if present.
        let jsonText: String
        if trimmed.hasPrefix("```json") {
            jsonText = String(trimmed.dropFirst(7))
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if trimmed.hasPrefix("```") {
            jsonText = String(trimmed.dropFirst(3))
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            jsonText = trimmed
        }

        guard let data = jsonText.data(using: .utf8) else {
            throw ExtractorError.parseFailed("Cannot encode response text")
        }

        let decoder = JSONDecoder()
        do {
            var context = try decoder.decode(ExtractedEmailContext.self, from: data)
            context.rawResponse = rawText
            return context
        } catch {
            throw ExtractorError.parseFailed("JSON parse failed: \(error)")
        }
    }

    // MARK: - Plain text extraction

    /// Strip HTML tags and decode entities from an email body to get plain text.
    private func extractPlainText(from body: String) -> String {
        // Remove HTML tags.
        var text = body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode common HTML entities.
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        // Collapse whitespace.
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
