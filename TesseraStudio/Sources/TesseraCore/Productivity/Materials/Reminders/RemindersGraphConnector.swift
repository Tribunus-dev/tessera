import Foundation

// MARK: - RemindersGraphConnector

/// Wires the graph view to the Reminders surface. Clicking
/// a `reminder` node opens the reminder detail.
public enum RemindersGraphConnector {

    /// Install the open handler. Non-reminder nodes fall through.
    @MainActor
    public static func wire(
        _ graph: GraphViewModel,
        to reminders: ReminderListViewModel
    ) {
        let previous = graph.openEntityHandler
        graph.openEntityHandler = { node in
            guard node.entityType == Reminder.entityType else {
                previous?(node)
                return
            }
            reminders.selectedID = node.id
            previous?(node)
        }
    }

    /// Link a reminder to another graph entity. Goes through
    /// ``ReminderStore`` so the constitutional receipt is emitted.
    @discardableResult
    public static func link(
        reminderID: UUID,
        to targetID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0,
        store: ReminderStore
    ) async throws -> EntityLink {
        try await store.linkReminder(reminderID, to: targetID, linkType: linkType, weight: weight)
    }

    /// Link a reminder directly through the data layer.
    @discardableResult
    public static func link(
        reminderID: UUID,
        to targetID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0,
        dataLayer: TesseraDataLayer
    ) async throws -> EntityLink {
        try await dataLayer.linkEntities(sourceID: reminderID, targetID: targetID, linkType: linkType, weight: weight)
    }

    /// A focused graph view anchored on one reminder's neighbourhood.
    @MainActor
    public static func graphViewModel(
        showLinkedTo id: UUID,
        store: GraphStore
    ) -> GraphViewModel {
        let vm = GraphViewModel(store: store)
        vm.anchorSet = [id]
        vm.radius = .oneHop
        return vm
    }
}
