import SwiftUI
import TesseraCore

/// The Tessy + Sky dual-agent chat surface. One input, two assistants: Tessy
/// (local, privacy-preserving) and Sky (cloud, complex reasoning). A keyword
/// classifier decides who answers; `@tessy` / `@sky` / `@both` overrides force
/// a specific routing. Mirrors the Linux group chat in `AppMain.cpp`.
struct DualAgentChatView: View {
    @State private var controller: TesseraDualAgentController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inputText = ""

    init() {
        _controller = State(initialValue: MainActor.assumeIsolated { TesseraDualAgentController() })
    }

    init(controller: TesseraDualAgentController) {
        _controller = State(initialValue: controller)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            inputBar
        }
        .navigationTitle("Tessy + Sky")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear") { controller.clearTranscript() }
                    .disabled(controller.messages.isEmpty)
                    .accessibilityHint("Clears the chat transcript")
            }
        }
        .onAppear { controller.seedCollabTraceIfNeeded() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                participantChip("You", symbol: "person.fill", tint: .blue)
                participantChip(AgentPersona.tessy.displayName,
                                symbol: AgentPersona.tessy.symbolName,
                                tint: AgentPersona.tessy.tint,
                                subtitle: "local, sensitive")
                participantChip(AgentPersona.sky.displayName,
                                symbol: AgentPersona.sky.symbolName,
                                tint: AgentPersona.sky.tint,
                                subtitle: "cloud, complex")
                Spacer()
                if !controller.statusPill.isEmpty {
                    Label(controller.statusPill, systemImage: "sparkles")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.tertiary, in: Capsule())
                        .accessibilityLabel(controller.statusPill)
                }
            }
            Text("Tessy keeps sensitive info local; Sky jumps in when it's complex. Type @sky, @tessy, or @both to force one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func participantChip(_ name: String, symbol: String, tint: Color, subtitle: String? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(tint).font(.caption)
            Text(name).font(.caption.bold())
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.1), in: Capsule())
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if controller.messages.isEmpty {
                        ContentUnavailableView(
                            "Ask Tessy or Sky",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("One input, two assistants. Tessy runs locally; Sky runs in the cloud. The router picks who answers - or force one with @tessy / @sky / @both.")
                        )
                        .padding(.top, 40)
                    }
                    ForEach(controller.messages) { message in
                        ChatBubbleView(
                            role: message.role,
                            content: message.content,
                            isStreaming: message.isStreaming,
                            speaker: message.speaker
                        )
                        .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: controller.messages.last?.content) {
                if let last = controller.messages.last {
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.25)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: controller.messages.count) {
                if let last = controller.messages.last {
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.25)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 12) {
            TextField("Ask Tessy and Sky... (@sky / @tessy / @both)", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .onSubmit { send() }
                .onChange(of: inputText) { _, newValue in
                    Task { await CovertTriggerMonitor.shared.observe(text: newValue) }
                }
                .accessibilityLabel("Message")

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.title2)
            }
            .accessibilityLabel("Send")
            .help("Send")
            .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || controller.isRunning)

            if controller.isRunning {
                Button("Cancel", role: .cancel) { controller.cancel() }
                    .font(.caption)
                    .accessibilityHint("Stops the current run")
            }
        }
        .padding()
        .background(.bar)
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        controller.send(text)
    }
}
