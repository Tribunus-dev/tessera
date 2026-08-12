import SwiftUI

// MARK: - SurfaceLinkedEntityChip

/// A compact chip showing a linked entity's UUID prefix and optional icon.
///
/// Replaces `DocLinkedEntityChip`, `SheetLinkedEntityChip`,
/// `SlideLinkedEntityChip`, and `LinkedEntityChip` across all
/// surface detail views.
public struct SurfaceLinkedEntityChip: View {
    public let id: UUID
    /// Optional SF Symbol name. Defaults to `"link"` when nil.
    public var icon: String? = nil
    /// Optional click handler. When nil the chip is read-only
    /// (matching the detail-view pattern). When provided the
    /// chip wraps a `Button`.
    public var onClick: (() -> Void)? = nil

    public init(id: UUID, icon: String? = nil, onClick: (() -> Void)? = nil) {
        self.id = id
        self.icon = icon
        self.onClick = onClick
    }

    private var chipContent: some View {
        HStack(spacing: 4) {
            Image(systemName: icon ?? "link")
                .symbolRenderingMode(.hierarchical)
            Text(String(id.uuidString.prefix(8)) + "…")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.quaternary))
    }

    public var body: some View {
        if let onClick {
            Button(action: onClick) {
                chipContent
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        } else {
            chipContent
                .foregroundStyle(.secondary)
        }
    }
}
