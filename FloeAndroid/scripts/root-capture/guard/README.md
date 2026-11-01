# Floe capture guard (local helper source)

This directory is the complete source of the narrow guard compiled into the
pinned `tcpdump-v1` helper. It is not an upstream tcpdump file and it does not
replace any upstream archive hash.

## Why it exists

The root server used to enforce duration, size, client-lease and shutdown
limits only with Java daemon threads. If the root-server process was SIGKILLed,
all of those threads disappeared while the native helper kept capturing (and
growing its output file) indefinitely.

The guard is an independent POSIX thread inside the helper itself. It owns
three bounds that survive the Java parent:

1. **Exact parent liveness.** The root server writes one configuration record
   to the child's stdin pipe and deliberately keeps the write end open. When
   the server is killed, the kernel closes that write end and the guard reads
   EOF/HUP. No PID polling, PID-reuse check or `PR_SET_PDEATHSIG` tied to a
   short-lived spawning thread is used.
2. **Monotonic deadline.** `CLOCK_MONOTONIC` from guard installation; quiet
   traffic cannot postpone it.
3. **Byte budget.** The output file is monitored and `RLIMIT_FSIZE` is the
   kernel-enforced backstop, so a slow/blocked userspace stop cannot grow the
   PCAP past the validated bound.

On a stop it appends one fsynced record to `<pcap>.guard`, sends `SIGTERM` to
its own process (tcpdump's existing handler calls `pcap_breakloop`), and after
a fixed grace calls `_exit(124)` even if capture cleanup is stuck. The partial
PCAP is preserved. A missing, malformed, mismatched or out-of-range
configuration aborts before capture starts; there is no permissive default.

## Files

| File | Purpose |
| --- | --- |
| `floe_capture_guard.c` | The complete guard implementation. |
| `floe_capture_guard.h` | API, constants and the stripped-safe identity record. |
| `../patches/0001-tcpdump-install-guard.patch` | The exact tcpdump 4.99.5 hook (include + one install call). |
| `../tests/guard_contract_test.c` | Host fork/pipe/deadline/size contract test. |
| `../tests/run-guard-tests.sh` | Builds and runs the host contract tests. |

`build-helper.sh` copies the two guard files into the extracted tcpdump source,
applies the patch, generates `floe_guard_identity.h` from the SHA-256 of this
source, this header and the patch, and adds `floe_capture_guard.c` to the
tcpdump compile list. The resulting ELF contains one identity record:

```
FLOE_CAPTURE_GUARD_V1|arm64-v8a|1|<source>|<header>|<patch>
```

`verify-helper.py` requires exactly one such record and compares it with the
build inputs; the generated `helper.json` embeds the same hashes and ABI. The
stager re-runs the verifier with the manifest values, so an old unguarded
helper cannot be staged or accepted as guarded. The runtime manifest schema is
`floe.root-capture-helper.v2` and requires the guard object.

The guard is Floe-authored source under MPL-2.0. It does not alter tcpdump's
license or the immutability of the pinned upstream archives.
