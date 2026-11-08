#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/Library/Caches/CodexBuild/FloeHeavyEditors/shared-main/xcode-27B52/font-native}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-6}"
export IPHONEOS_DEPLOYMENT_TARGET=26.0
export MACOSX_DEPLOYMENT_TARGET=15.0
# Keep the producer's configured thin LTO and recoverable raw static archive.
# Packaging removes redundant embedded LLVM IR from copies only. Native code,
# platform commands, non-STAB symbols and DWARF are verified unchanged.
task_cargo="${FLOE_CARGO:-$HOME/.cargo/bin/cargo}"
task_target="${1:-all}"
case "$task_target" in
  all) task_targets=(aarch64-apple-darwin aarch64-apple-ios-sim aarch64-apple-ios) ;;
  aarch64-apple-darwin|aarch64-apple-ios-sim|aarch64-apple-ios) task_targets=("$task_target") ;;
  package) task_targets=() ;;
  *) exit 2 ;;
esac
for task_slice in "${task_targets[@]}"; do
  "$task_cargo" build --manifest-path "$task_root/NativeRust/Cargo.toml" --release --locked --target "$task_slice"
done
if [ "$task_target" != all ] && [ "$task_target" != package ]; then exit 0; fi
task_staging="$CARGO_TARGET_DIR/framework-staging"
task_output="$task_root/Vendor/FloeFontCompiler.xcframework"
mkdir -p "$task_staging" "$task_root/Vendor"
task_arguments=()
for task_spec in 'aarch64-apple-darwin macos-arm64' 'aarch64-apple-ios-sim ios-arm64-simulator' 'aarch64-apple-ios ios-arm64'; do
  task_slice="${task_spec%% *}"
  task_name="${task_spec##* }"
  task_library="$task_staging/$task_name/libFloeFontCompiler.a"
  task_headers="$task_staging/$task_name/include"
  task_module_headers="$task_headers/FloeFontCompiler"
  mkdir -p "$task_module_headers"
  cp "$task_root/NativeRust/include/FloeFontCompiler.h" "$task_module_headers/"
  printf 'module FloeFontCompiler { header "FloeFontCompiler.h" export * }\n' > "$task_module_headers/module.modulemap"
  python3 "$task_root/Scripts/normalize_archive.py" \
    "$CARGO_TARGET_DIR/$task_slice/release/libFloeFontCompiler.a" \
    "$task_library" \
    "$task_staging/$task_name-normalization.json"
  # Use a real static-library XCFramework. A static ar archive disguised as a
  # framework can be incorrectly copied into the consumer app's Frameworks.
  task_arguments+=(-library "$task_library" -headers "$task_headers")
done
task_candidate="$CARGO_TARGET_DIR/FloeFontCompiler.candidate.xcframework"
if [ -e "$task_candidate" ]; then echo 'Preserve existing candidate before packaging' >&2; exit 1; fi
xcodebuild -create-xcframework "${task_arguments[@]}" -output "$task_candidate"
python3 - "$task_staging" "$task_candidate/normalization-manifest.json" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
json.dump({path.name.removesuffix('-normalization.json'):json.loads(path.read_text())
           for path in sorted(root.glob('*-normalization.json'))},open(sys.argv[2],'w'),indent=2)
PY
# ProcessXCFramework copies a static library's header root into the consumer's
# shared include directory. Keep the module map under FloeFontCompiler/ so it
# cannot collide with another static XCFramework's include/module.modulemap.
python3 "$task_root/Scripts/namespace_xcframework_headers.py" "$task_candidate"
if [ -e "$task_output" ]; then echo 'Preserve existing packaged compiler before replacement' >&2; exit 1; fi
mv "$task_candidate" "$task_output"
