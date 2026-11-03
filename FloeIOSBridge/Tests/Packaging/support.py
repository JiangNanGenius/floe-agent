"""Hermetic fixtures for the Bridge packaging/verification tests."""

from __future__ import annotations

import os
import plistlib
import shutil
import sys
import zipfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import verify_bridge as vb  # noqa: E402


def read_plist(path: Path) -> dict:
    with path.open("rb") as handle:
        return plistlib.load(handle)


def write_plist(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=True)


def project_yml_text(
    marketing: str = "1.0.0",
    build: str = "14",
    prototype_compilation: bool = False,
    override: tuple[str, str] | None = None,
) -> str:
    override_marketing, override_build = override or (marketing, build)
    lines = [
        "name: FloeIOSBridge",
        "options:",
        "  deploymentTarget:",
        '    iOS: "26.0"',
        "settings:",
        "  base:",
        f'    MARKETING_VERSION: "{marketing}"',
        f'    CURRENT_PROJECT_VERSION: "{build}"',
        "targets:",
        "  BridgeCore:",
        "    type: framework",
        "    settings:",
        "      base:",
        f'        MARKETING_VERSION: "{override_marketing}"',
        f'        CURRENT_PROJECT_VERSION: "{override_build}"',
        "  BridgeTunnel:",
        "    type: app-extension",
        "  BridgeTests:",
        "    type: bundle.ui-testing",
        "  BridgeHost:",
        "    type: application",
    ]
    if prototype_compilation:
        lines.extend([
            "    settings:",
            "      base:",
            '        SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) BRIDGE_PROTOTYPE_DIAGNOSTICS"',
        ])
    return "\n".join(lines) + "\n"


def write_source_root(
    root: Path,
    marketing: str = "1.0.0",
    build: str = "14",
    prototype: bool = False,
    project_text: str | None = None,
) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    (root / "project.yml").write_text(
        project_text if project_text is not None else project_yml_text(
            marketing, build, prototype_compilation=prototype
        )
    )
    bridge = root / "Sources" / "BridgeCore" / "BridgeBuild.swift"
    bridge.parent.mkdir(parents=True, exist_ok=True)
    bridge.write_text(
        "public enum BridgeBuild {\n"
        f'    public static let marketingVersion = "{marketing}"\n'
        f'    public static let buildNumber = "{build}"\n'
        f'    public static let prototypeDiagnostics = {"true" if prototype else "false"}\n'
        "}\n"
    )
    notices = root / "ThirdParty"
    for relative, content in (
        ("iCTRL/LICENSE", "iCTRL license fixture\n"),
        ("iCTRL/NOTICE.md", "iCTRL notice fixture\n"),
        ("idevice/LICENSE", "idevice license fixture\n"),
    ):
        path = notices / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
    return root


def identity_for(root: Path) -> vb.BuildIdentity:
    return vb.load_project_identity(root / "project.yml")


DEFAULT_UUIDS = {
    "host": "11111111-1111-4111-8111-111111111111",
    "appex": "22222222-2222-4222-8222-222222222222",
    "test": "33333333-3333-4333-8333-333333333333",
    "core": "44444444-4444-4444-8444-444444444444",
}
DSYM_UUIDS = {
    "BridgeHost.app.dSYM": ("host", DEFAULT_UUIDS["host"]),
    "BridgeTunnel.appex.dSYM": ("appex", DEFAULT_UUIDS["appex"]),
    "BridgeCore.framework.dSYM": ("core", DEFAULT_UUIDS["core"]),
    "BridgeTests.xctest.dSYM": ("test", DEFAULT_UUIDS["test"]),
}


def role_for(path: Path) -> str:
    parts = path.parts
    if path.name == "BridgeHost":
        return "host"
    if path.name == "BridgeTunnel":
        return "appex"
    if path.name == "BridgeTests":
        return "test"
    if path.name == "BridgeCore":
        if "PlugIns" in parts and any(part.endswith(".appex") for part in parts):
            return "appex-core"
        return "core"
    return "unknown"


class FakeMachOProbe:
    """Deterministic stand-in for otool/file/nm/dwarfdump."""

    def __init__(self, overrides: dict | None = None):
        self.overrides = overrides or {}

    def _config(self, role: str) -> dict:
        defaults = {
            "file": {
                "host": "Mach-O 64-bit executable arm64",
                "appex": "Mach-O 64-bit executable arm64",
                "test": "Mach-O 64-bit bundle arm64",
                "core": "Mach-O 64-bit dynamically linked shared library arm64",
                "appex-core": "Mach-O 64-bit dynamically linked shared library arm64",
            }.get(role, "Mach-O 64-bit executable arm64"),
            "loads": [],
            "rpaths": [],
            "undefined": [],
            "globals": [],
            "install": "",
            "uuid": DEFAULT_UUIDS.get("core" if role == "appex-core" else role, ""),
            "platform": 2,
            "minos": "26.0",
            "sdk": "27.1",
            "filetype": {
                "host": "EXECUTE",
                "appex": "EXECUTE",
                "test": "BUNDLE",
                "core": "DYLIB",
                "appex-core": "DYLIB",
            }.get(role, "EXECUTE"),
            "strings": [],
        }
        if role in {"host", "appex", "test"}:
            defaults["loads"] = [
                "@rpath/BridgeCore.framework/BridgeCore",
                "/System/Library/Frameworks/Foundation.framework/Foundation",
            ]
        if role == "test":
            defaults["loads"] = [
                "@rpath/XCTest.framework/XCTest",
                "@rpath/XCUIAutomation.framework/XCUIAutomation",
                "@rpath/BridgeCore.framework/BridgeCore",
                "/System/Library/Frameworks/Foundation.framework/Foundation",
            ]
        if role == "core" or role == "appex-core":
            defaults["install"] = "@rpath/BridgeCore.framework/BridgeCore"
        if role == "host":
            defaults["rpaths"] = list(vb.REQUIRED_HOST_RPATHS) + ["@executable_path/Frameworks"]
            defaults["globals"] = ["_tunnel_create_rppairing"]
        if role == "appex":
            defaults["rpaths"] = ["@executable_path/Frameworks"]
        if role == "test":
            defaults["rpaths"] = ["@loader_path/../../Frameworks"]
        defaults.update(self.overrides.get(role, {}))
        return defaults

    def file_description(self, binary: Path) -> str:
        return self._config(role_for(binary))["file"]

    def linked_libraries(self, binary: Path) -> list[str]:
        return list(self._config(role_for(binary))["loads"])

    def rpaths(self, binary: Path) -> list[str]:
        return list(self._config(role_for(binary))["rpaths"])

    def undefined_symbols(self, binary: Path) -> list[str]:
        return list(self._config(role_for(binary))["undefined"])

    def global_symbols(self, binary: Path) -> list[str]:
        return list(self._config(role_for(binary))["globals"])

    def installed_name(self, binary: Path) -> str:
        return self._config(role_for(binary))["install"]

    def macho(self, binary: Path) -> vb.MachOInfo:
        config = self._config(role_for(binary))
        return vb.MachOInfo(
            magic="MH_MAGIC_64",
            cpu="ARM64",
            filetype=config["filetype"],
            platform=config["platform"],
            minos=config["minos"],
            sdk=config["sdk"],
        )

    def uuids(self, binary: Path) -> dict[str, str]:
        if binary.name in DSYM_UUIDS:
            _, uuid = DSYM_UUIDS[binary.name]
            return {"arm64": uuid}
        config = self._config(role_for(binary))
        return {"arm64": config["uuid"]} if config["uuid"] else {}

    def strings(self, binary: Path) -> list[str]:
        return list(self._config(role_for(binary))["strings"])


def make_app(
    root: Path,
    identity: vb.BuildIdentity,
    mode: str = vb.QUALIFICATION,
    versions: dict | None = None,
    probe: FakeMachOProbe | None = None,
    signed: bool = False,
    bundle_ids: dict[str, str] | None = None,
    background_modes: list[str] | None = None,
) -> Path:
    versions = versions or {}
    bundle_ids = bundle_ids or vb.canonical_bundle_ids()
    if background_modes is None:
        background_modes = ["continuous"] if mode == vb.QUALIFICATION else []
    source_root = root / "source"
    if not source_root.exists():
        write_source_root(
            source_root,
            identity.marketing_version,
            identity.build_number,
            prototype=mode == vb.QUALIFICATION,
        )
    app = root / "BridgeHost.app"
    app.mkdir(parents=True, exist_ok=True)
    (app / "BridgeHost").write_bytes(b"host-binary")

    def version_for(role: str) -> tuple[str, str]:
        entry = versions.get(role, {})
        return (
            entry.get("marketing", identity.marketing_version),
            entry.get("build", identity.build_number),
        )

    host_version, host_build = version_for("host")
    prototype = mode == vb.QUALIFICATION
    host_plist = {
        "CFBundleIdentifier": bundle_ids["host"],
        "CFBundleShortVersionString": host_version,
        "CFBundleVersion": host_build,
        "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
        "NSLocalNetworkUsageDescription": (
            "Prototype read-only diagnostic endpoint." if prototype else "Floe Bridge local service."
        ),
        "UIFileSharingEnabled": True,
    }
    if background_modes:
        host_plist["UIBackgroundModes"] = list(background_modes)
    if prototype:
        host_plist["FloePrototypeChannels"] = True
        host_plist["FloePrototypeDiagnostics"] = True
    write_plist(app / "Info.plist", host_plist)

    appex = app / "PlugIns" / vb.APPEX_NAME
    appex.mkdir(parents=True, exist_ok=True)
    appex_version, appex_build = version_for("appex")
    write_plist(appex / "Info.plist", {
        "CFBundleIdentifier": bundle_ids["tunnel"],
        "CFBundleShortVersionString": appex_version,
        "CFBundleVersion": appex_build,
        "CFBundlePackageType": "XPC!",
        "NSExtension": {
            "NSExtensionPointIdentifier": "com.apple.networkextension.packet-tunnel",
            "NSExtensionPrincipalClass": "BridgeTunnel.PacketTunnelProvider",
        },
    })
    (appex / "BridgeTunnel").write_bytes(b"appex-binary")

    test_bundle = app / "PlugIns" / vb.TEST_NAME
    test_bundle.mkdir(parents=True, exist_ok=True)
    test_version, test_build = version_for("test")
    write_plist(test_bundle / "Info.plist", {
        "CFBundleIdentifier": bundle_ids["host"],
        "CFBundleShortVersionString": test_version,
        "CFBundleVersion": test_build,
        "XCTContainsUITests": True,
    })
    (test_bundle / "BridgeTests").write_bytes(b"test-binary")

    host_core = app / "Frameworks" / "BridgeCore.framework"
    host_core.mkdir(parents=True, exist_ok=True)
    core_version, core_build = version_for("core")
    (host_core / "BridgeCore").write_bytes(b"core-binary")
    write_plist(host_core / "Info.plist", {
        "CFBundleIdentifier": bundle_ids["core"],
        "CFBundleShortVersionString": core_version,
        "CFBundleVersion": core_build,
    })

    appex_core = appex / "Frameworks" / "BridgeCore.framework"
    appex_core.mkdir(parents=True, exist_ok=True)
    (appex_core / "BridgeCore").write_bytes(b"core-binary")
    appex_core_version, appex_core_build = version_for("appex-core")
    write_plist(appex_core / "Info.plist", {
        "CFBundleIdentifier": bundle_ids["core"],
        "CFBundleShortVersionString": appex_core_version,
        "CFBundleVersion": appex_core_build,
    })

    notices = app / "ThirdParty"
    for relative in ("iCTRL/LICENSE", "iCTRL/NOTICE.md", "idevice/LICENSE"):
        source = source_root / "ThirdParty" / relative
        target = notices / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)

    if signed:
        for bundle in (app, appex, test_bundle, host_core, appex_core):
            signature = bundle / "_CodeSignature"
            signature.mkdir(exist_ok=True)
            (signature / "CodeResources").write_bytes(b"signature")
        (app / "embedded.mobileprovision").write_bytes(b"profile")
        (appex / "embedded.mobileprovision").write_bytes(b"profile")
    return app


def source_root_for(app: Path) -> Path:
    return app.parent / "source"


def make_ipa(root: Path, app: Path, name: str = "Bridge.ipa", extra: dict | None = None) -> Path:
    ipa = root / name
    with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(app.rglob("*")):
            relative = path.relative_to(app.parent).as_posix()
            if path.is_dir():
                continue
            archive.write(path, "Payload/" + relative)
        for relative, content in (extra or {}).items():
            archive.writestr(relative, content)
    return ipa


def make_dsyms(root: Path) -> list[Path]:
    values = []
    for name, (role, uuid) in DSYM_UUIDS.items():
        path = root / name / "Contents" / "Resources" / "DWARF" / role
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"dwarf")
        values.append(root / name)
    return values
