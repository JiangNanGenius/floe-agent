# Guest DNS resolver helper — libnss_floe.so.2 (source package)

This directory holds the **guest-side** half of the Floe guest system DNS
bridge v1. The authoritative, Main-FROZEN cross-language contract is
[`PROTOCOL.json`](PROTOCOL.json) (`id: floe-guest-dns-v1`). This file is the
lane record for the helper source and its producer; it never overrides the
protocol, and nothing in it is permission to change the protocol.

The Android-side handler (peer-credential check, PrivateDNS/system-resolver
use, frame enforcement, socket bind/lifecycle) is owned by the runtime
facilities lane against the same frozen contract. This module only ever
**connects** to `/run/floe-dns/s` as a same-runtime-UID client.

## What ships here

| File | Role |
| --- | --- |
| `libnss_floe.c` | The real glibc NSS module source (MPL-2.0, self-authored). Implements exactly the four contract entry points `_nss_floe_gethostbyname{,_2,_3,_4}_r` with the glibc ABI. |
| `nss-floe.map` | Linker version script: exports only those four symbols; everything else is local. |
| `build-guest-resolver.sh` | Standalone reproducible producer. Compiles with the **pinned Zig 0.14.1** (same URL/sha as `../build-bootstrap.sh` — no new pins) and links the shared object with the pinned NDK's `ld.lld` (host-binutils precedent already used by the bootstrap recipe). |
| `PROTOCOL.json` | Read-only frozen contract (Main's; do not edit unilaterally). |

Producer invocation (outputs land **only** under the explicit `--out`
parameter; the source directory is never an output; existing deliverables
without the producer's ownership marker are refused, never overwritten;
failure logs/objects are preserved under `$OUT/build`):

```bash
bash FloeAndroid/core/linuxruntime/native-build/guest-resolver/build-guest-resolver.sh \
  --out <artifact-dir>
```

Emitted: `libnss_floe.so.2` + `libnss_floe.so.2.sha256` (sha256sum-style
sidecar) + `manifest.json` (the frozen `manifestSchema`: deterministic JSON,
sorted UTF-8 source list with per-file hashes, `sourceTreeSha256` over the
sorted `"<sha256>  <path>\n"` lines, toolchain identity from the existing
pin, binary hash/bytes, `minimumLoadAlignment`, exact exports; **no**
timestamps, private build paths, devices, credentials or raw logs).
Measured producer evidence (scratch verification, 2026-10-22): two runs
produce byte-identical binary and manifest; the binary is ELF64 AArch64 DYN
with SONAME `libnss_floe.so.2`, four `FUNC GLOBAL DEFAULT` exports and only
those, zero `DT_NEEDED`, all `PT_LOAD` alignments 0x4000 (16 KiB). The
authoritative producer run and asset staging remain Main's serialized step;
this lane ships source + recipe, not the shipped binary.

## ABI facts verified against primary inputs (not memory)

* `enum nss_status { TRYAGAIN=-2, UNAVAIL=-1, NOTFOUND=0, SUCCESS=1,
  RETURN=2 }` and `struct gaih_addrtuple { next; name*; family; addr[4];
  scopeid }` from the glibc `<nss.h>` shipped inside the pinned Zig
  (`lib/libc/include/generic-glibc/nss.h`); the same struct diff-verified
  byte-identical between glibc 2.28 and the guest's 2.36 — so one layout
  serves the declared symbol floor and the pinned rootfs.
* `gethostbyname4_r` result convention from glibc 2.36
  `sysdeps/posix/getaddrinfo.c`: tuples are constructed **inside the caller
  buffer**, `next` is a real pointer with the last entry NULL; the first
  tuple's `name` is consumed for `AI_CANONNAME`; the buffer-growth retry
  fires only on exactly `NSS_STATUS_TRYAGAIN + errno ERANGE +
  h_errno NETDB_INTERNAL` (which is what this module returns when the
  caller buffer is too small).
* `gethostbyname3_r` is called by `getaddrinfo` with `ttlp == NULL` and
  `canonp` non-NULL; legacy `gethostbyname3_r(3)` callers pass both — both
  outputs are filled only when present. `gethostbyname2_r` may be invoked
  with the 3_r argument list (glibc documents the extras as ignored trailing
  args; the aarch64 calling convention makes that safe).

## Wire behaviour (per PROTOCOL.json; implementation notes)

* AF_UNIX `SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC` to the fixed path
  `/run/floe-dns/s` — no abstract socket, no port, nothing path-configurable
  (env/config/model cannot influence it).
* One transaction per connection: `FDN1` + u16BE length + raw DNS message
  (A or AAAA, RD=1, QDCOUNT=1), then exactly one framed response is read and
  the connection is closed. Length bounds 12..4096; anything else is a
  refusal, not a retry.
* One monotonic 3500 ms absolute deadline spans connect + every
  poll/send/recv of a logical query (`_gethostbyname4_r` issues its A and
  then its AAAA sequentially inside the same deadline; never threads, never
  overlap beyond that).
* EINTR short-IO/EOF handled; `SIGPIPE` suppressed with `MSG_NOSIGNAL`
  (never a process-wide signal handler change).
* Response validation is strict: ID must match the request, QR/opcode fixed,
  the echoed question must equal the query name/type/class, and every answer
  owner must lie on the validated CNAME chain (bounded: 8 pointer jumps,
  8 CNAME hops, 64 walked answers, 16 collected addresses per family,
  names ≤ 253). Compression pointers must refer strictly backwards, so
  traversal terminates by construction.
* Honest refusals, **no fallback of any kind**:
  * transport/offline/SERVFAIL/REFUSED → `UNAVAIL` + `h_errno TRY_AGAIN`
    (getaddrinfo surfaces EAI_AGAIN; `files` still serves `/etc/hosts`,
    so unrelated local commands keep working offline);
  * NXDOMAIN → `NOTFOUND` + `HOST_NOT_FOUND`; no matching records →
    `NOTFOUND` + `NO_DATA`;
  * unknown frame / malformed / non-matching reply → `UNAVAIL` +
    `NO_RECOVERY`;
  * never a host resolver call, never a raw DNS attempt, never a
    fabricated positive record. `nsswitch.conf` must remain
    `hosts: files floe` with **no `dns` tail** (the facilities lane owns
    the bind).

## Coverage boundary — honest scope (do not overstate this)

* Served: anything going through the guest glibc NSS path —
  `getaddrinfo`/`gethostbyname*`: Python `socket.getaddrinfo`/urllib/requests,
  Node's default `dns.lookup`, curl/libcurl, apt, pip, npm install, etc.
* **Not** served (and never will be by an NSS module): clients with their
  own resolver that bypass NSS — Node `dns.resolve*`/c-ares, dnspython,
  `dig`/`host`, raw DNS-over-UDP/TCP sockets, JVM custom resolvers. They
  are simply not NSS users; the contract explicitly forbids claiming
  universal interception, and this package deliberately does **not** expand
  into a PRoot syscall redirector to catch them.
* Numeric literals (`127.0.0.1`, IPv6 text) are short-circuited by glibc's
  digits-dots path before any NSS module runs — expected behaviour, not a
  leak.
* Reverse (`gethostbyaddr`) lookups are deliberately not exported: the
  bridge contract is forward A/AAAA only.
* `gethostbyname*_r` is reentrant by construction: zero global mutable
  state, zero threads, zero background work, nothing retained across calls.

## Relationship to the superseded draft

An earlier facilities-lane draft was written against the pre-frozen loopback
`/etc/floe-dns-bridge` "127.0.0.1:port + nonce over UDP" design, which Main
rejected (high-port/network dependency, unauthenticated UDP, wrong
`enum nss_status` SUCCESS value, raw-syscall asm with a broken register
declaration, no `_gethostbyname{,3,4}_r`, no ERANGE protocol, no deadline
enforcement). This module is the canonical implementation against the
frozen v1 protocol; the draft contributes nothing byte-wise here and has
been retired from the product source tree.

## Licensing

Floe-authored MPL-2.0 source; compiled against the glibc public headers
bundled with the pinned Zig (LGPL-2.1-or-later **with** the glibc header
exception — headers are build-time inputs; no header text is copied into
this module); linked with the NDK's llvm `ld.lld`/`llvm-readelf` as build
host tools. Per-component table and corresponding-source bindings:
see `../../THIRD_PARTY.md` and `FloeAndroid/scripts/produce-corresponding-source.py`
(`--guest-resolver-dir/--guest-resolver-manifest`).
