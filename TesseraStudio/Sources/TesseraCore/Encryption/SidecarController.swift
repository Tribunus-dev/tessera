import Foundation

/// The two long-running sidecar processes (Postgres and Valkey) are
/// stopped before the key is destroyed. This protocol is the seam so
/// the executor does not couple to the sidecar implementations.
///
/// The real implementations land with the Postgres / Valkey wiring
/// (later phase). Today, ``NoOpSidecarController`` is what every
/// caller injects; when the sidecars arrive, the production code
/// swaps in a real one and the executor does not change.
public protocol SidecarController: Sendable {
    func stopPostgres() async throws
    func stopValkey() async throws
}

/// Default ``SidecarController`` for builds where the sidecars are not
/// yet wired. `stopPostgres` and `stopValkey` are silent no-ops.
public struct NoOpSidecarController: SidecarController {
    public init() {}

    public func stopPostgres() async throws {
        // TODO(phase-postgres): send SIGTERM to tessera-postgres, wait up
        // to 5s, then SIGKILL. Wired in the Postgres integration phase.
    }

    public func stopValkey() async throws {
        // TODO(phase-valkey): send SIGTERM to tessera-valkey, wait up
        // to 5s, then SIGKILL. Wired in the Valkey integration phase.
    }
}

/// Real ``SidecarController`` backed by the data layer's connection
/// lifecycle. The app does not run Postgres/Valkey as subprocess sidecars;
/// it holds pooled connections through ``TesseraDataLayer``. Before the wipe
/// destroys the key, this controller closes those pools so no in-flight
/// write is left holding the old credentials. The data layer is an actor, so
/// the calls are awaited.
public struct TesseraDataLayerSidecarController: SidecarController {
    private let dataLayer: TesseraDataLayer?

    public init(dataLayer: TesseraDataLayer?) {
        self.dataLayer = dataLayer
    }

    public func stopPostgres() async throws {
        // shutdown() closes both stores; for a finer-grained future split,
        // stopPostgres would close only the durable store. Today the data
        // layer exposes a single shutdown() so we use it and let stopValkey
        // be a no-op (both are closed together here).
        try? await dataLayer?.shutdown()
    }

    public func stopValkey() async throws {
        // Closed together with Postgres in stopPostgres() above; kept as a
        // no-op so the wipe sequence's two-step contract still holds.
    }
}
