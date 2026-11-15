#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Pure Python/Node-free verifier for the 20-engine starter resource set.

Checks only files and data formats. It does not execute a game engine, Ruby,
Swift, Unity, Cocos, a browser or a build tool.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import marshal_codec as m  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
TEMPLATES = ROOT / "Sources" / "FloeGameStarterKit" / "Resources" / "Templates"
CATALOG_PATH = ROOT / "Sources" / "FloeGameStarterKit" / "Resources" / "Catalog" / "engines.json"

ENGINE_ORDER = [
    "rpgMakerXP", "rpgMakerVX", "rpgMakerVXAce", "rpgMakerMV", "rpgMakerMZ",
    "phaser", "kaplay", "godot", "babylon", "playcanvas", "love", "renpy",
    "tic80", "ink", "twine", "gdevelop", "cocosCreator", "microStudio",
    "wasm4", "unity",
]

FORBIDDEN_SUFFIXES = {
    ".dll", ".exe", ".pdb", ".so", ".dylib", ".rgssad", ".rgss2a", ".rgss3a",
    ".pck", ".app", ".ipa", ".apk",
}


class Check:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.checks: list[str] = []

    def ok(self, condition: bool, message: str) -> None:
        if condition:
            self.checks.append(message)
        else:
            self.failures.append(message)

    def equal(self, actual, expected, message: str) -> None:
        self.ok(actual == expected, f"{message}: {actual!r} == {expected!r}")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    """Comparable value that treats Table user-defined payloads as tables."""
    if isinstance(value, m.RTable):
        return ("table", value.dimensions, value.x_size, value.y_size, value.z_size,
                tuple(value.values))
    if isinstance(value, m.RUserDefined):
        if value.class_name == "Table":
            table = m.decode_table(value)
            return canonical(table)
        return ("user", value.class_name, value.data)
    if isinstance(value, m.RObject):
        return ("object", value.class_name, tuple((key, canonical(item)) for key, item in value.ivars))
    if isinstance(value, m.RString):
        return ("string", value.data, value.encoding)
    if isinstance(value, m.RHash):
        return ("hash", tuple((canonical(key), canonical(item)) for key, item in value.pairs),
                value.has_default, canonical(value.default))
    if isinstance(value, list):
        return ("array", tuple(canonical(item) for item in value))
    if isinstance(value, m.RSymbol):
        return ("symbol", value.name)
    return value


def verify_catalog(check: Check) -> dict:
    check.ok(CATALOG_PATH.is_file(), "catalog exists")
    if not CATALOG_PATH.is_file():
        return {}
    catalog = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    check.equal(catalog.get("schemaVersion"), 1, "catalog schemaVersion")
    check.equal(catalog.get("catalogVersion"), "1.0.0", "catalog version")
    engines = catalog.get("engines", [])
    check.equal(len(engines), 20, "catalog engine count")
    check.equal([item.get("engine") for item in engines], ENGINE_ORDER, "catalog order")
    check.equal(len({item.get("engine") for item in engines}), 20, "unique engines")
    for item in engines:
        engine = item["engine"]
        check.equal(item["defaultInput"]["engine"], engine, f"{engine} default input engine")
        check.ok(bool(item.get("entry")), f"{engine} has entry")
        check.ok(bool(item.get("expectedFiles")), f"{engine} has expected files")
        check.ok(item["entry"] in item["expectedFiles"], f"{engine} entry is expected")
        check.ok(bool(item.get("prerequisites")), f"{engine} prerequisites")
        check.ok(bool(item.get("sourceLicense")), f"{engine} source license")
        check.ok(bool(item.get("engineLicense")), f"{engine} engine license")
    return catalog


def verify_static(check: Check, catalog: dict) -> None:
    for item in catalog["engines"]:
        if item["templateKind"] != "static":
            continue
        engine = item["engine"]
        root = TEMPLATES / Path(item["templateRoot"]).name
        check.ok(root.is_dir(), f"{engine} template root")
        actual = sorted(path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file())
        expected = sorted(file["path"] for file in item["files"])
        check.equal(actual, expected, f"{engine} file set")
        for file in item["files"]:
            path = root / file["path"]
            if not path.is_file():
                check.ok(False, f"{engine} missing {file['path']}")
                continue
            data = path.read_bytes()
            check.equal(len(data), file["bytes"], f"{engine} {file['path']} bytes")
            check.equal(sha256(data), file["sha256"], f"{engine} {file['path']} sha256")
            if path.suffix.lower() in FORBIDDEN_SUFFIXES:
                check.ok(False, f"{engine} forbidden binary {file['path']}")
        check.ok(item["entry"] in expected, f"{engine} entry exists")
        if engine in {"rpgMakerXP", "rpgMakerVX", "rpgMakerVXAce", "rpgMakerMZ", "cocosCreator"}:
            pngs = [path for path in root.rglob("*.png")]
            check.ok(bool(pngs), f"{engine} has original PNG assets")
            for path in pngs:
                data = path.read_bytes()
                size_ok = data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) >= 24
                if size_ok:
                    width, height = struct.unpack(">II", data[16:24])
                    size_ok = width > 0 and height > 0
                check.ok(size_ok, f"{engine} valid PNG {path.relative_to(root)}")
        inputs = root / "floe-inputs.json"
        if inputs.is_file():
            value = json.loads(inputs.read_text(encoding="utf-8"))
            check.equal(value.get("schemaVersion"), 1, f"{engine} static floe-inputs schema")
            check.equal(value.get("engine"), engine, f"{engine} static floe-inputs engine")
            check.equal(value.get("movement"), item["defaultInput"]["movement"],
                        f"{engine} static floe-inputs movement")
            check.equal(value.get("buttons"), item["defaultInput"]["buttons"],
                        f"{engine} static floe-inputs buttons")


def verify_legacy(check: Check) -> None:
    for engine, ext in [("rpgMakerXP", "rxdata"), ("rpgMakerVX", "rvdata"),
                        ("rpgMakerVXAce", "rvdata2")]:
        root = TEMPLATES / engine
        ini = (root / "Game.ini").read_text(encoding="utf-8")
        check.ok("Title=Glimmerfen" in ini, f"{engine} Game.ini title")
        check.ok("Scripts=Data\\Scripts." + ext in ini, f"{engine} Game.ini scripts path")
        for name in ["Actors", "Classes", "Skills", "Items", "Weapons", "Armors",
                     "Enemies", "Troops", "States", "Animations", "Tilesets",
                     "CommonEvents", "System", "MapInfos", "Map001", "Scripts"]:
            path = root / "Data" / f"{name}.{ext}"
            check.ok(path.is_file(), f"{engine} Data/{name}.{ext}")
            if not path.is_file():
                continue
            try:
                value = m.load(path.read_bytes())
                check.checks.append(f"{engine} Marshal parse {name}")
                check.ok(canonical(m.load(m.dump(value))) == canonical(value),
                         f"{engine} Marshal roundtrip {name}")
            except Exception as error:  # noqa: BLE001
                check.ok(False, f"{engine} Marshal parse {name}: {error}")
                continue
            if name == "Map001":
                ivars = dict(value.ivars)
                check.equal(ivars["@width"], 12, f"{engine} map width")
                check.equal(ivars["@height"], 10, f"{engine} map height")
                table = m.decode_table(ivars["@data"])
                check.equal(table.dimensions, 3, f"{engine} table dimensions")
                check.equal(len(table.values), 360, f"{engine} table values")
                events = ivars["@events"]
                check.equal(len(events.pairs), 2, f"{engine} map events")
                check.ok(any(event.get("@name").data == b"Ferry Keeper" for _, event in events.pairs),
                         f"{engine} Ferry Keeper event")
            if name == "Actors":
                check.equal(len(value), 2, f"{engine} actor records")
                check.equal(value[1].get("@name").data.decode("utf-8"), "Kestrel",
                            f"{engine} actor name")
            if name == "System":
                title = value.get("@game_title")
                if title is not None:
                    check.equal(title.data.decode("utf-8"), "Glimmerfen", f"{engine} system title")
            if name == "Scripts":
                check.equal(len(value), 1, f"{engine} script count")
                magic, title, payload = value[0]
                check.equal(magic, 1, f"{engine} script magic")
                check.equal(title.data.decode("utf-8"), "FloeStarter", f"{engine} script title")
                source = zlib.decompress(payload.data).decode("utf-8")
                check.ok("FloeStarterScene" in source, f"{engine} script source")
                check.ok("Marshal.dump" in source, f"{engine} script save API")
                check.ok("Input.trigger?" in source, f"{engine} script input API")
        for path in root.rglob("*"):
            if path.is_file() and path.suffix.lower() in FORBIDDEN_SUFFIXES:
                check.ok(False, f"{engine} forbidden file {path.relative_to(root)}")


def verify_mz(check: Check) -> None:
    root = TEMPLATES / "rpgMakerMZ"
    check.equal((root / "Game.rmmzproject").read_text(encoding="utf-8"), "RPGMZ 1.0.0\n",
                "MZ marker")
    for name in ["Actors", "Classes", "Skills", "Items", "Weapons", "Armors",
                 "Enemies", "Troops", "States", "Animations", "Tilesets",
                 "CommonEvents", "System", "MapInfos", "Map001"]:
        path = root / "data" / f"{name}.json"
        check.ok(path.is_file(), f"MZ {name}.json")
        if path.is_file():
            json.loads(path.read_text(encoding="utf-8"))
    system = json.loads((root / "data/System.json").read_text(encoding="utf-8"))
    check.equal(system.get("gameTitle"), "Glimmerfen", "MZ system title")
    map_value = json.loads((root / "data/Map001.json").read_text(encoding="utf-8"))
    check.equal(map_value.get("width"), 12, "MZ map width")
    check.equal(map_value.get("height"), 10, "MZ map height")
    check.equal(len(map_value.get("events", [])), 3, "MZ map events")
    check.ok(not list(root.rglob("rmmz_*.js")), "MZ no proprietary rmmz core scripts")
    check.ok((root / "js/plugins/FloeStarter.js").is_file(), "MZ original plugin")
    plugin = (root / "js/plugins/FloeStarter.js").read_text(encoding="utf-8")
    check.ok("@target MZ" in plugin, "MZ plugin target")
    check.ok("SPDX-License-Identifier: MIT" in plugin, "MZ plugin MIT")
    check.ok("licensed rmmz_* core scripts" in plugin, "MZ plugin prerequisite note")


def verify_unity(check: Check) -> None:
    root = TEMPLATES / "unity"
    version = (root / "ProjectSettings/ProjectVersion.txt").read_text(encoding="utf-8")
    check.ok("m_EditorVersion: 2022.3.0f1" in version, "Unity version")
    project = (root / "ProjectSettings/ProjectSettings.asset").read_text(encoding="utf-8")
    check.ok("productName: Glimmerfen" in project, "Unity product name")
    check.ok("activeInputHandler: 0" in project, "Unity old input handler")
    scene = (root / "Assets/Scenes/Main.unity").read_text(encoding="utf-8")
    check.ok(scene.startswith("%YAML 1.1"), "Unity scene YAML")
    script = (root / "Assets/Scripts/FloeStarter.cs").read_text(encoding="utf-8")
    check.ok("RuntimeInitializeOnLoadMethod" in script, "Unity runtime bootstrap")
    check.ok("Input.GetKey" in script, "Unity physical keyboard")
    check.ok("PlayerPrefs" in script, "Unity save API")
    editor = (root / "Assets/Editor/FloeWebBuild.cs").read_text(encoding="utf-8")
    check.ok("BuildTarget.WebGL" in editor, "Unity WebGL bootstrap")
    check.ok("BuildPipeline.BuildPlayer" in editor, "Unity build pipeline")
    manifest = json.loads((root / "Packages/manifest.json").read_text(encoding="utf-8"))
    check.ok(bool(manifest.get("dependencies")), "Unity package manifest")
    build_settings = (root / "ProjectSettings/EditorBuildSettings.asset").read_text(encoding="utf-8")
    check.ok("Assets/Scenes/Main.unity" in build_settings, "Unity scene in build settings")
    check.ok(not list(root.rglob("*.dll")), "Unity no engine binaries")


COMPONENT_UUID = "0f10e5a1-7a2b-4c3d-8e4f-5a6b7c8d9e0f"
BASE64_KEYS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


def compress_uuid(value: str) -> str:
    raw = value.replace("-", "")
    out = raw[:5]
    for index in range(5, 32, 3):
        c, d, e = int(raw[index], 16), int(raw[index + 1], 16), int(raw[index + 2], 16)
        out += BASE64_KEYS[(c << 2) | (d >> 2)]
        out += BASE64_KEYS[((d & 3) << 4) | e]
    return out


def verify_cocos(check: Check) -> None:
    root = TEMPLATES / "cocosCreator"
    package = json.loads((root / "package.json").read_text(encoding="utf-8"))
    check.equal(package.get("creator", {}).get("version"), "3.8.6", "Cocos creator version")
    scene = json.loads((root / "assets/Scenes/Main.scene").read_text(encoding="utf-8"))
    component = compress_uuid(COMPONENT_UUID)
    check.ok(any(isinstance(item, dict) and item.get("__type__") == component for item in scene),
             "Cocos scene custom component type")
    script = (root / "assets/scripts/FloeStarter.ts").read_text(encoding="utf-8")
    check.ok("@ccclass('FloeStarter')" in script, "Cocos TypeScript component")
    check.ok("view.setDesignResolutionSize" in script, "Cocos design resolution")
    meta = json.loads((root / "assets/scripts/FloeStarter.ts.meta").read_text(encoding="utf-8"))
    check.equal(meta.get("uuid"), COMPONENT_UUID, "Cocos script meta UUID")
    project = json.loads((root / "settings/v2/packages/project.json").read_text(encoding="utf-8"))
    check.ok(bool(project.get("general")), "Cocos project settings")
    check.ok(not list(root.rglob("*.dll")), "Cocos no engine binaries")


def verify_runtime_templates(check: Check, catalog: dict) -> None:
    for name in ["kaplay.js", "babylon.js", "playcanvas.js", "common.js",
                 "index.html", "LICENSE-FLOE-STARTER-MIT.txt"]:
        check.ok((TEMPLATES / "runtime" / name).is_file(), f"runtime template {name}")
    for name in ["project.godot", "main.tscn", "main.gd", "bridge.js",
                 "GODOT-LICENSE.txt", "GODOT-THIRD-PARTY.txt",
                 "LICENSE-FLOE-STARTER-MIT.txt"]:
        check.ok((TEMPLATES / "godot" / name).is_file(), f"godot template {name}")
    provenance = json.loads((ROOT / "Sources/FloeGameStarterKit/Resources/Catalog/PROVENANCE.json").read_text(encoding="utf-8"))
    for name, digest in provenance["runtimeTemplateHashes"].items():
        path = TEMPLATES / "runtime" / name
        if path.is_file():
            check.equal(sha256(path.read_bytes()), digest, f"runtime provenance {name}")
    for name, digest in provenance["godotTemplateHashes"].items():
        path = TEMPLATES / "godot" / name
        if path.is_file():
            check.equal(sha256(path.read_bytes()), digest, f"godot provenance {name}")
    for item in catalog["engines"]:
        if item["templateKind"] == "runtimePack":
            check.ok(item.get("runtimePack", {}).get("files"), f"{item['engine']} runtime pack files")


def verify_renpy_focus(check: Check) -> None:
    screens = ROOT.parent / "FloeGamePortableKit/Sources/FloeGamePortableKit/Resources/Templates/renpy/game/screens.rpy"
    check.ok(screens.is_file(), "current portable-final RenPy screens.rpy")
    if not screens.is_file():
        return
    text = screens.read_text(encoding="utf-8")
    check.ok("QuickSave() keyboard_focus False" in text, "RenPy quick save focus fix")
    check.ok("QuickLoad(confirm=False) keyboard_focus False" in text, "RenPy quick load focus fix")
    check.ok("MainMenu(confirm=False) keyboard_focus False" in text, "RenPy quick menu focus fix")
    check.ok("default_focus (i == items[0])" in text, "RenPy choice first item default focus")
    check.checks.append("RenPy screens.rpy sha256 " + sha256(screens.read_bytes()))


def verify_licenses(check: Check, catalog: dict) -> None:
    check.ok((ROOT / "Sources/FloeGameStarterKit/Resources/Licenses/FLOE-STARTER-MIT.txt").is_file(), "MIT starter license")
    check.ok((ROOT / "Sources/FloeGameStarterKit/Resources/Licenses/GDEVELOP-THIRD-PARTY-NOTICES.txt").is_file(),
             "GDevelop notices")
    for item in catalog["engines"]:
        check.ok(any(prereq.get("kind") for prereq in item["prerequisites"]),
                 f"{item['engine']} prerequisite kind")
        check.ok(all(prereq.get("requiredFor") for prereq in item["prerequisites"]),
                 f"{item['engine']} prerequisite targets")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Optional JSON result path")
    args = parser.parse_args()
    check = Check()
    catalog = verify_catalog(check)
    if catalog:
        verify_static(check, catalog)
        verify_legacy(check)
        verify_mz(check)
        verify_unity(check)
        verify_cocos(check)
        verify_runtime_templates(check, catalog)
        verify_renpy_focus(check)
        verify_licenses(check, catalog)
    result = {
        "result": "pass" if not check.failures else "fail",
        "checks": len(check.checks),
        "failures": check.failures,
        "catalogEngines": len(catalog.get("engines", [])) if catalog else 0,
        "staticEngines": sum(1 for x in catalog.get("engines", []) if x["templateKind"] == "static") if catalog else 0,
        "runtimePackEngines": sum(1 for x in catalog.get("engines", []) if x["templateKind"] == "runtimePack") if catalog else 0,
        "delegatedEngines": sum(1 for x in catalog.get("engines", []) if x["templateKind"] == "delegated") if catalog else 0,
    }
    text = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    print(text, end="")
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    if check.failures:
        sys.exit(1)


if __name__ == "__main__":
    main()
