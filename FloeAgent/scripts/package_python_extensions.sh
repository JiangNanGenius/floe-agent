#!/bin/bash
# Convert the pinned CPython iOS standard-library extension modules into
# App-Store-compatible XCFrameworks and matching `.fwork` placeholders.
set -euo pipefail

cd "$(dirname "$0")/.."

python_root="Vendor/Python.xcframework"
device_dynload="$python_root/ios-arm64/lib/python3.13/lib-dynload"
sim_dynload="$python_root/ios-arm64_x86_64-simulator/lib/python3.13/lib-dynload"
stdlib_dynload="FloeApp/Resources/python/lib/python3.13/lib-dynload"
output_root="Vendor/PythonExtensions"

# These cover the standard modules used by pip/package inspection, archives,
# HTTPS, data processing and ordinary model-authored scripts. Third-party
# binary wheels are still rejected; this list is fixed at build time.
modules=(
    _blake2 _csv _datetime _decimal _hashlib _json _random _sha2 _sha3
    _socket _ssl _statistics _struct array binascii math select unicodedata zlib
)

rm -rf "$output_root"
mkdir -p "$output_root" "$stdlib_dynload"

make_framework() {
    local module="$1"
    local source="$2"
    local destination="$3"
    local origin="$4"
    local identifier_module="${module//_/-}"
    mkdir -p "$destination"
    cp "$source" "$destination/$module"
    install_name_tool -id "@rpath/$module.framework/$module" "$destination/$module"
    /usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string en" "$destination/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $module" "$destination/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string org.python.extension.$identifier_module" "$destination/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$destination/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleName string $module" "$destination/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string FMWK" "$destination/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 3.13" "$destination/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 3.13" "$destination/Info.plist"
    printf '%s' "$origin" > "$destination/$module.origin"
}

for module in "${modules[@]}"; do
    device_source="$(find "$device_dynload" -maxdepth 1 -name "$module.cpython-313-iphoneos.so" -print -quit)"
    sim_source="$(find "$sim_dynload" -maxdepth 1 -name "$module.cpython-313-iphonesimulator.so" -print -quit)"
    if [ -z "$device_source" ] || [ -z "$sim_source" ]; then
        echo "error: missing pinned CPython extension for $module" >&2
        exit 1
    fi

    work_dir="$output_root/.work-$module"
    device_framework="$work_dir/device/$module.framework"
    sim_framework="$work_dir/simulator/$module.framework"
    device_marker="$module.cpython-313-iphoneos.fwork"
    sim_marker="$module.cpython-313-iphonesimulator.fwork"
    make_framework "$module" "$device_source" "$device_framework" \
        "python/lib/python3.13/lib-dynload/$device_marker"
    make_framework "$module" "$sim_source" "$sim_framework" \
        "python/lib/python3.13/lib-dynload/$sim_marker"

    xcodebuild -create-xcframework \
        -framework "$device_framework" \
        -framework "$sim_framework" \
        -output "$output_root/$module.xcframework" >/dev/null
    printf 'Frameworks/%s.framework/%s' "$module" "$module" > "$stdlib_dynload/$device_marker"
    printf 'Frameworks/%s.framework/%s' "$module" "$module" > "$stdlib_dynload/$sim_marker"
    rm -rf "$work_dir"
done

echo "Packaged ${#modules[@]} signed-at-build CPython extension frameworks"
