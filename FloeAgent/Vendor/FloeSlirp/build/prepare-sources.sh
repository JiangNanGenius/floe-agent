#!/bin/zsh
# Extract + verify pinned sources into $SRC, apply the local libslirp patch.
set -eu
. "${0:A:h}/env.sh"
mode="${1:-all}"
[[ "$mode" == all || "$mode" == --glib-only ]] || die "usage: prepare-sources.sh [--glib-only]"

mkdir -p "$SRC" "$BUILDS" "$STAGE" "$PKGCACHE/packagecache" "$LOGS"

verify() { # file expected-sha256
  local got
  got=$(shasum -a 256 "$1" | cut -d' ' -f1)
  [[ "$got" == "$2" ]] || die "sha256 mismatch for $1: got $got want $2"
  log "verified $1"
}

# Pinned digests (GNOME publishes the glib one; wrap hashes come from glib's own wrap files;
# libslirp digests recorded from the identical googlesource/gitlab trees)
verify "$DOMAIN/vendor/libslirp-4.9.7-googlesource.tar.gz" 4c34ed66c466daab0411bc50529567cfd1b9c30559db5ffbda41e54cbe36b030
verify "$DOMAIN/vendor/libslirp-4.9.7-gitlab.tar.gz"        d2567fa06a6357c7755d61c67293b2c0bf069b3f2173bde6b76cf768529a1938
verify "$DOMAIN/vendor/glib-2.90.1.tar.xz"                  93c941aa17d5eb1d53fe838365f29a8b4e539c222a256d974ec8f30fc413e396
verify "$DOMAIN/vendor/proxy-libintl-0.5.tar.gz"            f7a1cbd7579baaf575c66f9d99fb6295e9b0684a28b095967cfda17857595303
verify "$DOMAIN/vendor/libffi-3.5.2.tar.gz"                 f3a3082a23b37c293a4fcd1053147b371f2ff91fa7ea1b2a52e335676bac82dc
verify "$DOMAIN/vendor/libffi_3.5.2-1_patch.zip"            1ee3035d92e4df3541d0b2b8d192d2fa183b46e4a3d68c00d8f71ede354bee74
verify "$DOMAIN/vendor/pcre2-10.46.tar.bz2"                 15fbc5aba6beee0b17aecb04602ae39432393aba1ebd8e39b7cabf7db883299f
verify "$DOMAIN/vendor/pcre2_10.46-1_patch.zip"             761d16c89b9c13812842916b7ee970650ee7c1810f83bc567351faf7365b66be
verify "$DOMAIN/vendor/zlib-1.3.1.tar.gz"                   9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
verify "$DOMAIN/vendor/zlib_1.3.1-1_patch.zip"              e79b98eb24a75392009cec6f99ca5cdca9881ff20bfa174e8b8926d5c7a47095

# meson packagecache (meson re-hashes on use; pre-staged for offline reproducibility)
mkdir -p "$PKGCACHE/packagecache"
cp -f "$DOMAIN"/vendor/{libffi-3.5.2.tar.gz,libffi_3.5.2-1_patch.zip,pcre2-10.46.tar.bz2,pcre2_10.46-1_patch.zip,zlib-1.3.1.tar.gz,zlib_1.3.1-1_patch.zip} "$PKGCACHE/packagecache/"

# Extract libslirp (flat googlesource archive) into patched tree
if [[ "$mode" != --glib-only ]]; then
SLIRP_TREE="$SRC/libslirp-$SLIRP_VER"
if [[ ! -d "$SLIRP_TREE" ]]; then
  mkdir -p "$SLIRP_TREE"
  tar xzf "$DOMAIN/vendor/libslirp-4.9.7-googlesource.tar.gz" -C "$SLIRP_TREE"
  log "extracted libslirp-$SLIRP_VER"
fi
if [[ ! -f "$SLIRP_TREE/.floe-patched" ]]; then
  (cd "$SLIRP_TREE" && patch -p1 --forward < "$DOMAIN/patches/0001-floe-ios-hardening.patch") || die "libslirp patch failed"
  touch "$SLIRP_TREE/.floe-patched"
  log "applied 0001-floe-ios-hardening.patch"
fi

if [[ ! -f "$SLIRP_TREE/.floe-host-hooks" ]]; then
  (cd "$SLIRP_TREE" && patch -p1 --forward < "$DOMAIN/patches/0003-libslirp-floe-host-hooks.patch") || die "libslirp host-hooks patch failed"
  touch "$SLIRP_TREE/.floe-host-hooks"
fi
fi

# Extract glib
GLIB_TREE="$SRC/glib-$GLIB_VER"
if [[ ! -d "$GLIB_TREE" ]]; then
  tar xJf "$DOMAIN/vendor/glib-2.90.1.tar.xz" -C "$SRC"
  log "extracted glib-$GLIB_VER"
fi
if [[ ! -f "$GLIB_TREE/.floe-patched" ]]; then
  (cd "$GLIB_TREE" && patch -p1 --forward < "$DOMAIN/patches/0002-glib-embedded-no-test-subprocess.patch") || die "glib patch failed"
  touch "$GLIB_TREE/.floe-patched"
  log "applied 0002-glib-embedded-no-test-subprocess.patch (same source for all 3 platforms)"
fi
# Use the pinned, supplied proxy-libintl source instead of an implicit Git clone.
if [[ ! -d "$GLIB_TREE/subprojects/proxy-libintl-0.5" ]]; then
  mkdir -p "$GLIB_TREE/subprojects/proxy-libintl-0.5"
  tar xzf "$DOMAIN/vendor/proxy-libintl-0.5.tar.gz" --strip-components=1 -C "$GLIB_TREE/subprojects/proxy-libintl-0.5"
fi

# seed the wrap package cache where meson looks by default (source-tree
# subprojects/packagecache; meson re-verifies the wrap-recorded sha256)
mkdir -p "$GLIB_TREE/subprojects/packagecache"
cp -f "$DOMAIN"/vendor/{libffi-3.5.2.tar.gz,libffi_3.5.2-1_patch.zip,pcre2-10.46.tar.bz2,pcre2_10.46-1_patch.zip,zlib-1.3.1.tar.gz,zlib_1.3.1-1_patch.zip} "$GLIB_TREE/subprojects/packagecache/"

log "prepare-sources complete"
