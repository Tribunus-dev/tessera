import SwiftUI

// MARK: - SurfaceMetadataRow

/// A reusable metadata / status row shared across all surface detail views.
///
/// Renders each stat as a `.caption` pill (label · value). Shows a
/// small `ProgressView` in the trailing position while saving, and
/// renders `lastError` in red when non-nil.
public struct SurfaceMetadataRow: View {
    public let isSaving: Bool
    public let lastError: String?
    /// Each entry is rendered as "label · value".
    public let stats: [(label: String, value: String)]

    public init(
        isSaving: Bool,
        lastError: String?,
        stats: [(label: String, value: String)]
    ) {
        self.isSaving = isSaving
        self.lastError = lastError
        self.stats = stats
    }

    public var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                Text("\(stat.label) · \(stat.value)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSaving {
                ProgressView().controlSize(.small)
            }
            if let err = lastError {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
    }
}
