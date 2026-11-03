#!/bin/sh
# Uses the existing environment-owned .NET preparation. No new execution route or global SDK.
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export DOTNET_PROCESSOR_COUNT=1 DOTNET_gcServer=0 DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_MULTILEVEL_LOOKUP=0
[ "$#" = 2 ] || exit 64
op=$1
input_sha=$2
case "$op" in BasicMachining/????????-????-????-????-????????????) ;; *) exit 64;; esac
case "$op" in *[!A-Za-z0-9/-]*) exit 64;; esac
[ "${#input_sha}" = 64 ] || exit 64
case "$input_sha" in *[!0-9a-f]*) exit 64;; esac
root=$(pwd -P)
support="$root/$op/support"
hash_file() { actual=$(shasum -a 256 "$1"); actual=${actual%% *}; [ "$actual" = "$2" ] || { echo "Resource digest mismatch: ${1##*/}" >&2; exit 65; }; }
hash_file "$support/prepare-basic-machining.sh" 3b0d61d965fbf871bbdb699975aaea63674b5dfd0a5858e70c5817519782c255
/bin/sh "$support/prepare-basic-machining.sh" "$op" "$input_sha"
runtime="$root/.floe-env/basic-machining/0.2.0/runtime-8.0.33"
cache="$root/.floe-env/basic-machining/multi-axis-preview-0.1.2"
backend="$cache/backend"
for rel in .floe-env .floe-env/basic-machining .floe-env/basic-machining/multi-axis-preview-0.1.2 "$op" "$op/support"; do [ ! -L "$root/$rel" ] || exit 65; done
hash_file "$support/multi-axis-preview-backend-0.1.2.zip" 037850365248becbe34f97213967f41ca4313758ebed6fd38386c45bbc8fddc3
mkdir -p "$cache"
stage="$backend.pending-${op##*/}"
[ ! -e "$stage" ] || { echo 'Previous preparation evidence preserved; start a new operation' >&2; exit 65; }
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
mkdir "$stage"
/usr/bin/unzip -q "$support/multi-axis-preview-backend-0.1.2.zip" -d "$stage"
hash_file "$stage/BACKEND_SHA256SUMS" 6c96354ef1562f979e6cb42836ace876c4058c051abc1bc3a8f6a5abb815038a
(cd "$stage" && shasum -a 256 -c BACKEND_SHA256SUMS >/dev/null)
if [ ! -e "$backend" ]; then
 set +e
 "$runtime/dotnet" "$stage/CADMultiAxisPreviewHost.dll" --promote-directory "$stage" "$backend"
 promoted=$?
 set -e
 [ "$promoted" = 0 ] || [ "$promoted" = 2 ] || exit "$promoted"
fi
[ -d "$backend" ] && [ ! -L "$backend" ] && [ -z "$(find "$backend" -type l -print -quit)" ] || exit 65
hash_file "$backend/BACKEND_SHA256SUMS" 6c96354ef1562f979e6cb42836ace876c4058c051abc1bc3a8f6a5abb815038a
(cd "$backend" && shasum -a 256 -c BACKEND_SHA256SUMS >/dev/null)
hash_file "$root/$op/input/request.json" "$input_sha"
printf '{"schema":"floe.multi-axis-preview-environment.v1","operationID":"%s","requestSHA256":"%s","runtimeVersion":"8.0.33","coreSHA256":"3405064ebc312dbe38bacfdfb0eea8015354447ae3f749e4089cb8f584d1351d","wrapperSHA256":"bf762f9f104c15608f617558dbe7db99cf6efb79786bf54254d53ad41d3414b5","actualOS":"Darwin","architecture":"arm64"}\n' "${op##*/}" "$input_sha" > "$root/$op/environment-ready.pending.json"
mv "$root/$op/environment-ready.pending.json" "$root/$op/environment-ready.json"
echo 'Multi-axis stock preview: selected Mac environment prepared'
