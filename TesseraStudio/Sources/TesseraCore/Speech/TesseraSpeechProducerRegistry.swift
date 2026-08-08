import Foundation

/// Swappable, process-wide owner of the current ``TesseraSpeechProducer``.
///
/// The producer is a thin seam: a CLI-backed default lives here for
/// production, the W5 worker will register a C-bridge-backed producer
/// once `common/tessera-s2s-capture.h` lands, and tests register a
/// mock. The actor serialises swaps so a workflow run cannot observe
/// a mid-flight producer change.
///
/// All access is async on purpose: the actor isolation keeps the
/// producer's mutable state (loaded model handle on the C side,
/// canned frame buffer on the mock) from being shared across
/// concurrent workflow runs without going through the actor.
public actor TesseraSpeechProducerRegistry {
    public static let shared = TesseraSpeechProducerRegistry()

    private var current: any TesseraSpeechProducer

    /// Initial backend. Production wires a CLI-backed producer so the
    /// default path is real Talker inference as soon as the binary
    /// resolves; tests install a mock in `setUp` and restore in
    /// `tearDown`.
    public init(initial: any TesseraSpeechProducer = CliTesseraSpeechProducer()) {
        self.current = initial
    }

    /// Current producer. `await` required (actor isolation).
    public func producer() -> any TesseraSpeechProducer { current }

    /// Backend label of the current producer. Cheap, no copy; the
    /// UI uses it for the "Last speak" status row.
    public func backendLabel() -> String { current.backend }

    /// Replace the current producer. Idempotent; the call returns
    /// without error when `new` is the same instance.
    public func install(_ new: any TesseraSpeechProducer) {
        current = new
    }

    /// Reset to the CLI-backed production default. Used by
    /// integration tests that want to leave the process in a
    /// "default" state after a mock run.
    public func resetToDefault() {
        current = CliTesseraSpeechProducer()
    }
}
