import SwiftUI

// MARK: - SurfaceTagBar

/// A reusable tag bar shared across all surface detail views.
///
/// Each tag renders as a `#tagname ×` chip button (removes on click).
/// An inline `TextField("Add tag…", …)` handles new tag entry.
public struct SurfaceTagBar: View {
    public let tags: [String]
    public var draftTag: Binding<String>
    public let onRemove: (String) -> Void
    public let onAdd: () -> Void

    public init(
        tags: [String],
        draftTag: Binding<String>,
        onRemove: @escaping (String) -> Void,
        onAdd: @escaping () -> Void
    ) {
        self.tags = tags
        self.draftTag = draftTag
        self.onRemove = onRemove
        self.onAdd = onAdd
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Button {
                    onRemove(tag)
                } label: {
                    HStack(spacing: 4) {
                        Text("#\(tag)")
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.accentColor.opacity(0.15))
                    )
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            TextField("Add tag…", text: draftTag, onCommit: onAdd)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 160)
        }
    }
}
