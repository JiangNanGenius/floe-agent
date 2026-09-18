#!/bin/bash
# Build191 rich PPTX/DOCX structure checks + independent archive read-back.
#
# What it proves: the current FloeDocuments builders produce the rich deck
# (text box, preset shape, deduplicated images, bar/line/pie charts with
# `Sheet1!$...` formulas and a `ppt/embeddings/floe-chart-data-<n>.xlsx`
# workbook each), strict save validation accepts it and rejects a deck whose
# chart lost its workbook, and text edits preserve chart/media bytes. With
# PPT_EVIDENCE_DIR set, the generated deck is exported and read back by
# `validate_rich_pptx.py` (python-pptx + openpyxl), an independent parser
# rather than Floe code.
#
# How: compiles the CURRENT sources of FloeCore, FloeModels, FloeTools,
# FloeWorkspace, FloeDocuments and the vendored SMBClient checkout with one
# toolchain (Xcode-beta), so the previous mixed-toolchain `.build/debug` module
# set is never consumed. Only third-party module objects that cannot be
# rebuilt cheaply (Crypto, ZIPFoundation, SWCompression, BitByteData) come from
# the cached FloeAgent/.build/apple/Products/Debug build.
#
# No SwiftPM, no root `swift build`/`test`, no App build, no network, no paid
# call. No writes outside the build dir and PPT_EVIDENCE_DIR.
#
# Usage:
#   bash FloeAgent/scripts/tests/pptx/run_rich_deck_checks.sh
#   PPT_EVIDENCE_DIR=Local/Artifacts/build191-ppt \
#     bash FloeAgent/scripts/tests/pptx/run_rich_deck_checks.sh
#
# Env:
#   SWIFTC           explicit swiftc (default: Xcode-beta, then xcrun)
#   PPT_BUILD_DIR    scratch output dir (default mktemp)
#   PPT_EVIDENCE_DIR when set, the deck is copied there and validated with
#                    python-pptx/openpyxl if available
#   PPT_PYTHON       python interpreter with python-pptx/openpyxl
#                    (default: first python3 that imports both)
#
# Exit codes: 0 = checks passed, 1 = a check/compile failed,
#             2 = prerequisites unavailable (SKIP, not a pass).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
APP="$REPO/FloeAgent"
APPLE_DEBUG="$APP/.build/apple/Products/Debug"
SMB_SOURCES="$APP/.build/checkouts/SMBClient/Sources"
BUILD="${PPT_BUILD_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/floe-ppt.XXXXXX")}"

if [ -z "${SWIFTC:-}" ]; then
  XCODE_BETA_SWIFTC="/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
  if [ -x "$XCODE_BETA_SWIFTC" ]; then
    SWIFTC="$XCODE_BETA_SWIFTC"
  else
    SWIFTC="$(xcrun --find swiftc 2>/dev/null || true)"
  fi
fi

PREBUILT_OBJECTS=(
  "$APPLE_DEBUG/Crypto_Module.o"
  "$APPLE_DEBUG/ZIPFoundation_Module.o"
  "$APPLE_DEBUG/SWCompression_Module.o"
  "$APPLE_DEBUG/BitByteData_Module.o"
)
missing=0
[ -x "${SWIFTC:-}" ] || { echo "SKIP: no swiftc"; missing=1; }
for object in "${PREBUILT_OBJECTS[@]}"; do
  [ -f "$object" ] || { echo "SKIP: missing cached third-party object $object"; missing=1; }
done
[ -d "$SMB_SOURCES" ] || { echo "SKIP: missing SMBClient checkout sources $SMB_SOURCES"; missing=1; }
[ -f "$APP/Sources/FloeDocuments/OfficeDocumentBuilders.swift" ] || { echo "SKIP: missing FloeDocuments sources"; missing=1; }
if [ "$missing" -ne 0 ]; then
  echo "SKIP: restore the cached dependency checkout/build artifacts to run this harness."
  exit 2
fi

rm -rf "$BUILD"
mkdir -p "$BUILD"
echo "== build dir $BUILD"
echo "== swiftc $SWIFTC ($("$SWIFTC" --version 2>/dev/null | tail -1))"

COMMON=(-parse-as-library -swift-version 6
  -enable-experimental-feature StrictConcurrency
  -enable-upcoming-feature NonisolatedNonsendingByDefault)
fail() { echo "$1"; tail -30 "$2"; exit 1; }

echo "== compile FloeCore (current sources)"
"$SWIFTC" "${COMMON[@]}" -I "$APPLE_DEBUG" -module-name FloeCore \
  -emit-library -emit-module -emit-module-path "$BUILD/FloeCore.swiftmodule" \
  -o "$BUILD/libFloeCore.dylib" "$APP"/Sources/FloeCore/*.swift \
  > "$BUILD/core.log" 2>&1 || fail "COMPILE-FAIL FloeCore" "$BUILD/core.log"

echo "== compile FloeModels (current sources)"
"$SWIFTC" "${COMMON[@]}" -I "$BUILD" -I "$APPLE_DEBUG" -module-name FloeModels \
  -emit-library -emit-module -emit-module-path "$BUILD/FloeModels.swiftmodule" \
  -o "$BUILD/libFloeModels.dylib" "$APP"/Sources/FloeModels/*.swift \
  -L "$BUILD" -lFloeCore -Xlinker -rpath -Xlinker "$BUILD" \
  > "$BUILD/models.log" 2>&1 || fail "COMPILE-FAIL FloeModels" "$BUILD/models.log"

echo "== compile FloeTools (current sources)"
"$SWIFTC" "${COMMON[@]}" -I "$BUILD" -I "$APPLE_DEBUG" -module-name FloeTools \
  -emit-library -emit-module -emit-module-path "$BUILD/FloeTools.swiftmodule" \
  -o "$BUILD/libFloeTools.dylib" "$APP"/Sources/FloeTools/*.swift \
  -L "$BUILD" -lFloeCore -lFloeModels -Xlinker -rpath -Xlinker "$BUILD" \
  > "$BUILD/tools.log" 2>&1 || fail "COMPILE-FAIL FloeTools" "$BUILD/tools.log"

echo "== compile SMBClient (vendored checkout, Swift 5 mode as published)"
smb_sources=()
while IFS= read -r line; do smb_sources+=("$line"); done < <(find "$SMB_SOURCES" -name '*.swift' -print)
"$SWIFTC" -parse-as-library -swift-version 5 -module-name SMBClient \
  -emit-library -emit-module -emit-module-path "$BUILD/SMBClient.swiftmodule" \
  -o "$BUILD/libSMBClient.dylib" "${smb_sources[@]}" \
  > "$BUILD/smb.log" 2>&1 || fail "COMPILE-FAIL SMBClient" "$BUILD/smb.log"

echo "== compile FloeWorkspace (current sources)"
workspace_sources=()
while IFS= read -r line; do workspace_sources+=("$line"); done < <(find "$APP/Sources/FloeWorkspace" -name '*.swift' -print)
"$SWIFTC" "${COMMON[@]}" -I "$BUILD" -I "$APPLE_DEBUG" -module-name FloeWorkspace \
  -emit-library -emit-module -emit-module-path "$BUILD/FloeWorkspace.swiftmodule" \
  -o "$BUILD/libFloeWorkspace.dylib" "${workspace_sources[@]}" \
  -L "$BUILD" -lFloeCore -lFloeModels -lFloeTools -lSMBClient \
  -Xlinker -rpath -Xlinker "$BUILD" \
  "$APPLE_DEBUG/ZIPFoundation_Module.o" "$APPLE_DEBUG/SWCompression_Module.o" \
  "$APPLE_DEBUG/BitByteData_Module.o" "$APPLE_DEBUG/Crypto_Module.o" \
  > "$BUILD/workspace.log" 2>&1 || fail "COMPILE-FAIL FloeWorkspace" "$BUILD/workspace.log"

echo "== compile harness + current FloeDocuments sources"
documents_sources=()
while IFS= read -r line; do documents_sources+=("$line"); done < <(find "$APP/Sources/FloeDocuments" -name '*.swift' -print)
"$SWIFTC" -swift-version 6 -enable-experimental-feature StrictConcurrency \
  -I "$BUILD" -I "$APPLE_DEBUG" \
  "$SCRIPT_DIR/rich_deck_checks.swift" "${documents_sources[@]}" \
  -L "$BUILD" -lFloeCore -lFloeModels -lFloeTools -lFloeWorkspace -lSMBClient \
  -Xlinker -rpath -Xlinker "$BUILD" \
  -o "$BUILD/rich_deck_checks" \
  > "$BUILD/documents.log" 2>&1 || fail "COMPILE-FAIL FloeDocuments" "$BUILD/documents.log"

echo "== run rich deck checks"
if [ -n "${PPT_EVIDENCE_DIR:-}" ]; then
  mkdir -p "$PPT_EVIDENCE_DIR"
  if ! FLOE_PPT_EVIDENCE="$PPT_EVIDENCE_DIR" "$BUILD/rich_deck_checks"; then
    echo "RICH DECK CHECKS FAILED"
    exit 1
  fi
else
  if ! "$BUILD/rich_deck_checks"; then
    echo "RICH DECK CHECKS FAILED"
    exit 1
  fi
fi
echo "RICH DECK CHECKS PASSED"

if [ -n "${PPT_EVIDENCE_DIR:-}" ]; then
  deck="$PPT_EVIDENCE_DIR/rich-deck.pptx"
  if [ ! -f "$deck" ]; then
    echo "PPT-EVIDENCE-FAIL: expected exported deck at $deck"
    exit 1
  fi
  python="${PPT_PYTHON:-}"
  if [ -z "$python" ]; then
    for candidate in python3 /usr/bin/python3 /opt/homebrew/bin/python3.12; do
      if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "import pptx, openpyxl" >/dev/null 2>&1; then
        python="$candidate"; break
      fi
    done
  fi
  if [ -z "$python" ]; then
    echo "PPT-PYTHON-SKIP: no python with python-pptx/openpyxl; run validate_rich_pptx.py manually"
    exit 0
  fi
  echo "== independent python-pptx/openpyxl read-back ($python)"
  "$python" "$APP/scripts/tests/validate_rich_pptx.py" "$deck"
fi
