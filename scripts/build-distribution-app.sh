#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Recordly.xcodeproj}"
SCHEME="${SCHEME:-Recordly}"
CONFIGURATION="${CONFIGURATION:-Release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT_DIR/build/Recordly.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$ROOT_DIR/build/export}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build/dist}"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-$ROOT_DIR/scripts/export-options-developer-id.plist}"
TMP_EXPORT_OPTIONS_PLIST=""

usage() {
  cat <<EOF
Usage:
  TEAM_ID=<APPLE_TEAM_ID> \\
  SIGNING_IDENTITY="Developer ID Application: Your Name (TEAM_ID)" \\
  ./scripts/build-distribution-app.sh

Optional env vars:
  PROJECT_PATH
  SCHEME
  CONFIGURATION
  ARCHIVE_PATH
  EXPORT_PATH
  OUTPUT_DIR
  EXPORT_OPTIONS_PLIST
EOF
}

require_env() {
  local name="$1"
  if [[ -z "${(P)name:-}" ]]; then
    echo "Missing required environment variable: $name" >&2
    usage >&2
    exit 1
  fi
}

require_file() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo "Required file not found: $path" >&2
    exit 1
  fi
}

require_identity() {
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$SIGNING_IDENTITY"; then
    echo "Signing identity not found in keychain: $SIGNING_IDENTITY" >&2
    exit 1
  fi
}

require_env "TEAM_ID"
require_env "SIGNING_IDENTITY"
require_file "$PROJECT_PATH"
require_file "$EXPORT_OPTIONS_PLIST"
require_identity

mkdir -p "$(dirname "$ARCHIVE_PATH")" "$EXPORT_PATH" "$OUTPUT_DIR"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

TMP_EXPORT_OPTIONS_PLIST="$(mktemp "${TMPDIR:-/tmp}/recordly-export-options.XXXXXX.plist")"
cp "$EXPORT_OPTIONS_PLIST" "$TMP_EXPORT_OPTIONS_PLIST"
trap '[[ -n "$TMP_EXPORT_OPTIONS_PLIST" ]] && rm -f "$TMP_EXPORT_OPTIONS_PLIST"' EXIT
/usr/libexec/PlistBuddy -c "Set :teamID $TEAM_ID" "$TMP_EXPORT_OPTIONS_PLIST" >/dev/null

xcodebuild archive \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$TMP_EXPORT_OPTIONS_PLIST"

APP_PATH="$EXPORT_PATH/$SCHEME.app"
require_file "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

ZIP_PATH="$OUTPUT_DIR/$SCHEME.zip"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
rm -rf "$ARCHIVE_PATH"

echo "Archive: $ARCHIVE_PATH"
echo "App: $APP_PATH"
echo "Zip: $ZIP_PATH"
