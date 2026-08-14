import Foundation

// MARK: - LibreOfficeConverter

/// Shells out to `soffice --headless --convert-to` for the file formats
/// Tessera has no native or Python reader/writer for (ODT, RTF, ODS,
/// legacy XLS - see `WriterBridgeFilter`/`CalcBridgeFilter`).
///
/// **Why a CLI conversion, not a UNO API bridge.** The originally
/// planned architecture (`EmbeddedPythonBridge`/`tessera_lo_service.py`,
/// an in-process UNO bridge via LibreOffice's own bundled Python) is a
/// documented dead end on this machine: `CPythonBridge` links Homebrew
/// Python 3.14 while LO's `pyuno.so` is built against 3.12 (ABI
/// mismatch, not just inconvenience), and invoking LO's bundled
/// `python3.12` binary directly hangs indefinitely regardless (its
/// quarantine flag survives even a clean `LibreOffice.app` reinstall -
/// confirmed empirically, not just diagnosed).
///
/// `soffice --headless --convert-to` sidesteps both problems: it only
/// ever invokes the main `soffice` executable (which passes Gatekeeper
/// once the .app itself is properly signed) in its own well-supported,
/// synchronous, one-shot CLI mode - no embedded Python, no UNO socket,
/// no custom RPC protocol to implement. It is the same mechanism
/// countless server-side document-conversion pipelines already rely
/// on. `-env:UserInstallation=` gives every call its own throwaway
/// profile directory, so concurrent conversions (or a conversion
/// running alongside the user's own interactive LibreOffice session)
/// never contend for the single default profile's lock file -
/// confirmed empirically: two concurrent conversions with distinct
/// profile dirs both completed cleanly; sharing one profile is the
/// well-known way to make headless `soffice` calls hang or fail.
public actor LibreOfficeConverter {

    public enum ConverterError: Error, LocalizedError, Sendable, Equatable {
        case sofficeNotFound
        case timeout
        case conversionFailed(exitCode: Int32, stderr: String)
        case outputNotProduced(expectedPath: String)

        public var errorDescription: String? {
            switch self {
            case .sofficeNotFound:
                return "LibreOffice converter: soffice not found"
            case .timeout:
                return "LibreOffice converter: conversion timed out"
            case .conversionFailed(let code, let stderr):
                return "LibreOffice converter: soffice exited \(code): \(stderr)"
            case .outputNotProduced(let path):
                return "LibreOffice converter: expected output not produced at \(path)"
            }
        }
    }

    private let sofficePath: String
    private let timeoutSeconds: Int

    public init(timeoutSeconds: Int = 60) {
        self.timeoutSeconds = timeoutSeconds
        self.sofficePath = Self.resolveSofficePath()
    }

    /// The Homebrew-cask install path (the command wrapper `brew`
    /// links into `/opt/homebrew/bin/soffice`) checked first, falling
    /// back to the `.app` bundle's own binary directly - either one
    /// is the same underlying executable on this machine, but a
    /// caller without Homebrew's symlink still finds it.
    public static func resolveSofficePath() -> String {
        let candidates = [
            "/opt/homebrew/bin/soffice",
            "/usr/local/bin/soffice",
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return candidates.last!
    }

    /// True when a `soffice` binary was found at init time. Tests use
    /// this to skip gracefully on a machine without LibreOffice
    /// installed, matching `GitReadOnlyTests`' `gitAvailable()`
    /// pattern for the same reason.
    public nonisolated var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: Self.resolveSofficePath())
    }

    /// Convert `data` (a file of `sourceExtension`, e.g. `"odt"`) to
    /// `targetExtension` (e.g. `"docx"`), returning the converted
    /// file's bytes.
    ///
    /// Deliberately does not pass an explicit LO filter name (just the
    /// bare extension) - `soffice` auto-selects a sensible default
    /// per extension, and hand-picking filter names risks the exact
    /// mistake found elsewhere in this codebase (`tessera_lo_service
    /// .py`'s `"xls"` entry silently maps to the `.xlsx` filter, not
    /// the actual binary-97-2003 one). A bare `--convert-to xls`
    /// was verified to correctly select `"MS Excel 97"`.
    public func convert(data: Data, sourceExtension: String, targetExtension: String) async throws -> Data {
        guard isAvailable else { throw ConverterError.sofficeNotFound }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-lo-convert-\(UUID().uuidString)", isDirectory: true)
        let profileDir = workDir.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let inputURL = workDir.appendingPathComponent("input.\(sourceExtension)")
        try data.write(to: inputURL)

        try await runSoffice(arguments: [
            "--headless",
            "-env:UserInstallation=file://\(profileDir.path)",
            "--convert-to", targetExtension,
            "--outdir", workDir.path,
            inputURL.path,
        ])

        let outputURL = workDir.appendingPathComponent("input.\(targetExtension)")
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ConverterError.outputNotProduced(expectedPath: outputURL.path)
        }
        return try Data(contentsOf: outputURL)
    }

    // MARK: - Subprocess

    private func runSoffice(arguments: [String]) async throws {
        let sofficePath = self.sofficePath
        let timeoutSeconds = self.timeoutSeconds
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let work = DispatchWorkItem {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: sofficePath)
                process.arguments = arguments
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ConverterError.conversionFailed(exitCode: -1, stderr: String(describing: error)))
                    return
                }

                var timedOut = false
                let waitGroup = DispatchGroup()
                waitGroup.enter()
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    waitGroup.leave()
                }
                let result = waitGroup.wait(timeout: .now() + .seconds(timeoutSeconds))
                if result == .timedOut {
                    process.terminate()
                    timedOut = true
                }

                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()

                if timedOut {
                    continuation.resume(throwing: ConverterError.timeout)
                    return
                }
                if process.terminationStatus != 0 {
                    let stderr = String(data: errData, encoding: .utf8) ?? ""
                    continuation.resume(throwing: ConverterError.conversionFailed(exitCode: process.terminationStatus, stderr: stderr))
                    return
                }
                continuation.resume(returning: ())
            }
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
    }
}
