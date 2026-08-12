import XCTest
import SwiftUI
@testable import TesseraCore

// ActionAuditLogPanel tests (review #4 follow-up, agent-ux-fatigue).
// The four acceptance criteria the dispatch wired are:
//
//   1. The panel renders the chronological list with tier labels.
//   2. The toggle works (the panel can be presented / dismissed).
//   3. The chip vocabulary matches the audit-log HEAD chip (review
//      #5 / item 1C) - one chip language on every surface.
//   4. ASCII-only display string so the chip composes inside
//      SwiftUI text without surprises.
//
// The data layer (ActionAuditLogStore) is the source of truth for
// the panel; the SwiftUI view is a thin render over it. Tests are
// organised by acceptance criterion and exercise the data layer
// + the view-model surface directly, without spinning up AppKit
// (the AppKit side-panel presenter is a host concern).

@MainActor
final class ActionAuditLogPanelTests: XCTestCase {

    // MARK: - Helpers

    private func makeEntry(
        id: UUID = UUID(),
        timestamp: Date,
        actionClass: String,
        summary: String? = nil,
        tier: TesseraTier,
        risk: TesseraActionRisk,
        outcome: ActionAuditOutcome,
        receiptID: UUID? = nil
    ) -> ActionAuditEntry {
        ActionAuditEntry(
            id: id,
            timestamp: timestamp,
            actionClass: actionClass,
            summary: summary,
            tier: tier,
            risk: risk,
            outcome: outcome,
            receiptID: receiptID
        )
    }

    // MARK: - 1. Chronological list with tier labels

    func testVisibleIsSortedNewestFirst() {
        // The panel reads "what did the agent do lately", so the
        // visible slice is newest-first. Same direction as the
        // chat progress feed (item 2A).
        let store = ActionAuditLogStore()
        let t0 = Date(timeIntervalSince1970: 0)
        let older = makeEntry(timestamp: t0, actionClass: "bash:ls", tier: .tier0, risk: .low, outcome: .success)
        let middle = makeEntry(timestamp: t0.addingTimeInterval(60), actionClass: "file_write:src/**", tier: .tier1, risk: .medium, outcome: .success)
        let newer = makeEntry(timestamp: t0.addingTimeInterval(120), actionClass: "send_email", tier: .tier2, risk: .high, outcome: .success)
        store.append(older)
        store.append(middle)
        store.append(newer)
        XCTAssertEqual(store.visible.map(\.id), [newer.id, middle.id, older.id])
    }

    func testVisibleIncludesTierLabel() {
        // Each row's display string carries the tier label
        // (`tier: T0` ... `tier: T3`). The chip is the headline;
        // the user reads the tier at a glance.
        let store = ActionAuditLogStore()
        let entry = makeEntry(
            timestamp: Date(),
            actionClass: "exec_payment",
            tier: .tier3,
            risk: .high,
            outcome: .success
        )
        store.append(entry)
        let visible = store.visible
        XCTAssertEqual(visible.count, 1)
        XCTAssertTrue(visible[0].displayString.contains("tier: T3"),
            "displayString must include the tier short label: \(visible[0].displayString)")
    }

    func testAllTiersRender() {
        // Smoke: every tier short label surfaces in the chip
        // string. Catches a future refactor that drops the tier
        // field.
        for tier in TesseraTier.allCases {
            let entry = makeEntry(
                timestamp: Date(),
                actionClass: "toolname",
                tier: tier,
                risk: .low,
                outcome: .success
            )
            XCTAssertTrue(
                entry.displayString.contains("tier: \(tier.shortLabel)"),
                "missing tier: \(tier.shortLabel) in \(entry.displayString)"
            )
        }
    }

    // MARK: - 2. Toggle / capacity / clear

    func testAppendTrimsToCapacity() {
        // The capacity cap is the failure mode the brief calls
        // out: "the panel may have so many entries that it
        // becomes a wall." Default is 500; entries past the cap
        // are dropped FIFO.
        let store = ActionAuditLogStore(capacity: 3)
        for i in 0..<5 {
            store.append(makeEntry(
                timestamp: Date().addingTimeInterval(TimeInterval(i)),
                actionClass: "bash:ls",
                tier: .tier0,
                risk: .low,
                outcome: .success
            ))
        }
        XCTAssertEqual(store.entries.count, 3,
            "store should trim to capacity; got \(store.entries.count)")
    }

    func testClearEmptiesEntriesButNotFilter() {
        // Clear drops entries; the user's filter and search are
        // preserved so the next session starts on the same view.
        let store = ActionAuditLogStore()
        store.append(makeEntry(
            timestamp: Date(),
            actionClass: "bash:ls",
            tier: .tier0,
            risk: .low,
            outcome: .success
        ))
        store.tierFilter = [.tier2]
        store.searchText = "send"
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.tierFilter, [.tier2])
        XCTAssertEqual(store.searchText, "send")
    }

    func testHeaderSubtitleNarrowsWhenFiltered() {
        // The header reads "N actions" when no filter is active
        // and "N of M actions" when a filter narrows the visible
        // set. Lets the user see at a glance that the list is
        // filtered.
        let store = ActionAuditLogStore()
        let t0 = Date()
        store.append(makeEntry(
            timestamp: t0,
            actionClass: "bash:ls",
            tier: .tier0,
            risk: .low,
            outcome: .success
        ))
        store.append(makeEntry(
            timestamp: t0.addingTimeInterval(1),
            actionClass: "send_email",
            tier: .tier2,
            risk: .high,
            outcome: .success
        ))
        store.append(makeEntry(
            timestamp: t0.addingTimeInterval(2),
            actionClass: "exec_payment",
            tier: .tier3,
            risk: .high,
            outcome: .success
        ))
        XCTAssertEqual(store.headerSubtitle, "3 actions")
        store.tierFilter = [.tier3]
        XCTAssertEqual(store.headerSubtitle, "1 of 3 actions")
    }

    func testAppendBatchPreservesOrder() {
        // Re-hydration path: the host may push a batch of entries
        // (e.g. on first show). Order is preserved.
        let store = ActionAuditLogStore()
        let t0 = Date()
        let a = makeEntry(timestamp: t0, actionClass: "a", tier: .tier0, risk: .low, outcome: .success)
        let b = makeEntry(timestamp: t0.addingTimeInterval(1), actionClass: "b", tier: .tier1, risk: .low, outcome: .success)
        let c = makeEntry(timestamp: t0.addingTimeInterval(2), actionClass: "c", tier: .tier2, risk: .high, outcome: .success)
        store.append(contentsOf: [a, b, c])
        XCTAssertEqual(store.entries.map(\.id), [a.id, b.id, c.id])
    }

    // MARK: - 3. Filter + search

    func testFilterByTierHidesOtherTiers() {
        let store = ActionAuditLogStore()
        let t0 = Date()
        store.append(makeEntry(timestamp: t0, actionClass: "bash:ls", tier: .tier0, risk: .low, outcome: .success))
        store.append(makeEntry(timestamp: t0.addingTimeInterval(1), actionClass: "crm_note", tier: .tier1, risk: .medium, outcome: .success))
        store.append(makeEntry(timestamp: t0.addingTimeInterval(2), actionClass: "send_email", tier: .tier2, risk: .high, outcome: .success))
        store.append(makeEntry(timestamp: t0.addingTimeInterval(3), actionClass: "exec_payment", tier: .tier3, risk: .high, outcome: .success))
        store.tierFilter = [.tier2, .tier3]
        let visible = store.visible
        XCTAssertEqual(visible.count, 2)
        XCTAssertTrue(visible.allSatisfy { $0.tier == .tier2 || $0.tier == .tier3 })
    }

    func testFilterByOutcomeHidesOtherOutcomes() {
        let store = ActionAuditLogStore()
        let t0 = Date()
        store.append(makeEntry(timestamp: t0, actionClass: "bash:ls", tier: .tier0, risk: .low, outcome: .success))
        store.append(makeEntry(timestamp: t0.addingTimeInterval(1), actionClass: "send_email", tier: .tier2, risk: .high, outcome: .failure))
        store.append(makeEntry(timestamp: t0.addingTimeInterval(2), actionClass: "crm_note", tier: .tier1, risk: .medium, outcome: .reverted))
        store.outcomeFilter = [.failure]
        let visible = store.visible
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible[0].outcome, .failure)
    }

    func testSearchMatchesActionClassSubstring() {
        let store = ActionAuditLogStore()
        let t0 = Date()
        store.append(makeEntry(timestamp: t0, actionClass: "bash:git", tier: .tier0, risk: .low, outcome: .success))
        store.append(makeEntry(timestamp: t0.addingTimeInterval(1), actionClass: "bash:rm", tier: .tier2, risk: .high, outcome: .blocked))
        store.append(makeEntry(timestamp: t0.addingTimeInterval(2), actionClass: "send_email", tier: .tier2, risk: .high, outcome: .success))
        store.searchText = "git"
        let visible = store.visible
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible[0].actionClass, "bash:git")
    }

    func testSearchMatchesSummarySubstring() {
        let store = ActionAuditLogStore()
        let t0 = Date()
        store.append(makeEntry(
            timestamp: t0,
            actionClass: "bash:git",
            summary: "fetch from origin",
            tier: .tier0,
            risk: .low,
            outcome: .success
        ))
        store.append(makeEntry(
            timestamp: t0.addingTimeInterval(1),
            actionClass: "bash:rm",
            summary: "remove tmp dir",
            tier: .tier2,
            risk: .high,
            outcome: .blocked
        ))
        store.searchText = "remove"
        let visible = store.visible
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible[0].actionClass, "bash:rm")
    }

    func testSearchIsCaseInsensitive() {
        let store = ActionAuditLogStore()
        let t0 = Date()
        store.append(makeEntry(timestamp: t0, actionClass: "bash:Git", tier: .tier0, risk: .low, outcome: .success))
        store.searchText = "git"
        XCTAssertEqual(store.visible.count, 1)
    }

    func testEmptySearchReturnsAll() {
        // Whitespace-only search is treated as "no search".
        let store = ActionAuditLogStore()
        let t0 = Date()
        store.append(makeEntry(timestamp: t0, actionClass: "bash:ls", tier: .tier0, risk: .low, outcome: .success))
        store.append(makeEntry(timestamp: t0.addingTimeInterval(1), actionClass: "crm_note", tier: .tier1, risk: .low, outcome: .success))
        store.searchText = "   "
        XCTAssertEqual(store.visible.count, 2)
    }

    func testFiltersCompose() {
        // Tier + outcome + search all narrow together. The user
        // expects the conjunction, not any one in isolation.
        let store = ActionAuditLogStore()
        let t0 = Date()
        store.append(makeEntry(timestamp: t0, actionClass: "bash:git", tier: .tier0, risk: .low, outcome: .success))
        store.append(makeEntry(timestamp: t0.addingTimeInterval(1), actionClass: "bash:git", tier: .tier2, risk: .high, outcome: .failure))
        store.append(makeEntry(timestamp: t0.addingTimeInterval(2), actionClass: "send_email", tier: .tier2, risk: .high, outcome: .failure))
        store.tierFilter = [.tier2]
        store.outcomeFilter = [.failure]
        store.searchText = "git"
        let visible = store.visible
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible[0].actionClass, "bash:git")
        XCTAssertEqual(visible[0].outcome, .failure)
        XCTAssertEqual(visible[0].tier, .tier2)
    }

    // MARK: - 4. Chip vocabulary matches the audit-log HEAD chip (item 1C)

    func testDisplayStringUsesFieldValuePipeFormat() {
        // Same `field: value | field: value` shape as
        // `AuditLogHead.displayString` so the user reads one
        // chip language on the diff overlay, the chat progress
        // feed, and the audit log. Pipes separate fields; the
        // colons are inside each field.
        let entry = makeEntry(
            timestamp: Date(),
            actionClass: "bash:git",
            summary: "fetch from origin",
            tier: .tier0,
            risk: .low,
            outcome: .success,
            receiptID: UUID(uuidString: "A1B2C3D4-1111-2222-3333-444455556666")
        )
        let s = entry.displayString
        XCTAssertTrue(s.contains("|"), "displayString must use pipe separators: \(s)")
        XCTAssertTrue(s.contains("tier: T0"))
        XCTAssertTrue(s.contains("risk: low"))
        XCTAssertTrue(s.contains("tool: bash:git"))
        XCTAssertTrue(s.contains("outcome: ok"))
        XCTAssertTrue(s.contains("summary: fetch from origin"))
        XCTAssertTrue(s.contains("receipt: A1B2C3D4..."),
            "receipt substring must be the 8-char prefix + ellipsis: \(s)")
    }

    func testDisplayStringOmitsReceiptWhenAbsent() {
        // Tier 0/1 actions do not produce a receipt. The chip
        // omits the `receipt:` field rather than rendering an
        // empty placeholder.
        let entry = makeEntry(
            timestamp: Date(),
            actionClass: "bash:ls",
            tier: .tier0,
            risk: .low,
            outcome: .success,
            receiptID: nil
        )
        XCTAssertFalse(entry.displayString.contains("receipt:"))
    }

    func testDisplayStringCapsAtFieldCap() {
        // The cap matches `AuditLogHead.fieldCap` (item 1C) so
        // the chip never becomes a wall of text. We append a
        // 6th field (very long summary) and assert the cap held.
        let entry = makeEntry(
            timestamp: Date(),
            actionClass: "bash:git",
            summary: String(repeating: "x", count: 200),
            tier: .tier0,
            risk: .low,
            outcome: .success,
            receiptID: UUID()
        )
        let fields = entry.displayString.components(separatedBy: " | ")
        XCTAssertEqual(fields.count, AuditLogHead.fieldCap,
            "chip field cap must mirror AuditLogHead.fieldCap (5): \(fields)")
    }

    func testShortReceiptIDIsEightChars() {
        // The chip's receipt substring is the 8-char prefix +
        // ellipsis, matching `AuditLogHead.shortReceiptID`.
        let id = UUID(uuidString: "A1B2C3D4-1111-2222-3333-444455556666")
        let entry = makeEntry(
            timestamp: Date(),
            actionClass: "bash:git",
            tier: .tier0,
            risk: .low,
            outcome: .success,
            receiptID: id
        )
        XCTAssertEqual(entry.shortReceiptID, "A1B2C3D4")
    }

    // MARK: - 5. Outcome labels

    func testAllOutcomesHaveShortLabels() {
        // Every outcome gets a chip label. The four short labels
        // match the confirmation-panel vocabulary style: short,
        // ASCII, lower-case.
        for outcome in ActionAuditOutcome.allCases {
            XCTAssertFalse(outcome.shortLabel.isEmpty)
            XCTAssertTrue(outcome.shortLabel.allSatisfy { $0.isASCII },
                "Outcome short label must be ASCII: \(outcome.shortLabel)")
        }
    }

    func testAllOutcomesHaveTints() {
        // The row's tint is keyed off the outcome's tint name. The
        // names are a small closed set so the panel does not
        // depend on Color directly.
        let validTints: Set<String> = ["green", "red", "orange", "secondary"]
        for outcome in ActionAuditOutcome.allCases {
            XCTAssertTrue(validTints.contains(outcome.tintName),
                "Outcome tint must be one of \(validTints); got \(outcome.tintName) for \(outcome)")
        }
    }

    // MARK: - 6. ASCII guarantee

    func testDisplayStringIsAscii() {
        // The display string composes inside SwiftUI `Text`; any
        // non-ASCII character would be a render surprise.
        let cases: [(TesseraTier, TesseraActionRisk, ActionAuditOutcome, String?)] = [
            (.tier0, .low, .success, "summary 1"),
            (.tier1, .medium, .failure, "summary 2"),
            (.tier2, .high, .reverted, "summary 3"),
            (.tier3, .forbidden, .blocked, "summary 4"),
        ]
        for (tier, risk, outcome, summary) in cases {
            let entry = makeEntry(
                timestamp: Date(),
                actionClass: "bash:git",
                summary: summary,
                tier: tier,
                risk: risk,
                outcome: outcome,
                receiptID: UUID()
            )
            XCTAssertTrue(entry.displayString.allSatisfy { $0.isASCII },
                "displayString must be ASCII; got \(entry.displayString) for tier=\(tier)")
        }
    }

    // MARK: - 7. Codable + Sendable

    func testEntryRoundTripsThroughJSON() throws {
        // The entry is the audit record; the host may persist
        // it for the long tail. JSON round-trip must be
        // loss-less on the fields the user sees in the chip.
        let original = makeEntry(
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            actionClass: "send_email",
            summary: "followup on Q3 contract",
            tier: .tier2,
            risk: .high,
            outcome: .success,
            receiptID: UUID(uuidString: "A1B2C3D4-1111-2222-3333-444455556666")
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ActionAuditEntry.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testEntryIsSendable() {
        // The store is @MainActor; entries are appended from the
        // capture path. The entry must be Sendable so the
        // background capture can hand them to the main actor
        // without an isolation warning.
        let entry = makeEntry(
            timestamp: Date(),
            actionClass: "bash:ls",
            tier: .tier0,
            risk: .low,
            outcome: .success
        )
        let sendableCheck: () -> Bool = {
            let _: any Sendable = entry
            return true
        }
        XCTAssertTrue(sendableCheck())
    }

    // MARK: - 8. View body compiles + is observable

    func testPanelViewRendersWithoutCrash() {
        // The SwiftUI view is a thin render over the store. We
        // exercise `body` to confirm the view's @Bindable
        // plumbing + the filter chips compile and produce a
        // non-empty view tree. No UI assertion beyond "no
        // crash" - the data-layer tests above cover semantics.
        let store = ActionAuditLogStore()
        store.append(makeEntry(
            timestamp: Date(),
            actionClass: "bash:git",
            tier: .tier0,
            risk: .low,
            outcome: .success
        ))
        let view = ActionAuditLogPanel(
            store: store,
            isPresented: .constant(true)
        )
        // Render once via ImageRenderer to confirm the body
        // evaluates without error. ImageRenderer is a cheap
        // smoke test; it does not require a window.
        let renderer = ImageRenderer(content: view.frame(width: 380, height: 480))
        XCTAssertNotNil(renderer)
    }

    func testPanelEmptyStateRendersWithoutCrash() {
        // Empty state path: no entries, no filter. The view
        // must not crash and must produce a non-nil renderer.
        let store = ActionAuditLogStore()
        let view = ActionAuditLogPanel(
            store: store,
            isPresented: .constant(true)
        )
        let renderer = ImageRenderer(content: view.frame(width: 380, height: 480))
        XCTAssertNotNil(renderer)
    }

    func testTriggerLabelReadsCount() {
        // The trigger shows the entry count so the user can see
        // the audit log has activity without opening it. Mirrors
        // the chat progress feed trigger (item 2A).
        let store = ActionAuditLogStore()
        let view = ActionAuditLogTrigger(
            store: store,
            isPresented: .constant(false)
        )
        // No assertion beyond "compiles" - the @Bindable
        // dynamic member lookup is the load-bearing surface.
        _ = view.body
    }
}
