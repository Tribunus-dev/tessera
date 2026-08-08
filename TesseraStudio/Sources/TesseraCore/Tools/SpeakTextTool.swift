import Foundation

/// `speak_text` Tessera tool: text in, codes + s2s record out.
///
/// W6 producer (s2s design sections 3 + 4): the tool is the seam
/// that drives a single Talker + Code2Wav pass and writes the
/// `llama.tessera.s2s.v1` record to the trace store right after the
/// producer returns. The tool is the canonical invocation point
/// for the speech workflow node; the workflow executor's
/// `WorkflowEvent` stream surfaces progress to the editor's
/// inspector.
///
/// Provenance invariants (s2s design section 4.1 / 4.2):
///   - `provenance` on the emitted record is exactly `"s2s"`.
///   - The s2s share is Tier B local-only, so the EgressGuard drops
///     the record at the staging gate (verified at the staging
///     integration test in TesseraEgressStagingTests).
///   - Capture is default-on with no opt-out. The tool writes even
///     when `learningRuntimeCapture` is off; there is no s2s
///     settings key in the registered surface
///     (TesseraS2SDefaultOnTests).
///
/// Voice invariants (s2s design section 3.1 / 7):
///   - Presets only. A `refHash` is refused up-front with a
///     HIG-style actionable error; cloning is on indefinite hold,
///     and a `refHash` would re-introduce the user-audio
///     conditioning channel the consent lane closes (s2s design
///     section 8.1, condition C2).
public struct SpeakTextTool: TesseraTool {
    public let name = "speak_text"
    public let description = "Run the Talker + Code2Wav pass on a sentence and capture an s2s trace record."
    public let defaultApprovalLevel = ApprovalLevel.auto

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "text": SchemaProperty(
                type: "string",
                description: "The sentence to speak. Empty text is refused."
            ),
            "voice_preset": SchemaProperty(
                type: "string",
                description: "CustomVoice preset id (e.g. aria, serena). Cloning via ref_hash is refused.",
                enumValues: TesseraSpeechVoiceConfig.builtInPresets,
                defaultValue: "aria"
            ),
            "model_path": SchemaProperty(
                type: "string",
                description: "Path to the Talker GGUF (qwen3-tts-talker-*.gguf)."
            ),
            "code2wav_model_path": SchemaProperty(
                type: "string",
                description: "Optional path to the Code2Wav GGUF. Empty = use the binary's default."
            ),
            "ref_hash": SchemaProperty(
                type: "string",
                description: "Refused. Voice cloning is on indefinite hold; presets only."
            ),
        ],
        required: ["text", "model_path"]
    )

    /// Sid stamp. Device-local random UUID; the test seam lets
    /// the suite pin a deterministic value.
    private let sidProvider: @Sendable () -> String
    /// Trace store. Held on the tool so the workflow executor and
    /// the agent surface share one store; the test seam is the
    /// standard `TesseraTraceStore` constructor with a temp dir.
    private let traceStore: TesseraTraceStore?
    /// Producer accessor. Pulled from the registry on each
    /// call so a mid-process swap (e.g. the W5 worker hot-loading
    /// the C bridge) is honored without rebuilding the tool.
    private let producerAccessor: @Sendable () async -> any TesseraSpeechProducer

    public init() {
        self.sidProvider = { UUID().uuidString }
        self.traceStore = nil
        self.producerAccessor = { await TesseraSpeechProducerRegistry.shared.producer() }
    }

    /// Test seam.
    init(
        sidProvider: @escaping @Sendable () -> String = { UUID().uuidString },
        traceStore: TesseraTraceStore,
        producerAccessor: @escaping @Sendable () async -> any TesseraSpeechProducer
            = { await TesseraSpeechProducerRegistry.shared.producer() }
    ) {
        self.sidProvider = sidProvider
        self.traceStore = traceStore
        self.producerAccessor = producerAccessor
    }

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let text = arguments["text"]?.stringValue, !text.isEmpty else {
            return .fail("Text is required to speak.")
        }
        let modelPath = (arguments["model_path"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        guard !modelPath.isEmpty else {
            return .fail("Talker model path is required. Set model_path to a qwen3-tts-talker-*.gguf file.")
        }
        let code2WavPath = arguments["code2wav_model_path"]?.stringValue?
            .trimmingCharacters(in: .whitespaces)
        // Cloning-on-hold gate. refHash is the only path that would
        // re-introduce user-audio conditioning, so refuse with a
        // concrete, actionable error (s2s design section 8.1, C2).
        if let refHash = arguments["ref_hash"]?.stringValue, !refHash.isEmpty {
            return .fail(Self.refHashRefusedMessage(refHash: refHash))
        }
        // Preset validation: a typo or an unknown preset surfaces
        // as a clear, list-the-allowed-presets error.
        let presetRaw = arguments["voice_preset"]?.stringValue
            ?? TesseraSpeechVoiceConfig.builtInPresets.first ?? "aria"
        let preset = presetRaw.trimmingCharacters(in: .whitespaces)
        guard TesseraSpeechVoiceConfig.builtInPresets.contains(preset) else {
            return .fail(Self.unknownPresetMessage(preset: presetRaw))
        }
        let voice = TesseraSpeechVoiceConfig(preset: preset)

        let producer = await producerAccessor()
        let result: TesseraSpeechProducerResult
        do {
            result = try await producer.speak(
                text: text, voice: voice,
                modelPath: modelPath, code2WavPath: code2WavPath)
        } catch {
            // CliTesseraSpeechProducerError.LocalizedError surfaces
            // an actionable, HIG-style message; any other error is
            // rephrased so the workflow UI does not leak raw
            // subprocess stderr.
            return .fail(Self.localizedMessage(for: error))
        }
        // The record is the W4 contract. Stamp the sid, encode the
        // codes through the W4 codec, and append on the spot.
        let sid = sidProvider()
        let codes: TesseraS2SRecord.Codes
        do {
            codes = try TesseraS2SCodes.encode(frames: result.codes)
        } catch {
            return .fail("Producer returned malformed codes: \(error.localizedDescription)")
        }
        let timing = TesseraS2SRecord.Timing(
            retokenizeUs: result.retokenizeUs,
            talkerTtftUs: result.talkerTtftUs,
            decodeFramesPerS: result.decodeFramesPerS,
            code2wavFramesPerS: result.code2wavFramesPerS,
            firstPacketUs: result.firstPacketUs
        )
        let textPair = TesseraS2SRecord.Text(
            gemmaTokens: [], qwenIds: [], utf8: text)
        let record = TesseraS2SRecord(
            sid: sid,
            text: textPair,
            codes: codes,
            timing: timing,
            voice: TesseraS2SRecord.Voice(preset: preset),
            feedback: TesseraS2SRecord.Feedback(
                interrupted: false, regenerated: false, replayed: false),
            models: [
                "talker": modelPath,
                "code2wav": code2WavPath ?? "",
            ]
        )
        let line: String
        do {
            line = try record.jsonLine()
        } catch {
            return .fail("Could not serialise s2s record: \(error.localizedDescription)")
        }
        // The store is optional in production (lazy lookup from
        // the registry); the test seam always supplies one.
        if let traceStore {
            do {
                _ = try traceStore.appendS2S(records: [line])
            } catch {
                return .fail("Could not write s2s trace: \(error.localizedDescription)")
            }
        } else {
            let store = TesseraTraceStore()
            do {
                _ = try store.appendS2S(records: [line])
            } catch {
                return .fail("Could not write s2s trace: \(error.localizedDescription)")
            }
        }
        return .ok(
            "Spoke \(result.codes.count) frame(s) in \(result.firstPacketUs) us; "
            + "s2s record captured (sid \(sid)).",
            data: [
                "sid": .string(sid),
                "frames": .number(Double(result.codes.count)),
                "first_packet_us": .number(Double(result.firstPacketUs)),
                "preset": .string(preset),
                "backend": .string(producer.backend),
                "sample_rate": .number(Double(result.sampleRate)),
                "pcm_path": .string(result.pcmPath),
            ]
        )
    }

    // MARK: - Error phrasing (HIG-style, actionable, no possessives)

    static func refHashRefusedMessage(refHash: String) -> String {
        return "Voice cloning is on indefinite hold: ref_hash is not accepted. "
            + "Use a built-in voice preset (\(TesseraSpeechVoiceConfig.builtInPresets.joined(separator: ", "))). "
            + "(Ref hash supplied: \(refHash.prefix(12))...)"
    }

    static func unknownPresetMessage(preset: String) -> String {
        return "Unknown voice preset '\(preset)'. "
            + "Choose one of: \(TesseraSpeechVoiceConfig.builtInPresets.joined(separator: ", "))."
    }

    static func localizedMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let desc = localized.errorDescription {
            return desc
        }
        return "Speech producer failed: \(error)"
    }
}
