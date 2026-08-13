import Foundation

// MARK: - NotesGraphConnector

/// Wires the graph view to the Notes surface. Mirrors
/// `CalendarGraphConnector` / `DocsGraphConnector`.
public enum NotesGraphConnector {

    /// Install the open handler. Clicking a `note` node opens
    /// the note in the Notes surface. Non-note nodes fall
    /// through to the previous handler (chaining).
    @MainActor
    public static func wire(
        _ graph: GraphViewModel,
        to notes: NotesViewModel
    ) {
        let previous = graph.openEntityHandler
        graph.openEntityHandler = { node in
            guard node.entityType == Note.entityType else {
                previous?(node)
                return
            }
            notes.select(node.id)
            previous?(node)
        }
    }

    /// Link a note to another graph entity. Goes through
    /// ``NoteStore`` so the constitutional receipt is
    /// emitted.
    @discardableResult
    public static func link(
        noteID: UUID,
        to targetID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0,
        store: NoteStore
    ) async throws -> EntityLink {
        try await store.link(noteID: noteID, to: targetID, linkType: linkType, weight: weight)
    }

    /// Link a note directly through the data layer (bypasses
    /// the receipt that ``NoteStore`` emits; prefer the
    /// store variant above).
    @discardableResult
    public static func link(
        noteID: UUID,
        to targetID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0,
        dataLayer: TesseraDataLayer
    ) async throws -> EntityLink {
        try await dataLayer.linkEntities(sourceID: noteID, targetID: targetID, linkType: linkType, weight: weight)
    }

    /// A focused graph view anchored on one note's neighbourhood.
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
