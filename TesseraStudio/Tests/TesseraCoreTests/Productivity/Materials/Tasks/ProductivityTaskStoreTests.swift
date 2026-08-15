import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Tasks/ProductivityTaskStore.swift
// doc comments + docs/tessera-productivity-materials-tasks-design.md
// section 7's receipt table.
//
// `ProductivityTaskStore` wraps `TesseraDataLayer` directly with no
// protocol seam. Ungated half of doctrine rule 11 (see
// CalendarStoreTests.swift's header for the `.closed`-propagation
// mechanism) plus the receipt-type taxonomy pin. The receipt +
// persistence + no-op + not-found quartet needs a live row and lives in
// ProductivityTaskStoreIntegrationTests.swift (TESSERA_DB_INTEGRATION-gated).

final class ProductivityTaskStoreTests: DoctrineTestCase {

    private func makeStore() -> ProductivityTaskStore {
        ProductivityTaskStore(dataLayer: TesseraDataLayer())
    }

    // MARK: - Error propagation on a closed data layer

    func testUpsertOnClosedDataLayerThrowsRatherThanSucceeding() async {
        let store = makeStore()
        do {
            _ = try await store.upsert(ProductivityTask(title: "Review Q3 report"))
            XCTFail("expected the closed data layer's error to propagate")
        } catch {
            XCTAssertTrue(error is TesseraDataStoreError, "expected TesseraDataStoreError, got \(error)")
        }
    }

    func testGetOnClosedDataLayerThrowsRatherThanReturningNil() async {
        let store = makeStore()
        do {
            _ = try await store.get(id: UUID())
            XCTFail("expected the closed data layer's error to propagate")
        } catch {
            XCTAssertTrue(error is TesseraDataStoreError, "expected TesseraDataStoreError, got \(error)")
        }
    }

    // MARK: - Receipt type taxonomy pin (rule 5 + rule 7's independent
    // oracle: hardcoded from the design doc's table, section 7)

    func testProductivityTaskReceiptTypeRawValuesArePinned() {
        let expected: [ProductivityTaskReceiptType: String] = [
            .upsert: "task_upsert",
            .delete: "task_delete",
            .completed: "task_completed",
            .reopened: "task_reopened",
            .moved: "task_moved",
            .priorityChanged: "task_priority_changed",
            .dueDateChanged: "task_due_date_changed",
            .linkCreated: "task_link_created",
            .linkDeleted: "task_link_deleted",
            .createdFromChat: "task_created_from_chat",
            .createdFromNLU: "task_created_from_nlu",
        ]
        for (receiptType, rawValue) in expected {
            XCTAssertEqual(receiptType.rawValue, rawValue)
        }
    }

    func testProductivityTaskReceiptTypeHasNoUnexpectedCases() {
        let expected: Set<String> = [
            "task_upsert", "task_delete", "task_completed", "task_reopened",
            "task_moved", "task_priority_changed", "task_due_date_changed",
            "task_link_created", "task_link_deleted", "task_created_from_chat",
            "task_created_from_nlu",
        ]
        XCTAssertEqual(Set(ProductivityTaskReceiptType.allCases.map(\.rawValue)), expected)
    }

    // MARK: - ProductivityTaskStoreError equality

    func testProductivityTaskStoreErrorNotFoundEqualityIsByID() {
        let id = UUID()
        XCTAssertEqual(ProductivityTaskStoreError.taskNotFound(id: id), ProductivityTaskStoreError.taskNotFound(id: id))
        XCTAssertNotEqual(ProductivityTaskStoreError.taskNotFound(id: id), ProductivityTaskStoreError.taskNotFound(id: UUID()))
    }

    // MARK: - exposedDataLayer accessor

    func testExposedDataLayerBehavesIdenticallyToTheInjectedInstance() async {
        // Reference-identity is not checkable on an actor value directly,
        // but the accessor's contract (per its doc comment: "Exposed for
        // callers ... that need to reach the data layer's other
        // affordances") is that calling through it behaves identically to
        // calling the store itself; both are unconnected here, so both
        // must fail identically with `.closed`.
        let store = makeStore()
        do {
            _ = try await store.exposedDataLayer.getEntity(id: UUID())
            XCTFail("expected closed data layer error")
        } catch {
            XCTAssertTrue(error is TesseraDataStoreError)
        }
    }
}
