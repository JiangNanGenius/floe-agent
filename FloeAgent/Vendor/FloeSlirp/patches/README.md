# Local source patches

Apply to the exact upstream archives in `vendor/`, through
`build/prepare-sources.sh` and the compile profiles in `build/gen-cross.sh`.
Patch digests are computed from actual files in `PROVENANCE.json`.

1. `0001-floe-ios-hardening.patch`: libslirp iOS resolver linkage and the
   `SLIRP_NO_HOST_EXEC` boundary. Host command execution is unavailable.
2. `0002-glib-embedded-no-test-subprocess.patch`: replaces GLib test-process
   trap paths with loud failures when `FLOE_GLIB_NO_TEST_SUBPROCESS` is defined.
   Assertions and ordinary logging remain. iOS process-spawn archive members
   are removed and checked by the separate build script.
3. `0003-libslirp-floe-host-hooks.patch`: versioned per-instance socket-admission,
   host address-family/NAT64 and resolver hooks, plus a bounded listen backlog.
   `SLIRP_FLOE_HOST_HOOKS` is required in the shipping profile. Admission covers
   actual outbound socket creation and inbound accept; full listeners stay
   polled so excess clients can be accepted and closed promptly. Initial add
   and guest-reset rule replay both use the same bounded listener capacity.

The network library receives ordinary Ethernet frames. Guest-visible address
families remain intact while supported host-side translation changes the native
socket family. The App's public ARM64 configuration ABI and reserved fields
are unchanged. These extensions do not add host JIT, downloaded native code,
TAP/VPN interfaces, entitlements or a broader default host listen surface.

Source and build changes require fresh artifacts, generated manifests, actual
consumer links and read-only provenance checks; do not reuse an old binary's
hash for a new build. App, physical-device and Apple review acceptance are
separate from this source/dependency record.
