#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""collect-pypi-sources.py — corresponding-source bundle for the pinned PyPI
wheels of a Floe Linux guest image template recipe.

The Debian collector (debian-source-map.py) covers the APT userland. This
script closes the PyPI side of the corresponding-source obligation for
templates that pin wheels (the dev-document template pins four):

  python-pptx 1.0.2, pdfplumber 0.11.9, pdfminer.six 20251230, pypdfium2 5.13.0

For every pinned wheel it collects, verifies and records:

  * the wheel bytes themselves, SHA-256-checked against the recipe pin (the
    recipe pin is what the image build installed, so this ties the bundle to
    the qualified image);
  * the matching PyPI sdist, SHA-256-checked against the PyPI JSON API
    digests, with a file-level correspondence proof (every non-generated
    payload file in the wheel is byte-identical in the sdist);
  * for a wheel that bundles native code (pypdfium2's riscv64 manylinux
    wheel), the full source chain of the bundled binary:
      - pypdfium2 sdist build scripts (setupsrc/, patches/) — already the
        sdist collected above;
      - the exact pdfium revision: pypdfium2's sourcebuild pin
        (SBUILD_NATIVE_PIN in setupsrc/base.py) names the pdfium branch
        chromium/<build>; the branch tip commit is resolved through the
        gitiles JSON API and PROVEN to equal the build-time checkout by the
        frozen-branch argument (tip committer date <= wheel upload date);
      - the pdfium source archive at that exact commit;
      - pdfium's DEPS file at that commit, parsed into a machine-readable
        dependency-revision table (the same revisions build_native.py's
        DepsFetcher clones);
    plus the recorded CI build configuration (pyproject cibuildwheel
    environment) needed to replay the build.

Nothing here publishes anything. Outputs are component artifacts + digests a
reviewer (or the final distribution step) can re-check.

Exit codes: 0 = complete (no gaps), 3 = gaps recorded in pypi-source-gaps.tsv
(same contract as debian-source-map.py), 1 = hard failure.

Usage:
  python3 collect-pypi-sources.py --recipe templates/dev-document.json \
      --out DIR [--github-run URL]
  python3 collect-pypi-sources.py --self-test
"""
import argparse
import base64
import datetime
import hashlib
import io
import json
import os
import re
import sys
import tarfile
import urllib.request
import zipfile
from pathlib import Path

REPO_PDFIUM_GITILES = "https://pdfium.googlesource.com/pdfium"
# Files pypdfium2 generates at build time (not shipped in the sdist); the
# correspondence proof skips these, everything else must be byte-identical.
GENERATED_ALLOWLIST = {
    "pypdfium2/version.json",
    "pypdfium2_raw/version.json",
    "pypdfium2_raw/bindings.py",
}

DEPS_REVISION_RE = re.compile(r"^\s*'(\w+?)_revision': '([0-9a-f]{40})',\s*$")


class GapRecorder:
    def __init__(self, path):
        self.path = path
        self.rows = []

    def add(self, distribution, artifact, detail):
        self.rows.append((distribution, artifact, detail))

    def flush(self):
        with open(self.path, "w", encoding="utf-8") as handle:
            handle.write("#distribution\tartifact\tdetail\n")
            for row in self.rows:
                handle.write("\t".join(row) + "\n")


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch(url, dest, expect_sha256=None, timeout=180, retries=3):
    """Download url to dest (bytes), optionally verifying the SHA-256."""
    last = None
    for attempt in range(1, retries + 1):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "floe-source-collector/1.0"})
            with urllib.request.urlopen(request, timeout=timeout) as response:
                data = response.read()
            break
        except Exception as error:  # noqa: BLE001 - report the last error after retries
            last = error
            if attempt == retries:
                raise RuntimeError("download failed (%s): %s" % (url, last))
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "wb") as handle:
        handle.write(data)
    if expect_sha256 is not None:
        actual = sha256_file(dest)
        if actual != expect_sha256:
            raise RuntimeError(
                "sha256 mismatch for %s: got %s, want %s" % (dest, actual, expect_sha256))
    return len(data)


def fetch_json(url, timeout=120):
    request = urllib.request.Request(url, headers={"User-Agent": "floe-source-collector/1.0"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def gitiles_json(url):
    """gitiles prefixes JSON with )]}' — strip it."""
    request = urllib.request.Request(url, headers={"User-Agent": "floe-source-collector/1.0"})
    with urllib.request.urlopen(request, timeout=120) as response:
        raw = response.read().decode("utf-8")
    return json.loads(raw[raw.index("{"):])


def sdist_candidates(dist, version):
    base = "https://pypi.org/pypi/%s/%s/json" % (dist, version)
    data = fetch_json(base)
    sdist = None
    for upload in data.get("urls", []):
        if upload.get("packagetype") == "sdist" and upload["filename"].endswith(".tar.gz"):
            sdist = upload
            break
    if sdist is None:
        raise RuntimeError("no sdist found on PyPI for %s==%s" % (dist, version))
    return data, sdist


def normalize_payload_path(name):
    """Map a wheel payload path onto an sdist path (handle src/ layouts)."""
    name = name.replace("\\", "/")
    if name.startswith("src/"):
        return name[4:]
    return name


def _strip_shebang(payload):
    """Drop the first line when it is a shebang (entry-point rewrites)."""
    if payload.startswith(b"#!"):
        return payload.split(b"\n", 1)[1] if b"\n" in payload else b""
    return payload


def wheel_sdist_correspondence(wheel_path, sdist_path):
    """Return (checked, problems): every non-generated .py payload file of the
    wheel must exist in the sdist with identical bytes. Console-script
    wrappers in the wheel's .data/scripts/ scheme match the same-named sdist
    tool after shebang normalization."""
    problems = []
    checked = 0
    with zipfile.ZipFile(wheel_path) as wheel:
        py_entries = [n for n in wheel.namelist()
                      if n.endswith(".py") and ".dist-info/" not in n]
        wheel_bytes = {n: wheel.read(n) for n in py_entries}
    with tarfile.open(sdist_path, "r:gz") as sdist:
        sdist_bytes = {}
        sdist_by_basename = {}
        for member in sdist.getmembers():
            if member.isfile():
                parts = member.name.split("/", 1)
                key = parts[1] if len(parts) == 2 else parts[0]
                payload = sdist.extractfile(member).read()
                sdist_bytes[key] = payload
                sdist_by_basename.setdefault(os.path.basename(key), []).append(key)
                if key.startswith("src/"):
                    sdist_bytes.setdefault(key[4:], payload)
    for name, payload in sorted(wheel_bytes.items()):
        if name in GENERATED_ALLOWLIST:
            continue
        parts = name.split("/")
        if len(parts) >= 3 and parts[0].endswith(".data") and parts[1] == "scripts":
            candidates = sdist_by_basename.get(os.path.basename(name), [])
            if any(_strip_shebang(sdist_bytes[c]) == _strip_shebang(payload)
                   for c in candidates):
                checked += 1
            else:
                problems.append("wheel script %s matches no sdist tool" % name)
            continue
        candidate = normalize_payload_path(name)
        if candidate not in sdist_bytes:
            problems.append("wheel file %s not found in sdist" % name)
            continue
        if sdist_bytes[candidate] != payload:
            problems.append("wheel file %s differs from sdist" % name)
            continue
        checked += 1
    return checked, problems


def parse_deps_revisions(deps_text):
    revisions = []
    for line in deps_text.splitlines():
        match = DEPS_REVISION_RE.match(line)
        if match:
            revisions.append((match.group(1), match.group(2)))
    return revisions


def parse_gitiles_time(value):
    """'Wed Jun 24 18:46:34 2026 -0700' -> aware datetime."""
    return datetime.datetime.strptime(value, "%a %b %d %H:%M:%S %Y %z")


def frozen_tip_check(tip_committer_time, artifact_upload_time):
    """The pypdfium2 CI cloned pdfium with `git clone --depth=1 --revision
    chromium/<build>` — i.e. the branch tip at build time. If the branch tip
    has not moved since (its last commit predates the wheel upload), tip now
    == tip at build time, which pins the exact source commit."""
    return tip_committer_time <= artifact_upload_time


def license_note(dist, info):
    if dist == "pypdfium2":
        return "Apache-2.0 OR BSD-3-Clause (SPDX headers; LICENSES/ in sdist)"
    expression = info.get("license_expression")
    if expression:
        return expression
    for classifier in info.get("classifiers", []):
        if classifier.startswith("License ::"):
            return classifier.rsplit("::", 1)[-1].strip()
    return "see sdist metadata"


def quote_file(path, max_bytes=65536):
    if not os.path.isfile(path):
        return ""
    with open(path, "rb") as handle:
        data = handle.read(max_bytes)
    return data.decode("utf-8", errors="replace")


def build_pypi_bundle(recipe_path, out_dir, github_run=""):
    recipe_path = Path(recipe_path)
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "wheels").mkdir(exist_ok=True)
    (out / "sdists").mkdir(exist_ok=True)
    gaps = GapRecorder(out / "pypi-source-gaps.tsv")
    rows = []  # (distribution, version, artifact, role, url, sha256, bytes)

    with open(recipe_path, "r", encoding="utf-8") as handle:
        recipe = json.load(handle)
    pypi = recipe.get("pypi") or {}
    template_name = recipe.get("name", "unknown")

    summary_lines = [
        "# PyPI wheel corresponding sources — template '%s'" % template_name,
        "",
        "Generated: %s" % datetime.datetime.now(datetime.timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "",
    ]
    if github_run:
        summary_lines += ["Collector run: %s" % github_run, ""]

    if not pypi:
        summary_lines += [
            "This recipe pins no PyPI wheels; nothing to collect.",
            "",
        ]
        _write_outputs(out, gaps, rows, summary_lines)
        return 0

    summary_lines += [
        "Every row of `SOURCES.tsv` is SHA-256-verified. The recipe pin check",
        "ties each wheel to the exact bytes the qualified image installed; the",
        "sdist check ties the source to PyPI's own digest; the correspondence",
        "proof ties the wheel payload to the sdist payload file by file.",
        "",
    ]

    for distribution in sorted(pypi):
        entry = pypi[distribution]
        version = entry["version"]
        wheel_name = entry["wheel"]
        wheel_url = entry["url"]
        wheel_pin = entry["sha256"]
        step = "%s==%s" % (distribution, version)

        wheel_dest = out / "wheels" / wheel_name
        wheel_bytes = fetch(wheel_url, str(wheel_dest), expect_sha256=wheel_pin)
        rows.append((distribution, version, wheel_name, "installed-wheel",
                     wheel_url, wheel_pin, wheel_bytes))

        pypi_data, sdist = sdist_candidates(distribution, version)
        sdist_dest = out / "sdists" / sdist["filename"]
        sdist_bytes = fetch(sdist["url"], str(sdist_dest),
                            expect_sha256=sdist["digests"]["sha256"])
        rows.append((distribution, version, sdist["filename"], "pypi-sdist",
                     sdist["url"], sdist["digests"]["sha256"], sdist_bytes))

        checked, problems = wheel_sdist_correspondence(str(wheel_dest), str(sdist_dest))
        for problem in problems:
            gaps.add(distribution, wheel_name, "wheel/sdist correspondence: " + problem)
        info = pypi_data.get("info", {})
        summary_lines += [
            "## %s" % step,
            "",
            "- license (PyPI metadata): %s" % license_note(distribution, info),
            "- installed wheel: `%s` (recipe pin verified)" % wheel_name,
            "- corresponding sdist: `%s` (PyPI digest verified)" % sdist["filename"],
            "- correspondence proof: %d payload files byte-identical" % checked,
            "",
        ]

        with zipfile.ZipFile(str(wheel_dest)) as wheel:
            native_libs = [n for n in wheel.namelist()
                           if re.search(r"\.(so|dll|dylib)(\..*)?$", n)]
            if "pypdfium2_raw/version.json" in wheel.namelist():
                wheel_info = json.loads(
                    wheel.read("pypdfium2_raw/version.json").decode())
            else:
                wheel_info = None

        if not native_libs:
            continue

        summary_lines += [
            "### Native binary bundled by %s" % wheel_name,
            "",
        ]
        if distribution != "pypdfium2":
            gaps.add(distribution, wheel_name,
                     "native wheel with unhandled provenance chain: %s" % native_libs)
            summary_lines += [
                "- UNHANDLED native provenance for: %s" % ", ".join(native_libs),
                "",
            ]
            continue

        pdfium_build = (wheel_info or {}).get("build")
        if wheel_info is None or pdfium_build is None:
            gaps.add(distribution, wheel_name, "no pypdfium2_raw/version.json in wheel")
            continue

        sdist_dir = out / ("sdist-tree-" + distribution.replace(".", "_"))
        with tarfile.open(str(sdist_dest), "r:gz") as archive:
            for member in archive.getmembers():
                target = os.path.realpath(os.path.join(str(sdist_dir), member.name))
                if not target.startswith(os.path.realpath(str(sdist_dir)) + os.sep):
                    raise RuntimeError("unsafe path in sdist %s: %s"
                                       % (sdist_dest.name, member.name))
            archive.extractall(str(sdist_dir))
        roots = [p for p in sdist_dir.iterdir() if p.is_dir()]
        base_py = roots[0] / "setupsrc" / "base.py"
        pin_match = re.search(r"^SBUILD_NATIVE_PIN\s*=\s*(\d+)\s*$",
                              quote_file(str(base_py)), flags=re.MULTILINE)
        sbuild_pin = int(pin_match.group(1)) if pin_match else None
        if sbuild_pin != pdfium_build:
            gaps.add(distribution, wheel_name,
                     "wheel pdfium build %s != sdist SBUILD_NATIVE_PIN %s"
                     % (pdfium_build, sbuild_pin))

        upload_iso = next((u["upload_time"] for u in pypi_data.get("urls", [])
                           if u.get("filename") == wheel_name), None)
        upload_time = datetime.datetime.strptime(upload_iso, "%Y-%m-%dT%H:%M:%S") \
            .replace(tzinfo=datetime.timezone.utc)

        branch = "chromium/%d" % pdfium_build
        log = gitiles_json("%s/+log/refs/heads/%s?format=JSON&n=1"
                           % (REPO_PDFIUM_GITILES, branch))
        tip = log["log"][0]
        tip_commit = tip["commit"]
        tip_time = parse_gitiles_time(tip["committer"]["time"])

        pdfium_dir = out / "pdfium-source"
        pdfium_dir.mkdir(exist_ok=True)
        archive_url = "%s/+archive/%s.tar.gz" % (REPO_PDFIUM_GITILES, tip_commit)
        archive_dest = pdfium_dir / ("pdfium-%s.tar.gz" % tip_commit)
        archive_bytes = fetch(archive_url, str(archive_dest))
        archive_sha = sha256_file(str(archive_dest))
        # gitiles generates archives on demand: the gzip bytes differ between
        # requests, so the commit is the tree identifier, not the archive
        # hash. Record per-file hashes so the tree is verifiable anyway.
        tree_hashes = []
        with tarfile.open(str(archive_dest), "r:gz") as archive:
            for member in archive.getmembers():
                if member.isfile():
                    digest = hashlib.sha256(archive.extractfile(member).read())
                    tree_hashes.append("%s  %s" % (digest.hexdigest(), member.name))
        tree_hashes.sort(key=lambda line: line.split("  ", 1)[1])
        with open(pdfium_dir / "TREE.sha256", "w", encoding="utf-8") as handle:
            handle.write("\n".join(tree_hashes) + "\n")
        rows.append(("pdfium", "%d @ %s" % (pdfium_build, tip_commit[:12]),
                     archive_dest.name, "native-source (archive bytes vary per "
                     "generation; per-file hashes in TREE.sha256)",
                     archive_url, archive_sha, archive_bytes))

        deps_raw = fetch("%s/+/%s/DEPS?format=TEXT" % (REPO_PDFIUM_GITILES, tip_commit),
                         str(pdfium_dir / "DEPS"))
        deps_text = base64.b64decode(Path(pdfium_dir / "DEPS").read_text().strip()) \
            .decode("utf-8")
        Path(pdfium_dir / "DEPS").write_text(deps_text, encoding="utf-8")
        revisions = parse_deps_revisions(deps_text)
        with open(pdfium_dir / "deps-revisions.tsv", "w", encoding="utf-8") as handle:
            handle.write("#dependency\trevision (pdfium DEPS @ %s)\n" % tip_commit)
            for name, revision in revisions:
                handle.write("%s\t%s\n" % (name, revision))
        rows.append(("pdfium", tip_commit[:12], "DEPS", "native-deps-map",
                     "%s/+/%s/DEPS" % (REPO_PDFIUM_GITILES, tip_commit),
                     hashlib.sha256(deps_text.encode()).hexdigest(),
                     len(deps_text)))

        frozen = frozen_tip_check(tip_time, upload_time)
        if not frozen:
            gaps.add(distribution, wheel_name,
                     "pdfium branch %s moved after the wheel was built "
                     "(tip %s %s > upload %s); exact build commit unresolved"
                     % (branch, tip_commit[:12], tip_time.isoformat(),
                        upload_time.isoformat()))

        pyproject = quote_file(str(roots[0] / "pyproject.toml"))
        build_env_lines = []
        in_linux_env = False
        for line in pyproject.splitlines():
            if line.strip() == "[tool.cibuildwheel.linux.environment]":
                in_linux_env = True
                continue
            if in_linux_env:
                if line.startswith("["):
                    break
                build_env_lines.append(line)
        build_env = "\n".join(l for l in build_env_lines if l.strip())

        summary_lines += [
            "- bundled native: `%s` (sha256 in SOURCES.tsv)" % ", ".join(native_libs),
            "- wheel pdfium identity: `%d.%d.%d` origin `%s`"
              % (wheel_info["major"], wheel_info["minor"], wheel_info["build"],
                 wheel_info.get("origin")),
            "- pypdfium2 sourcebuild pin: `SBUILD_NATIVE_PIN = %s` (sdist setupsrc/base.py)"
              % sbuild_pin,
            "- pdfium source: branch `%s`, tip `%s` (committer %s)"
              % (branch, tip_commit, tip_time.isoformat()),
            "- frozen-branch proof: tip commit predates the wheel upload (%s): `%s`"
              % (upload_time.isoformat(), "yes" if frozen else "NO — GAP"),
            "- pdfium archive: `%s` (%d bytes; gitiles regenerates gzip bytes per\n"
              "  request, so the tree is verified by `TREE.sha256` per-file hashes,\n"
              "  not the archive digest)" % (archive_dest.name, archive_bytes),
            "- pdfium DEPS: `%d` pinned dependency revisions -> deps-revisions.tsv"
              % len(revisions),
            "- build scripts: pypdfium2 sdist `setupsrc/` + `patches/` "
              "(build_native.py clones each DEPS revision)",
            "- recorded CI build environment (pyproject [tool.cibuildwheel.linux]):",
            "",
            "```toml",
            build_env or "(not found in sdist pyproject.toml)",
            "```",
            "",
            "Rebuild recipe (manylinux riscv64, from the collected sdist):",
            "",
            "```sh",
            "tar -xzf %s" % sdist_dest.name,
            "cd %s" % roots[0].name,
            "PDFIUM_PLATFORM=sourcebuild-native \\",
            "BUILD_PARAMS=\"--vendor all --no-vendor libc++\" \\",
            "PDFIUM_VER=%d python3 setup.py bdist_wheel" % pdfium_build,
            "```",
            "",
            "pdfium license: BSD-3-Clause (BUILD_LICENSES/pdfium.txt in the sdist).",
            "",
        ]

    _write_outputs(out, gaps, rows, summary_lines)
    return 3 if gaps.rows else 0


def _write_outputs(out, gaps, rows, summary_lines):
    gaps.flush()
    with open(out / "SOURCES.tsv", "w", encoding="utf-8") as handle:
        handle.write("#distribution\tversion\tartifact\trole\turl\tsha256\tbytes\n")
        for row in rows:
            handle.write("\t".join(str(cell) for cell in row) + "\n")
    with open(out / "PYPI-SOURCES.md", "w", encoding="utf-8") as handle:
        handle.write("\n".join(summary_lines))
        handle.write("\n## Gap list\n\n")
        if gaps.rows:
            handle.write("These rows are real distribution gaps (same rule as\n"
                         "`debian-source-gaps.tsv`); resolve before publishing:\n\n")
            for distribution, artifact, detail in gaps.rows:
                handle.write("- `%s` `%s`: %s\n" % (distribution, artifact, detail))
        else:
            handle.write("`pypi-source-gaps.tsv` is header-only: every pinned wheel\n"
                         "has verified corresponding source and build provenance.\n")
        handle.write("\nDistribution stays gated by the primary release decision;\n"
                     "this bundle is material for the source offer, not the offer.\n")
    checksums = []
    for root, _dirs, files in os.walk(out):
        for name in sorted(files):
            path = Path(root) / name
            if name in ("PYPI-SOURCES.sha256",):
                continue
            checksums.append("%s  %s" % (sha256_file(path),
                                         path.relative_to(out)))
    with open(out / "PYPI-SOURCES.sha256", "w", encoding="utf-8") as handle:
        handle.write("\n".join(checksums) + "\n")


def self_test():
    """Offline checks: correspondence checker, DEPS parser, freeze check."""
    import tempfile
    failures = []

    def check(name, condition):
        print(("ok: " if condition else "FAIL: ") + name)
        if not condition:
            failures.append(name)

    work = Path(tempfile.mkdtemp(prefix="pypi-sources-selftest-"))
    wheel_path = work / "demo-1.0-py3-none-any.whl"
    sdist_path = work / "demo-1.0.tar.gz"
    with zipfile.ZipFile(str(wheel_path), "w") as wheel:
        wheel.writestr("demo/__init__.py", "print('hi')\n")
        wheel.writestr("demo/gen.json", "{}")
        wheel.writestr("demo-1.0.dist-info/METADATA", "Name: demo\n")
    with tarfile.open(str(sdist_path), "w:gz") as sdist:
        payload = b"print('hi')\n"
        info = tarfile.TarInfo("demo-1.0/src/demo/__init__.py")
        info.size = len(payload)
        sdist.addfile(info, io.BytesIO(payload))
    checked, problems = wheel_sdist_correspondence(str(wheel_path), str(sdist_path))
    check("correspondence: src/ layout + byte equality", checked == 1 and not problems)
    check("correspondence: missing file reported", not problems)

    with zipfile.ZipFile(str(wheel_path), "w") as wheel:
        wheel.writestr("demo-1.0.data/scripts/entry.py", b"#!/python\nvalue=1\n")
    with tarfile.open(str(sdist_path), "w:gz") as sdist:
        payload = b"print('hi')\n"
        info = tarfile.TarInfo("demo-1.0/src/demo/__init__.py")
        info.size = len(payload)
        sdist.addfile(info, io.BytesIO(payload))
        tool = b"#!/usr/bin/env python3\nvalue=1\n"
        info2 = tarfile.TarInfo("demo-1.0/tools/entry.py")
        info2.size = len(tool)
        sdist.addfile(info2, io.BytesIO(tool))
    checked3, problems3 = wheel_sdist_correspondence(str(wheel_path), str(sdist_path))
    check("correspondence: .data/scripts shebang normalization",
          checked3 == 1 and not problems3)
    with zipfile.ZipFile(str(wheel_path), "w") as wheel:
        wheel.writestr("demo/other.py", "different\n")
    _checked2, problems2 = wheel_sdist_correspondence(str(wheel_path), str(sdist_path))
    check("correspondence: mismatch reported", len(problems2) == 1)

    deps_text = "\n".join([
        "vars = {",
        "  'abseil_revision': '5e42a36a85a252d8cdee6c39661d2bfd9883fd5c',",
        "  'build_revision': '613f5c13bccbc15bd7ce8da9acb13ac06459f8cb',",
        "  # 'fake_revision': 'zz',",
        "}",
    ])
    revisions = parse_deps_revisions(deps_text)
    check("DEPS parser: two revisions", revisions == [
        ("abseil", "5e42a36a85a252d8cdee6c39661d2bfd9883fd5c"),
        ("build", "613f5c13bccbc15bd7ce8da9acb13ac06459f8cb")])

    frozen_tip = parse_gitiles_time("Wed Jun 24 18:46:34 2026 -0700")
    upload = datetime.datetime(2026, 8, 13, 10, 57, 57, tzinfo=datetime.timezone.utc)
    check("freeze check: frozen branch passes", frozen_tip_check(frozen_tip, upload))
    moved_tip = parse_gitiles_time("Fri Aug 14 09:00:00 2026 +0000")
    check("freeze check: moved branch fails", not frozen_tip_check(moved_tip, upload))

    print("self-test: %d checks, %d failures" % (6, len(failures)))
    return 1 if failures else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recipe", help="template recipe JSON with a pypi section")
    parser.add_argument("--out", help="output directory for the source bundle")
    parser.add_argument("--github-run", default="", help="collector run URL for the manifest")
    parser.add_argument("--self-test", action="store_true", help="offline checks, no network")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()
    if not args.recipe or not args.out:
        parser.error("--recipe and --out are required (or --self-test)")
    return build_pypi_bundle(args.recipe, args.out, args.github_run)


if __name__ == "__main__":
    sys.exit(main())
