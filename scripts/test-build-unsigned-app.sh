#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="$ROOT_DIR/scripts/build-unsigned-app.sh"

output=""
exit_code=0
set +e
output="$(PROJECT_PATH="$ROOT_DIR/does-not-exist/Recordly.xcodeproj" "$SCRIPT_PATH" 2>&1)"
exit_code=$?
set -e

if [[ $exit_code -eq 0 ]]; then
  echo "FAIL: unsigned build script unexpectedly succeeded with invalid project path"
  exit 1
fi

if [[ "$output" != *"Required project not found"* ]]; then
  echo "FAIL: expected missing project reference in output"
  echo "$output"
  exit 1
fi

echo "PASS"
