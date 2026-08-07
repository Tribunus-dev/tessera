import Foundation

// MARK: - SlidesGraphConnector

/// Wires the graph view to the Slides surface. Mirrors
/// `CalendarGraphConnector` / `DocsGraphConnector`.

public enum SlidesGraphConnector {

    @MainActor
    public static func wire(
        _ graph: GraphViewModel,
        to slides: SlidesViewModel
    ) {
        let previous = graph.openEntityHandler
        graph.openEntityHandler = { node in
            if node.entityType == SlideDeck.entityType, node.subtype == SlideDeck.subtype {
                slides.select(node.id)
                return
            }
            previous?(node)
        }
    }

    @discardableResult
    public static func link(
        deckID: UUID,
        to targetID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0,
        store: SlideStore
    ) async throws -> EntityLink {
        try await store.link(deckID: deckID, to: targetID, linkType: linkType, weight: weight)
    }

    @discardableResult
    public static func link(
        deckID: UUID,
        to targetID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0,
        dataLayer: TesseraDataLayer
    ) async throws -> EntityLink {
        try await dataLayer.linkEntities(sourceID: deckID, targetID: targetID, linkType: linkType, weight: weight)
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
