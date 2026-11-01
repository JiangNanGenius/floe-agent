#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1

echo "== local Bridge release publisher checks =="
/usr/bin/python3 -B -m unittest discover -s "$SCRIPT_DIR" -p 'test_*.py' -v
