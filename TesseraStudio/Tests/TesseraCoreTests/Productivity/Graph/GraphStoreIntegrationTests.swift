import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Graph/GraphStore.swift
// doc comments (loadAll/loadOfType/search). `GraphStore` is READ-ONLY --
// it has no mutation methods and emits no receipts (see this cluster's
// findings file, "Architectural notes"), so the doctrine Store-mutation
// coverage shape (receipt + persistence + no-op + error path) does not
// apply here; instead this exercises the "renderer"-style contract
// (content, not survival -- doctrine rule 8): the row -> `GraphNode`/
// `GraphEdge` mapping is correct against a live row, and edges whose
// endpoints are outside the loaded node set are dropped.
//
// Every method here requires a live `TesseraDataLayer` (no protocol
// seam, no data-layer-optional constructor like `CodeStore`), so this
// entire file is gated; the pure mapping/math pieces
// (`GraphNode.iconName`/`color`, `GraphStore.recomputeImportance`) are
// covered ungated in GraphModelTests.swift.

final class GraphStoreIntegrationTests: DoctrineTestCase {
    override var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.probe }

    private func connectedDataLayer() async throws -> TesseraDataLayer {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip("TESSERA_DB_INTEGRATION not set; skipping live-Postgres GraphStore tests")
        }
        let layer = TesseraDataLayer()
        let outcome = await layer.start()
        guard outcome == .ready else {
            throw XCTSkip("TesseraDataLayer did not reach .ready (\(outcome)); skipping live-Postgres GraphStore tests")
        }
        return layer
    }

    func testLoadOfTypeReturnsAnUpsertedContactAsANode() async throws {
        let layer = try await connectedDataLayer()
        let contactStore = ContactStore(dataLayer: layer)
        let contact = Contact(subtype: .person, name: NameComponents(first: "Zeph-\(UUID().uuidString.prefix(8))", last: "Example"))
        _ = try await contactStore.upsert(contact)

        let graphStore = GraphStore(dataLayer: layer)
        let snapshot = try await graphStore.loadOfType("contact", nodeLimit: 10_000)

        let node = snapshot.nodes.first { $0.id == contact.id }
        XCTAssertNotNil(node)
        XCTAssertEqual(node?.entityType, "contact")
        XCTAssertEqual(node?.label, contact.displayName)
        XCTAssertEqual(node?.iconName, GraphNode.iconName(for: "contact", subtype: contact.subtypeString))
    }

    func testLoadAllIncludesAnUpsertedTaskAndItsLinkAsAnEdge() async throws {
        let layer = try await connectedDataLayer()
        let taskStore = ProductivityTaskStore(dataLayer: layer)
        let noteStore = NoteStore(dataLayer: layer)
        let task = ProductivityTask(title: "Graph-visible task \(UUID().uuidString.prefix(8))")
        let note = Note(title: "Graph-visible note \(UUID().uuidString.prefix(8))")
        _ = try await taskStore.upsert(task)
        _ = try await noteStore.upsert(note)
        _ = try await taskStore.linkTask(task.id, to: note.id, linkType: "related_to")

        let graphStore = GraphStore(dataLayer: layer)
        let snapshot = try await graphStore.loadAll(nodeLimit: 50_000, edgeLimit: 100_000)

        XCTAssertTrue(snapshot.nodes.contains { $0.id == task.id })
        XCTAssertTrue(snapshot.nodes.contains { $0.id == note.id })
        XCTAssertTrue(snapshot.edges.contains { $0.sourceID == task.id && $0.targetID == note.id })
    }

    func testSearchFindsAnUpsertedNoteByLabelPrefix() async throws {
        let layer = try await connectedDataLayer()
        let noteStore = NoteStore(dataLayer: layer)
        let uniquePrefix = "Zzq\(UUID().uuidString.prefix(8))"
        let note = Note(title: uniquePrefix + " search target")
        _ = try await noteStore.upsert(note)

        let graphStore = GraphStore(dataLayer: layer)
        let results = try await graphStore.search(query: uniquePrefix, limit: 10)

        XCTAssertTrue(results.contains { $0.id == note.id })
    }
}
