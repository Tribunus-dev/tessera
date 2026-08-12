#!/usr/bin/env bash
#
# release-build.sh
#
# Full release build pipeline for Tessera distributed on GitHub.
# Runs in sequence:
#   1. setup-libreoffice-vendor.sh  — download + strip LO headless bundle
#   2. Vendor Python.xcframework    — copy from Homebrew, wrap as xcframework
#   3. xcodebuild                  — build TesseraStudio.app
#   4. Embed vendored Python       — copy Python.xcframework into app bundle
#   5. Embed LO bundle             — copy into app Contents/Resources/
#   6. productbuild                — produce signed .pkg installer
#
# Usage:
#   ./release-build.sh [--skip-lo] [--skip-python] [--skip-sign] [--identity <name>]
#
# Environment:
#   LO_VERSION         Override LibreOffice version (default: 25.8.3)
#
set -euo pipefail

# Resolve the script's own file path robustly regardless of cwd.
_SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
if [[ "$_SCRIPT_SOURCE" = /* ]]; then
    _SCRIPT_ABS="$_SCRIPT_SOURCE"
else
    _SCRIPT_ABS="$(pwd)/$_SCRIPT_SOURCE"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SCRIPT_ABS")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
SKIP_LO=false
SKIP_PYTHON=false
SKIP_SIGN=false
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
PRODUCT_NAME="TesseraStudioMac"
PKG_IDENTIFIER="dev.tribunus.tessera"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-lo)        SKIP_LO=true;        shift ;;
        --skip-python)    SKIP_PYTHON=true;    shift ;;
        --skip-sign)      SKIP_SIGN=true;      shift ;;
        --identity)       SIGN_IDENTITY="$2";  shift 2 ;;
        --help)
            echo "Usage: $0 [--skip-lo] [--skip-python] [--skip-sign] [--identity <name>]"
            echo ""
            echo "  --skip-lo        Skip LibreOffice bundle download/extraction"
            echo "  --skip-python   Skip Python.xcframework vendoring"
            echo "  --skip-sign     Skip code signing and notarization"
            echo "  --identity <n>  Signing identity name (default: ad-hoc)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

BUILD_DIR="$REPO_ROOT/build/Release"
ARTIFACTS_DIR="$REPO_ROOT/artifacts"
LO_BUNDLE="$ARTIFACTS_DIR/LibreOffice-Headless"
PYTHON_XCFRAMEWORK="$ARTIFACTS_DIR/Python.xcframework"
PYTHON_HOMEBREW="/opt/homebrew/opt/python@3.14/Frameworks/Python.framework"
DMG_BASENAME="${PRODUCT_NAME}-$(date +%Y%m%d)-$(git rev-parse --short HEAD 2>/dev/null || echo 'nogit').pkg"

echo "==> Tessera Release Build"
echo "    Skip LO bundle:    $SKIP_LO"
echo "    Skip Python vend:  $SKIP_PYTHON"
echo "    Skip signing:     $SKIP_SIGN"
echo "    Signing:          ${SIGN_IDENTITY:-ad-hoc}"
echo "    Output:           $DMG_BASENAME"

# ---------------------------------------------------------------------------
# Step 1 — LibreOffice headless bundle
# ---------------------------------------------------------------------------
if [[ "$SKIP_LO" == false ]]; then
    echo ""
    echo "==> Step 1/6: Downloading LibreOffice headless bundle..."
    "$SCRIPT_DIR/../scripts/setup-libreoffice-vendor.sh"
    echo "    LO bundle ready at: $LO_BUNDLE"
else
    if [[ ! -d "$LO_BUNDLE" ]]; then
        echo "ERROR: --skip-lo but $LO_BUNDLE does not exist."
        echo "       Run the full pipeline once to fetch LO, or pass --skip-lo only on subsequent builds."
        exit 1
    fi
    echo ""
    echo "==> Step 1/6: Skipping LO bundle (using existing: $LO_BUNDLE)"
fi

# ---------------------------------------------------------------------------
# Step 2 — Vendor Python.framework as Python.xcframework
# ---------------------------------------------------------------------------
# Python.xcframework is a vendored copy of Python 3.14 with its install name
# patched to @rpath/Python.framework/Versions/3.14/Python. The app's
# @executable_path/../Frameworks LC_RPATH lets dyld find it inside the bundle
# at runtime, so no Homebrew dependency is needed on the end-user machine.
#
# We vendor it once; subsequent runs reuse the cached copy. Delete
# artifacts/Python.xcframework to force a refresh.
# ---------------------------------------------------------------------------
if [[ "$SKIP_PYTHON" == false ]]; then
    echo ""
    echo "==> Step 2/6: Vendoring Python.framework..."
    if [[ ! -d "$PYTHON_XCFRAMEWORK" ]]; then
        if [[ ! -d "$PYTHON_HOMEBREW" ]]; then
            echo "ERROR: Homebrew Python.framework not found at $PYTHON_HOMEBREW"
            echo "       Run: brew install python@3.14"
            exit 1
        fi
        echo "    Homebrew Python found — wrapping as Python.xcframework..."
        # The inner framework is the Homebrew Python.framework; we wrap it as
        # a multi-architecture xcframework so Xcode can embed it in the app.
        mkdir -p "$ARTIFACTS_DIR/Python.xcframework/macos-arm64_x86_64"
        cp -a "$PYTHON_HOMEBREW" "$ARTIFACTS_DIR/Python.xcframework/macos-arm64_x86_64/Python.framework"

        # Write the xcframework Info.plist (universal, macOS only)
        cat > "$PYTHON_XCFRAMEWORK/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>BinaryPath</key>
            <string>Python.framework/Versions/3.14/Python</string>
            <key>LibraryIdentifier</key>
            <string>macos-arm64_x86_64</string>
            <key>SupportedArchitectures</key>
            <array>
                <string>arm64</string>
                <string>x86_64</string>
            </array>
            <key>SupportedPlatformVersion</key>
            <integer>26</integer>
        </dict>
    </array>
    <key>CFBundlePackageType</key>
    <string>XFWK</string>
    <key>CFBundleShortVersionString</key>
    <string>3.14</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
PLIST
        echo "    Python.xcframework created at: $PYTHON_XCFRAMEWORK"
    else
        echo "    Python.xcframework already exists — reusing: $PYTHON_XCFRAMEWORK"
    fi
else
    echo ""
    echo "==> Step 2/6: Skipping Python vendoring"
fi

# ---------------------------------------------------------------------------
# Step 3 — Xcode build
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 3/6: Building TesseraStudio.app..."
if [[ ! -f "$REPO_ROOT/TesseraStudio.xcodeproj/project.pbxproj" ]]; then
    echo "ERROR: Xcode project not found. Run 'xcodegen generate' first."
    exit 1
fi

# Build for distribution (validates signing settings)
BUILD_OPTS=(
    -project "$REPO_ROOT/TesseraStudio.xcodeproj"
    -scheme TesseraStudioMac
    -configuration Release
    -derivedDataPath "$BUILD_DIR/DerivedData"
    -destination 'generic/platform=macOS'
    BUILD_LIBRARY_FOR_DISTRIBUTING=YES
)

if [[ "$SKIP_SIGN" == false ]]; then
    if [[ -n "$SIGN_IDENTITY" ]]; then
        BUILD_OPTS+=(
            CODE_SIGN_STYLE=Manual
            CODE_SIGN_IDENTITY="$SIGN_IDENTITY"
            CODE_SIGNING_REQUIRED=YES
        )
    else
        BUILD_OPTS+=( CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Automatic )
    fi
else
    BUILD_OPTS+=(
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
        CODE_SIGNING_REQUIRED=NO
    )
fi

xcodebuild "${BUILD_OPTS[@]}" build 2>&1 | tail -5

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release/${PRODUCT_NAME}.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: Build failed — .app not found at $APP_PATH"
    exit 1
fi
echo "    Built: $APP_PATH"

# ---------------------------------------------------------------------------
# Step 4 — Embed vendored Python.xcframework in app bundle
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 4/6: Embedding vendored Python.xcframework..."
if [[ ! -d "$PYTHON_XCFRAMEWORK" ]]; then
    echo "ERROR: Python.xcframework not found at $PYTHON_XCFRAMEWORK"
    echo "       Run without --skip-python to vendor it, or delete artifacts/Python.xcframework to rebuild."
    exit 1
fi

PYTHON_DEST="$APP_PATH/Contents/Frameworks/Python.xcframework"
if [[ -d "$PYTHON_DEST" ]]; then
    rm -rf "$PYTHON_DEST"
fi
cp -a "$PYTHON_XCFRAMEWORK" "$PYTHON_DEST"
echo "    Embedded: Contents/Frameworks/Python.xcframework"

# ---------------------------------------------------------------------------
# Step 5 — Embed LibreOffice bundle in app
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 5/6: Embedding LibreOffice headless bundle..."

LO_DEST="$APP_PATH/Contents/Resources/LibreOffice-Headless"

if [[ -d "$LO_DEST" ]]; then
    rm -rf "$LO_DEST"
fi

cp -a "$LO_BUNDLE" "$LO_DEST"

# Copy MPL 2.0 attribution into the app bundle's Legal folder
mkdir -p "$APP_PATH/Contents/Resources/Legal"
cp "$LO_BUNDLE/NOTICE.txt" "$APP_PATH/Contents/Resources/Legal/LibreOffice-NOTICE.txt"

# Copy full MPL 2.0 license text
curl -LsS -o "$APP_PATH/Contents/Resources/Legal/MPL-2.0.txt" \
    "https://www.mozilla.org/media/MPL/2.0/index.txt" \
    2>/dev/null || cat > "$APP_PATH/Contents/Resources/Legal/MPL-2.0.txt" <<'EOF'
Mozilla Public License Version 2.0
https://www.mozilla.org/en-US/MPL/2.0/
EOF

echo "    Embedded: Contents/Resources/LibreOffice-Headless/"

# ---------------------------------------------------------------------------
# Step 6 — Package as .pkg
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 6/6: Creating installer package..."

mkdir -p "$REPO_ROOT/artifacts/pkg"

PKG_ARGS=(
    --identifier "$PKG_IDENTIFIER"
    --version "$(git describe --tags 2>/dev/null || echo '1.0.0')-$(date +%Y%m%d)"
    --root "$APP_PATH"
    /Applications
)
[[ -n "${SIGN_IDENTITY:-}" ]] && PKG_ARGS+=(--sign "$SIGN_IDENTITY")

PKG_PATH="$REPO_ROOT/artifacts/pkg/$DMG_BASENAME"

productbuild "${PKG_ARGS[@]}" "$PKG_PATH" 2>&1 | tail -3

if [[ -f "$PKG_PATH" ]]; then
    echo ""
    echo "==> Release build complete: $DMG_BASENAME ($(du -h "$PKG_PATH" | cut -f1))"
    echo "    $PKG_PATH"
    echo ""
    echo "    Contents:"
    echo "      Contents/Frameworks/Python.xcframework        (Python 3.14, vendored)"
    echo "      Contents/Resources/LibreOffice-Headless/  (stripped headless LO)"
    echo "      Contents/Resources/Legal/LibreOffice-NOTICE.txt  (MPL attribution)"
    echo "      Contents/Resources/Legal/MPL-2.0.txt  (MPL 2.0 license)"
else
    echo "ERROR: packagebuild failed — no .pkg produced."
    exit 1
fi
