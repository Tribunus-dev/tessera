import Foundation

// MARK: - TimeLimitedUndoPolicy

/// Time-based cap on undo, replacing the legacy `levelsOfUndo = 100`
/// depth cap. Undo entries older than ``cap`` are expired: the receipt
/// remains in the audit chain (the constitutional authority is
/// untouched), but the user can no longer reach it via Cmd-Z.
///
/// **Default 90 seconds.** The skill cites a ~30-second modal
/// attention span and recommends a 90-second default to cover the
/// tail (see `references/pattern-catalog.md` "Time-Limited Undo").
/// The default is the constant on this type; a future settings
/// surface can read it from ``TesseraSettings`` and pass an
/// override.
///
/// **Lazy expiry.** The cap is checked on every read of
/// ``TimeLimitedUndoBudget/isExpired`` or
/// ``TimeLimitedUndoBudget/remainingSeconds(at:)``; there is no
/// timer. The check is O(1) and a no-op on a hot loop; a timer
/// would wake the app just to discover nothing changed.
///
/// **Per-action-class time limits are explicitly out of scope.**
/// The cap is global; per-tier variation is a follow-up. The
/// constraint is documented in the implementation plan (2C:
// Time-limited undo, review #5 follow-up).
public struct TimeLimitedUndoPolicy: Sendable {
    /// Maximum age of an undo entry, in seconds. Negative or
    /// zero values are not meaningful; the budget treats them as
    /// "everything is expired."
    public let cap: TimeInterval

    /// Clock injection. Tests pass a controlled clock; production
    /// uses `Date()`. The closure must be `Sendable` because the
    /// policy is consumed from a `@MainActor` UI surface.
    public let clock: @Sendable () -> Date

    public init(
        cap: TimeInterval,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cap = cap
        self.clock = clock
    }

    /// Default policy: 90-second cap, real wall clock.
    public static let `default` = TimeLimitedUndoPolicy(cap: 90.0)
}

// MARK: - TimeLimitedUndoBudget

/// State of the visible "Undo available for Ns" affordance. The
/// countdown is a continuous `remaining: TimeInterval` value that
/// the SwiftUI view animates with `.animation(.linear)` -- a
/// smooth ease, not a 1 Hz text tick (the implementation plan's
/// explicit constraint).
///
/// The budget is a value type: the bridge rebuilds one on every
/// `canUndo` read and the SwiftUI view interpolates the
/// `remainingSeconds` continuously. No timer, no main-loop
/// coupling.
public struct TimeLimitedUndoBudget: Sendable {
    /// The moment the current top undo entry was registered. The
    /// bridge derives this from the top receipt's `timestamp` (the
    /// receipt carries the time the edit happened). `nil` when
    /// the undo stack is empty.
    public let registeredAt: Date?

    /// The policy that decides expiry. Stored so the SwiftUI view
    /// can read the cap for the visible label.
    public let policy: TimeLimitedUndoPolicy

    public init(registeredAt: Date?, policy: TimeLimitedUndoPolicy) {
        self.registeredAt = registeredAt
        self.policy = policy
    }

    /// No undo entry, no budget. The SwiftUI view renders nothing
    /// in this case.
    public static let empty = TimeLimitedUndoBudget(
        registeredAt: nil,
        policy: .default
    )

    /// True when there is no entry, or when the entry's age meets
    /// or exceeds the cap. Lazy: the clock is consulted at call
    /// time, not at registration time.
    public var isExpired: Bool {
        guard let registeredAt else { return true }
        return policy.clock().timeIntervalSince(registeredAt) >= policy.cap
    }

    /// True when there is an undo entry AND it has not yet
    /// expired. The bridge's `canUndo` returns this.
    public var isAvailable: Bool {
        guard let registeredAt else { return false }
        return policy.clock().timeIntervalSince(registeredAt) < policy.cap
    }

    /// Seconds remaining (>= 0) until the undo expires, computed
    /// at call time. Returns 0 when expired or when there is no
    /// entry. Suitable for an animated SwiftUI view that re-reads
    /// the value on every body invocation.
    public var remainingSeconds: TimeInterval {
        guard let registeredAt else { return 0 }
        return remainingSeconds(at: policy.clock())
    }

    /// Seconds remaining at a specific clock value. The test path
    /// uses this; the SwiftUI view uses ``remainingSeconds``.
    public func remainingSeconds(at now: Date) -> TimeInterval {
        guard let registeredAt else { return 0 }
        let elapsed = now.timeIntervalSince(registeredAt)
        return max(0, policy.cap - elapsed)
    }

    /// Fraction of the cap that has elapsed (0..1, clamped). The
    /// SwiftUI view uses this for a shrinking bar or a progress
    /// ring -- one continuous value that animates smoothly.
    public func progress(at now: Date) -> Double {
        guard let registeredAt, policy.cap > 0 else { return 0 }
        let elapsed = now.timeIntervalSince(registeredAt)
        return min(1.0, max(0.0, elapsed / policy.cap))
    }

    /// Human-readable label for the remaining time, e.g. "78s"
    /// or "0s". The SwiftUI view uses this for the visible
    /// affordance; the label is rounded down so the user sees a
    /// count that ticks down (not up) as time passes.
    public func remainingLabel(at now: Date) -> String {
        let s = Int(remainingSeconds(at: now).rounded(.down))
        return "\(s)s"
    }
}
