import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Shell tool (general-purpose harness)

/// Execute a shell command and return its captured stdout/stderr/exit code.
/// Mutation-class (`bash:<verb>`); the structural action-class machinery
/// (`TesseraActionClass`) classifies the verb and the destructive-verb
/// denylist rejects `rm`/`del`/`format`/`mkfs`/`sudo`/etc. outright.
public struct BashTool: TesseraTool {
    public let name = "bash"
    public let description = """
    Run a shell command and return stdout, stderr, and the exit code. \
    Use for builds, tests, git, and inspection. Destructive verbs \
    (rm/del/format/mkfs/sudo) are rejected by the safety policy.
    """
    public let parameters: JSONSchema = {
        let cmdProp = SchemaProperty(type: "string", description: "The shell command to execute.")
        let cwdProp = SchemaProperty(type: "string", description: "Working directory (optional). Defaults to the user's home.")
        let timeoutProp = SchemaProperty(type: "number", description: "Timeout in seconds (optional, default 120).", defaultValue: .number(120))
        return JSONSchema(type: "object", properties: ["command": cmdProp, "cwd": cwdProp, "timeout": timeoutProp], required: ["command"])
    }()
    public let defaultApprovalLevel: ApprovalLevel = .prompt

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let command = arguments["command"]?.stringValue else {
            return .fail("Missing 'command' argument.")
        }
        let cwd = arguments["cwd"]?.stringValue
        let timeout = arguments["timeout"]?.numberValue ?? 120

        #if os(macOS) || os(Linux)
        return try await runShell(command: command, cwd: cwd, timeout: timeout)
        #else
        return .fail("bash is not supported on this platform.")
        #endif
    }

    #if os(macOS) || os(Linux)
    private func runShell(command: String, cwd: String?, timeout: Double) async throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let cwd, !cwd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let stdoutData = PipeBuffer()
        let stderrData = PipeBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in stdoutData.append(handle.availableData) }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in stderrData.append(handle.availableData) }

        do {
            try process.run()
        } catch {
            return .fail("Could not launch command: \(error.localizedDescription)")
        }

        // Timeout: kill the process if it runs over.
        let deadline = Date(timeIntervalSinceNow: timeout)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            if process.isRunning, Date() > deadline {
                process.terminate()
            }
        }

        // Wait on a background thread so we don't block the actor.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                process.waitUntilExit()
                timer.invalidate()
                cont.resume()
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        // Drain any final bytes.
        try? stdoutData.append(stdoutPipe.fileHandleForReading.readToEnd())
        try? stderrData.append(stderrPipe.fileHandleForReading.readToEnd())

        let stdout = String(data: stdoutData.data, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData.data, encoding: .utf8) ?? ""
        let exit = process.terminationStatus

        var summary = "exit \(exit)"
        if !stdout.isEmpty { summary += "\n--- stdout ---\n\(stdout)" }
        if !stderr.isEmpty { summary += "\n--- stderr ---\n\(stderr)" }
        if exit == 0 {
            return .ok(summary, data: [
                "exit_code": .number(Double(exit)),
                "stdout": .string(stdout),
                "stderr": .string(stderr)
            ])
        } else {
            return .fail(summary)
        }
    }
    #endif
}

/// Thread-safe accumulator for pipe data.
private final class PipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var data = Data()
    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }
}
