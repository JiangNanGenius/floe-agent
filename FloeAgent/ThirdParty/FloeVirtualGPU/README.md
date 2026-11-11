# FloeVirtualGPU

Venus host backend for the optional ARM64EMU virtio-gpu device:
Linux Mesa Venus → virtio-gpu → virglrenderer → MoltenVK → public Metal.
The CPU interpreter does not generate executable native code.

`FloeGPUBinary` supplies three static arm64 slices. Exact upstream identities,
archive digests and licenses are in `../../Vendor/FloeGPU/PROVENANCE.json`.
`patches/0001-floe-vkr-accounting.patch` adds admission and lifetime accounting
to the pinned MIT renderer. The host target uses its public C headers only.

The default budget is 1 GiB, allocated on demand. Blob and internal Vulkan
allocations share one physical limit; mapped aliases do not incur a second
physical charge. Lowering a budget preserves live resources, limits new
allocations immediately and reports a pending target until resources are freed.
Completion tokens and map lifetimes remain owned until cancellation or teardown
has quiesced the renderer.

Enable this device only for verified images declaring Venus support. Stock
Mesa 25.0.7 requires `VN_PERF=no_async_mem_alloc` to receive quota failures
synchronously. Missing drivers are not replaced with a software Vulkan device.

Real Linux component qualification covers compute, offscreen graphics and
allocation failure/recovery. This backend does not implement a video codec
bridge or an accelerated onscreen display. The on-demand Xvnc screen uses a
software framebuffer. App, Simulator and physical iPad evidence are separate.
