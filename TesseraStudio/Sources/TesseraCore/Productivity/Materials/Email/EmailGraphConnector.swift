import Foundation

// MARK: - EmailGraphConnector

/// Wires the graph view to the Email surface. Clicking an
/// `email` node opens the email thread in the Email surface.
public enum EmailGraphConnector {

    /// Install the open handler. Non-email nodes fall through.
    @MainActor
    public static func wire(
        _ graph: GraphViewModel,
        to email: EmailListViewModel
    ) {
        let previous = graph.openEntityHandler
        graph.openEntityHandler = { node in
            guard node.entityType == EmailMessage.entityType else {
                previous?(node)
                return
            }
            email.selectEmail(node.id)
            previous?(node)
        }
    }

    /// Link an email to another graph entity. Goes through
    /// ``EmailStore`` so the constitutional receipt is emitted.
    @discardableResult
    public static func link(
        emailID: UUID,
        to targetID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0,
        store: EmailStore
    ) async throws -> EntityLink {
        try await store.link(emailID: emailID, to: targetID, linkType: linkType, weight: weight)
    }

    /// Link an email directly through the data layer.
    @discardableResult
    public static func link(
        emailID: UUID,
        to targetID: UUID,
        linkType: String = "related_to",
        weight: Float = 1.0,
        dataLayer: TesseraDataLayer
    ) async throws -> EntityLink {
        try await dataLayer.linkEntities(sourceID: emailID, targetID: targetID, linkType: linkType, weight: weight)
    }
}

// MARK: - EmailListViewModel (minimal protocol)

/// The subset of the email list view model that
/// ``EmailGraphConnector`` needs. Declared here so
/// the connector is self-contained; the real
/// ``EmailListViewModel`` conforms to it.
public protocol EmailListViewModel: AnyObject {
    func selectEmail(_ id: UUID)
}

extension EmailListViewModel {
    /// Default no-op so connectors are safe to call
    /// against any EmailListViewModel implementation.
    func selectEmail(_ id: UUID) {}
}
