#if os(iOS)
import SwiftUI
import SwiftData
import TesseraCore

/// iOS Studio shell: tab bar (Library / Chat / Intelligence / Email /
/// Settings) with first-run onboarding, a chat-history sheet, and a
/// telemetry drawer. The single-agent Playground has been replaced by the
/// unified Tessy + Sky chat (Part D wires the StateGraph-backed surface).
struct ContentView: View {
    @AppStorage(TesseraSettingsKey.onboardingComplete) private var onboardingComplete = false
    @Environment(\.modelContext) private var modelContext

    @State private var telemetryMonitor = TelemetryMonitor(
        bridge: TesseraEngineBridgeFactory.makeInferenceBridge()
    )
    @State private var telemetryExpanded = false
    @State private var showHistory = false
    @State private var exportItem: ExportItem?
    // Email surface state (Phase 5). Same
    // lazy-bootstrap pattern as the macOS
    // ``EmailSurfaceBootstrap``; the
    // iOS-side ``EmailView_iOS`` is
    // constructed once the user opens the
    // Email tab.
    @State private var emailSurface = EmailSurfaceBootstrap_iOS()

    var body: some View {
        TabView {
            NavigationStack {
                LibraryView()
            }
            .tabItem { Label("Library", systemImage: "books.vertical") }

            NavigationStack {
                VStack(spacing: 0) {
                    // Part D: UnifiedChatSurface hosting the StateGraph-backed
                    // UnifiedChatController (shared with the macOS dock).
                    ContentUnavailableView(
                        "Tessy + Sky",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("The unified chat lands here.")
                    )
                    TelemetryDrawer(monitor: telemetryMonitor, isExpanded: $telemetryExpanded)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("History", systemImage: "sidebar.left") { showHistory = true }
                    }
                }
            }
            .tabItem { Label("Chat", systemImage: "bubble.left.and.text.bubble.right") }

            NavigationStack {
                // Part F builds the cohesive Intelligence view.
                ContentUnavailableView(
                    "Intelligence",
                    systemImage: "brain.head.profile",
                    description: Text("AI configuration and machinery lands here.")
                )
            }
            .tabItem { Label("Intelligence", systemImage: "brain.head.profile") }

            NavigationStack {
                emailSurface.installIfNeeded()
                EmailView_iOS(
                    store: emailSurface.store,
                    sender: emailSurface.sender,
                    importer: emailSurface.importer,
                    identity: emailSurface.identity
                )
            }
            .tabItem { Label("Email", systemImage: "envelope") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(isPresented: $showHistory) {
            NavigationStack {
                ChatHistoryDrawer(
                    isPresented: $showHistory,
                    onRestore: { convo in restore(convo) },
                    onExport: { convo, format in exportConversation(convo, format: format) }
                )
            }
        }
        .sheet(item: $exportItem) { item in
            ExportView(item: item)
        }
        .fullScreenCover(isPresented: Binding(
            get: { !onboardingComplete },
            set: { onboardingComplete = !$0 }
        )) {
            OnboardingView()
        }
    }

    private func restore(_ convo: Conversation) {
        // Part D: hand the conversation off to the UnifiedChatController.
        showHistory = false
    }

    private func exportConversation(_ convo: Conversation, format: ExportFormat) {
        let messages = ConversationStore.messages(for: convo.id, in: modelContext)
        let base = slug(convo.title)
        switch format {
        case .markdown:
            let md = ConversationExporter.markdown(title: convo.title, messages: messages)
            exportItem = ExportItem(title: convo.title, filename: "\(base).md", data: Data(md.utf8))
        case .json:
            let js = ConversationExporter.json(title: convo.title, messages: messages)
            exportItem = ExportItem(title: convo.title, filename: "\(base).json", data: Data(js.utf8))
        case .pdf:
            let pdf = ConversationExporter.pdf(title: convo.title, messages: messages)
            exportItem = ExportItem(title: convo.title, filename: "\(base).pdf", data: pdf)
        case .png:
            let transcript = VStack(alignment: .leading, spacing: 12) {
                Text(convo.title).font(.headline)
                ForEach(messages) { message in
                    ChatBubbleView(message: message)
                }
            }
            .padding()
            .frame(width: 360)
            .background(.white)
            let renderer = ImageRenderer(content: transcript)
            renderer.scale = 2
            if let image = renderer.uiImage,
               let png = image.pngData() {
                exportItem = ExportItem(title: convo.title, filename: "\(base).png", data: png)
            }
        }
    }

    private func slug(_ title: String) -> String {
        let cleaned = title.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return cleaned.isEmpty ? "conversation" : String(cleaned.prefix(48))
    }
}
#endif
