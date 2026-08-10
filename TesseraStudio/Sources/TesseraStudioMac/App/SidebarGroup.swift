import SwiftUI

/// Sidebar destinations for the Mac Studio shell. Productivity only — the
/// chat lives in the persistent right-edge dock (see ContentView), and AI
/// machinery is consolidated under Intelligence.
enum Destination: String, CaseIterable, Identifiable {
    // Work
    case workflows = "Workflows"
    case tasks = "Tasks"
    case calendar = "Calendar"
    // Knowledge
    case notes = "Notes"
    case code = "Code"
    case docs = "Docs"
    case sheets = "Sheets"
    case slides = "Slides"
    // Connect
    case email = "Email"
    case contacts = "Contacts"
    case reminders = "Reminders"
    // Agents
    case collab = "Tessy & Sky"
    // System
    case intelligence = "Intelligence"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .workflows: "rectangle.connected.to.line.below"
        case .tasks: "checklist"
        case .calendar: "calendar"
        case .notes: "note.text"
        case .code: "curlybraces"
        case .docs: "doc.text"
        case .sheets: "tablecells"
        case .slides: "rectangle.on.rectangle.angled"
        case .email: "envelope"
        case .contacts: "person.crop.circle.badge.person"
        case .reminders: "bell.badge"
        case .collab: "bubble.left.and.exclamationmark.bubble.right"
        case .intelligence: "brain.head.profile"
        }
    }
}

/// The grouped sidebar sections. Each section lists its destinations in
/// display order; the sidebar renders one `Section` per group.
enum SidebarGroup: String, CaseIterable, Identifiable {
    case work = "Work"
    case knowledge = "Knowledge"
    case connect = "Connect"
    case agents = "Agents"
    case system = "System"

    var id: String { rawValue }

    var destinations: [Destination] {
        switch self {
        case .work: [.workflows, .tasks, .calendar]
        case .knowledge: [.notes, .code, .docs, .sheets, .slides]
        case .connect: [.email, .contacts, .reminders]
        case .agents: [.collab]
        case .system: [.intelligence]
        }
    }

    var symbol: String {
        switch self {
        case .work: "hammer"
        case .knowledge: "books.vertical"
        case .connect: "network"
        case .agents: "sparkles"
        case .system: "gearshape.2"
        }
    }
}
