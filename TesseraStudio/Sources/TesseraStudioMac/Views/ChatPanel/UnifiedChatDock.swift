import SwiftUI
import TesseraCore

/// The persistent right-edge Tessy + Sky chat dock. Hosts the
/// ``UnifiedChatController`` (window-lived, so the transcript survives
/// navigation across every productivity surface). Compact layout sized for a
/// ~360px inspector column.
struct UnifiedChatDock: View {
    @Bindable var controller: UnifiedChatController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inputText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            if controller.checkpoints.count > 1 { scrubber }
            transcript
            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    // MARK: - Time-travel scrubber

    private var scrubber: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { Double(max(0, controller.checkpoints.count - 1)) },
                set: { step in controller.seek(toCheckpoint: Int(step)) }
            ), in: 0...Double(max(1, controller.checkpoints.count - 1)))
            .controlSize(.mini)
            Text("\(controller.checkpoints.count) steps")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Tessy + Sky").font(.headline)
                Spacer()
                if !controller.statusPill.isEmpty {
                    Label(controller.statusPill, systemImage: "sparkles")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tertiary, in: Capsule())
                        .accessibilityLabel(controller.statusPill)
                }
            }
            HStack(spacing: 6) {
                personaChip(.tessy)
                personaChip(.sky)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func personaChip(_ persona: AgentPersona) -> some View {
        HStack(spacing: 3) {
            Image(systemName: persona.symbolName)
                .foregroundStyle(persona.tint)
                .font(.caption2)
            Text(persona.displayName).font(.caption2.bold())
            Text(persona.roleHint).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(persona.tint.opacity(0.1), in: Capsule())
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if controller.rows.isEmpty {
                        ContentUnavailableView(
                            "Ask Tessy or Sky",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("One input, two assistants. Tessy runs locally; Sky runs in the cloud. The router picks who answers - or force one with @tessy / @sky / @both.")
                        )
                        .padding(.top, 24)
                    }
                    ForEach(controller.rows) { row in
                        ChatBubbleView(
                            role: row.role,
                            content: row.content,
                            isStreaming: row.isStreaming,
                            speaker: row.speaker
                        )
                        .id(row.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onChange(of: controller.rows.last?.content) {
                scrollToBottom(proxy)
            }
            .onChange(of: controller.rows.count) {
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = controller.rows.last else { return }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.25)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            // Hold-your-horses toggle: pause new runs; queued prompts drain on resume.
            Button {
                if controller.holdMode.isPaused { controller.resumeFromHold() }
                else { controller.holdYourHorses() }
            } label: {
                Image(systemName: controller.holdMode.isPaused ? "play.circle.fill" : "pause.circle")
                    .symbolRenderingMode(.hierarchical)
                    .font(.title3)
                    .foregroundStyle(controller.holdMode.isPaused ? .green : .primary)
            }
            .accessibilityLabel(controller.holdMode.isPaused ? "Resume" : "Hold")
            .help(controller.holdMode.isPaused ? "Resume - drain queued prompts" : "Hold your horses - queue new prompts without running")

            TextField("Ask Tessy and Sky... (@sky / @tessy / @both)", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .onSubmit { send() }
                .accessibilityLabel("Message")

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.title3)
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
        .padding(10)
        .background(.bar)
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        controller.send(text)
    }
}
