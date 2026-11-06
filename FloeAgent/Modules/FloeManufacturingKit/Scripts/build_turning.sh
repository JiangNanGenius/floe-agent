#!/bin/bash
# GPL-2.0 LibLathe research component. SwiftPM uses its source target; this
# optional XCFramework is the standalone static-library handoff of that source.
set -euo pipefail
package_root="$(cd "$(dirname "$0")/.." && pwd)"
turning_root="$package_root/Sources/TurningNative"
checkout_id="$(printf '%s' "$package_root" | shasum -a 256 | cut -c 1-12)"
task_cache="${MANUFACTURING_TURNING_CACHE:-$HOME/Library/Caches/CodexBuild/FloeManufacturing/$checkout_id/turning-static}"
task_output="${MANUFACTURING_TURNING_OUTPUT:-$package_root/Vendor/TurningNative.xcframework}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$task_cache" "$(dirname "$task_output")"
sources=(
  "$turning_root/Vendor/liblathe/base/point.cpp"
  "$turning_root/Vendor/liblathe/base/segment.cpp"
  "$turning_root/Vendor/liblathe/base/boundbox.cpp"
  "$turning_root/Vendor/liblathe/base/segmentgroup.cpp"
  "$turning_root/Vendor/liblathe/base/quadtree.cpp"
  "$turning_root/src/turn_tool.cpp"
  "$turning_root/src/turn_ops.cpp"
  "$turning_root/src/turn_plan.cpp"
)
slices=()
for spec in 'iphoneos arm64-apple-ios26.0 ios-arm64' 'iphonesimulator arm64-apple-ios26.0-simulator ios-arm64-simulator' 'macosx arm64-apple-macos15.0 macos-arm64'; do
  read -r sdk triple name <<< "$spec"
  slice="$task_cache/$name"
  mkdir -p "$slice/Headers" "$slice/objects"
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  objects=()
  for source_file in "${sources[@]}"; do
    object="$slice/objects/$(basename "${source_file%.cpp}").o"
    xcrun --sdk "$sdk" clang++ -target "$triple" -isysroot "$sdk_path" \
      -std=c++17 -O2 -I"$turning_root/include" -I"$turning_root/Vendor" \
      -c "$source_file" -o "$object"
    objects+=("$object")
  done
  xcrun libtool -static -o "$slice/libTurningNative.a" "${objects[@]}"
  cp "$turning_root/include/TurningNative.h" "$slice/Headers/"
  printf 'module TurningNative { header "TurningNative.h" export * }\n' > "$slice/Headers/module.modulemap"
  xcrun nm -gU "$slice/libTurningNative.a" | awk '/_fm_turn_plan$|_fm_turn_free$/ { print }'
  slices+=(-library "$slice/libTurningNative.a" -headers "$slice/Headers")
done
new_output="$task_cache/TurningNative.new.xcframework"
previous_output="${task_output}.previous"
if [ -e "$previous_output" ]; then printf 'Preserve existing rollback: %s\n' "$previous_output" >&2; exit 1; fi
rm -rf "$new_output"
xcodebuild -create-xcframework "${slices[@]}" -output "$new_output"
cp "$turning_root/Vendor/liblathe/LICENSE" "$new_output/LICENSE-LibLathe-GPL-2.0.txt"
if [ -e "$task_output" ]; then mv "$task_output" "$previous_output"; fi
if mv "$new_output" "$task_output"; then
  rm -rf "$previous_output"
else
  if [ -e "$previous_output" ]; then mv "$previous_output" "$task_output"; fi
  exit 1
fi
find "$task_output" -name '*.a' -exec shasum -a 256 {} +
