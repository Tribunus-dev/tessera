import Foundation

/// UI disclosure level for the Intelligence view. `standard` hides the
/// ML-researcher controls behind ``AdvancedSection``; `advanced` reveals them.
///
/// Kept deliberately separate from ``TesseraPermissionProfile`` (which gates
/// agent autonomy) — interface complexity is not agent autonomy, and
/// conflating them would confuse users. Honored only by the Intelligence view;
/// productivity surfaces are unaffected.
public enum InterfaceLevel: String, CaseIterable, Sendable, Identifiable {
    case standard
    case advanced

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: "Standard"
        case .advanced: "Advanced"
        }
    }
}
