#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="$ROOT_DIR/scripts/build-unsigned-app.sh"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/recordly-unsigned-build.XXXXXX")"
OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/recordly-unsigned-output.XXXXXX")"

output=""
exit_code=0
set +e
output="$(BUILD_ROOT="$BUILD_ROOT" OUTPUT_DIR="$OUTPUT_DIR" "$SCRIPT_PATH" 2>&1)"
exit_code=$?
set -e

if [[ $exit_code -eq 0 ]]; then
  echo "FAIL: unsigned build script unexpectedly succeeded"
  exit 1
fi

if [[ "$output" != *"disabled"* || "$output" != *"Xcode"* ]]; then
  echo "FAIL: expected disabled Xcode build message"
  echo "$output"
  exit 1
fi

if [[ -n "$(find "$BUILD_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" || -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "FAIL: disabled unsigned build script should not generate artifacts"
  exit 1
fi

echo "PASS"
