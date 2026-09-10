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

# package|version|device_wheel_sha256|simulator_wheel_sha256|url_template|minimum_ios|flatten_subdir_modules
# url_template placeholders: {name} {name_lower} {version} {arch}
# New packages land via ios-wheelhouse (build_ios_wheel.sh → reviewed GitHub
# Release tag runtime-<pkg>-<version>-cp313), then receive their pin here.
packages=(
    "numpy|2.5.2.post1|d451e3281b8e2709bb85c6857c83b3c1797f930971b6bbff7f57469d3958e16e|154285250704dd82f8a5b53633eebe381f6eb56d232780291ac180e12a7ea0b1|https://api.anaconda.org/download/beeware/{name}/{version}/{name_lower}-{version}-cp313-cp313-ios_13_0_arm64_{arch}.whl|13.0|0"
    "Pillow|11.0.0|42543f517e0f888102db194ae34e903786c82bbb062854e7694d227a2044b984|6c7d4fbfb2a3b7b823f8cb8a5af5d91570d597a4385ea11ad0e29ea316e197ff|https://api.anaconda.org/download/beeware/{name}/{version}/{name_lower}-{version}-cp313-cp313-ios_13_0_arm64_{arch}.whl|13.0|0"
    "pandas|3.0.5|99ac5c6c541a0e24b0b6637e9405e9ae682ea4b188316a090d643edd6bedd92d|d0a9dc857c9d9d38e78d305a3385f51dc04366daf15fda2f17a3a0927d55bd67|https://github.com/JiangNanGenius/floe-agent/releases/download/runtime-pandas-{version}-cp313/{name_lower}-{version}-cp313-cp313-ios_17_0_arm64_{arch}.whl|17.0|1"
    # regex: native _regex extension inside the package dir → flatten=1.
    "regex|2026.9.10|dea63d24c095ff955569565dd374526415e92ba2d8ad16c9d2023268eae580dd|78a931572c1e8fb96d75cbc9cdc6523b7ea30ff69f208eab6b00403910b01331|https://github.com/JiangNanGenius/floe-agent/releases/download/runtime-regex-{version}-cp313/{name_lower}-{version}-cp313-cp313-ios_13_0_arm64_{arch}.whl|17.0|1"
    # Pure wheels: one file serves both slices (same sha twice, no {arch}).
    "pyyaml|6.0.3|425edf1bc97f0adf1c4575191d6b7df7bbd929ac8b57e5a871a964938a2e6bdd|425edf1bc97f0adf1c4575191d6b7df7bbd929ac8b57e5a871a964938a2e6bdd|https://github.com/JiangNanGenius/floe-agent/releases/download/runtime-pyyaml-{version}-cp313/{name_lower}-{version}-py3-none-any.whl|13.0|0"
    # markupsafe: upstream setup degraded to pure (no C speedups on iOS yet).
    "markupsafe|3.0.3|796bcf8359c369e44d5ced5db1a26a1cf2aca2bcf8929cd0fe4cffac73c98cf0|796bcf8359c369e44d5ced5db1a26a1cf2aca2bcf8929cd0fe4cffac73c98cf0|https://github.com/JiangNanGenius/floe-agent/releases/download/runtime-markupsafe-{version}-cp313/{name_lower}-{version}-py3-none-any.whl|13.0|0"
)

wheel_url() {
    local package="$1" version="$2" arch="$3"
    local spec p v d s template min_os flatten name_lower
    for spec in "${packages[@]}"; do
        IFS='|' read -r p v d s template min_os flatten <<< "$spec"
        if [ "$p" = "$package" ]; then
            name_lower="$(python3 -c "print('$package'.lower())")"
            template="${template//\{name\}/$package}"
            template="${template//\{name_lower\}/$name_lower}"
            template="${template//\{version\}/$version}"
            template="${template//\{arch\}/$arch}"
            printf '%s' "$template"
            return 0
        fi
    done
    echo "error: no wheel pin registered for $package" >&2
    return 1
}

download_wheel() {
    local package="$1" version="$2" arch="$3" expected="$4"
    local file="$cache_root/$package-$version-$arch.whl"
    if [ ! -f "$file" ]; then
        local url
        url="$(wheel_url "$package" "$version" "$arch")" || return 1
        local partial
        partial="$(mktemp "$file.partial.XXXXXX")" || return 1
        # This function runs inside command substitution, where Bash does not
        # reliably propagate errexit. Handle transfer failure explicitly and
        # never publish a partial wheel as a reusable cache entry.
        if ! curl --fail --location --retry 5 --retry-all-errors \
            --connect-timeout 30 --max-time 300 --retry-max-time 900 \
            --output "$partial" "$url"; then
            rm -f "$partial"
            echo "error: $package $arch wheel download failed" >&2
            return 1
        fi
        local downloaded
        downloaded="$(shasum -a 256 "$partial" | awk '{print $1}')" || { rm -f "$partial"; return 1; }
        if [ "$downloaded" != "$expected" ]; then
            rm -f "$partial"
            echo "error: $package $arch downloaded wheel SHA256 mismatch" >&2
            return 1
        fi
        mv "$partial" "$file" || { rm -f "$partial"; return 1; }
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
    IFS='|' read -r package version device_sha sim_sha url_template package_min_ios flatten_subdirs <<< "$spec"
    device_wheel="$(download_wheel "$package" "$version" "iphoneos" "$device_sha")"
    # Pure-Python py3-none-any wheels carry one file for both slices.
    if [ "$device_sha" = "$sim_sha" ] && [ "${url_template/\{arch\}/}" = "$url_template" ]; then
        sim_wheel="$device_wheel"
    else
        sim_wheel="$(download_wheel "$package" "$version" "iphonesimulator" "$sim_sha")"
    fi

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
        minimum_os="$package_min_ios"
        if [ "$flatten_subdirs" = "1" ] && [ "$package_dir" != "." ]; then
            framework_module="${package_dir//\//_}_$module"
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
modules = sorted(set(sys.argv[1:]))  # Locale-independent on every CI host.
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
        for module in modules:
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
    for module in modules:
        block.append(f"      - framework: Vendor/PythonExtensions/{module}.xcframework")
        block.append("        embed: true")
    block.append(end)
    out[index + 1:index + 1] = block
open(path, "w").write("\n".join(out) + "\n")
EOF

rm -rf "$cache_root/stage-"*
echo "Bundled ${#packages[@]} binary Python packages (${#project_yml_entries[@]} extension frameworks) into site-packages and Vendor/PythonExtensions"
