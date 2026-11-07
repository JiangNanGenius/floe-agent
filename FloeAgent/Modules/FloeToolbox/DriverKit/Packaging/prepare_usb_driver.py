#!/usr/bin/env python3
"""Prepare an opt-in DriverKit source configuration; never build/sign/install.

The default review configuration has no USB matches and produces no App overlay.
Nonempty, explicitly scoped matches produce an OPTIONAL overlay for review. No
entitlement grant, provisioning profile or device compatibility is inferred.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

DRIVER_ID = "org.floeagent.ios.FloeUSBSerialDriver"
SERVICE = "FloeUSBSerialDriver"
USER_CLIENT = "FloeUSBSerialUserClient"
MINIMUM_DRIVERKIT = "27.0"  # The existing object-qualified baseline, not iOS 26 proof.
WIRE_VERSION = 1

# Candidate VID/PIDs already in USBSerialChipPlans.candidate. These are not
# interface facts, permissions or hardware acceptance. Tests fence this table
# to the current Core source; generic CDC class matching is deliberately absent.
KNOWN_PAIRS = {
    0x0403: {0x6001, 0x6010, 0x6011, 0x6014, 0x6015},
    0x10C4: {0xEA60, 0xEA70, 0xEA71},
    0x1A86: {0x7523, 0x5523},
    0x067B: {0x2303},
}
MATCH_FIELDS = {
    "idVendor", "idProduct", "bConfigurationValue", "bInterfaceNumber",
    "bInterfaceClass", "bInterfaceSubClass", "bInterfaceProtocol",
}


def read_matches(path: Path) -> list[dict[str, int]]:
    if path.stat().st_size > 65_536:
        raise ValueError("USB match manifest exceeds 64 KiB")
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or set(data) != {"schemaVersion", "matches"} or type(data["schemaVersion"]) is not int or data["schemaVersion"] != 1:
        raise ValueError("expected USB match schemaVersion 1")
    return validate_matches(data["matches"])


def validate_matches(matches: list[dict[str, int]]) -> list[dict[str, int]]:
    if not isinstance(matches, list) or len(matches) > 32:
        raise ValueError("expected at most 32 exact USB interface matches")
    result = []
    for row in matches:
        if not isinstance(row, dict) or set(row) != MATCH_FIELDS:
            raise ValueError("each USB match requires all seven exact descriptor fields")
        for key, value in row.items():
            maximum = 65_535 if key in {"idVendor", "idProduct"} else 255
            minimum = 1 if key in {"idVendor", "bConfigurationValue"} else 0
            if type(value) is not int or not minimum <= value <= maximum:
                raise ValueError("USB descriptor values must be bounded integers, never wildcards")
        if row["idProduct"] not in KNOWN_PAIRS.get(row["idVendor"], set()):
            raise ValueError("VID/PID is outside the existing reviewed chip candidate table")
        if row in result:
            raise ValueError("duplicate USB interface match")
        result.append(dict(sorted(row.items())))
    return sorted(result, key=lambda x: tuple(x[k] for k in sorted(MATCH_FIELDS)))


def personality(match: dict[str, int]) -> dict:
    return {
        "CFBundleIdentifier": DRIVER_ID,
        "CFBundleIdentifierKernel": "com.apple.kpi.iokit",
        "IOProviderClass": "IOUSBHostInterface",
        "IOClass": "IOUserService",
        "IOUserClass": SERVICE,
        "IOUserServerName": DRIVER_ID,
        "IOMatchCategory": DRIVER_ID,
        "FloeUSBUserClientProperties": {"IOClass": "IOUserUserClient", "IOUserClass": USER_CLIENT},
        **match,
    }


def driver_info(matches: list[dict[str, int]]) -> dict:
    return {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": "Floe USB Serial",
        "CFBundleExecutable": SERVICE,
        "CFBundleIdentifier": DRIVER_ID,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": SERVICE,
        "CFBundlePackageType": "DEXT",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "OSBundleUsageDescription": "Use the USB serial interface you select in Floe.",
        "FloeUSBWireVersion": WIRE_VERSION,
        "FloeUSBMinimumDriverKitVersion": MINIMUM_DRIVERKIT,
        "IOKitPersonalities": {
            f"USB-{m['idVendor']:04X}-{m['idProduct']:04X}-C{m['bConfigurationValue']}-I{m['bInterfaceNumber']}-{index}": personality(m)
            for index, m in enumerate(matches)
        },
    }


def driver_target(app_root: Path, output: Path, team: str) -> dict:
    source = app_root / "Modules/FloeToolbox/DriverKit"
    return {
        "type": "driver-extension",
        # XcodeGen 2.46 has no DriverKit platform enum. Its upstream fixture
        # uses macOS plus SDKROOT; the actual target platform below is DriverKit.
        "platform": "macOS",
        "sources": [{"path": str(source / name), "buildPhase": "sources"} for name in (
            "FloeUSBSerialDriver.iig", "FloeUSBSerialUserClient.iig", "FloeUSBSerialDriver.cpp", "USBSerialBackend.cpp")]
            + [{"path": str(app_root / "Modules/FloeToolbox/Sources/FloeToolboxUSBWire/FloeUSBWire.c"), "buildPhase": "sources"},
               {"path": str(Path(__file__).resolve().parent / "en.lproj"), "buildPhase": "resources"},
               {"path": str(Path(__file__).resolve().parent / "zh-Hans.lproj"), "buildPhase": "resources"}],
        "settings": {"base": {
            "SDKROOT": "driverkit", "SUPPORTED_PLATFORMS": "driverkit", "ARCHS": "arm64",
            "DRIVERKIT_DEPLOYMENT_TARGET": MINIMUM_DRIVERKIT, "MACOSX_DEPLOYMENT_TARGET": "",
            "PRODUCT_NAME": SERVICE, "PRODUCT_BUNDLE_IDENTIFIER": DRIVER_ID,
            "INFOPLIST_FILE": str(output / "Driver-Info.plist"),
            "CODE_SIGN_ENTITLEMENTS": str(output / "Driver.entitlements"),
            "DEVELOPMENT_TEAM": team, "CODE_SIGN_STYLE": "Manual",
            "PROVISIONING_PROFILE_SPECIFIER": "$(FLOE_USB_DRIVER_PROFILE_SPECIFIER)",
            "SKIP_INSTALL": "YES", "GENERATE_INFOPLIST_FILE": "NO",
            "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
            "HEADER_SEARCH_PATHS": ["$(inherited)", '"$(IIG_HEADERS_DIR)"', f'"{source}"',
                                    f'"{app_root / "Modules/FloeToolbox/Sources/FloeToolboxUSBWire/include"}"'],
            "SYSTEM_FRAMEWORK_SEARCH_PATHS": ["$(inherited)", "$(SDKROOT)/System/DriverKit/System/Library/Frameworks"],
        }},
        "dependencies": [
            {"sdk": "System/DriverKit/System/Library/Frameworks/DriverKit.framework"},
            {"sdk": "System/DriverKit/System/Library/Frameworks/USBDriverKit.framework"},
        ],
    }


def prepare(app_root: Path, output: Path, matches: list[dict[str, int]], resolved_spec: dict) -> None:
    matches = validate_matches(matches)
    app_root = app_root.resolve(strict=True)
    output = output.resolve()
    # Source/config generation must not overwrite App files, source, existing
    # signing inputs, or an old reviewed checkpoint.
    if output == app_root or app_root in output.parents or output.exists():
        raise ValueError("output must be a new directory outside the App source tree")
    app = resolved_spec["targets"]["FloeAgent"]
    team = app["settings"]["base"]["DEVELOPMENT_TEAM"]
    app_id = app["settings"]["base"]["PRODUCT_BUNDLE_IDENTIFIER"]
    if not isinstance(team, str) or not team.isalnum() or len(team) != 10 or app_id != "org.floeagent.ios":
        raise ValueError("cannot resolve the existing Floe App/team identity")
    source_entitlements = (app_root / app["entitlements"]["path"]).resolve(strict=True)
    if not source_entitlements.is_relative_to(app_root):
        raise ValueError("App entitlements must resolve within its actual source root")
    host_entitlements = plistlib.loads(source_entitlements.read_bytes())
    host_entitlements["com.apple.developer.driverkit.communicates-with-drivers"] = True
    driver_entitlements = {"com.apple.developer.driverkit": True, "com.apple.developer.driverkit.transport.usb": matches}
    target = driver_target(app_root, output, team)
    standalone = {"name": "FloeUSBDriverReview", "targets": {SERVICE: target},
        "schemes": {"FloeUSBDriverReview": {"build": {"targets": {SERVICE: "all"}}}}}
    output.mkdir(parents=True)
    for name, value in (("Driver-Info.plist", driver_info(matches)), ("Driver.entitlements", driver_entitlements),
                        ("Host.entitlements", host_entitlements)):
        (output / name).write_bytes(plistlib.dumps(value, sort_keys=True))
    (output / "driver-project.json").write_text(json.dumps(standalone, indent=2) + "\n")
    # Empty review defaults are intentionally incapable of embedding or enabling
    # a USB host in the current five-bundle App.
    if matches:
        overlay = {
            "include": [str(app_root / "project.yml")],
            "name": "FloeAgentUSBReview",
            "targets": {
                SERVICE: target,
                "FloeAgent": {
                    "entitlements": {"path": str(output / "Host.entitlements"), "properties": host_entitlements},
                    "settings": {"base": {"CODE_SIGN_ENTITLEMENTS": str(output / "Host.entitlements")}},
                    "dependencies": [
                        {"package": "FloeToolbox", "product": "FloeToolboxUSB"},
                        {"target": SERVICE, "embed": True, "link": False, "codeSign": True,
                         "copy": {"destination": "productsDirectory", "subpath": "$(SYSTEM_EXTENSIONS_FOLDER_PATH)"}},
                    ],
                },
            },
        }
        (output / "app-overlay.json").write_text(json.dumps(overlay, indent=2) + "\n")
    plan = {"schemaVersion": 1, "driverBundleIdentifier": DRIVER_ID, "matchCount": len(matches),
        "appOverlayProduced": bool(matches), "baseSpecDefinesDriverTarget": SERVICE in resolved_spec["targets"],
        "entitlementGrantVerified": False, "profileVerified": False, "compiled": False,
        "installed": False, "hardwareVerified": False,
        "sourceEntitlementsSHA256": hashlib.sha256(source_entitlements.read_bytes()).hexdigest(),
        "minimumDriverKitVersion": MINIMUM_DRIVERKIT,
        "nextBoundary": "Review actual interface scope and matching App/driver entitlement grants/profiles before any signed packaging."}
    (output / "packaging-plan.json").write_text(json.dumps(plan, indent=2) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-root", type=Path, required=True, help="actual FloeAgent directory")
    parser.add_argument("--matches", type=Path, default=Path(__file__).with_name("matches.review.json"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    spec = subprocess.run(["xcodegen", "dump", "--no-env", "--type", "json", "--spec", str(args.app_root / "project.yml")],
        check=True, capture_output=True, text=True)
    prepare(args.app_root, args.output, read_matches(args.matches), json.loads(spec.stdout))


if __name__ == "__main__":
    main()
