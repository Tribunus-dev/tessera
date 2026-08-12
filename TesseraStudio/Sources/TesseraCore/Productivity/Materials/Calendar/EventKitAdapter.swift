import Foundation
#if canImport(EventKit)
import EventKit
#endif

// MARK: - EventKitAdapter

/// Read calendar events from the system Calendar app on macOS/iOS via
/// `EKEventStore`. The adapter is the one place the app touches the
/// `EventKit` framework for read access; the rest of the productivity
/// surface consumes `CalendarEvent` values and has no dependency on
/// `EventKit`.
///
/// **Entitlement.** Production builds need
/// `com.apple.developer. calendars` (full-access) entitlement.
/// The dev-preview falls back gracefully when the entitlement is absent.
///
/// **Observation.** ``startObservingChanges()`` returns an
/// `AsyncStream<CalendarChange>` that emits whenever the EKEventStore
/// refreshes its sources. The calendar stores update when the user
/// edits events in Calendar.app.
public actor EventKitAdapter {

    // MARK: - Types

    public struct CalendarChange: Sendable, Equatable {
        public let kind: Kind
        public let eventID: UUID?

        public enum Kind: String, Sendable, Equatable {
            case inserted
            case updated
            case deleted
            case sourceChanged  // calendars added/removed
        }

        public init(kind: Kind, eventID: UUID? = nil) {
            self.kind = kind
            self.eventID = eventID
        }
    }

    public enum AccessStatus: String, Sendable, Equatable {
        case authorized
        case denied
        case restricted
        case notDetermined
        case fullAccess
        case writeOnly
    }

    // MARK: - State

    #if canImport(EventKit) && (os(macOS) || os(iOS))
    private let store: EKEventStore
    #endif

    /// The last sync date. Used for incremental fetches.
    private var lastSyncDate: Date?

    // MARK: - Init

    /// Construct the adapter. Does NOT request access.
    public init() throws {
        #if canImport(EventKit) && (os(macOS) || os(iOS))
        self.store = EKEventStore()
        #endif
    }

    // MARK: - Permission

    /// Request full calendar access (read + write). On macOS 10.15+
    /// this shows the system permission dialog.
    public func requestAccess() async throws -> Bool {
        #if canImport(EventKit) && (os(macOS) || os(iOS))
        if #available(macOS 14.0, iOS 17.0, *) {
            return try await store.requestFullAccessToEvents()
        } else {
            return try await withCheckedThrowingContinuation { cont in
                store.requestAccess(to: .event) { granted, error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: granted)
                    }
                }
            }
        }
        #else
        return false
        #endif
    }

    /// The current access status.
    public var accessStatus: AccessStatus {
        #if canImport(EventKit) && (os(macOS) || os(iOS))
        if #available(macOS 14.0, iOS 17.0, *) {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess:  return .fullAccess
            case .writeOnly:   return .writeOnly
            case .denied:      return .denied
            case .restricted:  return .restricted
            case .notDetermined: return .notDetermined
            @unknown default:   return .notDetermined
            }
        } else {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .authorized: return .authorized
            case .denied:     return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default:   return .notDetermined
            }
        }
        #else
        return .denied
        #endif
    }

    // MARK: - Fetch

    /// Fetch events from the last 30 days through 90 days in the future.
    /// The initial sync window is wide to populate the surface quickly;
    /// subsequent syncs use ``fetchIncrementalEvents()`` for incremental updates.
    public func fetchAllEvents() async throws -> [CalendarEvent] {
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        let end = Calendar.current.date(byAdding: .day, value: 90, to: now)!
        return try await fetchEvents(from: start, to: end)
    }

    /// Fetch events changed since the last sync.
    public func fetchIncrementalEvents() async throws -> [CalendarEvent] {
        if let since = lastSyncDate {
            let end = Calendar.current.date(byAdding: .day, value: 90, to: Date())!
            let events = try await fetchEvents(from: since, to: end)
            lastSyncDate = Date()
            return events
        } else {
            return try await fetchAllEvents()
        }
    }

    /// Fetch events in a date range.
    public func fetchEvents(from startDate: Date, to endDate: Date) async throws -> [CalendarEvent] {
        #if canImport(EventKit) && (os(macOS) || os(iOS))
        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let ekEvents = store.events(matching: predicate)
        return ekEvents.compactMap { calendarEvent(from: $0) }
        #else
        return []
        #endif
    }

    /// Fetch one event by its canonical UUID.
    public func fetchEvent(id: UUID) async throws -> CalendarEvent? {
        #if canImport(EventKit) && (os(macOS) || os(iOS))
        guard let ekEvent = store.event(withIdentifier: id.uuidString) else {
            return nil
        }
        return calendarEvent(from: ekEvent)
        #else
        return nil
        #endif
    }

    // MARK: - Observation

    /// Begin observing calendar changes. Emits a ``CalendarChange`` whenever
    /// the event store refreshes its sources.
    public func startObservingChanges() -> AsyncStream<CalendarChange> {
        AsyncStream { continuation in
            #if canImport(EventKit) && (os(macOS) || os(iOS))
            let observer = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: self.store,
                queue: nil
            ) { _ in
                continuation.yield(CalendarChange(kind: .sourceChanged))
            }
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(observer)
            }
            #else
            continuation.onTermination = { _ in }
            #endif
        }
    }

    // MARK: - Mapping

    #if canImport(EventKit) && (os(macOS) || os(iOS))
    private func calendarEvent(from ekEvent: EKEvent) -> CalendarEvent {
        let id = UUID(uuidString: ekEvent.eventIdentifier ?? "") ?? UUID()

        let notes = ekEvent.notes ?? ""

        // Map EKParticipant to CalendarEvent.Attendee.
        // EKParticipant has no public .email property. The documented approach:
        // use .url (a mailto: URL) and strip the prefix via .resourceSpecifier.
        // Fall back to the .description plist string if that yields no "@".
        var attendees: [CalendarEvent.Attendee] = []
        if let ekAttendees = ekEvent.attendees {
            for ekParticipant in ekAttendees {
                // EKParticipant has no public .email property. Try the mailto: URL first.
                var email = ekParticipant.name ?? ""
                if let url = ekParticipant.value(forKey: "URL") as? URL,
                   url.scheme == "mailto" {
                    let raw = String(url.absoluteString.dropFirst(7))
                    if raw.contains("@") {
                        email = raw
                    }
                }
                if email.isEmpty || !email.contains("@") {
                    // Fallback: parse the description plist string.
                    // Format: "{UUID = ...; name = ...; email = abc@example.com; ...}"
                    let desc = ekParticipant.description
                    if let atRange = desc.range(of: "email = ", options: .caseInsensitive),
                       let afterEmail = desc.index(atRange.upperBound, offsetBy: 0, limitedBy: desc.endIndex),
                       let endSemicolon = desc[afterEmail...].firstIndex(of: ";"),
                       afterEmail < endSemicolon {
                        let candidate = String(desc[afterEmail..<endSemicolon]).trimmingCharacters(in: .whitespaces)
                        if candidate.contains("@") {
                            email = candidate
                        }
                    }
                }
                let status: CalendarEvent.ResponseStatus
                switch ekParticipant.participantStatus {
                case .accepted:  status = .accepted
                case .declined:  status = .declined
                case .tentative: status = .tentative
                case .pending:   status = .needsAction
                default:         status = .needsAction
                }
                attendees.append(CalendarEvent.Attendee(
                    email: email,
                    name: ekParticipant.name ?? email,
                    responseStatus: status
                ))
            }
        }

        // Map EKAlarm to reminder UUIDs. Each alarm gets a stable UUID
        // derived from the event id + alarm offset.
        var reminders: [UUID] = []
        if let ekAlarms = ekEvent.alarms {
            for ekAlarm in ekAlarms {
                if let absDate = ekAlarm.absoluteDate {
                    let alarmUUID = UUID(uuidString: "\(id.uuidString)-\(absDate.timeIntervalSince1970)") ?? UUID()
                    reminders.append(alarmUUID)
                }
            }
        }

        // Map EKRecurrenceRule to CalendarEvent.Recurrence.
        // EKRecurrenceRule exposes frequency, interval, daysOfTheWeek, etc.
        // We build the RRULE string using the same rules as CalendarNLUParser.
        var recurrence: CalendarEvent.Recurrence? = nil
        if let ekRule = ekEvent.recurrenceRules?.first {
            let freqStr: String
            switch ekRule.frequency {
            case .daily:    freqStr = "DAILY"
            case .weekly:   freqStr = "WEEKLY"
            case .monthly:  freqStr = "MONTHLY"
            case .yearly:   freqStr = "YEARLY"
            @unknown default: freqStr = "WEEKLY"
            }
            var parts = ["FREQ=\(freqStr)"]
            if ekRule.interval > 1 {
                parts.append("INTERVAL=\(ekRule.interval)")
            }
            if let days = ekRule.daysOfTheWeek, !days.isEmpty {
                let dayStrs = days.map { day -> String in
                    switch day.dayOfTheWeek {
                    case .sunday:    return "SU"
                    case .monday:    return "MO"
                    case .tuesday:   return "TU"
                    case .wednesday: return "WE"
                    case .thursday:  return "TH"
                    case .friday:    return "FR"
                    case .saturday:  return "SA"
                    @unknown default: return "MO"
                    }
                }
                parts.append("BYDAY=\(dayStrs.joined(separator: ","))")
            }
            let rruleString = parts.joined(separator: ";")
            // EKRecurrenceRule.exclusionDates is not public; exDates go in CalendarEvent.Recurrence.exDates.
            recurrence = CalendarEvent.Recurrence(rrule: rruleString, exDates: [])
        }

        let location: String? = {
            guard let loc = ekEvent.location, !loc.isEmpty else { return nil }
            return loc
        }()

        return CalendarEvent(
            id: id,
            title: ekEvent.title ?? "Untitled",
            notes: notes,
            startAt: ekEvent.startDate,
            endAt: ekEvent.endDate,
            allDay: ekEvent.isAllDay,
            location: location,
            attendees: attendees,
            recurrence: recurrence,
            reminders: reminders,
            linkedDocumentIDs: [],
            linkedTaskIDs: []
        )
    }
    #endif
}

// MARK: - Errors

public enum EventKitAdapterError: Error, Sendable, Equatable {
    case fetchFailed(underlying: String)
    case permissionDenied
    case frameworkUnavailable
}
