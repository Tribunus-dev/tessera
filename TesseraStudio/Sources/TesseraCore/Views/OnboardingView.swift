import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// First-run onboarding. Shown once, gated by an @AppStorage
/// flag. Review #6 fold: the three-page hero tour is replaced by
/// a single Form that mirrors the TesseraSettings form shape -
/// Models section (directory picker) and First goal section
/// (the typed-sentence seed from review #1). Onboarding matches
/// the terminal-core family: caption-bold, no hero, single form,
/// no page dots, no page-turn animation, no page-tint rotation.
public struct OnboardingView: View {
    @AppStorage(TesseraSettingsKey.onboardingComplete) private var onboardingComplete = false
    @AppStorage(TesseraSettingsKey.modelDirectory) private var modelDirectory = TesseraSettingsDefault.modelDirectory
    /// Drafted first goal typed in the First goal section. Persisted
    /// to ``TesseraSettingsKey.firstGoal`` on submit so the chat
    /// controller can seed the first send.
    @State private var firstGoalDraft: String = ""

    public var onComplete: () -> Void

    public init(onComplete: @escaping () -> Void = {}) {
        self.onComplete = onComplete
    }

    public var body: some View {
        Form {
            Section("Models") {
                PathField("Model directory", text: $modelDirectory, picks: .directory)
                // The four pipeline verbs collapse to a single caption
                // line so the directory field is the only functional
                // control on this row. Middle dots read as inline
                // separators in the same family as the rest of the
                // app's monospaced captions (see SheetListView_iOS,
                // DocDetailView_iOS).
                Text("Calibrate \u{00B7} Evolve \u{00B7} Evaluate \u{00B7} Deploy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                // Review #1 firstGoal card: typed-sentence seed for
                // UnifiedChatController. The TextField and the
                // optional footer are preserved verbatim from item
                // 1A; the hero chrome (icon, .largeTitle headline,
                // title3 subhead, "Meet the Agent" title) is dropped
                // because the form's section header carries the same
                // weight.
                TextField(
                    "e.g. Triage my email into 3 priority buckets.",
                    text: $firstGoalDraft,
                    axis: .vertical
                )
                .lineLimit(1...3)
            } header: {
                Text("First goal")
            } footer: {
                Text("Optional. The chat still works if you skip - this just gives the agent a head start.")
            }
            Section {
                Button("Get Started", action: finish)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 460)
        #endif
    }

    private func finish() {
        // Persist the typed first goal (or clear it when the user
        // skipped the field) so the chat controller can seed the
        // first send. Empty / whitespace is treated as "no seed".
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

/// A path setting with a Browse... button. Free typing still works
/// (power users paste paths), but HIG 2.13 asks that path fields
/// also offer a real file / folder picker instead of making the
/// user hand-type an absolute path. The NSOpenPanel resolves
/// security-scoped access for us on selection. Replicated from
/// ``TesseraStudioMac/Views/SettingsView.swift`` (private to that
/// file there) so the onboarding form matches the TesseraSettings
/// form shape verbatim. On iOS the Browse button is omitted; the
/// field is a free-typing TextField.
private struct PathField: View {
    enum PickTarget {
        case file(types: [UTType])
        case directory
    }

    let label: String
    @Binding var text: String
    let picks: PickTarget

    init(_ label: String, text: Binding<String>, picks: PickTarget) {
        self.label = label
        self._text = text
        self.picks = picks
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField(label, text: $text)
                    .accessibilityLabel(label)
                #if canImport(AppKit)
                Button("Browse\u{2026}") { browse() }
                    .accessibilityLabel("Browse for \(label)")
                #endif
            }
        }
    }

    #if canImport(AppKit)
    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        switch picks {
        case .file(let types):
            panel.canChooseFiles = true
            if !types.isEmpty { panel.allowedContentTypes = types }
        case .directory:
            panel.canChooseDirectories = true
        }
        // Start the panel where the current value points, when it
        // names an existing path - saves re-navigating from $HOME.
        if !text.isEmpty {
            let expanded = (text as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) {
                panel.directoryURL = URL(fileURLWithPath: isDir.boolValue
                    ? expanded
                    : (expanded as NSString).deletingLastPathComponent)
            }
        }
        if panel.runModal() == .OK, let url = panel.url {
            text = url.path
        }
    }
    #endif
}
