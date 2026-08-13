import Foundation

// MARK: - TasksGraphConnector

/// Wires the graph view to the Tasks surface. Clicking a
/// `task` node opens the task in the Tasks surface.
public enum TasksGraphConnector {

    /// Install the open handler. Non-task nodes fall through.
    @MainActor
    public static func wire(
        _ graph: GraphViewModel,
        to tasks: ProductivityTaskListViewModel
    ) {
        let previous = graph.openEntityHandler
        graph.openEntityHandler = { node in
            guard node.entityType == ProductivityTask.entityType else {
                previous?(node)
                return
            }
            tasks.select(node.id)
            previous?(node)
        }
    }

    /// Link a task to another graph entity. Goes through
    /// ``ProductivityTaskStore`` so the constitutional
    /// receipt is emitted.
    @discardableResult
    public static func link(
        taskID: UUID,
        to targetID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0,
        store: ProductivityTaskStore
    ) async throws -> EntityLink {
        try await store.linkTask(taskID, to: targetID, linkType: linkType, weight: weight)
    }

    /// Link a task directly through the data layer.
    @discardableResult
    public static func link(
        taskID: UUID,
        to targetID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0,
        dataLayer: TesseraDataLayer
    ) async throws -> EntityLink {
        try await dataLayer.linkEntities(sourceID: taskID, targetID: targetID, linkType: linkType, weight: weight)
    }

    /// A focused graph view anchored on one task's neighbourhood.
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

// MARK: - ProductivityTaskListViewModel (minimal protocol)

/// The subset of the task list view model that
/// ``TasksGraphConnector`` needs.
public protocol ProductivityTaskListViewModel: AnyObject {
    func select(_ id: UUID)
}
