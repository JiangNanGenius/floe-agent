#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
task_mode="${1:-run}"
task_qualification_root="$(cd "$(dirname "$0")/.." && pwd)"
task_repository_root="$(cd "$task_qualification_root/../../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
task_cache="$HOME/Library/Caches/CodexBuild/FloeHeavyEditors/shared-main/xcode-27B52/qualification-host"
task_private="$task_repository_root/Local/Private/heavy-editors-20261108"
task_artifacts="$task_repository_root/Local/Artifacts/heavy-editors-20261108"
task_workspace="$task_private/Workspace"
task_product="$task_artifacts/FloeHeavyEditorsQA.app"
mkdir -p "$task_private" "$task_artifacts" "$task_workspace"
case "$task_mode" in
  run|--verify|--logs|--debug|--build-only|--run-only|--sim-build) ;;
  *) echo 'usage: build_and_run.sh [run|--verify|--logs|--debug|--build-only|--run-only|--sim-build]' >&2; exit 2 ;;
esac
if [ "$task_mode" != --run-only ]; then
  xcodegen generate --spec "$task_qualification_root/project.yml" --project "$task_qualification_root" > "$task_private/generate-host.log" 2>&1
  task_scheme=FloeHeavyEditorsQA
  task_destination='platform=macOS,arch=arm64'
  if [ "$task_mode" = --sim-build ]; then task_scheme=FloeHeavyEditorsPadQA; task_destination='generic/platform=iOS Simulator'; fi
  task_build_log="$task_private/host-$task_scheme-$(date -u +%Y%m%dT%H%M%SZ).log"
  task_build_status=0
  python3 -B "$task_repository_root/Local/Private/shared-native-window/with_native_window.py" --label "heavy-editors-$task_scheme" -- \
    xcodebuild -project "$task_qualification_root/FloeHeavyEditorsQualification.xcodeproj" \
    -scheme "$task_scheme" -configuration Debug -destination "$task_destination" \
    -derivedDataPath "$task_cache" -jobs 2 CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS=-j2 build \
    > "$task_build_log" 2>&1 || task_build_status=$?
  cp "$task_build_log" "$task_private/host-$task_scheme-build.log"
  if [ "$task_build_status" -ne 0 ]; then exit "$task_build_status"; fi
  if [ "$task_mode" = --sim-build ]; then exit 0; fi
  python3 - "$task_cache/Build/Products/Debug/FloeHeavyEditorsQA.app" "$task_product" <<'PY'
from pathlib import Path
import shutil,sys
source,destination=map(Path,sys.argv[1:])
assert source.is_dir()
staging=destination.with_name(destination.name+'.staging')
assert not staging.exists(), 'Preserve previous staging for inspection'
shutil.copytree(source,staging,symlinks=True)
if destination.exists():
    previous=destination.with_name(destination.name+'.previous')
    assert not previous.exists(), 'Preserve previous exported host before replacement'
    destination.rename(previous)
staging.rename(destination)
PY
fi
if [ "$task_mode" = --build-only ]; then exit 0; fi
# Stop only this task's exported QA app; do not disturb a different checkout.
python3 - "$task_product/Contents/MacOS/FloeHeavyEditorsQA" <<'PY'
import os,signal,subprocess,sys
for line in subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines():
    fields=line.strip().split(None,1)
    if len(fields)==2 and fields[1]==sys.argv[1]:os.kill(int(fields[0]),signal.SIGTERM)
PY
if [ "$task_mode" = --debug ]; then
  lldb -- "$task_product/Contents/MacOS/FloeHeavyEditorsQA" --workspace "$task_workspace"
  exit 0
fi
/usr/bin/open -n "$task_product" --args --workspace "$task_workspace"
if [ "$task_mode" = --verify ]; then
  for task_attempt in {1..20}; do pgrep -x FloeHeavyEditorsQA >/dev/null && exit 0; sleep 0.1; done
  echo 'Qualification app did not remain running; inspect host logs.' >&2; exit 1
fi
if [ "$task_mode" = --logs ]; then /usr/bin/log stream --style compact --level info --predicate 'process == "FloeHeavyEditorsQA"'; fi
