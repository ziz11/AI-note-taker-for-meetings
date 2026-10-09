#!/bin/zsh
set -euo pipefail

# Local Release packaging with the same persistent identity used by Debug.
# The resulting app runs outside Xcode; this is not Developer ID distribution.
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="${RECORDLY_BUILD_DIR:-$TASK_ROOT/build/standalone-local}"
TASK_IDENTITY="${RECORDLY_SIGNING_IDENTITY:-Recordly Local Development}"
TASK_PACKAGES="${RECORDLY_PACKAGE_CACHE:-$TASK_OUTPUT/SourcePackages}"
if [[ "${1:-}" == "--help" ]]; then
  print 'Usage: ./scripts/build-standalone-local.sh'
  print 'Optional: RECORDLY_BUILD_DIR, RECORDLY_PACKAGE_CACHE, RECORDLY_SIGNING_IDENTITY'
  exit 0
fi
if [[ $# -ne 0 ]]; then
  print -u2 'Unexpected argument. Use --help.'
  exit 2
fi
if ! security find-identity -v -p codesigning | /usr/bin/grep -F "\"$TASK_IDENTITY\"" >/dev/null; then
  print -u2 "Missing signing identity: $TASK_IDENTITY. Run scripts/setup-local-signing.sh first."
  exit 1
fi
mkdir -p "$TASK_OUTPUT"
xcodebuild build -project "$TASK_ROOT/Recordly.xcodeproj" -scheme Recordly \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$TASK_OUTPUT" -clonedSourcePackagesDirPath "$TASK_PACKAGES" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$TASK_IDENTITY" DEVELOPMENT_TEAM=''
TASK_APP="$TASK_OUTPUT/Build/Products/Release/Recordly.app"
codesign --verify --deep --strict "$TASK_APP"
TASK_REVISION="$(git -C "$TASK_ROOT" rev-parse --short HEAD)"
TASK_ARCHIVE="$TASK_OUTPUT/Recordly-$TASK_REVISION-local.zip"
ditto -c -k --sequesterRsrc --keepParent "$TASK_APP" "$TASK_ARCHIVE"
print "Application: $TASK_APP"
print "Archive: $TASK_ARCHIVE"
