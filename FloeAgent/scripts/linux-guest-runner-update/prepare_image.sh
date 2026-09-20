#!/usr/bin/env bash
# prepare_image.sh — fetch the pinned base component archive, verify every
# byte against the pinned digests, and replace ONLY the guest runner inside
# the whole-disk ext4 image via the repo's install-into-image.sh.
#
# Usage (Linux, root for the loop mount):
#   sudo bash prepare_image.sh --work DIR --image-dir DIR --runner BIN \
#        --script FloeAgent/LinuxGuest/image/floe-guest-init \
#        --repo DIR --base-url https://github.com/<repo>/releases/download/<tag>
#
# Required env (verified base pins):
#   BASE_ZIP, BASE_ZIP_BYTES, BASE_ZIP_SHA512, BASE_ZIP_SHA256
#   BASE_MANIFEST_SHA512, BASE_BBL_SHA512, BASE_KERNEL_SHA512, BASE_DISK_SHA512
#
# Outputs in --image-dir: bbl64.bin kernel-riscv64.bin disk.img manifest-base.json
# (the base manifest is kept as a record; the new manifest is written by the
# package step). Evidence goes to <work>/evidence/.
set -euo pipefail

die() { printf 'prepare_image: ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf 'prepare_image: %s\n' "$*"; }

work=""
image_dir=""
runner=""
script=""
repo=""
base_url=""
while [ $# -gt 0 ]; do
    case "$1" in
        --work) work="${2:-}"; shift 2 ;;
        --image-dir) image_dir="${2:-}"; shift 2 ;;
        --runner) runner="${2:-}"; shift 2 ;;
        --script) script="${2:-}"; shift 2 ;;
        --repo) repo="${2:-}"; shift 2 ;;
        --base-url) base_url="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$work" ] && [ -n "$image_dir" ] && [ -n "$runner" ] && [ -n "$repo" ] && [ -n "$base_url" ] \
    || die "--work --image-dir --runner --repo --base-url are required"
[ -f "$runner" ] || die "runner binary not found: $runner"
for var in BASE_ZIP BASE_ZIP_BYTES BASE_ZIP_SHA512 BASE_ZIP_SHA256 \
           BASE_MANIFEST_SHA512 BASE_BBL_SHA512 BASE_KERNEL_SHA512 BASE_DISK_SHA512; do
    [ -n "${!var:-}" ] || die "missing env $var"
done
for tool in curl unzip sha512sum sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done
mkdir -p "$work" "$image_dir" "$work/evidence"
evidence="$work/evidence"

check_sha512() { # check_sha512 <file> <expected> <label>
    local actual label="$3"
    actual="$(sha512sum "$1" | cut -d' ' -f1)"
    [ "$actual" = "$2" ] || die "$1 sha512 mismatch ($label): got $actual want $2"
    log "$1 sha512 verified ($label)"
}

# 1. download + verify the base archive (three independent checks).
zip_path="$work/$BASE_ZIP"
if [ ! -f "$zip_path" ]; then
    log "downloading $base_url/$BASE_ZIP"
    curl -fL --retry 3 --retry-delay 10 -o "$zip_path.part" "$base_url/$BASE_ZIP"
    mv "$zip_path.part" "$zip_path"
fi
[ "$(stat -c %s "$zip_path")" = "$BASE_ZIP_BYTES" ] || die "base zip size mismatch"
check_sha512 "$zip_path" "$BASE_ZIP_SHA512" "base archive"
[ "$(sha256sum "$zip_path" | cut -d' ' -f1)" = "$BASE_ZIP_SHA256" ] || die "base zip sha256 mismatch"
log "base zip sha256 verified"

# 2. extract and verify every member against the pinned base digests.
unzip -Z1 "$zip_path" | grep -v '/$' | LC_ALL=C sort > "$work/zip-members.txt"
expected_members="$(printf 'bbl64.bin\ndisk.img\nkernel-riscv64.bin\nmanifest.json\n')"
if [ "$(cat "$work/zip-members.txt")" != "$expected_members" ]; then
    die "base archive member set changed: $(tr '\n' ' ' < "$work/zip-members.txt")"
fi
cp "$work/zip-members.txt" "$evidence/zip-members.txt"
unzip -q -o "$zip_path" -d "$image_dir"
mv "$image_dir/manifest.json" "$image_dir/manifest-base.json"
check_sha512 "$image_dir/manifest-base.json" "$BASE_MANIFEST_SHA512" "base manifest"
check_sha512 "$image_dir/bbl64.bin" "$BASE_BBL_SHA512" "base bbl"
check_sha512 "$image_dir/kernel-riscv64.bin" "$BASE_KERNEL_SHA512" "base kernel"
check_sha512 "$image_dir/disk.img" "$BASE_DISK_SHA512" "base disk"
cp "$image_dir/disk.img" "$work/disk-base-copy.img"
sha512sum "$work/disk-base-copy.img" | tee "$evidence/disk-base-sha512.txt"

# 3. replace only /usr/local/bin/floe-exec (+ the optional init script).
inject_args=(--image "$work/disk-base-copy.img" --runner "$runner")
[ -n "$script" ] && inject_args+=(--script "$script")
bash "$repo/FloeAgent/LinuxGuest/image/install-into-image.sh" "${inject_args[@]}" \
    2>&1 | tee "$evidence/runner-injection.log"
grep -q 'installed' "$evidence/runner-injection.log" || die "runner injection did not report success"
grep -q "$(sha256sum "$runner" | cut -d' ' -f1)" "$evidence/runner-injection.log" \
    || die "injected runner hash does not match the built runner"

# 4. post-injection filesystem check + new disk digest, then swap into place.
e2fsck -fy "$work/disk-base-copy.img" >"$evidence/e2fsck-after-injection.log" 2>&1 || true
tail -3 "$evidence/e2fsck-after-injection.log"
mv "$work/disk-base-copy.img" "$image_dir/disk.img"
{
    sha512sum "$image_dir/disk.img"
    printf 'disk_bytes=%s\n' "$(stat -c %s "$image_dir/disk.img")"
} | tee "$evidence/disk-updated-sha512.txt"

# 5. the archive member set must stay exactly the base four files.
rm -f "$zip_path"
ls -la "$image_dir" | tee "$evidence/image-dir-listing.txt"
log "done: updated image in $image_dir, evidence in $evidence"
