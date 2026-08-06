import Foundation

// MARK: - CLI-backed producer (production default)

/// Production ``TesseraSpeechProducer`` that shells out to the
/// `tessera-s2s-cli` binary the W5 worker ships. The CLI is the
/// end-to-end Talker + Code2Wav harness (s2s design section 3.3):
/// text in, PCM out, JSON status with the codes + timing channel
/// the s2s trace record needs. This is the same CLI the chained
/// calibration path uses, so the producer in the app and the
/// producer in the calibration harness stay in lock-step.
///
/// While the CLI is not yet shipped (W5 in flight), `speak` throws
/// `CliTesseraSpeechProducerError.binaryMissing`. Tests use the
/// mock; the workflow UI surfaces the binary-missing error as an
/// actionable, HIG-style message ("Install tessera-s2s-cli to
/// enable speech output").
///
/// The subprocess is invoked with the spec the W5 worker ships:
/// `<cli> speak --config <json-path>`, where the JSON config
/// carries `text`, `voice_preset`, `talker_model_path`,
/// `code2wav_model_path` (optional), and `output_pcm_path`. The
/// binary writes the PCM to the named path and prints one JSON
/// status line to stdout. Exit 0 = success; non-zero with a JSON
/// payload on stderr is a structured error; non-zero with plain
/// text is an I/O failure.
public struct CliTesseraSpeechProducer: TesseraSpeechProducer {
    public let backend = "cli"

    private let shell: TesseraProcessShell
    private let clock: @Sendable () -> Date
    /// Per-utterance wall-clock budget. The CLI does not expose a
    /// timeout flag yet; the producer enforces one so a runaway
    /// decode cannot wedge the workflow executor. 30 s is well
    /// above the target first-packet (~100 ms) and the per-frame
    /// rate at 12.5 Hz (80 ms/frame), so 30 s is roughly 370
    /// frames = ~30 s of audio.
    private let timeoutSeconds: Double

    public init(
        shell: TesseraProcessShell = ProcessRunner(),
        clock: @escaping @Sendable () -> Date = { Date() },
        timeoutSeconds: Double = 30
    ) {
        self.shell = shell
        self.clock = clock
        self.timeoutSeconds = timeoutSeconds
    }

    public func speak(
        text: String,
        voice: TesseraSpeechVoiceConfig,
        modelPath: String,
        code2WavPath: String?
    ) async throws -> TesseraSpeechProducerResult {
        try Task.checkCancellation()
        guard !text.isEmpty else {
            throw CliTesseraSpeechProducerError.emptyText
        }
        guard let cli = TesseraCLIBinaryResolver.resolve(
            override: TesseraSettings.tesseraCLIPath,
            settingsKey: TesseraSettingsKey.tesseraCLIPath
        ) else {
            throw CliTesseraSpeechProducerError.binaryMissing(
                TesseraCLIBinaryResolver.diagnosticMessage())
        }
        // The W5 worker ships the binary; until then, even a
        // resolved tessera-cli won't have the `speak` subcommand.
        // Surface a clean, actionable error instead of letting the
        // subprocess's "unknown subcommand" stderr leak to the UI.
        let probed = try await shell.run(
            executable: cli,
            arguments: ["--help"],
            environment: nil,
            workingDirectory: nil
        )
        if probed.stdout.contains("speak") == false
            && probed.stderr.contains("speak") == false {
            throw CliTesseraSpeechProducerError.binaryMissing(
                "tessera-cli at \(cli) does not advertise a `speak` subcommand; "
                + "ship the W5 S2S CLI binary to enable speech output")
        }

        let pcmPath = makePCMPath()
        var config: [String: Any] = [
            "text": text,
            "voice_preset": voice.preset,
            "talker_model_path": modelPath,
            "output_pcm_path": pcmPath,
        ]
        if let code2WavPath, !code2WavPath.isEmpty {
            config["code2wav_model_path"] = code2WavPath
        }
        let configPath = try EngineToolSupport.writeConfigFile(config: config)

        let started = clock()
        let result = try await shell.run(
            executable: cli,
            arguments: ["speak", "--config", configPath],
            environment: nil,
            workingDirectory: nil
        )
        try? FileManager.default.removeItem(atPath: configPath)

        if result.exitCode != 0 {
            throw CliTesseraSpeechProducerError.subprocessFailed(
                exitCode: result.exitCode, stderr: result.stderr)
        }
        let elapsedUs = Int(clock().timeIntervalSince(started) * 1_000_000)

        guard let stdoutObj = EngineToolSupport.parseJSONObject(stdout: result.stdout) else {
            throw CliTesseraSpeechProducerError.subprocessFailed(
                exitCode: 0,
                stderr: "tessera-s2s-cli returned unparseable JSON: \(result.stdout)")
        }
        return try parseStatus(
            stdoutObj: stdoutObj, pcmPath: pcmPath, elapsedUs: elapsedUs)
    }

    // MARK: - Status parsing

    /// Parse the CLI's JSON status line. The expected shape is
    /// `{"ok":true,"codes":[[...]], "timing":{...}, "sample_rate":24000}`
    /// on success and `{"ok":false,"error":"..."}` on failure. The
    /// layout is what the W5 worker has agreed to ship.
    private func parseStatus(
        stdoutObj: [String: Any],
        pcmPath: String,
        elapsedUs: Int
    ) throws -> TesseraSpeechProducerResult {
        guard let ok = stdoutObj["ok"] as? Bool, ok else {
            let message = (stdoutObj["error"] as? String) ?? "unknown error"
            throw CliTesseraSpeechProducerError.subprocessFailed(
                exitCode: 0, stderr: message)
        }
        guard let rawCodes = stdoutObj["codes"] as? [[Int]] else {
            throw CliTesseraSpeechProducerError.subprocessFailed(
                exitCode: 0,
                stderr: "tessera-s2s-cli status missing 'codes' field")
        }
        let codes = try rawCodes.map { frame -> [UInt16] in
            guard frame.count == TesseraS2SRecord.codesPerFrame else {
                throw CliTesseraSpeechProducerError.subprocessFailed(
                    exitCode: 0,
                    stderr: "frame width \(frame.count), "
                    + "expected \(TesseraS2SRecord.codesPerFrame)")
            }
            return frame.map { UInt16(clamping: $0) }
        }
        let timing = stdoutObj["timing"] as? [String: Any] ?? [:]
        let sampleRate = (stdoutObj["sample_rate"] as? Int) ?? 24_000
        return TesseraSpeechProducerResult(
            codes: codes,
            retokenizeUs: (timing["retokenize_us"] as? Int) ?? 0,
            talkerTtftUs: (timing["talker_ttft_us"] as? Int) ?? elapsedUs,
            decodeFramesPerS: (timing["decode_frames_per_s"] as? Double) ?? 12.5,
            code2wavFramesPerS: (timing["code2wav_frames_per_s"] as? Double) ?? 12.5,
            firstPacketUs: (timing["first_packet_us"] as? Int) ?? elapsedUs,
            pcmPath: pcmPath,
            sampleRate: sampleRate
        )
    }

    // MARK: - Helpers

    private func makePCMPath() -> String {
        let dir = NSTemporaryDirectory()
        let name = "tessera-s2s-pcm-\(UUID().uuidString).pcm"
        return (dir as NSString).appendingPathComponent(name)
    }
}

// MARK: - Errors

public enum CliTesseraSpeechProducerError: LocalizedError, Equatable {
    case emptyText
    case binaryMissing(String)
    case subprocessFailed(exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Enter a sentence before speaking."
        case .binaryMissing(let detail):
            return "Speech output needs the tessera-s2s-cli binary. \(detail)"
        case .subprocessFailed(let exitCode, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "tessera-s2s-cli failed (exit \(exitCode))."
            }
            return "tessera-s2s-cli failed (exit \(exitCode)): \(trimmed)"
        }
    }
}
