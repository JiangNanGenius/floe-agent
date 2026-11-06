// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCAD

/// Reviewed scripts run ONLY through the task's frozen exec.shell binding.
/// No native host interpreter, extra execution alias, cloud account or GPU is used.
enum CADOfflineRenderCommands {
    static let revision = CADPBRTSceneExporter.backendRevision
    static func payload(script: String, directory: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["script": script, "cwd": directory, "maxOutputBytes": 65536], options: .sortedKeys)
    }
    static let common = #"""
    set -eu
    umask 077
    floe_render_revision='b0bdf461ba5dd6504b70ebf0932acc0fe7aa744f'
    floe_render_root="${XDG_CACHE_HOME:-$HOME/.cache}/floe/renderers/pbrt-v4-$floe_render_revision"
    floe_render_binary="$floe_render_root/bin/pbrt"
    floe_render_hash() {
      if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1
      else shasum -a 256 "$1" | cut -d ' ' -f 1; fi
    }
    """#
    static let install = common + "\n" + #"""
    if [ -x "$floe_render_binary" ] && [ -f "$floe_render_root/binary.sha256" ] &&
       [ "$(floe_render_hash "$floe_render_binary")" = "$(cat "$floe_render_root/binary.sha256")" ]; then
      printf '{"backend":"pbrt-v4","revision":"%s","binarySHA256":"%s"}\n' "$floe_render_revision" "$(floe_render_hash "$floe_render_binary")" > backend.json
      exit 0
    fi
    mkdir -p "$floe_render_root"
    # Kernel leases release on process death, including a terminated guest.
    # Keep the lock inode so a queued installer cannot lock a replacement file.
    test ! -L "$floe_render_root/install.lease"
    if command -v flock >/dev/null 2>&1; then
      exec 9>>"$floe_render_root/install.lease"
      flock -n 9 || { echo 'This environment is already installing pbrt.' >&2; exit 73; }
    elif command -v lockf >/dev/null 2>&1; then
      if [ "${1:-}" != --floe-install-locked ]; then
        exec lockf -k -t 0 "$floe_render_root/install.lease" /bin/sh "$0" --floe-install-locked
      fi
    else
      echo 'Install the util-linux flock command in this environment before preparing pbrt.' >&2
      exit 69
    fi
    trap 'exit 130' HUP INT TERM
    # Debian-based guests can install their own build prerequisites. Other
    # selected machines use their already installed C++/CMake toolchain.
    if [ "$(uname -s)" = Linux ] && command -v apt-get >/dev/null 2>&1; then
      if [ "$(id -u)" = 0 ]; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates git cmake build-essential libgl1-mesa-dev
      elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo -n apt-get update
        sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates git cmake build-essential libgl1-mesa-dev
      fi
    fi
    for floe_render_tool in git cmake c++; do
      if ! command -v "$floe_render_tool" >/dev/null 2>&1; then
        echo "The selected environment needs $floe_render_tool. Install its C++ build tools or choose another execution environment." >&2
        exit 69
      fi
    done
    floe_render_work="$floe_render_root/build-source"
    if [ ! -d "$floe_render_work/.git" ]; then
      git clone --filter=blob:none --no-checkout https://github.com/mmp/pbrt-v4.git "$floe_render_work"
    fi
    git -C "$floe_render_work" fetch --depth 1 origin "$floe_render_revision"
    git -C "$floe_render_work" checkout --detach "$floe_render_revision"
    test "$(git -C "$floe_render_work" rev-parse HEAD)" = "$floe_render_revision"
    git -C "$floe_render_work" submodule update --init --recursive --depth 1
    # Floe local resource patch only: the upstream table generator otherwise
    # starts one worker per host CPU, independently of CMake's job budget.
    sed 's/int nThreads = AvailableCores();/int nThreads = std::min(2, AvailableCores());/' \
      "$floe_render_work/src/pbrt/cmd/rgb2spec_opt.cpp" > "$floe_render_work/src/pbrt/cmd/rgb2spec_opt.cpp.pending"
    mv "$floe_render_work/src/pbrt/cmd/rgb2spec_opt.cpp.pending" "$floe_render_work/src/pbrt/cmd/rgb2spec_opt.cpp"
    cmake -S "$floe_render_work" -B "$floe_render_work/build" \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_COMPILER=NOTFOUND \
      -DPBRT_BUILD_NATIVE_EXECUTABLE=OFF -DPBRT_USE_PREGENERATED_RGB_TO_SPECTRUM_TABLES=OFF \
      -DCMAKE_DISABLE_FIND_PACKAGE_OpenEXR=TRUE -DOPENEXR_FORCE_INTERNAL_IMATH=ON \
      -DGLFW_BUILD_X11=OFF -DGLFW_BUILD_WAYLAND=OFF
    test "$(git -C "$floe_render_work/build/_deps/imath-src" rev-parse HEAD)" = c0396a055a01bc537d32f435aee11a9b7ed6f0b5
    cmake --build "$floe_render_work/build" --target pbrt_exe --parallel 2
    mkdir -p "$floe_render_root/bin" "$floe_render_root/licenses"
    cp "$floe_render_work/build/pbrt" "$floe_render_root/bin/pbrt.pending"
    chmod 700 "$floe_render_root/bin/pbrt.pending"
    "$floe_render_root/bin/pbrt.pending" --help >/dev/null
    cp "$floe_render_work/LICENSE.txt" "$floe_render_root/licenses/LICENSE.txt"
    cp "$floe_render_work/THIRD_PARTY.md" "$floe_render_root/licenses/THIRD_PARTY.md"
    # Retain every bundled dependency's licence beside the locally built binary.
    find "$floe_render_work" -type f \( -iname '*license*' -o -iname '*copying*' -o -iname '*notice*' \) -exec sh -c '
      floe_render_notice_source=$1
      floe_render_notice_target=$2
      shift 2
      for floe_render_notice do
        floe_render_relative=${floe_render_notice#"$floe_render_notice_source"/}
        mkdir -p "$floe_render_notice_target/$(dirname "$floe_render_relative")"
        cp "$floe_render_notice" "$floe_render_notice_target/$floe_render_relative"
      done
    ' sh "$floe_render_work" "$floe_render_root/licenses/dependencies" {} +
    printf '%s\n' 'Floe local modification: rgb2spec_opt.cpp limits table generation to two threads. Rendering algorithms are unchanged.' > "$floe_render_root/licenses/FLOE-LOCAL-CHANGES.txt"
    mv "$floe_render_root/bin/pbrt.pending" "$floe_render_binary"
    floe_render_hash "$floe_render_binary" > "$floe_render_root/binary.sha256"
    printf '{"backend":"pbrt-v4","revision":"%s","binarySHA256":"%s"}\n' "$floe_render_revision" "$(floe_render_hash "$floe_render_binary")" > backend.json
    # Confirmed regenerable sources/objects only, after exporting binary and notices.
    rm -rf "$floe_render_work"
    """#
    static let render = common + "\n" + #"""
    test -x "$floe_render_binary"
    test -f "$floe_render_root/binary.sha256"
    test "$(floe_render_hash "$floe_render_binary")" = "$(cat "$floe_render_root/binary.sha256")"
    test -s scene.pbrt
    # Every operation has a new directory. Never accept a stale output or an
    # interrupted partial render as a completed image.
    test ! -e render.png
    "$floe_render_binary" --nthreads 2 --outfile render.png scene.pbrt
    test -s render.png
    printf '{"backend":"pbrt-v4","revision":"%s","sceneSHA256":"%s","imageSHA256":"%s"}\n' \
      "$floe_render_revision" "$(floe_render_hash scene.pbrt)" "$(floe_render_hash render.png)" > result.json
    """#
}
