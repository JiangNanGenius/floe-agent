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
