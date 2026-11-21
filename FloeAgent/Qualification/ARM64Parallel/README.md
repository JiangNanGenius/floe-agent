# ARM64 parallel IRQ publication

`IRQPublicationTests.c` includes the actual production session and parallel
runtime. Link it with the ordinary ARM64 engine archive, without force-loading
duplicate runtime objects. Compile with assertions enabled and the engine's
`include`, `Source/src` and `Bridge` include directories; Apple hosts also
require `Security`, `resolv` and pthread linkage.

Pass a new, writable fixture directory to the executable. It creates a small
firmware file, opens a real four-hart session and checks the real readiness
pipe and pending publications while all workers are quiet. It verifies:

- Repeated already-low IRQ levels do not request another full poll or wake.
- Rising, falling and repeated asserted levels preserve delivery and wakeup.
- Coalescing retains an unconsumed falling edge, event or TLB/control flag.
- A GIC rescan of four inactive interrupt lines does not manufacture work.
- Four worker completions in one wait need a single pipe byte. The next wait
  still wakes, and completions while the coordinator is working publish
  progress without writing to the readiness pipe.

Success prints `ARM64_IRQ_PUBLICATION_OK`. The original implementation fails
the first no-op publication assertion. This is a notification-path regression,
not a Linux performance or concurrent instruction-execution benchmark. Keep
the existing worker, fast-poll, interrupt/event and TLB synchronization checks
when changing this path; the optimization does not change their boundaries.

## Per-hart CPU state isolation

`CPUStateIsolationTests.c` uses the same compile/link contract and a new fixture
directory. It creates the actual five-hart session and checks that each hart's
frequently written run-control/counter fields are separated from its neighbor's
execution context by a full 128-byte cache-line gap. CPU alignment remains the
ordinary integer alignment; existing `calloc` and embedded Machine callers do
not acquire an unsupported over-alignment requirement. It also checks destroy
and stale-handle behavior. Success prints `ARM64_CPU_STATE_ISOLATION_OK`.

The same fixture verifies that instruction fetch observes a writable data-TLB
hit, DMA writes, a fetch-bank eviction by another exception-level translation,
and a TLB flush. Each assertion reads the real guest word from the production
MMU.

CPU and Machine are internal layouts, so rebuild all engine translation units
and source-including qualification hosts together after changing this header.
Retain concurrent worker, memory, cache, stop, hotplug and sanitizer checks;
this layout regression alone does not establish Linux or physical-iPad speed.

## Optional guest GPU fallback

`GPUFallbackTests.c` links the production ARM64 engine objects, replacing only
the GPU backend factory with a deterministic failure. Compile it with
assertions enabled and pass a new writable fixture directory. The test checks
that existing strict GPU callers still fail, while callers setting
`FLOE_AE_GPU_ALLOW_CPU_FALLBACK` start a real CPU machine, expose no guest GPU,
and retain CPU, disk and network failures. Success prints
`ARM64_GPU_OPTIONAL_CPU_FALLBACK_OK`.

## CPU progress with a backlogged virtual disk

`BlockProgressTests.c` uses the ordinary engine link setup above. Pass two new
fixture paths for its firmware and disk. It submits a block queue notification
and replaces only the callback that drains the disk. The real scheduler must
retire the full instruction budget even while block work stays pending.
Success prints `ARM64_BLOCK_PROGRESS_OK`.
