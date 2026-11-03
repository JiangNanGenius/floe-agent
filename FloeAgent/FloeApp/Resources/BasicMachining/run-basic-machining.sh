#!/bin/sh
# Reviewed task resource adapter. Execution uses existing exec.shell/jobs on the selected Mac Bridge.
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export DOTNET_PROCESSOR_COUNT=2 DOTNET_gcServer=0 DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_MULTILEVEL_LOOKUP=0
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || { echo 'Only the selected arm64 Mac execution target is supported' >&2; exit 64; }
[ "$#" = 2 ] || exit 64
op=$1
input_sha=$2
case "$op" in BasicMachining/????????-????-????-????-????????????) ;; *) exit 64;; esac
case "$op" in *[!A-Za-z0-9/-]*) exit 64;; esac
[ "${#input_sha}" = 64 ] || exit 64
case "$input_sha" in *[!0-9a-f]*) exit 64;; esac
root=$(pwd -P)
support="$root/$op/support"
cache="$root/.floe-env/basic-machining/0.2.0"
runtime="$cache/runtime-8.0.33"
backend="$cache/backend"
for rel in .floe-env .floe-env/basic-machining .floe-env/basic-machining/0.2.0 "$op" "$op/support"; do
 [ ! -L "$root/$rel" ] || { echo 'Resource symlink refused' >&2; exit 65; }
done
hash_file() { actual=$(shasum -a 256 "$1"); actual=${actual%% *}; [ "$actual" = "$2" ] || { echo "Resource digest mismatch: ${1##*/}" >&2; exit 65; }; }
validate_runtime() {
 [ -d "$runtime" ] && [ ! -L "$runtime" ] && [ -x "$runtime/dotnet" ] || return 1
 [ -z "$(find "$runtime" -type l -print -quit)" ] || return 1
 (cd "$runtime" && shasum -a 256 -c "$support/runtime-SHA256SUMS" >/dev/null) || return 1
 "$runtime/dotnet" --list-runtimes | /usr/bin/awk '$1=="Microsoft.NETCore.App" && $2=="8.0.33" {found=1} END {exit !found}'
}
validate_backend() {
 [ -d "$backend" ] && [ ! -L "$backend" ] || return 1
 [ -z "$(find "$backend" -type l -print -quit)" ] || return 1
 hash_file "$backend/BACKEND_SHA256SUMS" 8145fb2a8cef1c6d75be3ae54fe10598166aa93b27a036c3ed2b3368ee30134b
 (cd "$backend" && shasum -a 256 -c BACKEND_SHA256SUMS >/dev/null)
}
hash_file "$root/$op/input/request.json" "$input_sha"
hash_file "$support/runtime-SHA256SUMS" dadef426a6c034f1dbf3dc36f117f108fc2ad1ffa9fea62b0e292ef1a14ad09d

validate_runtime && validate_backend || { echo 'Prepare the selected environment first; no host runtime fallback was attempted' >&2; exit 65; }
echo 'Basic machining: computing fixed-Z stock removal'
exec "$runtime/dotnet" "$backend/CADStockTrialHost.dll" "$root" "$op/input/request.json" "$op/output" "$input_sha"
