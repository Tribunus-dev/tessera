# Tessera Studio — Linux (GTK4 + Adwaita)

Fedora port of `TesseraStudio` per `docs/linux-gtk4-port-spec.md` — full parity, not MVP.

## Build

```bash
sudo dnf install gtk4-devel libadwaita-devel gtksourceview5-devel libsecret-devel libsoup3-devel libedataserver-devel libetpan-devel
cmake -B build-linux -S tessera-studio-linux
cmake --build build-linux
./build-linux/tessera-studio-linux        # UI when deps present
./build-linux/tessera-studio-linux --help # headless fallback
glib-compile-schemas tessera-studio-linux/res
```

Headless core builds without GTK:

```bash
cmake -B /tmp/b -S tessera-studio-linux -DTESSERA_LINUX_BUILD_UI=OFF && cmake --build /tmp/b && ctest --test-dir /tmp/b
```

## Layout

- `src/app/` — `AdwApplication` entry (spec 5.1 `Adw.Application` + `AdwOverlaySplitView`)
- `src/core/{agent,engine,ops,data,learning,model}` — portable core (AgentLoop, ApprovalEngine, provider dlopen, calibration, DataLayer Postgres+Valkey+DuckDB, receipts)
- `src/core/encryption/` — libsecret (§7.1) + LUKS/PleadTheFifth (§7.2)
- `src/core/productivity/` — Contacts (libEBook/CardDAV+VCard), Calendar (EDS+CalDAV+libical), Reminders (VTODO+libnotify), Mail (libetpan) — §7.3 all REQUIRED
- `src/ui/surfaces/{chat,editor,code,workflow,receipts,learning,notes,tasks,settings}` — Adwaita surfaces (spec 5.2 widgets: GtkSourceView, Cairo, GtkLevelBar, AdwDialog)
- `src/ffi/ctessera/` — `libllama`/`libtessera-ffi` dlopen shim (portable, mirrors `cllama_shim.c`)
- `packaging/flatpak|rpm` + `android/` (Kotlin Compose companion §10.5)

Data stays on worker threads, never GTK thread (spec §12). Secrets via libsecret, not plaintext.

## Host enablement (i915)
GuC/HuC: `sudo grubby --update-kernel=ALL --args="i915.enable_guc=3"` then verify `journalctl -k | grep -i guc`.
OpenVINO 2025.1 top-5: 4.0 baseline, 4.5 op-policy, 4.1 async pool, 4.7 dma-buf, 4.3 LRU — see docs/openvino-ane-port-spec.md.
