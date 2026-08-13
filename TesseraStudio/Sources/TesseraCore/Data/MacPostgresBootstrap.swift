import Foundation
import Logging

// MARK: - MacPostgresBootstrap

/// Embedded Postgres bootstrap for macOS. On first launch this
/// actor downloads and extracts the Postgres binary bundle to
/// `~/Library/Application Support/Tessera/postgres/`, runs
/// `initdb` to create a fresh data cluster, then applies
/// the schema migrations. On subsequent launches it verifies
/// the data directory is intact and starts the server.
///
/// The bootstrap runs ONCE on first launch; callers check
/// ``hasBootstrapped`` before invoking. The actor is
/// thread-safe (singleton via `Shared`).
public actor MacPostgresBootstrap {

    // MARK: - Errors

    public enum BootstrapError: Error, Sendable {
        case postgresNotFound
        case initdbFailed(String)
        case pg_ctlFailed(String)
        case migrationFailed(String)
        case dataDirectoryCorrupt(String)
        case downloadFailed(String)
    }

    // MARK: - Paths

    private static let tesseraSupportDir: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Tessera", isDirectory: true)
    }()

    private static let postgresBundleDir: URL = {
        tesseraSupportDir.appendingPathComponent("postgres", isDirectory: true)
    }()

    private static let pgDataDir: URL = {
        tesseraSupportDir.appendingPathComponent("pgdata", isDirectory: true)
    }()

    private static let migrationDir: URL = {
        // Walk up from Sources/TesseraCore/Data/ to the repo root.
        let me = URL(fileURLWithPath: #file)
        let repoRoot = me
            .deletingLastPathComponent() // Data
            .deletingLastPathComponent() // TesseraCore
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // TesseraStudio
            .deletingLastPathComponent() // repo root
        return repoRoot.appendingPathComponent("tools/tessera/db/migrations", isDirectory: true)
    }()

    private static let postgresBinaryName = "postgres"

    // MARK: - Singleton

    public static let shared = MacPostgresBootstrap()

    private var _hasBootstrapped: Bool = false
    /// True after a successful bootstrap. Survives the actor's
    /// lifetime (persisted to a marker file on disk).
    public var hasBootstrapped: Bool {
        get { _hasBootstrapped }
    }

    private var logger: Logger

    private init() {
        self.logger = Logger(label: "tessera.data.mac-postgres")
        // Load persisted state.
        _hasBootstrapped = Self.bootstrapMarkerExists()
    }

    // MARK: - Public entry point

    /// Bootstrap Postgres: download, initdb, apply migrations, start server.
    /// Idempotent — safe to call every launch; it returns immediately
    /// after the marker check on subsequent calls.
    public func bootstrapOrStart() async throws {
        if _hasBootstrapped {
            // Already done; start the server in case it was stopped.
            try await startServer()
            return
        }

        let bundleBinDir = Self.postgresBundleDir.appendingPathComponent("bin", isDirectory: true)
        let postgresPath = bundleBinDir.appendingPathComponent(Self.postgresBinaryName)

        if !FileManager.default.fileExists(atPath: postgresPath.path) {
            // First run: download and extract.
            try await downloadAndExtractPostgres()
        }

        try await initdbIfNeeded()
        try await applyMigrations()
        try await startServer()

        // Mark success so future calls are cheap.
        _hasBootstrapped = true
        Self.writeBootstrapMarker()
    }

    // MARK: - Download

    private func downloadAndExtractPostgres() async throws {
        // macOS ARM64 Postgres 16 from the official tarball.
        // Check `uname -m` to distinguish arm64 vs x86_64.
        let machine = await Task.synchronous {
            let (r, _) = await Shell.run("/usr/bin/uname -m")
            return r.trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        let arch: String
        switch machine {
        case "arm64": arch = "darwin-arm64"
        case "x86_64": arch = "darwin-x86_64"
        default: arch = "darwin-arm64"
        }

        // We target Postgres 16.4 (latest stable as of 2026-01).
        let version = "16.4"
        let urlString = "https://get.enterprisedb.com/postgresql/postgresql-\(version)-\(arch).bin"
        let tarballName = "postgres-\(version)-\(arch).tar.gz"
        let destDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tarballPath = destDir.appendingPathComponent(tarballName)

        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        logger.info("Downloading Postgres \(version) for \(arch)...")

        let (dl, _) = try await Shell.run(
            "/usr/bin/curl -L -o \"\(tarballPath.path)\" \"\(urlString)\"",
            timeout: 300
        )
        guard dl.isEmpty else {
            throw BootstrapError.downloadFailed("curl returned non-empty output: \(dl)")
        }

        // The .bin installer on macOS is a self-extracting archive.
        // Run it with --install-only to extract to our bundle dir.
        let (runOut, runErr) = try await Shell.run(
            "chmod +x \"\(tarballPath.path)\" && \"\(tarballPath.path)\" --install-only --prefix \"\(Self.postgresBundleDir.path)\"",
            timeout: 120
        )
        logger.debug("Postgres installer output: \(runOut) \(runErr)")

        let extractedBin = Self.postgresBundleDir.appendingPathComponent("bin/\(Self.postgresBinaryName)")
        guard FileManager.default.fileExists(atPath: extractedBin.path) else {
            throw BootstrapError.downloadFailed(
                "installer did not produce \(extractedBin.path)"
            )
        }
        logger.info("Postgres extracted to \(Self.postgresBundleDir.path)")
    }

    // MARK: - initdb

    private func initdbIfNeeded() async throws {
        if FileManager.default.fileExists(atPath: Self.pgDataDir.path) {
            // Data directory exists — verify it looks like initdb output.
            let controlFile = Self.pgDataDir.appendingPathComponent("postgresql.conf")
            if !FileManager.default.fileExists(atPath: controlFile.path) {
                throw BootstrapError.dataDirectoryCorrupt(
                    "pgdata exists but postgresql.conf is missing"
                )
            }
            logger.info("Postgres data directory already initialised")
            return
        }

        logger.info("Running initdb...")
        let binDir = Self.postgresBundleDir.appendingPathComponent("bin", isDirectory: true)
        let initdbPath = binDir.appendingPathComponent("initdb")
        let pgpassPath = Self.pgDataDir.appendingPathComponent(".pgpass")
        let pgpassContent = "localhost:*:tessera:tessera\n"

        try FileManager.default.createDirectory(at: Self.pgDataDir, withIntermediateDirectories: true)

        // Write .pgpass so initdb can set permissions on it.
        try pgpassContent.write(toFile: pgpassPath.path, atomically: true, encoding: .utf8)

        let (out, err) = try await Shell.run(
            "chmod 0600 \"\(pgpassPath.path)\" && \"\(initdbPath.path)\" -D \"\(Self.pgDataDir.path)\" -U tessera -W",
            timeout: 60
        )
        logger.debug("initdb output: \(out) \(err)")

        // Verify the data dir was created.
        let controlFile = Self.pgDataDir.appendingPathComponent("postgresql.conf")
        guard FileManager.default.fileExists(atPath: controlFile.path) else {
            throw BootstrapError.initdbFailed("postgresql.conf not found after initdb")
        }

        // Patch pg_hba.conf to allow trust for localhost dev.
        let hbaPath = Self.pgDataDir.appendingPathComponent("pg_hba.conf")
        let trustLine = "# Trust local connections for Tessera development\nhost all all 127.0.0.1/32 trust\nhost all all ::1/128 trust\n"
        if FileManager.default.fileExists(atPath: hbaPath.path) {
            let existing = try String(contentsOf: hbaPath, encoding: .utf8)
            if !existing.contains("trust") {
                try (existing + trustLine).write(toFile: hbaPath.path, atomically: true, encoding: .utf8)
            }
        }

        logger.info("initdb complete")
    }

    // MARK: - Migrations

    private func applyMigrations() async throws {
        let migrationDir = Self.migrationDir
        guard FileManager.default.fileExists(atPath: migrationDir.path) else {
            // Repo migrations not found — this is fine for the Mac app
            // if migrations were applied externally.
            logger.warning("Migrations directory not found at \(migrationDir.path); skipping")
            return
        }

        let fm = FileManager.default
        var files = try fm.contentsOfDirectory(atPath: migrationDir.path)
        files.sort() // lexicographic = migration order

        let binDir = Self.postgresBundleDir.appendingPathComponent("bin", isDirectory: true)
        let psqlPath = binDir.appendingPathComponent("psql")

        for file in files {
            guard file.hasSuffix(".sql") else { continue }
            let sqlPath = migrationDir.appendingPathComponent(file)
            logger.info("Applying migration: \(file)")

            // Run via psql so we get proper multi-statement handling.
            let (out, err) = try await Shell.run(
                "\"\(psqlPath.path)\" -h localhost -U tessera -d tessera -f \"\(sqlPath.path)\"",
                timeout: 30
            )
            if !err.isEmpty {
                logger.warning("psql stderr for \(file): \(err)")
            }
            logger.debug("Migration \(file) output: \(out)")
        }
    }

    // MARK: - Server lifecycle

    /// Start the Postgres server. Safe to call on every launch;
    /// `pg_ctl start` is idempotent when the server is already running.
    public func startServer() async throws {
        let binDir = Self.postgresBundleDir.appendingPathComponent("bin", isDirectory: true)
        let pgCtlPath = binDir.appendingPathComponent("pg_ctl")
        let logFile = Self.pgDataDir.appendingPathComponent("postmaster.log")

        let (out, err) = try await Shell.run(
            "\"\(pgCtlPath.path)\" start -D \"\(Self.pgDataDir.path)\" -l \"\(logFile.path)\" -w",
            timeout: 30
        )
        logger.debug("pg_ctl start output: \(out) \(err)")

        // Verify the server is accepting connections.
        try await waitForServerReady()
    }

    /// Stop the Postgres server. Called during app shutdown.
    public func stopServer() async throws {
        let binDir = Self.postgresBundleDir.appendingPathComponent("bin", isDirectory: true)
        let pgCtlPath = binDir.appendingPathComponent("pg_ctl")

        let (_, err) = try await Shell.run(
            "\"\(pgCtlPath.path)\" stop -D \"\(Self.pgDataDir.path)\" -m fast -w",
            timeout: 30
        )
        logger.debug("pg_ctl stop: \(err)")
    }

    private func waitForServerReady() async throws {
        let binDir = Self.postgresBundleDir.appendingPathComponent("bin", isDirectory: true)
        let psqlPath = binDir.appendingPathComponent("psql")

        var lastError: String = "never attempted"
        for i in 0..<30 { // up to 30s
            do {
                let (out, _) = try await Shell.run(
                    "\"\(psqlPath.path)\" -h localhost -U tessera -d tessera -c 'SELECT 1' -t",
                    timeout: 10
                )
                if out.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                    logger.info("Postgres server ready after ~\(i * 1000)ms")
                    return
                }
                lastError = "unexpected output: \(out)"
            } catch {
                lastError = String(describing: error)
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
        }
        throw BootstrapError.pg_ctlFailed("server not ready after 30s: \(lastError)")
    }

    // MARK: - Bootstrap marker

    private static func bootstrapMarkerPath() -> URL {
        tesseraSupportDir.appendingPathComponent(".postgres-bootstrapped", isDirectory: false)
    }

    private static func bootstrapMarkerExists() -> Bool {
        FileManager.default.fileExists(atPath: bootstrapMarkerPath().path)
    }

    private static func writeBootstrapMarker() {
        try? FileManager.default.createDirectory(
            at: tesseraSupportDir,
            withIntermediateDirectories: true
        )
        try? "bootstrapped".write(toFile: bootstrapMarkerPath().path, atomically: true, encoding: .utf8)
    }
}

// MARK: - Shell helper

/// Thin synchronous wrapper around `Process` for the bootstrap script.
/// Blocks on `await run(...)` to return stdout+stderr as strings.
private enum Shell {
    static func run(_ command: String, timeout: Int = 30) async throws -> (stdout: String, stderr: String) {
        try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Set PATH so pg_ctl / psql can be found.
            var env = ProcessInfo.processInfo.environment
            let bundleBin = MacPostgresBootstrap.postgresBundleDir
                .appendingPathComponent("bin").path
            env["PATH"] = "\(bundleBin):/usr/local/bin:/usr/bin:/bin"
            process.environment = env

            var timedOut = false
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                timedOut = true
                process.terminate()
            }

            process.terminationHandler = { _ in
                timeoutTask.cancel()
                let stdout = Self.readPipe(stdoutPipe)
                let stderr = Self.readPipe(stderrPipe)
                if timedOut {
                    cont.resume(throwing: MacPostgresBootstrap.BootstrapError.pg_ctlFailed(
                        "command timed out after \(timeout)s: \(command)"
                    ))
                } else if process.terminationStatus == 0 {
                    cont.resume(returning: (stdout, stderr))
                } else {
                    cont.resume(throwing: MacPostgresBootstrap.BootstrapError.pg_ctlFailed(
                        "command failed (\(process.terminationStatus)): \(command)\nstderr: \(stderr)"
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                timeoutTask.cancel()
                cont.resume(throwing: MacPostgresBootstrap.BootstrapError.pg_ctlFailed(
                    "failed to start: \(error)"
                ))
            }
        }
    }

    private static func readPipe(_ pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Task.synchronous

extension Task where Success == Void, Failure == Never {
    /// Run a synchronous block on the current actor and wait for it.
    /// Used for `uname` etc. where we need to hop out of the actor.
    fileprivate static func synchronous(_ block: @escaping @Sendable () -> Void) async -> Void {
        await withCheckedContinuation { cont in
            let work = DispatchWorkItem {
                block()
                cont.resume()
            }
            DispatchQueue.global().async(execute: work)
        }
    }

    /// Run a synchronous block and return its result.
    fileprivate static func synchronous<T: Sendable>(_ block: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            let work = DispatchWorkItem {
                let result = block()
                cont.resume(returning: result)
            }
            DispatchQueue.global().async(execute: work)
        }
    }
}
