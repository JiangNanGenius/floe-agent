#!/bin/bash
# Explicit pinned compiler/runtime inputs; no package install, global SDK, or host fallback.
set -euo pipefail
[[ $# == 5 ]] || { echo 'runtime-dotnet csc.dll net8-ref-directory pinned-core.dll output-directory' >&2; exit 64; }
runtime_bin=$1
compiler_dll=$2
reference_dir=$3
core_dll=$4
output_dir=$5
source_dir=$(cd "$(dirname "$0")" && pwd -P)
[[ "$(/usr/bin/shasum -a 256 "$core_dll" | /usr/bin/awk '{print $1}')" == 3405064ebc312dbe38bacfdfb0eea8015354447ae3f749e4089cb8f584d1351d ]] || exit 65
export DOTNET_PROCESSOR_COUNT=1 DOTNET_gcServer=0 DOTNET_CLI_TELEMETRY_OPTOUT=1
mkdir -p "$output_dir"
cp "$core_dll" "$output_dir/MillSimSharp.dll"
references=()
for file in "$reference_dir"/*.dll; do references+=("-r:$file"); done
references+=("-r:$output_dir/MillSimSharp.dll")
for host in MultiAxisStockHost FixtureClearanceHost CADMultiAxisPreviewHost; do
 compiler_args=(-nologo -target:exe -langversion:latest -nullable:enable -optimize+ -deterministic+ "-out:$output_dir/$host.dll" "${references[@]}")
 if [[ $host == CADMultiAxisPreviewHost ]]; then compiler_args+=("-r:$output_dir/MultiAxisStockHost.dll" "-r:$output_dir/FixtureClearanceHost.dll"); fi
 "$runtime_bin" "$compiler_dll" "${compiler_args[@]}" "$source_dir/$host.cs"
 printf '%s\n' '{"runtimeOptions":{"tfm":"net8.0","framework":{"name":"Microsoft.NETCore.App","version":"8.0.33"},"rollForward":"Disable"}}' > "$output_dir/$host.runtimeconfig.json"
done
