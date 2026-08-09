import SwiftUI
import TesseraCore

/// Multi-cloud provider catalog section. Renders one row per provider in
/// ``TesseraCloudCatalog`` with a Keychain-backed API key field, a stored/
/// missing status dot, and a Test button that fires a one-token stream ping
/// against the configured endpoint. Mirrors the Linux providers surface
/// (`tessera-studio-linux/src/ui/surfaces/providers/Surface.cpp`).
///
/// Embedded inside the Model tab of the main Settings view. The keys live in
/// the Keychain under each entry's `keychainAccount` so they are independent
/// of the main remote-API and Sky keys.
struct ProvidersSettingsView: View {
    var body: some View {
        Section("Cloud providers") {
            ForEach(TesseraCloudCatalog.entries) { entry in
                ProviderRow(entry: entry)
            }
        }
    }

    /// Per-provider test outcome for the status line under the Test button.
    struct TestResult: Equatable {
        let ok: Bool
        let message: String
    }

    struct ProviderRow: View {
        let entry: TesseraCloudEntry

        @State private var keyDraft = ""
        @State private var keyState: TesseraSecretState = .missing
        @State private var result: TestResult?
        @State private var testing = false

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: keyState == .stored ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(keyState == .stored ? .green : .secondary)
                    Text(entry.label).font(.body.bold())
                    Spacer()
                    if testing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Test") { runTest() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(keyState == .missing)
                    }
                }
                SecureField("API key", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commit() }
                Text("Base: \(entry.baseURL)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let result {
                    Text(result.message)
                        .font(.caption2)
                        .foregroundStyle(result.ok ? .green : .red)
                }
            }
            .onAppear { load() }
        }

        private func load() {
            keyDraft = TesseraSecretStore.secret(account: entry.keychainAccount) ?? ""
            keyState = TesseraSecretStore.state(account: entry.keychainAccount)
        }

        private func commit() {
            let stored = TesseraSecretStore.setSecret(
                keyDraft.isEmpty ? nil : keyDraft,
                account: entry.keychainAccount
            )
            if stored {
                keyState = TesseraSecretStore.state(account: entry.keychainAccount)
            }
        }

        private func runTest() {
            // The ping runs a one-token stream against the entry's endpoint.
            // A successful first chunk = ok; anything else surfaces the error.
            let provider = RemoteLLMProvider(
                baseURL: entry.baseURL,
                apiKey: TesseraSecretStore.secret(account: entry.keychainAccount) ?? "",
                modelName: entry.defaultModel,
                useStreaming: true
            )
            testing = true
            Task {
                do {
                    let stream = try await provider.stream(
                        system: "You are being pinged.",
                        messages: [LLMMessage(role: "user", content: "ping")],
                        tools: []
                    )
                    var got = false
                    for try await chunk in stream {
                        if case .text = chunk { got = true; break }
                    }
                    await MainActor.run {
                        result = TestResult(ok: got, message: got ? "Connected" : "No response")
                        testing = false
                    }
                } catch {
                    await MainActor.run {
                        result = TestResult(ok: false, message: "Failed: \(error.localizedDescription)")
                        testing = false
                    }
                }
            }
        }
    }
}
