#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$ROOT_DIR/.build"
RELEASE_DIR="$BUILD_DIR/release"
APP_NAME="Oppy"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
WORKER_SRC_DIR="$ROOT_DIR/worker"
WORKER_DST_DIR="$RESOURCES_DIR/worker"
BUNDLE_VENV=0
IDENTITY=""
NOTARY_PROFILE=""

usage() {
  cat <<'EOF'
Usage: scripts/package_macos.sh [options]

Builds a distributable macOS .app bundle and zip archive at dist/.

Options:
  --bundle-venv            Build and include portable worker virtualenv inside app bundle.
  --identity "NAME"        Developer ID identity for codesign.
  --notary-profile "NAME"  notarytool keychain profile name.
  -h, --help               Show this help message.

Examples:
  scripts/package_macos.sh
  scripts/package_macos.sh --identity "Developer ID Application: Your Name (TEAMID)"
  scripts/package_macos.sh --identity "Developer ID Application: Your Name (TEAMID)" --notary-profile "oppy-notary"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-venv)
      BUNDLE_VENV=1
      shift
      ;;
    --identity)
      IDENTITY="${2:-}"
      if [[ -z "$IDENTITY" ]]; then
        echo "Missing value for --identity" >&2
        exit 1
      fi
      shift 2
      ;;
    --notary-profile)
      NOTARY_PROFILE="${2:-}"
      if [[ -z "$NOTARY_PROFILE" ]]; then
        echo "Missing value for --notary-profile" >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

echo "[1/6] Building release binary..."
swift build --package-path "$ROOT_DIR" -c release

echo "[2/6] Creating app bundle layout..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$RELEASE_DIR/Oppy" "$MACOS_DIR/Oppy"
chmod +x "$MACOS_DIR/Oppy"

cat > "$CONTENTS_DIR/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Oppy</string>
  <key>CFBundleExecutable</key>
  <string>Oppy</string>
  <key>CFBundleIconFile</key>
  <string></string>
  <key>CFBundleIdentifier</key>
  <string>com.oppy.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Oppy</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Oppy needs microphone access to transcribe meeting audio.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Oppy needs screen and system audio capture access to transcribe meeting audio.</string>
</dict>
</plist>
EOF

echo "[3/6] Copying worker files..."
rm -rf "$WORKER_DST_DIR"
mkdir -p "$WORKER_DST_DIR"

RSYNC_EXCLUDES=(
  --exclude='.venv/'
  --exclude='__pycache__/'
  --exclude='.pytest_cache/'
  --exclude='tests/'
  --exclude='*.pyc'
)

if [[ "$BUNDLE_VENV" -eq 1 ]]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "--bundle-venv requires python3 to be installed" >&2
    exit 1
  fi
fi

rsync -a "${RSYNC_EXCLUDES[@]}" "$WORKER_SRC_DIR/" "$WORKER_DST_DIR/"

if [[ "$BUNDLE_VENV" -eq 1 ]]; then
  echo "[3.1/6] Building portable worker virtualenv..."
  rm -rf "$WORKER_DST_DIR/.venv"
  python3 -m venv --copies "$WORKER_DST_DIR/.venv"
  "$WORKER_DST_DIR/.venv/bin/python3" -m pip install --upgrade pip
  "$WORKER_DST_DIR/.venv/bin/python3" -m pip install -r "$WORKER_DST_DIR/requirements.txt"
fi

if [[ -z "$IDENTITY" ]]; then
  echo "[4/6] Skipping codesign (no --identity provided)."
else
  echo "[4/6] Codesigning app bundle..."
  codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP_DIR"
  codesign --verify --deep --strict --verbose=2 "$APP_DIR"
fi

ZIP_PATH="$DIST_DIR/${APP_NAME}.zip"
echo "[5/6] Creating zip archive..."
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
  if [[ -z "$IDENTITY" ]]; then
    echo "Cannot notarize without --identity" >&2
    exit 1
  fi
  echo "[6/6] Submitting for notarization..."
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_DIR"
else
  echo "[6/6] Skipping notarization (no --notary-profile provided)."
fi

echo "Done."
echo "App bundle: $APP_DIR"
echo "Zip archive: $ZIP_PATH"
