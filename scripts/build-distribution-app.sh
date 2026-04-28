#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  cat <<EOF
Usage:
  ./scripts/build-distribution-app.sh

This repository-local packaging script is disabled.
Build and archive Recordly directly from Xcode instead.
EOF
}

echo "This script is disabled. Build Recordly directly in Xcode." >&2
exit 1
