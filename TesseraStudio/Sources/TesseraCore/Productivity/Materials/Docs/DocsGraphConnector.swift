import Foundation

// MARK: - DocsGraphConnector

/// Wires the graph view to the Docs surface. The graph view already
/// renders `document` / `doc` nodes (blue, doc.text); this connector
/// supplies the click-to-open path and the thin linking helpers that
/// go through `TesseraDataLayer` / `DocStore` -> `entity_links`.

public enum DocsGraphConnector {

    @MainActor
    public static func wire(
        _ graph: GraphViewModel,
        to docs: DocsViewModel
    ) {
        let previous = graph.openEntityHandler
        graph.openEntityHandler = { node in
            if node.entityType == Doc.entityType, node.subtype == Doc.subtype {
                docs.select(node.id)
                return
            }
            previous?(node)
        }
    }

    @discardableResult
    public static func link(
        docID: UUID,
        to targetID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0,
        store: DocStore
    ) async throws -> EntityLink {
        try await store.link(docID: docID, to: targetID, linkType: linkType, weight: weight)
    }

    @discardableResult
    public static func link(
        docID: UUID,
        to targetID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0,
        dataLayer: TesseraDataLayer
    ) async throws -> EntityLink {
        try await dataLayer.linkEntities(sourceID: docID, targetID: targetID, linkType: linkType, weight: weight)
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
