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

    // The persistent Tessy+Sky chat dock. Window-lived so it survives
    // navigation across every productivity surface. Runs the chat as a
    // StateGraph (UnifiedChatController); the transcript persists across
    // destination switches.
    @State private var chatController = UnifiedChatController()
    @State private var chatFocus = ChatFocusCoordinator()
    @State private var chatDockVisible = true
    @State private var showHistory = false
    // Progress Feed (review #2, agent-ux-fatigue): the chat-dock
    // progress feed is pull-to-open. The binding is the single
    // pull surface; nothing on the controller flips it. The
    // toolbar item below is the only trigger; the feed never
    // auto-presents and the dock never pushes it.
    @State private var progressFeedPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var telemetryMonitor = TelemetryMonitor(
        bridge: TesseraEngineBridgeFactory.makeInferenceBridge()
    )
    @State private var exportItem: ExportItem?
    // Scene-lived workflow editor state. The detail column is
    // rebuilt on every destination switch, destroying view-local
    // @State; the store lives here (one per window, lifetime =
    // the scene) so in-flight edits, the save baseline, and a
    // running run survive the switch. WorkflowsView is a shell
    // over it and is recreated freely.
    @State private var workflowEditor = WorkflowEditorStore()
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
        // Productivity surfaces need real width beside the persistent
        // chat dock (Code alone is 3-column); keep the window generous.
        .frame(minWidth: 1280, minHeight: 560)
        .overlay(alignment: .leading) {
            if showHistory {
                historyDrawer
                    .transition(.move(edge: .leading))
            }
        }
        .sheet(item: $exportItem) { item in
            ExportView(item: item)
        }
        // Progress Feed sheet (review #2): the only pull surface
        // for the agent activity feed. The sheet is bound to
        // `progressFeedPresented`; the controller never flips it.
        // The host (this view) is the only authority; the chat
        // thread is untouched and the receipts drawer is not
        // auto-opened. The keyboard shortcut is on the toolbar
        // trigger; the sheet itself does not capture Escape to
        // close, so a runaway Escape press cannot dismiss the
        // chat (the chat is in a different sheet scope if the
        // user has one open).
        .sheet(isPresented: $progressFeedPresented) {
            ChatProgressFeed(
                controller: chatController,
                isPresented: $progressFeedPresented
            )
            .frame(minWidth: 420, minHeight: 360)
        }
        .sheet(isPresented: Binding(
            get: { !onboardingComplete },
            set: { onboardingComplete = !$0 }
        )) {
            OnboardingView()
        }
        // Publish the telemetry drawer toggle to the focused scene
        // so View > Show/Hide Telemetry can reach it from any
        // destination.
        .focusedSceneValue(\.telemetryMenuActions, TelemetryMenuActions(
            toggle: { withAnimation(reduceMotion ? nil : .default) { telemetryExpanded.toggle() } },
            isExpanded: { telemetryExpanded }
        ))
        // Bridge the focus coordinator into the chat controller. Surfaces
        // write to `chatFocus` on selection change; the controller reads its
        // `documentContext` to augment prompts. This keeps the Mac-only
        // coordinator out of the TesseraCore controller (layer boundary).
        .onChange(of: chatFocus.focusedDocumentContext?.documentID, initial: true) { _, _ in
            chatController.setDocumentContext(chatFocus.focusedDocumentContext)
        }
        .onChange(of: chatFocus.focusHint, initial: true) { _, hint in
            // Non-document focus: clear any document context so the prompt is
            // augmented with the plain hint instead.
            if hint != nil { chatController.setDocumentContext(nil) }
        }
        // Runs are scene-lived, so one can reach a terminal outcome
        // while its own window is showing another destination. Keep
        // the editor store told whether the Workflows surface is on
        // screen so the completion ping fires exactly when the user
        // is NOT looking at the result (see WorkflowRunNotifier).
        .onChange(of: selection, initial: true) { _, newValue in
            workflowEditor.workflowsSurfaceVisible = (newValue == .workflows)
        }
        // Wire the telemetry monitor into the chat controller so the
        // first send emits the time-to-first-message event (review #1
        // measurement architecture). Done once on appear; the monitor
        // is owned by the window so per-window timing is correct.
        .onAppear {
            chatController.telemetryMonitor = telemetryMonitor
            chatController.recordOnboardingCompletion()
        }
    }

    /// Current sidebar destination. Falls back to Workflows on first
    /// launch and whenever a stored value no longer parses.
    private var selection: Destination? {
        storedDestinationRaw.flatMap(Destination.init(rawValue:)) ?? .workflows
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
                            .accessibilityLabel("\(group.rawValue), \(dest.rawValue)")
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
                .accessibilityLabel("Chat history")
                .accessibilityHint("Double tap to show or hide the chat history drawer")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Chat", systemImage: "sidebar.right") {
                    withAnimation(reduceMotion ? nil : .default) { chatDockVisible.toggle() }
                }
                .help("Show or hide the Tessy + Sky chat dock")
                .accessibilityLabel(chatDockVisible ? "Hide chat dock" : "Show chat dock")
                .accessibilityHint("Double tap to show or hide the Tessy and Sky chat dock")
                .keyboardShortcut("\\", modifiers: .command)
            }
            // Progress Feed trigger (review #2): the only pull
            // surface for the agent activity feed. The toolbar is
            // its home so the user always knows where to find it;
            // nothing on the controller opens the feed. The
            // keyboard shortcut mirrors the dock toggle so a
            // keyboard-first user can pull the feed without the
            // toolbar. `ChatProgressFeedTrigger` is itself a
            // Button, so the toolbar item is the trigger.
            ToolbarItem(placement: .primaryAction) {
                ChatProgressFeedTrigger(
                    controller: chatController,
                    isPresented: $progressFeedPresented
                )
                .help("Show the agent's activity feed (pull surface)")
                .accessibilityLabel("Agent activity feed")
                .accessibilityHint("Pulls up the agent's routing, tool calls, approvals, hold queue, and team-up handoffs.")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            detailContent
            TelemetryDrawer(monitor: telemetryMonitor, isExpanded: $telemetryExpanded)
        }
        // Persistent Tessy+Sky chat dock on the right edge. Sibling of the
        // surface switch so it survives navigation. WWDC23 Inspectors: attach
        // inside the detail column. The controller is window-lived so the
        // transcript persists across destination switches.
        .inspector(isPresented: $chatDockVisible) {
            UnifiedChatDock(controller: chatController, starterContext: DestinationStarterPrompts.Context(selection))
                .inspectorColumnWidth(min: 320, ideal: 360, max: 480)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .workflows:
            WorkflowsView(editor: workflowEditor)
        case .tasks:
            TasksView(store: tasksSurface.store, chatFocus: chatFocus)
                .onAppear { tasksSurface.installIfNeeded() }
        case .calendar:
            CalendarSurfaceView(model: calendarSurface.viewModel, chatFocus: chatFocus)
                .onAppear { calendarSurface.installIfNeeded() }
        case .notes:
            NotesView(viewModel: notesSurface.viewModel, chatFocus: chatFocus)
                .onAppear { notesSurface.installIfNeeded() }
        case .code:
            CodeSurfaceView(viewModel: codeSurface.viewModel, chatFocus: chatFocus)
                .onAppear { codeSurface.installIfNeeded() }
        case .docs:
            DocsListView(viewModel: docsSurface.viewModel, chatFocus: chatFocus)
                .onAppear { docsSurface.installIfNeeded() }
        case .sheets:
            SheetsListView(viewModel: sheetsSurface.viewModel, chatFocus: chatFocus)
                .onAppear { sheetsSurface.installIfNeeded() }
        case .slides:
            SlidesListView(viewModel: slidesSurface.viewModel, chatFocus: chatFocus)
                .onAppear { slidesSurface.installIfNeeded() }
        case .email:
            EmailView(
                store: emailSurface.store,
                sender: emailSurface.sender,
                importer: emailSurface.importer,
                identity: emailSurface.identity,
                chatFocus: chatFocus
            )
            .onAppear { emailSurface.installIfNeeded() }
        case .contacts:
            ContactsView(store: contactsSurface.store, importer: contactsSurface.importer, chatFocus: chatFocus)
                .onAppear { contactsSurface.installIfNeeded() }
        case .reminders:
            RemindersView(store: remindersSurface.store, scheduler: remindersSurface.scheduler, chatFocus: chatFocus)
                .onAppear { remindersSurface.installIfNeeded() }
        case .collab:
            CollabTraceView()
        case .intelligence:
            IntelligenceView()
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
        // Part D: hand the conversation off to the UnifiedChatController,
        // which reconstructs the transcript from checkpoints and continues
        // the thread. Until then, just close the drawer.
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

/// Map the macOS-only sidebar `Destination` to the platform-independent
/// ``DestinationStarterPrompts.Context``. The mapping lives here, not in
/// ``TesseraCore``, because `Destination` is a macOS-shell concern.
extension DestinationStarterPrompts.Context {
    init(_ destination: Destination?) {
        switch destination {
        case .workflows:    self = .workflows
        case .tasks:        self = .tasks
        case .calendar:     self = .calendar
        case .notes:        self = .notes
        case .code:         self = .code
        case .docs:         self = .docs
        case .sheets:       self = .sheets
        case .slides:       self = .slides
        case .email:        self = .email
        case .contacts:     self = .contacts
        case .reminders:    self = .reminders
        case .collab:       self = .collab
        case .intelligence: self = .intelligence
        case .none:         self = .neutral
        }
    }
}
