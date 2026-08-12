import Foundation
import os

/// Categories the budget tracks. Each consumer maps to one of these so
/// the per-UTC-day counter is shared across the two push notifiers and
/// the onFinished hooks (review #3 of the agent-ux-fatigue audit).
public enum TesseraNotificationCategory: String, Codable, Sendable {
    case workflow
    case training
    case adaptation
    case assessment
    case covert
    case wipeReport
    case reminder
}

/// One row in the JSONL log. Captures the attempt regardless of whether
/// the cap allowed it: blocked attempts are the audit trail the team
/// needs to see the cap engage in week 1.
public struct TesseraNotificationEvent: Codable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let utcDay: String
    public let category: String
    public let title: String
    public let body: String
    public let outcome: String?
    public let posted: Bool
    public let blockedReason: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        utcDay: String,
        category: String,
        title: String,
        body: String,
        outcome: String? = nil,
        posted: Bool,
        blockedReason: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.utcDay = utcDay
        self.category = category
        self.title = title
        self.body = body
        self.outcome = outcome
        self.posted = posted
        self.blockedReason = blockedReason
    }
}

/// Shared per-UTC-day cap for user-facing push notifications
/// (review #3, `03-proactive-notifications.md`). The cap is a HARD cap:
/// there is no `force:` override, no `categoryWeight`, no per-category
/// knob the planner can talk itself into. If a future use case genuinely
/// warrants a high-priority bypass, the architect approves a new
/// ``TesseraNotificationCategory`` enum case at the call site.
///
/// The actor is concurrency-safe: every read and write of the day and
/// the counter is serialised by the actor. The log file is written via
/// `Data.write(to:options: .atomic)` (full read-modify-write) so a
/// half-written row never lands on disk.
///
/// The budget respects ``TesseraSettings.telemetryEnabled``: when that
/// default is off, the budget still enforces the cap (the cap is a
/// product invariant, not a telemetry one) but skips the JSONL row so
/// nothing leaves the in-memory counter.
public actor TesseraNotificationBudget {
    public static let shared = TesseraNotificationBudget()

    /// Default cap. Hard; not a soft target. The skill
    /// (`references/pattern-catalog.md` lines 242-250) is explicit:
    /// the budget must be enforced as a hard cap, not a soft target.
    public static let defaultCapPerDay = 3

    /// JSONL log file name. Mirrors the `adaptation-records.json`
    /// convention at `TesseraAdaptationScheduler.swift:22` - the
    /// user's Application Support dir, named so the file is easy to
    /// find on disk for support cases.
    public static let logFileName = "tessera.notifications.log"

    /// Outcome strings that require ``devMode`` to be on to post. The
    /// review drops `.dryRun` from the postable set (the skill
    /// "anti-pattern: a notification that is not actionable in 15-30
    /// minutes"); the dev mode flag is the test-friendly escape hatch.
    public static let devModeOnlyOutcomes: Set<String> = ["dryRun"]

    private var currentDay: String = ""
    private var dailyCount: Int = 0
    private var devMode: Bool = false

    /// The cap. Public read so tests and a future settings UI can
    /// surface it; the underlying value is the constant.
    public nonisolated let capPerDay: Int

    private let logger = Logger(
        subsystem: "com.tessera.studio",
        category: "notification-budget"
    )

    public init(capPerDay: Int = TesseraNotificationBudget.defaultCapPerDay) {
        self.capPerDay = capPerDay
    }

    /// Directory the JSONL log lives in. Nonisolated so the
    /// inspection helper can read it without hopping the actor.
    public nonisolated static func logDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("TesseraStudio", isDirectory: true)
    }

    /// Full URL the JSONL log is written to.
    public nonisolated static func logFileURL() -> URL {
        logDirectory().appendingPathComponent(logFileName)
    }

    /// Toggle dev mode. Off by default. Public so tests can flip it
    /// without a settings round-trip; the production app leaves it
    /// alone.
    public func setDevMode(_ on: Bool) {
        devMode = on
    }

    /// Current dev-mode state. For tests.
    public func isDevMode() -> Bool {
        devMode
    }

    /// Number of posts that succeeded so far today. For tests + a
    /// future settings surface.
    public func deliveredToday() -> Int {
        rolloverIfNeeded()
        return dailyCount
    }

    /// Try to post a notification. Returns true if the cap allows it
    /// (and the outcome, if provided, is in the postable set). The
    /// caller posts the actual UN/NotificationCenter notification only
    /// when this returns true.
    ///
    /// The `outcome` argument is a free-form string. The budget only
    /// looks up the value in ``devModeOnlyOutcomes``; Learning types
    /// are not imported here to keep this file lean and free of
    /// cross-subsystem dependencies. The training scheduler passes
    /// `record.outcome.rawValue`.
    public func tryPost(
        category: TesseraNotificationCategory,
        title: String,
        body: String,
        outcome: String? = nil
    ) -> Bool {
        rolloverIfNeeded()
        let day = currentDay
        if let outcome, Self.devModeOnlyOutcomes.contains(outcome), !devMode {
            append(
                event: TesseraNotificationEvent(
                    utcDay: day,
                    category: category.rawValue,
                    title: title,
                    body: body,
                    outcome: outcome,
                    posted: false,
                    blockedReason: "outcome_requires_dev_mode"
                )
            )
            logger.notice("notification blocked: outcome_requires_dev_mode outcome=\(outcome, privacy: .public)")
            return false
        }
        if dailyCount >= capPerDay {
            append(
                event: TesseraNotificationEvent(
                    utcDay: day,
                    category: category.rawValue,
                    title: title,
                    body: body,
                    outcome: outcome,
                    posted: false,
                    blockedReason: "cap_exceeded"
                )
            )
            let countSnapshot = dailyCount
            let capSnapshot = capPerDay
            logger.notice("notification blocked: cap_exceeded day=\(day, privacy: .public) count=\(countSnapshot, privacy: .public) cap=\(capSnapshot, privacy: .public)")
            return false
        }
        dailyCount += 1
        append(
            event: TesseraNotificationEvent(
                utcDay: day,
                category: category.rawValue,
                title: title,
                body: body,
                outcome: outcome,
                posted: true,
                blockedReason: nil
            )
        )
        return true
    }

    /// Test helper: roll the per-UTC-day counter forward by `dayDelta`
    /// days so tests can assert the reset behaviour without a real
    /// clock. Negative values are not supported.
    public func advanceDay(by dayDelta: Int) {
        guard dayDelta > 0 else { return }
        rolloverIfNeeded()
        let formatter = isoDayFormatter
        guard let base = formatter.date(from: currentDay) else { return }
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.day = dayDelta
        let advanced = calendar.date(byAdding: components, to: base) ?? base
        currentDay = formatter.string(from: advanced)
        dailyCount = 0
    }

    // MARK: - Internals

    /// If the wall clock has moved into a new UTC day, reset the
    /// counter. Called at the top of every read or write so the
    /// counter is never "stale" from a midnight-rollover perspective.
    private func rolloverIfNeeded() {
        let day = isoDayFormatter.string(from: Date())
        if day != currentDay {
            currentDay = day
            dailyCount = 0
        }
    }

    /// Append a single JSONL row. The full file is read, the new
    /// line is concatenated, and the result is written back with
    /// `.atomic`. This is more expensive than a streaming append but
    /// guarantees no partial row lands on disk: a notification log
    /// where half a row is readable is worse than one with a slightly
    /// higher write cost.
    private func append(event: TesseraNotificationEvent) {
        guard TesseraSettings.telemetryEnabled else { return }
        let dir = Self.logDirectory()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let url = dir.appendingPathComponent(Self.logFileName)
        let line: String
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(event)
            let json = String(decoding: data, as: UTF8.self)
            line = json + "\n"
        } catch {
            return
        }
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let combined = existing + line
        try? combined.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private let isoDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// Test-only inspection surface. Lets the test target read the JSONL
/// log without depending on the actor's internal state. Kept separate
/// from the actor so the production call surface stays small.
public enum TesseraNotificationBudgetLog {
    public static func events() -> [TesseraNotificationEvent] {
        let url = TesseraNotificationBudget.logFileURL()
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let row = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(TesseraNotificationEvent.self, from: row)
            }
    }

    /// Delete the log file. Used by tests to start from a clean slate.
    public static func reset() {
        try? FileManager.default.removeItem(at: TesseraNotificationBudget.logFileURL())
    }
}
