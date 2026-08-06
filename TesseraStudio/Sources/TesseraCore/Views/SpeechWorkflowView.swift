import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Speech workflow view (W6, s2s design section 4.3)
//
// HIG layout (NavigationSplitView palette / canvas / inspector pattern,
// per docs/tessera-studio-design.md and the existing Tessera Studio
// views):
//   - Sidebar (palette): speech node card + model picker + preset
//     picker. Sentence text field on top of the canvas. Cmd-R runs;
//     the Edit menu (Cut/Copy/Paste/Select All) routes through the
//     focused text field automatically.
//   - Detail (canvas): the text field, a Run button, and a live
//     progress strip that lists producer events.
//   - Inspector (parameter panel): a JSONSchema-driven form bound to
//     the node's parameters; voice preset, code2wav path, and a
//     locked "ref_hash is refused" notice per the cloning-on-hold
//     gate (s2s design section 3.1 / 7).
//
// The view is platform-safe: it is a SwiftUI struct that the Mac
// app and the iOS app can both instantiate. The Open panel for
// model selection is AppKit-only (a no-op stub on iOS); the rest
// is platform-agnostic.

/// One captured S2S record row in the live event pane. Mirrors
/// what the producer returned; the full record lives in the trace
/// store, this struct is just the UI surface.
public struct SpeechWorkflowEvent: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case info, success, error
    }
    public let id = UUID()
    public let kind: Kind
    public let text: String
    public let timestamp = Date()
}

/// SwiftUI view that drives a single W6 speak run. The view is
/// stateful (text, voice, run-state, log) and uses a `TesseraTool`
/// or a workflow executor as its backend; the seam is the public
/// `init` that takes a closure, so tests can swap in a mock.
public struct SpeechWorkflowView: View {
    /// Backend seam. The default calls the workflow executor with
    /// a single-node speak_text workflow; tests inject a closure
    /// that returns a canned success or a structured failure.
    public typealias Runner = @Sendable (SpeechWorkflowRequest) async throws -> SpeechWorkflowOutcome

    public struct SpeechWorkflowRequest: Sendable, Equatable {
        public var text: String
        public var voicePreset: String
        public var modelPath: String
        public var code2WavPath: String?
        public init(text: String, voicePreset: String, modelPath: String, code2WavPath: String?) {
            self.text = text
            self.voicePreset = voicePreset
            self.modelPath = modelPath
            self.code2WavPath = code2WavPath
        }
    }

    public struct SpeechWorkflowOutcome: Sendable, Equatable {
        public var success: Bool
        public var sid: String?
        public var frames: Int?
        public var firstPacketUs: Int?
        public var backend: String?
        public var message: String
        public init(success: Bool, sid: String? = nil, frames: Int? = nil,
                    firstPacketUs: Int? = nil, backend: String? = nil,
                    message: String) {
            self.success = success
            self.sid = sid
            self.frames = frames
            self.firstPacketUs = firstPacketUs
            self.backend = backend
            self.message = message
        }
    }

    @State private var sentence: String = ""
    @State private var voicePreset: String = TesseraSpeechVoiceConfig.builtInPresets.first ?? "aria"
    @State private var modelPath: String = ""
    @State private var code2WavPath: String = ""
    @State private var isRunning: Bool = false
    @State private var events: [SpeechWorkflowEvent] = []
    @State private var lastOutcome: SpeechWorkflowOutcome?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private let runner: Runner
    private let initialModelPath: String
    private let initialCode2WavPath: String

    /// Production initializer. Uses a real workflow executor under
    /// the hood. `initialModelPath` is the path the user last
    /// selected (or empty); the picker defaults to it.
    public init(
        initialModelPath: String = "",
        initialCode2WavPath: String = ""
    ) {
        self.initialModelPath = initialModelPath
        self.initialCode2WavPath = initialCode2WavPath
        self.runner = Self.liveRunner
    }

    /// Test seam. Caller provides a runner closure.
    public init(
        runner: @escaping Runner,
        initialModelPath: String = "",
        initialCode2WavPath: String = ""
    ) {
        self.runner = runner
        self.initialModelPath = initialModelPath
        self.initialCode2WavPath = initialCode2WavPath
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            canvas
                .inspector(isPresented: .constant(true)) {
                    inspector
                }
        }
        .navigationTitle("Speech")
        .onAppear {
            if modelPath.isEmpty { modelPath = initialModelPath }
            if code2WavPath.isEmpty { code2WavPath = initialCode2WavPath }
        }
    }

    // MARK: - Sidebar (palette)

    private var sidebar: some View {
        List {
            Section("Speech node") {
                LabeledContent("Type", value: "speak_text")
                LabeledContent("Backend", value: backendLabel)
                    .help("Source of the Talker + Code2Wav pass. cli uses tessera-s2s-cli; ffi uses the C bridge once the W5 worker lands.")
            }
            Section("Voice") {
                Picker("Preset", selection: $voicePreset) {
                    ForEach(TesseraSpeechVoiceConfig.builtInPresets, id: \.self) { preset in
                        Text(preset.capitalized).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Voice preset")
                .help("CustomVoice preset. Cloning via reference audio is on indefinite hold.")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Speech")
    }

    // MARK: - Canvas (detail)

    private var canvas: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Type a sentence, then run the Talker + Code2Wav pass.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $sentence)
                .font(.body)
                .frame(minHeight: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                )
                .accessibilityLabel("Sentence to speak")
                .help("The text the Talker will speak. Empty input is refused.")
                .overlay(alignment: .topLeading) {
                    if sentence.isEmpty {
                        Text("e.g. Hello from the Tessera Talker.")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Button {
                    Task { await runOnce() }
                } label: {
                    Label(isRunning ? "Running..." : "Run", systemImage: "play.fill")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(isRunning || sentence.isEmpty || modelPath.isEmpty)
                .accessibilityLabel("Run")
                .help("Run the Talker + Code2Wav pass on the sentence above (Cmd-R).")

                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Running")
                }
                Spacer()
                if let outcome = lastOutcome {
                    statusBadge(outcome: outcome)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Events").font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(events) { event in
                            HStack(alignment: .top, spacing: 6) {
                                Circle()
                                    .fill(eventColor(event.kind))
                                    .frame(width: 8, height: 8)
                                    .padding(.top, 6)
                                Text(event.text)
                                    .font(.callout.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 100, maxHeight: 220)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
    }

    // MARK: - Inspector (parameter panel)

    private var inspector: some View {
        Form {
            Section("Talker model") {
                HStack {
                    TextField("Path", text: $modelPath, prompt: Text("qwen3-tts-talker-*.gguf"))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Talker model path")
                        .help("Path to the Talker GGUF. Empty is refused.")
                    Button("Choose...") { chooseModel() }
                        .help("Pick the Talker GGUF from disk.")
                }
            }
            Section("Code2Wav model") {
                HStack {
                    TextField("Path (optional)", text: $code2WavPath,
                              prompt: Text("qwen3-tts-code2wav-*.gguf"))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Code2Wav model path")
                        .help("Optional path to the Code2Wav GGUF. Leave empty to use the binary's default.")
                    Button("Choose...") { chooseCode2Wav() }
                }
            }
            Section("Voice") {
                Picker("Preset", selection: $voicePreset) {
                    ForEach(TesseraSpeechVoiceConfig.builtInPresets, id: \.self) { preset in
                        Text(preset.capitalized).tag(preset)
                    }
                }
                .help("CustomVoice preset. Cloning via reference audio is on indefinite hold.")
                Label("ref_hash is refused", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("Voice cloning is on indefinite hold (s2s design section 3.1 / 7). The speak_text tool rejects any non-empty ref_hash with an actionable error.")
            }
            Section("Provenance") {
                LabeledContent("Schema", value: "llama.tessera.s2s.v1")
                LabeledContent("Provenance", value: "s2s")
                LabeledContent("Capture", value: "default-on")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Parameters")
    }

    // MARK: - Status

    private func statusBadge(outcome: SpeechWorkflowOutcome) -> some View {
        HStack(spacing: 6) {
            Image(systemName: outcome.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(outcome.success ? .green : .orange)
            Text(outcome.success ? "Last run OK" : "Last run failed")
                .font(.callout)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(outcome.success ? "Last run succeeded" : "Last run failed")
    }

    private var backendLabel: String {
        // Best-effort: the inspector and sidebar should agree, and
        // either value is informative even if the registry isn't
        // initialised yet. SwiftUI views are not async, so we read
        // the static hint; the actual backend is fetched by the
        // tool at run time.
        TesseraSpeechProducerRegistry.sharedSyncLabel()
    }

    private func eventColor(_ kind: SpeechWorkflowEvent.Kind) -> Color {
        switch kind {
        case .info: return .secondary
        case .success: return .green
        case .error: return .orange
        }
    }

    // MARK: - Actions

    private func runOnce() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            appendEvent(.error, "Enter a sentence before running.")
            return
        }
        guard !modelPath.isEmpty else {
            appendEvent(.error, "Choose the Talker model path first.")
            return
        }
        let request = SpeechWorkflowRequest(
            text: trimmed,
            voicePreset: voicePreset,
            modelPath: modelPath,
            code2WavPath: code2WavPath.isEmpty ? nil : code2WavPath
        )
        appendEvent(.info, "Running speak_text (preset=\(voicePreset), model=\(modelPath))...")
        do {
            let outcome = try await runner(request)
            lastOutcome = outcome
            if outcome.success {
                let frames = outcome.frames ?? 0
                let fp = outcome.firstPacketUs ?? 0
                let sid = outcome.sid ?? "?"
                appendEvent(.success,
                            "Captured \(frames) frame(s) in \(fp) us; s2s record sid=\(sid).")
            } else {
                appendEvent(.error, outcome.message)
            }
        } catch {
            appendEvent(.error, "Run failed: \(error.localizedDescription)")
        }
    }

    private func appendEvent(_ kind: SpeechWorkflowEvent.Kind, _ text: String) {
        events.append(SpeechWorkflowEvent(kind: kind, text: text))
    }

    // MARK: - File pickers

    private func chooseModel() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.title = "Choose Talker GGUF"
        if panel.runModal() == .OK, let url = panel.url {
            modelPath = url.path
        }
        #endif
    }

    private func chooseCode2Wav() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.title = "Choose Code2Wav GGUF"
        if panel.runModal() == .OK, let url = panel.url {
            code2WavPath = url.path
        }
        #endif
    }

    // MARK: - Live runner (workflow executor seam)

    /// Build and run a one-node workflow containing only a speak_text
    /// node, with the user's parameters. Returns the
    /// `ToolResult.data` projected into the view's outcome type.
    static let liveRunner: Runner = { request in
        guard SpeakTextNode.inputs.contains(where: { $0.id == "text" }) else {
            return SpeechWorkflowOutcome(
                success: false,
                message: "SpeakTextNode is missing its text port; the node schema is broken.")
        }
        let preset = request.voicePreset
        let tool = SpeakTextTool()
        let arguments: [String: JSONValue] = [
            "text": .string(request.text),
            "voice_preset": .string(preset),
            "model_path": .string(request.modelPath),
            "code2wav_model_path": .string(request.code2WavPath ?? ""),
        ]
        do {
            let result = try await tool.execute(arguments: arguments)
            let data = result.data ?? [:]
            return SpeechWorkflowOutcome(
                success: result.success,
                sid: data["sid"]?.stringValue,
                frames: data["frames"]?.numberValue.map { Int($0) } ?? nil,
                firstPacketUs: data["first_packet_us"]?.numberValue.map { Int($0) } ?? nil,
                backend: data["backend"]?.stringValue,
                message: result.success
                    ? "ok: \(result.output)"
                    : (result.error ?? result.output)
            )
        } catch {
            return SpeechWorkflowOutcome(
                success: false, message: SpeakTextTool.localizedMessage(for: error))
        }
    }
}

// MARK: - Sync backend label helper

extension TesseraSpeechProducerRegistry {
    /// Best-effort sync label for SwiftUI views that can't `await`
    /// from inside `body`. Returns the static "tessera-speech"
    /// string; the view is the only caller and the value is
    /// purely cosmetic (the actual backend is fetched by the tool
    /// at run time).
    public static func sharedSyncLabel() -> String {
        "tessera-speech"
    }
}
