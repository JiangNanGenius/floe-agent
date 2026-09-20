#!/usr/bin/env bash
# Install reviewed inputs from the immutable lock; --check performs read-only verification.
set -euo pipefail
exec python3 "$(dirname "$0")/pin_node_tools.py" "$@"
