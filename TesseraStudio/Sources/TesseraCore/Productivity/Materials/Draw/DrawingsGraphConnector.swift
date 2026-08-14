import Foundation

// MARK: - DrawingsGraphConnector

/// Wires the graph view to the Draw surface: the click-to-open path
/// and the thin linking helpers that go through `TesseraDataLayer` /
/// `DrawingStore` -> `entity_links`. Mirrors `DocsGraphConnector`/
/// `SlidesGraphConnector`'s shape exactly.
public enum DrawingsGraphConnector {

    @MainActor
    public static func wire(
        _ graph: GraphViewModel,
        to drawings: DrawingsViewModel
    ) {
        let previous = graph.openEntityHandler
        graph.openEntityHandler = { node in
            if node.entityType == Drawing.entityType, node.subtype == Drawing.subtype {
                drawings.select(node.id)
                return
            }
            previous?(node)
        }
    }

    @discardableResult
    public static func link(
        drawingID: UUID,
        to targetID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0,
        store: DrawingStore
    ) async throws -> EntityLink {
        try await store.link(drawingID: drawingID, to: targetID, linkType: linkType, weight: weight)
    }

    @discardableResult
    public static func link(
        drawingID: UUID,
        to targetID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0,
        dataLayer: TesseraDataLayer
    ) async throws -> EntityLink {
        try await dataLayer.linkEntities(sourceID: drawingID, targetID: targetID, linkType: linkType, weight: weight)
    }

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
