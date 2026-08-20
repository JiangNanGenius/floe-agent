#!/bin/bash
# secret_scan.sh — gitleaks scan with redaction. Runs on the full history
# so accidentally committed secrets fail even if later removed.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v gitleaks >/dev/null 2>&1; then
    echo "error: gitleaks not installed (brew install gitleaks)" >&2
    exit 1
fi

gitleaks git . \
    --gitleaks-ignore-path ../.gitleaksignore \
    --redact \
    --report-path .gitleaks-report.json \
    --verbose

echo "secret_scan OK: no secrets detected"
