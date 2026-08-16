import XCTest
@testable import TesseraCore

// MARK: - SheetStoreImportFromDatabaseTests
//
// Contract source: this track's brief (P2-D item 2.16, `SheetStore.
// importFromDatabase`) + testing-doctrine.md's Store-mutation coverage shape
// ("receipt + persistence + no-op zero-receipt + error path (not-found
// throws without writing)") + `SheetStoreTests.swift`'s own established
// pattern for a DB-gated `SheetStore` method (this method follows THAT
// file's exact `applyGoalSeek`/`applySolverRun` shape per the wave brief's
// own "follows this file's OWN established mutation-method shape exactly"
// instruction, so this file mirrors `SheetStoreTests.swift`'s helpers).
//
// DB-GATED (doctrine rule 11): same reasoning as `SheetStoreTests.swift`'s
// own header - `SheetStore` takes a concrete `TesseraDataLayer` actor with
// no protocol seam, so this whole file needs a real, reachable Postgres +
// Valkey and is skipped unless `TESSERA_DB_INTEGRATION=1` is set AND the
// local stack answers. The ungated shadow of the one genuinely NEW logic
// path this method introduces (grid growth) lives in
// `SheetStoreImportFromDatabaseLogicShadowTests.swift`.
final class SheetStoreImportFromDatabaseTests: DoctrineTestCase {
    override var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.probe }

    private func makeConnectedStore() async throws -> SheetStore {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip(
                "TESSERA_DB_INTEGRATION not set - skipping real-Postgres SheetStore tests " +
                "(doctrine rule 11: see SheetStoreImportFromDatabaseLogicShadowTests.swift for the ungated shadow)."
            )
        }
        let dataLayer = TesseraDataLayer()
        let outcome = await dataLayer.start()
        guard case .ready = outcome else {
            throw XCTSkip("Postgres/Valkey not reachable in this environment (\(outcome)) - skipping.")
        }
        return SheetStore(dataLayer: dataLayer)
    }

    private func freshSheet(rows: Int = 2, cols: Int = 2) -> Sheet {
        Sheet.makeBlank(title: "SheetStoreImportFromDatabaseTests-\(UUID().uuidString.prefix(8))", rows: rows, cols: cols)
    }

    /// Filters out the fire-and-forget `SheetReceiptPayload.receiptType`
    /// material receipt every `SheetStore.upsert(_:)` schedules, the same
    /// filter `SheetStoreTests.swift`'s own `sheetReceipts` helper applies
    /// and for the identical reason (see that file's doc comment).
    private func sheetReceipts(_ store: SheetStore, forSheet id: UUID) async throws -> [GraphReceipt] {
        let all = try await store.receipts(forSheet: id)
        return all.filter { $0.receiptType != SheetReceiptPayload.receiptType }
    }

    // MARK: - Mutation: receipt + persistence

    func testImportFromDatabaseWritesHeaderAndDataRowsAndEmitsOneReceiptWithFullProvenance() async throws {
        let store = try await makeConnectedStore()
        let sheet = try await store.upsert(freshSheet(rows: 1, cols: 1))

        let updated = try await store.importFromDatabase(
            columns: ["id", "name"],
            rows: [["1", "Ada"], ["2", "Grace"]],
            sourcePath: "/tmp/employees.csv",
            sourceHash: "sha256:deadbeef",
            sql: "SELECT id, name FROM read_csv_auto('/tmp/employees.csv')",
            anchor: CellAddr(col: 0, row: 0),
            for: sheet.id
        )

        // Header row at the anchor, then one row per result row.
        XCTAssertEqual(updated.cellText(row: 0, col: 0), "id")
        XCTAssertEqual(updated.cellText(row: 0, col: 1), "name")
        XCTAssertEqual(updated.cellText(row: 1, col: 0), "1")
        XCTAssertEqual(updated.cellText(row: 1, col: 1), "Ada")
        XCTAssertEqual(updated.cellText(row: 2, col: 0), "2")
        XCTAssertEqual(updated.cellText(row: 2, col: 1), "Grace")
        // Grew to fit: 1 header + 2 data rows = 3 rows, 2 columns.
        XCTAssertEqual(updated.rowCount, 3)
        XCTAssertEqual(updated.columnCount, 2)

        let receipts = try await sheetReceipts(store, forSheet: sheet.id)
        let importReceipts = receipts.filter { $0.receiptType == SheetReceiptType.importFromDatabase.rawValue }
        XCTAssertEqual(importReceipts.count, 1)
        let payload = importReceipts[0].payload
        XCTAssertEqual(payload["sourcePath"], .string("/tmp/employees.csv"))
        XCTAssertEqual(payload["sourceHash"], .string("sha256:deadbeef"))
        XCTAssertEqual(payload["sql"], .string("SELECT id, name FROM read_csv_auto('/tmp/employees.csv')"))
        XCTAssertEqual(payload["rowCount"], .number(2))
        XCTAssertEqual(payload["columnCount"], .number(2))

        // Re-fetch: the write is genuinely persisted, not just returned.
        let refetched = try await store.get(id: sheet.id)
        XCTAssertEqual(refetched?.cellText(row: 1, col: 1), "Ada")
    }

    func testImportFromDatabaseAtANonZeroAnchorOffsetsBothRowsAndColumns() async throws {
        let store = try await makeConnectedStore()
        let sheet = try await store.upsert(freshSheet(rows: 2, cols: 2))

        let updated = try await store.importFromDatabase(
            columns: ["x"],
            rows: [["42"]],
            sourcePath: "/tmp/x.csv",
            sourceHash: "sha256:aaaa",
            sql: "SELECT x FROM read_csv_auto('/tmp/x.csv')",
            anchor: CellAddr(col: 1, row: 1),
            for: sheet.id
        )

        XCTAssertEqual(updated.cellText(row: 1, col: 1), "x")
        XCTAssertEqual(updated.cellText(row: 2, col: 1), "42")
        XCTAssertEqual(updated.cellText(row: 0, col: 0), "", "cells outside the imported range must stay untouched")
    }

    // MARK: - No-op: empty result

    func testImportFromDatabaseWithEmptyColumnsIsANoOp() async throws {
        let store = try await makeConnectedStore()
        let sheet = try await store.upsert(freshSheet())
        let receiptsBefore = try await sheetReceipts(store, forSheet: sheet.id)

        let updated = try await store.importFromDatabase(
            columns: [],
            rows: [],
            sourcePath: "/tmp/x.csv",
            sourceHash: "sha256:aaaa",
            sql: "SELECT 1 WHERE FALSE",
            anchor: CellAddr(col: 0, row: 0),
            for: sheet.id
        )

        XCTAssertEqual(updated.rowCount, sheet.rowCount, "a no-op must not resize the grid")
        let receiptsAfter = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptsAfter.count, receiptsBefore.count, "a no-op must emit zero receipts")
    }

    func testImportFromDatabaseWithColumnsButNoRowsIsANoOp() async throws {
        let store = try await makeConnectedStore()
        let sheet = try await store.upsert(freshSheet())
        let receiptsBefore = try await sheetReceipts(store, forSheet: sheet.id)

        _ = try await store.importFromDatabase(
            columns: ["id"],
            rows: [],
            sourcePath: "/tmp/x.csv",
            sourceHash: "sha256:aaaa",
            sql: "SELECT id FROM read_csv_auto('/tmp/x.csv') WHERE FALSE",
            anchor: CellAddr(col: 0, row: 0),
            for: sheet.id
        )

        let receiptsAfter = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptsAfter.count, receiptsBefore.count)
    }

    // MARK: - Error path: sheet not found

    func testImportFromDatabaseAgainstAMissingSheetThrowsWithoutWriting() async throws {
        let store = try await makeConnectedStore()
        let missingID = UUID()

        do {
            _ = try await store.importFromDatabase(
                columns: ["id"],
                rows: [["1"]],
                sourcePath: "/tmp/x.csv",
                sourceHash: "sha256:aaaa",
                sql: "SELECT id FROM read_csv_auto('/tmp/x.csv')",
                anchor: CellAddr(col: 0, row: 0),
                for: missingID
            )
            XCTFail("importing into a nonexistent sheet must throw")
        } catch let error as SheetStoreError {
            guard case .sheetNotFound = error else {
                XCTFail("expected .sheetNotFound, got \(error)")
                return
            }
        }
    }

    // MARK: - Error path: locked sheet

    func testImportFromDatabaseAgainstALockedSheetThrowsWithoutWriting() async throws {
        let store = try await makeConnectedStore()
        var sheet = freshSheet()
        sheet.protection = SheetProtection(isLocked: true, reason: "locked for import test")
        sheet = try await store.upsert(sheet)
        let receiptsBefore = try await sheetReceipts(store, forSheet: sheet.id)

        do {
            _ = try await store.importFromDatabase(
                columns: ["id"],
                rows: [["1"]],
                sourcePath: "/tmp/x.csv",
                sourceHash: "sha256:aaaa",
                sql: "SELECT id FROM read_csv_auto('/tmp/x.csv')",
                anchor: CellAddr(col: 0, row: 0),
                for: sheet.id
            )
            XCTFail("importing into a locked sheet must throw")
        } catch let error as SheetStoreError {
            guard case .sheetProtected = error else {
                XCTFail("expected .sheetProtected, got \(error)")
                return
            }
        }

        let receiptsAfter = try await sheetReceipts(store, forSheet: sheet.id)
        XCTAssertEqual(receiptsAfter.count, receiptsBefore.count, "a rejected write must not emit a receipt")
    }
}
