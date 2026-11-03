#!/bin/sh
set -eu
[ "$#" = 5 ] || { echo 'usage: build-wrapper.sh dotnet csc.dll net8-reference-directory MillSimSharp.dll output-directory' >&2; exit 64; }
runner=$1
compiler=$2
references=$3
core=$4
output=$5
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ -x "$runner" ] && [ -f "$compiler" ] && [ -d "$references" ] && [ -f "$core" ] || exit 65
mkdir -p "$output"
set -- -nologo -target:exe -langversion:latest -nullable:enable -optimize+ -deterministic+ "-out:$output/CADStockTrialHost.dll"
for reference in "$references"/*.dll; do set -- "$@" "-r:$reference"; done
"$runner" "$compiler" "$@" "-r:$core" "$source_dir/CADStockTrialHost.cs"
cp "$core" "$output/MillSimSharp.dll"
printf '%s\n' '{"runtimeOptions":{"tfm":"net8.0","framework":{"name":"Microsoft.NETCore.App","version":"8.0.33"}}}' > "$output/CADStockTrialHost.runtimeconfig.json"
