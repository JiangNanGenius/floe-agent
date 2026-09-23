#!/bin/bash
# run_smp_tests.sh — driver for the TinyEMU SMP host tests.
# Equivalent to `make test` in this directory; kept for symmetry with the
# shell-driver style of FloeAgent/LinuxGuest/tests.
set -euo pipefail
cd "$(dirname "$0")"
make test "$@"
