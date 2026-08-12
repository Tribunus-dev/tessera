import SwiftUI

/// Destination-aware curated starter prompts for the empty chat surface.
///
/// Review #1 of the agent-ux-fatigue Tessera Studio audit identified the
/// empty chat (macOS dock placeholder, iOS ContentUnavailableView, and
/// LibraryView empty state) as the empty-canvas paradox: an "ask me
/// anything" surface with no entry point. The fix is a 3-5 prompt list
/// keyed off the current sidebar `Destination`, so the user lands on a
/// guided first task instead of a blank input.
///
/// Tapping a starter fires `onSelect(prompt)`. The caller wires the
/// closure to fill the chat's `inputText` and call `send()` (the existing
/// macOS dock path at ``UnifiedChatDock.send``); no new plumbing is
/// required.

public struct DestinationStarterPrompts {

    /// A context the prompt list is keyed off. Mirrors the macOS sidebar's
    /// `Destination` so each prompt list lands on a guided first task; lives
    /// here in `TesseraCore` so the iOS chat tab and the `LibraryView` empty
    /// state can use the same data source without coupling to the macOS-only
    /// sidebar type. The macOS app maps `Destination -> Context` at the call
    /// site.
    public enum Context: Equatable, Sendable {
        case workflows
        case tasks
        case calendar
        case notes
        case code
        case docs
        case sheets
        case slides
        case email
        case contacts
        case reminders
        case collab
        case intelligence
        /// No destination context (iOS chat tab, LibraryView, dock fallback).
        case neutral
    }

    /// A single curated starter prompt for a context.
    public struct Prompt: Identifiable, Equatable, Sendable {
        public let id: String
        public let text: String
        public let symbol: String
    }

    /// The header line shown above the list. Captures the "you can type your
    /// own too" reassurance without legal-copying the disclosure into a
    /// sentence the user has to read.
    public static let headerLine = "Pick a starting task or type your own."

    /// The "What's next?" line shown after the first message, so the empty
    /// surface never reappears as a permanent fixture (review #1 guardrail:
    /// suggestions collapse once the user has moved past the empty state).
    public static let whatsNextLine = "What's next?"

    /// Prompts for each context. Returns 3-5 entries for every case; tests
    /// pin the count and uniqueness per context.
    public static func prompts(for context: Context) -> [Prompt] {
        switch context {
        case .workflows:    workflows
        case .tasks:        tasks
        case .calendar:     calendar
        case .notes:        notes
        case .code:         code
        case .docs:         docs
        case .sheets:       sheets
        case .slides:       slides
        case .email:        email
        case .contacts:     contacts
        case .reminders:    reminders
        case .collab:       collab
        case .intelligence: intelligence
        case .neutral:      neutral
        }
    }

    // Per-context prompt arrays. Kept as static lets so a context's list
    // lives next to its own surface, the team owns the array in code
    // review, and tests can assert counts and uniqueness.

    private static let workflows: [Prompt] = [
        Prompt(id: "workflows.wire", text: "Wire a Calibrate node to the next model in the queue.", symbol: "rectangle.connected.to.line.below"),
        Prompt(id: "workflows.suggest", text: "Suggest a 3-node starter workflow for a small model.", symbol: "wand.and.stars"),
        Prompt(id: "workflows.run", text: "Run the last workflow and report the metric.", symbol: "play.fill"),
        Prompt(id: "workflows.explain", text: "Explain what each existing node does.", symbol: "questionmark.circle"),
    ]

    private static let tasks: [Prompt] = [
        Prompt(id: "tasks.summarize", text: "Summarize today's open tasks by due date.", symbol: "checklist"),
        Prompt(id: "tasks.suggest", text: "Suggest three tasks I should add for the week.", symbol: "plus.circle"),
        Prompt(id: "tasks.prioritize", text: "Re-prioritize my top 5 tasks.", symbol: "arrow.up.arrow.down"),
        Prompt(id: "tasks.blockers", text: "Flag tasks that look blocked on someone else.", symbol: "exclamationmark.triangle"),
    ]

    private static let calendar: [Prompt] = [
        Prompt(id: "calendar.today", text: "Brief me on today's meetings.", symbol: "calendar"),
        Prompt(id: "calendar.week", text: "What's the busiest window this week?", symbol: "clock"),
        Prompt(id: "calendar.gap", text: "Find a 60-minute gap tomorrow for focused work.", symbol: "moonphase.waxing.gibbous"),
        Prompt(id: "calendar.conflicts", text: "List overlapping events I should reschedule.", symbol: "exclamationmark.triangle"),
    ]

    private static let notes: [Prompt] = [
        Prompt(id: "notes.summarize", text: "Summarize the last paragraph of this note.", symbol: "note.text"),
        Prompt(id: "notes.outline", text: "Turn this note into a bulleted outline.", symbol: "list.bullet"),
        Prompt(id: "questions", text: "What questions does this note leave open?", symbol: "questionmark.circle"),
    ]

    private static let code: [Prompt] = [
        Prompt(id: "code.imports", text: "Explain this file's imports.", symbol: "curlybraces"),
        Prompt(id: "code.todos", text: "List the TODO comments in this directory.", symbol: "checklist"),
        Prompt(id: "code.recent", text: "Summarize the most recent commit on the current branch.", symbol: "clock.arrow.circlepath"),
        Prompt(id: "code.tests", text: "Which files in this folder have no test coverage?", symbol: "questionmark.diamond"),
    ]

    private static let docs: [Prompt] = [
        Prompt(id: "docs.recent", text: "Show the three most recently edited documents.", symbol: "doc.text"),
        Prompt(id: "docs.summary", text: "Summarize the open document in 3 sentences.", symbol: "text.alignleft"),
        Prompt(id: "docs.table", text: "Convert the current selection into a table.", symbol: "tablecells"),
    ]

    private static let sheets: [Prompt] = [
        Prompt(id: "sheets.formulas", text: "Add SUM and AVERAGE formulas to the open sheet.", symbol: "tablecells"),
        Prompt(id: "sheets.chart", text: "Suggest a chart for the visible data.", symbol: "chart.bar"),
        Prompt(id: "sheets.anomalies", text: "Flag any rows that look anomalous.", symbol: "exclamationmark.triangle"),
    ]

    private static let slides: [Prompt] = [
        Prompt(id: "slides.outline", text: "Outline a 5-slide deck from this topic.", symbol: "rectangle.on.rectangle.angled"),
        Prompt(id: "slides.summary", text: "Shorten the speaker notes on this slide.", symbol: "text.bubble"),
        Prompt(id: "slides.qa", text: "List questions an audience would ask about this deck.", symbol: "questionmark.circle"),
    ]

    private static let email: [Prompt] = [
        Prompt(id: "email.draft", text: "Draft a reply to the newest message.", symbol: "envelope"),
        Prompt(id: "email.triage", text: "Triage the inbox into 3 priority buckets.", symbol: "tray.full"),
        Prompt(id: "email.followup", text: "Draft polite follow-ups for messages older than 7 days.", symbol: "clock"),
    ]

    private static let contacts: [Prompt] = [
        Prompt(id: "contacts.duplicates", text: "Find contacts I may have duplicated.", symbol: "person.crop.circle.badge.person"),
        Prompt(id: "contacts.recent", text: "Show the 5 contacts I emailed most this month.", symbol: "person.crop.circle"),
        Prompt(id: "contacts.missing", text: "Which contacts lack an email address?", symbol: "questionmark.circle"),
    ]

    private static let reminders: [Prompt] = [
        Prompt(id: "reminders.due", text: "List reminders due in the next 24 hours.", symbol: "bell.badge"),
        Prompt(id: "reminders.suggest", text: "Suggest 3 reminders based on this week's calendar.", symbol: "plus.circle"),
        Prompt(id: "reminders.snooze", text: "Snooze overdue reminders by one day.", symbol: "moon.zzz"),
    ]

    private static let collab: [Prompt] = [
        Prompt(id: "collab.explain", text: "When should I ask Tessy vs Sky?", symbol: "bubble.left.and.exclamationmark.bubble.right"),
        Prompt(id: "collab.handoff", text: "Walk me through how a handoff between Tessy and Sky works.", symbol: "arrow.left.arrow.right"),
        Prompt(id: "collab.example", text: "Show one example where both answered together.", symbol: "person.2"),
    ]

    private static let intelligence: [Prompt] = [
        Prompt(id: "intelligence.who", text: "Who am I letting make decisions on my behalf?", symbol: "brain.head.profile"),
        Prompt(id: "intelligence.budget", text: "Summarize this week's token spend by persona.", symbol: "gauge.with.needle"),
        Prompt(id: "intelligence.audit", text: "Show the last 5 actions Tessy took autonomously.", symbol: "list.bullet.clipboard"),
    ]

    private static let neutral: [Prompt] = [
        Prompt(id: "neutral.first", text: "Help me write a clear spec for the next thing I want to ship.", symbol: "square.and.pencil"),
        Prompt(id: "neutral.summarize", text: "Summarize the longest article in my Library.", symbol: "text.alignleft"),
        Prompt(id: "neutral.inbox", text: "Triage my email into 3 priority buckets.", symbol: "tray.full"),
        Prompt(id: "neutral.calendar", text: "Brief me on today's meetings.", symbol: "calendar"),
    ]
}

/// Reusable SwiftUI view that renders the destination-aware starter list.
/// Lives in ``TesseraCore`` so the macOS dock, the iOS chat tab, and the
/// `LibraryView` empty state can all use the same component.
public struct DestinationStarterPromptsList: View {
    public let context: DestinationStarterPrompts.Context
    public let onSelect: (String) -> Void

    public init(context: DestinationStarterPrompts.Context, onSelect: @escaping (String) -> Void) {
        self.context = context
        self.onSelect = onSelect
    }

    public var body: some View {
        let prompts = DestinationStarterPrompts.prompts(for: context)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .symbolRenderingMode(.hierarchical)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(DestinationStarterPrompts.headerLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(prompts) { prompt in
                    Button {
                        onSelect(prompt.text)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: prompt.symbol)
                                .symbolRenderingMode(.hierarchical)
                                .frame(width: 18)
                                .foregroundStyle(.secondary)
                            Text(prompt.text)
                                .font(.callout)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(prompt.text)
                    .accessibilityHint("Double tap to send this starter prompt")
                }
            }
        }
    }
}
