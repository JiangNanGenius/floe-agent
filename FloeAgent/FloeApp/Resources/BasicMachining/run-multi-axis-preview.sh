#!/bin/sh
# Existing jobs.submit -> exec.shell on the explicitly selected same-Mac environment only.
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export DOTNET_PROCESSOR_COUNT=1 DOTNET_gcServer=0 DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_MULTILEVEL_LOOKUP=0
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || exit 64
[ "$#" = 2 ] || exit 64
op=$1
input_sha=$2
case "$op" in BasicMachining/????????-????-????-????-????????????) ;; *) exit 64;; esac
case "$op" in *[!A-Za-z0-9/-]*) exit 64;; esac
[ "${#input_sha}" = 64 ] || exit 64
case "$input_sha" in *[!0-9a-f]*) exit 64;; esac
root=$(pwd -P)
support="$root/$op/support"
runtime="$root/.floe-env/basic-machining/0.2.0/runtime-8.0.33"
backend="$root/.floe-env/basic-machining/multi-axis-preview-0.1.2/backend"
hash_file() { actual=$(shasum -a 256 "$1"); actual=${actual%% *}; [ "$actual" = "$2" ] || { echo "Resource digest mismatch: ${1##*/}" >&2; exit 65; }; }
for rel in .floe-env .floe-env/basic-machining .floe-env/basic-machining/0.2.0 .floe-env/basic-machining/multi-axis-preview-0.1.2 "$op" "$op/support"; do [ ! -L "$root/$rel" ] || exit 65; done
[ -d "$runtime" ] && [ -x "$runtime/dotnet" ] && [ ! -L "$runtime" ] && [ -z "$(find "$runtime" -type l -print -quit)" ] || { echo 'Prepare this environment first; no host runtime fallback' >&2; exit 65; }
hash_file "$support/runtime-SHA256SUMS" dadef426a6c034f1dbf3dc36f117f108fc2ad1ffa9fea62b0e292ef1a14ad09d
(cd "$runtime" && shasum -a 256 -c "$support/runtime-SHA256SUMS" >/dev/null)
[ -d "$backend" ] && [ ! -L "$backend" ] && [ -z "$(find "$backend" -type l -print -quit)" ] || exit 65
hash_file "$backend/BACKEND_SHA256SUMS" 6c96354ef1562f979e6cb42836ace876c4058c051abc1bc3a8f6a5abb815038a
(cd "$backend" && shasum -a 256 -c BACKEND_SHA256SUMS >/dev/null)
hash_file "$root/$op/input/request.json" "$input_sha"
echo 'Multi-axis stock preview: computing bounded XYZ/IJK motion and material envelopes'
exec "$runtime/dotnet" "$backend/CADMultiAxisPreviewHost.dll" "$root" "$op/input/request.json" "$op/output" "$input_sha"
