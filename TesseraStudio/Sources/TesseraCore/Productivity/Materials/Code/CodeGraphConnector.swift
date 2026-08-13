import Foundation

// MARK: - CodeGraphConnector

/// Wires the graph view to the Code surface. Clicking a
/// `code` node opens the file in the code editor.
public enum CodeGraphConnector {

    /// Install the open handler. Non-code nodes fall through.
    @MainActor
    public static func wire(
        _ graph: GraphViewModel,
        to code: CodeSurfaceViewModel
    ) {
        let previous = graph.openEntityHandler
        graph.openEntityHandler = { node in
            guard node.entityType == CodeFile.entityType else {
                previous?(node)
                return
            }
            code.openFile(id: node.id)
            previous?(node)
        }
    }

    /// Link a code file to another graph entity. Goes through
    /// ``CodeStore`` so the constitutional receipt is emitted.
    @discardableResult
    public static func link(
        fileID: UUID,
        to targetID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0,
        store: CodeStore
    ) async throws -> EntityLink? {
        try await store.link(fileID, to: targetID, linkType: linkType, weight: weight)
    }

    /// Link a code file directly through the data layer.
    @discardableResult
    public static func link(
        fileID: UUID,
        to targetID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0,
        dataLayer: TesseraDataLayer
    ) async throws -> EntityLink {
        try await dataLayer.linkEntities(sourceID: fileID, targetID: targetID, linkType: linkType, weight: weight)
    }

    /// A focused graph view anchored on one file's neighbourhood.
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
