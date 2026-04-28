#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  cat <<EOF
Usage:
  ./scripts/build-unsigned-app.sh

This repository-local packaging script is disabled.
Build and archive Recordly directly from Xcode instead.
EOF
}

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

echo "This script is disabled. Build Recordly directly in Xcode." >&2
exit 1
