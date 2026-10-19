#!/usr/bin/env python3
"""Build verified patched Office browser resources from the restored pinned source.

This producer rebuilds ``browser/dist`` with the genuine upstream Makefile
mechanics (node_modules via ``npm ci --offline`` from the pinned shrinkpack,
eslint/prettier checks, ``tsc-emit`` + ``tsc-strict`` -> ``tscompile`` ->
``release/cool-src.js`` -> ``release/bundle.js`` via m4, the ES2022 acorn
syntax check and the pinned ``esbuild-wasm`` minifier) inside an owned staging
tree. It never patches a prebuilt bundle: the locked browser source patch is
applied to the staged TypeScript and the real bundle chain is re-executed.

Phases (fail-closed, each logged with the exact argv, cwd and exit):

1. validate    ``browser.patch.lock.json`` (separate frontend identity; the
               native ``engine.patch.lock.json`` repair proof is untouched).
2. stage       APFS-clone the restored ``source/browser`` + ``source/scripts``
               into the owned target cache root; verify digests against the
               read-only restored input.
3. deps        ``gmake node_modules`` (npm ci --offline, pinned shrinkpack).
4. control     with the *unpatched* staged tree, delete exactly the bundle.js
               chain outputs and rebuild; the rebuilt ``dist/bundle.js`` must
               be byte-identical to the restored original. This proves the
               relocated toolchain reproduces the original pipeline before any
               patch claim.
5. patch       apply the locked patch with ``git apply`` (check then apply),
               verify the patched TypeScript digest.
6. rebuild     re-run the same ``build-cool`` chain; verify the patched digest
               and the patch fingerprints in the emitted module, intermediate
               and final minified bundle.
7. output      publish ``output/bundle.js`` plus ``output/receipt.json`` (the
               stable root integration interface) and full dist manifests.

``--verify-receipt`` re-hashes a receipt without building anything so the root
integration gate can bind the exact bytes before Xcode staging.

The producer does not run native hosts, App builds, Simulators, Git commits,
pinning or distribution, and never writes to the restored input tree.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

HEX64 = re.compile(r"^[0-9a-f]{64}$")

DEFAULT_RESTORED_SOURCE = Path(
    "/Users/jiangnangenius/Library/Caches/CodexBuild/FloeAgent/"
    "office-linux-closure-A2/xcode-27A266a/bundle-sim4/source"
)
DEFAULT_STAGE_ROOT = Path(
    "/Users/jiangnangenius/Library/Caches/CodexBuild/FloeAgent/"
    "ios-pencil-live-20261019/xcode-27A266a/browser-pinch-df47d2dad175"
)
# Root-verified identity: the sim4 and device-bundle-cold original
# browser/dist/bundle.js are byte-identical with this digest.
DEFAULT_EXPECTED_ORIGINAL_BUNDLE_SHA256 = (
    "6320b78ccd3b08e55d4d861f78e696b15d750aca871a1c4a6c8f2027a795f574"
)

BROWSER_TS_REL = Path("src/canvas/CanvasSectionContainer.ts")
LOCKED_SOURCEFILE_REL = Path("browser") / BROWSER_TS_REL
MODULE_JS_REL = Path("dist/src/canvas/CanvasSectionContainer.js")


def emitted_module_rel(source_file):
    """Map a locked ``browser/src/...`` TypeScript source to its emitted JS."""
    source = Path(source_file)
    try:
        relative = source.relative_to(Path("browser/src"))
    except ValueError:
        raise ProducerError(
            "locked sourceFile must be under browser/src: %s" % source_file)
    return Path("dist/src") / relative.with_suffix(".js")

# Exactly the generated outputs of the dist/bundle.js chain. These stamps and
# intermediates are removed so make re-executes the genuine chain; the rest of
# dist (css, images, l10n, admin) is untouched because the patch has no
# dependency on it.
CONTROL_CLEAN_STAMPS = (
    "eslint.done",
    "prettier.done",
    "tsc-emit.done",
    "tsc-strict.done",
    "tscompile.done",
)
CONTROL_CLEAN_PATHS = (
    "dist/src",
    "dist/bundle.js",
    "dist/strict.tsbuildinfo",
    # tsc-emit uses --incremental (tsconfig.json); leaving the emit buildinfo
    # behind lets tsc skip emitting deleted outputs entirely (observed:
    # 91/525 JS files, truncated cool-src.js). It must be cold like dist/src.
    "dist/tsconfig.tsbuildinfo",
    "release/cool-src.js",
    "release/bundle.js",
)
CONTROL_CLEAN_OPTIONAL = {"dist/strict.tsbuildinfo", "dist/tsconfig.tsbuildinfo"}

# A TypeScript-only source whose emitted JS proves tsc really cold-emitted.
EMIT_PROBE_REL = "dist/src/canvas/CanvasSectionContainer.js"

# Dropped again before the patched build so the rebuild is deterministic
# regardless of second-granularity stamp mtimes.
PATCH_REBUILD_STAMPS = CONTROL_CLEAN_STAMPS

# A code sequence introduced by the locked patch that survives TypeScript
# transpilation and esbuild minification (member names are never mangled and
# esbuild does not reorder operands). Expected absent in the original bundle
# and present in the rebuilt patched bundle.
PATCH_MARKER = "this.positionOnMouseDown===null||this.touchEventInProgress"
PATCH_TOKEN_COUNTS = (
    "this.clearMousePositions()",
    "this.findSectionContainingPoint(this.positionOnMouseDown)",
    "this.convertPositionToCanvasLocale(",
)

RECEIPT_KIND = "Floe Office browser patched resource build"
RECEIPT_FORMAT_VERSION = 1


class ProducerError(Exception):
    """Fail-closed producer or contract violation."""


def npm_state_env(stage_root, base_env=None):
    """Return an env routing all npm mutable state into the owned stage.

    The machine-global ``~/.npm/_cacache`` is a symlink whose target volume
    path does not exist here; repairing user settings is out of scope. npm ci
    therefore gets an explicit owned cache and logs directory; the pinned
    offline shrinkpack install itself is unchanged.
    """
    env = dict(base_env if base_env is not None else os.environ)
    env["npm_config_cache"] = str(Path(stage_root) / "npm-cache")
    env["npm_config_logs_dir"] = str(Path(stage_root) / "npm-logs")
    (Path(stage_root) / "npm-cache").mkdir(parents=True, exist_ok=True)
    (Path(stage_root) / "npm-logs").mkdir(parents=True, exist_ok=True)
    return env


# The restored bundle ships configure's *outputs* (browser/Makefile,
# npm-shrinkwrap.json) but not the build-root bookkeeping inputs
# (config.status, configure, aclocal.m4). gmake must consume those generated
# files and must never attempt to regenerate them (that would re-run
# configure over the whole engine). -o marks exactly these configure-output
# bookkeeping targets as never-remake; no actual build output of the
# bundle.js chain is in this list.
ASSUME_OLD_TARGETS = (
    "Makefile",
    "npm-shrinkwrap.json",
    "../config.status",
    "../configure",
    "../aclocal.m4",
)


def assume_old_args():
    argv = []
    for target in ASSUME_OLD_TARGETS:
        argv += ["-o", target]
    return argv


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(argv, cwd, log_path, env=None):
    """Execute one exact command, capturing merged output to the log."""
    argv = [str(part) for part in argv]
    proc = subprocess.run(
        argv,
        cwd=str(cwd),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
    )
    log_path.parent.mkdir(parents=True, exist_ok=True)
    header = "argv: %r\ncwd: %s\n" % (argv, cwd)
    log_path.write_text(header + (proc.stdout or "") + "\n[exit %d]\n" % proc.returncode)
    return proc.returncode, proc.stdout or ""


class Recorder:
    """Exact commands actually executed, for the receipt."""

    def __init__(self):
        self.entries = []

    def add(self, phase, argv, cwd, exit_code, log):
        self.entries.append(
            {
                "phase": phase,
                "argv": [str(part) for part in argv],
                "cwd": str(cwd),
                "exitCode": exit_code,
                "log": str(log),
            }
        )


def validate_browser_lock(lock_obj, lock_dir):
    """Validate the separate frontend lock; return (repository, commit, entries).

    ``lock_dir`` is the directory containing the lock (the Collabora
    third-party root that holds ``patches/``).
    """
    if not isinstance(lock_obj, dict):
        raise ProducerError("browser patch lock must be a JSON object")
    if lock_obj.get("formatVersion") != 1:
        raise ProducerError("browser patch lock formatVersion must be 1")
    engine = lock_obj.get("engine")
    if not isinstance(engine, dict):
        raise ProducerError("browser patch lock has no engine block")
    repository = engine.get("repository")
    commit = engine.get("commit")
    if not isinstance(repository, str) or not repository:
        raise ProducerError("browser patch lock engine.repository is invalid")
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ProducerError("browser patch lock engine.commit is invalid")
    entries = lock_obj.get("browserSourcePatches")
    if not isinstance(entries, list) or not entries:
        raise ProducerError("browser patch lock has no browserSourcePatches entries")
    normalized = []
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise ProducerError("browserSourcePatches[%d] is not an object" % index)
        fields = {}
        for name in (
            "patch",
            "patchSHA256",
            "sourceRepository",
            "sourceCommit",
            "sourceFile",
            "originalSourceSHA256",
            "patchedSourceSHA256",
        ):
            value = entry.get(name)
            if not isinstance(value, str) or not value:
                raise ProducerError("browserSourcePatches[%d].%s missing" % (index, name))
            fields[name] = value
        for name in ("patchSHA256", "originalSourceSHA256", "patchedSourceSHA256"):
            if not HEX64.fullmatch(fields[name]):
                raise ProducerError(
                    "browserSourcePatches[%d].%s is not lowercase sha256" % (index, name))
        if fields["sourceRepository"] != repository or fields["sourceCommit"] != commit:
            raise ProducerError(
                "browserSourcePatches[%d] source identity differs from the engine block" % index)
        if fields["originalSourceSHA256"] == fields["patchedSourceSHA256"]:
            raise ProducerError("browserSourcePatches[%d] original equals patched digest" % index)
        source_file = Path(fields["sourceFile"])
        if (source_file.is_absolute() or ".." in source_file.parts
                or "\\" in fields["sourceFile"]):
            raise ProducerError(
                "browserSourcePatches[%d].sourceFile must be a contained relative path" % index)
        try:
            source_file.relative_to(Path("browser/src"))
        except ValueError:
            raise ProducerError(
                "browserSourcePatches[%d].sourceFile must be under browser/src" % index)
        patch_path = (lock_dir / fields["patch"]).resolve()
        try:
            patch_path.relative_to(lock_dir.resolve())
        except ValueError:
            raise ProducerError(
                "browserSourcePatches[%d].patch escapes the lock directory" % index)
        if not patch_path.is_file():
            raise ProducerError("browser patch lock patch file missing: %s" % patch_path)
        if sha256_file(patch_path) != fields["patchSHA256"]:
            raise ProducerError("browser patch lock patch digest mismatch: %s" % patch_path)
        marker = entry.get("bundleMarker")
        if marker is not None and (not isinstance(marker, str) or not marker):
            raise ProducerError(
                "browserSourcePatches[%d].bundleMarker must be a non-empty string" % index)
        tokens = entry.get("bundleTokens")
        if tokens is None:
            tokens = []
        if not isinstance(tokens, list) or any(
                not isinstance(token, str) or not token for token in tokens):
            raise ProducerError(
                "browserSourcePatches[%d].bundleTokens must be a list of non-empty strings"
                % index)
        normalized.append(
            {
                "patch": fields["patch"],
                "patchPath": str(patch_path),
                "patchSHA256": fields["patchSHA256"],
                "sourceFile": fields["sourceFile"],
                "originalSourceSHA256": fields["originalSourceSHA256"],
                "patchedSourceSHA256": fields["patchedSourceSHA256"],
                "bundleMarker": marker,
                "bundleTokens": tokens,
            }
        )
    # A file may be patched more than once, but only as a contiguous chain in
    # the declared order: the next patch's original must be the previous
    # patch's result. Independent files start from the pinned original.
    chains = {}
    for index, entry in enumerate(normalized):
        chain = chains.setdefault(entry["sourceFile"], [])
        if chain and entry["originalSourceSHA256"] != chain[-1]["patchedSourceSHA256"]:
            raise ProducerError(
                "browserSourcePatches[%d] does not continue the source chain for %s"
                % (index, entry["sourceFile"]))
        chain.append(entry)
    return repository, commit, normalized


def make_overrides(stage_source, browser_dir, node, npm, cool_version):
    return [
        "NODE=%s" % node,
        "NPM=%s" % npm,
        "abs_top_srcdir=%s" % stage_source,
        "abs_top_builddir=%s" % stage_source,
        "abs_srcdir=%s" % browser_dir,
        "abs_builddir=%s" % browser_dir,
        "COOL_VERSION=%s" % cool_version,
    ]


def plan_control_cleanup(browser_dir):
    """Return the existing staged control outputs (relative paths)."""
    removed = []
    for rel in CONTROL_CLEAN_STAMPS + CONTROL_CLEAN_PATHS:
        if (browser_dir / rel).exists():
            removed.append(rel)
    return removed


def tool_version(binary):
    exe = shutil.which(binary)
    if not exe:
        raise ProducerError("required tool not available on this host: %s" % binary)
    proc = subprocess.run([exe, "--version"], stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True)
    lines = (proc.stdout or "").splitlines()
    return {"path": exe, "version": lines[0] if lines else ""}


def collect_tools():
    return {name: tool_version(name) for name in ("node", "npm", "m4", "gmake", "python3", "git")}


def shrinkpack_manifest_digest(node_shrinkpack_dir):
    entries = []
    for entry in sorted(os.scandir(node_shrinkpack_dir), key=lambda item: item.name):
        if not entry.is_file():
            raise ProducerError("unexpected non-file in node_shrinkpack: %s" % entry.path)
        entries.append("%s %d\n" % (entry.name, entry.stat().st_size))
    if not entries:
        raise ProducerError("node_shrinkpack is empty")
    return hashlib.sha256("".join(entries).encode("utf-8")).hexdigest(), len(entries)


def node_modules_listing_digest(node_modules_dir):
    names = sorted(entry.name for entry in os.scandir(node_modules_dir))
    if not names:
        raise ProducerError("node_modules is empty after install")
    return hashlib.sha256("\n".join(names).encode("utf-8")).hexdigest(), len(names)


def package_version(node_modules_dir, package):
    path = Path(node_modules_dir) / package / "package.json"
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text()).get("version")
    except (json.JSONDecodeError, OSError):
        return None


def flatten_minified(text):
    """Join esbuild '--line-limit=100' hard wraps (newlines sit only between
    tokens, e.g. ``this.\\nfindSection...``) so literal token counting over a
    minified bundle is meaningful. Marker text contains no newlines itself."""
    return text.replace("\n", "")


def marker_report(text, marker=PATCH_MARKER, tokens=PATCH_TOKEN_COUNTS):
    flat = flatten_minified(text)
    return {
        "patchMarkerPresent": marker is not None and marker in flat,
        "tokenCounts": {token: flat.count(token) for token in tokens},
    }


def entry_evidence(entry):
    """Return the bundle marker/tokens that must prove one patch is applied."""
    marker = entry.get("bundleMarker")
    tokens = tuple(entry.get("bundleTokens") or ())
    if marker is None and not tokens and Path(entry["sourceFile"]) == LOCKED_SOURCEFILE_REL:
        # Backward-compatible default for the historical single Canvas patch
        # (synthetic fixtures and older lock copies).
        return PATCH_MARKER, PATCH_TOKEN_COUNTS
    return marker, tokens


def require_bundle_evidence(entries):
    """Fail closed unless every locked patch has a bundle-level proof."""
    for index, entry in enumerate(entries):
        marker, tokens = entry_evidence(entry)
        if marker is None and not tokens:
            raise ProducerError(
                "locked patch %d has no marker/token bundle evidence" % index)


def dist_manifest(dist_dir):
    rows = []
    for root, dirs, files in os.walk(dist_dir):
        dirs.sort()
        for name in sorted(files):
            path = Path(root) / name
            rel = path.relative_to(dist_dir).as_posix()
            rows.append((rel, sha256_file(path), path.stat().st_size))
    return rows


def write_manifest(rows, out_path):
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as handle:
        for rel, digest, size in rows:
            handle.write("%s\t%s\t%d\n" % (rel, digest, size))


def tree_digest(rows):
    digest = hashlib.sha256()
    for rel, sha, size in sorted(rows):
        digest.update(("%s %s %d\n" % (rel, sha, size)).encode("utf-8"))
    return digest.hexdigest()


def patch_targets(patch_path, cwd):
    """Return the single worktree path a locked patch changes.

    ``git apply --numstat`` parses the patch without touching the tree; using
    git's own parser avoids accepting a patch that silently edits a second file
    outside its locked ``sourceFile``.
    """
    proc = subprocess.run(
        ["git", "apply", "--numstat", str(patch_path)],
        cwd=str(cwd), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise ProducerError(
            "cannot parse locked patch %s: %s" % (patch_path, proc.stderr.strip()))
    paths = []
    for line in proc.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) != 3:
            raise ProducerError(
                "unexpected git apply --numstat line for %s: %r" % (patch_path, line))
        added, removed, path = parts
        if added == "-" or removed == "-":
            raise ProducerError("binary locked patch is unsupported: %s" % patch_path)
        paths.append(path)
    return paths


class Producer:
    def __init__(self, args):
        self.args = args
        self.repo_root = args.repo_root.resolve()
        self.lock_path = args.lock if args.lock.is_absolute() else self.repo_root / args.lock
        self.restored = args.restored_source
        self.stage_root = args.stage_root
        self.stage_source = self.stage_root / "source"
        self.stage_browser = self.stage_source / "browser"
        self.output_dir = args.output_dir or self.stage_root / "output"
        self.evidence = args.evidence_dir
        self.logs = self.evidence / "logs"
        self.recorder = Recorder()
        self.serialized = str(args.build_lock_runner) != "none"

    # -- phase 1: validate -----------------------------------------------------
    def validate(self):
        if not self.lock_path.is_file():
            raise ProducerError("browser patch lock missing: %s" % self.lock_path)
        self.lock_sha = sha256_file(self.lock_path)
        try:
            lock_obj = json.loads(self.lock_path.read_text())
        except json.JSONDecodeError as error:
            raise ProducerError("browser patch lock is not valid JSON: %s" % error)
        self.engine_repository, self.engine_commit, self.entries = validate_browser_lock(
            lock_obj, self.lock_path.parent)
        restored_browser = self.restored / "browser"
        checks = {
            "restored browser tree": restored_browser.is_dir(),
            "generated Makefile": (restored_browser / "Makefile").is_file(),
            "package.json": (restored_browser / "package.json").is_file(),
            "npm-shrinkwrap.json": (restored_browser / "npm-shrinkwrap.json").is_file(),
            "node_shrinkpack": (restored_browser / "node_shrinkpack").is_dir(),
            "original dist/bundle.js": (restored_browser / "dist/bundle.js").is_file(),
            "top scripts (genlangmaps/unocommands/unoshortcuts)": (
                (self.restored / "scripts/genlangmaps.py").is_file()
                and (self.restored / "scripts/unocommands.py").is_file()
                and (self.restored / "scripts/unoshortcuts.py").is_file()
            ),
        }
        missing = [name for name, ok in checks.items() if not ok]
        if missing:
            raise ProducerError("restored input lacks required build inputs: %s" % ", ".join(missing))
        # Every independent file chain must start from the restored pinned
        # original; later entries in the same chain were checked against the
        # previous patch result by validate_browser_lock.
        self.source_chains = {}
        for entry in self.entries:
            self.source_chains.setdefault(entry["sourceFile"], []).append(entry)
        self.original_sources = {}
        for source_file, chain in self.source_chains.items():
            source_path = self.restored / source_file
            if not source_path.is_file():
                raise ProducerError("restored locked source file missing: %s" % source_file)
            original = sha256_file(source_path)
            if original != chain[0]["originalSourceSHA256"]:
                raise ProducerError(
                    "restored source digest mismatch for %s: %s != locked %s"
                    % (source_file, original, chain[0]["originalSourceSHA256"]))
            self.original_sources[source_file] = original
        self.original_ts_sha = self.original_sources.get(str(LOCKED_SOURCEFILE_REL))
        self.original_bundle_sha = sha256_file(restored_browser / "dist/bundle.js")
        if self.original_bundle_sha != self.args.expected_original_bundle_sha256:
            raise ProducerError(
                "restored original dist/bundle.js digest mismatch: %s != expected %s"
                % (self.original_bundle_sha, self.args.expected_original_bundle_sha256))

    # -- phase 2: stage --------------------------------------------------------
    def stage(self):
        if self.stage_root.exists() and any(self.stage_root.iterdir()):
            raise ProducerError(
                "stage root exists and is not empty (refusing to reuse or overwrite): %s"
                % self.stage_root)
        self.stage_source.mkdir(parents=True)
        for name in ("browser", "scripts"):
            src = self.restored / name
            dst = self.stage_source / name
            argv = ["cp", "-c", "-R", "-p", str(src), str(dst)]
            code, _ = run(argv, self.stage_source, self.logs / ("02-stage-cp-%s.log" % name))
            self.recorder.add("02-stage-cp-%s" % name, argv, self.stage_source, code,
                              self.logs / ("02-stage-cp-%s.log" % name))
            if code != 0:
                argv = ["cp", "-R", "-p", str(src), str(dst)]
                code, _ = run(argv, self.stage_source, self.logs / ("02-stage-cp-plain-%s.log" % name))
                self.recorder.add("02-stage-cp-plain-%s" % name, argv, self.stage_source, code,
                                  self.logs / ("02-stage-cp-plain-%s.log" % name))
                if code != 0:
                    raise ProducerError("staging copy failed for %s" % name)
        for rel in (*self.source_chains.keys(), "browser/dist/bundle.js"):
            staged = sha256_file(self.stage_source / rel)
            original = sha256_file(self.restored / rel)
            if staged != original:
                raise ProducerError("staged digest mismatch after clone for %s" % rel)

    def _gmake(self, phase, target, jobs=None):
        argv = [shutil.which("gmake"), "-C", str(self.stage_browser)]
        # Consume the configure-produced bookkeeping files; never regenerate.
        argv += assume_old_args()
        if jobs:
            argv += ["-j%d" % jobs]
        argv.append(target)
        argv += make_overrides(
            self.stage_source, self.stage_browser,
            shutil.which("node"), shutil.which("npm"), self.engine_commit[:10])
        if self.serialized:
            argv = [sys.executable or "python3", str(self.args.build_lock_runner), "--", *argv]
        log = self.logs / ("%s.log" % phase)
        code, output = run(argv, self.stage_browser, log, env=npm_state_env(self.stage_root))
        self.recorder.add(phase, argv, self.stage_browser, code, log)
        if code != 0:
            tail = "\n".join(output.splitlines()[-60:])
            raise ProducerError(
                "%s failed (exit %d); original failure retained in %s\n%s"
                % (phase, code, log, tail))
        return code

    # -- phase 3: dependency install -------------------------------------------
    def install_deps(self):
        self._gmake("03-deps-install", "node_modules")
        node_modules = self.stage_browser / "node_modules"
        for rel in ("typescript/bin/tsc", "esbuild-wasm/bin/esbuild",
                    "acorn/dist/acorn.js", "prettier/bin/prettier.cjs",
                    "eslint/bin/eslint.js"):
            if not (node_modules / rel).is_file():
                raise ProducerError("dependency install missing pinned tool: %s" % rel)

    # -- tsc cold-emit proof -----------------------------------------------------
    def verify_typescript_emit(self, phase_label):
        """Prove tsc really (re)emitted every JS module, not an incremental skip.

        A stale dist/tsconfig.tsbuildinfo lets tsc exit 0 while emitting
        nothing, silently truncating cool-src.js. Compare the staged dist/src
        file set against the restored original's set and require the probe
        module emitted from a TypeScript-only source.
        """
        stage_src = self.stage_browser / "dist/src"
        restored_src = self.restored / "browser/dist/src"
        if not stage_src.is_dir():
            raise ProducerError("%s did not produce dist/src at all" % phase_label)
        # Both sets are keyed relative to the browser root so the emitted
        # module names ("dist/src/...") match directly.
        staged = {str(p.relative_to(self.stage_browser)) for p in stage_src.rglob("*.js")}
        original = {str(p.relative_to(self.restored / "browser")) for p in restored_src.rglob("*.js")}
        probes = sorted({str(emitted_module_rel(source_file))
                         for source_file in self.source_chains})
        missing_probes = [probe for probe in probes if probe not in staged]
        if missing_probes:
            raise ProducerError(
                "%s: tsc emitted no %s; incremental buildinfo likely skipped the "
                "compile (staged JS count %d vs restored %d)"
                % (phase_label, ", ".join(missing_probes), len(staged), len(original)))
        # The patch never adds/removes modules: the emitted set must equal the
        # restored one exactly. Report the real deltas if not.
        missing = sorted(original - staged)
        extra = sorted(staged - original)
        if missing or extra:
            raise ProducerError(
                "%s: TypeScript emit set differs from the restored baseline "
                "(missing %d %s, extra %d %s)"
                % (phase_label, len(missing), missing[:5], len(extra), extra[:5]))
        return {"emittedJsFiles": len(staged), "matchesRestoredSet": True}

    # -- phase 4: control rebuild ----------------------------------------------
    def control_build(self):
        removed = plan_control_cleanup(self.stage_browser)
        expected = [rel for rel in CONTROL_CLEAN_STAMPS + CONTROL_CLEAN_PATHS
                    if rel not in CONTROL_CLEAN_OPTIONAL]
        missing = sorted(set(expected) - set(removed))
        if missing:
            raise ProducerError("control cleanup expected outputs missing from stage: %s"
                                % ", ".join(missing))
        for rel in removed:
            path = self.stage_browser / rel
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
        self._gmake("04-control-build", "build-cool", jobs=self.args.jobs)
        emit_proof = self.verify_typescript_emit("control build")
        rebuilt = sha256_file(self.stage_browser / "dist/bundle.js")
        identical = rebuilt == self.original_bundle_sha
        if not identical and not self.args.allow_toolchain_drift:
            raise ProducerError(
                "control rebuild did not reproduce the original bundle byte-for-byte "
                "(restored %s vs rebuilt %s). The patched-output claim would be weak; "
                "investigate toolchain drift or rerun with --allow-toolchain-drift."
                % (self.original_bundle_sha, rebuilt))
        return {
            "cleanedOutputs": removed,
            "emitProof": emit_proof,
            "rebuiltBundleSHA256": rebuilt,
            "byteIdenticalToRestoredOriginal": identical,
        }

    # -- phase 5: apply the locked patches --------------------------------------
    def apply_patch(self):
        applied = []
        for index, entry in enumerate(self.entries):
            target = self.stage_source / entry["sourceFile"]
            current = sha256_file(target)
            if current != entry["originalSourceSHA256"]:
                raise ProducerError(
                    "staged source %s is not the locked pre-patch state for patch %d: "
                    "%s != %s"
                    % (entry["sourceFile"], index, current,
                       entry["originalSourceSHA256"]))
            targets = patch_targets(entry["patchPath"], self.stage_source)
            if targets != [entry["sourceFile"]]:
                raise ProducerError(
                    "locked patch %d changes %r, not exactly its sourceFile %r"
                    % (index, targets, entry["sourceFile"]))
            check_log = self.logs / ("05-patch-%02d-check.log" % index)
            argv = ["git", "apply", "--check", "-p1", entry["patchPath"]]
            code, _ = run(argv, self.stage_source, check_log)
            self.recorder.add("05-patch-%02d-check" % index, argv, self.stage_source,
                              code, check_log)
            if code != 0:
                raise ProducerError(
                    "locked patch %d does not apply cleanly to the staged tree" % index)
            apply_log = self.logs / ("05-patch-%02d-apply.log" % index)
            argv = ["git", "apply", "-p1", entry["patchPath"]]
            code, _ = run(argv, self.stage_source, apply_log)
            self.recorder.add("05-patch-%02d-apply" % index, argv, self.stage_source,
                              code, apply_log)
            if code != 0:
                raise ProducerError("git apply failed for locked patch %d" % index)
            patched = sha256_file(target)
            if patched != entry["patchedSourceSHA256"]:
                raise ProducerError(
                    "patch %d produced %s, not the locked patched source %s"
                    % (index, patched, entry["patchedSourceSHA256"]))
            applied.append({
                "patch": entry["patch"],
                "sourceFile": entry["sourceFile"],
                "stagedPatchedSHA256": patched,
            })
        dropped = []
        for rel in PATCH_REBUILD_STAMPS:
            path = self.stage_browser / rel
            if path.exists():
                path.unlink()
                dropped.append(rel)
        return {"patches": applied, "stampsDroppedForRebuild": dropped}

    # -- phase 6: patched rebuild -----------------------------------------------
    def patched_build(self):
        self._gmake("06-patched-build", "build-cool", jobs=self.args.jobs)
        emit_proof = self.verify_typescript_emit("patched build")
        dist_bundle = self.stage_browser / "dist/bundle.js"
        patched_bundle_sha = sha256_file(dist_bundle)
        if patched_bundle_sha == self.original_bundle_sha:
            raise ProducerError(
                "patched build produced the original bundle digest: the patch was "
                "silently omitted from the bundle chain")
        modules = {}
        for source_file in self.source_chains:
            module_js = self.stage_browser / emitted_module_rel(source_file)
            if not module_js.is_file():
                raise ProducerError(
                    "patched build did not emit the transpiled module for %s" % source_file)
            modules[source_file] = {
                "module": str(emitted_module_rel(source_file)),
                "moduleSHA256": sha256_file(module_js),
            }
        patched_text = dist_bundle.read_text(errors="replace")
        original_text = (self.restored / "browser/dist/bundle.js").read_text(errors="replace")
        require_bundle_evidence(self.entries)
        marker_evidence = []
        for index, entry in enumerate(self.entries):
            marker, tokens = entry_evidence(entry)
            if marker is None and not tokens:
                raise ProducerError(
                    "locked patch %d has no marker/token bundle evidence" % index)
            patched_markers = marker_report(patched_text, marker, tokens)
            original_markers = marker_report(original_text, marker, tokens)
            if original_markers["patchMarkerPresent"]:
                raise ProducerError(
                    "the restored ORIGINAL bundle unexpectedly already carries patch %d's marker"
                    % index)
            if marker is not None and not patched_markers["patchMarkerPresent"]:
                raise ProducerError(
                    "the final minified patched bundle does not carry patch %d's "
                    "marker even though the chain rebuilt; refusing to emit an "
                    "unproven resource" % index)
            for token in tokens:
                if patched_markers["tokenCounts"][token] <= original_markers["tokenCounts"][token]:
                    raise ProducerError(
                        "patch %d token %r count did not increase in the patched "
                        "bundle (patched %d vs original %d)"
                        % (index, token, patched_markers["tokenCounts"][token],
                           original_markers["tokenCounts"][token]))
            marker_evidence.append({
                "patch": entry["patch"],
                "sourceFile": entry["sourceFile"],
                "bundleMarker": marker,
                "bundleTokens": list(tokens),
                "patchedBundle": patched_markers,
                "originalBundle": original_markers,
            })
        first_module = modules[self.entries[0]["sourceFile"]]["moduleSHA256"]
        return {
            "emitProof": emit_proof,
            "distBundleSHA256": patched_bundle_sha,
            "moduleSHA256": first_module,
            "modules": modules,
            "intermediates": {
                "release/cool-src.js": sha256_file(self.stage_browser / "release/cool-src.js"),
                "release/bundle.js": sha256_file(self.stage_browser / "release/bundle.js"),
            },
            "markers": marker_evidence,
        }

    # -- phase 7: outputs + receipt ----------------------------------------------
    def emit_outputs(self, control_info, patch_info, build_info):
        self.output_dir.mkdir(parents=True, exist_ok=True)
        out_bundle = self.output_dir / "bundle.js"
        shutil.copyfile(self.stage_browser / "dist/bundle.js", out_bundle)
        node_modules = self.stage_browser / "node_modules"
        shrink_digest, shrink_count = shrinkpack_manifest_digest(self.stage_browser / "node_shrinkpack")
        listing_digest, listing_count = node_modules_listing_digest(node_modules)
        patched_rows = dist_manifest(self.stage_browser / "dist")
        restored_rows = dist_manifest(self.restored / "browser/dist")
        patched_manifest_path = self.evidence / "dist-manifest-patched.tsv"
        restored_manifest_path = self.evidence / "dist-manifest-restored.tsv"
        write_manifest(patched_rows, patched_manifest_path)
        write_manifest(restored_rows, restored_manifest_path)
        applied_by_patch = {item["patch"]: item for item in patch_info["patches"]}
        patch_identity = [
            {
                "patch": entry["patch"],
                "patchPath": entry["patchPath"],
                "patchSHA256": entry["patchSHA256"],
                "sourceFile": entry["sourceFile"],
                "originalSourceSHA256": entry["originalSourceSHA256"],
                "patchedSourceSHA256": entry["patchedSourceSHA256"],
                "stagedPatchedSHA256": applied_by_patch[entry["patch"]]["stagedPatchedSHA256"],
                "applied": True,
                "stampsDroppedForRebuild": patch_info["stampsDroppedForRebuild"],
            }
            for entry in self.entries
        ]
        receipt = {
            "formatVersion": RECEIPT_FORMAT_VERSION,
            "kind": RECEIPT_KIND,
            "generatedAtUTC": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "tools": self.tools,
            "inputs": {
                "restoredSourceRoot": str(self.restored),
                "restoredOriginalBundleSHA256": self.original_bundle_sha,
                "restoredOriginalTSSHA256": self.original_ts_sha,
                "stageRoot": str(self.stage_root),
                "browserTreeClone": "cp -cRp (APFS clonefile, mtime preserved)",
            },
            "frontendIdentity": {
                "browserPatchLock": str(self.lock_path),
                "browserPatchLockSHA256": self.lock_sha,
                "engineRepository": self.engine_repository,
                "engineCommit": self.engine_commit,
                "coolVersionOverride": self.engine_commit[:10],
                "patches": patch_identity,
            },
            "dependencyInstall": {
                "mode": "gmake node_modules -> npm ci --offline (pinned node_shrinkpack)",
                "npmConfigCache": str(self.stage_root / "npm-cache"),
                "npmConfigLogsDir": str(self.stage_root / "npm-logs"),
                "globalNpmUntouched": "machine ~/.npm/_cacache symlink target is missing; all npm state was routed to the owned stage",
                "npmShrinkwrapSHA256": sha256_file(self.stage_browser / "npm-shrinkwrap.json"),
                "packageLockSHA256": sha256_file(self.stage_browser / "package-lock.json"),
                "nodeShrinkpackFiles": shrink_count,
                "nodeShrinkpackManifestSHA256": shrink_digest,
                "nodeModulesEntries": listing_count,
                "nodeModulesListingSHA256": listing_digest,
                "pinnedVersions": {
                    name: package_version(node_modules, name)
                    for name in ("typescript", "esbuild-wasm", "eslint", "prettier", "acorn")
                },
            },
            "controlBuild": control_info,
            "patchedBuild": build_info,
            "output": {
                "bundle": str(out_bundle),
                "bundleSHA256": sha256_file(out_bundle),
                "sizeBytes": out_bundle.stat().st_size,
            },
            "distTree": {
                "patchedTreeSHA256": tree_digest(patched_rows),
                "restoredTreeSHA256": tree_digest(restored_rows),
                "patchedFiles": len(patched_rows),
                "restoredFiles": len(restored_rows),
                "patchedManifest": str(patched_manifest_path),
                "restoredManifest": str(restored_manifest_path),
            },
            # Portable path-free frontend identity for root pinning. The patch
            # inventory mirrors the live contract order and closure.
            "browserResources": {
                "formatVersion": 1,
                "engineCommit": self.engine_commit,
                "browserPatchLockSHA256": self.lock_sha,
                "patches": [
                    {
                        "patch": entry["patch"],
                        "patchSHA256": entry["patchSHA256"],
                        "sourceFile": entry["sourceFile"],
                        "originalSourceSHA256": entry["originalSourceSHA256"],
                        "patchedSourceSHA256": entry["patchedSourceSHA256"],
                    }
                    for entry in self.entries
                ],
                "originalBundleSHA256": self.original_bundle_sha,
                "bundleSHA256": sha256_file(out_bundle),
                "sizeBytes": out_bundle.stat().st_size,
                "patchedDistTreeSHA256": tree_digest(patched_rows),
                "dependencyLockSHA256": sha256_file(self.stage_browser / "npm-shrinkwrap.json"),
                "toolchain": {
                    name: package_version(node_modules, name)
                    for name in ("typescript", "esbuild-wasm", "acorn")
                },
            },
            "commands": self.recorder.entries,
            "limitations": [
                ("COOL_VERSION supplied as a make override (%s, the pinned engine commit short id) "
                 "because the staged tree has no .git; it only feeds the unminified banner, and the "
                 "minified bundle strips comments.") % self.engine_commit[:10],
                ("gmake runs with '-o Makefile': the restored bundle omits the top-level "
                 "config.status, so the generated Makefile is consumed, never regenerated."),
                ("Host node/npm runtime versions differ from the obsolete /Users/runner toolchain; "
                 "the build tools themselves are the pinned shrinkpack versions recorded in "
                 "dependencyInstall.pinnedVersions."),
                ("This receipt proves genuine patched-source bundle reproduction only. "
                 "UIKit/WebKit/App behavior acceptance remains the root Simulator/device gate."),
                ("Rebuilding this bundle does not update engine.lock.json's qualified "
                 "host artifact or resource pins; those remain pinned to the previously "
                 "built bundle until the root rebuilds and re-qualifies the native host."),
            ],
        }
        receipt_text = json.dumps(receipt, indent=2, sort_keys=True) + "\n"
        (self.output_dir / "receipt.json").write_text(receipt_text)
        self.evidence.mkdir(parents=True, exist_ok=True)
        (self.evidence / "receipt.json").write_text(receipt_text)
        return receipt

    def run(self):
        self.tools = collect_tools()
        self.validate()
        self.stage()
        self.install_deps()
        control_info = self.control_build()
        patch_info = self.apply_patch()
        build_info = self.patched_build()
        return self.emit_outputs(control_info, patch_info, build_info)


DEFAULT_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_LOCK_PATH = DEFAULT_REPO_ROOT / "FloeAgent/ThirdParty/Collabora/browser.patch.lock.json"


def verify_receipt(receipt_path, lock_path=None, expected_original_bundle_sha256=None):
    """Re-hash receipt identities against the live browser lock. No build, no writes.

    ``lock_path`` defaults to the repository ``browser.patch.lock.json``; the
    live lock, not the receipt's self-reported digests, is the authority for
    the frontend contract identity. ``expected_original_bundle_sha256``
    defaults to the root-pinned restored original baseline. Returns a list of
    human-readable failures; an empty list means every recorded identity still
    matches the bytes on disk and the live contract.
    """
    receipt_path = Path(receipt_path)
    receipt = json.loads(receipt_path.read_text())
    if receipt.get("kind") != RECEIPT_KIND:
        raise ProducerError("receipt kind unexpected: %r" % receipt.get("kind"))
    if receipt.get("formatVersion") != RECEIPT_FORMAT_VERSION:
        raise ProducerError("receipt formatVersion unexpected: %r" % receipt.get("formatVersion"))
    if lock_path is None:
        lock_path = DEFAULT_LOCK_PATH
    if expected_original_bundle_sha256 is None:
        expected_original_bundle_sha256 = DEFAULT_EXPECTED_ORIGINAL_BUNDLE_SHA256
    failures = []

    def check(label, path, expected):
        try:
            actual = sha256_file(Path(path))
        except OSError as error:
            failures.append("%s: unreadable (%s)" % (label, error))
            return
        if actual != expected:
            failures.append("%s: %s != recorded %s" % (label, actual, expected))

    # -- live frontend contract (authority), independent of receipt claims ----
    lock_path = Path(lock_path)
    live_entries = None
    try:
        live_lock_sha = sha256_file(lock_path)
        live_repository, live_commit, live_entries = validate_browser_lock(
            json.loads(lock_path.read_text()), lock_path.parent)
    except (OSError, ProducerError, ValueError, json.JSONDecodeError) as error:
        failures.append("live browser patch lock invalid: %s" % error)
    identity = receipt["frontendIdentity"]
    identity_patches = identity.get("patches")
    if live_entries is not None:
        if identity.get("engineCommit") != live_commit:
            failures.append("receipt engineCommit %r != live lock %r"
                            % (identity.get("engineCommit"), live_commit))
        if identity.get("engineRepository") != live_repository:
            failures.append("receipt engineRepository %r != live lock %r"
                            % (identity.get("engineRepository"), live_repository))
        if identity.get("coolVersionOverride") != live_commit[:10]:
            failures.append("receipt coolVersionOverride != live commit short id")
        if identity.get("browserPatchLockSHA256") != live_lock_sha:
            failures.append("receipt browserPatchLockSHA256 != live lock bytes digest")
    # -- baseline pin ----------------------------------------------------------
    recorded_original = receipt["inputs"].get("restoredOriginalBundleSHA256")
    if recorded_original != expected_original_bundle_sha256:
        failures.append("receipt original bundle baseline %r != pinned %r"
                        % (recorded_original, expected_original_bundle_sha256))
    # -- internal consistency (never self-contradictory) -----------------------
    if receipt["output"].get("bundleSHA256") != receipt["patchedBuild"].get("distBundleSHA256"):
        failures.append("output.bundleSHA256 != patchedBuild.distBundleSHA256")
    control = receipt["controlBuild"]
    if not control.get("byteIdenticalToRestoredOriginal"):
        failures.append("control build was not byte-identical to the restored original; "
                        "the patched-output claim is not proven for this receipt")
    elif control.get("rebuiltBundleSHA256") != recorded_original:
        failures.append("control rebuiltBundleSHA256 != recorded restored original")
    block = receipt.get("browserResources")
    if not isinstance(block, dict):
        failures.append("receipt has no browserResources block")
    else:
        for key, expected in (
            ("bundleSHA256", receipt["output"].get("bundleSHA256")),
            ("originalBundleSHA256", recorded_original),
            ("engineCommit", identity.get("engineCommit")),
            ("browserPatchLockSHA256", identity.get("browserPatchLockSHA256")),
            ("patchedDistTreeSHA256", receipt["distTree"].get("patchedTreeSHA256")),
            ("dependencyLockSHA256", receipt["dependencyInstall"].get("npmShrinkwrapSHA256")),
        ):
            if block.get(key) != expected:
                failures.append("browserResources.%s inconsistent with receipt detail" % key)
        for value in block.values():
            if isinstance(value, str) and (value.startswith("/") or ":/" in value):
                failures.append("browserResources block must stay path-free")
        block_patches = block.get("patches")
        if block_patches is not None:
            if not isinstance(block_patches, list):
                failures.append("browserResources.patches is not a list")
            elif not isinstance(identity_patches, list) or len(block_patches) != len(identity_patches):
                failures.append("browserResources.patches count differs from frontendIdentity")
            else:
                for index, (claim, detail) in enumerate(zip(block_patches, identity_patches)):
                    if not isinstance(claim, dict):
                        failures.append("browserResources.patches[%d] is not an object" % index)
                        continue
                    for key in ("patch", "patchSHA256", "sourceFile",
                                "originalSourceSHA256", "patchedSourceSHA256"):
                        if claim.get(key) != detail.get(key):
                            failures.append(
                                "browserResources.patches[%d].%s inconsistent" % (index, key))
                    for key in ("patch", "sourceFile"):
                        value = claim.get(key)
                        if isinstance(value, str) and (value.startswith("/") or ":/" in value):
                            failures.append("browserResources.patches must stay path-free")
        elif isinstance(identity_patches, list) and identity_patches:
            # Legacy single-patch receipt block.
            first = identity_patches[0]
            for key in ("patchSHA256", "sourceFile", "originalSourceSHA256",
                        "patchedSourceSHA256"):
                if block.get(key) != first.get(key):
                    failures.append("browserResources.%s inconsistent with patch[0]" % key)
    # -- live patch contract against the staged and repo bytes -----------------
    stage_root = Path(receipt["inputs"]["stageRoot"]) / "source"
    stage_browser = stage_root / "browser"
    if live_entries is not None:
        if not isinstance(identity_patches, list):
            failures.append("receipt has no browser patch inventory")
        elif len(identity_patches) != len(live_entries):
            failures.append("receipt browser patch inventory count differs from the live lock")
        else:
            for index, (patch, live) in enumerate(zip(identity_patches, live_entries)):
                for field in ("patch", "patchSHA256", "sourceFile",
                              "originalSourceSHA256", "patchedSourceSHA256"):
                    if patch.get(field) != live[field]:
                        failures.append("receipt patch %d %s differs from the live lock"
                                        % (index, field))
                if patch.get("stagedPatchedSHA256") != live["patchedSourceSHA256"]:
                    failures.append(
                        "receipt patch %d stagedPatchedSHA256 differs from the live lock"
                        % index)
                if patch.get("applied") is not True:
                    failures.append("receipt patch %d was not applied" % index)
                check("live patch file %d" % index, patch.get("patchPath"),
                      live["patchSHA256"])
            # The staged tree carries the final source of each file chain, not
            # each intermediate state. Re-hash the final file once per chain;
            # the live lock's chained original/patched digests and the
            # receipt's per-entry stagedPatchedSHA256 bind the intermediate
            # states that the producer verified while applying them.
            final_sources = {}
            for live in live_entries:
                final_sources[live["sourceFile"]] = live
            for source_file, final in final_sources.items():
                check("staged final source %s" % source_file,
                      stage_root / source_file,
                      final["patchedSourceSHA256"])
    # -- output and staged bundle bytes ----------------------------------------
    check("staged patched bundle", stage_browser / "dist/bundle.js",
          receipt["patchedBuild"]["distBundleSHA256"])
    check("output bundle", receipt["output"]["bundle"], receipt["output"]["bundleSHA256"])
    try:
        bundle_text = flatten_minified(Path(stage_browser / "dist/bundle.js").read_text(errors="replace"))
        restored_source = receipt["inputs"].get("restoredSourceRoot")
        original_text = None
        if isinstance(restored_source, str) and restored_source:
            restored_root = Path(restored_source) / "browser/dist/bundle.js"
            check("restored original bundle", restored_root, recorded_original)
            original_text = flatten_minified(restored_root.read_text(errors="replace"))
        else:
            failures.append(
                "receipt inputs.restoredSourceRoot is missing; the original "
                "bundle baseline cannot be checked")
        for index, live in enumerate(live_entries or []):
            marker, tokens = entry_evidence(live)
            if marker is None and not tokens:
                failures.append("live patch %d has no marker/token bundle evidence" % index)
                continue
            patched_report = marker_report(bundle_text, marker, tokens)
            if marker is not None and not patched_report["patchMarkerPresent"]:
                failures.append("patch %d marker absent from staged patched bundle" % index)
            if original_text is None:
                # The missing baseline is already a failure; never treat an
                # absent original as a zero-count trust exemption.
                continue
            original_report = marker_report(original_text, marker, tokens)
            if marker is not None and original_report["patchMarkerPresent"]:
                failures.append("restored original bundle already carries patch %d marker" % index)
            for token in tokens:
                if patched_report["tokenCounts"][token] <= original_report["tokenCounts"][token]:
                    failures.append(
                        "patch %d token %r count did not increase in the staged bundle"
                        % (index, token))
    except OSError as error:
        failures.append("staged patched bundle unreadable: %s" % error)
    dep = receipt["dependencyInstall"]
    check("npm-shrinkwrap", stage_browser / "npm-shrinkwrap.json", dep["npmShrinkwrapSHA256"])
    check("package-lock", stage_browser / "package-lock.json", dep["packageLockSHA256"])
    try:
        if shrinkpack_manifest_digest(stage_browser / "node_shrinkpack")[0] != \
                dep["nodeShrinkpackManifestSHA256"]:
            failures.append("node_shrinkpack manifest digest changed")
    except (ProducerError, OSError) as error:
        failures.append("node_shrinkpack recheck failed: %s" % error)
    for rel, expected in receipt["patchedBuild"]["intermediates"].items():
        check(rel, stage_browser / rel, expected)
    modules = receipt["patchedBuild"].get("modules")
    if isinstance(modules, dict) and modules:
        for source_file, spec in modules.items():
            check("patched module JS %s" % source_file,
                  stage_browser / spec["module"], spec["moduleSHA256"])
    else:
        check("patched module JS", stage_browser / MODULE_JS_REL,
              receipt["patchedBuild"]["moduleSHA256"])
    try:
        rows = dist_manifest(stage_browser / "dist")  # in-memory only; never writes
        if tree_digest(rows) != receipt["distTree"]["patchedTreeSHA256"]:
            failures.append("patched dist tree digest changed")
        if len(rows) != receipt["distTree"]["patchedFiles"]:
            failures.append("patched dist file count changed")
    except OSError as error:
        failures.append("dist manifest recheck failed: %s" % error)
    return failures


def build_arg_parser():
    default_repo = Path(__file__).resolve().parent.parent.parent
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", type=Path, default=default_repo)
    parser.add_argument("--restored-source", type=Path, default=DEFAULT_RESTORED_SOURCE,
                        help="read-only restored <...>/bundle-sim4/source")
    parser.add_argument("--stage-root", type=Path, default=DEFAULT_STAGE_ROOT,
                        help="owned target cache root; must be absent or empty")
    parser.add_argument("--output-dir", type=Path, default=None)
    parser.add_argument("--evidence-dir", type=Path,
                        default=default_repo / "Local/Private/pencil-browser-resource-build")
    parser.add_argument("--lock", type=Path,
                        default=default_repo / "FloeAgent/ThirdParty/Collabora/browser.patch.lock.json")
    parser.add_argument("--expected-original-bundle-sha256",
                        default=DEFAULT_EXPECTED_ORIGINAL_BUNDLE_SHA256)
    parser.add_argument("--jobs", type=int, default=2, choices=(1, 2))
    parser.add_argument("--build-lock-runner", default=str(
        default_repo / "Local/Private/ios-closure-20261018/run_local_build.py"),
        help="serialized compile runner; 'none' disables (tests only)")
    parser.add_argument("--allow-toolchain-drift", action="store_true",
                        help="proceed even if the control rebuild is not byte-identical")
    parser.add_argument("--verify-receipt", type=Path, default=None,
                        help="verify an existing receipt and exit (no build)")
    return parser


def main(argv=None):
    args = build_arg_parser().parse_args(argv)
    if args.verify_receipt:
        failures = verify_receipt(args.verify_receipt, lock_path=args.lock,
                                  expected_original_bundle_sha256=args.expected_original_bundle_sha256)
        if failures:
            print("RECEIPT VERIFY FAILED")
            for line in failures:
                print("  - %s" % line)
            return 1
        print("RECEIPT VERIFY OK: %s" % args.verify_receipt)
        return 0
    if str(args.build_lock_runner) != "none" and not Path(args.build_lock_runner).is_file():
        raise ProducerError("build lock runner missing: %s" % args.build_lock_runner)
    producer = Producer(args)
    receipt = producer.run()
    output = receipt["output"]
    print("patched bundle        : %s" % output["bundle"])
    print("patched bundle sha256 : %s (%d bytes)" % (output["bundleSHA256"], output["sizeBytes"]))
    print("control byte-identical: %s" % receipt["controlBuild"]["byteIdenticalToRestoredOriginal"])
    print("receipt               : %s" % (producer.output_dir / "receipt.json"))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ProducerError as error:
        print("FAIL-CLOSED: %s" % error, file=sys.stderr)
        sys.exit(2)
