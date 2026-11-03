# Root capture helper notice

The optional Full-only root capture feature executes one fixed helper:
`tcpdump-v1`, built from tcpdump 4.99.5 and libpcap 1.10.5. The helper is not
downloaded at runtime, is not embedded in the Play distribution, and is not
accepted from an arbitrary path or URL.

tcpdump and libpcap are distributed under the BSD license. The upstream
license texts are reproduced verbatim in `tcpdump-LICENSE` and
`libpcap-LICENSE`. Copyright and redistribution conditions remain those of the
upstream projects; Floe does not relicense either component.

The helper also contains the Floe-authored MPL-2.0 capture guard
(`scripts/root-capture/guard/`, applied with
`scripts/root-capture/patches/0001-tcpdump-install-guard.patch`). The guard is
not a separate component or download: it is compiled into the same pinned PIE
and enforces parent-pipe liveness, a monotonic deadline and the output byte
budget independently of the Java root server. Its exact source/header/patch
hashes are embedded in the ELF and recorded in the manifest; an unguarded
helper is rejected by the verifier, stager and runtime manifest check.

The Full APK ships the executable as
`lib/arm64-v8a/libfloecapture_helper.so` plus the digest/source manifest
`assets/root-capture/helper.json`. The root server binds the packaged bytes to
the installed, signature-verified Floe APK and verifies the SHA-256 before
execution. It prefers the package-manager extracted
`nativeLibraryDir/libfloecapture_helper.so` when that copy is inside the
verified package's own code directory and is executable; otherwise it
installs the exact APK entry under the root-owned, non-shell-writable
`/data/local/floe-capture/helper/<sha256>/tcpdump` (0700 directories, 0500
binary, validated no-symlink ancestry) and executes only that digest-bound
path. Capture output lives under the protected
`/data/local/floe-capture/work` tree, never `/data/local/tmp`. The App's own
preflight checks the same digest; a missing or mismatched artifact leaves root
capture unavailable rather than falling back to an unchecked binary.
