#!/usr/bin/env bash
#
# setup-libreoffice-vendor.sh
#
# Build-time bundler for release distributions. Downloads, extracts, and strips
# the minimal headless LibreOffice subset into the artifacts directory consumed
# by the release packaging step.
#
# Run this as part of the release build (before packaging). It requires network
# access to download the DMG from documentfoundation.org.
#
# Output: TesseraStudio/artifacts/LibreOffice-Headless/
#   The release packaging step copies this into:
#     TesseraStudio.app/Contents/Resources/LibreOffice-Headless/
#
# License: LibreOffice components are licensed under MPL 2.0.
#   See: https://www.mozilla.org/en-US/MPL/2.0/
#   Attribution notice is written to artifacts/LibreOffice-Headless/NOTICE.txt
#
set -euo pipefail

# Resolve the script's own file path robustly regardless of cwd.
# BASH_SOURCE[0] alone is relative to caller's cwd — use $0 as fallback
# and resolve via /proc/self/exe or a known anchor to get an absolute path.
_SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
if [[ "$_SCRIPT_SOURCE" = /* ]]; then
    _SCRIPT_ABS="$_SCRIPT_SOURCE"
else
    _SCRIPT_ABS="$(pwd)/$_SCRIPT_SOURCE"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SCRIPT_ABS")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACTS_DIR="${OUTPUT_DIR:-$REPO_ROOT/artifacts}"
OUTPUT_DIR="$ARTIFACTS_DIR/LibreOffice-Headless"
LO_APP="$OUTPUT_DIR/LibreOffice.app"

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------
LO_VERSION="${LO_VERSION:-25.8.7}"

# ---------------------------------------------------------------------------
# Architecture
# ---------------------------------------------------------------------------
ARCH="$(uname -m)"
# aarch64: URL directory AND filename both use "aarch64"
# x86_64: URL directory uses "x86_64" but filename uses "x86-64" (hyphen, not underscore)
case "$ARCH" in
    arm64)
        ARCH_URL_SUFFIX="aarch64"
        ARCH_DMG_SUFFIX="aarch64"
        ;;
    x86_64)
        ARCH_URL_SUFFIX="x86_64"
        ARCH_DMG_SUFFIX="x86-64"
        ;;
    *)
        echo "ERROR: Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

DMG_URL="https://download.documentfoundation.org/libreoffice/stable/${LO_VERSION}/mac/${ARCH_URL_SUFFIX}/LibreOffice_${LO_VERSION}_MacOS_${ARCH_DMG_SUFFIX}.dmg"
DMG_FILENAME="LibreOffice_${LO_VERSION}_MacOS_${ARCH_DMG_SUFFIX}.dmg"

echo "==> [setup-libreoffice-vendor] LibreOffice headless bundler"
echo "    Version: $LO_VERSION ($ARCH_URL_SUFFIX)"
echo "    Source:  $DMG_URL"
echo "    Output:  $LO_APP"

# ---------------------------------------------------------------------------
# Fast path: already extracted at correct version
# ---------------------------------------------------------------------------
if [[ -f "$LO_APP/Contents/MacOS/soffice" ]]; then
    SOFFICE_VERSION=$("$LO_APP/Contents/MacOS/soffice" --version 2>/dev/null | head -1 || echo "unknown")
    # Verify the extracted version matches the target LO_VERSION (strip any suffix like .1)
    SOFFICE_MAJMIN="${SOFFICE_VERSION%%.*}"
    TARGET_MAJMIN="${LO_VERSION%%.*}"
    if [[ "$SOFFICE_VERSION" == "$LO_VERSION"* ]]; then
        echo "    Status:  already extracted (soffice $SOFFICE_VERSION)"
        echo "    To rebuild: rm -rf $LO_APP && $0"
        exit 0
    else
        echo "    Status:  found soffice $SOFFICE_VERSION but need $LO_VERSION — rebuilding"
        rm -rf "$OUTPUT_DIR"
    fi
fi

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------
echo "==> Downloading LibreOffice $LO_VERSION..."
TMPDIR="$(mktemp -d)"
DMG_PATH="$TMPDIR/$DMG_FILENAME"

cleanup() {
    # Unmount any mounted DMG before removing the temp dir (DMG mounts are read-only)
    [[ -n "${MOUNT_POINT:-}" ]] && hdiutil detach "$MOUNT_POINT" -force 2>/dev/null || true
    [[ -d "$TMPDIR" ]] && rm -rf "$TMPDIR"
}
trap cleanup EXIT

if command -v curl >/dev/null 2>&1; then
    curl -fLSs --retry 3 --retry-delay 5 -o "$DMG_PATH" "$DMG_URL"
elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$DMG_PATH" "$DMG_URL"
else
    echo "ERROR: Neither curl nor wget found."
    exit 1
fi

if [[ ! -s "$DMG_PATH" ]]; then
    echo "ERROR: Download failed or produced an empty file."
    exit 1
fi
echo "    Downloaded: $(du -h "$DMG_PATH" | cut -f1)"

# ---------------------------------------------------------------------------
# Mount DMG
# ---------------------------------------------------------------------------
echo "==> Mounting DMG..."
MOUNT_POINT="$TMPDIR/mount"
mkdir -p "$MOUNT_POINT"
hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_POINT" -nobrowse > /dev/null
_cleanup_mount() { hdiutil detach "$MOUNT_POINT" -force 2>/dev/null || true; }
trap _cleanup_mount RETURN

# Locate LibreOffice.app inside the DMG
LO_APP_IN_DMG=""
for candidate in "$MOUNT_POINT/LibreOffice.app" "$MOUNT_POINT"/*.app; do
    if [[ -f "$candidate/Contents/MacOS/soffice" ]]; then
        LO_APP_IN_DMG="$candidate"
        break
    fi
done

if [[ -z "$LO_APP_IN_DMG" ]]; then
    echo "ERROR: Could not find LibreOffice.app inside the DMG."
    exit 1
fi

# ---------------------------------------------------------------------------
# Extract headless subset with spellcheck + all locales
# (~1.1GB vs 800MB full; spellcheck, locales, fonts, templates ~150MB)
# ---------------------------------------------------------------------------
echo "==> Extracting stripped headless subset..."
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

SRC="$LO_APP_IN_DMG/Contents"
DST="$LO_APP/Contents"

mkdir -p "$DST"

# Required top-level directories
for dir in MacOS Frameworks Resources PkgInfo; do
    [[ -d "$SRC/$dir" ]] && cp -a "$SRC/$dir" "$DST/$dir"
done

# Strip Resources to headless essentials
SRC_RES="$SRC/Resources"
DST_RES="$DST/Resources"

KEEP_RESOURCES=(
    # UNO Python bridge
    uno.py unohelper.py pythonloader.py pythonscript.py pythonloader.unorc
    python bootstraprc python.py
    # Core macros and config
    basic autocorr autotext Scripts
    # UNO types, filters, registry, XSLT
    types filter registry xslt
    # Language tag support
    liblangtag
    # Extensions: spellcheck dictionaries + spreadsheet solver
    extensions nlpsolver
    # soffice.cfg is the core config; strip UI icon themes (images_*.zip)
    soffice.cfg
    # Fonts, gallery, templates — useful data files, not GUI-only
    fonts gallery template
    # Misc essential
    uno_packages uno_packages.manifest
)

for entry in "$SRC_RES"/*; do
    [[ ! -e "$entry" ]] && continue
    name="$(basename "$entry")"

    # Always-keep items
    for keep in "${KEEP_RESOURCES[@]}"; do
        if [[ "$name" == "$keep" ]]; then
            cp -a "$entry" "$DST_RES/$name"
            continue 2
        fi
    done

    # Strip config/images_*.zip (icon themes, ~100MB, only needed for GUI)
    if [[ "$name" == "config" ]]; then
        mkdir -p "$DST_RES/config"
        # Only keep soffice.cfg from the config dir
        [[ -f "$SRC_RES/config/soffice.cfg" ]] && \
            cp -a "$SRC_RES/config/soffice.cfg" "$DST_RES/config/"
        continue
    fi

    # Keep all locales — the non-English ones are all <1MB each, free
    if [[ "$name" == *.lproj ]]; then
        cp -a "$entry" "$DST_RES/$name"
        continue
    fi
done

# Strip Frameworks to essential subset
SRC_FW="$SRC/Frameworks"
DST_FW="$DST/Frameworks"

KEEP_FRAMEWORKS=(
    LibreOfficePython.framework
    libuuresolverlo.dylib
    libmergedlo.dylib
    libuno_sal.dylib.3
    libuno_salhelpergcc3.dylib.3
    libuno_cppu.dylib.3
    libuno_cppuhelpergcc3.dylib.3
    libbass.dylib
    libbassmix.dylib
    libbasslo.dylib
    intl
)

for entry in "$SRC_FW"/*; do
    [[ ! -e "$entry" ]] && continue
    name="$(basename "$entry")"
    for keep in "${KEEP_FRAMEWORKS[@]}"; do
        [[ "$name" == "$keep" ]] && cp -a "$entry" "$DST_FW/$name" && continue 2
    done
done

# ---------------------------------------------------------------------------
# MPL 2.0 attribution notice (required for binary redistribution)
# ---------------------------------------------------------------------------
cat > "$OUTPUT_DIR/NOTICE.txt" <<'NOTICE'
This product includes LibreOffice software components.

LibreOffice is licensed under the Mozilla Public License Version 2.0 (MPL 2.0).

You may obtain a copy of the MPL 2.0 at:
  https://www.mozilla.org/en-US/MPL/2.0/

The full source code for LibreOffice is available at:
  https://www.libreoffice.org/download/source/

The following files distributed herein are portions of LibreOffice:
  All files under Contents/MacOS/, Contents/Frameworks/, and Contents/Resources/
  of the LibreOffice.app bundle.
NOTICE

# ---------------------------------------------------------------------------
# Verify critical files
# ---------------------------------------------------------------------------
echo "==> Verifying bundle..."
for path in \
    "$LO_APP/Contents/MacOS/soffice" \
    "$LO_APP/Contents/Frameworks/libmergedlo.dylib" \
    "$LO_APP/Contents/Frameworks/libuuresolverlo.dylib" \
    "$LO_APP/Contents/Frameworks/LibreOfficePython.framework/LibreOfficePython" \
    "$LO_APP/Contents/Resources/uno.py" \
    "$OUTPUT_DIR/NOTICE.txt"; do
    if [[ -f "$path" ]]; then
        echo "    $(basename "$path"): OK"
    else
        echo "    $(basename "$path"): MISSING — aborting"
        exit 1
    fi
done

echo ""
echo "==> Bundle ready (${LO_VERSION}): $(du -sh "$OUTPUT_DIR" | cut -f1)"
echo "    $LO_APP"
echo ""
echo "    Packaging step copies this into:"
echo "      TesseraStudio.app/Contents/Resources/LibreOffice-Headless/"
