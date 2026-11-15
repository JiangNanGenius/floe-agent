# FloeVirtualGPU

Venus host backend for the optional ARM64EMU virtio-gpu device:
Linux Mesa Venus → virtio-gpu → virglrenderer → MoltenVK → public Metal.
The CPU interpreter does not generate executable native code.

`FloeGPUBinary` supplies three static arm64 slices. Exact upstream identities,
archive digests and licenses are in `../../Vendor/FloeGPU/PROVENANCE.json`.
`patches/0001-floe-vkr-accounting.patch` adds admission and lifetime accounting
to the pinned MIT renderer. The host target uses its public C headers only.

The transport adapter now lives in
`../ARM64EMU/Bridge/fvgpu_virtio_backend_adapter.c` and is compiled through
`Sources/33_gpu_backend_adapter.c` by the engine. Its Apache-2.0 bytes and
ABI are unchanged. The engine owns the transport callbacks and consumes the
backend public session API; this target never links back to the engine.
Only existing public session declarations have default visibility; internal
helpers remain hidden. UIKit is linked only on iOS; AppKit/IOKit only on macOS.

The default budget is 1 GiB, allocated on demand. Blob and internal Vulkan
allocations share one physical limit; mapped aliases do not incur a second
physical charge. Lowering a budget preserves live resources, limits new
allocations immediately and reports a pending target until resources are freed.
Completion tokens and map lifetimes remain owned until cancellation or teardown
has quiesced the renderer.

`FloeGPUDeviceInfo` reports the device-wide physical heap size and, when the
driver exposes `VK_EXT_memory_budget`, its physical heap budget separately from
`session_budget_bytes`. The session value is the enforceable quota; the
physical figures must never be presented as this session's allowance. A HOST3D
shm export must cover the guest's requested blob bytes before it is mapped;
the page-rounded tail may be zero-filled.

A ledger invariant violation (unmatched release, counter overflow, reservation
mismatch) is recorded and makes every later admission fail closed.
`floe_gpu_ledger_faulted()` exposes that state so the transport can mark the
device for reset instead of reporting an undercounted budget. Assertion builds
still abort at the original assertion after recording the fault.

Set `FLOE_GPU_TRACE=1` to emit bounded lifecycle lines to stderr (limit
`FLOE_GPU_TRACE_LIMIT`, default 4096, clamped 16...65536). Tracing is disabled
by default and records only object ids, byte counts and lifecycle states.

Enable this device only for verified images declaring Venus support. Stock
Mesa 25.0.7 requires `VN_PERF=no_async_mem_alloc` to receive quota failures
synchronously. Missing drivers are not replaced with a software Vulkan device.

Real Linux component qualification covers compute, offscreen graphics and
allocation failure/recovery. This backend does not implement a video codec
bridge or an accelerated onscreen display. The on-demand Xvnc screen uses a
software framebuffer. App, Simulator and physical iPad evidence are separate.
