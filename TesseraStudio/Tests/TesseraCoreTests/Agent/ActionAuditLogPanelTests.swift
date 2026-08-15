import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Agent/ActionAuditLogPanel.swift doc
// comments plus AGENTS.md's "ActionAuditLogPanel ... a side-panel SwiftUI
// view rendering a chronological list of every agent action + outcome
// with the tier label, time, and receipt id... backed by ActionAuditLogStore
// (@Observable, @MainActor, default capacity 500, FIFO trim)" and
// docs/PROJECT-STATUS.md item 3D.
final class ActionAuditLogPanelTests: DoctrineTestCase {

    private func entry(
        actionClass: String = "bash:git",
        summary: String? = nil,
        tier: TesseraTier = .tier1,
        risk: TesseraActionRisk = .medium,
        outcome: ActionAuditOutcome = .success,
        receiptID: UUID? = nil,
        timestamp: Date = Date()
    ) -> ActionAuditEntry {
        ActionAuditEntry(
            timestamp: timestamp, actionClass: actionClass, summary: summary,
            tier: tier, risk: risk, outcome: outcome, receiptID: receiptID
        )
    }

    // MARK: - ActionAuditOutcome: labels + tints

    func testOutcomeShortLabels() {
        XCTAssertEqual(ActionAuditOutcome.success.shortLabel, "ok")
        XCTAssertEqual(ActionAuditOutcome.failure.shortLabel, "fail")
        XCTAssertEqual(ActionAuditOutcome.reverted.shortLabel, "undone")
        XCTAssertEqual(ActionAuditOutcome.blocked.shortLabel, "blocked")
    }

    func testOutcomeCasesArePinnedToTheFourDocumentedOutcomes() {
        // Independent oracle (rule 7): pinned against AGENTS.md's named
        // set (success | failure | reverted | blocked).
        XCTAssertEqual(Set(ActionAuditOutcome.allCases.map(\.rawValue)), ["success", "failure", "reverted", "blocked"])
    }

    func testOutcomeEncodeDecodeIdentity() throws {
        for outcome in ActionAuditOutcome.allCases {
            let data = try JSONEncoder().encode(outcome)
            let decoded = try JSONDecoder().decode(ActionAuditOutcome.self, from: data)
            XCTAssertEqual(decoded, outcome)
        }
    }

    // MARK: - ActionAuditEntry.shortReceiptID / displayString

    func testShortReceiptIDIsNilWhenNoReceipt() {
        XCTAssertNil(entry(receiptID: nil).shortReceiptID)
    }

    func testShortReceiptIDIsFirstEightCharsWhenPresent() {
        let id = UUID(uuidString: "a1b2c3d4-5566-7788-99aa-bbccddeeff00")!
        XCTAssertEqual(entry(receiptID: id).shortReceiptID, "A1B2C3D4")
    }

    func testDisplayStringHasFourFieldsWithNoOptionalData() {
        let e = entry(actionClass: "bash:git", tier: .tier1, risk: .medium, outcome: .success, receiptID: nil)
        XCTAssertEqual(e.displayString, "tier: T1 | risk: medium | tool: bash:git | outcome: ok")
    }

    func testDisplayStringAppendsSummaryFieldWhenPresent() {
        let e = entry(summary: "fetch from origin")
        XCTAssertTrue(e.displayString.contains("| summary: fetch from origin"))
    }

    func testDisplayStringAppendsReceiptFieldWithEllipsisWhenPresent() {
        let id = UUID(uuidString: "a1b2c3d4-5566-7788-99aa-bbccddeeff00")!
        let e = entry(receiptID: id)
        XCTAssertTrue(e.displayString.hasSuffix("| receipt: A1B2C3D4..."))
    }

    func testDisplayStringCarriesBothSummaryAndReceiptUnlikeTheFieldCappedChip() {
        // Doc comment: "The panel row shares the chip VOCABULARY but not
        // the chip's field budget" -- applying AuditLogHead.fieldCap here
        // dropped `receipt:` whenever a summary was present, which is
        // exactly the field the row exists to carry.
        let id = UUID(uuidString: "a1b2c3d4-5566-7788-99aa-bbccddeeff00")!
        let e = entry(summary: "fetch from origin", receiptID: id)
        let fields = e.displayString.components(separatedBy: " | ")
        XCTAssertEqual(fields.count, 6, "tier/risk/tool/outcome/summary/receipt, uncapped")
        XCTAssertTrue(e.displayString.contains("summary: fetch from origin"))
        XCTAssertTrue(e.displayString.contains("receipt: A1B2C3D4..."))
    }

    func testEntryEncodeDecodeIdentity() throws {
        let e = entry(summary: "x", receiptID: UUID())
        let data = try JSONEncoder().encode(e)
        let decoded = try JSONDecoder().decode(ActionAuditEntry.self, from: data)
        XCTAssertEqual(decoded, e)
    }

    // MARK: - ActionAuditLogStore: capacity cap, FIFO trim (doc comment)

    @MainActor
    func testAppendGrowsEntriesInOrder() async {
        let store = ActionAuditLogStore(capacity: 500)
        let e1 = entry(actionClass: "a")
        let e2 = entry(actionClass: "b")
        store.append(e1)
        store.append(e2)
        XCTAssertEqual(store.entries.map(\.actionClass), ["a", "b"])
    }

    @MainActor
    func testAppendTrimsFromTheHeadWhenOverCapacity() async {
        let store = ActionAuditLogStore(capacity: 3)
        for i in 0..<5 {
            store.append(entry(actionClass: "e\(i)"))
        }
        XCTAssertEqual(store.entries.count, 3)
        // FIFO trim: the newest 3 survive (e2, e3, e4); the oldest 2 drop.
        XCTAssertEqual(store.entries.map(\.actionClass), ["e2", "e3", "e4"])
    }

    @MainActor
    func testAppendContentsOfPreservesOrderAndTrims() async {
        let store = ActionAuditLogStore(capacity: 3)
        let batch = (0..<5).map { entry(actionClass: "b\($0)") }
        store.append(contentsOf: batch)
        XCTAssertEqual(store.entries.map(\.actionClass), ["b2", "b3", "b4"])
    }

    @MainActor
    func testDefaultCapacityConstantIsFiveHundred() async {
        XCTAssertEqual(ActionAuditLogStore.defaultCapacity, 500)
        XCTAssertEqual(ActionAuditLogStore().capacity, 500)
    }

    @MainActor
    func testClearRemovesAllEntriesButNotTheFilterState() async {
        let store = ActionAuditLogStore()
        store.append(entry())
        store.tierFilter = [.tier2]
        store.searchText = "abc"
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.tierFilter, [.tier2])
        XCTAssertEqual(store.searchText, "abc")
    }

    // MARK: - visible: filter (tier + outcome + search) and sort
    // (newest-first, tie-break by id)

    @MainActor
    func testVisibleWithNoFilterReturnsEverythingNewestFirst() async {
        let store = ActionAuditLogStore()
        let older = entry(actionClass: "older", timestamp: Date(timeIntervalSince1970: 1000))
        let newer = entry(actionClass: "newer", timestamp: Date(timeIntervalSince1970: 2000))
        store.append(older)
        store.append(newer)
        XCTAssertEqual(store.visible.map(\.actionClass), ["newer", "older"])
    }

    @MainActor
    func testVisibleTierFilterNarrowsToAllowedTiers() async {
        let store = ActionAuditLogStore()
        store.append(entry(actionClass: "t1", tier: .tier1))
        store.append(entry(actionClass: "t2", tier: .tier2))
        store.tierFilter = [.tier2]
        XCTAssertEqual(store.visible.map(\.actionClass), ["t2"])
    }

    @MainActor
    func testVisibleOutcomeFilterNarrowsToAllowedOutcomes() async {
        let store = ActionAuditLogStore()
        store.append(entry(actionClass: "ok1", outcome: .success))
        store.append(entry(actionClass: "fail1", outcome: .failure))
        store.outcomeFilter = [.failure]
        XCTAssertEqual(store.visible.map(\.actionClass), ["fail1"])
    }

    @MainActor
    func testVisibleSearchMatchesActionClassCaseInsensitively() async {
        let store = ActionAuditLogStore()
        store.append(entry(actionClass: "bash:git"))
        store.append(entry(actionClass: "file_write:src/**"))
        store.searchText = "GIT"
        XCTAssertEqual(store.visible.map(\.actionClass), ["bash:git"])
    }

    @MainActor
    func testVisibleSearchMatchesSummary() async {
        let store = ActionAuditLogStore()
        store.append(entry(actionClass: "bash:git", summary: "fetch from origin"))
        store.append(entry(actionClass: "bash:npm", summary: "install deps"))
        store.searchText = "origin"
        XCTAssertEqual(store.visible.map(\.actionClass), ["bash:git"])
    }

    @MainActor
    func testVisibleSearchTrimsWhitespace() async {
        let store = ActionAuditLogStore()
        store.append(entry(actionClass: "bash:git"))
        store.searchText = "  git  "
        XCTAssertEqual(store.visible.count, 1)
    }

    @MainActor
    func testVisibleAppliesTierAndOutcomeAndSearchTogether() async {
        let store = ActionAuditLogStore()
        store.append(entry(actionClass: "bash:git", summary: "fetch", tier: .tier2, outcome: .success))
        store.append(entry(actionClass: "bash:git", summary: "fetch", tier: .tier1, outcome: .success))
        store.append(entry(actionClass: "bash:git", summary: "fetch", tier: .tier2, outcome: .failure))
        store.tierFilter = [.tier2]
        store.outcomeFilter = [.success]
        store.searchText = "fetch"
        XCTAssertEqual(store.visible.count, 1)
        XCTAssertEqual(store.visible.first?.tier, .tier2)
        XCTAssertEqual(store.visible.first?.outcome, .success)
    }

    @MainActor
    func testVisibleSortIsStableByIdWhenTimestampsTie() async {
        let store = ActionAuditLogStore()
        let sharedTime = Date(timeIntervalSince1970: 5000)
        // Two ids, deterministic order by string comparison.
        let idLow = UUID(uuidString: "10000000-0000-0000-0000-000000000000")!
        let idHigh = UUID(uuidString: "F0000000-0000-0000-0000-000000000000")!
        let a = ActionAuditEntry(id: idHigh, timestamp: sharedTime, actionClass: "a", tier: .tier0, risk: .low, outcome: .success)
        let b = ActionAuditEntry(id: idLow, timestamp: sharedTime, actionClass: "b", tier: .tier0, risk: .low, outcome: .success)
        store.append(a)
        store.append(b)
        // Tie-break: ascending id.uuidString ("1..." < "F...").
        XCTAssertEqual(store.visible.map(\.id), [idLow, idHigh])
    }

    // MARK: - headerSubtitle

    @MainActor
    func testHeaderSubtitleWithNoFilterShowsTotalCount() async {
        let store = ActionAuditLogStore()
        store.append(entry())
        store.append(entry())
        XCTAssertEqual(store.headerSubtitle, "2 actions")
    }

    @MainActor
    func testHeaderSubtitleSingularForOneAction() async {
        let store = ActionAuditLogStore()
        store.append(entry())
        XCTAssertEqual(store.headerSubtitle, "1 action")
    }

    @MainActor
    func testHeaderSubtitleWithActiveFilterShowsNOfM() async {
        let store = ActionAuditLogStore()
        store.append(entry(tier: .tier1))
        store.append(entry(tier: .tier2))
        store.tierFilter = [.tier2]
        XCTAssertEqual(store.headerSubtitle, "1 of 2 actions")
    }

    @MainActor
    func testHeaderSubtitleWithEmptyStoreShowsZeroActions() async {
        let store = ActionAuditLogStore()
        XCTAssertEqual(store.headerSubtitle, "0 actions")
    }
}
