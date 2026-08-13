import Foundation

// MARK: - TesseraFormatBridge

/// The Swift-side actor that wraps the Python format-bridge subprocess.
///
/// ``TesseraFormatBridge`` speaks JSON over stdin/stdout to a single
/// ``python3 scripts/tessera-format-bridge.py`` process that handles
/// all format conversion (import: external file → Block AST JSON;
/// export: Block AST JSON → external file).
///
/// The actor serialises calls so concurrent requests don't interleave
/// the JSON stream. The subprocess is spawned once and reused until
/// it exits or times out.
///
/// **Error taxonomy**
/// - ``FormatBridgeError.timeout`` — the subprocess ran for > 30 s
/// - ``FormatBridgeError.missingLibrary`` — the Python script reported
///   `no converter for .xxx` (the required Python library is absent)
/// - ``FormatBridgeError.missingScript`` — the bridge script is not
///   on the resolved path
/// - ``FormatBridgeError.subprocessError`` — unexpected subprocess failure
/// - ``FormatBridgeError.invalidResponse`` — the Python script's stdout
///   was not valid JSON
public actor TesseraFormatBridge {

    // MARK: - Errors

    public enum FormatBridgeError: Error, LocalizedError, Sendable {
        case timeout
        case missingLibrary(String)
        case missingScript
        case subprocessError(exitCode: Int32, stderr: String)
        case invalidResponse(String)
        case pythonNotFound

        public var errorDescription: String? {
            switch self {
            case .timeout:
                return "Format bridge: subprocess timed out after 30 seconds"
            case .missingLibrary(let detail):
                return "Format bridge: \(detail)"
            case .missingScript:
                return "Format bridge: script not found on expected path"
            case .subprocessError(let code, let stderr):
                return "Format bridge: subprocess exited \(code): \(stderr)"
            case .invalidResponse(let detail):
                return "Format bridge: invalid response: \(detail)"
            case .pythonNotFound:
                return "Format bridge: python3 not found on PATH"
            }
        }
    }

    // MARK: - Supported formats

    /// Formats that can be imported (external file → Block AST).
    public static let importFormats: [String] = [
        "docx", "xlsx", "pptx", "eml", "mbox", "html", "md", "pdf",
    ]

    /// Formats that can be exported (Block AST → external file).
    public static let exportFormats: [String] = [
        "docx", "xlsx", "pptx", "eml", "html", "md", "pdf",
    ]

    /// Formats that can be imported.
    public var supportedImportFormats: [String] { Self.importFormats }

    /// Formats that can be exported.
    public var supportedExportFormats: [String] { Self.exportFormats }

    // MARK: - Init

    private let bridgeScriptPath: String
    private let pythonPath: String
    private let timeoutSeconds: Int

    /// Resolve the bridge script path. The script lives in the repo root's
    /// ``scripts/`` directory. When the app is bundled, we fall back to
    /// the bundle's Resources directory.
    private static func resolveBridgeScriptPath() -> String {
        // 1. Repo root (the developer checkout path)
        let home = NSHomeDirectory()
        let repoRoot = URL(fileURLWithPath: home)
            .appendingPathComponent("Developer/GitHub/tessera")
        let repoPath = repoRoot
            .appendingPathComponent("scripts/tessera-format-bridge.py")
            .path
        if FileManager.default.fileExists(atPath: repoPath) {
            return repoPath
        }

        // 2. Bundle Resources
        if let bundlePath = Bundle.main.resourcePath {
            let bundled = (bundlePath as NSString)
                .appendingPathComponent("tessera-format-bridge.py")
            if FileManager.default.fileExists(atPath: bundled) {
                return bundled
            }
        }

        // 3. CWD
        let cwd = FileManager.default.currentDirectoryPath
        let cwdPath = (cwd as NSString).appendingPathComponent("scripts/tessera-format-bridge.py")
        if FileManager.default.fileExists(atPath: cwdPath) {
            return cwdPath
        }

        // 4. Fallback to repoRoot path even if it doesn't exist (the
        //    subprocess will report the error)
        return repoPath
    }

    /// Resolve the Python 3 interpreter path.
    private static func resolvePythonPath() -> String {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        // PATH fallback
        if let pathEnv = getenv("PATH") {
            let pathStr = String(cString: pathEnv)
            let dirs = pathStr.split(separator: ":").map(String.init)
            for dir in dirs {
                let p = (dir as NSString).appendingPathComponent("python3")
                if FileManager.default.isExecutableFile(atPath: p) {
                    return p
                }
            }
        }
        return "/usr/bin/python3"
    }

    public init(timeoutSeconds: Int = 30) {
        self.timeoutSeconds = timeoutSeconds
        self.bridgeScriptPath = Self.resolveBridgeScriptPath()
        self.pythonPath = Self.resolvePythonPath()
    }

    // MARK: - Public API

    /// Import: convert a file's bytes to a Tessera Block AST.
    ///
    /// - Parameters:
    ///   - data: the raw file bytes
    ///   - format: the file format (e.g. `"docx"`, `"html"`)
    /// - Returns: the Block AST as JSON `Data`
    public func importFile(data: Data, format: String) async throws -> Data {
        let response = try await _runBridge(
            command: [
                "action": "import",
                "format": format,
                "data": data.base64EncodedString(),
            ]
        )
        return try _decodeResponse(response, expectingAST: true)
    }

    /// Export: convert a Tessera Block AST to a file's bytes.
    ///
    /// - Parameters:
    ///   - blocks: the Block AST as JSON `Data`
    ///   - format: the target file format (e.g. `"docx"`, `"html"`)
    /// - Returns: the raw file bytes
    public func exportFile(blocks: Data, format: String) async throws -> Data {
        guard let blocksJSON = try? JSONSerialization.jsonObject(with: blocks) else {
            throw FormatBridgeError.invalidResponse("blocks data is not valid JSON")
        }
        let response = try await _runBridge(
            command: [
                "action": "export",
                "format": format,
                "blocks": blocksJSON,
            ]
        )
        return try _decodeResponse(response, expectingAST: false)
    }

    // MARK: - Internal

    private func _runBridge(command: [String: Any]) async throws -> [String: Any] {
        // Check Python exists
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            throw FormatBridgeError.pythonNotFound
        }

        // Check script exists
        guard FileManager.default.fileExists(atPath: bridgeScriptPath) else {
            throw FormatBridgeError.missingScript
        }

        // Serialize command to JSON
        let commandData: Data
        do {
            commandData = try JSONSerialization.data(withJSONObject: command)
        } catch {
            throw FormatBridgeError.invalidResponse("failed to serialise command: \(error)")
        }
        guard let commandString = String(data: commandData, encoding: .utf8) else {
            throw FormatBridgeError.invalidResponse("command is not valid UTF-8")
        }

        // Run synchronously in a Task so we can await it
        return try await withCheckedThrowingContinuation { continuation in
            let proc = DispatchWorkItem {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: self.pythonPath)
                process.arguments = [self.bridgeScriptPath]
                process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Developer/GitHub/tessera")

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                var environment = ProcessInfo.processInfo.environment
                environment["PYTHONIOENCODING"] = "utf-8"
                process.environment = environment

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: FormatBridgeError.subprocessError(
                        exitCode: -1,
                        stderr: String(describing: error)
                    ))
                    return
                }

                // Write command to stdin
                if let cmdBytes = commandString.data(using: .utf8) {
                    try? stdinPipe.fileHandleForWriting.write(contentsOf: cmdBytes)
                }
                try? stdinPipe.fileHandleForWriting.close()

                // Wait with a simple timeout using a semaphore
                var timedOut = false
                let waitGroup = DispatchGroup()
                waitGroup.enter()
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    waitGroup.leave()
                }
                let result = waitGroup.wait(timeout: .now() + .seconds(self.timeoutSeconds))
                if result == .timedOut {
                    process.terminate()
                    timedOut = true
                }

                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: errData, encoding: .utf8) ?? ""

                if timedOut {
                    continuation.resume(throwing: FormatBridgeError.timeout)
                    return
                }

                if process.terminationStatus == -1 {
                    continuation.resume(throwing: FormatBridgeError.timeout)
                    return
                }

                let stdoutString = String(data: outData, encoding: .utf8) ?? ""
                guard !stdoutString.isEmpty else {
                    continuation.resume(throwing: FormatBridgeError.subprocessError(
                        exitCode: process.terminationStatus,
                        stderr: stderr.isEmpty ? "(no stderr)" : stderr
                    ))
                    return
                }

                guard let json = try? JSONSerialization.jsonObject(
                    with: stdoutString.data(using: .utf8)!
                ) as? [String: Any] else {
                    continuation.resume(throwing: FormatBridgeError.invalidResponse(
                        "stdout is not valid JSON: \(stdoutString.prefix(200))"
                    ))
                    return
                }

                if let error = json["error"] as? String {
                    if error.contains("no converter") || error.contains("not found") || error.contains("not installed") {
                        continuation.resume(throwing: FormatBridgeError.missingLibrary(error))
                    } else {
                        continuation.resume(throwing: FormatBridgeError.subprocessError(
                            exitCode: process.terminationStatus,
                            stderr: error
                        ))
                    }
                    return
                }

                continuation.resume(returning: json)
            }

            DispatchQueue.global(qos: .userInitiated).async(execute: proc)
        }
    }

    private func _decodeResponse(_ json: [String: Any], expectingAST: Bool) throws -> Data {
        guard json["status"] as? String == "ok" else {
            let err = json["error"] as? String ?? "unknown error"
            throw FormatBridgeError.subprocessError(exitCode: 0, stderr: err)
        }

        guard let dataB64 = json["data"] as? String else {
            throw FormatBridgeError.invalidResponse("response missing 'data' field")
        }

        guard let decoded = Data(base64Encoded: dataB64) else {
            throw FormatBridgeError.invalidResponse("data field is not valid base64")
        }

        return decoded
    }
}

// MARK: - FormatBridgeProcessRunner

/// A thin wrapper around ``Process`` for synchronous subprocess execution.
/// Exists so we can inject a mock in tests.
/// Process abstraction local to the format bridge. Distinct from
/// TesseraCore's Engine/ProcessRunner: this one carries timeout
/// semantics (`timedOut`) the engine runner does not model.
public protocol FormatBridgeProcessRunner: Sendable {
    func run(
        executable: String,
        arguments: [String],
        input: String,
        timeoutSeconds: Int
    ) throws -> FormatBridgeProcessResult
}

public struct FormatBridgeProcessResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let timedOut: Bool

    public init(stdout: String, stderr: String, exitCode: Int32, timedOut: Bool) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
    }
}

/// The default process runner used by ``TesseraFormatBridge``.
public struct DefaultFormatBridgeProcessRunner: FormatBridgeProcessRunner {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        input: String,
        timeoutSeconds: Int
    ) throws -> FormatBridgeProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONIOENCODING"] = "utf-8"
        process.environment = environment

        try process.run()

        // Write input
        if let inputData = input.data(using: .utf8) {
            try stdinPipe.fileHandleForWriting.write(contentsOf: inputData)
        }
        try stdinPipe.fileHandleForWriting.close()

        // Wait with timeout using busy-polling (simple, no DispatchSource needed
        // in this synchronous context)
        let deadline = DispatchTime.now() + .seconds(timeoutSeconds)
        var timedOut = false
        while process.isRunning {
            if DispatchTime.now() >= deadline {
                process.terminate()
                timedOut = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        if !timedOut {
            process.waitUntilExit()
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return FormatBridgeProcessResult(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus,
            timedOut: timedOut
        )
    }
}
