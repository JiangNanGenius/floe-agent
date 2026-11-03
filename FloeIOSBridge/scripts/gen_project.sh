#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen is required" >&2; exit 2; }
cd "$PROJECT_DIR"
xcodegen generate --spec project.yml
