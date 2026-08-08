import SwiftUI

/// Renders a tool call record within a chat message.
public struct ToolCallView: View {
    public let record: ToolCallRecord
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    public init(record: ToolCallRecord) {
        self.record = record
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header row
            Button(action: { withAnimation(reduceMotion ? nil : .spring(duration: 0.25)) { isExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.purple)
                        .accessibilityHidden(true)

                    Text(record.toolName)
                        .font(.system(.caption, design: .monospaced).bold())
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer()

                    statusIcon

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tertiary)
                        .contentTransition(.symbolEffect(.replace))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide \(record.toolName) details" : "Show \(record.toolName) details")
            .accessibilityHint(isExpanded ? "Collapses the tool call" : "Expands the tool call")
            .accessibilityAddTraits(.isButton)

            // Expanded details
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    // Arguments
                    if !record.arguments.isEmpty {
                        Text("Arguments")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        ForEach(record.arguments.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            HStack(alignment: .top, spacing: 4) {
                                Text(key)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(value.shortDescription)
                                    .font(.system(.caption2, design: .monospaced))
                            }
                        }
                    }

                    // Result
                    if let result = record.result {
                        Divider()
                        HStack(spacing: 4) {
                            Image(systemName: result.success ? "checkmark.circle" : "xmark.circle")
                                .font(.caption2)
                                .symbolRenderingMode(.hierarchical)
                                .contentTransition(.symbolEffect(.replace))
                                .foregroundStyle(result.success ? .green : .red)
                            Text(result.success ? "Success" : "Failed")
                                .font(.caption2.bold())
                                .lineLimit(1)
                        }
                        if !result.output.isEmpty {
                            Text(result.output)
                                .font(.system(.caption2, design: .monospaced))
                                .lineLimit(10)
                                .truncationMode(.tail)
                                .textSelection(.enabled)
                        }
                        if let error = result.error {
                            Text(error)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.red)
                                .lineLimit(4)
                                .truncationMode(.tail)
                        }
                    } else {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Running...")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Timestamp
                    Text(record.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(8)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(8)
        .background(.purple.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusIcon: some View {
        if let result = record.result {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption)
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(result.success ? .green : .red)
        } else {
            ProgressView()
                .controlSize(.mini)
        }
    }
}
