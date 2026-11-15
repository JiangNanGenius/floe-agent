#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
#
# Behavioral checks for the guest acceleration dispatcher. Run inside a
# disposable Linux environment (root is required only for the fake device-node
# check; without it that check is skipped). It uses fake tools and fake nodes,
# never a real GPU, package install, display server or network.
#
#   sh acceleration_guest_checks.sh [floe-accel path]
#
# Exit 0 prints ACCELERATION_GUEST_CHECKS_OK. Non-Linux hosts exit 2.

set -u
[ "$(uname -s)" = Linux ] || { echo "acceleration_guest_checks: Linux guest required" >&2; exit 2; }

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DISPATCHER=${1:-"$HERE/../../LinuxGuest/acceleration/floe-accel"}
[ -f "$DISPATCHER" ] || { echo "missing dispatcher: $DISPATCHER" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/floe-accel-check.XXXXXX") || exit 2
FAKE="$WORK/bin"
mkdir -p "$FAKE"
CREATED_DRI=0
CREATED_RENDER=""
CREATED_VIDEO=""
cleanup() {
    [ -n "$CREATED_RENDER" ] && rm -f "$CREATED_RENDER"
    [ -n "$CREATED_VIDEO" ] && rm -f "$CREATED_VIDEO"
    [ "$CREATED_DRI" -eq 1 ] && rmdir /dev/dri 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM

cat >"$FAKE/vulkaninfo" <<'EOF'
#!/bin/sh
# The App/runner presets DISPLAY=:0 even without a screen. Pure Vulkan
# enumeration must clear it before vulkaninfo tries an XCB WSI path.
if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    echo "vulkaninfo inherited a display environment" >&2
    exit 1
fi
echo "Vulkan Instance Version: 1.4.309"
EOF
cat >"$FAKE/glxinfo" <<'EOF'
#!/bin/sh
echo "OpenGL renderer string: fake glx"
EOF
cat >"$FAKE/floe-gl-probe" <<'EOF'
#!/bin/sh
case "${1:-}" in
    glx)
        if [ "${DISPLAY:-}" = ":9876" ]; then
            echo "GLX_DISPLAY_PASSED" >&2
            exit 69
        fi
        printf '{"schemaVersion":1,"probe":"glx","available":true,"rendered":true}\n' ;;
    egl) printf '{"schemaVersion":1,"probe":"egl","available":true,"rendered":true}\n' ;;
    *) echo "bad probe" >&2; exit 2 ;;
esac
EOF
cat >"$FAKE/floe-opencl-probe" <<'EOF'
#!/bin/sh
case "${1:-}" in
    status) printf '{"schemaVersion":1,"enumerated":true,"platforms":[{"deviceCount":1}]}\n' ;;
    run) printf '{"schemaVersion":1,"enumerated":true,"compute":{"success":true,"operations":["fill","copy","readback","map"]}}\n' ;;
    *) echo "bad opencl probe" >&2; exit 2 ;;
esac
EOF
cat >"$FAKE/floe-blas-run" <<'EOF'
#!/bin/sh
case "${1:-}" in
    --status) echo "provider: fake" ;;
    --set-mode) echo "mode: $2" ;;
    *) shift; exec "$@" ;;
esac
EOF
cat >"$FAKE/floe-blas-probe" <<'EOF'
#!/bin/sh
echo '{"probe":"fake"}'
EOF
cat >"$FAKE/floe-codec" <<'EOF'
#!/bin/sh
echo '{"formats":[]}'
EOF
cat >"$FAKE/floe-blender" <<'EOF'
#!/bin/sh
echo '{"available":false}'
EOF
cat >"$FAKE/clspv" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$FAKE/ldconfig" <<'EOF'
#!/bin/sh
echo "libOpenCL.so.1 (libc6,AArch64) => /usr/lib/libOpenCL.so.1"
EOF
chmod +x "$FAKE"/*

count_nodes() {
    count=0
    for path in /dev/dri/renderD*; do
        [ -e "$path" ] && count=$((count + 1))
    done
    printf '%s' "$count"
}
count_video() {
    count=0
    for path in /dev/video*; do
        [ -e "$path" ] && count=$((count + 1))
    done
    printf '%s' "$count"
}
BASE_RENDER=$(count_nodes)
BASE_VIDEO=$(count_video)

if [ -w /dev ]; then
    [ -d /dev/dri ] || { mkdir -p /dev/dri && CREATED_DRI=1; }
    if [ -e /dev/dri/renderD129 ]; then
        echo "SKIP: /dev/dri/renderD129 already exists; cannot prove additive scanning" >&2
    else
        : >/dev/dri/renderD129 && CREATED_RENDER=/dev/dri/renderD129
    fi
    if [ -e /dev/video42 ]; then
        echo "SKIP: /dev/video42 already exists; cannot prove additive scanning" >&2
    else
        : >/dev/video42 && CREATED_VIDEO=/dev/video42
    fi
else
    echo "SKIP: /dev is not writable; node-scan check runs without fake nodes" >&2
fi
EXPECTED_RENDER=$BASE_RENDER
[ -n "$CREATED_RENDER" ] && EXPECTED_RENDER=$((BASE_RENDER + 1))
EXPECTED_VIDEO=$BASE_VIDEO
[ -n "$CREATED_VIDEO" ] && EXPECTED_VIDEO=$((BASE_VIDEO + 1))

COUNTER=0
check() {
    COUNTER=$((COUNTER + 1))
    if ! "$@"; then
        echo "FAIL after check $COUNTER: $*" >&2
        exit 1
    fi
}

run_dispatcher() {
    PATH="$FAKE:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$DISPATCHER" "$@"
}

# 1. Inventory is valid JSON with the unchanged old body and additive facts.
PATH="$FAKE:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$DISPATCHER" status --json >"$WORK/status.json"
python3 - "$WORK/status.json" "$EXPECTED_RENDER" "$EXPECTED_VIDEO" <<'PY'
import json
import sys
path, expected_render, expected_video = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
status = json.load(open(path))
assert status["schemaVersion"] == 1, status
for section in ("graphics", "video", "compute", "blender"):
    assert isinstance(status[section], dict), section
for key in ("deviceNodePresent", "inspectorInstalled"):
    assert key in status["graphics"], key
for key in ("clientInstalled", "decoderNodePresent", "encoderNodePresent"):
    assert key in status["video"], key
for key in ("runnerInstalled", "probeInstalled", "providerInstalled"):
    assert key in status["compute"], key
for key in ("launcherInstalled", "applicationInstalled"):
    assert key in status["blender"], key
assert status["graphics"]["renderNodeCount"] == expected_render, status
assert "cardNodeCount" in status["graphics"], status
assert status["video"]["videoNodeCount"] == expected_video, status
assert status["graphics"]["glxInspectorInstalled"] is True, status
assert status["graphics"]["eglInspectorInstalled"] is True, status
assert "eglLibraryInstalled" in status["graphics"], status
assert status["graphics"]["glProbeInstalled"] is True, status
assert status["compute"]["openCLProbeInstalled"] is True, status
assert status["compute"]["openCLLoaderInstalled"] is True, status
assert status["compute"]["openCLCompilerInstalled"] is True, status
if expected_render:
    assert status["graphics"]["deviceNodePresent"] is True, status
    assert status["graphics"]["renderNodePresent"] is True, status
print("status-json-ok")
PY
check test $? -eq 0

# 2. Existing entries still resolve and fail predictably.
set +e
run_dispatcher status unexpected >"$WORK/status-bad.out" 2>"$WORK/status-bad.err"
check test $? -eq 2
run_dispatcher graphics info >"$WORK/glx-nodisplay.out" 2>"$WORK/glx-nodisplay.err"
GLX_NODISPLAY=$?
run_dispatcher unknown >"$WORK/unknown.out" 2>"$WORK/unknown.err"
UNKNOWN=$?
set -e
check test "$GLX_NODISPLAY" -eq 69
check grep -q "Open Screen" "$WORK/glx-nodisplay.err"
check test "$UNKNOWN" -eq 2

# 2b. A preset/wrong DISPLAY must not break pure Vulkan enumeration, while
# OpenGL still receives the actual project DISPLAY.
DISPLAY=:9876
WAYLAND_DISPLAY=wayland-0
export DISPLAY WAYLAND_DISPLAY
run_dispatcher graphics status >"$WORK/vulkan-display.out" 2>"$WORK/vulkan-display.err"
check grep -q "Vulkan Instance Version" "$WORK/vulkan-display.out"
unset WAYLAND_DISPLAY
set +e
DISPLAY=:9876 run_dispatcher graphics info >"$WORK/glx-wrong-display.out" 2>"$WORK/glx-wrong-display.err"
WRONG_DISPLAY=$?
set -e
check test "$WRONG_DISPLAY" -eq 69
check grep -q "GLX_DISPLAY_PASSED" "$WORK/glx-wrong-display.err"

# 3. New OpenGL paths use the probe and preserve its exit status.
DISPLAY=:99
export DISPLAY
run_dispatcher graphics info >"$WORK/glx.json" 2>"$WORK/glx.err"
check grep -q '"probe":"glx"' "$WORK/glx.json"
unset DISPLAY
run_dispatcher graphics egl >"$WORK/egl.json" 2>"$WORK/egl.err"
check grep -q '"probe":"egl"' "$WORK/egl.json"

# 4. OpenCL status/probe reach the probe; missing probe is an explicit 69.
run_dispatcher compute opencl status >"$WORK/opencl-status.json" 2>"$WORK/opencl-status.err"
check grep -q '"enumerated":true' "$WORK/opencl-status.json"
run_dispatcher compute opencl probe --device any --size 1024 >"$WORK/opencl-run.json" 2>"$WORK/opencl-run.err"
check grep -q '"success":true' "$WORK/opencl-run.json"

mkdir -p "$WORK/no-opencl"
cp "$FAKE/vulkaninfo" "$FAKE/glxinfo" "$FAKE/floe-gl-probe" "$FAKE/floe-blas-run" \
   "$FAKE/floe-blas-probe" "$FAKE/floe-codec" "$FAKE/floe-blender" "$WORK/no-opencl/"
set +e
PATH="$WORK/no-opencl:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$DISPATCHER" compute opencl status \
    >"$WORK/no-opencl.out" 2>"$WORK/no-opencl.err"
NO_PROBE=$?
set -e
check test "$NO_PROBE" -eq 69
check grep -q "Missing floe-opencl-probe" "$WORK/no-opencl.err"

# 5. An old image without either GL inspector keeps the same explicit error.
mkdir -p "$WORK/no-gl"
cp "$FAKE/vulkaninfo" "$FAKE/floe-blas-run" "$FAKE/floe-blas-probe" "$FAKE/floe-codec" "$FAKE/floe-blender" "$WORK/no-gl/"
set +e
DISPLAY=:99 PATH="$WORK/no-gl:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$DISPATCHER" graphics info \
    >"$WORK/no-gl.out" 2>"$WORK/no-gl.err"
NO_GL=$?
set -e
check test "$NO_GL" -eq 69
check grep -q "Missing glxinfo" "$WORK/no-gl.err"

# 6. Missing BLAS still fails 69 rather than pretending success.
mkdir -p "$WORK/no-blas"
cp "$FAKE/vulkaninfo" "$FAKE/floe-codec" "$FAKE/floe-blender" "$WORK/no-blas/"
set +e
PATH="$WORK/no-blas:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$DISPATCHER" compute status \
    >"$WORK/no-blas.out" 2>"$WORK/no-blas.err"
NO_BLAS=$?
set -e
check test "$NO_BLAS" -eq 69
check grep -q "Missing floe-blas-run" "$WORK/no-blas.err"

echo "ACCELERATION_GUEST_CHECKS_OK $COUNTER"
