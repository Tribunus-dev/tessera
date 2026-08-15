import XCTest

// Placeholder keeping the test target buildable between the 2026-08-15
// pre-doctrine suite deletion and the doctrine-compliant rewrite (see
// docs/testing-doctrine.md). Each rewrite cluster deletes this file's
// claim on its area by landing real suites; the last cluster deletes the
// file.
final class DoctrinePlaceholderTests: XCTestCase {
    func testFixturesSurvivedTheSuiteDeletion() throws {
        // The pinned data contracts must exist even while no suite runs.
        let fixtures = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Fixtures") ?? []
        XCTAssertFalse(fixtures.isEmpty, "pinned fixtures are data contracts and must survive")
    }
}
