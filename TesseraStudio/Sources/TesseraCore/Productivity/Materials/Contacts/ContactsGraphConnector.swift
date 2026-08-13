import Foundation

// MARK: - ContactsGraphConnector

/// Wires the graph view to the Contacts surface. Clicking
/// a `contact` node opens the contact detail.
public enum ContactsGraphConnector {

    /// Install the open handler. Non-contact nodes fall through.
    @MainActor
    public static func wire(
        _ graph: GraphViewModel,
        to contacts: ContactsViewModel
    ) {
        let previous = graph.openEntityHandler
        graph.openEntityHandler = { node in
            guard node.entityType == Contact.entityType else {
                previous?(node)
                return
            }
            contacts.select(node.id)
            previous?(node)
        }
    }

    /// Link a contact to another graph entity. Goes through
    /// ``ContactStore`` so the constitutional receipt is emitted.
    @discardableResult
    public static func link(
        contactID: UUID,
        to targetID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0,
        store: ContactStore
    ) async throws -> EntityLink {
        try await store.linkContact(contactID, to: targetID, linkType: linkType, weight: weight)
    }

    /// Link a contact directly through the data layer.
    @discardableResult
    public static func link(
        contactID: UUID,
        to targetID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0,
        dataLayer: TesseraDataLayer
    ) async throws -> EntityLink {
        try await dataLayer.linkEntities(sourceID: contactID, targetID: targetID, linkType: linkType, weight: weight)
    }

    /// A focused graph view anchored on one contact's neighbourhood.
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

// MARK: - ContactsViewModel (minimal protocol)

/// The subset of the contacts list view model that
/// ``ContactsGraphConnector`` needs.
public protocol ContactsViewModel: AnyObject {
    func select(_ id: UUID)
}
