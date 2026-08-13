import SwiftUI

/// Sheet presented when a tool requires explicit user approval.
///
/// The gate is synchronous: the agent loop is parked on a continuation
/// behind this sheet and resumes only when ``onResolve`` runs. Every
/// exit path here therefore resolves - there is no dismiss that leaves
/// the loop waiting, which is why interactive dismissal is disabled.
///
/// The structural fields (tier, risk, action class, reversibility) come
/// from ``ApprovalSafetyFacts``, the same derivation the chat progress
/// feed and the audit log read, in the shared `field: value` chip
/// vocabulary from ``AuditLogHead``.
public struct ApprovalSheet: View {
    public let request: PendingApprovalUnion
    public let onResolve: (Bool) -> Void

    private let facts: ApprovalSafetyFacts

    public init(request: PendingApprovalUnion, onResolve: @escaping (Bool) -> Void) {
        self.request = request
        self.onResolve = onResolve
        self.facts = ApprovalSafetyFacts(
            toolName: request.toolName,
            arguments: request.arguments
        )
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                header
                factsRow
                if facts.isIrreversible { irreversibleNotice }
                toolSection
                if !request.arguments.isEmpty { argumentsSection }
                Spacer(minLength: 0)
                actions
            }
            .padding()
            .navigationTitle("Approval")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        // The loop is parked behind this sheet; a swipe-away or Escape
        // would strand it. Deny / Approve are the only exits.
        .interactiveDismissDisabled()
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Label("Tool Approval Required", systemImage: "hand.raised")
                .font(.headline)
            Spacer()
            Text(request.speaker.displayName)
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(request.speaker.tint.opacity(0.15), in: Capsule())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tool approval required, requested by \(request.speaker.displayName)")
    }

    // MARK: - Structural facts

    private var factsRow: some View {
        HStack(spacing: 6) {
            chip(facts.tier.shortLabel, tint: tierTint)
            chip(facts.risk.rawValue, tint: riskTint)
            chip(facts.reversibilityLabel, tint: facts.isIrreversible ? .orange : .secondary)
            Spacer()
        }
        // One spoken string rather than five chips read in isolation.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(facts.displayString)
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private var tierTint: Color {
        switch facts.tier {
        case .tier0: return .secondary
        case .tier1: return .blue
        case .tier2: return .orange
        case .tier3: return .red
        }
    }

    private var riskTint: Color {
        switch facts.risk {
        case .low: return .secondary
        case .medium: return .blue
        case .high: return .orange
        case .forbidden: return .red
        }
    }

    private var irreversibleNotice: some View {
        Label("This cannot be undone.", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .accessibilityLabel("Warning: this action cannot be undone.")
    }

    // MARK: - Detail

    private var toolSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tool")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(request.toolName)
                .font(.system(.body, design: .monospaced).bold())
                .textSelection(.enabled)
            if !facts.actionClass.isEmpty {
                Text(facts.actionClass)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var argumentsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Arguments")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(request.arguments.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                HStack(alignment: .top) {
                    Text(key)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(value.shortDescription)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    /// Approve is prominent only for a reversible action. When the
    /// action cannot be undone, Deny carries the emphasis so the
    /// low-effort default is the safe one.
    @ViewBuilder
    private var actions: some View {
        HStack {
            if facts.isIrreversible {
                Button("Deny", role: .destructive) { onResolve(false) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Approve") { onResolve(true) }
                    .buttonStyle(.bordered)
            } else {
                Button("Deny", role: .destructive) { onResolve(false) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Approve") { onResolve(true) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
