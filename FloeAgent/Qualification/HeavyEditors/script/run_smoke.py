#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Run the exported, task-owned native host without touching any Simulator."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--workspace-name", required=True)
parser.add_argument("--kind", choices=("gis", "score", "font"))
args = parser.parse_args()
if not re.fullmatch(r"Workspace-[A-Za-z0-9-]+", args.workspace_name):
    parser.error("Use a task-owned Workspace-<name> directory")
repository = Path(__file__).resolve().parents[4]
workspace = repository / "Local/Private/heavy-editors-20261108" / args.workspace_name
workspace.mkdir(exist_ok=False)
executable = repository / "Local/Artifacts/heavy-editors-20261108/FloeHeavyEditorsQA.app/Contents/MacOS/FloeHeavyEditorsQA"
command = [str(executable), "--workspace", str(workspace), "--smoke-plans", str(repository / "FloeAgent/Modules")]
if args.kind:
    command.extend(("--smoke-kind", args.kind))
with (workspace / "host-process.log").open("w") as log:
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    (workspace / "Process.json").write_text(json.dumps({"pid": process.pid, "executable": str(executable), "mode": "independent native host smoke"}) + "\n")
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        result_file = workspace / "SmokeResult.json"
        if result_file.exists():
            result = json.loads(result_file.read_text())
            print(json.dumps({"success": result["success"], "editors": [(item["kind"], item["revision"], item["exportCount"]) for item in result["editors"]], "error": result["error"], "evidence": str(result_file.relative_to(repository))}, ensure_ascii=False))
            raise SystemExit(0 if result["success"] else 1)
        if process.poll() is not None:
            raise SystemExit("Native host exited " + str(process.returncode))
        time.sleep(0.25)
    raise SystemExit("Smoke timed out; host and original evidence preserved")
