# Source this in an opted-in OpenCL CLIENTS environment only.
# It selects the private CLVK ICD and the matched private Venus Vulkan ICD.
# It never adds /usr/lib/floe-opencl to LD_LIBRARY_PATH: the system
# libOpenCL.so.1 loader must load this ICD by absolute path, not be shadowed.
#
# Runtime-only profile: the ICD contains the offline OpenCL C compiler path but
# the actual clspv process is a separately admitted package input. If it is
# missing, CLVK_CLSPV_PATH is not exported and CL_DEVICE_COMPILER_AVAILABLE is
# false rather than falsely advertising a compiler.
#
# Fallback: unset OCL_ICD_VENDORS and OPENCL_VENDOR_PATH, then rerun without
# this script. Debian's loader configuration is unchanged.

FLOE_OPENCL_ROOT="${FLOE_OPENCL_ROOT:-/usr/lib/floe-opencl}"
FLOE_OPENCL_ICD="${FLOE_OPENCL_ICD:-/usr/share/floe-opencl/vendors/floe-clvk.icd}"
FLOE_GPU_VK_ICD="${FLOE_GPU_VK_ICD:-/usr/share/floe-gpu/virtio_icd.json}"

if [ ! -e "$FLOE_OPENCL_ROOT/libfloe_clvk.so.1" ]; then
    printf '%s\n' "floe-opencl: missing $FLOE_OPENCL_ROOT/libfloe_clvk.so.1" >&2
fi
if [ ! -e "$FLOE_GPU_VK_ICD" ]; then
    printf '%s\n' "floe-opencl: missing Vulkan ICD $FLOE_GPU_VK_ICD" >&2
fi

# Debian ocl-icd 2.3.3-1 honours both variables; OCL_ICD_VENDORS takes
# precedence and may name this one .icd file directly.
export OCL_ICD_VENDORS="$FLOE_OPENCL_ICD"
export OPENCL_VENDOR_PATH="/usr/share/floe-opencl/vendors"

# The compiler is a separate ARM64 Linux clspv process, admitted at packaging
# time. Never point this at an unverified host compiler.
if [ -x "$FLOE_OPENCL_ROOT/clspv" ]; then
    export CLVK_CLSPV_PATH="$FLOE_OPENCL_ROOT/clspv"
else
    unset CLVK_CLSPV_PATH 2>/dev/null || true
    printf '%s\n' "floe-opencl: missing verified compiler $FLOE_OPENCL_ROOT/clspv; source compilation is unavailable" >&2
fi
if [ -x "$FLOE_OPENCL_ROOT/llvm-spirv" ]; then
    export CLVK_LLVMSPIRV_BIN="$FLOE_OPENCL_ROOT/llvm-spirv"
fi

# CLVK's Vulkan backend must see the matched private Venus ICD, not a host or
# CPU Vulkan device. The guest-combined package owns this JSON.
export VK_DRIVER_FILES="$FLOE_GPU_VK_ICD"
export VK_ICD_FILENAMES="$VK_DRIVER_FILES"

# Do not force a CPU/software device.
unset LIBGL_ALWAYS_SOFTWARE D3D_ALWAYS_SOFTWARE 2>/dev/null || true
