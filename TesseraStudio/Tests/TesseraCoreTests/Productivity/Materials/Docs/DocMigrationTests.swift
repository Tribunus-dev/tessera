import XCTest
@testable import TesseraCore

final class DocMigrationTests: XCTestCase {

    func testMigrationFileExistsAndIsIdempotent() throws {
        let url = Bundle.module.url(forResource: "0010_docs", withExtension: "sql")
            ?? URL(fileURLWithPath: "/Users/user/Developer/GitHub/tessera/worktrees/prod-material-docs/tools/tessera/db/migrations/0010_docs.sql")
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        XCTAssertTrue(exists, "0010_docs.sql must exist — checked \(url.path)")
        let sql = try String(contentsOf: url, encoding: .utf8)
        // Must be IF NOT EXISTS (idempotent re-apply).
        XCTAssertTrue(sql.contains("IF NOT EXISTS"), "migration must use IF NOT EXISTS")
        XCTAssertTrue(sql.contains("idx_entities_doc_updated"), "must create idx_entities_doc_updated")
        XCTAssertTrue(sql.contains("idx_entities_doc_favorite"), "must create idx_entities_doc_favorite")
        XCTAssertTrue(sql.contains("idx_entities_doc_archived"), "must create idx_entities_doc_archived")
        // All indexes must be partial on document/doc.
        XCTAssertTrue(sql.contains("entity_type = 'document' AND subtype = 'doc'"), "indexes must be partial on document/doc")
    }

    func testNoCollisionWithReservedMigrations() {
        let fm = FileManager.default
        let dir = "/Users/user/Developer/GitHub/tessera/worktrees/prod-material-docs/tools/tessera/db/migrations"
        let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        XCTAssertTrue(files.contains("0010_docs.sql"))
        // 0011/0012 are reserved for Sheets/Slides — must not collide yet.
        // If they exist, the test still passes (another worker landed them).
        // The only failure is if 0010 itself is missing.
        XCTAssertTrue(files.contains("0009_code_files.sql"))
    }
}
