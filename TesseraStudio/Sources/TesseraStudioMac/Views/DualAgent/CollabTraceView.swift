import SwiftUI
import TesseraCore

/// The Tessy & Sky handoff log. A separate surface from the group chat: it
/// narrates how the two agents collaborate (Tessy keeps personal context
/// local, asks Sky to reason over the abstracted task, then synthesizes).
/// Mirrors the Linux `src/ui/surfaces/collab/Surface.cpp`.
struct CollabTraceView: View {
    @State private var controller: TesseraDualAgentController

    init() {
        _controller = State(initialValue: MainActor.assumeIsolated { TesseraDualAgentController() })
    }

    init(controller: TesseraDualAgentController) {
        _controller = State(initialValue: controller)
    }

    var body: some View {
        VStack(spacing: 0) {
            explanation
            traceList
        }
        .navigationTitle("Tessy & Sky")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear Log") { controller.clearCollabTrace() }
                    .disabled(controller.collabTrace.isEmpty)
            }
        }
        .onAppear { controller.seedCollabTraceIfNeeded() }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("How Sky helps Tessy", systemImage: "person.2.wave.2")
                .font(.headline)
            Text("This log shows the handoff between Tessy (local) and Sky (cloud) - not the main group chat. Sensitive data never leaves the device; Sky only sees the abstracted task.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.5))
    }

    private var traceList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if controller.collabTrace.isEmpty {
                    ContentUnavailableView(
                        "No handoffs yet",
                        systemImage: "bubble.left.and.exclamationmark.bubble.right",
                        description: Text("When a message teams up Tessy and Sky, the handoff appears here.")
                    )
                    .padding(.top, 40)
                }
                ForEach(controller.collabTrace) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: entry.from.symbolName)
                            .foregroundStyle(entry.from.tint)
                            .font(.caption)
                            .frame(width: 18, height: 18)
                            .background(entry.from.tint.opacity(0.15), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(entry.from.displayName).font(.caption.bold())
                                Text(entry.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.text)
                                .font(.callout)
                                .foregroundStyle(.primary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(entry.from.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding()
        }
    }
}
