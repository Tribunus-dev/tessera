import XCTest
@testable import TesseraCore

final class DocMigrationTests: XCTestCase {

    private var migrationCandidates: [String] {
        [
            "tools/tessera/db/migrations/0010_docs.sql",
            "../tools/tessera/db/migrations/0010_docs.sql",
            "../../tools/tessera/db/migrations/0010_docs.sql",
        ]
    }

    private func migrationContents() throws -> String? {
        if let url = Bundle.module.url(forResource: "0010_docs", withExtension: "sql"),
           FileManager.default.fileExists(atPath: url.path) {
            return try String(contentsOf: url, encoding: .utf8)
        }
        for path in migrationCandidates where FileManager.default.fileExists(atPath: path) {
            return try String(contentsOfFile: path, encoding: .utf8)
        }
        let legacy = "/Users/user/Developer/GitHub/tessera/worktrees/prod-material-docs/tools/tessera/db/migrations/0010_docs.sql"
        if FileManager.default.fileExists(atPath: legacy) {
            return try String(contentsOfFile: legacy, encoding: .utf8)
        }
        return nil
    }

    func testMigrationFileExistsAndIsIdempotent() throws {
        guard let sql = try migrationContents() else {
            XCTFail("0010_docs.sql must exist — checked \(migrationCandidates + ["/Users/user/Developer/GitHub/tessera/worktrees/prod-material-docs/tools/tessera/db/migrations/0010_docs.sql"])")
            return
        }
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
        let candidates = [
            "tools/tessera/db/migrations",
            "../tools/tessera/db/migrations",
            "../../tools/tessera/db/migrations",
            "/Users/user/Developer/GitHub/tessera/worktrees/prod-material-docs/tools/tessera/db/migrations",
            "/Users/user/Developer/GitHub/tessera/tools/tessera/db/migrations",
        ]
        let dir = candidates.first(where: { fm.fileExists(atPath: $0) }) ?? candidates[0]
        let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        XCTAssertTrue(files.contains("0010_docs.sql"), "0010_docs.sql must exist in \(dir)")
        XCTAssertTrue(files.contains("0009_code_files.sql"), "0009_code_files.sql must exist in \(dir)")
    }
}
