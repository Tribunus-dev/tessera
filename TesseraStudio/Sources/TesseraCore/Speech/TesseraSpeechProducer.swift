import Foundation

// MARK: - Result type

/// One Talker + Code2Wav pass for a single text input (s2s design section
/// 3.2 / 4.1). Carries the per-frame codec codes plus the timing channel
/// the trace record needs, plus a synthetic PCM placeholder so the
/// downstream audio node can pick it up. The PCM is empty for the CLI
/// producer (the CLI writes the file the workflow executor reads); the
/// mock returns hand-built bytes for tests.
///
/// Codes are frame-major, each frame exactly ``TesseraS2SRecord.codesPerFrame``
/// UInt16 values (index 0 = codebook 0, indices 1-15 = acoustic layers),
/// matching the on-disk s2s.v1 layout 1:1.
public struct TesseraSpeechProducerResult: Sendable, Equatable {
    public var codes: [[UInt16]]
    /// Microseconds spent on text retokenize (Gemma detokenize -> Qwen
    /// retokenize). Recorded on the timing channel; mock returns 0.
    public var retokenizeUs: Int
    /// Microseconds from the producer call to the first complete 16-code
    /// frame (Talker TTFT). Recorded on the timing channel.
    public var talkerTtftUs: Int
    /// Frames per second during the Talker decode loop.
    public var decodeFramesPerS: Double
    /// Frames per second out of the Code2Wav graph (measured at the
    /// producer boundary, not the on-device graph).
    public var code2wavFramesPerS: Double
    /// Microseconds from the producer call to the first PCM sample out.
    /// Recorded on the timing channel; equals talker TTFT + a Code2Wav
    /// warm-up for real inference, equals talker TTFT for the mock.
    public var firstPacketUs: Int
    /// Path to the PCM file the CLI wrote. Empty when the producer is
    /// in-process (the mock returns synthetic bytes inline).
    public var pcmPath: String
    /// Sample rate of the PCM payload (Hz). The CLI producer reads it
    /// from the Code2Wav config; the mock returns 24000 to match.
    public var sampleRate: Int

    public init(
        codes: [[UInt16]],
        retokenizeUs: Int,
        talkerTtftUs: Int,
        decodeFramesPerS: Double,
        code2wavFramesPerS: Double,
        firstPacketUs: Int,
        pcmPath: String,
        sampleRate: Int
    ) {
        self.codes = codes
        self.retokenizeUs = retokenizeUs
        self.talkerTtftUs = talkerTtftUs
        self.decodeFramesPerS = decodeFramesPerS
        self.code2wavFramesPerS = code2wavFramesPerS
        self.firstPacketUs = firstPacketUs
        self.pcmPath = pcmPath
        self.sampleRate = sampleRate
    }
}

// MARK: - Producer protocol

/// One utterance of text -> 16-codebook codes + PCM. The contract is
/// the seam between Swift and the C-side Talker + Code2Wav path
/// (s2s design section 3.2): the W5 worker ships a C bridge; until it
/// does, the CLI-backed default in this file shells out to
/// `tessera-s2s-cli` and the tests use a mock that returns canned
/// codes.
///
/// The producer is ``Sendable``; the registry stores an `any
/// TesseraSpeechProducer` and swaps implementations at runtime.
public protocol TesseraSpeechProducer: Sendable {
    /// The asset role this producer covers. "cli" for the default,
    /// "mock" for the in-memory test producer, "ffi" once the W5
    /// worker ships the C bridge. Logged on the workflow progress
    /// pane so the user knows which path served the utterance.
    var backend: String { get }

    /// Run one utterance. Implementations MUST throw on a missing
    /// model, a malformed response, or a frame-width error
    /// (matches ``TesseraS2SCodesError``); the workflow executor
    /// surfaces the throw as ``WorkflowExecutorError.nodeFailed``.
    /// Implementations MUST honour cooperative cancellation via
    /// `Task.checkCancellation()`.
    func speak(
        text: String,
        voice: TesseraSpeechVoiceConfig,
        modelPath: String,
        code2WavPath: String?
    ) async throws -> TesseraSpeechProducerResult
}

// MARK: - Voice config (the only user-facing knob)

/// Voice configuration. Presets only (s2s design section 3.1 / 7:
/// cloning on indefinite hold). A non-preset `refHash` is rejected
/// by ``TesseraSpeechProducerRegistry.allowedVoices()``'s caller,
/// the SpeakTextTool: refHash paths would re-introduce user-audio
/// conditioning, exactly the channel the consent lane (s2s design
/// section 8.1, condition C2) closes.
public struct TesseraSpeechVoiceConfig: Sendable, Equatable, Hashable, Codable {
    public var preset: String
    public var refHash: String?

    public init(preset: String, refHash: String? = nil) {
        self.preset = preset
        self.refHash = refHash
    }

    /// Built-in presets the Talker ships with (CustomVoice preset
    /// list, s2s design section 3.1). The names match the Qwen3-TTS
    /// CustomVoice surface; the registry is the source of truth for
    /// what the UI offers.
    public static let builtInPresets: [String] = [
        "aria", "serena", "vivian", "brian", "tara", "leo",
    ]
}
