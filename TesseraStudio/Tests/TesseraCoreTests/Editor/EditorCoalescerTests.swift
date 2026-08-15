import XCTest
@testable import TesseraCore

// MARK: - EditorCoalescerTests
//
// Contract: EditorCoalescer.swift's own doc comments - "A burst is a
// sequence of edits that arrive within coalesceWindow seconds of each
// other... When the window expires... the coalescer flushes its pending
// mutations"; "the coalescer does not concatenate mutations across
// edits... Coalesce: keep the most recent mutation... The previous
// pending mutations are stale"; `Settings.coalesceWindow` - "Clamp to the
// architect-specified range" (0.5-5.0s).
//
// SCOPE: the timer-driven auto-flush (DispatchSourceTimer firing after
// `coalesceWindow` real seconds) is NOT exercised here - it would require
// a real wall-clock sleep, which this doctrine's rule 4 explicitly warns
// against depending on in assertions. Every test below drives the
// coalescer through its deterministic, synchronous surface: `append(...)`
// followed by an explicit `flush()` call, never waiting on the timer.
// This still exercises the actual coalescing DECISION logic (same-burst
// vs new-burst) doctrine rule 11 cares about; only the "did the timer
// literally fire after N wall-clock seconds" question is left untested,
// and is noted as a gap in docs/.scratch/test-rewrite-findings-writer.md
// rather than silently skipped.

final class EditorCoalescerTests: DoctrineTestCase {

    // MARK: - Settings clamping

    func testSettingsClampsCoalesceWindowToTheArchitectSpecifiedRange() {
        XCTAssertEqual(EditorCoalescer.Settings(coalesceWindow: 0.1).coalesceWindow, 0.5, "below the floor clamps up to 0.5s")
        XCTAssertEqual(EditorCoalescer.Settings(coalesceWindow: 10).coalesceWindow, 5.0, "above the ceiling clamps down to 5.0s")
        XCTAssertEqual(EditorCoalescer.Settings(coalesceWindow: 2.0).coalesceWindow, 2.0, "an in-range value passes through unchanged")
    }

    func testDefaultSettingsCoalesceWindowIs1point5Seconds() {
        XCTAssertEqual(EditorCoalescer.Settings.default.coalesceWindow, 1.5)
    }

    // MARK: - hasPending

    func testHasPendingFalseBeforeAnyAppend() {
        let coalescer = EditorCoalescer()
        XCTAssertFalse(coalescer.hasPending)
    }

    func testHasPendingTrueAfterAppendAndFalseAfterFlush() {
        let coalescer = EditorCoalescer()
        coalescer.append(mutation: .setDocumentTitle(title: "x"), blockID: UUID(), documentID: UUID(), queueMessage: "edited")
        XCTAssertTrue(coalescer.hasPending)
        _ = coalescer.flush()
        XCTAssertFalse(coalescer.hasPending, "flush must clear the pending burst")
    }

    // MARK: - flush() with nothing pending

    func testFlushWithNothingPendingReturnsNil() {
        let coalescer = EditorCoalescer()
        XCTAssertNil(coalescer.flush())
    }

    // MARK: - Coalescing: same document + same block + within window -> keeps only the LATEST mutation

    func testAppendingTwiceToTheSameBlockWithinTheWindowKeepsOnlyTheLatestMutation() {
        let coalescer = EditorCoalescer()
        let documentID = UUID()
        let blockID = UUID()
        let firstMutation = Mutation.setBlockContent(blockID: blockID, content: [InlineRun(text: "h")])
        let secondMutation = Mutation.setBlockContent(blockID: blockID, content: [InlineRun(text: "he")])

        coalescer.append(mutation: firstMutation, blockID: blockID, documentID: documentID, queueMessage: "typed h")
        coalescer.append(mutation: secondMutation, blockID: blockID, documentID: documentID, queueMessage: "typed he")

        let burst = coalescer.flush()
        XCTAssertEqual(burst?.mutations, [secondMutation], "the coalesced burst must carry only the MOST RECENT mutation, not a concatenation of every edit in the burst")
        XCTAssertEqual(burst?.queueItem.message, "typed he", "the queue message must reflect the latest edit's description")
    }

    func testCoalescedBurstCarriesTheDocumentAndBlockIDs() {
        let coalescer = EditorCoalescer()
        let documentID = UUID()
        let blockID = UUID()
        coalescer.append(mutation: .setDocumentTitle(title: "x"), blockID: blockID, documentID: documentID, queueMessage: "edit")
        let burst = coalescer.flush()
        XCTAssertEqual(burst?.documentID, documentID)
        XCTAssertEqual(burst?.blockID, blockID)
    }

    func testCoalescedBurstsQueueItemIsPreAppliedWithTheSourceMutationAttached() {
        let coalescer = EditorCoalescer()
        let mutation = Mutation.setDocumentTitle(title: "x")
        coalescer.append(mutation: mutation, blockID: UUID(), documentID: UUID(), queueMessage: "edit")
        let burst = coalescer.flush()
        XCTAssertEqual(burst?.queueItem.state, .applied, "a coalesced editor burst is already applied - the queue item records history, it doesn't gate anything")
        XCTAssertEqual(burst?.queueItem.sourceMutation, mutation)
    }

    // MARK: - A different BLOCK starts a fresh burst immediately (flushing the old one first)

    func testAppendingToADifferentBlockFlushesThePreviousBurstAndStartsAFreshOne() {
        let coalescer = EditorCoalescer()
        let documentID = UUID()
        let blockA = UUID()
        let blockB = UUID()

        var flushedBursts: [EditorCoalescer.CoalescedBurst] = []
        let observer = NotificationCenter.default.addObserver(forName: EditorCoalescer.didFlushNotification, object: coalescer, queue: nil) { note in
            if let burst = note.userInfo?["burst"] as? EditorCoalescer.CoalescedBurst {
                flushedBursts.append(burst)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        coalescer.append(mutation: .setDocumentTitle(title: "a"), blockID: blockA, documentID: documentID, queueMessage: "edit A")
        coalescer.append(mutation: .setDocumentTitle(title: "b"), blockID: blockB, documentID: documentID, queueMessage: "edit B")

        XCTAssertEqual(flushedBursts.count, 1, "switching blocks must flush the PREVIOUS burst (block A) via the same didFlushNotification path flush() uses")
        XCTAssertEqual(flushedBursts.first?.blockID, blockA)

        // The new burst (block B) is still pending; flushing it now must
        // return exactly block B's edit, proving the two bursts never merged.
        let secondBurst = coalescer.flush()
        XCTAssertEqual(secondBurst?.blockID, blockB)
    }

    // MARK: - A different DOCUMENT also starts a fresh burst

    func testAppendingToADifferentDocumentStartsAFreshBurst() {
        let coalescer = EditorCoalescer()
        let blockID = UUID()
        let firstDocument = UUID()
        let secondDocument = UUID()

        coalescer.append(mutation: .setDocumentTitle(title: "a"), blockID: blockID, documentID: firstDocument, queueMessage: "doc A edit")
        coalescer.append(mutation: .setDocumentTitle(title: "b"), blockID: blockID, documentID: secondDocument, queueMessage: "doc B edit")

        let burst = coalescer.flush()
        XCTAssertEqual(burst?.documentID, secondDocument, "the pending burst after switching documents must belong to the NEW document, not a merge of both")
    }

    // MARK: - updateSettings

    func testUpdateSettingsChangesTheEffectiveCoalesceWindow() {
        let coalescer = EditorCoalescer(settings: .default)
        coalescer.updateSettings(EditorCoalescer.Settings(coalesceWindow: 3.0))
        XCTAssertEqual(coalescer.coalesceWindow, 3.0)
    }
}
