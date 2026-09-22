#!/usr/bin/env python3
"""Fail the build if a bundled native Python/Node payload reappears.

Phase 2 (TinyEMU migration) removed the in-process CPython and nodejs-mobile
runtimes from the app: local Python/Node execute inside each environment's
TinyEMU Linux guest. This audit is the anti-regression gate with two modes:

  --project   Lint project.yml and Package.swift for the retired embed,
              resource, build and download paths (no build required).
  --app PATH  Audit a built .app bundle (or .ipa via --ipa) for native
              Python/Node markers in its file list and embedded frameworks.

Both modes exit non-zero with a named finding per violation. Keep the markers
lean and exact: they name artifacts the retired pipeline produced, never a
legitimate remaining component (PDFium, LibArchive, dash, Office, Whisper).

Two further gates cover the Linux-convergence contract without touching any
artifact or license:

  --keepalive   Fail if a silent-audio/keepalive keep-alive pattern reappears in
                the background-execution or Linux-guest code paths. Explicit
                user work runs under the system continued-processing task, not
                an inaudible audio session.
  --convergence Verify the generic-runtime convergence declarations: retired
                interpreter tool names are declared Linux-guest routed, and
                every signed catalog package still has recorded provenance.
                Read-only: no catalog, artifact or license is modified.
"""
import argparse
import json
import re
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# File/path markers inside a built bundle that only the retired native
# Python/Node pipeline could produce.
BUNDLE_MARKERS = [
    (re.compile(r"(^|/)Python\.framework/"), "embedded Python.framework"),
    (re.compile(r"(^|/)NodeMobile\.framework/"), "embedded NodeMobile.framework"),
    (re.compile(r"(^|/)[A-Za-z0-9_.]*cpython-3\d+", re.IGNORECASE), "CPython extension binary"),
    (re.compile(r"(^|/)lib/python3\.\d+/"), "bundled Python standard library"),
    (re.compile(r"(^|/)PythonServiceBootstrap\.py$"), "Python service bootstrap resource"),
    (re.compile(r"(^|/)NodeTools/"), "bundled NodeTools resources"),
    (re.compile(r"(^|/)site-packages/"), "bundled Python site-packages"),
    (re.compile(r"(^|/)node_modules/(npm|pnpm|yarn)/"), "bundled Node package managers"),
    # Precompiled wheel dependencies were resolved at App build time for the
    # retired in-process interpreter. Linux (pip/venv inside the guest) or the
    # audited skill installer own them now; a .whl inside the App is the
    # retired delivery path returning.
    (re.compile(r"\.whl$", re.IGNORECASE), "bundled precompiled Python wheel"),
    # Native Ruby/Rust runtimes: Ruby ships only as a WASM interpreter under
    # Qualification/ThirdParty, Rust crates are compiled into the App, so a
    # runtime library or interpreter binary in the bundle is a payload.
    (re.compile(r"(^|/)(ruby|ruby[0-9.]+)$"), "bundled native Ruby interpreter"),
    (re.compile(r"(^|/)libruby[a-z0-9_.-]*\.dylib$", re.IGNORECASE), "bundled native Ruby library"),
    (re.compile(r"(^|/)libstd-[0-9a-f]+\.dylib$"), "bundled Rust standard library"),
]

# Embedded framework directory names the retired pipeline signed into the app
# (stdlib extensions and ios-wheelhouse wheels). Name-exact, not substrings.
FRAMEWORK_MARKERS = re.compile(
    r"(^|/)(Python|NodeMobile|_asyncio|_contextvars|_queue|_multibytecodec|"
    r"_codecs_[a-z0-9]+|_sha1|_sha2|_sha3|_md5|_dbm|_lsprof|cmath|_bisect|"
    r"_blake2|_bz2|_csv|_ctypes|_datetime|_decimal|_elementtree|_hashlib|"
    r"_heapq|_json|_lzma|_opcode|_pickle|_random|_socket|_sqlite3|_ssl|"
    r"_statistics|_struct|_uuid|_zoneinfo|array|binascii|fcntl|math|mmap|"
    r"pyexpat|resource|select|termios|unicodedata|zlib|_bounded_integers|"
    r"_brotli|_common|_generator|_imaging[a-z_]*|_mt19937|_multiarray[a-z_]*|"
    r"_operand_flag_tests|_pcg64|_philox|_pocketfft_umath|_rational_tests|"
    r"_sfc64|_simd|_struct_ufunc_tests|_umath[a-z_]*|bit_generator|"
    r"frozenlist__frozenlist|greenlet__greenlet|lapack_lite|lxml_[a-z_]+|"
    r"mtrand|multidict__multidict|pandas__[a-z_]+|regex__regex|"
    r"zstandard_backend_c)\.framework/"
)

# Source-of-truth references that must never return to the project manifests.
PROJECT_MARKERS = [
    ("Vendor/Python.xcframework", "Python xcframework embed"),
    ("Vendor/PythonExtensions", "Python extension embeds"),
    ("Vendor/NodeMobile", "NodeMobile embed"),
    ("Resources/python", "bundled Python stdlib resource"),
    ("Resources/NodeTools", "bundled Node tools resource"),
    ("PythonServiceBootstrap", "Python service bootstrap"),
    ("managed_package_install", "in-process managed pip installer"),
    ("managed_package_remove", "in-process managed pip uninstaller"),
    ("bootstrap_python_runtime", "CPython bootstrap"),
    ("pin_node_tools", "Node tools download"),
    ("install_python_binary_packages", "iOS wheel embeds"),
    ("install_python_bundled_packages", "bundled pure-Python preset"),
    ("package_python_extensions", "Python extension packaging"),
    ("build_ios_wheel", "ios-wheelhouse build"),
    ("build_pandas_ios", "pandas iOS build"),
    ("prepare_pandas_ios", "pandas iOS preparation"),
    ("prepare_lxml_ios", "lxml iOS preparation"),
    ("install_pandas_pure_dependencies", "pandas pure dependencies"),
    ("ios_wheelhouse", "ios-wheelhouse driver"),
    ("pin_python_bundled_packages", "bundled Python pins"),
    ("Vendor/Ruby", "Ruby runtime embed"),
    ("Vendor/Rust", "Rust runtime embed"),
    ("ruby_runtime", "Ruby runtime payload"),
    ("rust_runtime", "Rust runtime payload"),
]

# Manifest references that only the retired precompiled-wheel delivery path
# would produce. Checked per line so a name in a comment is reported too.
MANIFEST_PAYLOAD_MARKERS = [
    (re.compile(r"\.whl\b", re.IGNORECASE), "bundled precompiled wheel"),
    (re.compile(r"wheelhouse", re.IGNORECASE), "wheelhouse reference"),
]

# Silent-audio/keep-alive patterns. The app must never keep itself alive with
# an inaudible audio session: explicit user work uses the system
# continued-processing task plus the bounded completion lease. Checked only in
# the background-execution and Linux-guest sources so unrelated prose or a
# legitimate AVPlayer audio-session configuration is not flagged.
KEEPALIVE_MARKERS = [
    (re.compile(r"silent[-_ ]?audio", re.IGNORECASE), "silent-audio keepalive"),
    (re.compile(r"(silent|inaudible)[A-Za-z]*[Aa]udio(Player|Track|Loop|Engine)"),
     "silent audio player/track/loop"),
    (re.compile(r"SilentAudioKeepAlive", re.IGNORECASE), "silent audio keep-alive type"),
    (re.compile(r"keepAlive(Silent)?Track", re.IGNORECASE), "keep-alive audio track"),
    (re.compile(r"silenceLoop", re.IGNORECASE), "silence loop"),
]

KEEPALIVE_SOURCE_DIRS = [
    "FloeAgent/FloeApp/Platform",
    "FloeAgent/Sources/FloeExecution/Linux",
]

# Generic interpreter surfaces that converged on the Linux guest. Each name
# must be declared Linux-routed in the capability router; a native/bundled
# payload for one of them is a regression.
CONVERGED_RUNTIME_TOOL_NAMES = ["exec.wasm", "exec.compatEvaluator", "wasm.packages"]

CAPABILITY_ROUTER_SOURCE = "FloeAgent/Sources/FloeTools/CapabilityExecutionRouter.swift"
CAPABILITY_CATALOG = "capability-hub/catalog.json"
CAPABILITY_LANGUAGES_DOC = "capability-hub/LANGUAGES.md"


def audit_keepalive(root=None):
    """Fail when a silent-audio/keep-alive pattern returns to the sources."""
    base = Path(root) if root else ROOT.parent
    findings = []
    for relative in KEEPALIVE_SOURCE_DIRS:
        directory = base / relative
        if not directory.exists():
            continue
        for path in sorted(directory.rglob("*.swift")):
            text = path.read_text(errors="ignore")
            for line_number, line in enumerate(text.splitlines(), start=1):
                for pattern, label in KEEPALIVE_MARKERS:
                    if pattern.search(line):
                        findings.append(
                            f"{path.relative_to(base)}:{line_number}: {label}: {line.strip()}"
                        )
                        break
    return findings


def audit_convergence(root=None):
    """Verify Linux convergence declarations and catalog provenance."""
    base = Path(root) if root else ROOT.parent
    findings = []

    router = base / CAPABILITY_ROUTER_SOURCE
    router_text = router.read_text(errors="ignore") if router.exists() else ""
    if not router.exists():
        findings.append(f"{CAPABILITY_ROUTER_SOURCE}: capability router is missing")
    else:
        for tool_name in CONVERGED_RUNTIME_TOOL_NAMES:
            if f'"{tool_name}"' not in router_text:
                findings.append(
                    f"{CAPABILITY_ROUTER_SOURCE}: converged runtime tool {tool_name} is not declared"
                )
        if "linuxGuest" not in router_text:
            findings.append(f"{CAPABILITY_ROUTER_SOURCE}: no Linux guest backend declared")

    catalog = base / CAPABILITY_CATALOG
    if not catalog.exists():
        findings.append(f"{CAPABILITY_CATALOG}: signed catalog is missing")
        return findings
    try:
        document = json.loads(catalog.read_text())
    except (OSError, ValueError) as error:
        findings.append(f"{CAPABILITY_CATALOG}: unreadable catalog: {error}")
        return findings
    packages = document.get("packages")
    if not isinstance(packages, list) or not packages:
        findings.append(f"{CAPABILITY_CATALOG}: no signed packages recorded")
        return findings
    languages_doc = base / CAPABILITY_LANGUAGES_DOC
    languages_text = languages_doc.read_text(errors="ignore") if languages_doc.exists() else ""
    for package in packages:
        for field in ("id", "version", "sha256", "url"):
            if not package.get(field):
                findings.append(
                    f"{CAPABILITY_CATALOG}: package {package.get('id', '?')} has no {field}"
                )
        identifier = package.get("id")
        if identifier and identifier not in languages_text:
            findings.append(
                f"{CAPABILITY_LANGUAGES_DOC}: provenance for {identifier} is not recorded"
            )
    return findings


def audit_paths(paths, source):
    findings = []
    for path in paths:
        normalized = "/" + path.lstrip("/")
        for pattern, label in BUNDLE_MARKERS:
            if pattern.search(normalized):
                findings.append(f"{source}: {label}: {path}")
                break
        else:
            match = FRAMEWORK_MARKERS.search(normalized)
            if match:
                findings.append(f"{source}: retired extension framework: {path}")
    return findings


def audit_app(bundle):
    findings = []
    for candidate in bundle.rglob("*"):
        if candidate.is_symlink() or candidate.is_dir():
            continue
        relative = candidate.relative_to(bundle).as_posix()
        findings.extend(audit_paths([relative], str(bundle)))
    return findings


def audit_ipa(ipa):
    with zipfile.ZipFile(ipa) as archive:
        return audit_paths([name for name in archive.namelist() if not name.endswith("/")], str(ipa))


def audit_project():
    findings = []
    for manifest in [ROOT / "project.yml", ROOT / "Package.swift"]:
        if not manifest.exists():
            continue
        text = manifest.read_text()
        for needle, label in PROJECT_MARKERS:
            if needle in text:
                findings.append(f"{manifest.name}: {label} reference returned: {needle}")
        for line_number, line in enumerate(text.splitlines(), start=1):
            for pattern, label in MANIFEST_PAYLOAD_MARKERS:
                if pattern.search(line):
                    findings.append(f"{manifest.name}:{line_number}: {label}: {line.strip()}")
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", action="store_true", help="lint project.yml/Package.swift")
    parser.add_argument("--app", type=Path, help="audit a built .app bundle")
    parser.add_argument("--ipa", type=Path, help="audit a packaged .ipa (file list only)")
    parser.add_argument(
        "--keepalive", action="store_true",
        help="lint background/Linux sources for silent-audio keepalive patterns",
    )
    parser.add_argument(
        "--convergence", action="store_true",
        help="verify Linux convergence declarations and signed catalog provenance",
    )
    args = parser.parse_args()

    findings = []
    ran = False
    default_run = (
        not args.app and not args.ipa and not args.project
        and not args.keepalive and not args.convergence
    )
    if args.project or default_run:
        ran = True
        findings.extend(audit_project())
    if args.keepalive or default_run:
        ran = True
        findings.extend(audit_keepalive())
    if args.convergence or default_run:
        ran = True
        findings.extend(audit_convergence())
    if args.app:
        ran = True
        findings.extend(audit_app(args.app))
    if args.ipa:
        ran = True
        findings.extend(audit_ipa(args.ipa))
    if not ran:
        parser.error("choose --project, --keepalive, --convergence, --app or --ipa")

    if findings:
        print("native-runtime/keepalive/convergence markers found (forbidden):")
        for finding in findings[:50]:
            print(f"  {finding}")
        if len(findings) > 50:
            print(f"  … and {len(findings) - 50} more")
        return 1
    print("native-runtime-free audit passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
