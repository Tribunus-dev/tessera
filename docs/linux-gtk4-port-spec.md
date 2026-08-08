# TesseraStudio: GTK 4 + Adwaita Port Specification
**Status:** Draft v0.1
**Date:** 2026-08-06
**Scope:** A **full, feature-parity Linux desktop port** of the "TesseraStudio"
app (currently a SwiftUI macOS app that is still under active development on
macOS; the Linux port will commence once the macOS app settles), written with
GTK 4 and the Adwaita design language, targeting Fedora Linux on an Intel T2
MacBook.

This is a buildable reference, not a guarantee every surface maps 1:1. Where a
feature relies on a macOS-only API (Keychain, EventKit, Contacts,
"Plead the Fifth"), the spec names a real Linux replacement backend. Every
such item is **REQUIRED** (part of the full port), not optional;

---

## 0. What we are porting

The SwiftUI app layout in the repo (`TesseraStudio/`):

- `Sources/TesseraCore` - platform-neutral logic: agent, models, engine
  bridges, tools, learning, charts, editor, workflows. Reuse as a shared
  model layer behind a thin FFI.
- `Sources/TesseraStudioMac` - the macOS app shell and views.
- `Sources/TesseraStudioiOS` - the iOS shell. **Ported to an Android
  companion** (see section 9); shares the same `TesseraCore`.
- `Sources/CLlama/cllama_shim.c` - dlopen/dlsym bridge to libllama (portable).
- `TesseraStudio/ffi/tessera_ffi.cpp` - real C++ engine FFI (portable C++, no
  Apple-only dependencies).

Design axes:

1. UI stack: GTK 4 + libadwaita (`Adw*` widgets).
2. Language: keep the C/C++ engine; rewrite the SwiftUI shell in C++/GTK.
   Adopt the existing `tessera_ffi` ABI rather than the xcframework.
3. Inference: on-device via `dlopen(libllama)` (portable) plus remote
   OpenAI-compatible endpoints. iGPU acceleration (SYCL/L0 + zero-copy) is an
   engine follow-up, not a first-launch requirement.

---

## 1. Goals and Non-Goals

### 1.1 Goals
- Recreate the primary surfaces: Chat, Agent, Code/Search, Quantization
  (calibration) tooling, Receipts, Workflows, Notes, Tasks, Settings, plus the
  productivity integrations (Calendar, Email, Reminders, Contacts).
- Run the agent loop and on-device + remote LLM providers unchanged.
- Expose the calibrated/audited quantization tools (quantize/calibrate/
  evolve/evaluate) driving the same `tessera-cli` / FFI engine as macOS.
- Keep all LLM/FFI/script work off the GTK main thread so the UI never stalls.
- Native Fedora packaging (Flatpak + rpm).

### 1.2 Scope policy: full parity
This is a **full port**; nothing is deferred. Everything present in the Mac
app ships, including the macOS-only surfaces re-implemented against a Linux
backend. Platform-differing pieces are marked `REQUIRED` with a named Linux
backend everywhere in this spec; there are no "drop for MVP" items.

### 1.3 Non-Goals (platform absent, not deferred)
- The iOS app is NOT dropped: it is ported to an **equivalent Android app**
  (see section 9). Desktop is Fedora Linux + GTK4.
- Metal / CoreML / ANE export paths (`.mlmodelc`) - Linux and Android GGUF.
- Apple-ID account scope (Apple keychain, iCloud, Apple Push) - replaced by
  keyring/libsecret (desktop) and Android Keystore (mobile) equivalents.
- Touch-ID / Face-ID biometrics - replaced by keyring / Biometric-Prompt on
  Android.

---

## 2. Toolchain and language

| Concern      | Choice                                                        | Rationale                                            |
|--------------|---------------------------------------------------------------|------------------------------------------------------|
| GUI stack    | GTK 4 (>= 4.10) + libadwaita (>= 1.4)                          | Adwaita design language, GNOME-native                |
| Language     | C++20 for core/engine and FFI; C for the shim                  | Reuse llama.cpp + tessera C++ engine; no FFI tax    |
| Build        | CMake + a vcpkg/Conan manifest                                 | Matches llama.cpp/tessera conventions               |
| UI model     | View/Model/Controller separation via `Adw*` containers        | Mirrors the Storage/View/Model split in the Swift     |
| Extras       | Rust only via FFI where a Rust lib is required (duckdb)       | Avoid dual toolchains where possible                |

The portable core is UI-independent, so an alternate GTK theme or a later
rewrap to another framework remains possible without touching the engine.

---

## 3. Directory scaffolding

```
tessera-studio-linux/
+-- CMakeLists.txt
+-- cmake/                   # compiler/toolchain config
+-- res/                     # Adwaita-themed resources (CSS, icons, logos)
+-- po/                      # gettext (optional i18n)
+-- src/
|   +-- app/AppMain.cpp      # GApplication / AdwApp entry
|   +-- core/                # port of TesseraCore (portable C++)
|   |   +-- agent/           # agent loop, actions, approvals, safety
|   |   +-- engine/          # LLM provider, FFI, CLI, process runner
|   |   +-- ops/             # quantize / calibrate / evolve / evaluate
|   |   +-- data/            # stores: postgres + valkey + duckdb, caches
|   |   +-- learning/        # learning center, training, traces
|   |   +-- model/           # Chat / Conversation / ModelInfo / Receipt
|   +-- ui/                  # GTK4 + Adwaita
|   |   +-- surfaces/        # one dir per window surface
|   |   |   +-- chat/
|   |   |   +-- editor/
|   |   |   +-- code/
|   |   |   +-- workflow/
|   |   |   +-- receipts/
|   |   |   +-- learning/
|   |   |   +-- notes/
|   |   |   +-- tasks/
|   |   +-- widgets/         # reusable widgets (charts, token budget)
|   +-- ffi/ctessera         # libtessera-ffi dlopen shim
+-- packaging/
|   +-- flatpak/org.tessera.TesseraStudio.yml
|   +-- rpm/tessera-studio.spec
+-- tests/
+-- docs/
```

The `TesseraStudioMac` SwiftUI views map to `src/ui/surfaces/**`, one per
window in the Adwaita model.

---

## 4. Engine / inference bridge (portable layer)

Reuse the approach of `cllama_shim.c`: run llama.cpp as a shared library and
`dlsym` the functions at runtime.

### 4.1 Providers

Port of `TesseraLLMProviderType`:

- `PLACEHOLDER` - built-in, no config.
- `REMOTE_API` - OpenAI-compatible `/chat/completions`, HTTP streaming. Use an
  async HTTP client (libsoup3); expose the same state/comment events.
- `ON_DEVICE` - dlopen `libllama.so`, resolve symbols as in the shim. Model
  path, context length, gpu layers, threads from config.

### 4.2 The `tessera-cli` subprocess fallback

Keep it. Default search paths on Linux:

- `$HOME/.local/opt/tessera/bin/tessera-cli`
- `/usr/local/bin/tessera-cli`, `/usr/bin/tessera-cli`
- the git-source build dir (build/bin/tessera-cli)

Respected override: `$XDG_CONFIG_HOME`/a user setting; `PATH` searched last.
This mirrors the current `TesseraCLIBinaryResolver` precedence.

### 4.3 Engine FFI

Compile `tessera_ffi.cpp` as `libtessera-ffi.so` and dlopen it. The C symbols
are identical to the macOS xcframework; the Swift wrapper becomes a thin C++
`EngineCall`. Keeps the whole quantization toolchain replayable.

---

## 5. GUI: GTK 4 + Adwaita mapping

### 5.1 Window / navigation model

- `Adw.Application` + `AdwApplicationWindow`.
- Top-level side panel via `AdwOverlaySplitView` (Chat+Tools / Code).
- Settings / Learning / Library in `AdwNavigationSplitView` or a leaflet.
- A header bar (`AdwHeaderBar`) for each window surface.
- Workflow canvas uses `GtkDrawingArea` (see 5.4). HTwO

### 5.2 Shared widgets (from TesseraCore)

| Swift source                 | Adwaita/GTK target                  |
| ---------------------------- | ----------------------------------- |
| ChatBubbleView / ChatPanelInputView | Message list; `AdwTextView` input |
| MarkdownRenderer             | GtkTextBuffer + tag-based MD renderer, or a small Markdown -> GtkTags pass |
| CodeBlockHighlighter         | GtkSourceView (gtksourceview5)    |
| MetricsChartView             | Cairo drawing on a GtkDrawingArea   |
| TokenBudgetView              | GtkLevelBar / progress               |
| ApprovalSheet / ToolCallView | AdwDialogs / AlertDialog            |
| ReceiptView / C2PAManifest   | document page + JSON preview         |

Use `AdwGroup` / `AdwExpanderRow` for the stacked multi-panel layouts SwiftUI
built with nested groups.

### 5.3 Chat and agent

Port the pure state machines verbatim; the UI only reflects events:
- `AgentLoop`, `ApprovalEngine`, `DenialCircuitBreaker`, `SafetyDecision` ->
  `core/agent/*`. No change.
- `ChatPanelViewModel` / `ChatPanelStateMachine` -> `ui/chat/Session.*` and a
  same-named state machine.
- `ChatQueueItem`, `CrossDocumentChatRegistry`, `MatchAndSupersedeEngine` ->
  `ui/chat/Queue.*` etc. These are mostly data-layer; portable.

### 5.4 Code surface

- `CodeFileTree`, `CodeSearchPanel`, `CodeOutline` -> `src/views/code/*`
- Center on `GtkSourceView` in a `GtkPaned` (tree | editor | outline).
- `GitReadOnly` -> invoke `git` subprocess via the shared `ProcessRunner`.

### 5.5 Quantization / calibration tooling

All tool calls (`CalibrateTool`, `QuantizeTool`, `EvolveTool`, `Evaluate`,
`Convert`, `LoadModel`, `ListModels`, `InspectSidecar`, and the `PythonTools/*`)
just drive `tessera-cli` / FFI / python. On Linux they run the same binaries;
the UI is a progress + terminal `Adw` console. The python tooling under
`tools/tile640` and `tools/tessera` runs via a bundled venv the Flatpak ships;
only path/config wiring is needed, no rewrite.

---

## 6. Storage and data layer

The data stack is **PostgreSQL + Valkey + DuckDB** (not SQLite). Roles:

- **PostgreSQL** - the system of record. Structured state: conversations,
  agents, actions, receipts, workflows, store contents, account/config.
  Moved in with the app or a connected service.
- **Valkey** - in-memory cache / hot state: KV cache tokens budgets, recent
  traces, queue working sets, LRU on model metadata, fast pub/sub for the
  agent loop's progress.
- **DuckDB** - analytical/columnar: telemetry, spec-traces (`spec.v1`
  JSONL -> analytical queries), C2PA/audit mining, calibration workloads
  (imatrix aggregation), and the local graph store (existing vendored duckdb).

Data partition discipline:
- Writes go through PostgreSQL (source of truth); Valkey is a cache that can be
  rebuilt; DuckDB holds offline/analytical, never the canonical writable store.
- Analytic read paths (charts, traces, model metrics) fetch from DuckDB via
  UDFs or FTSDP over Postgres when the volume is small enough.

XDG Base Directory layout:
- `$XDG_CONFIG_HOME/tessera/` settings (`GSettings` with
  `org.tessera.TesseraStudio` schema, or JSON/Toml for non-GNOME)
- `$XDG_CACHE_HOME/tessera/`
- `$XDG_DATA_HOME/tessera/models/`, `.receipts/`, `.traces/`, `.db/` (an
  embedded local Postgres data dir OR a connection string to an external
  instance)

Connections:
- Postgres: `postgresql://` URL; the app embeds one option via
  `embedded-postgres`/`postgres` bundled in the Flatpak, or connects to a
  user-supplied service.
- Valkey: `valkey://` local socket or TCP.
- DuckDB: on-disk `*.duckdb` in the data dir, opened in-process (vendor as-is).

macOS `UserDefaults` -> GSettings / JSON under the same keys; existing
`TesseraDataLayer` abstraction becomes a thin layer over the local
Postgres+DuckDB pair so the Storage/ model stays the same.

---

## 7. macOS-only frameworks -> Linux replacements

### 7.1 Secrets / Keychain

- `Security`/`SecItem` (TesseraSecretStore, KeychainStorage,
  TesseraKeychainVolume, PleadTheFifthKeychain) -> **libsecret** backed by
  GNOME Keyring (`org.freedesktop.secrets`); KWallet DBus as a fallback.
  **REQUIRED** for parity.

### 7.2 "Plead the Fifth" / disk encryption

| Swift | Linux |
| ----- | ----- |
| TesseraEncryptedVolume | LUKS via cryptsetup / udisks2 integration; or img+losetup+cryptsetup |
| SecureOverwrite        | data-overwrite like `shred`, mindful of SSD TRIM |
| HotKey / input intercept | X11 `XRecord`; Wayland `org.freedesktop.portal.GlobalShortcuts` |
| wipe/trigger           | app-level event -> spawn `cryptsetup luksClose` / systemd |

Note the Wayland limits on global shortcuts; keep the control/trigger logic
intact and only the transport changes.

### 7.3 Productivity data sources (full scope)

All in scope per the "full parity" goal. Each supported store maps to a
concrete Linux backend; the same UI surfaces are ported to GTK4 unchanged in
intent.

| macOS | Linux backend | Status |
|-------|---------------|--------|
| Contacts / `ContactStore` / `AppleContactsAdapter` / `GoogleContactsAdapter` / `VCardImporter` | **libEBook** (libedataserver, CardDAV) + `libcarddav`, plus a pure VCF importer for vCard files | REQUIRED |
| Calendar / `CalendarStore` / `CalendarViewModel` / recurrences | **libedataserver + CalDAV**, `libical` for recurrence, cached in DuckDB/Valkey | REQUIRED |
| Reminders / `ReminderStore` + notification | CalDAV (VTODO) via libical + `libnotify` / `GNotification` scheduling | REQUIRED |
| Mail / `EmailComposer` / `EmailImporter` / `EmailSender` | **libetpan** (SMTP+IMAP) for compose/send/receive; import via RFC-822 MIME | REQUIRED |
| Notes / local tasks | Valkey-cached + PostgreSQL-backed local store; graph edges via core/graph | REQUIRED |
| Notifications | `libnotify` / `GNotification` | REQUIRED |

Account data stays in the system secret store (7.1), not plaintext config.
Sync happens through the same provider (CardDAV / CalDAV / IMAP) the macOS
app uses, mapped to their Linux libraries. Work on worker threads so no sync
round-trip touches the GTK main thread.

---

## 8. On-device / iGPU inference

From `docs/workspace-intel-t2-linux.md`:

- The iGPU (Iris Plus G7) cannot run the Metal kernels. For on-device
  decoding, first ship CPU (AVX-512) GGUF via libllama.
- Optional, engine-only and flag-gated: SYCL `malloc_shared` for zero-copy
  weights/KV, and an L0/SYCL out-of-order queue + `submit_barrier` for
  CPU/GPU overlap.
- The UI has a "backend" selector (CPU / CPU-SYCL L0) reading the same keys
  (`onDeviceGPULayers`, `onDeviceThreadCount`).

### 8.1 OpenVINO GPU: zero-copy + async overlap (engine-level, flag-gated)

The fork's OpenVINO backend is the Linux analog of the Apple / ANE path. The
build already links `GGML_OPENVINO=ON` and registers `OPENVINO0`. Hall of the
"Apple" architecture already exists in `ggml/src/ggml-openvino`; three gaps
remain to reach the zero-copy + hybrid-overlap design:

Already present:
- Remote/USM zero-copy buffer: `ggml-openvino.cpp` `buffer_context.is_remote`
  backing `ov::intel_gpu::ocl::USMTensor`; `ggml_openvino_get_remote_context()`.
  Used today for `cache_*` KV tensors on GPU (init_tensor, line ~158).
- Prefill/decode graph split: `utils.cpp` compiles two models
  (`compiled_model_prefill` / `compiled_model_decode`, ~lines 539-558) with
  `is_prefill` routing, plus an infer-request cache reused across decode.

Gaps to close:
1. Zero-copy only for KV, not weights/inputs/layers. Weight/input tensors still
   `ggml_aligned_malloc` + `memcpy` (openvino.cpp:100,279-296). Pick the
   weight/io binding into a host-visible USMTensor (echo the cache_ path) so
   set/get_tensor stops copying and both sides touch one pointer.
2. Fully synchronous infer: `infer_request->infer()` (utils.cpp:371,585,
   615). Convert the split decode to `create_infer_request` -> `start_async`
   + event/wait, mirroring Metal events; sink prospects only at the decode
   dependency edge.
3. Register the backend `.async = true` (openvino.cpp:762) and populate the
   NULL async funcs (642-650) so ggml-cpu and ggml-openvino overlap under
   ggml-scheduler.

Measure of success: zero `memcpy` on weight/io; prefill underway while decode
runs -> lower per-request wall-clock. Not a 2x decode (shared ~60 GB/s DRAM).

Engine-only, gated behind `onDeviceGPULayers`/`GGML_OPENVINO_DEVICE=GPU` +
an env flag; CPU AVX-512 remains the default.

---

## 9. Accessibility and theme

GTK4 + Adwaita has AT-SPI accessibility built in and native light/dark support:
- Use `AdwThemeManager`, respect `prefers-color-scheme`.
- Font/geometry from `AdwStyleManager`.
- Keyboard-focus pass mirrors the SwiftUI app; schedule in a later milestone.

---

## 10. Packaging

- AppID: `org.tessera.TesseraStudio`.
- Flatpak on `org.gnome.Platform` with GTK4, adwaita, gtksourceview,
  libsecret; `--socket=wayland,x11`, `--talk-name=org.freedesktop.secrets`,
  bundled python venv for the quantizer, vendored duckdb.
- rpm spec for native Fedora installs.

---

## 10.5 Android companion app (iOS port)

The iOS shell (`Sources/TesseraStudioiOS`, ~11 thin view files) shares
`TesseraCore` and is ported to an equivalent **Android app** so the mobile
surface is not dropped.

### 10.5.1 Approach
- **Language:** Kotlin + Jetpack Compose (Material 3), matching the thin iOS
  SwiftUI shell. Business logic stays in a shared core.
- **Shared core:** compile `TesseraCore` logic to a native C++/FFI layer usable
  by both desktop and Android (and later re-linked to Swift). Model config,
  agent actions, receipts, quantization orchestration live here; each platform
  shell only renders.
- **Inference:** the same `libllama` dlopen shim loads from the app's .so dir
  on Android (no dlopen-CPUs), or falls back to the remote API provider.

### 10.5.2 Surface mapping (iOS -> Android)
| iOS surface | Android (Compose) |
| ----------- | ----------------- |
| `ContentView` / `TesseraStudioiOSApp` | `MainActivity` + NavHost |
| `ChatPanelView_iOS` | Compose `ChatScreen` + `LazyColumn` message list + input row |
| `NotesView_iOS` | Compose `NotesScreen` (list + editor) |
| `RemindersView_iOS` / `ReminderDetailView_iOS` | Compose `RemindersScreen` + detail |
| `TasksView_iOS` | Compose `TasksScreen` |
| `EmailView_iOS` / `EmailSurfaceBootstrap_iOS` | Compose `EmailScreen` + account bootstrap |
| `ReceiptsDrawerSheet_iOS` | Compose `ModalBottomSheet` |

### 10.5.3 Mobile-specific replacements
| iOS | Android |
|-----|---------|
| SwiftUI navigation | Compose Navigation Compose |
| EventKit/Contacts/Reminders | the EDS/CalDAV adapters above, or the built-in `CalendarProvider`/`ContactsContract` for on-device, else CalDAV |
| `UserNotifications` / `NotificationCenter` | `NotificationManager` + `postNotifications` |
| Keychain `SecItem` | Android Keystore + EncryptedSharedPreferences |

- Android exposes the calibration tools and receipts the same way as desktop:
  quantize/calibrate/evolve via `tessera-cli` bundled or via a networked
  Postgres+Valkey backend.
- Android target does **not** run the Python quantizer on-device; it drives an
  in-app trigger that runs it against a reachable Postgres/Valkey/DuckDB (in
  app, local, or remote). The heavy calibration runs server-side.

---

## 11. Milestones

**C0 - Skeleton (2-4 wks)**
- CMake + App opens in Adwaita, navigation shell works.
- Core engine bridge: dlopen libllama, remote provider, CLI resolver.
- GSettings scaffold, i18n stub.
- Chat MVP: build a conversation, send a prompt through a provider.

**M1 - Inference + chat (C0 + 1-2 wks)**
- Port `AgentLoop`, `ApprovalEngine`, `DenialCircuitBreaker`, `Safety`.
- Agent actions, receipts; token budget.
- Calibration progress tab invoking `tessera-cli`.

**M2 - Code / editor (M1 + 2 wks)**
- `GtkSourceView` editor, file tree, search, git (read-only).
- Agent cursor overlay and diffs.

**M3 - Calibration workspace (M2 + 2 wks)**
- Quantize / calibrate / evolve as in-app workflows.

**M4 - Workflow canvas + learning (M3 + 3-4 wks)**
- Node canvas editor (`GtkDrawingArea`).
- Learning dashboard wired to the training binary.

**M5 - Productivity store (M4 + 3-4 wks)**
- `libedataserver`/CardDAV contacts, CalDAV calendar + VTODO reminders, and
  `libetpan` mail, all behind the portable core stores.
- Account auth via the libsecret wrapper; sync on worker threads.
- Notes + local tasks finishing the product surface.

**M6 - Encryption / Plead the Fifth (M5 + mapping)**
- LUKS volume management (7.2), secure overwrite, global-hotkey triggers,
  platform gates (X11/portal).

**M7 - Full parity polish (M6)**
- Accessibility pass (AT-SPI), theming, keyboard nav, telemetry drawers,
  runs view, final i18n; the server App private surface.

**M8 - Android companion (M7, parallel)**
- Kotlin + Compose shell; shared C++ core; on-device libllama + remote API.
- Mobile CRUD for notes, tasks, reminders, calendar, receipts; Keystore.
- Calibration drove from a reachable Postgres+Valkey+DuckDB backend.

Each milestone is independently shippable; the port keeps the macOS build in
lockstep until it settles (the Git repo vision).

---

## 12. Risks and decisions

- Stay Adwaita-first (native Fedora look); document theming with the unlock.
- Performance: the i5-1038NG7 has low decode throughput (weight-bound
  bandwidth). The UI must not stall; run all LLM/FFI/script work on worker
  threads and marshal busy callbacks to the GTK thread.
- Python/CLI closures: the Flatpak bundles a venv; keep all quantization
  operations callable via `tessera-cli` so the GUI can also be exercised by
  tests.
- duckdb: already vendored in this fork; vendor it in the Linux build.
- Data layer: Postgres + Valkey + DuckDB is heavier than a single embedded
  store. Mitigate with: local embedded Postgres for "zero-config" dev, Valkey
  is drop-in cacheable, and DuckDB stays in-process. The Flatpak ships all
  three; Android connects to a reachable backend.

---

## 13. Open questions

1. `TesseraCore` and `TesseraStudioMac` are SwiftUI/App-Kit-coupled; identify
   every `#if os(macOS)` path and re-spec the UI interactions.
2. Which GTK/cc layout to use for the "workflow canvas" - approved as a
   `GtkDrawingArea` custom render (see 5.4). Confirm performance needs.
3. `tessera-cli` / python dependency startup time vs in-process FFI; decide the
   default execution mode.
4. Keychain/reminders leak the Apple-ID context: the libsecret wrapper is the
   first-week driver.

Also, question 2 in section 13: the workflow-canvas answer is confirmed
`GtkDrawingArea` (see 5.4); the entry locking in the M4 milestone only needs a
performance pass.

---

## 14. Backlog (marked TODO)

Items called out during review for later design work. Not scheduled in M0-M7;
each becomes a task card when its parent area begins.

### 14.1 Storage / data plane
- [ ] **TODO** Concrete Postgres schema (source-of-truth tables, migrations),
      section 6.
- [ ] **TODO** Valkey key layout / eviction + pub/sub contracts, section 6.
- [ ] **TODO** DuckDB analytical schema (telemetry, traces, charts) + how
      instrumentation feeds it, section 6.
- [ ] **TODO** Embedded-Postgres packaging decision - bundled local postgres
      vs external service for dev/Flatpak, section 6/10.

### 14.2 Android companion
- [ ] **TODO** Android scoring/Keystore metadata + schema, section 10.5.
- [ ] **TODO** Decide Android inference mode: bundled libllama .so vs remote
      API; NPU-offload feasibility, section 10.5/8.

### 14.3 GUI
- [ ] **TODO** Workflow-canvas renderer spec - `GtkDrawingArea` node math,
      hit-testing, ports, section 5.4.
- [ ] **TODO** GTK file-production checklist for C0 (widgets, dialogs,
      shortcuts).

### 14.4 Engine / NPU
- [ ] **TODO** CPU/GPU overlap design: SYCL out-of-order queue +
      submit_barrier hybrid, section 8.
- [ ] **TODO** Intel NPU collaboration study - see section 15.

---

## 15. NPU collaboration: can we reuse the ANE work on Intel NPUs?

**Short answer: No for the kernel code, yes for the architecture.** The ANE
path is CoreML/Metal/IOSurface code that cannot run on Intel x86. But the
*scheduling + sharing* design transfers, and this repo already has an Intel
accelerator venture: an **OpenVINO backend** (`ggml/src/ggml-openvino`) that
supports Intel **CPU / GPU / NPU**.

### What does NOT transfer
- The ANE kernels are CoreML-compiled, ANE-instruction-set, IOSurface-bound.
  Not reusable on an Intel NPU (different ISA, no Metal/Metal events).
- The `ane-pump` lock-free state machine and Metal-shader dispatch are
  Mac/Apple-transport specific.

### What DOES transfer (the valuable reuse)
- **Zero-copy + accelerator-overlap design** (see the ANE deep study, section
  4.3): the IOSurface + Metal-event pattern of handing pinned buffers between
  accelerator and host maps to Intel L0 shared-USM + events on Linux.
- **Hybrid scheduler split** (CPU prefill + accelerator decode) is
  device-neutral and applies to an Intel NPU exactly as it does to the ANE.
- Quantization / per-tensor decision logic from the T640 work applies on any
  accelerator.

### How to do it on Intel (grounded in this repo)
- The OpenVINO backend is real code: `GGML_OPENVINO=ON` builds
  `ggml/src/ggml-openvino`; it walks the GGML cgraph -> `ov::Model`, binds
  GGML tensors, runs with `GGML_OPENVINO_DEVICE=CPU|GPU|NPU`. Q4_0/Q4_K etc.
  supported. This is the on-Intel equivalent of the CoreML-export path.
- To run CPU+NPU *together* (not just substitute), wire the OpenVINO path to
  the T640 CPU path and give the NPU the GEMM-bound ops while the CPU does
  prefill + AVX-512 unpack, sharing memory via L0 USM (mirroring the section-8
  design). Stateful execution is experimental; NPU is stateless-only.

### Honest caveats for THIS machine
- The i5-1038NG7 has **no NPU**: no `/dev/accel`, no Intel NPU PCI device
  (only `00:04.0` Power/Thermal controller). So NPU collaboration is **N/A
  on this exact laptop**; it becomes relevant only on an AI-PC (Intel Core
  Ultra) that exposes `/dev/accel`.
- On an NPU, OpenVINO forces a static graph and a small prefill chunk (default
  256); keep the context small.

**Conclusion:** recycle the *hybrid schedule* + *zero-copy* architecture, not
the ANE code. On this laptop the practical accelerator remains the CPU
(AVX-512) plus iGPU via L0/SYCL; the NPU path is future-hardware only. See
backlog item 14.4.

---

## Appendix A - macOS-only Swift files to swap or drop

| Swift file | disposition |
| ---------- | ----------- |
| Encryption/Keychain*.swift            | rewrite with libsecret |
| Encryption/PleadTheFifth*, TextInputInterceptor | port, portal hotkeys |
| Encryption/TesseraEncryptedVolume      | cryptsetup/LUKS wrapper |
| Productivity/Contacts/*               | port to libedataserver + VER/VCard |
| ImportExport/ShareSheetCoordinator    | drop (no share sheet) |
| TesseraStudioMac/Views/Reminders, Calendar, Email | port to libcald/libetpan EDS backends |
| TesseraStudioMac/App/TesseraAppLifecycle | rewrite for AdwApp |
| TesseraCore/Views/*                    | rewrite in GTK4 |
| TesseraStudioiOS/**                    | ported to Android (section 10.5) |

---

## Appendix B: overall concept parallels

| Concern        | macOS               | GNOME/Fedora          |
| -------------- | ------------------- | --------------------- |
| Preferences    | UserDefaults        | GSettings             |
| Secrets        | SecItem / Keychain  | libsecret            |
| Notifications  | UserNotifications   | GNotification         |
| Canvas         | SwiftUI Canvas      | Cairo / GtkDrawingArea |
| App lifecycle  | @main SwiftUI        | GApplication / AdwApp |
| Settings UI    | SwiftUI Settings     | AdwPreferencesWindow  |
| Theming        | SwiftUI / NSAppearance | AdwThemeManager    |