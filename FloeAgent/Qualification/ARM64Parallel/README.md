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

CPU and Machine are internal layouts, so rebuild all engine translation units
and source-including qualification hosts together after changing this header.
Retain concurrent worker, memory, cache, stop, hotplug and sanitizer checks;
this layout regression alone does not establish Linux or physical-iPad speed.
