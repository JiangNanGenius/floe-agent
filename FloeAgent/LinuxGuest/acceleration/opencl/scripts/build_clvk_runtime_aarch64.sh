#!/bin/sh
# Runtime-only ARM64 Linux producer for the genuine kpet/clvk ICD.
#
# The external-compiler profile never configures, builds or links clspv, LLVM,
# tablegen, libclc or SPIRV-LLVM-Translator. The ICD keeps compiler support ON
# and its offline clBuildProgram path executes the separately supplied clspv
# process. A compiler may be absent while preparing a runtime stage, but this
# producer then refuses to advertise it as packageable (exit 3).
#
# SOURCE-ONLY STATUS: no configure/build is run in this source tree. The script
# fails closed unless --execute is supplied and every pinned input is present.
# It never downloads, installs packages, boots a VM or contacts a GPU.
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
REPO=$(CDPATH= cd -- "$HERE/../../../.." && pwd)
CLVK_SOURCE=""
OPENCL_HEADERS=""
SPIRV_HEADERS=""
SPIRV_TOOLS=""
CLSPV_SOURCE=""
CLSPV_INCLUDE="$HERE/include"
LLVM_SPIRV=""
LLVM_SPIRV_MANIFEST=""
COMPILER=""
COMPILER_MANIFEST=""
SYSROOT=""
CROSS_FILE=""
NATIVE=0
WORK=""
BUILD=""
STAGE=""
JOBS=6
EXECUTE=0
CHECK_ONLY=0
PLAN_ONLY=0
ENABLE_IL=0
PLAN_OUT=""
PATCH_DIR="$HERE/patches"
PATCHES="0001-floe-private-icd-output-name.patch 0002-floe-external-clspv-runtime.patch 0003-floe-runtime-compiler-admission.patch 0004-floe-il-disabled-api-honesty.patch"

while [ $# -gt 0 ]; do
    case "$1" in
        --clvk-source) CLVK_SOURCE="$2"; shift 2 ;;
        --opencl-headers) OPENCL_HEADERS="$2"; shift 2 ;;
        --spirv-headers) SPIRV_HEADERS="$2"; shift 2 ;;
        --spirv-tools) SPIRV_TOOLS="$2"; shift 2 ;;
        --clspv-source) CLSPV_SOURCE="$2"; shift 2 ;;
        --clspv-include) CLSPV_INCLUDE="$2"; shift 2 ;;
        --compiler) COMPILER="$2"; shift 2 ;;
        --compiler-manifest) COMPILER_MANIFEST="$2"; shift 2 ;;
        --llvm-spirv) LLVM_SPIRV="$2"; shift 2 ;;
        --llvm-spirv-manifest) LLVM_SPIRV_MANIFEST="$2"; shift 2 ;;
        --enable-spirv-il) ENABLE_IL=1; shift ;;
        --sysroot) SYSROOT="$2"; shift 2 ;;
        --cross-file) CROSS_FILE="$2"; shift 2 ;;
        --native) NATIVE=1; shift ;;
        --work) WORK="$2"; shift 2 ;;
        --build) BUILD="$2"; shift 2 ;;
        --stage) STAGE="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --plan-out) PLAN_OUT="$2"; shift 2 ;;
        --execute) EXECUTE=1; shift ;;
        --check-only) CHECK_ONLY=1; shift ;;
        --plan-only) PLAN_ONLY=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$WORK" ] && [ -n "$BUILD" ] && [ -n "$STAGE" ] || {
    echo "missing --work/--build/--stage" >&2; exit 2;
}
[ "$ENABLE_IL" -eq 1 ] || {
    [ -z "$LLVM_SPIRV" ] && [ -z "$LLVM_SPIRV_MANIFEST" ] || {
        echo "--llvm-spirv/--llvm-spirv-manifest require --enable-spirv-il" >&2; exit 2;
    }
}
[ -z "$COMPILER" ] || [ -n "$COMPILER_MANIFEST" ] || {
    echo "--compiler requires --compiler-manifest (unverified compilers are never staged)" >&2; exit 2;
}
[ -z "$COMPILER_MANIFEST" ] || [ -n "$COMPILER" ] || {
    echo "--compiler-manifest requires --compiler" >&2; exit 2;
}
if [ "$ENABLE_IL" -eq 1 ]; then
    [ -n "$LLVM_SPIRV" ] && [ -n "$LLVM_SPIRV_MANIFEST" ] || {
        echo "--enable-spirv-il requires --llvm-spirv and --llvm-spirv-manifest" >&2; exit 2;
    }
fi
[ "$NATIVE" -eq 1 ] || [ -n "$CROSS_FILE" ] || {
    echo "cross build requires --cross-file" >&2; exit 2;
}

MISSING=""
fail_input() {
    echo "MISSING_OR_UNVERIFIED: $*" >&2
    MISSING="$MISSING$*;"
}
sha256_of() {
    python3 - "$1" <<'PY'
import hashlib, pathlib, sys
p = pathlib.Path(sys.argv[1])
h = hashlib.sha256()
with p.open('rb') as f:
    for chunk in iter(lambda: f.read(1 << 20), b''):
        h.update(chunk)
print(h.hexdigest())
PY
}
verify_source() {
    name=$1; path=$2; commit=$3; tree=$4
    if ! out=$(python3 "$HERE/scripts/verify_source_tree.py" "$name" "$path" \
            --commit "$commit" --tree "$tree" 2>&1); then
        echo "$out" >&2
        fail_input "$name source identity"
    fi
}

# Always check package-local assets.
for p in $PATCHES; do
    [ -f "$PATCH_DIR/$p" ] || fail_input "private patch: $PATCH_DIR/$p"
done
[ -f "$HERE/include/clspv/Sampler.h" ] || fail_input "vendored clspv/Sampler.h"
[ -f "$HERE/PINS.json" ] || fail_input "PINS.json"
EXPECTED_HEADER=$(python3 - "$HERE/PINS.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["components"]["clspv-header"]["vendoredSHA256"])
PY
)
if [ -f "$HERE/include/clspv/Sampler.h" ]; then
    ACTUAL_HEADER=$(sha256_of "$HERE/include/clspv/Sampler.h")
    [ "$ACTUAL_HEADER" = "$EXPECTED_HEADER" ] || fail_input "vendored clspv header hash $ACTUAL_HEADER != $EXPECTED_HEADER"
fi

if [ "$PLAN_ONLY" -ne 1 ]; then
    verify_source clvk "$CLVK_SOURCE" "399abf00c30b6d1d7a65d7ac06beee60b5991d7b" "76685cd7d5ec7ba634f04a9d966299faba9ced64"
    verify_source opencl-headers "$OPENCL_HEADERS" "386ca390b2f52efeb3e1a55a500690eb8013f60e" "d3a2c90329d8e3647dc2405084d508292390a35f"
    [ -n "$SPIRV_HEADERS" ] || fail_input "SPIRV-Headers source (set --spirv-headers)"
    [ -n "$SPIRV_TOOLS" ] || fail_input "SPIRV-Tools source (set --spirv-tools)"
    if [ -n "$SPIRV_HEADERS" ]; then
        verify_source spirv-headers "$SPIRV_HEADERS" "2b7475f6d664efbad4d4315c94ecec9640831e5b" "d32102dcf5b644c393ee605222d9da3feec64eb7"
    fi
    if [ -n "$SPIRV_TOOLS" ]; then
        verify_source spirv-tools "$SPIRV_TOOLS" "ba9a9e32160e2500ce1e48cc563a8fedaf596e6e" "9efb82f9bddb172231c18b5f4ecaa75ba2f862ab"
    fi
    if [ -n "$CLSPV_SOURCE" ]; then
        verify_source clspv-header-source "$CLSPV_SOURCE" "7ee3a40e652b3649d175758f72d7af98b9450a68" "a5de315ace53c50cf8ec1dbca8f3b89839472636"
        if [ -f "$CLSPV_SOURCE/include/clspv/Sampler.h" ]; then
            SRC_HEADER=$(sha256_of "$CLSPV_SOURCE/include/clspv/Sampler.h")
            [ "$SRC_HEADER" = "$EXPECTED_HEADER" ] || fail_input "pinned clspv header $SRC_HEADER != vendored $EXPECTED_HEADER"
        else
            fail_input "clspv source lacks include/clspv/Sampler.h"
        fi
    fi
    command -v cmake >/dev/null 2>&1 || fail_input "cmake"
    command -v ninja >/dev/null 2>&1 || fail_input "ninja"
    command -v python3 >/dev/null 2>&1 || fail_input "python3"
    if [ "$NATIVE" -ne 1 ]; then
        if ! python3 "$HERE/scripts/verify_sysroot.py" >/dev/null 2>&1; then
            fail_input "Debian trixie ARM64 sysroot hashes"
        fi
    fi
fi

# The optional external compiler is verified before any build. A missing
# compiler is allowed for a component stage, but a supplied compiler without
# a valid manifest is not.
if [ "$PLAN_ONLY" -ne 1 ] && [ -n "$COMPILER" ]; then
    if ! python3 "$HERE/scripts/verify_external_toolchain.py" \
            --manifest "$COMPILER_MANIFEST" --artifact "$COMPILER" \
            --out "$HERE/checks/EXTERNAL_TOOLCHAIN_CLSPV.json" >/dev/null 2>&1; then
        fail_input "external clspv manifest/artifact admission"
    fi
fi
if [ "$PLAN_ONLY" -ne 1 ] && [ "$ENABLE_IL" -eq 1 ] && [ -n "$LLVM_SPIRV" ]; then
    if ! python3 "$HERE/scripts/verify_external_toolchain.py" \
            --manifest "$LLVM_SPIRV_MANIFEST" --artifact "$LLVM_SPIRV" \
            --tool llvm-spirv \
            --out "$HERE/checks/EXTERNAL_TOOLCHAIN_LLVMSPIRV.json" >/dev/null 2>&1; then
        fail_input "external llvm-spirv manifest/artifact admission"
    fi
fi

if [ -n "$MISSING" ]; then
    if [ -n "$PLAN_OUT" ]; then
        python3 "$HERE/scripts/make_plan.py" --out "$PLAN_OUT" \
            --status blocked-missing-or-unverified-inputs --mode check \
            --profile external-runtime --target "$( [ "$NATIVE" -eq 1 ] && echo native || echo aarch64-linux )" \
            --jobs "$JOBS" --missing "$MISSING" \
            --build-target OpenCL --excluded-input LLVM --excluded-input clspv \
            --excluded-input SPIRV-LLVM-Translator --excluded-input tablegen \
            --excluded-input libclc >/dev/null
    fi
    echo "BUILD_NOT_READY:$MISSING" >&2
    exit 2
fi

if [ "$PLAN_ONLY" -eq 1 ] || [ "$CHECK_ONLY" -eq 1 ]; then
    TMPPLAN=$(mktemp -d "$HERE/checks/.plan.XXXXXX")
    trap 'rm -rf "$TMPPLAN"' EXIT HUP INT TERM
    ARGS_FILE="$TMPPLAN/cmake-args.txt"
else
    ARGS_FILE="$WORK/cmake-args.txt"
    for d in "$WORK" "$BUILD" "$STAGE"; do
        [ ! -e "$d" ] || { echo "output path already exists: $d" >&2; exit 2; }
    done
    mkdir -p "$WORK" "$BUILD" "$STAGE"
    ARGS_FILE="$WORK/cmake-args.txt"
fi
: > "$ARGS_FILE"
add_arg() { printf '%s\n' "$1" >> "$ARGS_FILE"; }

add_arg -S
add_arg "$WORK/clvk"
add_arg -B
add_arg "$BUILD"
add_arg -G
add_arg Ninja
add_arg -DCMAKE_BUILD_TYPE=Release
add_arg -DCMAKE_INSTALL_PREFIX=/usr
add_arg -DCLVK_VULKAN_IMPLEMENTATION=system
add_arg -DCLVK_BUILD_TESTS=OFF
add_arg -DCLVK_BUILD_STATIC_TESTS=OFF
add_arg -DCLVK_COMPILER_AVAILABLE=ON
add_arg -DCLVK_CLSPV_ONLINE_COMPILER=OFF
add_arg -DCLVK_EXTERNAL_CLSPV=ON
if [ "$ENABLE_IL" -eq 1 ]; then
    add_arg -DCLVK_ENABLE_SPIRV_IL=ON
    add_arg -DCLVK_EXTERNAL_LLVMSPIRV_PATH=/usr/lib/floe-opencl/llvm-spirv
else
    add_arg -DCLVK_ENABLE_SPIRV_IL=OFF
fi
add_arg -DCLVK_EXTERNAL_CLSPV_PATH=/usr/lib/floe-opencl/clspv
add_arg "-DCLSPV_INCLUDE_DIR=$CLSPV_INCLUDE"
add_arg "-DSPIRV_HEADERS_SOURCE_DIR=${SPIRV_HEADERS:-<missing:SPIRV-Headers>}"
add_arg "-DSPIRV_TOOLS_SOURCE_DIR=${SPIRV_TOOLS:-<missing:SPIRV-Tools>}"
add_arg "-DOPENCL_HEADERS_SOURCE_DIR=$OPENCL_HEADERS"
add_arg -DCLVK_BUILD_SPIRV_TOOLS=ON
add_arg -DSPIRV_SKIP_TESTS=ON
if [ "$NATIVE" -ne 1 ]; then
    add_arg "-DCMAKE_TOOLCHAIN_FILE=$CROSS_FILE"
    add_arg "-DCMAKE_SYSROOT=$SYSROOT"
    add_arg "-DVulkan_INCLUDE_DIR=$SYSROOT/usr/include"
    add_arg "-DVulkan_LIBRARY=$SYSROOT/usr/lib/aarch64-linux-gnu/libvulkan.so"
fi

if [ "$PLAN_ONLY" -eq 1 ] || [ "$CHECK_ONLY" -eq 1 ]; then
    STATUS="inputs-verified-build-not-run"
    MODE="check"
    NOTE="All declared runtime-only inputs verified; no configure/compile/link/install was run."
    if [ "$PLAN_ONLY" -eq 1 ]; then
        STATUS="plan-only-build-not-run"
        MODE="plan"
        NOTE="Plan only. Inputs were not required to exist; no configure/compile/link/install was run."
    fi
    if [ -n "$PLAN_OUT" ]; then
        python3 "$HERE/scripts/make_plan.py" --out "$PLAN_OUT" \
            --status "$STATUS" --mode "$MODE" --profile external-runtime \
            --target "$( [ "$NATIVE" -eq 1 ] && echo native || echo aarch64-linux )" \
            --jobs "$JOBS" --cmake-args-file "$ARGS_FILE" \
            --build-target OpenCL \
            --input "clvk:$CLVK_SOURCE" --input "opencl-headers:$OPENCL_HEADERS" \
            --input "spirv-headers:${SPIRV_HEADERS:-<unverified>}" \
            --input "spirv-tools:${SPIRV_TOOLS:-<unverified>}" \
            --input "clspv-header:$CLSPV_INCLUDE/clspv/Sampler.h" \
            --optional-input "external-clspv:${COMPILER:-<not-supplied>}" \
            --optional-input "external-llvm-spirv:${LLVM_SPIRV:-<not-supplied>}" \
            --excluded-input LLVM --excluded-input clspv \
            --excluded-input SPIRV-LLVM-Translator --excluded-input tablegen \
            --excluded-input libclc --note "$NOTE" >/dev/null
    fi
    echo "INPUTS_OK BUILD_NOT_RUN"
    exit 0
fi

[ "$EXECUTE" -eq 1 ] || {
    echo "refusing to build without --execute (source-only delivery default)" >&2
    exit 2
}

echo "PHASE copy-and-apply-patches"
cp -cR "$CLVK_SOURCE/." "$WORK/clvk/" 2>/dev/null || cp -R "$CLVK_SOURCE/." "$WORK/clvk/"
for p in $PATCHES; do
    ( cd "$WORK/clvk" && patch -p1 --batch --dry-run -i "$PATCH_DIR/$p" >/dev/null )
done
for p in $PATCHES; do
    ( cd "$WORK/clvk" && patch -p1 --batch --forward -i "$PATCH_DIR/$p" >/dev/null )
done

echo "PHASE configure-runtime-only"
set --
while IFS= read -r arg; do
    set -- "$@" "$arg"
done < "$ARGS_FILE"
if ! cmake "$@" > "$WORK/configure.log" 2>&1; then
    tail -n 120 "$WORK/configure.log" >&2
    echo "CONFIGURE_FAILED" >&2
    exit 1
fi
# Prove the executed configure did not introduce the toolchain.
grep -q '^CLVK_EXTERNAL_CLSPV:BOOL=ON$' "$BUILD/CMakeCache.txt" || {
    echo "external mode missing from CMakeCache" >&2; exit 1; }
if grep -q '^CLSPV_SOURCE_DIR:' "$BUILD/CMakeCache.txt"; then
    echo "clspv source was configured" >&2; exit 1
fi
if grep -q '^LLVM_DIR:' "$BUILD/CMakeCache.txt"; then
    echo "LLVM was configured" >&2; exit 1
fi
if grep -q '^LLVM_SPIRV_SOURCE:' "$BUILD/CMakeCache.txt"; then
    echo "SPIRV-LLVM-Translator was configured" >&2; exit 1
fi
[ ! -d "$BUILD/external/clspv" ] || { echo "clspv build dir exists" >&2; exit 1; }
[ ! -d "$BUILD/external/SPIRV-LLVM-Translator" ] || {
    echo "SPIRV-LLVM-Translator build dir exists" >&2; exit 1; }

echo "PHASE build-OpenCL-target"
if ! cmake --build "$BUILD" --target OpenCL --parallel "$JOBS" \
        > "$WORK/build.log" 2>&1; then
    tail -n 120 "$WORK/build.log" >&2
    echo "BUILD_FAILED" >&2
    exit 1
fi

LIB_REAL=$(find "$BUILD" -maxdepth 1 -name 'libfloe_clvk.so.*' -type f | head -n 1)
[ -n "$LIB_REAL" ] || { echo "missing built libfloe_clvk.so.*" >&2; exit 1; }
[ -L "$BUILD/libfloe_clvk.so.1" ] || { echo "missing libfloe_clvk.so.1 symlink" >&2; exit 1; }
[ ! -e "$BUILD/libOpenCL.so.1" ] || { echo "unexpected loader-named library" >&2; exit 1; }
[ ! -e "$BUILD/clspv" ] || { echo "clspv target was built unexpectedly" >&2; exit 1; }
[ ! -e "$BUILD/llvm-spirv" ] || { echo "llvm-spirv target was built unexpectedly" >&2; exit 1; }

echo "PHASE stage-runtime"
mkdir -p "$STAGE/usr/lib/floe-opencl" "$STAGE/usr/share/floe-opencl/vendors" \
         "$STAGE/usr/bin" "$STAGE/usr/share/doc/floe-opencl-clvk/licenses"
cp -P "$BUILD"/libfloe_clvk.so* "$STAGE/usr/lib/floe-opencl/"
cp "$HERE/runtime/floe-clvk.icd" "$STAGE/usr/share/floe-opencl/vendors/floe-clvk.icd"
cp "$HERE/runtime/floe-opencl-env.sh" "$STAGE/usr/share/floe-opencl/floe-opencl-env.sh"
cp "$HERE/runtime/floe-opencl-register" "$STAGE/usr/bin/floe-opencl-register"
cp "$HERE/PINS.json" "$STAGE/usr/share/doc/floe-opencl-clvk/PINS.json"
cp "$PATCH_DIR"/*.patch "$STAGE/usr/share/doc/floe-opencl-clvk/"
cp "$HERE/licenses"/* "$STAGE/usr/share/doc/floe-opencl-clvk/licenses/"
cp "$WORK/configure.log" "$WORK/build.log" "$STAGE/usr/share/doc/floe-opencl-clvk/"
chmod 0755 "$STAGE/usr/bin/floe-opencl-register"

python3 "$HERE/scripts/verify_private_stage.py" \
    --libdir "$STAGE/usr/lib/floe-opencl" \
    --expected-soname libfloe_clvk.so.1 >/dev/null || {
    echo "STAGED_ICD_LAYOUT_FAILED" >&2; exit 1; }

COMPILER_SHA=""
LLVMSPIRV_SHA=""
if [ -n "$COMPILER" ]; then
    cp "$COMPILER" "$STAGE/usr/lib/floe-opencl/clspv"
    chmod 0755 "$STAGE/usr/lib/floe-opencl/clspv"
    python3 "$HERE/scripts/verify_external_toolchain.py" \
        --manifest "$COMPILER_MANIFEST" --stage-root "$STAGE" \
        --artifact "$STAGE/usr/lib/floe-opencl/clspv" \
        --out "$HERE/checks/EXTERNAL_TOOLCHAIN_CLSPV_STAGED.json" >/dev/null || {
        echo "STAGED_COMPILER_ADMISSION_FAILED" >&2; exit 1; }
    COMPILER_SHA=$(sha256_of "$STAGE/usr/lib/floe-opencl/clspv")
    cp "$COMPILER_MANIFEST" "$STAGE/usr/share/doc/floe-opencl-clvk/EXTERNAL_TOOLCHAIN_CLSPV.json"
fi
if [ "$ENABLE_IL" -eq 1 ]; then
    cp "$LLVM_SPIRV" "$STAGE/usr/lib/floe-opencl/llvm-spirv"
    chmod 0755 "$STAGE/usr/lib/floe-opencl/llvm-spirv"
    python3 "$HERE/scripts/verify_external_toolchain.py" \
        --manifest "$LLVM_SPIRV_MANIFEST" --stage-root "$STAGE" \
        --artifact "$STAGE/usr/lib/floe-opencl/llvm-spirv" --tool llvm-spirv \
        --out "$HERE/checks/EXTERNAL_TOOLCHAIN_LLVMSPIRV_STAGED.json" >/dev/null || {
        echo "STAGED_LLVMSPIRV_ADMISSION_FAILED" >&2; exit 1; }
    LLVMSPIRV_SHA=$(sha256_of "$STAGE/usr/lib/floe-opencl/llvm-spirv")
    cp "$LLVM_SPIRV_MANIFEST" "$STAGE/usr/share/doc/floe-opencl-clvk/EXTERNAL_TOOLCHAIN_LLVMSPIRV.json"
fi

echo "PHASE write-producer-result"
python3 - "$STAGE" "$ENABLE_IL" "$COMPILER_SHA" "$LLVMSPIRV_SHA" "$ARGS_FILE" "$JOBS" <<'PY'
import hashlib, json, pathlib, sys
stage = pathlib.Path(sys.argv[1])
enable_il = sys.argv[2] == "1"
compiler_sha = sys.argv[3] or None
llvmspirv_sha = sys.argv[4] or None
cmake_args = [l for l in pathlib.Path(sys.argv[5]).read_text().splitlines() if l]
artifacts = {}
for p in sorted(stage.rglob("*")):
    if p.is_file() and not p.is_symlink():
        h = hashlib.sha256(p.read_bytes()).hexdigest()
        artifacts[str(p.relative_to(stage))] = {"sha256": h, "bytes": p.stat().st_size}
compiler_admitted = compiler_sha is not None
result = {
    "schema": 1,
    "status": ("runtime-stage-built-compiler-admitted" if compiler_admitted
               else "runtime-stage-built-compiler-missing"),
    "profile": "external-runtime-il" if enable_il else "external-runtime",
    "sourceOnly": False,
    "configureRun": True,
    "buildRun": True,
    "target": "aarch64-linux",
    "jobs": int(sys.argv[6]),
    "buildTarget": "OpenCL",
    "clvkCommit": "399abf00c30b6d1d7a65d7ac06beee60b5991d7b",
    "clspvHeaderCommit": "7ee3a40e652b3649d175758f72d7af98b9450a68",
    "llvmCompilerProvenanceCommit": "71a85ef89fc1997205104b72447e0dc2c4ad83da",
    "compilerAvailableCompileFlag": True,
    "spirvIl": enable_il,
    "llvmConfigured": False,
    "clspvTargetConfigured": False,
    "llvmSpirvTargetConfigured": False,
    "cmakeArgs": cmake_args,
    "externalCompiler": ({"path": "/usr/lib/floe-opencl/clspv", "sha256": compiler_sha}
                         if compiler_admitted else None),
    "externalLlvmSpirv": ({"path": "/usr/lib/floe-opencl/llvm-spirv", "sha256": llvmspirv_sha}
                          if llvmspirv_sha else None),
    "admission": {
        "runtimeBuilt": True,
        "compilerAdmitted": compiler_admitted,
        "packagingAllowed": compiler_admitted,
        "reason": ("verified external clspv supplied" if compiler_admitted
                   else "runtime stage only: verified external clspv is missing; package/admission is refused"),
    },
    "artifacts": artifacts,
    "unrun": [
        "actual ARM64 configure/build/link of this source package",
        "ocl-icd dlopen and platform/device enumeration",
        "real clspv execution and clBuildProgram",
        "numerical/lifetime fixture on CL_DEVICE_TYPE_GPU",
        "VM/App/Simulator/device acceptance owned by Main",
    ],
}
(stage / "usr/share/floe-opencl/PRODUCER_RESULT.json").write_text(
    json.dumps(result, indent=2, sort_keys=True) + "\n")
print(json.dumps({"status": result["status"], "artifacts": len(artifacts)}, indent=2))
PY

if [ -z "$COMPILER_SHA" ]; then
    echo "RUNTIME_STAGE_READY_COMPILER_MISSING: package and compiler-advertised runtime are refused" >&2
    exit 3
fi
echo "RUNTIME_STAGE_READY_COMPILER_ADMITTED stage=$STAGE"
echo "NEXT: run package_opencl_runtime.py with the same verified compiler manifest."
