import SwiftUI
import TesseraCore

// MARK: - VersionHistorySheet

/// A sheet showing the receipt-chain version history for a document.
/// Displays each saved version as a row with: timestamp, relative time,
/// the action summary, and who made the change. Selecting a version
/// shows its receipt payload details.
///
/// Accessed from: Review tab → "Version History" button.
public struct VersionHistorySheet: View {
    let doc: Doc
    let store: DocStore
    @Environment(\.dismiss) private var dismiss

    @State private var receipts: [Receipt] = []
    @State private var isLoading: Bool = true
    @State private var loadError: String?
    @State private var selectedReceipt: Receipt?

    public init(doc: Doc, store: DocStore) {
        self.doc = doc
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if isLoading {
                Spacer()
                ProgressView("Loading history…")
                Spacer()
            } else if let error = loadError {
                Spacer()
                errorState(error)
                Spacer()
            } else if receipts.isEmpty {
                Spacer()
                emptyState
                Spacer()
            } else {
                content
            }
        }
        .frame(minWidth: 680, idealWidth: 800, minHeight: 480, idealHeight: 560)
        .task {
            await loadHistory()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Version History")
                .font(.headline)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - States

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Failed to load history")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No version history yet")
                .font(.headline)
            Text("Save the document to create the first version.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    // MARK: - Content

    private var content: some View {
        HStack(spacing: 0) {
            receiptList
                .frame(minWidth: 280, idealWidth: 320, maxWidth: .infinity)
            Divider()
            receiptDetail
                .frame(minWidth: 300, idealWidth: 400, maxWidth: .infinity)
        }
    }

    // MARK: - Receipt list

    private var receiptList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(receipts.reversed(), id: \.id) { receipt in
                    receiptRow(receipt)
                    Divider().padding(.leading, 16)
                }
            }
        }
    }

    private func receiptRow(_ receipt: Receipt) -> some View {
        Button {
            selectedReceipt = receipt
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // Leading accent bar (not color-only: the filled Rectangle
                // provides a shape signal alongside the circle color).
                Rectangle()
                    .fill(selectedReceipt?.id == receipt.id ? Color.accentColor : Color.clear)
                    .frame(width: 3)
                    .frame(minHeight: 40)
                VStack(alignment: .center, spacing: 2) {
                    Circle()
                        .fill(selectedReceipt?.id == receipt.id ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 10, height: 10)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 1)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(receipt.summary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selectedReceipt?.id == receipt.id ? .primary : .primary)
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        Text(formattedDate(receipt.timestamp))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(actorLabel(receipt.actor))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.trailing, 16)
            .padding(.vertical, 10)
            .background(selectedReceipt?.id == receipt.id ? Color.accentColor.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(receipt.summary), \(actorLabel(receipt.actor)), \(formattedDate(receipt.timestamp))")
    }

    // MARK: - Receipt detail

    @ViewBuilder
    private var receiptDetail: some View {
        if let receipt = selectedReceipt {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard(receipt)
                    mutationsSection(receipt)
                    snapshotSection(receipt)
                    signatureSection(receipt)
                }
                .padding()
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "hand.tap")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Select a version to see details")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func summaryCard(_ receipt: Receipt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(receipt.summary)
                .font(.headline)
            HStack(spacing: 12) {
                Label(formattedDate(receipt.timestamp), systemImage: "clock")
                Label(actorLabel(receipt.actor), systemImage: "person")
                if receipt.mutations.count > 1 {
                    Label("\(receipt.mutations.count) ops", systemImage: "square.stack.3d.up")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func mutationsSection(_ receipt: Receipt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Changes")
                .font(.subheadline)
                .fontWeight(.semibold)
            ForEach(Array(receipt.mutations.enumerated()), id: \.offset) { _, mutation in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.right.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.blue)
                        .font(.caption)
                        .padding(.top, 2)
                    Text(mutation.shortDescription)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func snapshotSection(_ receipt: Receipt) -> some View {
        Group {
            if !receipt.preMutationSnapshot.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Snapshot (\(receipt.preMutationSnapshot.count) blocks)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("State before this change — used for undo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func signatureSection(_ receipt: Receipt) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Receipt")
                .font(.subheadline)
                .fontWeight(.semibold)
            HStack(spacing: 4) {
                Text(receipt.id.uuidString.prefix(8) + "…")
                    .font(.system(size: 10, design: .monospaced))
                Spacer()
                Button {
                    #if canImport(AppKit)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(receipt.id.uuidString, forType: .string)
                    #endif
                } label: {
                    Label("Copy ID", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }
            .padding(8)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(4)
        }
    }

    // MARK: - Data loading

    private func loadHistory() async {
        isLoading = true
        loadError = nil
        do {
            receipts = try await store.history(of: doc.id, limit: 100)
        } catch {
            loadError = String(describing: error)
        }
        isLoading = false
    }

    // MARK: - Formatting helpers

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func actorLabel(_ actor: Actor) -> String {
        switch actor {
        case .user:
            return "You"
        case .agent(_, let model, _):
            return model
        }
    }
}
