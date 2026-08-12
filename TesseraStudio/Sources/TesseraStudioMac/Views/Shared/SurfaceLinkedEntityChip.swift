import SwiftUI
import TesseraCore

// MARK: - SurfaceLinkedEntityChip

/// A minimal pill chip for displaying one linked entity in a surface
/// detail pane. Created as the Phase 12 Wave 1 Agent 1 component.
///
/// Displays an SF Symbol icon, the entity's label, and an optional
/// type badge. Compact enough to appear inline in metadata rows or
/// as a horizontal scroll in a linked-entities section.
public struct SurfaceLinkedEntityChip: View {
    public let link: EntityLink
    public let label: String
    public var onTap: (() -> Void)?

    /// Convenience init from just a target entity ID (used by Doc/Sheet/Slide
    /// detail views that only have the id, not the full EntityLink).
    public init(id: UUID) {
        self.link = EntityLink(
            id: id,
            sourceID: id,
            targetID: id,
            linkType: "",
            weight: 1.0
        )
        self.label = String(id.uuidString.prefix(8))
        self.onTap = nil
    }

    public init(link: EntityLink, label: String, onTap: (() -> Void)? = nil) {
        self.link = link
        self.label = label
        self.onTap = onTap
    }

    public var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .font(.caption2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconColor)
                Text(label)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !link.linkType.isEmpty {
                    Text(link.linkType)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.08), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Linked \(link.linkType.isEmpty ? "entity" : link.linkType): \(label)")
        .accessibilityHint("Double-tap to navigate to this linked material")
    }

    private var iconName: String {
        switch link.linkType {
        case CalendarLinkType.attendeeOf.rawValue: return "person.crop.circle"
        case CalendarLinkType.prepDocument.rawValue: return "doc.text"
        case CalendarLinkType.prepTask.rawValue: return "checkmark.square"
        case CalendarLinkType.reminderFor.rawValue: return "bell"
        // Contacts and Reminders surfaces use plain string link types.
        default: return "link"
        }
    }

    private var iconColor: Color {
        switch link.linkType {
        case CalendarLinkType.attendeeOf.rawValue: return .accentColor
        case CalendarLinkType.prepDocument.rawValue: return .purple
        case CalendarLinkType.prepTask.rawValue: return .green
        case CalendarLinkType.reminderFor.rawValue: return .orange
        default: return .secondary
        }
    }
}
