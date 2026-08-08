import Foundation

// MARK: - Mock producer (tests only)

/// Test-only ``TesseraSpeechProducer`` that returns canned codes +
/// timing without spawning a subprocess. The workflow tests install
/// this in the registry's `setUp` and restore the CLI default in
/// `tearDown`, so the suite stays hermetic regardless of whether
/// the W5 binary is on disk.
///
/// The mock stamps every call into ``calls`` so tests can assert
/// the SpeakTextTool (or any other caller) actually reached the
/// producer with the arguments the user typed.
public final class MockTesseraSpeechProducer: TesseraSpeechProducer, @unchecked Sendable {
    public let backend = "mock"

    public struct Call: Sendable, Equatable {
        public let text: String
        public let voice: TesseraSpeechVoiceConfig
        public let modelPath: String
        public let code2WavPath: String?
    }

    public private(set) var calls: [Call] = []
    private let lock = NSLock()

    /// What the next ``speak`` returns. Reassignable from tests so
    /// one mock instance can serve "success then failure" sequences
    /// without rebuilding the producer.
    public var nextResult: TesseraSpeechProducerResult
    /// What the next ``speak`` throws. Wins over ``nextResult`` when
    /// non-nil. The lock-protected ``consumeError`` path makes a
    /// throw a one-shot so two consecutive calls don't both see the
    /// same error.
    public var nextError: Error?
    /// When true, the next ``speak`` returns codes whose frame width
    /// is wrong. The producer is the boundary, so a malformed
    /// payload surfaces here; the SpeakTextTool hands the throw
    /// up to the workflow executor.
    public var nextFrameWidthIsWrong = false

    public init(
        codes: [[UInt16]]? = nil,
        talkerTtftUs: Int = 96_500,
        firstPacketUs: Int = 100_000
    ) {
        let resolved = codes ?? Self.cannedFrames(count: 12)
        self.nextResult = TesseraSpeechProducerResult(
            codes: resolved,
            retokenizeUs: 50,
            talkerTtftUs: talkerTtftUs,
            decodeFramesPerS: 12.5,
            code2wavFramesPerS: 12.5,
            firstPacketUs: firstPacketUs,
            pcmPath: "",
            sampleRate: 24_000
        )
    }

    public func speak(
        text: String,
        voice: TesseraSpeechVoiceConfig,
        modelPath: String,
        code2WavPath: String?
    ) async throws -> TesseraSpeechProducerResult {
        lock.lock()
        calls.append(Call(
            text: text, voice: voice,
            modelPath: modelPath, code2WavPath: code2WavPath))
        let err = nextError
        if nextError != nil { nextError = nil }
        let badWidth = nextFrameWidthIsWrong
        if nextFrameWidthIsWrong { nextFrameWidthIsWrong = false }
        lock.unlock()

        if let err { throw err }
        if badWidth {
            // Returning a wrong-width frame mirrors the W5-side
            // error class: the CLI is the boundary, so the throw
            // here matches what a real failure would look like.
            throw CliTesseraSpeechProducerError.subprocessFailed(
                exitCode: 0,
                stderr: "frame width 8, expected 16")
        }
        return nextResult
    }

    /// Read-only snapshot of the call log. Useful for assertions
    /// that don't want to hold the lock.
    public func snapshotCalls() -> [Call] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    /// Reset the call log and the queued error. Tests reuse a
    /// single mock across cases; the explicit reset is cheaper
    /// than rebuilding the registry.
    public func reset() {
        lock.lock()
        calls.removeAll()
        nextError = nil
        nextFrameWidthIsWrong = false
        lock.unlock()
    }

    /// Default canned frame stream. Two-frame ramp + ten steady
    /// frames so the trace record has 12 real frames; every code
    /// fits the codebook's 0..3071 range.
    public static func cannedFrames(count: Int) -> [[UInt16]] {
        let perFrame = TesseraS2SRecord.codesPerFrame
        return (0..<count).map { f in
            (0..<perFrame).map { c in UInt16((f * perFrame + c) * 3 % 3072) }
        }
    }
}
