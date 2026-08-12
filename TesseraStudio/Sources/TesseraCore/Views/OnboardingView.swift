import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Three-page first-run onboarding. Shown once, gated by an @AppStorage
/// flag. Layout adapts: wider on macOS, full screen on iOS (design doc 5.10).
public struct OnboardingView: View {
    @AppStorage(TesseraSettingsKey.onboardingComplete) private var onboardingComplete = false
    @AppStorage(TesseraSettingsKey.modelDirectory) private var modelDirectory = TesseraSettingsDefault.modelDirectory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    /// Drafted first goal typed on page 3. Persisted to
    /// ``TesseraSettingsKey.firstGoal`` on submit so the chat controller
    /// can seed the first send.
    @State private var firstGoalDraft: String = ""

    public var onComplete: () -> Void

    public init(onComplete: @escaping () -> Void = {}) {
        self.onComplete = onComplete
    }

    private let pageCount = 3

    public var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 12)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            pageDots
            controls
                .padding(.bottom, 24)
        }
        .padding(.horizontal, 32)
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 460)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case 0: welcomePage
        case 1: modelPage
        default: agentPage
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.3x3.topleft.filled")
                .symbolRenderingMode(.hierarchical)
                .font(.largeTitle)
                .foregroundStyle(.purple)
            Text("Welcome to Tessera Studio")
                .font(.largeTitle.bold())
            Text("Quantize, calibrate, and deploy LLMs for the Apple Neural Engine - from corpus to device.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 8) {
                feature("slider.horizontal.3", "Calibrate", "Per-tensor imatrix activation statistics.")
                feature("point.topleft.down.curvedto.point.bottomright.up", "Evolve", "AWQ genetic search for optimal policies.")
                feature("gauge.with.needle", "Evaluate", "Perplexity, latency, and ANE power.")
                feature("cpu", "Deploy", "CoreML .mlmodelc for on-device inference.")
            }
            .padding(.top, 8)
        }
    }

    private var modelPage: some View {
        VStack(spacing: 16) {
            Image(systemName: "cube.box")
                .symbolRenderingMode(.hierarchical)
                .font(.largeTitle)
                .foregroundStyle(.blue)
            Text("Set Up Models")
                .font(.largeTitle.bold())
            Text("Tessera scans a directory for .gguf and .mlmodelc models.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 8) {
                Text("Model directory")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("~/Models/tessera", text: $modelDirectory)
                        .textFieldStyle(.roundedBorder)
                    #if canImport(AppKit)
                    Button("Browse…") { browseModelDirectory() }
                        .accessibilityLabel("Browse for the model directory")
                    #endif
                }
            }
            .frame(maxWidth: 420)
        }
    }

    #if canImport(AppKit)
    /// Folder-picker companion for the model directory field, same
    /// pattern as Settings' PathField.browse: free typing still works,
    /// but HIG 2.13 also wants a real picker.
    private func browseModelDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        // Start the panel where the current value points, when it
        // names an existing path - saves re-navigating from $HOME.
        if !modelDirectory.isEmpty {
            let expanded = (modelDirectory as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) {
                panel.directoryURL = URL(fileURLWithPath: isDir.boolValue
                    ? expanded
                    : (expanded as NSString).deletingLastPathComponent)
            }
        }
        if panel.runModal() == .OK, let url = panel.url {
            modelDirectory = url.path
        }
    }
    #endif

    private var agentPage: some View {
        // Review #1 onboarding: page 3 is no longer a 4-row approval legend
        // (an education-as-text surface that did not feed the agent). It is
        // a single typed-sentence "firstGoal" card that seeds the chat on
        // the user's first send. The typed goal is persisted to
        // ``TesseraSettingsKey.firstGoal``; the controller reads it on the
        // first send and clears it.
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .symbolRenderingMode(.hierarchical)
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Meet the Agent")
                .font(.largeTitle.bold())
            Text("Type one sentence about the first thing you want Tessy or Sky to do. The chat will pre-load it for you.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 8) {
                Text("Your first goal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    "e.g. Triage my email into 3 priority buckets.",
                    text: $firstGoalDraft,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .frame(maxWidth: 420)
                Text("Optional. The chat still works if you skip - this just gives the agent a head start.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420, alignment: .leading)
            }
        }
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 24)
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<pageCount, id: \.self) { index in
                Circle()
                    .foregroundStyle(index == page ? .primary : .quaternary)
                    .frame(width: 8, height: 8)
            }
        }
    }

    // HIG 2.7: matched spring per §2.7 — Reduce Motion falls back to
    // a near-instant linear so withAnimation still fires without motion.
    private var pageTurnAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .spring(duration: 0.35, bounce: 0.15)
    }

    private var controls: some View {
        HStack {
            if page > 0 {
                Button("Back") { withAnimation(pageTurnAnimation) { page -= 1 } }
                    .buttonStyle(.bordered)
            }
            Spacer()
            // HIG 14.2: the tutorial is optional - Skip is visible on
            // every page and completes onboarding immediately.
            Button("Skip") { finish() }
                .buttonStyle(.borderless)
            Button(page == pageCount - 1 ? "Get Started" : "Continue") {
                if page == pageCount - 1 {
                    finish()
                } else {
                    withAnimation(pageTurnAnimation) { page += 1 }
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: 420)
    }

    private func finish() {
        // Review #1 onboarding: persist the typed first goal (or clear it
        // when the user skipped the field) so the chat controller can seed
        // the first send. Empty / whitespace is treated as "no seed".
        let trimmed = firstGoalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        TesseraSettings.setFirstGoal(trimmed)
        // Always record the completion timestamp on the way out so the
        // time-to-first-message window has a start. The controller
        // is idempotent: a later re-completion does not overwrite.
        UserDefaults.standard.set(
            Date().timeIntervalSince1970,
            forKey: TesseraSettingsKey.onboardingCompletedAt
        )
        onboardingComplete = true
        onComplete()
    }
}
