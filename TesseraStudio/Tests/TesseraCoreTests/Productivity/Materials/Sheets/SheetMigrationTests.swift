import XCTest
@testable import TesseraCore

/// Tests for the `0011_sheets.sql` migration. Pins the file's
/// existence, the partial WHERE predicates, and the idempotent
/// `IF NOT EXISTS` shape.
final class SheetMigrationTests: XCTestCase {

    private var migrationCandidates: [String] {
        [
            "tools/tessera/db/migrations/0011_sheets.sql",
            "../tools/tessera/db/migrations/0011_sheets.sql",
            "../../tools/tessera/db/migrations/0011_sheets.sql",
        ]
    }

    private func migrationContents() throws -> String? {
        for path in migrationCandidates where FileManager.default.fileExists(atPath: path) {
            return try String(contentsOfFile: path, encoding: .utf8)
        }
        return nil
    }

    func testMigrationFileExists() throws {
        guard let contents = try migrationContents() else {
            XCTFail("expected 0011_sheets.sql at one of: \(migrationCandidates)")
            return
        }
        XCTAssertTrue(contents.contains("idx_entities_sheet_updated"))
        XCTAssertTrue(contents.contains("WHERE entity_type = 'document' AND subtype = 'sheet'"))
    }

    func testMigrationIsIdempotent() throws {
        guard let contents = try migrationContents() else { return }
        XCTAssertFalse(contents.contains("BEGIN"), "migration should not use BEGIN")
        XCTAssertFalse(contents.contains("COMMIT"), "migration should not use COMMIT")
        XCTAssertFalse(contents.contains("DROP INDEX"), "migration should not drop indexes")
        // Every CREATE is `IF NOT EXISTS`.
        let createLines = contents
            .components(separatedBy: .newlines)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("--") == false }
            .filter { $0.contains("CREATE INDEX") }
        XCTAssertGreaterThan(createLines.count, 0)
        for line in createLines {
            XCTAssertTrue(line.contains("IF NOT EXISTS"), "each CREATE INDEX must be IF NOT EXISTS: \(line)")
        }
    }

    func testEveryCreateIndexHasSheetPartialPredicate() throws {
        guard let contents = try migrationContents() else { return }
        let sqlLines = contents
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
        let indexCount = sqlLines.filter { $0.contains("CREATE INDEX") }.count
        let whereCount = sqlLines.filter { $0.contains("WHERE entity_type = 'document' AND subtype = 'sheet'") }.count
        XCTAssertEqual(indexCount, 3, "migration should have exactly 3 partial indexes")
        XCTAssertEqual(indexCount, whereCount, "every CREATE INDEX should be guarded by the sheet partial predicate")
    }

    func testExpectedIndexNames() throws {
        guard let contents = try migrationContents() else { return }
        XCTAssertTrue(contents.contains("idx_entities_sheet_updated"))
        XCTAssertTrue(contents.contains("idx_entities_sheet_favorite"))
        XCTAssertTrue(contents.contains("idx_entities_sheet_archived"))
    }

    func testNoCrossMaterialIndexNames() throws {
        guard let contents = try migrationContents() else { return }
        XCTAssertFalse(contents.contains("idx_entities_note_"))
        XCTAssertFalse(contents.contains("idx_entities_doc_"))
        XCTAssertFalse(contents.contains("idx_entities_slide_"))
    }

    func testFavoriteArchivedIndexesFilterByJSONExtractor() throws {
        guard let contents = try migrationContents() else { return }
        XCTAssertTrue(contents.contains("body->>'isFavorite'"), "favorite index should filter on body->>'isFavorite'")
        XCTAssertTrue(contents.contains("body->>'isArchived'"), "archived index should filter on body->>'isArchived'")
    }
}
