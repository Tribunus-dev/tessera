import SwiftUI

/// Sidebar destinations for the Mac Studio shell. Extended from the original
/// 6-destination flat list to a grouped layout that surfaces the productivity
/// Materials + the dual-agent chat. Mirrors the Linux app's grouped nav
/// (Work/Knowledge/Connect/Agents/System).
enum Destination: String, CaseIterable, Identifiable {
    // Work
    case playground = "Playground"
    case dualAgent = "Tessy + Sky"
    case workflows = "Workflows"
    case tasks = "Tasks"
    case calendar = "Calendar"
    // Knowledge
    case library = "Library"
    case runs = "Runs"
    case learning = "Learning"
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
    case capacity = "Capacity"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .playground: "bubble.left.and.text.bubble.right"
        case .dualAgent: "person.2.wave.2"
        case .workflows: "rectangle.connected.to.line.below"
        case .tasks: "checklist"
        case .calendar: "calendar"
        case .library: "books.vertical"
        case .runs: "clock.arrow.circlepath"
        case .learning: "chart.bar.doc.horizontal"
        case .notes: "note.text"
        case .code: "curlybraces"
        case .docs: "doc.text"
        case .sheets: "tablecells"
        case .slides: "rectangle.on.rectangle.angled"
        case .email: "envelope"
        case .contacts: "person.crop.circle.badge.person"
        case .reminders: "bell.badge"
        case .collab: "bubble.left.and.exclamationmark.bubble.right"
        case .capacity: "gauge.with.dots.needle.67percent"
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
        case .work: [.playground, .dualAgent, .workflows, .tasks, .calendar]
        case .knowledge: [.library, .runs, .learning, .notes, .code, .docs, .sheets, .slides]
        case .connect: [.email, .contacts, .reminders]
        case .agents: [.collab]
        case .system: [.capacity]
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
