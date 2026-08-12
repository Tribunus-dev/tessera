#if canImport(AppKit)
import AppKit
import Foundation
import TesseraCore

/// App-wide notifications for the "Plea the Fifth" feature. Centralised
/// so the settings view (which posts) and the menu item (which listens)
/// agree on the contract without a direct dependency.
extension Notification.Name {
    /// Posted by the macOS Settings view when the user clicks
    /// "View last wipe report...". The PleadTheFifthMenuItem (which
    /// owns the actual report window) observes this and presents it.
    static let openLastWipeReport = Notification.Name("com.tessera.studio.openLastWipeReport")
}

/// Posts the open-last-wipe-report notification through the shared
/// ``TesseraNotificationBudget`` so user-initiated report-window
/// requests count against the same per-UTC-day cap as the workflow
/// and training notifiers (review #3 of the agent-ux-fatigue audit).
/// Returns true when the notification was dispatched, false when the
/// budget's cap is already spent (the menu item can then render the
/// "budget exhausted" badge instead of opening a blank report).
public enum PleadTheFifthNotificationPoster {
    public static func requestOpenReport() async -> Bool {
        let allowed = await TesseraNotificationBudget.shared.tryPost(
            category: .wipeReport,
            title: "Wipe report",
            body: "Open the last wipe report window."
        )
        guard allowed else { return false }
        await MainActor.run {
            NotificationCenter.default.post(name: .openLastWipeReport, object: nil)
        }
        return true
    }
}
#endif
