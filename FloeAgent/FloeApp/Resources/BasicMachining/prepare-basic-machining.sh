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

mkdir -p "$cache"
id=${op##*/}
runtime_stage="$runtime.pending-$id"
backend_stage="$backend.pending-$id"
archive="$cache/runtime-8.0.33.pending-$id.tar.gz"
cleanup() { rm -rf "$runtime_stage" "$backend_stage"; rm -f "$archive"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
[ ! -e "$runtime_stage" ] && [ ! -e "$backend_stage" ] && [ ! -e "$archive" ] || { echo 'A previous preparation is preserved; use a new operation' >&2; exit 65; }
echo 'Preparing basic machining: verifying the pinned backend'
hash_file "$support/basic-machining-backend-0.2.0.zip" da659f9f0b52ea0c696d20f3fee5a1523c8bf3cdd174858872d147e29e403770
mkdir "$backend_stage"
/usr/bin/unzip -q "$support/basic-machining-backend-0.2.0.zip" -d "$backend_stage"
hash_file "$backend_stage/BACKEND_SHA256SUMS" 8145fb2a8cef1c6d75be3ae54fe10598166aa93b27a036c3ed2b3368ee30134b
(cd "$backend_stage" && shasum -a 256 -c BACKEND_SHA256SUMS >/dev/null)
if [ -e "$runtime" ]; then
 echo 'Preparing basic machining: verifying the managed runtime cache'
 validate_runtime || { echo 'The managed runtime cache failed verification; no host runtime fallback was attempted' >&2; exit 65; }
else
 echo 'Preparing basic machining: downloading .NET 8.0.33 (29.1 MB) into this environment'
 /usr/bin/curl --fail --location --silent --show-error --connect-timeout 15 --max-time 150 --max-filesize 29113192 --output "$archive" 'https://builds.dotnet.microsoft.com/dotnet/Runtime/8.0.33/dotnet-runtime-8.0.33-osx-arm64.tar.gz'
 [ "$(stat -f %z "$archive")" = 29113192 ] || exit 65
 hash_file "$archive" bb673780acf815e0e37e373397bc362cd4330f3f95e6b6d87f284c7c3739deae
 mkdir "$runtime_stage"
 /usr/bin/tar -xzf "$archive" -C "$runtime_stage"
 (cd "$runtime_stage" && shasum -a 256 -c "$support/runtime-SHA256SUMS" >/dev/null)
 set +e
 "$runtime_stage/dotnet" "$backend_stage/CADStockTrialHost.dll" --promote-directory "$runtime_stage" "$runtime"
 promoted=$?
 set -e
 [ "$promoted" = 0 ] || [ "$promoted" = 2 ] || exit "$promoted"
 validate_runtime || { echo 'Managed runtime promotion failed verification' >&2; exit 65; }
fi
if [ -e "$backend" ]; then
 validate_backend || { echo 'Managed backend cache failed verification' >&2; exit 65; }
else
 set +e
 "$runtime/dotnet" "$backend_stage/CADStockTrialHost.dll" --promote-directory "$backend_stage" "$backend"
 promoted=$?
 set -e
 [ "$promoted" = 0 ] || [ "$promoted" = 2 ] || exit "$promoted"
 validate_backend || exit 65
fi
echo 'Preparing basic machining: ready on the selected arm64 Mac'
printf '{"schema":"floe.basic-machining-environment.v1","operationID":"%s","requestSHA256":"%s","runtimeVersion":"8.0.33","coreSHA256":"3405064ebc312dbe38bacfdfb0eea8015354447ae3f749e4089cb8f584d1351d","wrapperSHA256":"3e8653b17d34a6786ee4a753660944c52172cff71e1f6ba431dc1de74b463cf9","actualOS":"Darwin","architecture":"arm64"}\n' "$id" "$input_sha" > "$root/$op/environment-ready.pending.json"
mv "$root/$op/environment-ready.pending.json" "$root/$op/environment-ready.json"
