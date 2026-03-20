#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="$ROOT_DIR/scripts/build-distribution-app.sh"

run_missing_env_case() {
  local label="$1"
  local expected="$2"

  local output=""
  local exit_code=0
  set +e
  output="$("$SCRIPT_PATH" 2>&1)"
  exit_code=$?
  set -e

  if [[ $exit_code -eq 0 ]]; then
    echo "FAIL: $label unexpectedly succeeded"
    exit 1
  fi

  if [[ "$output" != *"$expected"* ]]; then
    echo "FAIL: $label missing expected text: $expected"
    echo "$output"
    exit 1
  fi
}

set +u
unset TEAM_ID
unset SIGNING_IDENTITY
set -u
run_missing_env_case "missing TEAM_ID" "TEAM_ID"

export TEAM_ID="TESTTEAMID"
set +u
unset SIGNING_IDENTITY
set -u
run_missing_env_case "missing SIGNING_IDENTITY" "SIGNING_IDENTITY"

echo "PASS"
