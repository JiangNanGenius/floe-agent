#!/bin/bash
# Bundle pinned CPython 3.13 iOS binary wheels (BeeWare numpy/Pillow and Floe
# pandas) into the app: pure-Python trees go to the bundled site-packages,
# every .so becomes a separately embedded XCFramework with .fwork markers,
# exactly like the standard-library extensions (package_python_extensions.sh).
# Runtime download of native code stays impossible; this list is fixed at
# build time and every input is SHA-256 pinned.
set -euo pipefail

cd "$(dirname "$0")/.."

site_packages="FloeApp/Resources/python/lib/python3.13/site-packages"
output_root="Vendor/PythonExtensions"
cache_root="${TMPDIR:-/tmp}/floe-python-binary-packages"
mkdir -p "$cache_root" "$site_packages" "$output_root"

# package|version|device_wheel_sha256|simulator_wheel_sha256
packages=(
    "numpy|2.5.2.post1|d451e3281b8e2709bb85c6857c83b3c1797f930971b6bbff7f57469d3958e16e|154285250704dd82f8a5b53633eebe381f6eb56d232780291ac180e12a7ea0b1"
    "Pillow|11.0.0|42543f517e0f888102db194ae34e903786c82bbb062854e7694d227a2044b984|6c7d4fbfb2a3b7b823f8cb8a5af5d91570d597a4385ea11ad0e29ea316e197ff"
    "pandas|3.0.5|99ac5c6c541a0e24b0b6637e9405e9ae682ea4b188316a090d643edd6bedd92d|d0a9dc857c9d9d38e78d305a3385f51dc04366daf15fda2f17a3a0927d55bd67"
)

download_wheel() {
    local package="$1" version="$2" arch="$3" expected="$4"
    local name
    name="$(python3 -c "print('$package'.lower())")"
    local file="$cache_root/$package-$version-$arch.whl"
    if [ ! -f "$file" ]; then
        local url="https://api.anaconda.org/download/beeware/$package/$version/$name-$version-cp313-cp313-ios_13_0_arm64_$arch.whl"
        if [ "$package" = pandas ]; then
            url="https://github.com/JiangNanGenius/floe-agent/releases/download/runtime-pandas-3.0.5-cp313/pandas-3.0.5-cp313-cp313-ios_17_0_arm64_$arch.whl"
        fi
        curl --fail --location --retry 3 --output "$file" \
            "$url"
    fi
    local actual
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        echo "error: $package $arch wheel SHA256 mismatch" >&2
        exit 1
    fi
    printf '%s' "$file"
}

make_framework() {
    local module="$1" source="$2" destination="$3" supported_platform="$4" minimum_os="$5"
    local identifier_module="${module#_}"
    identifier_module="${identifier_module//_/-}"
    mkdir -p "$destination"
    cp "$source" "$destination/$module"
    install_name_tool -id "@rpath/$module.framework/$module" "$destination/$module"
    /usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string en" "$destination/Info.plist" >/dev/null
    /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $module" "$destination/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string org.python.extension.$identifier_module" "$destination/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$destination/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleName string $module" "$destination/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string FMWK" "$destination/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 3.13" "$destination/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms array" "$destination/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms:0 string $supported_platform" "$destination/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 3.13" "$destination/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string $minimum_os" "$destination/Info.plist"
}

project_yml_entries=()

for spec in "${packages[@]}"; do
    IFS='|' read -r package version device_sha sim_sha <<< "$spec"
    device_wheel="$(download_wheel "$package" "$version" "iphoneos" "$device_sha")"
    sim_wheel="$(download_wheel "$package" "$version" "iphonesimulator" "$sim_sha")"

    stage="$cache_root/stage-$package"
    rm -rf "$stage"
    mkdir -p "$stage/device" "$stage/simulator"
    python3 -m zipfile -e "$device_wheel" "$stage/device"
    python3 -m zipfile -e "$sim_wheel" "$stage/simulator"

    # Pure-Python tree into the bundled site-packages (read-only, signed with
    # the app). Native payloads are converted to frameworks below instead of
    # being shipped as unsigned .so files.
    rsync -a \
        --exclude '__pycache__/' \
        --exclude '*.pyc' \
        --exclude '*.so' \
        --exclude '*.a' \
        "$stage/device/" "$site_packages/"

    # Every native module becomes one XCFramework plus .fwork markers at the
    # module's original in-package location (device + simulator spellings).
    while IFS= read -r so_rel; do
        module="$(basename "$so_rel" .cpython-313-iphoneos.so)"
        package_dir="$(dirname "$so_rel")"
        sim_so="$stage/simulator/$package_dir/$module.cpython-313-iphonesimulator.so"
        if [ ! -f "$sim_so" ]; then
            echo "error: simulator counterpart missing for $module ($package)" >&2
            exit 1
        fi
        framework_module="$module"
        minimum_os=13.0
        if [ "$package" = pandas ]; then
            framework_module="${package_dir//\//_}_$module"
            minimum_os=17.0
        fi
        work_dir="$output_root/.work-binpkg-$framework_module"
        rm -rf "$work_dir"
        make_framework "$framework_module" "$stage/device/$so_rel" "$work_dir/device/$framework_module.framework" "iPhoneOS" "$minimum_os"
        make_framework "$framework_module" "$sim_so" "$work_dir/simulator/$framework_module.framework" "iPhoneSimulator" "$minimum_os"
        printf 'python/lib/python3.13/site-packages/%s/%s.cpython-313-iphoneos.fwork' "$package_dir" "$module" > "$work_dir/device/$framework_module.framework/$framework_module.origin"
        printf 'python/lib/python3.13/site-packages/%s/%s.cpython-313-iphonesimulator.fwork' "$package_dir" "$module" > "$work_dir/simulator/$framework_module.framework/$framework_module.origin"
        # Generated targets are owned by this fixed, SHA-pinned package list.
        if [ -d "$output_root/$framework_module.xcframework" ]; then
            rm -rf "$output_root/$framework_module.xcframework"
        fi
        xcodebuild -create-xcframework \
            -framework "$work_dir/device/$framework_module.framework" \
            -framework "$work_dir/simulator/$framework_module.framework" \
            -output "$output_root/$framework_module.xcframework" >/dev/null
        rm -rf "$work_dir"
        printf 'Frameworks/%s.framework/%s' "$framework_module" "$framework_module" \
            > "$site_packages/$package_dir/$module.cpython-313-iphoneos.fwork"
        printf 'Frameworks/%s.framework/%s' "$framework_module" "$framework_module" \
            > "$site_packages/$package_dir/$module.cpython-313-iphonesimulator.fwork"
        project_yml_entries+=("$framework_module")
    done < <(cd "$stage/device" && find . -name "*.cpython-313-iphoneos.so" | sed 's|^\./||' | sort)
done

python3 scripts/install_pandas_pure_dependencies.py

# Keep project.yml's embed list in sync with the packaged frameworks. The
# block between the markers is regenerated on every run, so CI and local
# builds embed exactly the same binary packages.
python3 - "${project_yml_entries[@]}" <<'EOF'
import sys
path = "project.yml"
begin = "        # BEGIN embedded Python binary packages (generated)"
end = "        # END embedded Python binary packages"
lines = open(path).read().splitlines(keepends=False)
out = []
inside = False
emitted = False
for line in lines:
    if line.strip() == begin.strip():
        inside = True
        out.append(begin)
        for module in sys.argv[1:]:
            out.append(f"      - framework: Vendor/PythonExtensions/{module}.xcframework")
            out.append("        embed: true")
        out.append(end)
        emitted = True
        continue
    if line.strip() == end.strip():
        inside = False
        continue
    if not inside:
        out.append(line)
if not emitted:
    # Insert after the last PythonExtensions embed entry.
    index = max(i for i, line in enumerate(out) if "Vendor/PythonExtensions/" in line)
    block = [begin]
    for module in sys.argv[1:]:
        block.append(f"      - framework: Vendor/PythonExtensions/{module}.xcframework")
        block.append("        embed: true")
    block.append(end)
    out[index + 1:index + 1] = block
open(path, "w").write("\n".join(out) + "\n")
EOF

rm -rf "$cache_root/stage-"*
echo "Bundled ${#packages[@]} binary Python packages (${#project_yml_entries[@]} extension frameworks) into site-packages and Vendor/PythonExtensions"
