import SwiftUI

/// Renders a single chat message as a bubble. Assistant content is rendered
/// as rich Markdown; user content stays plain text. In the dual-agent surface
/// the optional `speaker` drives the label, tint, and avatar glyph so Tessy
/// and Sky read as distinct participants.
public struct ChatBubbleView: View {
    public let role: ChatRole
    public let content: String
    public let toolCalls: [ToolCallRecord]
    public let isStreaming: Bool
    public let speaker: AgentPersona?

    public init(message: ChatMessage) {
        self.role = message.role
        self.content = message.content
        self.toolCalls = message.toolCalls
        self.isStreaming = false
        self.speaker = message.speaker.flatMap { AgentPersona(rawValue: $0) }
    }

    public init(role: ChatRole, content: String, isStreaming: Bool = false) {
        self.role = role
        self.content = content
        self.toolCalls = []
        self.isStreaming = isStreaming
        self.speaker = nil
    }

    public init(role: ChatRole, content: String, isStreaming: Bool = false, speaker: AgentPersona?) {
        self.role = role
        self.content = content
        self.toolCalls = []
        self.isStreaming = isStreaming
        self.speaker = speaker
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if role == .user { Spacer(minLength: 60) }

            // Avatar glyph for a named persona (Tessy/Sky). Plain bubbles
            // (single-agent Playground, system, tool) get no avatar.
            if let speaker, role == .assistant {
                Image(systemName: speaker.symbolName)
                    .foregroundStyle(speaker.tint)
                    .font(.caption)
                    .frame(width: 18, height: 18)
                    .background(speaker.tint.opacity(0.15), in: Circle())
                    .accessibilityHidden(true)
                    .padding(.top, 2)
            }

            VStack(alignment: role == .user ? .trailing : .leading, spacing: 6) {
                // Role / persona label
                Text(roleLabel)
                    .font(.caption2.bold())
                    .foregroundStyle(speaker?.tint ?? .secondary)

                // Message content
                if !content.isEmpty {
                    contentBody
                        .padding(10)
                        .background(bubbleColor, in: RoundedRectangle(cornerRadius: 12))
                }

                // Tool calls
                ForEach(toolCalls) { call in
                    ToolCallView(record: call)
                }

                // Streaming indicator
                if isStreaming {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Generating...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if role != .user { Spacer(minLength: 60) }
        }
        // VoiceOver reads the bubble as one element: the role
        // label followed by the message content, instead of
        // stopping on the caption-sized role text separately.
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var contentBody: some View {
        switch role {
        case .assistant, .system:
            MarkdownRenderer(content)
                .textSelection(.enabled)
        case .user, .tool:
            Text(content)
                .textSelection(.enabled)
        }
    }

    private var roleLabel: String {
        if let speaker {
            return speaker.displayName
        }
        switch role {
        case .user: return "You"
        case .assistant: return "Tessera Agent"
        case .system: return "System"
        case .tool: return "Tool"
        }
    }

    private var bubbleColor: Color {
        if let speaker {
            return speaker.tint.opacity(0.12)
        }
        switch role {
        case .user: return .blue.opacity(0.15)
        case .assistant: return Color(.quaternaryLabelColor).opacity(0.18)
        case .system: return .yellow.opacity(0.1)
        case .tool: return .green.opacity(0.1)
        }
    }
}
