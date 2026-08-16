import XCTest
import CryptoKit
@testable import TesseraCore

// Contract source: ReceiptExportService.export's own doc comments --
// "requires a userConfirmed: true flag" (ExportError.userDenied),
// "the service consults the configured EgressPolicy before building the
// artifact" (ExportError.buildFailed on denial), and the `guard
// !chain.isEmpty else { throw ExportError.noReceipts }` gate. Doctrine
// rule 11's ungated shadow: the same gating/wiring contract, exercised
// against `InMemoryReceiptExportService` + `InMemoryDocumentStore` so it
// runs in a plain `swift test`. The real service's Postgres-backed
// persistence and its pure build helpers are separately verified
// (respectively: out of scope per ReceiptExportServiceTests.swift's own
// header comment, and directly by that same file).

final class ReceiptExportServicingContractTests: DoctrineTestCase {

    private func seedOneReceipt(in documentStore: InMemoryDocumentStore, documentID: UUID) async throws {
        _ = try await documentStore.apply(
            mutation: .insertBlockAfter(parentID: nil, anchorID: nil, block: Block(id: UUID(), type: .paragraph)),
            to: documentID,
            actor: .user(UUID())
        )
    }

    // MARK: - userConfirmed gate

    func testExportWithoutUserConfirmationThrowsUserDeniedAndLogsNothing() async throws {
        let documentStore = InMemoryDocumentStore()
        let docID = UUID()
        try await seedOneReceipt(in: documentStore, documentID: docID)
        let service = InMemoryReceiptExportService(documentStore: documentStore)

        do {
            _ = try await service.export(documentID: docID, format: .signedJSON, documentTitle: "Doc", userID: UUID(), userConfirmed: false)
            XCTFail("expected ExportError.userDenied")
        } catch ExportError.userDenied {
            // expected
        }
        XCTAssertTrue(service.loggedExports(for: docID).isEmpty)
    }

    // MARK: - noReceipts gate

    func testExportOfDocumentWithNoReceiptsThrowsNoReceiptsAndLogsNothing() async throws {
        let documentStore = InMemoryDocumentStore()
        let docID = UUID()
        let service = InMemoryReceiptExportService(documentStore: documentStore)

        do {
            _ = try await service.export(documentID: docID, format: .signedJSON, documentTitle: "Doc", userID: UUID(), userConfirmed: true)
            XCTFail("expected ExportError.noReceipts")
        } catch ExportError.noReceipts {
            // expected
        }
        XCTAssertTrue(service.loggedExports(for: docID).isEmpty)
    }

    // MARK: - egress policy gate

    func testExportDeniedByEgressPolicyThrowsBuildFailedAndLogsNothing() async throws {
        struct DenyAll: EgressPolicy {
            func allowsExport(documentID: UUID, format: ReceiptExportFormat) -> Bool { false }
        }
        let documentStore = InMemoryDocumentStore()
        let docID = UUID()
        try await seedOneReceipt(in: documentStore, documentID: docID)
        let service = InMemoryReceiptExportService(documentStore: documentStore, egressPolicy: DenyAll())

        do {
            _ = try await service.export(documentID: docID, format: .signedJSON, documentTitle: "Doc", userID: UUID(), userConfirmed: true)
            XCTFail("expected ExportError.buildFailed")
        } catch ExportError.buildFailed(_) {
            // expected
        }
        XCTAssertTrue(service.loggedExports(for: docID).isEmpty)
    }

    // MARK: - successful export logs exactly one receipt

    func testSuccessfulExportLogsExactlyOneReceiptNamingTheFormat() async throws {
        let documentStore = InMemoryDocumentStore()
        let docID = UUID()
        try await seedOneReceipt(in: documentStore, documentID: docID)
        let service = InMemoryReceiptExportService(documentStore: documentStore)

        let artifact = try await service.export(documentID: docID, format: .markdown, documentTitle: "Doc", userID: UUID(), userConfirmed: true)

        let logged = service.loggedExports(for: docID)
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged.first?.id, artifact.receiptID)
        XCTAssertTrue(logged.first?.summary.contains("Markdown summary") ?? false)
    }

    func testExportChainedTwiceLogsTwoReceiptsWithTheSecondsPriorPointingAtTheFirst() async throws {
        let documentStore = InMemoryDocumentStore()
        let docID = UUID()
        try await seedOneReceipt(in: documentStore, documentID: docID)
        let service = InMemoryReceiptExportService(documentStore: documentStore)

        _ = try await service.export(documentID: docID, format: .signedJSON, documentTitle: "Doc", userID: UUID(), userConfirmed: true)
        _ = try await service.export(documentID: docID, format: .signedJSON, documentTitle: "Doc", userID: UUID(), userConfirmed: true)

        let logged = service.loggedExports(for: docID)
        XCTAssertEqual(logged.count, 2)
    }
}
