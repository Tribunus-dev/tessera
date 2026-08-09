import SwiftUI
import SwiftData
import AppKit
import TesseraCore

/// macOS Studio shell: a grouped split-view sidebar (Work / Knowledge / Connect
/// / Agents / System) with a leading chat-history drawer, a bottom telemetry
/// drawer, first-run onboarding, and export. The productivity surfaces are
/// lazy-bootstrapped on first navigation so app launch stays cheap.
struct ContentView: View {
    @AppStorage(TesseraSettingsKey.onboardingComplete) private var onboardingComplete = false
    @Environment(\.modelContext) private var modelContext

    // Per-window scene restoration (HIG 2.5). SwiftUI persists
    // these when the window closes or the app quits and restores
    // them on relaunch; every window keeps its own copy. The
    // destination is stored as its raw string because
    // @SceneStorage needs a RawRepresentable/String-compatible
    // value, and Optional<Destination> is not one.
    @SceneStorage("ContentView.destination") private var storedDestinationRaw: String?
    @SceneStorage("ContentView.telemetryExpanded") private var telemetryExpanded = false

    @State private var agentLoop = TesseraAgentLoop(
        registry: TesseraToolRegistry.default,
        approvalEngine: TesseraApprovalEngine(),
        llmProvider: TesseraLLMProviderFactory.makeFromSettings(),
        maxIterations: TesseraSettings.maxIterations,
        tokenLimit: TesseraSettings.tokenBudget
    )
    @State private var showHistory = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var telemetryMonitor = TelemetryMonitor(
        bridge: TesseraEngineBridgeFactory.makeInferenceBridge()
    )
    @State private var restoredMessages: [ChatMessage] = []
    @State private var playgroundSession = UUID()
    @State private var exportItem: ExportItem?
    // Scene-lived workflow editor state. The detail column is
    // rebuilt on every destination switch, destroying view-local
    // @State; the store lives here (one per window, lifetime =
    // the scene) so in-flight edits, the save baseline, and a
    // running run survive the switch. WorkflowsView is a shell
    // over it and is recreated freely.
    @State private var workflowEditor = WorkflowEditorStore()
    // Per-window identity for the Learning-surface visibility tally
    // (training runs are global, so the ping decision looks across
    // all windows; see LearningSurfaceTracker).
    @State private var windowID = UUID()
    // Email surface state (Phase 5). The data layer is
    // shared with the rest of the productivity
    // surface; the email store is a thin wrapper
    // around it. The data layer is created lazily
    // on first access (when the user opens the
    // Email destination) so app launch is not
    // gated on Postgres.
    @State private var emailSurface = EmailSurfaceBootstrap()
    // Productivity surface bootstraps. Each is lazy: the data layer (and its
    // Postgres connect) only happens on first navigation to that surface.
    @State private var notesSurface = NotesSurfaceBootstrap()
    @State private var docsSurface = DocsSurfaceBootstrap()
    @State private var sheetsSurface = SheetsSurfaceBootstrap()
    @State private var slidesSurface = SlidesSurfaceBootstrap()
    @State private var codeSurface = CodeSurfaceBootstrap()
    @State private var tasksSurface = TasksSurfaceBootstrap()
    @State private var contactsSurface = ContactsSurfaceBootstrap()
    @State private var remindersSurface = RemindersSurfaceBootstrap()
    @State private var calendarSurface = CalendarSurfaceBootstrap()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        // HIG 4.1: keep the nested split views from collapsing to
        // nothing; the window can still grow past the default size.
        .frame(minWidth: 900, minHeight: 560)
        .overlay(alignment: .leading) {
            if showHistory {
                historyDrawer
                    .transition(.move(edge: .leading))
            }
        }
        .sheet(item: $exportItem) { item in
            ExportView(item: item)
        }
        .sheet(isPresented: Binding(
            get: { !onboardingComplete },
            set: { onboardingComplete = !$0 }
        )) {
            OnboardingView()
        }
        .onChange(of: agentLoop.isRunning) { _, running in
            if running {
                telemetryMonitor.start()
            } else {
                telemetryMonitor.stop()
            }
        }
        // Publish the telemetry drawer toggle to the focused scene
        // so View > Show/Hide Telemetry can reach it from any
        // destination.
        .focusedSceneValue(\.telemetryMenuActions, TelemetryMenuActions(
            toggle: { withAnimation(reduceMotion ? nil : .default) { telemetryExpanded.toggle() } },
            isExpanded: { telemetryExpanded }
        ))
        // Runs are scene-lived, so one can reach a terminal outcome
        // while its own window is showing another destination. Keep
        // the editor store told whether the Workflows surface is on
        // screen so the completion ping fires exactly when the user
        // is NOT looking at the result (see WorkflowRunNotifier).
        .onChange(of: selection, initial: true) { _, newValue in
            workflowEditor.workflowsSurfaceVisible = (newValue == .workflows)
            LearningSurfaceTracker.shared.setVisible(newValue == .learning, for: windowID)
        }
        .onDisappear {
            // A closed window must not keep claiming the Learning
            // surface is visible; drop its tally entry.
            LearningSurfaceTracker.shared.setVisible(false, for: windowID)
        }
    }

    /// Current sidebar destination. Falls back to the Playground
    /// on first launch (nothing stored yet) and whenever a stored
    /// value no longer parses (a destination renamed or removed
    /// between versions degrades to the default, not a crash).
    private var selection: Destination? {
        storedDestinationRaw.flatMap(Destination.init(rawValue:)) ?? .playground
    }

    private var selectionBinding: Binding<Destination?> {
        Binding(
            get: { selection },
            set: { storedDestinationRaw = $0?.rawValue }
        )
    }

    private var sidebar: some View {
        List(selection: selectionBinding) {
            ForEach(SidebarGroup.allCases) { group in
                Section(group.rawValue) {
                    ForEach(group.destinations) { dest in
                        Label(dest.rawValue, systemImage: dest.icon)
                            .tag(dest)
                    }
                }
            }
        }
        .navigationTitle("Tessera Studio")
        .frame(minWidth: 180)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("History", systemImage: "sidebar.left") {
                    withAnimation(reduceMotion ? nil : .default) { showHistory.toggle() }
                }
                .help("Show or hide the chat history drawer")
                .accessibilityHint("Shows or hides the chat history drawer")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            detailContent
            TelemetryDrawer(monitor: telemetryMonitor, isExpanded: $telemetryExpanded)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .playground:
            PlaygroundView(agentLoop: agentLoop, restoredMessages: restoredMessages)
                .id(playgroundSession)
        case .dualAgent:
            DualAgentChatView()
        case .workflows:
            WorkflowsView(editor: workflowEditor)
        case .tasks:
            TasksView(store: tasksSurface.store)
                .onAppear { tasksSurface.installIfNeeded() }
        case .calendar:
            CalendarSurfaceView(model: calendarSurface.viewModel)
                .onAppear { calendarSurface.installIfNeeded() }
        case .library:
            LibraryView()
        case .runs:
            RunsView()
        case .learning:
            LearningDashboardView()
        case .notes:
            NotesView(viewModel: notesSurface.viewModel)
                .onAppear { notesSurface.installIfNeeded() }
        case .code:
            CodeSurfaceView(viewModel: codeSurface.viewModel)
                .onAppear { codeSurface.installIfNeeded() }
        case .docs:
            DocsListView(viewModel: docsSurface.viewModel)
                .onAppear { docsSurface.installIfNeeded() }
        case .sheets:
            SheetsListView(viewModel: sheetsSurface.viewModel)
                .onAppear { sheetsSurface.installIfNeeded() }
        case .slides:
            SlidesListView(viewModel: slidesSurface.viewModel)
                .onAppear { slidesSurface.installIfNeeded() }
        case .email:
            EmailView(
                store: emailSurface.store,
                sender: emailSurface.sender,
                importer: emailSurface.importer,
                identity: emailSurface.identity
            )
            .onAppear { emailSurface.installIfNeeded() }
        case .contacts:
            ContactsView(store: contactsSurface.store, importer: contactsSurface.importer)
                .onAppear { contactsSurface.installIfNeeded() }
        case .reminders:
            RemindersView(store: remindersSurface.store, scheduler: remindersSurface.scheduler)
                .onAppear { remindersSurface.installIfNeeded() }
        case .collab:
            CollabTraceView()
        case .capacity:
            CapacityView()
        case nil:
            ContentUnavailableView(
                "Select a destination",
                systemImage: "sidebar.left",
                description: Text("Choose a destination from the sidebar to begin.")
            )
        }
    }

    private var historyDrawer: some View {
        ChatHistoryDrawer(
            isPresented: $showHistory,
            onRestore: { convo in restore(convo) },
            onExport: { convo, format in exportConversation(convo, format: format) }
        )
        .frame(width: 300)
        .clipShape(RoundedRectangle(cornerRadius: 0))
        .shadow(radius: 8)
    }

    private func restore(_ convo: Conversation) {
        restoredMessages = ConversationStore.messages(for: convo.id, in: modelContext)
        playgroundSession = UUID()
        storedDestinationRaw = Destination.playground.rawValue
        withAnimation(reduceMotion ? nil : .default) { showHistory = false }
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
            // Render the transcript as a SwiftUI stack and snapshot it.
            let transcript = VStack(alignment: .leading, spacing: 12) {
                Text(convo.title).font(.headline)
                ForEach(messages) { message in
                    ChatBubbleView(message: message)
                }
            }
            .padding()
            .frame(width: 720)
            .background(.white)
            let renderer = ImageRenderer(content: transcript)
            renderer.scale = 2
            if let nsImage = renderer.nsImage,
               let tiff = nsImage.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
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
