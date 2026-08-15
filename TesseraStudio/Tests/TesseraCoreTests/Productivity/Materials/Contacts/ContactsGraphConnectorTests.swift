import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Contacts/ContactsGraphConnector.swift
// doc comments ("Wires the graph view to the Contacts surface. Clicking
// a contact node opens the contact detail" + "Non-contact nodes fall
// through"). This is the Materials/Contacts/ file (the graph-wiring
// connector), distinct from the top-level Contacts/ engine covered in
// Tests/TesseraCoreTests/Productivity/Contacts/ per this cluster's
// ownership note.
//
// `wire(_:to:)`'s routing logic needs no data layer I/O at all (it only
// installs a closure), so this file is fully ungated.

@MainActor
final class ContactsGraphConnectorTests: DoctrineTestCase {

    /// Records every id the connector's installed handler routed to
    /// `select(_:)`, satisfying the minimal `ContactsViewModel` protocol.
    private final class RecordingContactsViewModel: ContactsViewModel {
        var selectedIDs: [UUID] = []
        func select(_ id: UUID) { selectedIDs.append(id) }
    }

    private func makeGraphViewModel() -> GraphViewModel {
        GraphViewModel(store: GraphStore(dataLayer: TesseraDataLayer()))
    }

    private func makeNode(entityType: String, id: UUID = UUID()) -> GraphNode {
        GraphNode(id: id, entityType: entityType, label: "n", importance: 0, updatedAt: Date())
    }

    func testWireRoutesAContactNodeToContactsSelect() {
        let graph = makeGraphViewModel()
        let contacts = RecordingContactsViewModel()
        ContactsGraphConnector.wire(graph, to: contacts)

        let contactNode = makeNode(entityType: Contact.entityType)
        graph.openEntityHandler?(contactNode)

        XCTAssertEqual(contacts.selectedIDs, [contactNode.id])
    }

    func testWireDoesNotRouteANonContactNodeToContactsSelect() {
        let graph = makeGraphViewModel()
        let contacts = RecordingContactsViewModel()
        ContactsGraphConnector.wire(graph, to: contacts)

        let taskNode = makeNode(entityType: "task")
        graph.openEntityHandler?(taskNode)

        XCTAssertEqual(contacts.selectedIDs, [])
    }

    func testWirePreservesThePreviouslyInstalledHandlerForEveryNode() {
        let graph = makeGraphViewModel()
        var previouslyCalledWith: [UUID] = []
        graph.openEntityHandler = { node in previouslyCalledWith.append(node.id) }

        let contacts = RecordingContactsViewModel()
        ContactsGraphConnector.wire(graph, to: contacts)

        let contactNode = makeNode(entityType: Contact.entityType)
        let taskNode = makeNode(entityType: "task")
        graph.openEntityHandler?(contactNode)
        graph.openEntityHandler?(taskNode)

        // The doc comment says "Non-contact nodes fall through" -- the
        // previous handler must still see BOTH nodes (contact routing is
        // additive, not a replacement of the existing chain).
        XCTAssertEqual(previouslyCalledWith, [contactNode.id, taskNode.id])
        XCTAssertEqual(contacts.selectedIDs, [contactNode.id])
    }

    func testGraphViewModelShowLinkedToAnchorsOnTheGivenIDWithOneHopRadius() {
        let store = GraphStore(dataLayer: TesseraDataLayer())
        let anchorID = UUID()

        let vm = ContactsGraphConnector.graphViewModel(showLinkedTo: anchorID, store: store)

        XCTAssertEqual(vm.anchorSet, [anchorID])
        XCTAssertEqual(vm.radius, .oneHop)
    }
}
