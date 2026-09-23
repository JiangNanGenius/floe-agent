#!/usr/bin/env python3
"""qualify_runtime_templates.py — qualify a Floe Linux guest image candidate
against a named runtime-template recipe (basic / dev-document).

A *template recipe* (owned by job D, job-6f5ac974858c47c2) declares which
packages a preinstalled guest template must contain. This script is the
verification side (job K): it consumes the image's own package inventory
(`guest-packages.tsv`, produced by the image build's guest stage 1) and,
optionally, the corresponding-source mapping produced by the sources job
(`debian-package-source-map.tsv`), and reports whether the recipe is really
satisfied by that exact image.

Exit codes (stable, for CI gating):
  0  qualified: every recipe requirement is present in the inventory
     (and in the source mapping when one is supplied)
  1  not qualified: the image does not satisfy a present recipe
  2  input error: bad arguments / unreadable inputs
  3  dependency missing: a requested recipe file does not exist yet (the
     D job has not delivered it). This is an explicit dependency failure —
     the image is never labelled as carrying a template that was not
     verified.

Recipe file schema (JSON; recipe files live in the directory given by
`--recipe-dir`, default `FloeAgent/LinuxGuest/image/templates`):
{
  "schema": 1,
  "name": "basic",
  "description": "...",
  "packages": {
    "python3":        {"min_version": "3.11"},   # or null for any version
    "nodejs":         null,
    "python3-numpy":  null
  },
  "require_source_mapping": true   # optional; default true
}

The script never writes into the recipe directory and never downloads
anything; it is safe to run locally on evidence files.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import tempfile

EXIT_QUALIFIED = 0
EXIT_NOT_QUALIFIED = 1
EXIT_INPUT_ERROR = 2
EXIT_DEPENDENCY_MISSING = 3

DEFAULT_RECIPE_DIR = os.path.join("FloeAgent", "LinuxGuest", "image", "templates")
DEPENDENCY_OWNER = "job-6f5ac974858c47c2 (D: preinstall image recipes)"


def split_debian_version(version: str) -> tuple[int, str, str]:
    """Return epoch, upstream version and revision per Debian Policy 5.6.12."""
    if ":" in version:
        epoch_text, value = version.split(":", 1)
        if not epoch_text.isdecimal():
            raise ValueError(f"invalid Debian version epoch: {version!r}")
        epoch = int(epoch_text)
    else:
        epoch, value = 0, version
    if not value or not value[0].isdigit() or not re.fullmatch(r"[A-Za-z0-9.+~-]+", value):
        raise ValueError(f"invalid Debian version: {version!r}")
    if "-" in value:
        upstream, revision = value.rsplit("-", 1)
        if not revision:
            raise ValueError(f"invalid Debian revision: {version!r}")
    else:
        upstream, revision = value, "0"
    return epoch, upstream, revision


def compare_debian_part(left: str, right: str) -> int:
    """Compare one upstream/revision part using dpkg's non-digit/digit rules."""
    def order(char: str) -> int:
        if char == "~":
            return -1
        if not char:
            return 0
        if char.isascii() and char.isalpha():
            return ord(char)
        return ord(char) + 256

    i = j = 0
    while i < len(left) or j < len(right):
        while (i < len(left) and not left[i].isdigit()) or (j < len(right) and not right[j].isdigit()):
            a = left[i] if i < len(left) and not left[i].isdigit() else ""
            b = right[j] if j < len(right) and not right[j].isdigit() else ""
            if order(a) != order(b):
                return -1 if order(a) < order(b) else 1
            i += bool(a)
            j += bool(b)

        while i < len(left) and left[i] == "0":
            i += 1
        while j < len(right) and right[j] == "0":
            j += 1
        left_end, right_end = i, j
        while left_end < len(left) and left[left_end].isdigit():
            left_end += 1
        while right_end < len(right) and right[right_end].isdigit():
            right_end += 1
        left_digits, right_digits = left[i:left_end], right[j:right_end]
        if len(left_digits) != len(right_digits):
            return -1 if len(left_digits) < len(right_digits) else 1
        if left_digits != right_digits:
            return -1 if left_digits < right_digits else 1
        i, j = left_end, right_end
    return 0


def compare_debian_versions(left: str, right: str) -> int:
    left_epoch, left_upstream, left_revision = split_debian_version(left)
    right_epoch, right_upstream, right_revision = split_debian_version(right)
    if left_epoch != right_epoch:
        return -1 if left_epoch < right_epoch else 1
    upstream = compare_debian_part(left_upstream, right_upstream)
    return upstream if upstream else compare_debian_part(left_revision, right_revision)


def version_at_least(have: str, minimum: str) -> bool:
    return compare_debian_versions(have, minimum) >= 0


def read_packages(path: str) -> dict:
    """Read `guest-packages.tsv`: binary, version, arch, source, source_version."""
    inventory = {}
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            name = parts[0].split(":")[0]
            inventory[name] = {
                "version": parts[1],
                "arch": parts[2] if len(parts) > 2 else "",
                "source": parts[3] if len(parts) > 3 and parts[3] else name,
                "source_version": parts[4] if len(parts) > 4 and parts[4] else parts[1],
            }
    return inventory


def read_source_map(path: str) -> set:
    """Read `debian-package-source-map.tsv`; return the mapped binary names."""
    mapped = set()
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if not line.startswith("#"):
                parts = line.rstrip("\n").split("\t")
                if parts and parts[0]:
                    mapped.add(parts[0].split(":")[0])
    return mapped


def load_recipe(args) -> tuple:
    """Return (recipe dict, recipe path). Exit 3 when the recipe is absent."""
    if args.recipe_file:
        path = args.recipe_file
    else:
        path = os.path.join(args.recipe_dir, f"{args.recipe}.json")
    if not os.path.isfile(path):
        print(
            f"DEPENDENCY-MISSING: template recipe '{args.recipe}' not found at "
            f"{path}\n"
            f"  owner: {DEPENDENCY_OWNER}\n"
            f"  This is an explicit dependency failure: the image is NOT "
            f"qualified for the '{args.recipe}' template and must not be "
            f"labelled as preinstalled until the recipe lands.",
            file=sys.stderr,
        )
        return None, path
    try:
        with open(path, "r", encoding="utf-8") as handle:
            recipe = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"INPUT-ERROR: cannot read recipe {path}: {exc}", file=sys.stderr)
        return "ERROR", path
    if not isinstance(recipe, dict) or not isinstance(recipe.get("packages"), dict):
        print(f"INPUT-ERROR: recipe {path} has no 'packages' object", file=sys.stderr)
        return "ERROR", path
    return recipe, path


def qualify_recipe(recipe: dict, recipe_path: str, inventory: dict,
                   source_map: set | None) -> dict:
    """Return a JSON-able qualification report for one recipe."""
    requirements = []
    ok = True
    for name in sorted(recipe["packages"]):
        spec = recipe["packages"][name] or {}
        entry = inventory.get(name)
        row = {
            "package": name,
            "requirement": spec if spec else "present (any version)",
            "present": bool(entry),
        }
        if entry:
            row["installed_version"] = entry["version"]
            row["source"] = entry["source"]
            row["source_version"] = entry["source_version"]
            minimum = spec.get("min_version") if isinstance(spec, dict) else None
            if minimum:
                try:
                    meets_minimum = version_at_least(entry["version"], minimum)
                except (TypeError, ValueError):
                    row["reason"] = "invalid Debian version in inventory or recipe"
                    ok = False
                    requirements.append(row)
                    continue
                if not meets_minimum:
                    row["reason"] = f"version {entry['version']} < required {minimum}"
                    ok = False
            if "reason" not in row and source_map is not None:
                if name not in source_map:
                    row["reason"] = "no corresponding-source mapping in the sources bundle"
                    ok = False
        else:
            row["reason"] = "not installed in the image inventory"
            ok = False
        requirements.append(row)

    source_check = {
        "performed": source_map is not None,
        "note": ("source map supplied; every recipe package must have a mapping"
                 if source_map is not None else
                 "no source map supplied — corresponding-source cross-check NOT "
                 "performed (pass --source-map from the sources job to include it)"),
    }
    return {
        "recipe": recipe.get("name", os.path.basename(recipe_path)),
        "recipe_path": recipe_path,
        "description": recipe.get("description", ""),
        "requirements": requirements,
        "source_check": source_check,
        "qualified": ok,
    }


def write_reports(out_dir: str, reports: list, template_files: list) -> None:
    os.makedirs(out_dir, exist_ok=True)
    payload = {
        "tool": "qualify_runtime_templates.py",
        "recipe_files": template_files,
        "reports": reports,
    }
    with open(os.path.join(out_dir, "template-qualification.json"), "w",
              encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=False)
        handle.write("\n")
    lines = ["# Runtime-template qualification", ""]
    for report in reports:
        verdict = "QUALIFIED" if report["qualified"] else "NOT QUALIFIED"
        lines.append(f"## {report['recipe']} — {verdict}")
        if report.get("description"):
            lines.append("")
            lines.append(report["description"])
        lines.append("")
        lines.append("| package | installed | requirement | result |")
        lines.append("| --- | --- | --- | --- |")
        for row in report["requirements"]:
            requirement = row["requirement"]
            if isinstance(requirement, dict):
                requirement = json.dumps(requirement, ensure_ascii=False)
            lines.append(
                f"| {row['package']} | {row.get('installed_version', '—')} | "
                f"{requirement} | {row.get('reason', 'ok')} |")
        lines.append("")
        lines.append(f"source cross-check: {report['source_check']['note']}")
        lines.append("")
    with open(os.path.join(out_dir, "template-qualification.md"), "w",
              encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def run(args) -> int:
    if args.selftest:
        return selftest()
    if not args.packages:
        print("INPUT-ERROR: --packages is required (guest-packages.tsv)",
              file=sys.stderr)
        return EXIT_INPUT_ERROR
    if not os.path.isfile(args.packages):
        print(f"INPUT-ERROR: package inventory not found: {args.packages}",
              file=sys.stderr)
        return EXIT_INPUT_ERROR
    inventory = read_packages(args.packages)
    if not inventory:
        print(f"INPUT-ERROR: package inventory is empty: {args.packages}",
              file=sys.stderr)
        return EXIT_INPUT_ERROR
    source_map = None
    if args.source_map:
        if not os.path.isfile(args.source_map):
            print(f"INPUT-ERROR: source map not found: {args.source_map}",
                  file=sys.stderr)
            return EXIT_INPUT_ERROR
        source_map = read_source_map(args.source_map)

    recipes = args.recipe or []
    if not recipes and not args.recipe_file:
        print("INPUT-ERROR: pass at least one --recipe or --recipe-file",
              file=sys.stderr)
        return EXIT_INPUT_ERROR

    recipes_to_run = [(name, None) for name in recipes]
    if args.recipe_file:
        recipes_to_run.append((None, args.recipe_file))

    reports = []
    template_files = []
    missing = []
    for name, recipe_file in recipes_to_run:
        probe = argparse.Namespace(recipe=name, recipe_file=recipe_file,
                                   recipe_dir=args.recipe_dir)
        recipe, path = load_recipe(probe)
        if recipe is None:
            missing.append(f"{name or recipe_file}: {path}")
            continue
        if recipe == "ERROR":
            return EXIT_INPUT_ERROR
        template_files.append(path)
        reports.append(qualify_recipe(recipe, path, inventory, source_map))

    if reports and not args.out:
        print("INPUT-ERROR: --out DIR is required to write the report",
              file=sys.stderr)
        return EXIT_INPUT_ERROR
    if reports:
        write_reports(args.out, reports, template_files)
        for report in reports:
            verdict = "QUALIFIED" if report["qualified"] else "NOT-QUALIFIED"
            print(f"TEMPLATE_{verdict.replace('-', '_')} {report['recipe']}")
            for row in report["requirements"]:
                state = "ok" if "reason" not in row else row["reason"]
                print(f"  {row['package']}: {state}")
    if missing:
        print(f"TEMPLATE_DEPENDENCY_MISSING {' '.join(m.split(':')[0] for m in missing)}")
        for line in missing:
            print(f"  missing recipe: {line}", file=sys.stderr)
        return EXIT_DEPENDENCY_MISSING
    if not reports:
        return EXIT_DEPENDENCY_MISSING
    return EXIT_QUALIFIED if all(r["qualified"] for r in reports) else EXIT_NOT_QUALIFIED


def selftest() -> int:
    """Local contract test: no network, no image, no D recipes required."""
    tmp = tempfile.mkdtemp(prefix="floe-template-selftest-")
    try:
        recipe_dir = os.path.join(tmp, "templates")
        os.makedirs(recipe_dir)
        packages = os.path.join(tmp, "guest-packages.tsv")
        source_map = os.path.join(tmp, "map.tsv")
        out = os.path.join(tmp, "out")
        with open(packages, "w", encoding="utf-8") as handle:
            handle.write("python3\t3.11.2-1\triscv64\tpython3\t3.11.2-1\n")
            handle.write("nodejs\t20.19.2+dfsg-1\triscv64\tnodejs\t20.19.2+dfsg-1\n")
            handle.write("coreutils\t9.1-1\triscv64\tcoreutils\t9.1-1\n")
        with open(source_map, "w", encoding="utf-8") as handle:
            handle.write("#binary\tbinary_version\tsource\tsource_version\tsuite\tpool_base\tdirectory\tfile\tsha256\tsize\n")
            handle.write("python3\t3.11.2-1\tpython3\t3.11.2-1\ttrixie\tpool\tp/python3\tx.dsc\tabc\t1\n")
            handle.write("nodejs\t20.19.2+dfsg-1\tnodejs\t20.19.2+dfsg-1\ttrixie\tpool\tp/nodejs\ty.dsc\tdef\t1\n")
            handle.write("coreutils\t9.1-1\tcoreutils\t9.1-1\ttrixie\tpool\tp/coreutils\tz.dsc\tghi\t1\n")
        good = {"schema": 1, "name": "basic",
                "packages": {"python3": {"min_version": "3.10"}, "nodejs": None}}
        # dev-document is written with a *real* satisfied requirement set (an
        # empty requirement set is not a recipe).
        devdoc = {"schema": 1, "name": "dev-document",
                  "packages": {"python3": None, "coreutils": None}}
        old = {"schema": 1, "name": "too-old",
               "packages": {"python3": {"min_version": "99.0"}}}
        for recipe in (good, devdoc, old):
            with open(os.path.join(recipe_dir, recipe["name"] + ".json"), "w",
                      encoding="utf-8") as handle:
                json.dump(recipe, handle)

        results = []
        # Debian Policy 5.6.12, including ordering that the previous
        # split-and-lexical shortcut got wrong. A min-version check must not
        # silently discard epochs, pre-release tildes or Debian revisions.
        version_cases = (
            ("1:1.0", "99.0", True),
            ("1.0", "1:0.1", False),
            ("1.0~rc1", "1.0", False),
            ("1.0", "1.0~rc1", True),
            ("1.0+deb13u1", "1.0", True),
            ("1.0-1+deb13u1", "1.0-1", True),
            ("1.0-1", "1.0-1+b1", False),
            ("1.0-1", "1.0-1~b1", True),
            ("1.00", "1.0", True),
            ("1.0a", "1.0+", False),
        )
        for have, minimum, expected in version_cases:
            results.append((f"Debian version {have} >= {minimum}",
                            version_at_least(have, minimum) == expected))
        base = ["--packages", packages, "--source-map", source_map, "--out", out,
                "--recipe-dir", recipe_dir]

        rc = run(argparse.Namespace(recipe=["basic"], recipe_file=None,
                                    recipe_dir=recipe_dir, packages=packages,
                                    source_map=source_map, out=out, selftest=False))
        results.append(("qualified recipe -> 0", rc == EXIT_QUALIFIED))

        rc = run(argparse.Namespace(recipe=["dev-document"], recipe_file=None,
                                    recipe_dir=recipe_dir, packages=packages,
                                    source_map=source_map, out=out, selftest=False))
        results.append(("second qualified recipe -> 0", rc == EXIT_QUALIFIED))

        # recipe present but package missing from a trimmed inventory
        trimmed = os.path.join(tmp, "trimmed.tsv")
        with open(trimmed, "w", encoding="utf-8") as handle:
            handle.write("python3\t3.11.2-1\triscv64\tpython3\t3.11.2-1\n")
        rc = run(argparse.Namespace(recipe=["basic"], recipe_file=None,
                                    recipe_dir=recipe_dir, packages=trimmed,
                                    source_map=None, out=out, selftest=False))
        results.append(("missing package -> 1", rc == EXIT_NOT_QUALIFIED))

        rc = run(argparse.Namespace(recipe=["too-old"], recipe_file=None,
                                    recipe_dir=recipe_dir, packages=packages,
                                    source_map=None, out=out, selftest=False))
        results.append(("version too old -> 1", rc == EXIT_NOT_QUALIFIED))

        invalid_version = os.path.join(tmp, "invalid-version.tsv")
        with open(invalid_version, "w", encoding="utf-8") as handle:
            handle.write("python3\tinvalid-version\triscv64\tpython3\tinvalid-version\n")
            handle.write("nodejs\t20.19.2+dfsg-1\triscv64\tnodejs\t20.19.2+dfsg-1\n")
        rc = run(argparse.Namespace(recipe=["basic"], recipe_file=None,
                                    recipe_dir=recipe_dir, packages=invalid_version,
                                    source_map=None, out=out, selftest=False))
        results.append(("malformed installed version fails closed -> 1", rc == EXIT_NOT_QUALIFIED))

        rc = run(argparse.Namespace(recipe=["does-not-exist"], recipe_file=None,
                                    recipe_dir=recipe_dir, packages=packages,
                                    source_map=None, out=out, selftest=False))
        results.append(("missing recipe -> 3 (dependency)", rc == EXIT_DEPENDENCY_MISSING))

        rc = run(argparse.Namespace(recipe=["basic"], recipe_file=None,
                                    recipe_dir=recipe_dir, packages="/nonexistent.tsv",
                                    source_map=None, out=out, selftest=False))
        results.append(("missing inventory -> 2 (input error)", rc == EXIT_INPUT_ERROR))

        # source cross-check catches an unmapped package
        partial_map = os.path.join(tmp, "partial-map.tsv")
        with open(partial_map, "w", encoding="utf-8") as handle:
            handle.write("#binary\tbinary_version\tsource\tsource_version\tsuite\tpool_base\tdirectory\tfile\tsha256\tsize\n")
            handle.write("python3\t3.11.2-1\tpython3\t3.11.2-1\ttrixie\tpool\tp/python3\tx.dsc\tabc\t1\n")
        rc = run(argparse.Namespace(recipe=["basic"], recipe_file=None,
                                    recipe_dir=recipe_dir, packages=packages,
                                    source_map=partial_map, out=out, selftest=False))
        results.append(("unmapped source -> 1", rc == EXIT_NOT_QUALIFIED))

        report_path = os.path.join(out, "template-qualification.json")
        parsed = None
        if os.path.isfile(report_path):
            try:
                with open(report_path, "r", encoding="utf-8") as handle:
                    parsed = json.load(handle)
            except json.JSONDecodeError:
                parsed = None
        results.append(("report JSON written and valid",
                        isinstance(parsed, dict) and parsed.get("reports")))

        failed = 0
        for name, ok in results:
            print(f"selftest {'ok' if ok else 'FAIL'}: {name}")
            if not ok:
                failed += 1
        print(f"selftest: {len(results) - failed}/{len(results)} passed")
        return 0 if failed == 0 else 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Qualify a guest image package inventory against named "
                    "runtime-template recipes (basic / dev-document).")
    parser.add_argument("--recipe", action="append", default=[],
                        help="recipe name (repeatable): basic, dev-document, ...")
    parser.add_argument("--recipe-file", default=None,
                        help="explicit recipe JSON path (bypasses --recipe-dir)")
    parser.add_argument("--recipe-dir", default=DEFAULT_RECIPE_DIR,
                        help=f"recipe directory (default: {DEFAULT_RECIPE_DIR})")
    parser.add_argument("--packages", default=None,
                        help="guest-packages.tsv from the image evidence")
    parser.add_argument("--source-map", default=None,
                        help="debian-package-source-map.tsv from the sources job")
    parser.add_argument("--out", default=None,
                        help="output directory for template-qualification.{json,md}")
    parser.add_argument("--selftest", action="store_true",
                        help="run the local contract tests (no inputs needed)")
    return run(parser.parse_args())


if __name__ == "__main__":
    sys.exit(main())
