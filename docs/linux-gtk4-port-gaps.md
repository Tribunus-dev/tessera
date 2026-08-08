# Tessera Studio Linux - gap analysis and work plan

Audit date: 2026-08-08. Compares `tessera-studio-linux/` (~7,800 LOC C++/GTK4)
against the SwiftUI app (`TesseraStudio/`, ~79,000 LOC) and the port spec
(`docs/linux-gtk4-port-spec.md`).

The README claims "full parity, not MVP." The GTK shell is genuinely
substantial, but the two pillars of an LLM studio (on-device inference and cloud
streaming) are non-functional in the default build, and several "all REQUIRED"
backends degrade to demo data. This doc lists the work to close the gap.

Work items are grouped P0 (broken-in-default-build) -> P3 (polish). Each item
names the file(s), the change, the size estimate, and how to verify.

## P0 - the LLM path is a placeholder echo

These three are why every chat turn returns `[placeholder] echo: <prompt>` today.

### P0.1 Cloud streaming: define `HAVE_LIBSOUP` in CMake

**Root cause:** `CMakeLists.txt:17` runs `pkg_check_modules(LIBSOUP libsoup-3.0)`
and links `LIBSOUP_LIBRARIES` into the binary (line 119), but the
`target_compile_definitions` blocks (lines 56-75) only define `HAVE_EDS`,
`HAVE_LIBETPAN`, `HAVE_LIBSECRET`, `HAVE_ATSPI` - never `HAVE_LIBSOUP` for
`tessera-core-linux`. `src/core/provider.cpp` gates `RemoteStreamingProvider`
behind `#ifdef HAVE_LIBSOUP` (line 46), so the whole class is `#else`'d to
`PlaceholderProvider` and the real ~120-line SSE code for 11 providers never
compiles.

**Work:**

```cmake
if(LIBSOUP_FOUND)
    target_include_directories(tessera-core-linux PRIVATE ${LIBSOUP_INCLUDE_DIRS})
    target_link_libraries(tessera-core-linux PRIVATE ${LIBSOUP_LIBRARIES})
    target_compile_definitions(tessera-core-linux PRIVATE HAVE_LIBSOUP=1)
endif()
```

Mirror for the UI executable's compile definitions block (lines 134-140).

**Size:** S (one block, mirrors the existing EDS/LIBETPAN pattern).

**Verify:** `cmake -B build-linux -S tessera-studio-linux && cmake --build
build-linux`, then confirm `RemoteStreamingProvider::send` is in the binary
(`nm build-linux/tessera-studio-linux | grep RemoteStreamingProvider`). Set
`OPENAI_API_KEY`, open Chat, send a prompt, observe real streamed tokens.

### P0.2 On-device inference: implement `make_provider_on_device` + `dlsym`

**Root cause:** `src/core/provider.cpp:207-210` ignores all args and returns
`new PlaceholderProvider()`. `src/ffi/ctessera/shim.cpp` (23 LOC) calls `dlopen`
on `libllama.so`/`libtessera-ffi.so` but never `dlsym`s a symbol - the handles
are stored and `dlclose`d.

**Work:**
1. Resolve symbols from `libllama.so` via `dlsym`: at minimum `llama_model_load`,
   `llama_new_context_with_model`, `llama_decode`, `llama_get_logits,
   `llama_token_to_piece`, `llama_tokenize`, `llama_kv_cache_clear,
   `llama_sampler_chain_*` (or the legacy `llama_sample_*` set).
2. Add a `LlamaProvider : LLMProvider` in `provider.cpp` that owns a model +
   context, tokenizes the prompt, decodes incrementally on the worker thread,
   emits `on_chunk` per token, and clears the KV cache on completion.
3. Replace `make_provider_on_device` to `dlopen` via `shim.cpp`, resolve symbols,
   load the model at `model_path`, set `gpu_layers`/`threads`, and return the new
   provider. Fall back to `PlaceholderProvider` only on dlopen/load failure.

**Size:** M. Mirror the SwiftUI `cllama_shim.c` (633 LOC) + `LlamaLLMProvider`
(14.7k LOC) - both are the spec.

**Verify:** point `on-device-model-path` at a real GGUF, open Chat, send a
prompt, observe real generation at configured `gpu-layers`.

### P0.3 Cloud-only Sky path + provider "Test" button

With P0.1 fixed the Sky agent in AppMain's group chat and the Test button in
`src/ui/surfaces/providers/Surface.cpp` will start working automatically. No
extra work beyond verifying: the worker thread that calls `prov->send("ping",
...)` should now see `ok=true` when a key is present.

**Size:** S (verification only after P0.1).

## P1 - "all REQUIRED" productivity backends degrade to demo data

Spec section 7.3 marks Contacts/Calendar/Reminders/Mail as REQUIRED with no demo
fallback. Today only source *names* are enumerated.

### P1.1 EDS content reads in `Productivity.cpp`

**Root cause:** `src/core/productivity/Productivity.cpp` only calls
`e_source_registry_new_sync` + `e_source_registry_list_sources` to list
address-book / calendar / task-list *display names*. It never calls
`e_book_client_get_contacts_sync` or `e_cal_client_get_object_list_sync`, so no
contact/event/reminder data is read. It falls through to demo fixtures ("Ada
Lovelace", "Sprint review").

**Work:**
- Contacts: open each `E_BOOK_CLIENT` via `e_book_client_connect_sync`, run
  `e_book_client_get_contacts_sync` with a wildcard query, map `EContact` to the
  internal `Contact` (full name, email list, phone, org, note).
- Calendar: `e_cal_client_connect_sync`, `e_cal_client_get_object_list_sync` for
  `VEVENT` components over a date window, map `icalcomponent` -> event (summary,
  start/end, RRULE, attendees).
- Reminders: same as calendar but `VTODO` components (summary, due, priority,
  status).

**Size:** M. The EDS APIs are verbose but well-documented; this is mechanical
mapping work.

**Verify:** on a Fedora machine with GNOME Online Accounts configured for Google
Contacts + Calendar, the respective surfaces show real entries, not "Ada
Lovelace" / "Sprint review".

### P1.2 EDS write-back for "+ Event/Contact/Reminder"

**Root cause:** `CalendarSurface.cpp`, `ContactsSurface.cpp`,
`RemindersSurface.cpp` "+New" dialogs append a UI row only - no
`e_cal_client_create_object_sync` / `e_book_client_add_contact_sync` /
`e_cal_client_create_object_sync` (for VTODO).

**Work:** in each surface's create handler, build the `EContact` / `icalcomponent
(VEVENT|VTODO)` and call the corresponding EDS create. Refresh the list from EDS
on success rather than mutating the UI directly.

**Size:** S-M.

**Verify:** create an event in the Calendar surface, confirm it appears in GNOME
Calendar; create a contact, confirm it appears in GNOME Contacts.

### P1.3 Mail: actually call libetpan

**Root cause:** `Productivity.cpp::emails()` checks
`getenv("TESSERA_IMAP_URL")` and pushes a fake email regardless. libetpan is
linked but no libetpan function is ever called anywhere in the tree.

**Work:** behind `HAVE_LIBETPAN`, use `mailimap` to connect to the IMAP URL,
`mailimap_login`, `mailimap_select`, `mailimap_search`/`mailimap_fetch`, map
`mailmessage` -> `EmailMessage`. For SMTP send, `smtp_socket` /
`mailsmtp_socket`. Resolve credentials from libsecret ("tessera",
"imap-credentials" / "smtp-credentials").

**Size:** M. libetpan's API is C and fiddly; budget for IMAP IDLE later.

**Verify:** set IMAP creds in libsecret, point `TESSERA_IMAP_URL`, open Email,
see real inbox. Reply sends via SMTP and lands in the recipient's inbox.

## P2 - data plane is Postgres-via-popen only

Spec section 6 mandates Postgres + Valkey + DuckDB. Only Postgres is wired, and
only via `podman exec tessera-postgres psql -c ...`.

### P2.1 Use libpq, not popen

**Root cause:** `src/core/data/DataLayer.cpp` shells out to `podman exec
tessera-postgres psql -t -A -F '|' -c "..."`. `LIBPQ_LIBRARIES` is not even in
CMakeLists. `sql_escape` is a hand-rolled escaper.

**Work:** add `pkg_check_modules(LIBPQ libpq)` (or `find_package(PostgreSQL)`),
link into `tessera-core-linux`, replace every popen call with `PQconnectdb` +
`PQexecParams` (parameterized queries eliminate `sql_escape` entirely), keep
the same row/field mapping.

**Size:** M. Mechanical but touches every method in DataLayer.

**Verify:** start a Postgres container, insert/query an entity, confirm via
`psql` that the rows are there; kill `podman` mid-run, confirm graceful
degradation to `DataStoreDegraded`.

### P2.2 Valkey: real cache, not a TCP probe

**Root cause:** DataLayer's `Ready/CacheDegraded` state is computed by TCP-probing
the Valkey port. No `hiredis` symbol is ever called. Spec section 6 + 14.1 say
Valkey holds hot state (active sessions, recent chat cache, run locks).

**Work:** add `pkg_check_modules(HIREDIS hiredis)`, wire a `ValkeyCache` that
owns a `redisConnect`, implement `get`/`set`/`setex`/`del`/`incr` for the spec's
hot-state keys. Wire read-through/write-through in `DataLayer` so cache misses
fall through to Postgres and writes fan out to both.

**Size:** M. Land the key-layout contract from spec 14.1 first.

**Verify:** run two concurrent chats, confirm the active-session key is set in
Valkey; stop Valkey, confirm the app degrades to `CacheDegraded` and keeps
working against Postgres.

### P2.3 DuckDB: real analytics

**Root cause:** `duckdb_*` is never called; a path is created but no symbol is
resolved. Spec 6 + 14.1 say DuckDB holds analytical aggregates (token usage over
time, per-model run stats).

**Work:** vendor DuckDB (spec 12 notes it is "already vendored" - verify), wire
`duckdb_open`/`duckdb_query`, define the analytical schema (spec 14.1 TODO),
expose an `analytics_*` method set on DataLayer.

**Size:** M-L. Schema design + ETL from Postgres is the bulk.

## P3 - surfaces and polish

### P3.1 Wire Docs / Sheets / Slides / Models surfaces into nav

**Root cause:** `AppMain.cpp:208` defines 15 destinations; `DocsSurface`,
`SheetsSurface`, `SlidesSurface`, `ModelsSurface`, `EditorSurface`,
`ReceiptsSurface` are never instantiated (their `_surface_new` calls have no call
site). `EditorSurface.cpp` / `ReceiptsSurface.cpp` are not even in CMakeLists.

**Work:** add the missing destinations to `dests[]`, call the existing
`*_surface_new` constructors, add the two uncompiled files to CMake.

**Size:** S.

### P3.2 Agent loop: real tool dispatch

**Root cause:** `src/core/agent/Agent.cpp` (36 LOC) is single-turn, `approve()/
deny()` are empty `{}`, `run_one_turn` calls `provider->send(...)` with no-op
callbacks, no tool dispatch. SwiftUI's `TesseraAgentLoop` (15k LOC) is the spec.

**Work:** port the streaming loop: LLM call -> parse tool calls -> execute via
`ToolRegistry` with `ApprovalEngine` gating -> yield events. Port the
action-class classifier + denial circuit-breaker.

**Size:** L. This is the spine; budget accordingly.

### P3.3 Plead the Fifth: real LUKS + wipe

**Root cause:** `src/core/encryption/Volume.cpp` probes `$PATH` for cryptsetup
and writes a placeholder text file. `PleadTheFifth::arm()`/`trigger()` are empty
no-ops. AppMain's "Lock/Wipe" dialog accept handler is an empty body with a
comment. SwiftUI's wipe is a real 9-step actor (crypto-shred + N-pass overwrite
+ audit trail).

**Work:** real `cryptsetup luksFormat`/`luksOpen`/`luksClose` via polkit
(`udisks2` is the friendly path); secure-overwrite (shred pattern); wire
AppMain's accept handler to `Volume::wipe()`. Add the wipe-report audit trail.

**Size:** M-L. polkit authorization is the fiddly part.

### P3.4 Global hotkey + covert phrase (X11/Wayland)

**Work:** X11 `XRecord` or Wayland `GlobalShortcuts` portal for the hotkey chord;
covert-phrase monitor via AT-SPI text events (Linux has no AppKit swizzle
equivalent - text-entry interception needs portal or accessibility subscribe).

**Size:** M. Wayland portal is the modern path; X11 fallback for Xorg sessions.

### P3.5 BrowserTool + DesktopTool real implementations

**Root cause:** `BrowserTool.cpp` (9 LOC) pushes a fake DOM and returns canned
base64 for screenshots. `DesktopTool` click/type are no-ops returning demo data.

**Work:** BrowserTool via WebKitGTK (`WebKitWebView` headless) or Spawn
Playwright; DesktopTool click/type via AT-SPI `atspi_accessible_do_action`.

**Size:** M (WebKit) / S (AT-SPI click/type).

### P3.6 Notes/Tasks editor body persistence

**Root cause:** Notes `+New Note` and Tasks NLU create real entities in
Postgres, but the editor body never writes back (Notes), and the Tasks detail
editor doesn't persist (Tasks). Tags are hardcoded.

**Work:** wire the editor `onChanged` to `dl->upsert_note(...)`; same for Tasks
detail fields; tags from a real `list_tags` query.

**Size:** S.

### P3.7 Flatpak manifest completeness

**Root cause:** `packaging/flatpak/org.tessera.TesseraStudio.yml` is missing
`--share=network` (cloud calls fail even with P0.1 fixed), missing
`--talk-name=org.freedesktop.portal.Background`/`RemoteDesktop`/`GlobalShortcuts,
and missing postgres/valkey/duckdb modules (the podman-exec data path has
nothing to talk to inside the sandbox).

**Work:** add `--share=network`; add portal talk-names; add Postgres/Valkey/DuckDB
as Flatpak modules (or document the embedded-Postgres decision from spec 14.1).

**Size:** S-M.

### P3.8 `save_config` persistence + systemd `--background`

**Root cause:** `src/core/config.cpp::save_config` is a load-only stub ("Persist
via GSettings when GTK available; stub for core-only build"). The systemd unit
`packaging/.../tessera-agent.service` expects a `--background` flag that AppMain
does not parse.

**Work:** make `save_config` write through to GSettings; add `--background` to
AppMain's arg parse that runs the agent loop headless.

**Size:** S.

### P3.9 Android companion

**Root cause:** `android/app/src/main/java/org/tessera/MainActivity.kt` is a
single line (`class MainActivity // stub`). No Gradle build, no manifest, no
Compose, no JNI.

**Work:** per spec section 10.5 - Compose + Material 3 UI, shared C++ core via
JNI, on-device libllama or remote API. This is its own multi-week effort.

**Size:** XL. Treat as a separate workstream.

### P3.10 Tests

**Root cause:** `tests/test_provider.cpp` asserts `done || true` (tautology);
`test_cli_resolver.cpp` checks `!v.empty()`. No tests for DataLayer, StateGraph,
TraceStore, MoE, KnowledgeSync.

**Work:** real provider test (mock libsoup), DataLayer test (Postgres fixture),
StateGraph test (validation, cycle detection, checkpointer), TraceStore test
(purge/trim).

**Size:** M.

## Sequencing recommendation

1. **P0.1** first (one-line CMake fix; unblocks cloud LLM for everything else).
2. **P0.2** next (unblocks on-device inference; biggest single capability add).
3. **P1.1 + P1.2** (EDS read + write; turns the productivity surfaces from demo
   into real - the highest visible-value work after the LLM path).
4. **P2.1** (libpq) before P2.2/P2.3 (the popen-`psql` path is the data-plane
   foundation).
5. **P3.1** (wire Docs/Sheets/Slides into nav) - cheap win, immediately visible.
6. Everything else is parallelizable after that.

## Items that need a design decision before coding

- **Embedded Postgres vs. container Postgres** (spec 14.1 open). Affects P2.x,
  P3.7, and the P3.3 wipe ordering.
- **Wayland vs. X11 hotkey path** (spec 13 open). Affects P3.4.
- **CLI vs. in-process FFI default** (spec 13 open). Affects P0.2.
- **Android inference mode** (bundled libllama vs. remote API, spec 14.2 open).
  Affects P3.9.
