#!/usr/bin/env python3
"""Verify the BootstrapCanary package topology and linkage boundaries."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


BUNDLE_ID = "org.floeagent.iosbridge"
TEST_BUNDLE_NAME = "BootstrapCanaryUITests.xctest"
FORBIDDEN_HOST_LOADS = ("XCTest", "XCTestCore", "XCUIAutomation", "XCTAutomationSupport", "libXCTest")
REQUIRED_TEST_LOADS = ("XCTest.framework/XCTest", "XCUIAutomation.framework/XCUIAutomation")
REQUIRED_HOST_RPATHS = (
    "/System/Developer/Library/Frameworks",
    "/System/Developer/Library/PrivateFrameworks",
    "/System/Developer/usr/lib",
    "/Developer/Library/Frameworks",
    "/Developer/Library/PrivateFrameworks",
    "/Developer/usr/lib",
    "/private/preboot/Cryptexes/OS/System/Developer/Library/Frameworks",
    "/private/preboot/Cryptexes/OS/System/Developer/Library/PrivateFrameworks",
    "/private/preboot/Cryptexes/OS/System/Developer/usr/lib",
)
REQUIRED_TEST_RPATHS = (
    "/System/Developer/Library/Frameworks",
    "/System/Developer/Library/PrivateFrameworks",
    "/System/Developer/usr/lib",
    "/Developer/Library/Frameworks",
    "/Developer/Library/PrivateFrameworks",
    "/Developer/usr/lib",
    "/private/preboot/Cryptexes/OS/System/Developer/Library/Frameworks",
    "/private/preboot/Cryptexes/OS/System/Developer/Library/PrivateFrameworks",
    "/private/preboot/Cryptexes/OS/System/Developer/usr/lib",
)


def run(command: list[str], check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, text=True, capture_output=True, check=check)


def plist_raw(path: Path, key: str) -> str | None:
    result = run(["/usr/bin/plutil", "-extract", key, "raw", "-o", "-", str(path)])
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def plist_json(path: Path, key: str):
    result = run(["/usr/bin/plutil", "-extract", key, "json", "-o", "-", str(path)])
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def linked_libraries(binary: Path) -> list[str]:
    result = run(["/usr/bin/otool", "-L", str(binary)])
    if result.returncode != 0:
        return []
    lines = result.stdout.splitlines()[1:]
    libraries = []
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        libraries.append(stripped.split(" (compatibility")[0])
    return libraries


def rpaths(binary: Path) -> list[str]:
    result = run(["/usr/bin/otool", "-l", str(binary)])
    if result.returncode != 0:
        return []
    values = []
    lines = result.stdout.splitlines()
    for index, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH" and index + 2 < len(lines):
            path_line = lines[index + 2].strip()
            if path_line.startswith("path "):
                values.append(path_line[len("path "):].split(" (offset")[0])
    return values


def undefined_symbols(binary: Path) -> list[str]:
    result = run(["/usr/bin/nm", "-u", str(binary)])
    if result.returncode != 0:
        return []
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def file_description(binary: Path) -> str:
    result = run(["/usr/bin/file", str(binary)])
    return result.stdout.strip() if result.returncode == 0 else ""


def check(name: str, ok: bool, detail: str) -> dict:
    return {"name": name, "ok": bool(ok), "detail": detail}


def check_app(app: Path, require_unsigned: bool = True) -> dict:
    checks: list[dict] = []

    def add(name: str, ok: bool, detail: str) -> None:
        checks.append(check(name, ok, detail))

    add("app-directory", app.is_dir(), str(app))
    if not app.is_dir():
        return {"app": str(app), "checks": checks, "failures": [item["name"] for item in checks if not item["ok"]]}

    host_plist = app / "Info.plist"
    host_binary = app / "BootstrapCanary"
    add("host-info-plist", host_plist.is_file(), str(host_plist))
    add("host-executable", host_binary.is_file(), str(host_binary))
    add("host-bundle-id", plist_raw(host_plist, "CFBundleIdentifier") == BUNDLE_ID,
        str(plist_raw(host_plist, "CFBundleIdentifier")))
    background_modes = plist_json(host_plist, "UIBackgroundModes") or []
    add("host-background-continuous", "continuous" in background_modes, str(background_modes))
    add("host-arch-arm64", "arm64" in file_description(host_binary), file_description(host_binary))

    test_bundle = app / "PlugIns" / TEST_BUNDLE_NAME
    test_binary = test_bundle / "BootstrapCanaryUITests"
    test_plist = test_bundle / "Info.plist"
    add("test-bundle-present", test_bundle.is_dir(), str(test_bundle))
    add("test-executable", test_binary.is_file(), str(test_binary))
    add("test-info-plist", test_plist.is_file(), str(test_plist))
    if test_plist.is_file():
        test_id = plist_raw(test_plist, "CFBundleIdentifier")
        add("test-bundle-id-aligns-host", test_id == BUNDLE_ID, str(test_id))
        test_contains = plist_raw(test_plist, "XCTContainsUITests")
        add("test-contains-ui-tests", test_contains in {"true", "YES", "1"}, str(test_contains))
    if test_binary.is_file():
        add("test-arch-arm64", "arm64" in file_description(test_binary), file_description(test_binary))

    host_loads = linked_libraries(host_binary) if host_binary.is_file() else []
    host_forbidden = [item for item in host_loads if any(token in item for token in FORBIDDEN_HOST_LOADS)]
    add("host-no-xctest-load", not host_forbidden, json.dumps(host_forbidden))
    host_undefined = undefined_symbols(host_binary) if host_binary.is_file() else []
    xctest_symbols = [item for item in host_undefined if "XCTestMain" in item]
    add("host-no-xctest-main-symbol", not xctest_symbols, json.dumps(xctest_symbols))
    host_rpaths = rpaths(host_binary) if host_binary.is_file() else []
    missing_host_rpaths = [item for item in REQUIRED_HOST_RPATHS if item not in host_rpaths]
    add("host-ddi-rpaths", not missing_host_rpaths, json.dumps(missing_host_rpaths))

    if test_binary.is_file():
        test_loads = linked_libraries(test_binary)
        missing_loads = [item for item in REQUIRED_TEST_LOADS if not any(item in load for load in test_loads)]
        add("test-links-xctest-and-xcui", not missing_loads, json.dumps(missing_loads))
        test_rpaths = rpaths(test_binary)
        missing_rpaths = [item for item in REQUIRED_TEST_RPATHS if item not in test_rpaths]
        add("test-ddi-rpaths", not missing_rpaths, json.dumps(missing_rpaths))

    nested_apps = [str(path.relative_to(app)) for path in app.rglob("*.app") if path != app]
    add("no-nested-app", not nested_apps, json.dumps(nested_apps))
    nested_extensions = [str(path.relative_to(app)) for path in app.rglob("*.appex")]
    add("no-appex", not nested_extensions, json.dumps(nested_extensions))
    xctest_bundles = [str(path.relative_to(app)) for path in app.rglob("*.xctest")]
    add("exactly-one-xctest", xctest_bundles == [f"PlugIns/{TEST_BUNDLE_NAME}"], json.dumps(xctest_bundles))
    ddi_frameworks = [
        str(path.relative_to(app))
        for path in app.rglob("*")
        if path.is_dir() and path.name in {"XCTest.framework", "XCTestCore.framework", "XCUIAutomation.framework"}
    ]
    add("no-bundled-xctest-frameworks", not ddi_frameworks, json.dumps(ddi_frameworks))

    signatures = [str(path.relative_to(app)) for path in app.rglob("_CodeSignature")]
    profiles = [str(path.relative_to(app)) for path in app.rglob("embedded.mobileprovision")]
    add("unsigned-no-code-signature", (not signatures) if require_unsigned else True, json.dumps(signatures))
    add("unsigned-no-profile", (not profiles) if require_unsigned else True, json.dumps(profiles))

    failures = [item["name"] for item in checks if not item["ok"]]
    return {
        "app": str(app),
        "checks": checks,
        "failures": failures,
        "ok": not failures,
        "hostLoads": host_loads,
        "hostRpaths": host_rpaths,
        "testLoads": linked_libraries(test_binary) if test_binary.is_file() else [],
        "testRpaths": rpaths(test_binary) if test_binary.is_file() else [],
    }


def check_ipa(ipa: Path, require_unsigned: bool = True) -> dict:
    checks: list[dict] = []
    if not ipa.is_file():
        return {"ipa": str(ipa), "checks": [check("ipa-exists", False, str(ipa))], "failures": ["ipa-exists"]}

    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
    top_apps = sorted({name.split("/")[1] for name in names if name.startswith("Payload/") and len(name.split("/")) > 2 and name.split("/")[1].endswith(".app")})
    checks.append(check("ipa-single-app", top_apps == ["BootstrapCanary.app"], json.dumps(top_apps)))
    checks.append(check("ipa-payload-prefix", all(name.startswith("Payload/") for name in names), "all entries under Payload/"))
    checks.append(check("ipa-no-macosx", not any(name.startswith("__MACOSX") for name in names), "no __MACOSX"))
    if require_unsigned:
        checks.append(check("ipa-no-signature-dir", not any("_CodeSignature/" in name for name in names), "no _CodeSignature"))
        checks.append(check("ipa-no-embedded-profile", not any(name.endswith("embedded.mobileprovision") for name in names), "no embedded.mobileprovision"))

    with tempfile.TemporaryDirectory(prefix="bootstrap-canary-verify-") as temporary:
        with zipfile.ZipFile(ipa) as archive:
            archive.extractall(temporary)
        app = Path(temporary) / "Payload" / "BootstrapCanary.app"
        app_result = check_app(app, require_unsigned=require_unsigned)
    checks.extend(app_result["checks"])
    failures = [item["name"] for item in checks if not item["ok"]]
    return {
        "ipa": str(ipa),
        "checks": checks,
        "failures": failures,
        "ok": not failures,
        "appResult": app_result,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app")
    parser.add_argument("--ipa")
    parser.add_argument("--allow-signed", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    if not args.app and not args.ipa:
        parser.error("provide --app and/or --ipa")

    result = {}
    ok = True
    if args.app:
        result["app"] = check_app(Path(args.app), require_unsigned=not args.allow_signed)
        ok = ok and result["app"]["ok"]
    if args.ipa:
        result["ipa"] = check_ipa(Path(args.ipa), require_unsigned=not args.allow_signed)
        ok = ok and result["ipa"]["ok"]
    result["ok"] = ok

    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        for section in ("app", "ipa"):
            if section in result:
                print(f"[{section}] ok={result[section]['ok']}")
                for item in result[section]["checks"]:
                    print(f"  {'OK' if item['ok'] else 'FAIL'}  {item['name']}: {item['detail']}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
