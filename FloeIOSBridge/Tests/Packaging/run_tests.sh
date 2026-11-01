#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1

echo "== existing signing-logic checks =="
/usr/bin/python3 -B "$PROJECT_DIR/scripts/test_signing.py"

echo "== packaging verification checks =="
/usr/bin/python3 -B -m unittest discover -s "$SCRIPT_DIR" -p 'test_*.py' -v
