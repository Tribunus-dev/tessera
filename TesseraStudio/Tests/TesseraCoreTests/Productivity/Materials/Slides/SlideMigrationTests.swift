import XCTest
@testable import TesseraCore

final class SlideMigrationTests: XCTestCase {

    func testMigrationFileExistsAndIsIdempotent() throws {
        let candidates: [URL] = [
            Bundle.module.url(forResource: "0012_slides", withExtension: "sql"),
            URL(fileURLWithPath: "/Users/user/Developer/GitHub/tessera/worktrees/prod-material-slides/tools/tessera/db/migrations/0012_slides.sql"),
            URL(fileURLWithPath: "/Users/user/Developer/GitHub/tessera/tools/tessera/db/migrations/0012_slides.sql"),
        ].compactMap { $0 }
        let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertNotNil(url, "0012_slides.sql must exist — checked \(candidates.map { $0.path }.joined(separator: ", "))")
        let sql = try String(contentsOf: url!, encoding: .utf8)
        XCTAssertTrue(sql.contains("IF NOT EXISTS"), "migration must use IF NOT EXISTS")
        XCTAssertTrue(sql.contains("idx_entities_slide_updated"), "must create idx_entities_slide_updated")
        XCTAssertTrue(sql.contains("idx_entities_slide_favorite"), "must create idx_entities_slide_favorite")
        XCTAssertTrue(sql.contains("idx_entities_slide_archived"), "must create idx_entities_slide_archived")
        XCTAssertTrue(sql.contains("entity_type = 'document' AND subtype = 'slide'"), "indexes must be partial on document/slide")
    }

    func testNoCollisionWithReservedMigrations() {
        let fm = FileManager.default
        let candidates = [
            "/Users/user/Developer/GitHub/tessera/worktrees/prod-material-slides/tools/tessera/db/migrations",
            "/Users/user/Developer/GitHub/tessera/tools/tessera/db/migrations",
        ]
        let dir = candidates.first(where: { fm.fileExists(atPath: $0) }) ?? candidates[0]
        let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        XCTAssertTrue(files.contains("0012_slides.sql"), "0012_slides.sql must exist in \(dir)")
        XCTAssertTrue(files.contains("0009_code_files.sql"))
        // Docs/Sheets migrations are from sibling worktrees — may not be present on main.
        // The invariant is that 0010/0011/0012 are the B-wave numbers; verify 0012 didn't collide.
        XCTAssertFalse(files.contains("0012_docs.sql"))
        XCTAssertFalse(files.contains("0012_sheets.sql"))
    }

    func testMigrationMentionsSlideSubtype() throws {
        let candidates: [URL] = [
            Bundle.module.url(forResource: "0012_slides", withExtension: "sql"),
            URL(fileURLWithPath: "/Users/user/Developer/GitHub/tessera/worktrees/prod-material-slides/tools/tessera/db/migrations/0012_slides.sql"),
        ].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            XCTFail("0012_slides.sql not found"); return
        }
        let sql = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(sql.contains("subtype = 'slide'"))
        // Must mention the body extractor for favorite/archived.
        XCTAssertTrue(sql.contains("isFavorite") || sql.contains("is_favorite") || sql.contains("body->>"))
    }
}
