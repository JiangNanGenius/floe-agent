#!/usr/bin/env python3
"""Execute the real FloeCPythonBridge runner against isolated managed roots.

The bridge string is extracted from FloeCPythonBridge.m at run time, so this
harness exercises the code that ships rather than a hand-written copy. Each
step runs the runner exactly like the bridge does: fresh globals, shared
interpreter and shared ``sys.modules``.

Scenarios:
  * two managed environments in sequence: a module cached from the previous
    environment must not shadow the active one (Build191's importlib.metadata
    0.9.0 / tabulate 0.10.0 split);
  * the writable site-packages path is honored even before the first install
    created it, and a later install is visible to the next run;
  * a module pinned in ``sys.modules`` from a retired managed root is evicted,
    while a bundled-root module stays.

This is a desktop CPython harness, not iOS acceptance: the app uses its own
embedded CPython and device verification belongs to the user.
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
import tempfile
import textwrap

# __file__ lives in FloeAgent/scripts/tests -> repo root is three levels up.
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
BRIDGE = os.path.join(REPO_ROOT, "FloeAgent", "FloeApp", "Execution", "FloeCPythonBridge.m")

failures: list[str] = []
checks = 0


def check(condition: bool, label: str) -> None:
    global checks
    checks += 1
    if condition:
        print(f"PASS  {label}")
    else:
        print(f"FAIL  {label}")
        failures.append(label)


def extract_runner(source: str) -> str:
    start = source.index("static const char *runner =")
    end = source.index("PyObject *execution =", start)
    region = source[start:end]
    parts = re.findall(r'"((?:[^"\\]|\\.)*)"', region)
    joined = "".join(parts)
    return (joined.replace("\\n", "\n").replace('\\"', '"').replace("\\\\", "\\"))


def site_packages(root: str) -> str:
    return os.path.join(root, "usr", "lib", "floe-python", "site-packages")


def write_distribution(root: str, package: str, version: str, marker: str) -> str:
    directory = os.path.join(site_packages(root), package)
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, "__init__.py"), "w", encoding="utf-8") as handle:
        handle.write(f'VERSION = "{marker}"\n')
    # CPython 3.9's stdlib metadata finder matches the underscore form of the
    # distribution directory/name; pip's normalized dash form needs 3.10+. The
    # app ships a newer CPython, so the harness uses the portable underscore
    # spelling and documents the version difference.
    dist_info = os.path.join(site_packages(root), f"{package}-{version}.dist-info")
    os.makedirs(dist_info, exist_ok=True)
    with open(os.path.join(dist_info, "METADATA"), "w", encoding="utf-8") as handle:
        handle.write(f"Metadata-Version: 2.1\nName: {package}\nVersion: {version}\n")
    with open(os.path.join(dist_info, "RECORD"), "w", encoding="utf-8") as handle:
        handle.write("")
    return directory


def run_runner(runner: str, pythonpath: list[str], script: str, working_directory: str) -> dict:
    environment = {"PYTHONPATH": os.pathsep.join(pythonpath)}
    context = {"environment": environment, "workingDirectory": working_directory}
    namespace = {
        "__builtins__": __builtins__,
        "_floe_context_json": json.dumps(context),
        "_floe_script": script,
        "_floe_input_json": "null",
        "_floe_timeout": 30.0,
        "_floe_cap": 262144,
        "_floe_is_cancelled": lambda: False,
    }
    exec(compile(runner, "<floe-cpython-runner>", "exec"), namespace, namespace)
    return json.loads(namespace["_floe_result"])


PROBE = textwrap.dedent(
    """
    import importlib.metadata as metadata
    import demo_pkg
    print("file=" + (getattr(demo_pkg, "__file__", "") or ""))
    print("marker=" + getattr(demo_pkg, "VERSION", "?"))
    print("version=" + metadata.version("demo_pkg"))
    """
)


def main() -> int:
    with open(BRIDGE, encoding="utf-8") as handle:
        runner = extract_runner(handle.read())
    check(len(runner) > 4000, f"runner extracted from FloeCPythonBridge.m ({len(runner)} chars)")
    try:
        compile(runner, "<floe-cpython-runner>", "exec")
        check(True, "extracted runner compiles")
    except SyntaxError as error:  # pragma: no cover - reported as a failure
        check(False, f"extracted runner compiles ({error})")
        print("\n0 checks passed; runner unusable")
        return 1

    with tempfile.TemporaryDirectory(prefix="floe-python-runner-") as temp:
        base = os.path.join(temp, "base")
        env_a = os.path.join(temp, "env-a")
        env_b = os.path.join(temp, "env-b")
        env_c = os.path.join(temp, "env-c")
        working = os.path.join(temp, "workspace")
        os.makedirs(working, exist_ok=True)
        stale_root = write_distribution(env_a, "demo_pkg", "1.0.0", "env-a")
        write_distribution(base, "demo_pkg", "0.9.0", "bundled")

        first = run_runner(runner, [site_packages(env_a), site_packages(base)], PROBE, working)
        check(first.get("status") == "ok", f"first run status ok ({first.get('error', '')})")
        check(f"file={stale_root}" in first.get("stdout", ""), "first run resolves the writable environment")
        check("version=1.0.0" in first.get("stdout", ""), "first run metadata reports the writable version")

        # A module that survived from the retired environment while a different
        # writable root is active must be evicted by the next run.
        stale_file = os.path.join(stale_root, "__init__.py")
        module = type(sys)("demo_pkg")
        module.__file__ = stale_file
        module.VERSION = "env-a-stale"
        sys.modules["demo_pkg"] = module

        write_distribution(env_b, "demo_pkg", "2.0.0", "env-b")
        second = run_runner(runner, [site_packages(env_b), site_packages(base)], PROBE, working)
        check(second.get("status") == "ok", f"second run status ok ({second.get('error', '')})")
        check(f"file={site_packages(env_b)}" in second.get("stdout", ""),
              "retired-environment module was evicted and the active environment resolved")
        check("version=2.0.0" in second.get("stdout", ""), "metadata follows the active environment")

        # The writable root may not exist before the first install. Python skips
        # missing sys.path entries, and the directory must become visible to the
        # same persistent interpreter once it exists.
        missing = site_packages(env_c)
        check(not os.path.exists(missing), "writable install target starts absent")
        third = run_runner(runner, [missing, site_packages(base)], PROBE, working)
        check("version=0.9.0" in third.get("stdout", ""), "pre-install run falls back to the bundled copy")

        write_distribution(env_c, "demo_pkg", "3.0.0", "env-c")
        fourth = run_runner(runner, [missing, site_packages(base)], PROBE, working)
        check(fourth.get("status") == "ok", f"post-install run status ok ({fourth.get('error', '')})")
        check(f"file={missing}" in fourth.get("stdout", ""),
              "install into the previously missing writable root is visible to the next run")
        check("version=3.0.0" in fourth.get("stdout", ""), "metadata reports the newly installed version")

    print(f"\n{checks - len(failures)}/{checks} CPython runner checks passed "
          f"(python {sys.version.split()[0]})")
    if failures:
        print("FAILED: " + "; ".join(failures))
        return 1
    print("ALL CPYTHON RUNNER CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
