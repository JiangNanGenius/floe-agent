#!/usr/bin/env bash
set -euo pipefail

readonly COLLABORA_COMMIT="673f94ffc1ed291e9245ee0cbdea4f685a73c56e"
readonly MIN_FREE_GIB=150
readonly DEFAULT_BUILD_ROOT="/Volumes/TECLAST/FloeAgent-M0/Collabora"

mode="${1:---check}"
build_root="${FLOE_COLLABORA_ROOT:-$DEFAULT_BUILD_ROOT}"

probe_path="$build_root"
while [[ ! -e "$probe_path" ]]; do
  parent_path=$(dirname "$probe_path")
  if [[ "$parent_path" == "$probe_path" ]]; then
    printf 'Collabora gate failed: cannot resolve filesystem for %s\n' "$build_root" >&2
    exit 2
  fi
  probe_path="$parent_path"
done

free_kib=$(df -Pk "$probe_path" | awk 'NR==2 {print $4}')
required_kib=$((MIN_FREE_GIB * 1024 * 1024))
if (( free_kib < required_kib )); then
  printf 'Collabora gate failed: %s GiB free; %s GiB required on %s\n' \
    "$((free_kib / 1024 / 1024))" "$MIN_FREE_GIB" "$(dirname "$build_root")" >&2
  exit 2
fi

required_tools=(git make autoconf automake pkg-config)
for tool in "${required_tools[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Collabora gate failed: missing tool %s\n' "$tool" >&2
    exit 3
  fi
done

if [[ ! -d /Applications/Xcode-beta.app ]]; then
  printf 'Collabora gate failed: /Applications/Xcode-beta.app is missing\n' >&2
  exit 4
fi

printf 'Collabora prerequisites pass. Commit: %s\n' "$COLLABORA_COMMIT"
[[ "$mode" == "--check" ]] && exit 0

source_dir="$build_root/source"
mkdir -p "$build_root"
if [[ ! -d "$source_dir/.git" ]]; then
  git clone https://gerrit.collaboraoffice.com/online "$source_dir"
fi
git -C "$source_dir" fetch --tags origin
git -C "$source_dir" checkout --detach "$COLLABORA_COMMIT"
[[ "$mode" == "--fetch" ]] && exit 0

if [[ "$mode" != "--build" ]]; then
  printf 'Usage: %s [--check|--fetch|--build]\n' "$0" >&2
  exit 64
fi

engine_dir="$source_dir/engine"
pushd "$engine_dir" >/dev/null
printf '%s\n' \
  '--enable-werror' \
  '--enable-symbols' \
  '--with-myspell-dicts' \
  '--with-distro=CPiOS' \
  '--with-lang=en-US zh-CN zh-TW' > autogen.input
./autogen.sh
make -j2
popd >/dev/null

pushd "$source_dir" >/dev/null
./autogen.sh
./configure \
  --enable-iosapp \
  --with-iosapp-name='Floe Office M0' \
  --with-ios-bundle-identifier-prefix=org.floeagent \
  --with-lo-builddir="$engine_dir"
make -C browser -j2
popd >/dev/null

printf 'Collabora build prepared at %s. Open ios/Mobile/Mobile.xcodeproj for signed device deployment.\n' "$source_dir"
