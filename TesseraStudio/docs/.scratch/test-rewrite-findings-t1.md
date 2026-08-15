# Test-rewrite findings: cluster T1 (Agent / Encryption / Learning / Editor-partial)

Cluster scope: `Tests/TesseraCoreTests/Support/DoctrineTestSupport.swift`
(shared timeout support, all waves), `Tests/TesseraCoreTests/Agent/`,
`Tests/TesseraCoreTests/Encryption/`, `Tests/TesseraCoreTests/Learning/`,
and exactly `Tests/TesseraCoreTests/Editor/TimeLimitedUndoTests.swift` +
`Tests/TesseraCoreTests/Editor/AuditLogHeadTests.swift`.

## XCTExpectFailure rows (suspected code bugs)

- **testRandomPassesUnderDirectoryFinalPassWritesZeroBytes**
  (Tests/TesseraCoreTests/Encryption/SecureOverwriteTests.swift:~100):
  SUSPECTED CODE BUG: `SecureOverwrite.overwriteAndDelete`'s "final zero
  pass" never writes zero bytes - `writeRandomPass(...)` unconditionally
  calls `randomFill(&buffer, n)` as the first statement of its write
  loop on every invocation, including the one the caller makes after
  explicitly zeroing `buffer` for the documented "N random passes plus a
  final zero pass" step. The pre-zeroed buffer is immediately
  overwritten by `randomFill` before anything reaches disk, so the final
  pass silently runs one more random-fill pass instead of a zero pass.
  Violates the file's own top-of-file doc comment: "Overwrites a file
  with random bytes (N passes) and then zeros, before unlinking it."
  Location of the bug itself:
  `Sources/TesseraCore/Encryption/SecureOverwrite.swift`, the
  `overwriteAndDelete`/`writeRandomPass` pair (~lines 177-243).

## Contract sources not found (documented gaps, not silently skipped)

- **TesseraToolRegistry.default's exact ~29-tool roster**: no design doc
  or AGENTS.md line enumerates the exact tool list beyond the doc
  comment's prose summary ("the 8 v1 tools plus the 9 learning tools
  plus the 9 Python-tool wrappers"). `docs/agent-tools-surface.md`
  describes a DIFFERENT, not-yet-landed tool surface (`doc_*`/`sheet_*`/
  `slide_*`/`drawing_*`/`materials_*`/`lifecycle_*` prefixes for the
  product-surface expansion), not the calibration/productivity tool set
  actually registered today. `TesseraToolRegistryTests.swift` tests the
  registry's own logic (lookup, override-by-name, sorted enumeration)
  against fabricated stub tools instead of iterating the real roster, to
  avoid a circular oracle (rule 7); it only spot-checks that `list_models`
  exists (verified against `ListModelsTool.name` source) and that the
  full roster has no duplicate names.

- **TesseraActionClass.destructiveVerbs' exact 17-word list**: no
  contract outside the implementation's own literal array names these
  specific verbs (rm, rmdir, del, delete, drop, purge, erase, format,
  mkfs, dd, shred, sudo, chmod, chown, kill, shutdown, reboot).
  `TesseraActionClassTests.testEveryDestructiveVerbIsIrreversibleAtLowRisk`
  hand-copies this list as a rule-9 fixture (each individual verb is
  independently a reasonable, common-sense "destructive shell verb" a
  reviewer would expect on such a list), but the exact SET was learned
  by reading the source array, not from an external design doc. Flagged
  per the prime rule's spirit; the single-fixture test
  (`testDestructiveVerbHeadIsIrreversible`, using only "rm") is not
  affected by this caveat.

- **`ChatProgressFeed` (SwiftUI view)**: no independently-testable logic
  beyond `LiveStateEntry`/its payload structs, which are fully covered
  in `UnifiedChatRowTests.swift`. No dedicated `ChatProgressFeedTests.swift`
  was created; docs/PROJECT-STATUS.md references a
  `ChatProgressFeedTests.testSurfaceUpdateLatency` for the P95 <500ms
  budget, which requires timing `UnifiedChatController`'s append path
  under load -- not attempted here given the time budget; logged as a
  gap rather than a guessed/weak timing assertion.

- **`TesseraDualAgentController.send(_:)`**: drives the real
  streaming/tool-call/approval machinery end to end (spawns tasks,
  drives both loops concurrently, updates `statusPill`). Out of scope
  for this pass; `TesseraDualAgentControllerTests.swift` covers the pure
  value types (`DualAgentMessage`, `CollabTraceEntry`) and the
  documented reset/seed methods only.

- **Learning/ subsystem, 38 files, ~20 not reached this pass** (time
  budget; per this cluster's explicit contract-hierarchy-fallback
  instructions: "write what you can... list the ungrounded remainder").
  Files with NO test file in this pass (construction/Codable/doc-comment
  behavior was not attempted; not because a contract search came back
  empty, but because the file itself was not read closely enough in the
  time available to write a grounded test):
  `TesseraApproverNetwork.swift` (has math worth fixture+property
  testing - predict/train/calibrationMetrics/checkCollapseGuard),
  `TesseraS2SRecord.swift` + its nested Text/Codes/Timing/Voice/Feedback
  structs and `TesseraS2SCodes.encode/decode` (a real codec round-trip
  candidate), `TesseraSessionScorecard.swift` (has documented threshold
  constants: minTokens=64, minAcceptance=0.10, maxRepetition=0.60,
  maxGarbage=0.30, ngramSize=4, worth fixture testing against those),
  `TesseraSessionTraceReader.swift`, `TesseraTraceStore.swift` (has an
  injectable `directory:` init, a real store-shape candidate),
  `TesseraCurationLedger.swift` (has an injectable `directory:` init,
  same shape), `TesseraCurationService.swift`,
  `TesseraEscalationService.swift` + `TesseraEscalationContracts.swift`'s
  `TesseraTeacherConfig`/`TesseraTeacherAssessment`/`TesseraEscalationFrame`
  Codable types, `TesseraCapabilityEvalService.swift` +
  `TesseraCapabilityEvalStore.swift`, `TesseraAnonymizerService.swift`,
  `TesseraApproverNetwork.swift`, `TesseraAutonomyService.swift` (the
  REAL (non-noop) ratchet implementation -- large, 28KB, the actual
  "hard-to-get-right" logic behind `TesseraAutonomyStoring`; only the
  no-op default and the data model types are tested this pass),
  `TesseraEvalInstanceStore.swift`, `TesseraForagingStore.swift`,
  `TesseraLearningStore.swift` (also not `public`), `TesseraProposalRegistry.swift`,
  `TesseraReasoningPlaybookStore.swift`, `TesseraReferenceKnowledgeStore.swift`,
  `TesseraSessionCurationScheduler.swift` + `TesseraSessionCurationStage.swift`,
  `TesseraTeacherAssessor.swift`, `TesseraTrackR.swift`,
  `TesseraTrainBinaryResolver.swift`, `TesseraTrainingOrchestrator.swift`
  + `TesseraTrainingScheduler.swift`, `TesseraVocabDecoder.swift`
  (dlopen-adjacent, likely empirical-probe territory per rule 10),
  `TesseraAdaptationScheduler.swift` + `TesseraAssessmentScheduler.swift`
  (the `onFinished` hook AGENTS.md explicitly calls out for item 1D --
  **this is a real gap against an explicit AGENTS.md contract line** and
  should be prioritized first if this cluster resumes;
  `TesseraNotificationBudgetTests.swift` covers the budget itself
  thoroughly but not the two schedulers' hook-firing behavior),
  `TesseraLearningServices.swift` (the `installDefaults` composition
  root), `TesseraHarnessBinary.swift` (internal, not `public`).

- **TesseraEncryptedVolume's create/mount/unmount/reset**: shells out to
  real `hdiutil` against a real disk image. This is empirical-probe
  territory (rule 10): it needs a clearly-marked, gated file
  (`TESSERA_...` env gate), a probe-date + hdiutil-version comment, a
  120s timeout via `DoctrineTimeout.probe`, and (rule 11) an ungated
  shadow of the same contract against a stubbed/protocol seam. The
  actor's create/mount/unmount are NOT protocol-abstracted (unlike
  `PleadTheFifthVolume`), so there is no seam to write the ungated
  shadow against without either (a) a source-side refactor (out of
  scope for a test-only pass) or (b) a live hdiutil probe with no
  ungated pairing, which would violate rule 11. Left untested rather
  than shipping a rule-11 violation; `TesseraEncryptedVolumeTests.swift`
  covers the two pure value types (`TesseraVolumeConfig`,
  `TesseraEncryptedVolumeError`) only.

- **TesseraVolumeMigrator.migrate(into:from:onProgress:)**: requires a
  real `TesseraEncryptedVolume` (same hdiutil dependency as above); its
  internal `copyDirectory`/`verifyCopy`/`sizesMatch`/`overwriteDirectory`
  helpers are `private` (not reachable even via `@testable import`), so
  there is no way to unit-test the copy/verify/wipe logic in isolation
  from the full hdiutil-backed flow. `TesseraVolumeMigratorTests.swift`
  covers the pure public value types (`Report`, `Source`, `Destination`)
  only.

- **TextInputInterceptor.install()**: not tested at all, per its own doc
  comment: "'Verified manually' applies to the swizzle: XCTest cannot
  drive a real keystroke through an AppKit/UIKit method swizzle." Beyond
  that, `install()` performs a REAL, PROCESS-WIDE `method_exchangeImplementations`
  swap of `-[NSTextView didChangeText]` (and the UIKit equivalents) --
  calling it even once in a test would silently alter the behavior of
  every `NSTextView` for the remainder of the `swift test` process
  (including any other cluster's tests that construct or drive a text
  view), with no `uninstall()` to undo it. Not exercised at all, by
  design; this is a stronger version of the `TesseraDataRoot.setSandboxRoot`
  leak concern below and was judged too risky to touch even once.

## Cross-test process-state leaks (rule 4), documented rather than
## silently worked around

- **TesseraDataRoot.setSandboxRoot(_:for:)** has no reset/unset API
  (only `setMountedRoot(nil)` cleanly resets). `TesseraDataRootTests.swift`
  uses it (the doc comment names it "the documented test-only seam") to
  test the real, important sandbox-fallback contract, using only inert
  `/tmp/doctrine-*` placeholder paths -- but the override persists for
  the remainder of the `swift test` process once set. If a later
  cluster's test reads `TesseraDataRoot.appSupport()`/`.caches()`/
  `.preferences()` without first setting its own override, it will see
  one of this file's placeholder paths instead of the real default. No
  data-loss risk (the paths are inert), but a source-side reset API
  (`TesseraDataRoot.resetSandboxRootOverrides()` or similar) would
  close this gap; flagging for the architect rather than silently
  declining to test the fallback contract.

- **TesseraApprovalEngine** persists overrides to
  `UserDefaults.standard` under a fixed key
  (`"tessera.approval.overrides"`), not injectable.
  `TesseraApprovalEngineTests.swift` removes that key in
  setUp/tearDown so it is deterministic regardless of run order, but
  any OTHER cluster's test that also touches `TesseraApprovalEngine`
  and does not do the same cleanup could observe a dirty key depending
  on interleaving. Documented here so a later cluster reusing
  `TesseraApprovalEngine` in its own tests is aware of the shared key.

## Safety-motivated scope decisions (destructive real-secret risk),
## explained in the affected test files' own header comments too

- `PleadTheFifthExecutorTests.swift` never calls `executor.destroyAll(...)`:
  step 3/4 ("destroy_volume_password"/"destroy_dak") delete the FIXED
  production Keychain account names
  (`PleadTheFifthKeychain.volumePasswordAccount`/`.dataAccessKeyAccount`)
  with no injectable seam, regardless of which mock volume/sidecar is
  passed to the executor's test-only initializer. On a machine with a
  real "Plead the Fifth" volume configured, running the real wipe
  sequence in a test would irreversibly destroy that user's actual
  encrypted-volume access. Tested via directly-constructed
  `WipeReport`/`WipeStep` values instead (both have an accessible
  memberwise init), covering `succeeded`, Codable round-trip, and the
  documented step-5-partial-failure caveat without ever running a step.

- `TesseraKeychainVolumeTests.swift` never calls `storeVolumePassword`/
  `deleteVolumePassword`/`receiptSigningKey`, for the same reason
  (`volumePasswordAccount` is a fixed production account, not
  injectable). Only the read-only `hasVolumePassword()` and the pure
  `generateVolumePassword(byteCount:)` generator are exercised.

- `CovertTriggerMonitorTests.swift` never calls `setPhrase`/
  `loadFromKeychain` on a real monitor, for the same reason (the
  `covertTriggerPhrase` Keychain account is fixed, not per-instance).
  Only `testObserve(candidate:text:)` (explicitly documented as
  "no state change") and the read-only surfaces of a fresh, never-armed
  `CovertTriggerMonitor()` instance are exercised.

## DoctrineTestSupport.swift design notes (for T2-T5)

- `executionTimeAllowance` (Apple XCTest, XCTestCase.h) was investigated
  and rejected as rule 12's "clean built-in hook": its own header doc
  says it only applies "if test timeouts are enabled" (an
  Xcode-scheme/`xcodebuild -maximum-test-execution-time-allowance`
  opt-in, absent under a plain `swift test`) and rounds the requested
  value UP TO THE NEAREST MINUTE, which cannot express this doctrine's
  30s default or distinguish it from the 120s probe allowance.
  `DoctrineTestCase` instead implements an `XCTestObservation`-based
  watchdog (`testCaseWillStart`/`testCaseDidFinish`) that records an
  `XCTIssue` against the timed-out test by name. Verified compiling
  against this machine's real XCTest.framework via `swiftc -typecheck`
  (the wave's build/test lock forbids `swift build`/`swift test`, but a
  standalone `swiftc -typecheck` against a scratch file does not touch
  the shared package).
- Limitation documented in the file's own top comment: the watchdog
  cannot forcibly unwind a truly deadlocked synchronous test on the main
  thread (no supported Swift/XCTest API for that outside Xcode's own
  spindump-and-restart machinery, which is exactly what was rejected
  above). `withDoctrineTimeout` races the operation against a
  `Task.sleep` via `withThrowingTaskGroup` and DOES return control to
  the caller once the timeout elapses, for async test bodies.
- `withDoctrineTimeout`'s `operation` parameter is declared `@escaping`
  -- a deliberate, necessary deviation from a literal non-escaping
  closure type, documented inline: racing it via `withThrowingTaskGroup`
  requires `addTask`'s `@escaping` closure parameter, so a non-escaping
  `operation` could not be captured. Call-site syntax (including
  trailing-closure form) is unaffected.

## Other notes

- `TesseraApprovalEngine`'s `requestApproval(toolName:.prompt)` parking
  tests use a short polling loop (`waitForPendingRequest`, 5ms interval,
  5s timeout) rather than a single fixed `Task.sleep`, to avoid flakiness
  on a slow CI machine while still being fast on a healthy one.
- Several MainActor-isolated test classes/methods in this cluster use
  either whole-class `@MainActor` (e.g. `TesseraApprovalEngineTests`,
  `ChatGraphBuilderTests`, `UnifiedChatControllerTests`) or per-method
  `@MainActor ... async` (e.g. `ActionAuditLogPanelTests`,
  `InlineStopTests`) to construct/exercise `@MainActor`-isolated
  production types (`TesseraAgentLoop`, `TesseraApprovalEngine`,
  `ActionAuditLogStore`, `UnifiedChatController`,
  `TesseraDualAgentController`). Both patterns were typecheck-verified
  in isolation via the same `swiftc -typecheck` probe technique used for
  `DoctrineTestSupport.swift`; the async-marked variant was chosen
  wherever there was any doubt, since it is unambiguously supported by
  XCTest's async test invocation path regardless of which thread the
  runner itself uses.

## Post-dispatch addendum (centralized build/test pass)

Found while diagnosing the first `swift test` run after this wave's
build fixed clean:

- **testToolResultPayloadDecodesFromLegacyJSONWithNoSourcesField**
  (Tests/TesseraCoreTests/Agent/ChatMessageCitationTests.swift):
  SUSPECTED CODE BUG: `ToolResultPayload.sources` is a non-Optional
  `[Citation]` with no custom `Decodable` init, so Swift's synthesized
  decoder requires the `sources` key and throws `keyNotFound` on
  pre-3A on-disk JSON instead of defaulting to `[]` per the type's own
  documented legacy-compat contract - `confidenceBand` (a genuine
  `ConfidenceBand?`) correctly defaults via the synthesized decoder's
  `decodeIfPresent` handling for Optional properties, `sources` does
  not get that treatment since it isn't Optional. Wrapped in
  `XCTExpectFailure`; not fixed here (source change, out of this
  wave's scope).

- **6 tests in TesseraDataRootTests.swift** (testAppSupportFallsBack
  ToSandboxRootWhenNotMounted, testCachesFallsBackToSandboxCachesRoot,
  testPreferencesFallsBackToSandboxPreferencesRoot,
  testAllDataPathsRootAtTheMountedVolumeWhenMounted [duckdbFile
  assertion only],
  testClearingTheMountedRootFallsBackToTheSandboxAgain,
  testDuckdbFileNameIsTesseraDuckdb): SUSPECTED CODE BUG, single root
  cause - `TesseraDataRoot.insideVolume(subdirectory:fallbackFile:)`
  (TesseraDataRoot.swift) applies `subdirectory` and `fallbackFile`
  asymmetrically between its two branches:
  - Mounted branch: `volumeRoot.appendingPathComponent(subdirectory:
    ...)` - appends `subdirectory`, IGNORES `fallbackFile` entirely.
  - Non-mounted/sandbox-override branch: `sandboxRoot(for:...)`
    returns the raw override URL unchanged; NEVER appends
    `subdirectory`; only conditionally appends `fallbackFile` if
    given. This masks in real production use only because
    `sandboxRoot(for:)`'s own NO-OVERRIDE fallback path reconstructs
    an equivalent suffix internally (`base.appendingPathComponent(
    "TesseraStudio")`) - but `setSandboxRoot(_:for:)`'s own
    documented "test-only seam" bypasses that reconstruction
    entirely, exposing the asymmetry.
  Net effect: `appSupport()`/`caches()`/`preferences()` under a
  sandbox override return the bare override root (missing their
  "Library/.../TesseraStudio" suffix) instead of the subdirectory-
  qualified path the mounted branch correctly produces; `appSupport()`
  additionally still applies its `fallbackFile: "default.store"`
  parameter in that branch, so it returns override+"default.store"
  instead of the bare directory. `duckdbFile()` while MOUNTED returns
  the "duckdb" directory instead of "duckdb/tessera.duckdb", since the
  mounted branch drops `fallbackFile` on the floor. All 6 wrapped in
  `XCTExpectFailure`; not fixed here (source change, out of this
  wave's scope) - a real fix likely wants `insideVolume` to append
  BOTH `subdirectory` (always) AND `fallbackFile` (when present) in
  BOTH branches, uniformly.
