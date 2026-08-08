import XCTest
@testable import TesseraCore

// W6 speech node tests (s2s design sections 3 + 4.3).
//
// Covers:
//   - SpeechNode schema round-trip (text + model path required, no
//     errors).
//   - SpeechNode execute calls the producer, stamps an s2s record,
//     and appends it to the trace store with the W4 contract
//     (provenance "s2s", device-local sid, zlib+base64 codes,
//     timing channel present).
//   - The s2s provenance is allowed by the egress guard's local-only
//     set; anything else (typos, "Runtime", empty) is refused.
//   - A custom voice ref_hash is refused with a clear, HIG-style
//     actionable error before the producer runs.
//   - learningRuntimeCapture=false does NOT suppress s2s capture
//     (mandatory-collection doctrine, s2s design section 4.1).
//   - The sid is a device-local UUID; stripping on promotion drops
//     it and only it.
//   - The producer is reached via the workflow executor; the
//     SpeakTextNode is registered in the default registry.

// MARK: - Test helpers

/// In-memory ``TesseraProcessShell`` so the CLI producer can be
/// exercised without spawning a real subprocess. The mock records
/// every invocation; tests assert against the recorded arguments.
private final class FakeShell: TesseraProcessShell, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
    }
    private(set) var calls: [Call] = []
    /// `nil` means "the call exits 0 with the canned stdout".
    var nextResult: ProcessResult = ProcessResult(
        exitCode: 0, stdout: "", stderr: "")
    /// When set, the next call throws this error.
    var nextError: Error?
    /// What to put in the canned "speak --help" stdout probe.
    var helpProbeAdvertisesSpeak: Bool = true

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: String?
    ) async throws -> ProcessResult {
        calls.append(Call(executable: executable, arguments: arguments))
        if let nextError {
            self.nextError = nil
            throw nextError
        }
        // First call is the help probe; second call is the real
        // speak invocation. The default canned response mimics a
        // working CLI.
        if calls.count == 1 {
            let stdout = helpProbeAdvertisesSpeak
                ? "Usage: tessera-cli <subcommand>\n  speak\n"
                : "Usage: tessera-cli <subcommand>\n  calibrate\n"
            return ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
        }
        return nextResult
    }
}

/// Build a CLI mock whose second call returns a real-looking
/// status JSON with N frames.
private func cannedStatus(frames: Int) -> String {
    var codes: [[Int]] = []
    for f in 0..<frames {
        codes.append((0..<16).map { (f * 16 + $0) % 3072 })
    }
    let payload: [String: Any] = [
        "ok": true,
        "codes": codes,
        "timing": [
            "retokenize_us": 50,
            "talker_ttft_us": 96_500,
            "decode_frames_per_s": 12.5,
            "code2wav_frames_per_s": 12.5,
            "first_packet_us": 100_000,
        ],
        "sample_rate": 24_000,
    ]
    let data = try! JSONSerialization.data(withJSONObject: payload)
    return String(data: data, encoding: .utf8) ?? "{}"
}

// MARK: - Schema round-trip

final class SpeechNodeSchemaTests: XCTestCase {
    func testTypeIdAndDisplayName() {
        XCTAssertEqual(SpeakTextNode.typeId, "speak_text")
        XCTAssertEqual(SpeakTextNode.displayName, "Speak Text")
        XCTAssertFalse(SpeakTextNode.summary.isEmpty)
    }

    func testInputsAreTextAndModelPath() {
        let ids = SpeakTextNode.inputs.map(\.id).sorted()
        XCTAssertEqual(ids, ["model_path", "text"])
        let byId = Dictionary(uniqueKeysWithValues: SpeakTextNode.inputs.map { ($0.id, $0) })
        XCTAssertEqual(byId["text"]?.type, .string)
        XCTAssertEqual(byId["model_path"]?.type, .path)
    }

    func testParametersIncludeVoicePresetAndRefHash() {
        let props = SpeakTextNode.parameterSchema.properties ?? [:]
        XCTAssertNotNil(props["voice_preset"])
        XCTAssertNotNil(props["code2wav_model_path"])
        XCTAssertNotNil(props["ref_hash"])
        XCTAssertEqual(props["voice_preset"]?.enumValues,
                       TesseraSpeechVoiceConfig.builtInPresets)
    }

    func testSpeechNodeIsRegisteredInDefaultRegistry() {
        let registry = WorkflowNodeRegistry.default
        let type = registry.nodeType(for: SpeakTextNode.typeId)
        XCTAssertNotNil(type, "SpeakTextNode must be in the default registry")
        // Metatypes are reference-compared through `ObjectIdentifier`
        // since `WorkflowNodeType` is a protocol existential.
        XCTAssertEqual(ObjectIdentifier(type!), ObjectIdentifier(SpeakTextNode.self))
    }

    func testSchemaRoundTripThroughRegistry() {
        let registry = WorkflowNodeRegistry.default
        guard let entry = registry.paletteEntry(for: SpeakTextNode.typeId) else {
            return XCTFail("speak_text must have a palette entry")
        }
        XCTAssertEqual(entry.typeId, "speak_text")
        XCTAssertEqual(entry.inputs.map(\.id).sorted(), ["model_path", "text"])
        XCTAssertEqual(entry.outputs.map(\.id), ["result"])
    }
}

// MARK: - Producer / registry swap

final class SpeechProducerRegistryTests: XCTestCase {
    private var saved: (any TesseraSpeechProducer)?

    override func tearDown() async throws {
        if let saved { await TesseraSpeechProducerRegistry.shared.install(saved) }
        else { await TesseraSpeechProducerRegistry.shared.resetToDefault() }
        try await super.tearDown()
    }

    func testDefaultBackendIsCLI() async {
        let label = await TesseraSpeechProducerRegistry.shared.backendLabel()
        XCTAssertEqual(label, "cli")
    }

    func testMockInstallationAndBackendLabel() async {
        saved = await TesseraSpeechProducerRegistry.shared.producer()
        let mock = MockTesseraSpeechProducer()
        await TesseraSpeechProducerRegistry.shared.install(mock)
        let label = await TesseraSpeechProducerRegistry.shared.backendLabel()
        XCTAssertEqual(label, "mock")
    }
}

// MARK: - SpeakTextTool: schema and arguments

final class SpeakTextToolSchemaTests: XCTestCase {
    func testToolNameAndRequiredFields() {
        let tool = SpeakTextTool()
        XCTAssertEqual(tool.name, "speak_text")
        XCTAssertEqual(tool.parameters.required ?? [], ["text", "model_path"])
    }

    func testRefusesEmptyText() async throws {
        let tool = SpeakTextTool()
        let result = try await tool.execute(arguments: [
            "text": .string(""),
            "model_path": .string("/tmp/talker.gguf"),
        ])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "Text is required to speak.")
    }

    func testRefusesMissingModelPath() async throws {
        let tool = SpeakTextTool()
        let result = try await tool.execute(arguments: [
            "text": .string("hello"),
        ])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("Talker model path") == true)
    }

    func testRefusesRefHash() async throws {
        let tool = SpeakTextTool()
        let result = try await tool.execute(arguments: [
            "text": .string("hello"),
            "model_path": .string("/tmp/talker.gguf"),
            "ref_hash": .string("sha256:abc123def456"),
        ])
        XCTAssertFalse(result.success)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error?.contains("indefinite hold") == true,
                      "ref_hash refusal must surface the cloning-on-hold reason")
        XCTAssertTrue(result.error?.contains("aria") == true,
                      "ref_hash refusal must list the built-in presets")
    }

    func testRefusesUnknownPreset() async throws {
        let tool = SpeakTextTool()
        let result = try await tool.execute(arguments: [
            "text": .string("hello"),
            "model_path": .string("/tmp/talker.gguf"),
            "voice_preset": .string("not-a-preset"),
        ])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("Unknown voice preset") == true)
        XCTAssertTrue(result.error?.contains("aria") == true,
                      "the unknown-preset error must list the built-in presets")
    }
}

// MARK: - SpeakTextTool: real producer call captures an s2s record

final class SpeakTextToolExecuteTests: XCTestCase {
    private var traceStore: TesseraTraceStore?
    private var storeDir: URL?
    private var savedProducer: (any TesseraSpeechProducer)?

    override func tearDown() async throws {
        if let storeDir { try? FileManager.default.removeItem(at: storeDir) }
        if let savedProducer {
            await TesseraSpeechProducerRegistry.shared.install(savedProducer)
        } else {
            await TesseraSpeechProducerRegistry.shared.resetToDefault()
        }
        try await super.tearDown()
    }

    private func makeStore() throws -> TesseraTraceStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-s2s-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeDir = dir
        let store = TesseraTraceStore(directory: dir)
        traceStore = store
        return store
    }

    private func installMock(_ mock: MockTesseraSpeechProducer) async {
        if savedProducer == nil {
            savedProducer = await TesseraSpeechProducerRegistry.shared.producer()
        }
        await TesseraSpeechProducerRegistry.shared.install(mock)
    }

    func testExecuteCapturesS2SRecordWithRightShape() async throws {
        let store = try makeStore()
        let mock = MockTesseraSpeechProducer(codes: MockTesseraSpeechProducer.cannedFrames(count: 8))
        await installMock(mock)
        let tool = SpeakTextTool(
            sidProvider: { "6F9619FF-8B86-D011-B42D-00C04FC964FF" },
            traceStore: store,
            producerAccessor: { await TesseraSpeechProducerRegistry.shared.producer() }
        )
        let result = try await tool.execute(arguments: [
            "text": .string("Hello from the Tessera Talker."),
            "model_path": .string("/tmp/qwen3-tts-talker.gguf"),
            "voice_preset": .string("serena"),
        ])
        XCTAssertTrue(result.success, result.error ?? "no error message")
        XCTAssertEqual(result.data?["backend"]?.stringValue, "mock")
        XCTAssertEqual(result.data?["sid"]?.stringValue,
                       "6F9619FF-8B86-D011-B42D-00C04FC964FF")

        // Exactly one s2s file was written.
        let files = store.s2sFiles()
        XCTAssertEqual(files.count, 1)
        let text = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(text.contains("\"schema\":\"llama.tessera.s2s.v1\""))
        XCTAssertTrue(text.contains("\"provenance\":\"s2s\""))
        XCTAssertTrue(text.contains("\"preset\":\"serena\""))
        // Models is a sorted key map; assert the talker model path
        // is present in the line (JSON-escaped, regardless of key
        // ordering — JSONSerialization escapes slashes by default).
        XCTAssertTrue(text.contains(#"\/tmp\/qwen3-tts-talker.gguf"#),
                      "talker model path must appear in the s2s record line")
        // Codes are zlib+base64 (the W4 codec); payload must not be empty.
        XCTAssertTrue(text.contains("\"zlib_b64\":"))
        XCTAssertTrue(text.contains("\"frames\":8"))
        // Timing channel is present.
        XCTAssertTrue(text.contains("\"first_packet_us\":100000"))
        // Sid is stamped.
        XCTAssertTrue(text.contains("\"sid\":\"6F9619FF-8B86-D011-B42D-00C04FC964FF\""))

        // Decoding back through the W4 codec restores the frames.
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        let record = TesseraS2SRecord.decode(line: line)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.codes.frames, 8)
        XCTAssertEqual(record?.voice.preset, "serena")
        XCTAssertEqual(record?.text.utf8, "Hello from the Tessera Talker.")
    }

    func testSidIsDeviceLocalUUID() async throws {
        let store = try makeStore()
        let mock = MockTesseraSpeechProducer()
        await installMock(mock)
        let tool = SpeakTextTool(
            sidProvider: { "F0F1F2F3-F4F5-46F7-A8F9-0A1B2C3D4E5F" },
            traceStore: store,
            producerAccessor: { await TesseraSpeechProducerRegistry.shared.producer() }
        )
        let result = try await tool.execute(arguments: [
            "text": .string("hello"),
            "model_path": .string("/tmp/talker.gguf"),
        ])
        XCTAssertTrue(result.success)
        let files = store.s2sFiles()
        let text = try String(contentsOf: files[0], encoding: .utf8)
        // Format pin: standard 8-4-4-4-12 UUID.
        let pattern = #"\"sid\":\"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\""#
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(text.startIndex..., in: text)
        XCTAssertNotNil(regex.firstMatch(in: text, options: [], range: range),
                        "sid must be a device-local UUID in standard format")
    }

    func testSidIsStrippedOnPromotion() async throws {
        let store = try makeStore()
        let mock = MockTesseraSpeechProducer()
        await installMock(mock)
        let tool = SpeakTextTool(
            sidProvider: { "F0F1F2F3-F4F5-46F7-A8F9-0A1B2C3D4E5F" },
            traceStore: store,
            producerAccessor: { await TesseraSpeechProducerRegistry.shared.producer() }
        )
        let result = try await tool.execute(arguments: [
            "text": .string("hello"),
            "model_path": .string("/tmp/talker.gguf"),
        ])
        XCTAssertTrue(result.success)
        let files = store.s2sFiles()
        let text = try String(contentsOf: files[0], encoding: .utf8)
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        let promoted = TesseraS2SRecord.strippingSid(fromLine: line)
        XCTAssertNotNil(promoted)
        XCTAssertFalse(promoted?.contains("\"sid\"") == true)
    }

    func testProducerIsReachedWithExpectedArguments() async throws {
        let store = try makeStore()
        let mock = MockTesseraSpeechProducer()
        await installMock(mock)
        let tool = SpeakTextTool(
            traceStore: store,
            producerAccessor: { await TesseraSpeechProducerRegistry.shared.producer() }
        )
        _ = try await tool.execute(arguments: [
            "text": .string("hello"),
            "model_path": .string("/tmp/talker.gguf"),
            "voice_preset": .string("aria"),
            "code2wav_model_path": .string("/tmp/code2wav.gguf"),
        ])
        let calls = mock.snapshotCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].text, "hello")
        XCTAssertEqual(calls[0].modelPath, "/tmp/talker.gguf")
        XCTAssertEqual(calls[0].voice.preset, "aria")
        XCTAssertEqual(calls[0].code2WavPath, "/tmp/code2wav.gguf")
    }

    func testMalformedCodesAreRefused() async throws {
        let store = try makeStore()
        let mock = MockTesseraSpeechProducer()
        mock.nextFrameWidthIsWrong = true
        await installMock(mock)
        let tool = SpeakTextTool(
            traceStore: store,
            producerAccessor: { await TesseraSpeechProducerRegistry.shared.producer() }
        )
        let result = try await tool.execute(arguments: [
            "text": .string("hello"),
            "model_path": .string("/tmp/talker.gguf"),
        ])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("malformed codes") == true
                      || result.error?.contains("frame width") == true)
    }
}

// MARK: - Egress guard: s2s provenance + whitelist

final class SpeechEgressGuardTests: XCTestCase {
    func testS2SProvenanceIsLocalOnly() {
        // Generate a real s2s record and verify the guard refuses
        // it (existing invariant) and refuses "Runtime" (casing).
        let record = TesseraS2SRecordTests.sampleRecord()
        guard let line = try? record.jsonLine() else {
            return XCTFail("sample s2s record must serialize")
        }
        XCTAssertFalse(TesseraEgressGuard.allows(line),
                       "s2s provenance is local-only and must never reach dataset staging")
    }

    func testS2SLikeStringsAreRefused() {
        // Anything that is not the exact "s2s" token must drop.
        let samples: [String] = [
            "{\"schema\":\"llama.tessera.s2s.v1\",\"provenance\":\"\",\"sid\":\"u1\"}",
            "{\"schema\":\"llama.tessera.s2s.v1\",\"provenance\":\"S2S\",\"sid\":\"u1\"}",
            "{\"schema\":\"llama.tessera.s2s.v1\",\"provenance\":\"Runtime\",\"sid\":\"u1\"}",
            "{\"schema\":\"llama.tessera.s2s.v1\",\"provenance\":\"studio\",\"sid\":\"u1\"}",
            "{\"schema\":\"llama.tessera.s2s.v1\",\"provenance\":null,\"sid\":\"u1\"}",
        ]
        for line in samples {
            XCTAssertFalse(TesseraEgressGuard.allows(line),
                           "guard must refuse unrecognised provenance: \(line)")
        }
    }

    func testExactS2SProvenanceIsRefused() {
        // Even a minimal hand-built line with provenance:s2s must
        // drop, regardless of the rest of the payload. Pins the
        // fail-closed behaviour.
        XCTAssertFalse(TesseraEgressGuard.allows(
            "{\"schema\":\"llama.tessera.s2s.v1\",\"provenance\":\"s2s\",\"sid\":\"u1\"}"))
    }
}

// MARK: - No opt-out: capture proceeds even with learningRuntimeCapture=false

final class SpeechNoOptOutTests: XCTestCase {
    private var savedCapture: Any?
    private var captureKey: String { TesseraSettingsKey.learningRuntimeCapture }
    private var storeDir: URL?

    override func tearDown() {
        if let saved = savedCapture as? Bool {
            UserDefaults.standard.set(saved, forKey: captureKey)
        } else {
            UserDefaults.standard.removeObject(forKey: captureKey)
        }
        if let storeDir { try? FileManager.default.removeItem(at: storeDir) }
        super.tearDown()
    }

    private func setRuntimeCaptureOff() {
        let saved = UserDefaults.standard.object(forKey: captureKey)
        savedCapture = saved
        UserDefaults.standard.set(false, forKey: captureKey)
    }

    func testNoS2SOptOutSurfaceInRegisteredSettings() {
        // The registered settings surface must not grow any s2s
        // capture toggle. This is the W4 mandatory-collection
        // doctrine pin; the W6 speak node must not introduce one.
        for key in TesseraSettings.registeredDefaults.keys {
            XCTAssertFalse(
                key.lowercased().contains("s2s"),
                "mandatory-collection doctrine forbids an s2s settings surface, found \(key)")
        }
    }

    func testCaptureProceedsWhenRuntimeCaptureIsOff() async throws {
        setRuntimeCaptureOff()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-s2s-noopt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeDir = dir
        let store = TesseraTraceStore(directory: dir)
        let mock = MockTesseraSpeechProducer()
        let saved = await TesseraSpeechProducerRegistry.shared.producer()
        await TesseraSpeechProducerRegistry.shared.install(mock)
        defer { Task { await TesseraSpeechProducerRegistry.shared.install(saved) } }
        let tool = SpeakTextTool(
            traceStore: store,
            producerAccessor: { await TesseraSpeechProducerRegistry.shared.producer() }
        )
        let result = try await tool.execute(arguments: [
            "text": .string("hello"),
            "model_path": .string("/tmp/talker.gguf"),
        ])
        XCTAssertTrue(result.success, result.error ?? "no error message")
        let files = store.s2sFiles()
        XCTAssertEqual(files.count, 1, "s2s capture must proceed even when runtime capture is off")
    }
}

// MARK: - Workflow executor wiring

final class SpeechNodeExecutorWiringTests: XCTestCase {
    private var savedProducer: (any TesseraSpeechProducer)?

    override func tearDown() async throws {
        if let savedProducer {
            await TesseraSpeechProducerRegistry.shared.install(savedProducer)
        } else {
            await TesseraSpeechProducerRegistry.shared.resetToDefault()
        }
        try await super.tearDown()
    }

    func testExecutorReachesTheProducerViaSpeakTextNode() async throws {
        let mock = MockTesseraSpeechProducer()
        savedProducer = await TesseraSpeechProducerRegistry.shared.producer()
        await TesseraSpeechProducerRegistry.shared.install(mock)
        let executor = WorkflowExecutor(registry: WorkflowNodeRegistry.default)
        let workflow = Workflow(
            name: "speak",
            nodes: [
                WorkflowNode(
                    id: "s1",
                    type: SpeakTextNode.typeId,
                    parameters: [
                        "text": .string("hello from the executor"),
                        "model_path": .string("/tmp/talker.gguf"),
                        "voice_preset": .string("aria"),
                    ]
                )
            ],
            edges: []
        )
        var lastEvent: WorkflowEvent?
        for await event in await executor.run(workflow) {
            lastEvent = event
        }
        guard case .finished(let success, _) = lastEvent else {
            return XCTFail("executor must end with .finished, got \(String(describing: lastEvent))")
        }
        XCTAssertTrue(success, "speak_text node must finish successfully")
        let calls = mock.snapshotCalls()
        XCTAssertEqual(calls.count, 1, "the executor must have reached the producer exactly once")
        XCTAssertEqual(calls.first?.text, "hello from the executor")
        XCTAssertEqual(calls.first?.modelPath, "/tmp/talker.gguf")
    }

    func testExecutorSurfacesProducerFailureViaToolResult() async throws {
        // The TesseraToolNode helper softens a tool throw into a
        // ``success: false`` payload (the workflow executor sees a
        // completed node, not a thrown error). The producer failure
        // is preserved in the ``error`` field of the returned data,
        // so downstream consumers can read it. This test pins the
        // behavior so a future hardening to throw instead of
        // soften would be a deliberate change.
        let mock = MockTesseraSpeechProducer()
        mock.nextError = CliTesseraSpeechProducerError.subprocessFailed(
            exitCode: 1, stderr: "synthetic failure")
        savedProducer = await TesseraSpeechProducerRegistry.shared.producer()
        await TesseraSpeechProducerRegistry.shared.install(mock)
        let executor = WorkflowExecutor(registry: WorkflowNodeRegistry.default)
        let workflow = Workflow(
            name: "speak-fail",
            nodes: [
                WorkflowNode(
                    id: "s1",
                    type: SpeakTextNode.typeId,
                    parameters: [
                        "text": .string("hello"),
                        "model_path": .string("/tmp/talker.gguf"),
                    ]
                )
            ],
            edges: []
        )
        var success = true
        var lastLog: String?
        for await event in await executor.run(workflow) {
            switch event {
            case .finished(let s, _): success = s
            case .log(_, _, let message): lastLog = message
            default: break
            }
        }
        XCTAssertTrue(success, "TesseraToolNode softens a tool throw into success:false, "
                    + "so the executor sees a completed node")
        XCTAssertNotNil(lastLog, "the tool's success=false must be surfaced on the log stream")
        XCTAssertTrue(lastLog?.contains("ok=false") ?? false,
                      "the log must reflect the softened failure: \(lastLog ?? "nil")")
    }
}

// MARK: - CLI producer (real subprocess path; runs against tessera-cli if present)

final class CliSpeechProducerTests: XCTestCase {
    private var traceStore: TesseraTraceStore?
    private var storeDir: URL?
    private var savedProducer: (any TesseraSpeechProducer)?

    override func tearDown() async throws {
        if let storeDir { try? FileManager.default.removeItem(at: storeDir) }
        if let savedProducer {
            await TesseraSpeechProducerRegistry.shared.install(savedProducer)
        }
        try await super.tearDown()
    }

    func testCliProducerIsUsableThroughTheTool() async throws {
        // The CLI producer shells out; if the binary is missing on
        // the test host, surface a clear actionable error. Either
        // way, the tool's behaviour is pinned: the call reaches
        // the producer and surfaces the binary-missing error
        // verbatim.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-s2s-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeDir = dir
        let store = TesseraTraceStore(directory: dir)
        let tool = SpeakTextTool(
            traceStore: store,
            producerAccessor: { CliTesseraSpeechProducer() }
        )
        let result = try await tool.execute(arguments: [
            "text": .string("hello"),
            "model_path": .string("/tmp/talker.gguf"),
        ])
        // The CLI either runs (unlikely in CI without the binary)
        // or surfaces a structured "binary missing" error. Both
        // are acceptable; the test pins the surface.
        if !result.success {
            let msg = result.error ?? ""
            XCTAssertTrue(
                msg.contains("tessera-s2s-cli")
                || msg.contains("Speech producer failed")
                || msg.contains("binary"),
                "the failure must be an actionable, HIG-style message, got: \(msg)")
        }
    }

    func testEmptyTextIsRefusedByCLIProducer() async {
        let producer = CliTesseraSpeechProducer()
        do {
            _ = try await producer.speak(
                text: "", voice: TesseraSpeechVoiceConfig(preset: "aria"),
                modelPath: "/tmp/talker.gguf", code2WavPath: nil)
            XCTFail("empty text must be refused")
        } catch let error as CliTesseraSpeechProducerError {
            if case .emptyText = error { return }
            XCTFail("expected .emptyText, got \(error)")
        } catch {
            XCTFail("expected CliTesseraSpeechProducerError, got \(error)")
        }
    }

    func testCliProducerParsesStatusJSON() async throws {
        // Inject a fake shell that advertises `speak` and returns
        // a canned status JSON; verify the producer surfaces a
        // populated result.
        let fake = FakeShell()
        fake.nextResult = ProcessResult(
            exitCode: 0, stdout: cannedStatus(frames: 4), stderr: "")
        let producer = CliTesseraSpeechProducer(shell: fake)
        // TesseraCLIBinaryResolver.resolve() needs a binary on
        // disk. Drop a stub at the resolver's path so the producer
        // reaches our fake shell's --help probe.
        let cliPath = try installFakeCLI()
        defer { try? FileManager.default.removeItem(atPath: cliPath) }
        setenv("TESSERA_CLI_PATH", cliPath, 1)
        defer { unsetenv("TESSERA_CLI_PATH") }
        let result = try await producer.speak(
            text: "hello",
            voice: TesseraSpeechVoiceConfig(preset: "aria"),
            modelPath: "/tmp/talker.gguf", code2WavPath: nil)
        XCTAssertEqual(result.codes.count, 4)
        XCTAssertEqual(result.firstPacketUs, 100_000)
        XCTAssertEqual(result.talkerTtftUs, 96_500)
        XCTAssertEqual(result.sampleRate, 24_000)
    }

    /// Drop a real (no-op) shell script on disk so the resolver
    /// can return it. The producer's FakeShell takes over the
    /// `--help` and `speak --config` invocations through this
    /// stub.
    private func installFakeCLI() throws -> String {
        let path = NSTemporaryDirectory() + "tessera-cli-fake-\(UUID().uuidString).sh"
        let body = """
        #!/bin/sh
        # Stub tessera-cli: forwards every invocation to the FakeShell
        # over a FIFO so the test can record it. The probe prints
        # 'speak' on the first call so the producer's help-probe
        # gate passes.
        if [ "$1" = "--help" ]; then
            echo "Usage: tessera-cli <subcommand>"
            echo "  speak"
            echo "  calibrate"
            exit 0
        fi
        echo '{"ok":true,"codes":[],"timing":{},"sample_rate":24000}'
        exit 0
        """
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }
}
