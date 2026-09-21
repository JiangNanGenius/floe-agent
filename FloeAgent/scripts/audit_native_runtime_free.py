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
"""
import argparse
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
    args = parser.parse_args()

    findings = []
    ran = False
    if args.project or (not args.app and not args.ipa):
        ran = True
        findings.extend(audit_project())
    if args.app:
        ran = True
        findings.extend(audit_app(args.app))
    if args.ipa:
        ran = True
        findings.extend(audit_ipa(args.ipa))
    if not ran:
        parser.error("choose --project, --app or --ipa")

    if findings:
        print("native Python/Node markers found (Phase 2 forbids them):")
        for finding in findings[:50]:
            print(f"  {finding}")
        if len(findings) > 50:
            print(f"  … and {len(findings) - 50} more")
        return 1
    print("native-runtime-free audit passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
