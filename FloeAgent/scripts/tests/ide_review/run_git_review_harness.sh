#!/bin/bash
# Focused, direct swiftc compile+link of the real FloeGit/FloeCore/SwiftGitX
# sources into a standalone behavior harness. No SwiftPM build, no FloeApp,
# no simulator. `libgit2` is imported through the module map produced by a
# previous local build and linked from the cached C object.
#
# Usage: run_git_review_harness.sh <main.swift> <output-name> [extra swift files...]
# Example: FloeAgent/scripts/tests/ide_review/run_git_review_harness.sh \
#            "$(dirname "$0")/git_main.swift" git-review
#
# Requires a local build artifact for libgit2 (FloeAgent/.build/debug/libgit2.o
# and the generated libgit2 module map); it does not resolve dependencies or
# rebuild the engine.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TESTDIR="$SCRIPT_DIR"
BUILD="$ROOT/FloeAgent/.build/debug"
WORK="${HARNESS_SCRATCH:-$TESTDIR/.build}"
STAGE="$WORK/stage"
MODULEMAP="$ROOT/FloeAgent/.build/out/Intermediates.noindex/libgit2.build/Debug/libgit2-t.build/libgit2.modulemap"
LIBGIT2_INCLUDE="$ROOT/FloeAgent/.build/checkouts/libgit2/include"
SWIFTGITX_SRC="$ROOT/FloeAgent/.build/checkouts/SwiftGitX/Sources/SwiftGitX"

for artifact in "$BUILD/libgit2.o" "$MODULEMAP" "$LIBGIT2_INCLUDE" "$SWIFTGITX_SRC"; do
  if [ ! -e "$artifact" ]; then
    echo "missing local build artifact: $artifact" >&2
    echo "link a previous local libgit2/SwiftGitX build once before running this harness" >&2
    exit 2
  fi
done

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

MAIN="${1:?main swift file}"
NAME="${2:?output name}"
shift 2

FLOECORE_SOURCES=()
for f in "$ROOT"/FloeAgent/Sources/FloeCore/*.swift; do
  case "$(basename "$f")" in
    Digest.swift) continue ;; # imports swift-crypto; unused by this harness
  esac
  FLOECORE_SOURCES+=("$f")
done

SWIFTGITX_SOURCES=()
while IFS= read -r f; do SWIFTGITX_SOURCES+=("$f"); done < <(find "$SWIFTGITX_SRC" -name '*.swift' | sort)

mkdir -p "$WORK" "$STAGE"

COMMON=(
  -swift-version 6
  -enable-experimental-feature StrictConcurrency
  -module-cache-path "$ROOT/FloeAgent/.build/out/Intermediates.noindex/ModuleCache"
  -Xcc -fmodule-map-file="$MODULEMAP"
  -Xcc -I -Xcc "$LIBGIT2_INCLUDE"
  -target arm64-apple-macosx15.0
  -sdk "$SDK"
)

if [ ! -f "$STAGE/FloeCore.swiftmodule" ]; then
  echo "== building FloeCore review module"
  xcrun swiftc "${COMMON[@]}" -parse-as-library \
    -module-name FloeCore \
    -emit-module -emit-module-path "$STAGE/FloeCore.swiftmodule" \
    -emit-library -static -o "$STAGE/libFloeCoreReview.a" \
    "${FLOECORE_SOURCES[@]}"
fi

if [ ! -f "$STAGE/SwiftGitX.swiftmodule" ]; then
  echo "== building SwiftGitX review module"
  xcrun swiftc "${COMMON[@]}" -parse-as-library \
    -module-name SwiftGitX \
    -emit-module -emit-module-path "$STAGE/SwiftGitX.swiftmodule" \
    -emit-library -static -o "$STAGE/libSwiftGitXReview.a" \
    "${SWIFTGITX_SOURCES[@]}"
fi

echo "== building harness $NAME"
xcrun swiftc "${COMMON[@]}" \
  -I "$STAGE" \
  -o "$WORK/$NAME" \
  "$MAIN" \
  "$@" \
  "$ROOT/FloeAgent/Sources/FloeGit/GitModels.swift" \
  "$ROOT/FloeAgent/Sources/FloeGit/LocalGitService.swift" \
  "$STAGE/libFloeCoreReview.a" \
  "$STAGE/libSwiftGitXReview.a" \
  "$BUILD/libgit2.o" \
  -lz -liconv

echo "== running $NAME"
"$WORK/$NAME"
