#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="$ROOT_DIR/scripts/build-distribution-app.sh"
ARCHIVE_PATH="$(mktemp -u "${TMPDIR:-/tmp}/recordly-distribution-archive.XXXXXX.xcarchive")"
EXPORT_PATH="$(mktemp -d "${TMPDIR:-/tmp}/recordly-distribution-export.XXXXXX")"
OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/recordly-distribution-output.XXXXXX")"

output=""
exit_code=0
set +e
output="$(ARCHIVE_PATH="$ARCHIVE_PATH" EXPORT_PATH="$EXPORT_PATH" OUTPUT_DIR="$OUTPUT_DIR" "$SCRIPT_PATH" 2>&1)"
exit_code=$?
set -e

if [[ $exit_code -eq 0 ]]; then
  echo "FAIL: distribution build script unexpectedly succeeded"
  exit 1
fi

if [[ "$output" != *"disabled"* || "$output" != *"Xcode"* ]]; then
  echo "FAIL: expected disabled Xcode build message"
  echo "$output"
  exit 1
fi

if [[ -e "$ARCHIVE_PATH" || -n "$(find "$EXPORT_PATH" -mindepth 1 -maxdepth 1 -print -quit)" || -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "FAIL: disabled distribution build script should not generate artifacts"
  exit 1
fi

echo "PASS"
