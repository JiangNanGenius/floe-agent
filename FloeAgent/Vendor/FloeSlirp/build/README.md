# Static dependency rebuild

`prepare-sources.sh` verifies supplied archives, prepares source trees and
applies recorded patches. `build-platform.sh` builds/stages one platform.
`assemble_xcframework.py` merges the four static components and packages three
arm64 platforms. See the parent README for the complete recipe.

`env.sh` derives source paths and supports `FLOE_SLIRP_CACHE`, `MESON`, `NINJA`,
`PKG_CONFIG`, `PYTHON` and `JOBS` overrides. The cache is separate from source
and other active builds; six compiler jobs are the default. Generated objects,
source preparation and logs stay in that cache. Source may contain spaces;
use a space-free cache for pkg-config compatibility.

`gen-cross.sh` selects the SDK with `xcrun` for C, C++, Objective-C and archive
tools, preserves target/sysroot flags alongside feature defines, and disables
configure-time `pipe2`/`dup3` assumptions on older target OSes. macOS targets
15.0, and both iOS platforms target 15.0.

`stage-glib.py` exports GLib core, PCRE2 without JIT, proxy-libintl, and their
headers/pkg-config metadata. GObject/GIO, libffi and zlib are not linked into
this stack. `strip-exec-glib.sh` removes process-spawn archive members from
the iOS delivery and fails if that transformation cannot be verified. Host
process execution is also disabled in libslirp itself.

The smoke source is supplied at `../smoke/slirp_smoke.c`. Consumers require
resolv, iconv, m and objc, Foundation/CoreFoundation, and macOS-only AppKit/Carbon;
the engine's Package.swift records those settings. `audit.sh` inspects linked
smoke images for forbidden imports. iOS and Simulator images are not launched.

For library-only changes, retain verified GLib staging and use `slirp-only`.
After source, patch or configuration changes, assemble a new output and update
manifests/provenance through explicit write commands, then run read-only checks.
Checks never update hashes or substitute artifacts to hide a mismatch.
