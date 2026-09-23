#!/usr/bin/env python3
"""template_recipe.py — validate and consume Floe runtime-template recipes.

A *runtime-template recipe* (owner job-6f5ac974858c47c2 (D)) declares which
Debian packages and which pinned PyPI wheels a preinstalled guest template
must contain. The recipe files live next to this helper in `templates/` and
are consumed by the image build:

    templates/<name>.json

Recipe schema (keys are fixed; schema 1):

    {
      "schema": 1,
      "name": "dev-document",                 # == the file stem
      "description": "...",                    # optional
      "packages": {                            # non-empty; Debian binary names
        "git": null,                           # null (or {}) = any version
        "python3": {"min_version": "3.13"}
      },
      "pypi": {                                # optional; system interpreter
        "python-pptx": {
          "version": "1.0.2",
          "wheel": "python_pptx-1.0.2-py3-none-any.whl",
          "url": "https://files.pythonhosted.org/...",
          "sha256": "<64 lowercase hex>",
          "import": "pptx"                     # optional module name
        }
      },
      "require_source_mapping": true           # optional; default true
    }

The app-side mirror of this shape is `RuntimeV2TemplateRecipe` in
FloeAgent/Sources/FloeExecution/Linux/RuntimeV2/RuntimeV2TemplateStore.swift.

Subcommands (all support --help; non-zero exit on invalid input):

  validate --recipe PATH
      Schema/key/type check; prints a one-line summary. Exit 0 valid,
      1 invalid, 3 recipe file missing.

  summary --recipe PATH
      Machine-readable JSON on stdout: package names, pypi names, counts.

  check-inventory --recipe PATH --packages PATH [--json OUT] [--self-test]
      Compare the recipe against a real `guest-packages.tsv`
      (binary, version, arch, source, source_version; arch-qualified names
      like `libc6:riscv64` are matched by their bare name). The Debian
      version comparison is copied verbatim from
      FloeAgent/scripts/qualify_runtime_templates.py so both tools agree.
      Exit 0 qualified, 1 not qualified, 2 input error, 3 recipe missing.

  manifest --recipe PATH
      Emit the recipe-derived projection of the `template` object that
      write-image-manifest.py embeds. It never claims verification: the
      evidence-dependent fields are empty and `verified` is false.

  --self-test
      Pure-function fixtures (version comparison incl. epochs and
      `+deb13u1` revisions, inventory parsing, recipe validation, exit
      codes) that need no image and no network. Exit 0 when all pass.

This script is stdlib-only, never writes into the recipe directory and never
downloads anything.
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import io
import json
import os
import re
import shutil
import sys
import tempfile

EXIT_OK = 0
EXIT_INVALID = 1
EXIT_INPUT_ERROR = 2
EXIT_DEPENDENCY_MISSING = 3

DEPENDENCY_OWNER = "job-6f5ac974858c47c2 (D: preinstall image recipes)"

ROOT_KEYS = ("schema", "name", "description", "packages", "pypi", "require_source_mapping")
REQUIREMENT_KEYS = ("min_version",)
PYPI_KEYS = ("version", "wheel", "url", "sha256", "import")

PACKAGE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
DISTRIBUTION_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$")
MODULE_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.]*$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class RecipeError(Exception):
    """A recipe problem with the process exit code the CLI should use."""

    def __init__(self, message, exit_code=EXIT_INPUT_ERROR):
        super().__init__(message)
        self.exit_code = exit_code


# ---------------------------------------------------------------------------
# Debian version comparison — the same implementation and ordering as
# FloeAgent/scripts/qualify_runtime_templates.py (commit 331cb7db), per
# Debian Policy 5.6.12: numeric epoch, then the upstream version, then the
# Debian revision, each compared with dpkg's alternating non-digit/digit
# rules where '~' sorts before everything (including end-of-string) and '+'
# sorts after letters. The old split-and-lexical shortcut was removed: it
# discarded epochs and revisions and mis-ordered '~rc1'. The selftest
# cross-checks this module against the qualifier so they cannot drift.
# ---------------------------------------------------------------------------
def split_debian_version(version: str):
    """Return epoch, upstream version and revision per Debian Policy 5.6.12."""
    if ":" in version:
        epoch_text, value = version.split(":", 1)
        if not epoch_text.isdecimal():
            raise ValueError("invalid Debian version epoch: %r" % version)
        epoch = int(epoch_text)
    else:
        epoch, value = 0, version
    if not value or not value[0].isdigit() or not re.fullmatch(r"[A-Za-z0-9.+~-]+", value):
        raise ValueError("invalid Debian version: %r" % version)
    if "-" in value:
        upstream, revision = value.rsplit("-", 1)
        if not revision:
            raise ValueError("invalid Debian revision: %r" % version)
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
        while ((i < len(left) and not left[i].isdigit())
               or (j < len(right) and not right[j].isdigit())):
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


# ---------------------------------------------------------------------------
# Recipe loading and validation
# ---------------------------------------------------------------------------
def sha512_file(path: str) -> str:
    digest = hashlib.sha512()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_pypi_entry(distribution, entry, problems):
    if not isinstance(distribution, str) or not DISTRIBUTION_RE.match(distribution):
        problems.append("invalid pypi distribution name %r" % (distribution,))
        return
    if not isinstance(entry, dict):
        problems.append("pypi[%s] must be an object" % distribution)
        return
    extra = sorted(set(entry) - set(PYPI_KEYS))
    if extra:
        problems.append("pypi[%s] has unknown key(s): %s (allowed: %s)"
                        % (distribution, ", ".join(extra), ", ".join(PYPI_KEYS)))
    version = entry.get("version")
    if not isinstance(version, str) or not version.strip():
        problems.append("pypi[%s].version must be a non-empty string" % distribution)
    wheel = entry.get("wheel")
    if (not isinstance(wheel, str) or not wheel or os.path.basename(wheel) != wheel
            or not wheel.endswith(".whl")):
        problems.append("pypi[%s].wheel must be a plain .whl filename" % distribution)
    url = entry.get("url")
    if not isinstance(url, str) or not url.startswith("https://"):
        problems.append("pypi[%s].url must be an https:// URL" % distribution)
    sha = entry.get("sha256")
    if not isinstance(sha, str) or not SHA256_RE.match(sha):
        problems.append("pypi[%s].sha256 must be 64 lowercase hex chars" % distribution)
    module = entry.get("import")
    if module is not None and (not isinstance(module, str) or not MODULE_RE.match(module)):
        problems.append("pypi[%s].import must be a dotted python identifier" % distribution)


def validate_recipe(recipe, path):
    """Return a list of human-readable problems ([] when the recipe is valid)."""
    if not isinstance(recipe, dict):
        return ["recipe is not a JSON object"]
    problems = []
    stem = os.path.splitext(os.path.basename(path))[0]

    extra = sorted(set(recipe) - set(ROOT_KEYS))
    if extra:
        problems.append("unknown root key(s): %s (allowed: %s)"
                        % (", ".join(extra), ", ".join(ROOT_KEYS)))

    schema = recipe.get("schema")
    if type(schema) is not int or schema != 1:
        problems.append("schema must be the integer 1 (got %r)" % (schema,))

    name = recipe.get("name")
    if not isinstance(name, str) or not name:
        problems.append("name must be a non-empty string")
    else:
        if name != name.strip():
            problems.append("name is padded with whitespace")
        if name != stem:
            problems.append("name %r does not match the file stem %r" % (name, stem))

    if "description" in recipe and not isinstance(recipe["description"], str):
        problems.append("description must be a string when present")

    packages = recipe.get("packages")
    if not isinstance(packages, dict) or not packages:
        problems.append("packages must be a non-empty object")
    else:
        for package in sorted(packages):
            requirement = packages[package]
            if not isinstance(package, str) or not PACKAGE_RE.match(package):
                problems.append("invalid package name %r" % (package,))
                continue
            if requirement is None:
                continue
            if not isinstance(requirement, dict):
                problems.append("packages[%s] must be null or an object" % package)
                continue
            requirement_extra = sorted(set(requirement) - set(REQUIREMENT_KEYS))
            if requirement_extra:
                problems.append("packages[%s] has unknown key(s): %s (allowed: %s)"
                                % (package, ", ".join(requirement_extra),
                                   ", ".join(REQUIREMENT_KEYS)))
            minimum = requirement.get("min_version")
            if minimum is None:
                continue
            if not isinstance(minimum, str) or not minimum.strip():
                problems.append("packages[%s].min_version must be a non-empty string" % package)

    pypi = recipe.get("pypi")
    if pypi is not None:
        if not isinstance(pypi, dict):
            problems.append("pypi must be an object when present")
        else:
            for distribution in sorted(pypi):
                validate_pypi_entry(distribution, pypi[distribution], problems)

    mapping = recipe.get("require_source_mapping")
    if mapping is not None and not isinstance(mapping, bool):
        problems.append("require_source_mapping must be a boolean when present")
    return problems


def load_recipe(path, invalid_exit=EXIT_INPUT_ERROR):
    """Read + validate a recipe file; raise RecipeError with a clear message."""
    if not path:
        raise RecipeError("no recipe path given", EXIT_INPUT_ERROR)
    if not os.path.exists(path):
        raise RecipeError(
            "recipe file does not exist: %s\n"
            "  owner: %s\n"
            "  This is an explicit dependency failure: the template image must "
            "not be built or qualified without its recipe." % (path, DEPENDENCY_OWNER),
            EXIT_DEPENDENCY_MISSING,
        )
    if os.path.isdir(path) or not os.path.isfile(path):
        raise RecipeError("recipe is not a regular file: %s" % path, EXIT_INPUT_ERROR)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        raise RecipeError("cannot read recipe %s: %s" % (path, exc), EXIT_INPUT_ERROR)
    if not text.strip():
        raise RecipeError("recipe is empty: %s" % path, EXIT_INPUT_ERROR)
    try:
        recipe = json.loads(text)
    except json.JSONDecodeError as exc:
        raise RecipeError("recipe %s is not valid JSON: %s" % (path, exc), EXIT_INPUT_ERROR)
    problems = validate_recipe(recipe, path)
    if problems:
        detail = "\n".join("  - %s" % problem for problem in problems)
        raise RecipeError("recipe %s is invalid:\n%s" % (path, detail), invalid_exit)
    return recipe


def pypi_module_name(distribution, entry):
    """The module to import: the explicit `import` key or the dist name with - -> _."""
    module = entry.get("import")
    if module:
        return module
    return distribution.replace("-", "_")


# ---------------------------------------------------------------------------
# check-inventory
# ---------------------------------------------------------------------------
def check_requirements(recipe, recipe_path, inventory, packages_path):
    requirements = []
    missing = []
    below_minimum = []
    ok = True
    for name in sorted(recipe["packages"]):
        spec = recipe["packages"][name] or {}
        entry = inventory.get(name)
        row = {
            "package": name,
            "present": bool(entry),
            "requirement": spec if spec else "present (any version)",
        }
        if entry:
            row["installed_version"] = entry["version"]
            row["source"] = entry["source"]
            minimum = spec.get("min_version") if isinstance(spec, dict) else None
            if minimum:
                try:
                    meets_minimum = version_at_least(entry["version"], minimum)
                except ValueError:
                    row["reason"] = "invalid Debian version in inventory or recipe"
                    below_minimum.append({"name": name, "have": entry["version"],
                                          "minimum": minimum})
                    ok = False
                    requirements.append(row)
                    continue
                if not meets_minimum:
                    row["reason"] = "version %s < required %s" % (entry["version"], minimum)
                    below_minimum.append({"name": name, "have": entry["version"],
                                          "minimum": minimum})
                    ok = False
        else:
            row["reason"] = "not installed in the image inventory"
            missing.append(name)
            ok = False
        requirements.append(row)
    pypi = recipe.get("pypi") or {}
    return {
        "schema": 1,
        "tool": "template_recipe.py check-inventory",
        "recipe": recipe["name"],
        "recipePath": recipe_path,
        "packagesPath": packages_path,
        "qualified": ok,
        "requirements": requirements,
        "missing": missing,
        "belowMinimum": below_minimum,
        "pypi": {
            "checked": False,
            "names": sorted(pypi),
            "note": ("PyPI wheels are verified inside the guest (import + pinned "
                     "version); this inventory check covers Debian packages only."),
        },
    }


def cmd_check_inventory(args):
    try:
        recipe = load_recipe(args.recipe, EXIT_INPUT_ERROR)
    except RecipeError as exc:
        print("INPUT-ERROR: %s" % exc, file=sys.stderr)
        return exc.exit_code
    if not args.packages:
        print("INPUT-ERROR: --packages is required (guest-packages.tsv)", file=sys.stderr)
        return EXIT_INPUT_ERROR
    if not os.path.isfile(args.packages):
        print("INPUT-ERROR: package inventory not found: %s" % args.packages, file=sys.stderr)
        return EXIT_INPUT_ERROR
    inventory = read_packages(args.packages)
    if not inventory:
        print("INPUT-ERROR: package inventory is empty: %s" % args.packages, file=sys.stderr)
        return EXIT_INPUT_ERROR

    report = check_requirements(recipe, args.recipe, inventory, args.packages)
    if args.json:
        out_dir = os.path.dirname(os.path.abspath(args.json))
        if out_dir:
            os.makedirs(out_dir, exist_ok=True)
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(report, handle, indent=2, sort_keys=False)
            handle.write("\n")

    verdict = "QUALIFIED" if report["qualified"] else "NOT_QUALIFIED"
    print("TEMPLATE_INVENTORY_%s %s" % (verdict, report["recipe"]))
    for row in report["requirements"]:
        state = row.get("reason", "ok")
        installed = row.get("installed_version")
        if row["present"] and installed:
            print("  %s: %s (%s)" % (row["package"], state, installed))
        else:
            print("  %s: %s" % (row["package"], state))
    return EXIT_OK if report["qualified"] else EXIT_INVALID


# ---------------------------------------------------------------------------
# Other subcommands
# ---------------------------------------------------------------------------
def cmd_validate(args):
    try:
        recipe = load_recipe(args.recipe, EXIT_INVALID)
    except RecipeError as exc:
        print("template-recipe INVALID: %s" % exc, file=sys.stderr)
        return exc.exit_code
    pypi = recipe.get("pypi") or {}
    mapping = recipe.get("require_source_mapping", True)
    print("template-recipe OK name=%s schema=1 apt=%d pypi=%d "
          "require_source_mapping=%s path=%s"
          % (recipe["name"], len(recipe["packages"]), len(pypi),
             str(bool(mapping)).lower(), args.recipe))
    return EXIT_OK


def cmd_summary(args):
    try:
        recipe = load_recipe(args.recipe, EXIT_INPUT_ERROR)
    except RecipeError as exc:
        print("INPUT-ERROR: %s" % exc, file=sys.stderr)
        return exc.exit_code
    packages = recipe["packages"]
    pypi = recipe.get("pypi") or {}
    minimums = {}
    for package in sorted(packages):
        requirement = packages[package]
        if isinstance(requirement, dict) and requirement.get("min_version"):
            minimums[package] = requirement["min_version"]
    payload = {
        "schema": 1,
        "name": recipe["name"],
        "recipePath": args.recipe,
        "requireSourceMapping": bool(recipe.get("require_source_mapping", True)),
        "apt": {
            "names": sorted(packages),
            "count": len(packages),
            "minimums": minimums,
        },
        "pypi": {
            "names": sorted(pypi),
            "count": len(pypi),
        },
        "totalRequirements": len(packages) + len(pypi),
    }
    print(json.dumps(payload, indent=2, sort_keys=False))
    return EXIT_OK


def cmd_manifest(args):
    try:
        recipe = load_recipe(args.recipe, EXIT_INPUT_ERROR)
    except RecipeError as exc:
        print("INPUT-ERROR: %s" % exc, file=sys.stderr)
        return exc.exit_code
    block = {
        "id": recipe["name"],
        "recipeSha512": sha512_file(args.recipe),
        "recipePath": args.recipe,
        "verified": False,
        "reason": ("recipe-only projection: no stage-1/stage-2 verification "
                   "evidence was consulted"),
        "missingPackages": [],
        "belowMinimum": [],
        "pypiFailures": [],
        "packages": [],
        "checks": ["recipe:schema-1", "recipe:name=stem", "recipe:sha512"],
    }
    print(json.dumps(block, indent=2, sort_keys=False))
    return EXIT_OK


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
def selftest():
    results = []

    def check(label, condition):
        results.append((label, bool(condition)))

    # Debian Policy 5.6.12 ordering — the same group of cases as
    # qualify_runtime_templates.py selftest (commit 331cb7db), including the
    # orderings the previous split-and-lexical shortcut got wrong. A
    # min-version check must not silently discard epochs, pre-release tildes
    # or Debian revisions.
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
        # Inventory strings seen in the real trixie riscv64 image.
        ("1:9.20.29-1~deb13u1", "9.20.29", True),
        ("3.13.5-1", "3.13", True),
        ("20.19.2+dfsg-1+deb13u2", "20.19", True),
        ("25.1.1+dfsg-1", "25.1", True),
        ("2.41.5-0+deb13u1", "2.42", False),
    )
    for have, minimum, expected in version_cases:
        check("Debian version %s >= %s" % (have, minimum),
              version_at_least(have, minimum) is expected)

    def raises_value_error(version):
        try:
            split_debian_version(version)
        except ValueError:
            return True
        return False

    check("malformed version fails closed (bad epoch)",
          raises_value_error("x:1.0"))
    check("malformed version fails closed (leading non-digit)",
          raises_value_error(".1.0"))

    # Cross-implementation parity: this image-side helper and the cloud-side
    # qualifier must give identical verdicts for real dpkg inventory strings.
    # Importing the sibling script by path keeps the selftest image/network
    # free; when the checkout layout is missing the qualifier the check is
    # skipped rather than faked.
    qualifier_path = os.path.normpath(os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "..",
        "scripts", "qualify_runtime_templates.py"))
    if os.path.isfile(qualifier_path):
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "floe_qualify_runtime_templates", qualifier_path)
        qualifier = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(qualifier)
        parity = True
        for have, minimum, _ in version_cases:
            if version_at_least(have, minimum) != qualifier.version_at_least(have, minimum):
                parity = False
                break
        check("version parity with scripts/qualify_runtime_templates.py", parity)
    else:
        check("version parity with scripts/qualify_runtime_templates.py "
              "(qualifier absent: skipped)", True)

    tmp = tempfile.mkdtemp(prefix="floe-template-recipe-selftest-")
    try:
        recipe_dir = os.path.join(tmp, "templates")
        os.makedirs(recipe_dir)

        def write_recipe(name, payload):
            path = os.path.join(recipe_dir, name + ".json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, indent=2)
            return path

        valid = {
            "schema": 1,
            "name": "basic",
            "description": "base image packages",
            "packages": {"python3": {"min_version": "3.13"}, "nodejs": None},
            "require_source_mapping": True,
        }
        valid_path = write_recipe("basic", valid)
        check("valid recipe loads", load_recipe(valid_path)["name"] == "basic")

        def invalid(path):
            try:
                load_recipe(path, EXIT_INVALID)
                return False
            except RecipeError:
                return True

        check("schema != 1 rejected",
              invalid(write_recipe("basic", dict(valid, schema=2))))
        check("name != file stem rejected",
              invalid(write_recipe("basic", dict(valid, name="other"))))
        check("empty packages rejected",
              invalid(write_recipe("basic", dict(valid, packages={}))))
        check("unknown root key rejected",
              invalid(write_recipe("basic", dict(valid, extra_key=1))))
        check("non-string min_version rejected",
              invalid(write_recipe("basic", dict(valid, packages={"python3": {"min_version": 3}}))))
        check("unknown requirement key rejected",
              invalid(write_recipe("basic", dict(valid, packages={"python3": {"maximum": "9"}}))))
        bad_pypi = dict(valid, pypi={"python-pptx": {
            "version": "1.0.2", "wheel": "../python_pptx-1.0.2.whl",
            "url": "https://files.pythonhosted.org/x.whl", "sha256": "abc"}})
        check("bad pypi wheel/sha rejected", invalid(write_recipe("basic", bad_pypi)))
        good_pypi = dict(valid, pypi={"python-pptx": {
            "version": "1.0.2", "wheel": "python_pptx-1.0.2-py3-none-any.whl",
            "url": "https://files.pythonhosted.org/x.whl",
            "sha256": "a" * 64, "import": "pptx"}})
        good_path = write_recipe("basic", good_pypi)
        try:
            recipe = load_recipe(good_path)
            check("valid pypi recipe loads", pypi_module_name("python-pptx", recipe["pypi"]["python-pptx"]) == "pptx")
        except RecipeError:
            check("valid pypi recipe loads", False)
        check("module fallback replaces - with _",
              pypi_module_name("python-pptx", {}) == "python_pptx")

        # Inventory parsing (arch-qualified names) + exit codes.
        packages = os.path.join(tmp, "guest-packages.tsv")
        with open(packages, "w", encoding="utf-8") as handle:
            handle.write("libc6:riscv64\t2.41.5-0+deb13u1\triscv64\tglibc\t2.41.5-0+deb13u1\n")
            handle.write("python3\t3.13.5-1\triscv64\tpython3-defaults\t3.13.5-1\n")
            handle.write("nodejs\t20.19.2+dfsg-1+deb13u2\triscv64\tnodejs\t20.19.2+dfsg-1\n")
        inventory = read_packages(packages)
        check("arch-qualified inventory key stripped",
              set(inventory) == {"libc6", "python3", "nodejs"})

        def run_quiet(**kwargs):
            buffer = io.StringIO()
            sink = io.StringIO()
            with contextlib.redirect_stdout(buffer), contextlib.redirect_stderr(sink):
                rc = run(argparse.Namespace(self_test=False, json=None, **kwargs))
            return rc, buffer.getvalue()

        rc, _ = run_quiet(command="check-inventory", recipe=valid_path, packages=packages)
        check("satisfied inventory -> 0", rc == EXIT_OK)
        trimmed = os.path.join(tmp, "trimmed.tsv")
        with open(trimmed, "w", encoding="utf-8") as handle:
            handle.write("nodejs\t20.19.2+dfsg-1+deb13u2\triscv64\tnodejs\t20.19.2+dfsg-1\n")
        rc, _ = run_quiet(command="check-inventory", recipe=valid_path, packages=trimmed)
        check("missing python3 -> 1", rc == EXIT_INVALID)
        rc, _ = run_quiet(command="check-inventory", recipe=valid_path,
                          packages=os.path.join(tmp, "missing.tsv"))
        check("missing inventory -> 2", rc == EXIT_INPUT_ERROR)
        rc, _ = run_quiet(command="check-inventory",
                          recipe=os.path.join(tmp, "nope.json"), packages=packages)
        check("missing recipe -> 3", rc == EXIT_DEPENDENCY_MISSING)

        # summary/manifest emit parseable JSON.
        rc, summary_text = run_quiet(command="summary", recipe=good_path)
        check("summary exits 0 and is JSON",
              rc == EXIT_OK and json.loads(summary_text)["pypi"]["names"] == ["python-pptx"])

        rc, manifest_text = run_quiet(command="manifest", recipe=good_path)
        try:
            block = json.loads(manifest_text)
            check("manifest projection has the block keys",
                  rc == EXIT_OK and block["verified"] is False
                  and block["recipeSha512"] == sha512_file(good_path)
                  and block["id"] == "basic")
        except (ValueError, KeyError):
            check("manifest projection has the block keys", False)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    failed = 0
    for label, ok in results:
        print("selftest %s: %s" % ("ok" if ok else "FAIL", label))
        if not ok:
            failed += 1
    print("selftest: %d/%d passed" % (len(results) - failed, len(results)))
    return EXIT_OK if failed == 0 else EXIT_INVALID


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def run(args):
    if getattr(args, "self_test", False):
        return selftest()
    command = getattr(args, "command", None)
    if command == "validate":
        return cmd_validate(args)
    if command == "summary":
        return cmd_summary(args)
    if command == "check-inventory":
        return cmd_check_inventory(args)
    if command == "manifest":
        return cmd_manifest(args)
    print("INPUT-ERROR: no subcommand given (try --help)", file=sys.stderr)
    return EXIT_INPUT_ERROR


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Validate and consume Floe runtime-template recipes "
                    "(templates/<name>.json).")
    parser.add_argument("--self-test", action="store_true",
                        help="run the pure-function fixture suite and exit")
    sub = parser.add_subparsers(dest="command")

    validate = sub.add_parser("validate", help="schema/key/type-check a recipe")
    validate.add_argument("--recipe", required=True, help="recipe JSON path")

    summary = sub.add_parser("summary", help="machine-readable recipe summary")
    summary.add_argument("--recipe", required=True, help="recipe JSON path")

    check = sub.add_parser("check-inventory",
                           help="compare a recipe against guest-packages.tsv")
    check.add_argument("--recipe", default=None, help="recipe JSON path")
    check.add_argument("--packages", default=None, help="guest-packages.tsv path")
    check.add_argument("--json", default=None, help="write the JSON report here")
    check.add_argument("--self-test", action="store_true", help="run the fixture suite")

    manifest = sub.add_parser("manifest",
                              help="emit the recipe-derived manifest template block")
    manifest.add_argument("--recipe", required=True, help="recipe JSON path")

    args = parser.parse_args(argv)
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
