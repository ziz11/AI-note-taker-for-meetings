#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Recordly.xcodeproj}"
SCHEME="${SCHEME:-Recordly}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build/unsigned}"
APP_DIR="$BUILD_ROOT/export"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build/dist-unsigned}"

usage() {
  cat <<EOF
Usage:
  ./scripts/build-unsigned-app.sh

Optional env vars:
  PROJECT_PATH
  SCHEME
  CONFIGURATION
  BUILD_ROOT
  OUTPUT_DIR
EOF
}

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! -e "$PROJECT_PATH" ]]; then
  echo "Required project not found: $PROJECT_PATH" >&2
  exit 1
fi

mkdir -p "$APP_DIR" "$OUTPUT_DIR"
rm -rf "$BUILD_ROOT/Build" "$APP_DIR/$SCHEME.app"

xcodebuild build \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$BUILD_ROOT/Build" \
  -destination "platform=macOS" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

BUILT_APP="$BUILD_ROOT/Build/Build/Products/$CONFIGURATION/$SCHEME.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "Built app not found: $BUILT_APP" >&2
  exit 1
fi

cp -R "$BUILT_APP" "$APP_DIR/$SCHEME.app"

ZIP_PATH="$OUTPUT_DIR/$SCHEME-unsigned.zip"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR/$SCHEME.app" "$ZIP_PATH"

echo "App: $APP_DIR/$SCHEME.app"
echo "Zip: $ZIP_PATH"
