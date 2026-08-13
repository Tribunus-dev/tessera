import SwiftUI

// MARK: - Color(hex:)

/// Parse a `#RRGGBB` or `#RRGGBBAA` string into a SwiftUI `Color`.
///
/// Module-internal rather than file-private: agent cursors and sheet
/// cell fills both persist colours as hex strings, and a second copy of
/// this would be one more place for the two to drift apart.
///
/// Returns nil for anything that is not 6 or 8 hex digits, so a
/// malformed stored colour falls back to the default rather than
/// rendering as black.
extension Color {
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&value) else { return nil }
        let r, g, b, a: Double
        if s.count == 6 {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        } else {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        }
        self = Color(red: r, green: g, blue: b, opacity: a)
    }
}
