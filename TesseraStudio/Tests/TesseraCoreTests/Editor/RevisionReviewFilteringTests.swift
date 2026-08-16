import XCTest
@testable import TesseraCore

// MARK: - RevisionReviewFilteringTests
//
// Contract: sota-p2-core-report.md section 2.9 - "author + pending-only
// filters; search" - plus this track's own tests list: "author filter
// partitions exactly". Pure filter over an already-scanned row list; no
// store, no DB, no SwiftUI host.

final class RevisionReviewFilteringTests: DoctrineTestCase {

    private func row(
        id: UUID = UUID(),
        author: String?,
        status: RevisionRowStatus = .pending,
        excerpt: String = ""
    ) -> RevisionRow {
        RevisionRow(id: id, author: author, timestamp: nil, kind: .insertion, excerpt: excerpt, status: status)
    }

    // MARK: - Author filter

    func testAuthorFilterPartitionsExactly() {
        let alice1 = row(author: "alice")
        let alice2 = row(author: "alice")
        let bob1 = row(author: "bob")
        let noAuthor = row(author: nil)
        let rows = [alice1, alice2, bob1, noAuthor]

        let aliceOnly = RevisionReviewFiltering.apply(to: rows, authorFilter: ["alice"], pendingOnly: false, searchText: "")
        XCTAssertEqual(Set(aliceOnly.map(\.id)), [alice1.id, alice2.id])

        let bobOnly = RevisionReviewFiltering.apply(to: rows, authorFilter: ["bob"], pendingOnly: false, searchText: "")
        XCTAssertEqual(Set(bobOnly.map(\.id)), [bob1.id])

        let both = RevisionReviewFiltering.apply(to: rows, authorFilter: ["alice", "bob"], pendingOnly: false, searchText: "")
        XCTAssertEqual(Set(both.map(\.id)), [alice1.id, alice2.id, bob1.id])

        // A row with no author never matches a non-empty author filter,
        // regardless of which authors are selected.
        XCTAssertFalse(aliceOnly.contains { $0.id == noAuthor.id })
        XCTAssertFalse(bobOnly.contains { $0.id == noAuthor.id })
        XCTAssertFalse(both.contains { $0.id == noAuthor.id })
    }

    func testEmptyAuthorFilterMeansEveryAuthor() {
        let rows = [row(author: "alice"), row(author: "bob"), row(author: nil)]
        let visible = RevisionReviewFiltering.apply(to: rows, authorFilter: [], pendingOnly: false, searchText: "")
        XCTAssertEqual(visible.count, 3)
    }

    // MARK: - Pending-only filter

    func testPendingOnlyFilterExcludesResolvedRows() {
        let pending = row(author: "alice", status: .pending)
        let resolved = row(author: "alice", status: .resolved(direction: .accept, receiptID: nil, resolvedAt: Date()))
        let rows = [pending, resolved]

        let pendingOnly = RevisionReviewFiltering.apply(to: rows, authorFilter: [], pendingOnly: true, searchText: "")
        XCTAssertEqual(pendingOnly.map(\.id), [pending.id])

        let both = RevisionReviewFiltering.apply(to: rows, authorFilter: [], pendingOnly: false, searchText: "")
        XCTAssertEqual(Set(both.map(\.id)), [pending.id, resolved.id])
    }

    // MARK: - Search

    func testSearchMatchesAuthorOrExcerptCaseInsensitively() {
        let alice = row(author: "Alice Torres", excerpt: "fixed the header")
        let bob = row(author: "Bob", excerpt: "removed a stray comma")
        let rows = [alice, bob]

        let byAuthor = RevisionReviewFiltering.apply(to: rows, authorFilter: [], pendingOnly: false, searchText: "torres")
        XCTAssertEqual(byAuthor.map(\.id), [alice.id])

        let byExcerpt = RevisionReviewFiltering.apply(to: rows, authorFilter: [], pendingOnly: false, searchText: "COMMA")
        XCTAssertEqual(byExcerpt.map(\.id), [bob.id])
    }

    func testBlankSearchTextMatchesEverything() {
        let rows = [row(author: "alice"), row(author: "bob")]
        let visible = RevisionReviewFiltering.apply(to: rows, authorFilter: [], pendingOnly: false, searchText: "   ")
        XCTAssertEqual(visible.count, 2)
    }

    // MARK: - Combined filters

    func testFiltersCombineWithAndSemantics() {
        let match = row(author: "alice", status: .pending, excerpt: "header fix")
        let wrongAuthor = row(author: "bob", status: .pending, excerpt: "header fix")
        let resolved = row(author: "alice", status: .resolved(direction: .reject, receiptID: nil, resolvedAt: Date()), excerpt: "header fix")
        let rows = [match, wrongAuthor, resolved]

        let visible = RevisionReviewFiltering.apply(
            to: rows, authorFilter: ["alice"], pendingOnly: true, searchText: "header"
        )
        XCTAssertEqual(visible.map(\.id), [match.id])
    }
}
