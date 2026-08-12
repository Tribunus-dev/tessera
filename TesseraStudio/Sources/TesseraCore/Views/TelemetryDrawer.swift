import SwiftUI
import Charts
import Observation

/// Polls a TesseraEngineBridge's telemetry every 500ms while active and
/// keeps a rolling window of samples for the sparklines.
@Observable
@MainActor
public final class TelemetryMonitor {
    public private(set) var samples: [TelemetrySample] = []
    public private(set) var isRunning = false
    /// Discrete events recorded from app code (review #1: time-to-first-message,
    /// onboarding-first-goal-set). Kept as a rolling log so the drawer can
    /// surface the most recent N alongside the sparklines.
    public private(set) var events: [TelemetryEvent] = []

    private let bridge: any TesseraEngineBridge
    private let capacity: Int
    private let eventCapacity: Int
    private var task: Task<Void, Never>?

    public init(bridge: any TesseraEngineBridge, capacity: Int = 60, eventCapacity: Int = 50) {
        self.bridge = bridge
        self.capacity = capacity
        self.eventCapacity = eventCapacity
    }

    public var latest: TelemetrySample? { samples.last }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard self.isRunning else { return }
                if let sample = await self.bridge.telemetry() {
                    self.append(sample)
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    public func stop() {
        isRunning = false
        task?.cancel()
        task = nil
    }

    public func reset() {
        samples = []
        events = []
    }

    /// Record a discrete app event (e.g. "time_to_first_message" with
    /// elapsed seconds). The drawer is free to surface the last N; nothing
    /// else in the app reads this.
    public func recordEvent(name: String, metadata: [String: String] = [:]) {
        events.append(TelemetryEvent(name: name, timestamp: Date(), metadata: metadata))
        if events.count > eventCapacity {
            events.removeFirst(events.count - eventCapacity)
        }
    }

    private func append(_ sample: TelemetrySample) {
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }
}

/// A discrete app event recorded on the ``TelemetryMonitor``. Used by the
/// review #1 measurement architecture (time-to-first-message, onboarding
/// first-goal-set).
public struct TelemetryEvent: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let name: String
    public let timestamp: Date
    public let metadata: [String: String]

    public init(name: String, timestamp: Date, metadata: [String: String] = [:]) {
        self.name = name
        self.timestamp = timestamp
        self.metadata = metadata
    }
}

/// Bottom drawer showing real-time engine telemetry during runs, with a
/// compact sparkline per metric category (design doc 11.7).
public struct TelemetryDrawer: View {
    public let monitor: TelemetryMonitor
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collapsed: Set<TelemetryCategory> = []

    public init(monitor: TelemetryMonitor, isExpanded: Binding<Bool>) {
        self.monitor = monitor
        self._isExpanded = isExpanded
    }

    public var body: some View {
        VStack(spacing: 0) {
            handle
            if isExpanded {
                Divider()
                if monitor.samples.isEmpty {
                    Text("Waiting for telemetry...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    sections
                }
            }
        }
        .background(.bar)
    }

    private var handle: some View {
        Button(action: { withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2)) { isExpanded.toggle() } }) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)
                Text("Telemetry")
                    .font(.caption.bold())
                if let latest = monitor.latest {
                    Text(String(format: "%.0f tok/s", latest.tokensPerSecond))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .symbolRenderingMode(.hierarchical)
                    .font(.caption2)
                    .rotationEffect(.degrees(isExpanded ? 0 : 180))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide telemetry" : "Show telemetry")
        .accessibilityValue(monitor.latest.map {
            String(format: "%.0f tokens per second", $0.tokensPerSecond)
        } ?? "")
    }

    private var sections: some View {
        ScrollView {
            VStack(spacing: 8) {
                section(.throughput) {
                    Sparkline(values: monitor.samples.map(\.tokensPerSecond), color: .green)
                    currentValue(String(format: "%.0f tok/s", monitor.latest?.tokensPerSecond ?? 0))
                }
                section(.memory) {
                    Sparkline(values: monitor.samples.map(\.memoryUsageMB), color: .blue)
                    currentValue(String(format: "%.0f MB", monitor.latest?.memoryUsageMB ?? 0))
                }
                section(.gpu) {
                    Sparkline(values: monitor.samples.map { $0.gpuUtilization ?? 0 }, color: .purple)
                    currentValue(gpuLabel)
                }
                section(.kernel) {
                    Sparkline(values: monitor.samples.map(\.kernelDispatchMs), color: .orange)
                    currentValue(String(format: "%.2f ms", monitor.latest?.kernelDispatchMs ?? 0))
                }
            }
            .padding()
        }
        .frame(maxHeight: 220)
    }

    private var gpuLabel: String {
        if let gpu = monitor.latest?.gpuUtilization {
            return String(format: "%.0f%%", gpu * 100)
        }
        return "n/a"
    }

    private func currentValue(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit().bold())
    }

    private func section<Content: View>(
        _ category: TelemetryCategory,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let isCollapsed = collapsed.contains(category)
        return VStack(alignment: .leading, spacing: 6) {
            Button(action: { toggle(category) }) {
                HStack {
                    Label(category.rawValue, systemImage: category.icon)
                        .font(.caption.bold())
                    Spacer()
                    Image(systemName: "chevron.right")
                        .symbolRenderingMode(.hierarchical)
                        .font(.caption2)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(category.rawValue), \(isCollapsed ? "collapsed" : "expanded")")
            .accessibilityHint("Double tap to \(isCollapsed ? "expand" : "collapse")")

            if !isCollapsed {
                HStack(spacing: 12) {
                    content()
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func toggle(_ category: TelemetryCategory) {
        if collapsed.contains(category) {
            collapsed.remove(category)
        } else {
            collapsed.insert(category)
        }
    }
}

/// A compact sparkline chart over a rolling value window.
struct Sparkline: View {
    let values: [Double]
    let color: Color

    private var points: [ConvergencePoint] {
        values.enumerated().map { ConvergencePoint(step: $0.offset, value: $0.element) }
    }

    var body: some View {
        Chart(points) { point in
            LineMark(
                x: .value("t", point.step),
                y: .value("v", point.value)
            )
            .foregroundStyle(color)
            .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        // The sparkline is visual-only; the current-value text
        // next to it carries the number for VoiceOver.
        .accessibilityHidden(true)
    }
}
