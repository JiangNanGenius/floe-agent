# FloeSlirp

Pinned static network-stack dependency for `FloeARM64Engine`: libslirp 4.9.7,
GLib 2.90.1 core, PCRE2 10.46 with JIT disabled, and proxy-libintl 0.5.
`FloeSlirpBinary` in `FloeAgent/Package.swift` supplies the three arm64 slices.
Engine C sources include `<slirp/libslirp.h>` and `<slirp/floe_host_net.h>`.

`PROVENANCE.json` binds the supplied upstream archives, license members, local
patches, rebuild sources/scripts, and delivered archives/headers. Full source
archives are under `vendor/`; `licenses/` contains byte-exact upstream texts.
The App bundles four generated `Licenses/FloeSlirp-*.txt` notices, including
the corresponding-source and relink instructions. libffi and zlib source
archives are retained for completeness and are not linked into this stack.
The stack notice reproduces all 58 libslirp source/header leading notices,
including the nine MIT permission grants and their copyright holders.

## Build and assemble

Use Xcode 27.2 (27B52), Python 3, Meson 1.12+, Ninja 1.13+, pkg-config and
zsh. Select a fresh, space-free build-cache path, separate from source and any
other active build. Keep the SDK `DEVELOPER_DIR` explicit.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export FLOE_SLIRP_CACHE="$HOME/Library/Caches/FloeSlirp-rebuild"
cd FloeAgent/Vendor/FloeSlirp
zsh build/prepare-sources.sh
zsh build/build-platform.sh macos
zsh build/build-platform.sh ios-device
zsh build/build-platform.sh ios-sim
python3 build/assemble_xcframework.py --staging-root "$FLOE_SLIRP_CACHE/staging" --output "$FLOE_SLIRP_CACHE/export/FloeSlirp.xcframework" --manifests-dir "$FLOE_SLIRP_CACHE/export/vendor"
zsh build/audit.sh macos
zsh build/audit.sh ios-device
zsh build/audit.sh ios-sim
```

The assembler requires a new output path and never removes an earlier
deliverable. Review the resulting library/platform identities and consumer
links before replacing the repository's XCFramework. Copy the generated
`SHA256SUMS-static` and `SHA256SUMS-xcframework` to `vendor/` with that new
framework, then explicitly regenerate and check its record:

```sh
python3 tools/generate_floeslirp_provenance.py --vendor-dir . --write PROVENANCE.json
python3 tools/generate_floeslirp_provenance.py --vendor-dir . --write PROVENANCE.json --check
python3 tools/generate_floeslirp_provenance.py --vendor-dir . --verify-staged
```

Published digests identify the delivered bytes. A private or modified rebuild
has its own digests. Never modify an immutable source tag or reuse an old
artifact's digest for new bytes. To modify a library, edit its unpacked source
under the separate cache's `src/` after preparation, rebuild, and replace the
entire XCFramework including headers in your own matching App source copy.

## Build profiles and source changes

- The macOS slice targets macOS 15.0; device and Simulator slices target
  iOS 15.0. Compiler and SDK paths are explicit for every language, including
  Objective-C. Configure profiles force the SDK-27 `pipe2`/`dup3` fallbacks.
- libslirp uses explicit O2 with assertions retained and
  `SLIRP_NO_HOST_EXEC`/`SLIRP_FLOE_HOST_HOOKS`. GLib test-subprocess entry points
  fail loudly; the iOS archives exclude process-spawn members. PCRE2's code
  emitter is not compiled.
- Source preparation verifies supplied archive hashes and applies recorded
  patches. The supplied proxy-libintl archive is extracted into the wrap
  directory. Build outputs and logs stay under the cache.
- `prepare-sources.sh --glib-only` and `build-platform.sh platform glib-only`
  prepare/build just GLib and its static dependencies. The `slirp-only` build
  mode reuses populated GLib staging, preserving its source/platform checks.
- `smoke/slirp_smoke.c` supplies the lifecycle, poll-mask and raw TCP smoke.
  A component smoke, artifact check or static link is separate from full App,
  physical-device and Apple review acceptance.

## App source and release freeze

Before freezing a new App source tag, generate notices with that exact tag
and regenerate the ordinary license inventory:

```sh
python3 tools/make_bundle_notices.py --app-source-tag vX.Y.Z
python3 tools/make_bundle_notices.py --app-source-tag vX.Y.Z --check
```

Use the actual unused App tag in place of `vX.Y.Z`. Release preflight checks
this binding before an archive; development placeholders cannot be used for
a release. All `--check` and `--verify-staged` operations are read-only. Keep
upstream license texts unchanged and retain the complete corresponding App
source, library sources, patches and relink route with the immutable tag.
