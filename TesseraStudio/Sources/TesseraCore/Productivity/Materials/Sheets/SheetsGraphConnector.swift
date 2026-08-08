import Foundation

// MARK: - SheetsGraphConnector

/// Wires the graph view to the Sheets surface. Mirrors
/// `CalendarGraphConnector` / `DocsGraphConnector`.

public enum SheetsGraphConnector {

    @MainActor
    public static func wire(
        _ graph: GraphViewModel,
        to sheets: SheetsViewModel
    ) {
        let previous = graph.openEntityHandler
        graph.openEntityHandler = { node in
            if node.entityType == Sheet.entityType, node.subtype == Sheet.subtype {
                sheets.select(node.id)
                return
            }
            previous?(node)
        }
    }

    @discardableResult
    public static func link(
        sheetID: UUID,
        to targetID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0,
        store: SheetStore
    ) async throws -> EntityLink {
        try await store.link(sheetID: sheetID, to: targetID, linkType: linkType, weight: weight)
    }

    @discardableResult
    public static func link(
        sheetID: UUID,
        to targetID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0,
        dataLayer: TesseraDataLayer
    ) async throws -> EntityLink {
        try await dataLayer.linkEntities(sourceID: sheetID, targetID: targetID, linkType: linkType, weight: weight)
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
