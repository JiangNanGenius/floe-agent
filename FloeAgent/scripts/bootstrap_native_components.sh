#!/bin/bash
# Install the native components the app still links: PDFium (document
# rendering), LibArchive (bounded RAR reads), the reviewed Office native host,
# and the dash/ios_system shell frameworks used by the native compatibility
# backend.
#
# Phase 2 (TinyEMU migration): the bundled CPython runtime, Python extension
# frameworks, ios-wheelhouse packages and the NodeMobile/NodeTools downloads
# left the IPA; local Python/Node run inside each environment's TinyEMU Linux
# guest. The retired recipes are archived recoverably under
# ThirdParty/NativeRuntimeArchive/recipes/ and must not return to the build.
set -euo pipefail

cd "$(dirname "$0")/.."

# Native PDF content editing is independent of any script runtime.
python3 scripts/bootstrap_pdfium.py
python3 scripts/bootstrap_libarchive.py
python3 scripts/bootstrap_office_host.py

# The local terminal needs the POSIX interpreter in addition to ios_system.
bash "$(dirname "$0")/build_dash_ios.sh"

echo "Installed native components (PDFium, LibArchive, Office host, dash)"
