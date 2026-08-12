import XCTest
import Foundation
import CryptoKit
@testable import TesseraCore

/// Tests for the time-limited undo policy (review #5 follow-up,
/// item 2C of the implementation plan). The legacy
/// `AppKitUndoManagerBridge.levelsOfUndo = 100` cap is replaced
/// with a 90-second time cap. The tests cover the two acceptance
/// criteria:
///   1. ``TimeLimitedUndoBudget`` reports `isExpired == true`
///      once the top entry's age meets the cap. The bridge's
///      `canUndo` is the conjunction of "stack non-empty" and
///      "budget isAvailable".
///   2. The visible countdown is a continuous value
///      (``TimeLimitedUndoBudget/remainingSeconds`` /
///      ``TimeLimitedUndoBudget/progress(at:)``) that the
///      SwiftUI view animates with `.animation(.linear)`. The
///      test exercises the model that drives the view.
///
/// Lazy expiry is verified by injecting a controlled clock and
/// checking `isExpired` at a sequence of clock values -- there
/// is no timer, and the check is O(1) on each access.
///
/// Receipt chain semantics are untouched. The tests build a
/// `ReceiptUndoManager`, sign a real receipt, and register it;
/// the budget is computed from the receipt's `timestamp` via
/// the same path the bridge consults on every `canUndo` read.
final class TimeLimitedUndoTests: XCTestCase {

    // MARK: - Fixtures

    private var signer: ReceiptSigner!
    private var documentID: UUID!
    private var userID: UUID!

    override func setUp() {
        super.setUp()
        let key = Curve25519.Signing.PrivateKey()
        signer = ReceiptSigner(signingKey: key)
        documentID = UUID()
        userID = UUID()
    }

    /// Build a one-mutation receipt with a controlled timestamp.
    /// The timestamp is the receipt's "registered at" -- the
    /// same value the bridge reads on `canUndo` to compute the
    /// budget.
    private func makeReceipt(at timestamp: Date) throws -> Receipt {
        let block = Block(
            id: UUID(),
            type: .paragraph,
            content: [InlineRun(text: "x")]
        )
        return try signer.sign(
            documentID: documentID,
            mutations: [.setBlockContent(blockID: block.id, content: [InlineRun(text: "y")])],
            priorReceiptID: nil,
            actor: .user(userID),
            timestamp: timestamp
        )
    }

    /// A controlled clock. Each test creates a fresh one so the
    /// clock state is independent.
    private final class TestClock: @unchecked Sendable {
        private var current: Date
        init(at date: Date) { self.current = date }
        var now: Date { current }
        func advance(by seconds: TimeInterval) {
            current = current.addingTimeInterval(seconds)
        }
        var ticker: @Sendable () -> Date { { [weak self] in self?.now ?? Date() } }
    }

    // MARK: - testExpiry

    /// The acceptance criterion: undo entries older than the
    /// cap are expired. Build a budget with a 90-second cap,
    /// sign a receipt at t=0, advance the clock to t=100, and
    /// verify the budget reports `isExpired == true` and
    /// `isAvailable == false`.
    func testExpiry() throws {
        let clock = TestClock(at: Date(timeIntervalSince1970: 1_000_000))
        let policy = TimeLimitedUndoPolicy(cap: 90.0, clock: clock.ticker)
        let manager = ReceiptUndoManager(documentID: documentID)
        let receipt = try makeReceipt(at: clock.now)
        manager.register(receipt)

        // Build the budget the same way the bridge does.
        let top = manager.snapshotUndoStack().last
        let budget = TimeLimitedUndoBudget(registeredAt: top?.timestamp, policy: policy)

        // t=0: just registered, well within the cap.
        XCTAssertFalse(budget.isExpired)
        XCTAssertTrue(budget.isAvailable)
        XCTAssertEqual(budget.remainingSeconds, 90.0, accuracy: 0.0001)

        // Advance to t=89: still inside the cap (boundary check).
        clock.advance(by: 89)
        let nearBoundary = TimeLimitedUndoBudget(
            registeredAt: manager.snapshotUndoStack().last?.timestamp,
            policy: policy
        )
        XCTAssertFalse(nearBoundary.isExpired)
        XCTAssertTrue(nearBoundary.isAvailable)
        XCTAssertEqual(nearBoundary.remainingSeconds, 1.0, accuracy: 0.0001)

        // Advance to t=100: past the cap, expired.
        clock.advance(by: 11)
        let past = TimeLimitedUndoBudget(
            registeredAt: manager.snapshotUndoStack().last?.timestamp,
            policy: policy
        )
        XCTAssertTrue(past.isExpired)
        XCTAssertFalse(past.isAvailable)
        XCTAssertEqual(past.remainingSeconds, 0.0, accuracy: 0.0001)
    }

    // MARK: - testVisibleCountdown

    /// The acceptance criterion: the visible countdown is a
    /// continuous value (smooth animation, not 1 Hz text). The
    /// test exercises the model that drives the SwiftUI view:
    /// ``TimeLimitedUndoBudget/remainingSeconds(at:)`` and
    /// ``TimeLimitedUndoBudget/progress(at:)``.
    ///
    /// The chip reads `remainingSeconds` and `progress` on every
    /// body invocation; SwiftUI's `TimelineView(.animation)`
    /// drives the body and `.animation(.linear)` interpolates
    /// the value. The test verifies the values are continuous
    /// (no integer-only jumps) and that the label rounds down
    /// (so the user sees a count that ticks down, not up).
    func testVisibleCountdown() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(at: start)
        let policy = TimeLimitedUndoPolicy(cap: 90.0, clock: clock.ticker)
        let manager = ReceiptUndoManager(documentID: documentID)
        let receipt = try makeReceipt(at: clock.now)
        manager.register(receipt)

        func budgetAt(_ now: Date) -> TimeLimitedUndoBudget {
            TimeLimitedUndoBudget(
                registeredAt: manager.snapshotUndoStack().last?.timestamp,
                policy: policy
            )
        }

        // The countdown at t=0 is the full cap.
        let atStart = budgetAt(start)
        XCTAssertEqual(atStart.remainingSeconds(at: start), 90.0, accuracy: 0.0001)
        XCTAssertEqual(atStart.progress(at: start), 0.0, accuracy: 0.0001)
        XCTAssertEqual(atStart.remainingLabel(at: start), "90s")

        // The countdown at t=30 is 60s remaining, 1/3 elapsed.
        let t30 = start.addingTimeInterval(30)
        let at30 = budgetAt(t30)
        XCTAssertEqual(at30.remainingSeconds(at: t30), 60.0, accuracy: 0.0001)
        XCTAssertEqual(at30.progress(at: t30), 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(at30.remainingLabel(at: t30), "60s")

        // The countdown at t=60 is 30s remaining, 2/3 elapsed.
        let t60 = start.addingTimeInterval(60)
        let at60 = budgetAt(t60)
        XCTAssertEqual(at60.remainingSeconds(at: t60), 30.0, accuracy: 0.0001)
        XCTAssertEqual(at60.progress(at: t60), 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(at60.remainingLabel(at: t60), "30s")

        // The countdown at t=89 is 1s remaining (rounds down).
        let t89 = start.addingTimeInterval(89)
        let at89 = budgetAt(t89)
        XCTAssertEqual(at89.remainingSeconds(at: t89), 1.0, accuracy: 0.0001)
        XCTAssertEqual(at89.remainingLabel(at: t89), "1s")

        // The countdown at t=90 is 0s, fully elapsed.
        let t90 = start.addingTimeInterval(90)
        let at90 = budgetAt(t90)
        XCTAssertEqual(at90.remainingSeconds(at: t90), 0.0, accuracy: 0.0001)
        XCTAssertEqual(at90.progress(at: t90), 1.0, accuracy: 0.0001)
        XCTAssertEqual(at90.remainingLabel(at: t90), "0s")

        // The countdown at t=200 is still 0s (clamped).
        let t200 = start.addingTimeInterval(200)
        let at200 = budgetAt(t200)
        XCTAssertEqual(at200.remainingSeconds(at: t200), 0.0, accuracy: 0.0001)
        XCTAssertEqual(at200.progress(at: t200), 1.0, accuracy: 0.0001)

        // The countdown is CONTINUOUS: between two integer-second
        // marks the value is fractional. The SwiftUI view uses
        // this for the .animation(.linear) interpolation, not
        // a 1 Hz text tick.
        let t30_5 = start.addingTimeInterval(30.5)
        let at30_5 = budgetAt(t30_5)
        XCTAssertEqual(at30_5.remainingSeconds(at: t30_5), 59.5, accuracy: 0.0001)
    }

    // MARK: - Additional guards

    /// Default policy is 90 seconds. The implementation plan's
    /// acceptance criterion.
    func testDefaultPolicyCapIs90Seconds() {
        XCTAssertEqual(TimeLimitedUndoPolicy.default.cap, 90.0)
    }

    /// An empty budget is expired and not available. The
    /// SwiftUI view hides the chip on empty.
    func testEmptyBudgetIsExpired() {
        let budget = TimeLimitedUndoBudget.empty
        XCTAssertTrue(budget.isExpired)
        XCTAssertFalse(budget.isAvailable)
        XCTAssertEqual(budget.remainingSeconds, 0.0)
    }

    /// Lazy expiry: the budget does not capture the clock at
    /// construction; every read re-samples. The test creates
    /// a budget, advances the clock, and verifies the next
    /// read sees the new value (no timer / no cached value).
    func testExpiryIsLazy() {
        let clock = TestClock(at: Date(timeIntervalSince1970: 2_000_000))
        let policy = TimeLimitedUndoPolicy(cap: 60.0, clock: clock.ticker)
        let budget = TimeLimitedUndoBudget(registeredAt: clock.now, policy: policy)

        XCTAssertFalse(budget.isExpired)
        clock.advance(by: 61)
        XCTAssertTrue(budget.isExpired)
    }

    /// The label rounds DOWN: 89.9s shows as "89s", so the
    /// user sees a count that ticks down (not up) as time
    /// passes. The chip is not a 1 Hz text update -- the
    /// SwiftUI view animates the underlying value -- but the
    /// label format is the integer-second floor.
    func testRemainingLabelRoundsDown() {
        let start = Date(timeIntervalSince1970: 3_000_000)
        let policy = TimeLimitedUndoPolicy(cap: 90.0)
        let budget = TimeLimitedUndoBudget(registeredAt: start, policy: policy)
        XCTAssertEqual(budget.remainingLabel(at: start.addingTimeInterval(0.4)), "89s")
        XCTAssertEqual(budget.remainingLabel(at: start.addingTimeInterval(89.9)), "0s")
    }

    /// Receipt chain is preserved across expiry. The receipt
    /// stays on the undo stack; only the bridge's `canUndo`
    /// gate hides it. The test signs a receipt, registers it,
    /// advances the clock past the cap, and verifies the
    /// manager still reports the stack is non-empty (the
    /// chain is intact).
    func testReceiptChainPreservedAcrossExpiry() throws {
        let clock = TestClock(at: Date(timeIntervalSince1970: 4_000_000))
        let policy = TimeLimitedUndoPolicy(cap: 60.0, clock: clock.ticker)
        let manager = ReceiptUndoManager(documentID: documentID)
        let receipt = try makeReceipt(at: clock.now)
        manager.register(receipt)
        clock.advance(by: 120)
        // The receipt is still on the undo stack -- the audit
        // chain is the constitutional authority, untouched.
        XCTAssertTrue(manager.canUndo)
        XCTAssertEqual(manager.snapshotUndoStack().count, 1)
        // The budget says expired.
        let budget = TimeLimitedUndoBudget(
            registeredAt: manager.snapshotUndoStack().last?.timestamp,
            policy: policy
        )
        XCTAssertTrue(budget.isExpired)
        XCTAssertFalse(budget.isAvailable)
    }

    /// Progress is clamped to [0, 1]. A 90-second cap with a
    /// 200-second elapsed reads 1.0, not 2.22. The SwiftUI
    /// view's `ProgressView(value:)` expects the clamped
    /// value.
    func testProgressIsClamped() {
        let start = Date(timeIntervalSince1970: 5_000_000)
        let policy = TimeLimitedUndoPolicy(cap: 90.0)
        let budget = TimeLimitedUndoBudget(registeredAt: start, policy: policy)
        XCTAssertEqual(budget.progress(at: start.addingTimeInterval(200)), 1.0, accuracy: 0.0001)
        XCTAssertEqual(budget.progress(at: start.addingTimeInterval(-50)), 0.0, accuracy: 0.0001)
    }
}
