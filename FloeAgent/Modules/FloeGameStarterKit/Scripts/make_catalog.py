#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Build the deterministic 20-engine starter catalog and provenance records.

The catalog is the single machine-readable descriptor consumed by the Swift
catalog/service. It records the actual static template files and hashes, the
delegated component providers, required runtime packs and explicit user SDK
prerequisites. It never claims that an editor, runtime or build was executed.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEMPLATES = ROOT / "Sources" / "FloeGameStarterKit" / "Resources" / "Templates"
CATALOG = ROOT / "Sources" / "FloeGameStarterKit" / "Resources" / "Catalog"
RENPY_SCREENS = ROOT.parent / "FloeGamePortableKit/Sources/FloeGamePortableKit/Resources/Templates/renpy/game/screens.rpy"

ENGINE_ORDER = [
    "rpgMakerXP", "rpgMakerVX", "rpgMakerVXAce", "rpgMakerMV", "rpgMakerMZ",
    "phaser", "kaplay", "godot", "babylon", "playcanvas", "love", "renpy",
    "tic80", "ink", "twine", "gdevelop", "cocosCreator", "microStudio",
    "wasm4", "unity",
]

KEY_VOCABULARY = set("""left right up down enter escape space tab backspace delete insert
home end pageUp pageDown shift control alt meta rightShift rightControl rightAlt rightMeta
capsLock numLock scrollLock printScreen pause contextMenu a b c d e f g h i j k l m n o p q r s t u v w x y z
zero one two three four five six seven eight nine minus equal leftBracket rightBracket backslash
semicolon quote backquote comma period slash f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12
f13 f14 f15 f16 f17 f18 f19 f20 f21 f22 f23 f24 numpad0 numpad1 numpad2 numpad3 numpad4
numpad5 numpad6 numpad7 numpad8 numpad9 numpadDecimal numpadDivide numpadMultiply
numpadSubtract numpadAdd numpadEnter numpadEqual""".split())


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def files(root: Path) -> list[dict]:
    result = []
    for path in sorted(root.rglob("*")):
        if path.is_file():
            result.append({"path": path.relative_to(root).as_posix(),
                           "sha256": sha256(path), "bytes": path.stat().st_size})
    return result


def input_decl(engine: str, movement: dict | None = None, buttons: list | None = None) -> dict:
    return {
        "schemaVersion": 1,
        "engine": engine,
        "movement": movement or {"left": ["left"], "right": ["right"],
                                 "up": ["up"], "down": ["down"]},
        "buttons": buttons or [],
    }


def button(identifier: str, label: str, keys: list[str]) -> dict:
    return {"id": identifier, "label": label, "keys": keys}


XP_KEYS = [
    button("confirm", "C (also Enter/Space)", ["c"]),
    button("cancel", "X (also Esc)", ["x"]),
    button("actionA", "Shift (also Z)", ["shift"]),
]
VX_KEYS = [
    button("confirm", "Z (also Enter/Space)", ["z"]),
    button("cancel", "X (also Esc)", ["x"]),
    button("actionA", "Shift", ["shift"]),
    button("pageLeft", "Q", ["q"]),
    button("pageRight", "W", ["w"]),
]
MV_KEYS = [
    button("confirm", "Z", ["z"]),
    button("cancel", "X", ["x"]),
    button("action3", "Shift", ["shift"]),
    button("pageUp", "Q", ["q"]),
    button("pageDown", "W", ["w"]),
]
TIC_KEYS = [
    button("confirm", "Z", ["z"]),
    button("cancel", "X", ["x"]),
    button("action3", "A", ["a"]),
    button("action4", "S", ["s"]),
]
WASM_KEYS = [
    button("confirm", "X", ["x"]),
    button("cancel", "Z", ["z"]),
]
MZ_KEYS = [
    button("confirm", "Z (also Enter/Space)", ["z"]),
    button("cancel", "X (also Esc)", ["x"]),
    button("actionA", "Shift", ["shift"]),
    button("save", "F5", ["f5"]),
    button("load", "F9", ["f9"]),
]



def runtime_pack(engine: str) -> dict:
    packs = {
        "phaser": {
            "id": "phaser-3.90.0", "engineVersion": "3.90.0", "license": "MIT",
            "upstream": "https://github.com/phaserjs/phaser",
            "sourceCommit": "a9965625f49cf366584f454556b039e06e8adad6",
            "files": [
                {"path": "phaser.js", "sha256": "2e1bc84f885ab5c62b11ebb72492bb334159ac5678b664c7cb2942fc979e44e3", "bytes": 1086308},
                {"path": "LICENSE.phaser.md", "sha256": "c3123cd25de4eccf1fd5a5a0a6fc872299116d1dbbb48b00f2554a4c35220a65", "bytes": 1100},
                {"path": "THIRD-PARTY-NOTICES.txt", "sha256": "fd57bb945a3993569b6eae1833d25e9eb1e2a988cca541ba8dc770b0b7b7792b", "bytes": 14546},
            ],
        },
        "kaplay": {
            "id": "kaplay-3001.0.0", "engineVersion": "3001.0.0", "license": "MIT",
            "upstream": "https://github.com/kaplayjs/kaplay",
            "sourceCommit": "f41e7d0bd9ab3d6de8ef29bc7ce20fbfb619223c",
            "files": [
                {"path": "runtime/engine.js", "sha256": "d772c29d33ce675981976de8385fa632d286de282c09290848a213bc2f5e50a6", "bytes": 191767},
                {"path": "licenses/ENGINE.txt", "sha256": "4d8513caec72ba8f202fa550f10de67bef19fc9ab8739403bd6d76d7788247d9", "bytes": 1072},
            ],
        },
        "babylon": {
            "id": "babylon-9.35.0", "engineVersion": "9.35.0", "license": "Apache-2.0",
            "upstream": "https://github.com/BabylonJS/Babylon.js",
            "sourceCommit": "00bc37c78dc519e229a709beebd5ed2099e8aba8",
            "files": [
                {"path": "runtime/engine.js", "sha256": "e7489b1ba1044cb296b6cad3a5732309cc18fdc6873fd009dc585de34e4388e2", "bytes": 8876104},
                {"path": "licenses/ENGINE.txt", "sha256": "9362ea9ea17cb221a20cbbd63f404710834cc273d2a9a7b60314fd68ab702cd6", "bytes": 9226},
                {"path": "licenses/NOTICE.md", "sha256": "225463efd81558f120a6e0cdd7f4c1007ed486006d1228c4849fee0c49715823", "bytes": 46},
            ],
        },
        "playcanvas": {
            "id": "playcanvas-2.24.0", "engineVersion": "2.24.0", "license": "MIT",
            "upstream": "https://github.com/playcanvas/engine",
            "sourceCommit": "0d07e104eef005a7d678c87a290206dcbcfecc84",
            "files": [
                {"path": "runtime/engine.js", "sha256": "6151c8a059ea40779a39ee3f1ccbbc3a9efb9c63e5b276a7bede915a1a3bbd7b", "bytes": 4689849},
                {"path": "licenses/ENGINE.txt", "sha256": "42fa51ddd556be151a29f381fb97ee975825dcc454e805ea3ea9c079cca04d34", "bytes": 1064},
            ],
        },
    }
    return packs[engine]


def prereq(kind: str, name: str, version: str, url: str, notes: str,
           required_for: list[str]) -> dict:
    return {"kind": kind, "name": name, "version": version, "url": url,
            "notes": notes, "requiredFor": required_for}


def static_entry(engine: str, display: str, root_name: str, entry: str,
                 readiness: str, source_license: str, engine_license: str,
                 prerequisites: list[dict], notes: list[str], default_input: dict,
                 web_entry: str | None = None) -> dict:
    root = TEMPLATES / root_name
    manifest = files(root)
    paths = {item["path"] for item in manifest}
    if entry not in paths:
        raise SystemExit(f"{engine}: entry {entry} not in static template")
    return {
        "engine": engine, "displayName": display, "starterVersion": "1.0.0",
        "entry": entry, "webEntry": web_entry, "readiness": readiness,
        "sourceLicense": source_license, "engineLicense": engine_license,
        "templateKind": "static", "templateRoot": f"Templates/{root_name}",
        "files": manifest, "expectedFiles": sorted(paths),
        "prerequisites": prerequisites, "notes": notes,
        "defaultInput": default_input,
    }


def delegated_entry(engine: str, display: str, entry: str, web_entry: str | None,
                    readiness: str, source_license: str, engine_license: str,
                    provider: str, expected_files: list[str],
                    prerequisites: list[dict], notes: list[str],
                    default_input: dict, source_pins: list[str]) -> dict:
    return {
        "engine": engine, "displayName": display, "starterVersion": "1.0.0",
        "entry": entry, "webEntry": web_entry, "readiness": readiness,
        "sourceLicense": source_license, "engineLicense": engine_license,
        "templateKind": "delegated", "provider": provider,
        "expectedFiles": sorted(expected_files), "files": [],
        "prerequisites": prerequisites, "notes": notes,
        "defaultInput": default_input, "sourcePins": source_pins,
    }


def runtime_entry(engine: str, display: str, entry: str, provider: str,
                  expected_files: list[str], prerequisites: list[dict],
                  notes: list[str], default_input: dict,
                  source_pins: list[str]) -> dict:
    return {
        "engine": engine, "displayName": display, "starterVersion": "1.0.0",
        "entry": entry, "webEntry": entry, "readiness": "runtimePackRequired",
        "sourceLicense": "MIT (original Floe starter files)",
        "engineLicense": runtime_pack(engine)["license"] + " (pinned engine runtime pack)",
        "templateKind": "runtimePack", "provider": provider,
        "runtimePack": runtime_pack(engine),
        "expectedFiles": sorted(expected_files), "files": [],
        "prerequisites": prerequisites, "notes": notes,
        "defaultInput": default_input, "sourcePins": source_pins,
    }


def build() -> dict:
    entries: list[dict] = []
    runtime_template_hashes = {
        "kaplay.js": sha256(TEMPLATES / "runtime/kaplay.js"),
        "babylon.js": sha256(TEMPLATES / "runtime/babylon.js"),
        "playcanvas.js": sha256(TEMPLATES / "runtime/playcanvas.js"),
        "common.js": sha256(TEMPLATES / "runtime/common.js"),
        "index.html": sha256(TEMPLATES / "runtime/index.html"),
        "LICENSE-FLOE-STARTER-MIT.txt": sha256(TEMPLATES / "runtime/LICENSE-FLOE-STARTER-MIT.txt"),
    }
    for engine in ("rpgMakerXP", "rpgMakerVX", "rpgMakerVXAce"):
        entries.append(static_entry(
            engine,
            {"rpgMakerXP": "RPG Maker XP", "rpgMakerVX": "RPG Maker VX",
             "rpgMakerVXAce": "RPG Maker VX Ace"}[engine],
            engine,
            {"rpgMakerXP": "Game.rxproj", "rpgMakerVX": "Game.rvproj",
             "rpgMakerVXAce": "Game.rvproj2"}[engine],
            "sourceWithEditor",
            "MIT (original map/database/event/Ruby starter data and code)",
            "RPG Maker editor and RGSS runtime: user-supplied proprietary license",
            [
                prereq("editor", {"rpgMakerXP": "RPG Maker XP", "rpgMakerVX": "RPG Maker VX",
                                  "rpgMakerVXAce": "RPG Maker VX Ace"}[engine],
                       {"rpgMakerXP": "1.02+", "rpgMakerVX": "1.02+", "rpgMakerVXAce": "1.00+"}[engine],
                       "https://www.rpgmakerweb.com/", "Needed to open/edit/re-export the standard project.", ["edit", "build"]),
                prereq("runtime", {"rpgMakerXP": "RGSS1", "rpgMakerVX": "RGSS2",
                                   "rpgMakerVXAce": "RGSS3"}[engine], "engine-provided",
                       "https://www.rpgmakerweb.com/", "Needed to play the RGSS game; no runtime/DLL is bundled.", ["play"]),
            ],
            ["Standard Data/*." + {"rpgMakerXP": "rxdata", "rpgMakerVX": "rvdata",
                                   "rpgMakerVXAce": "rvdata2"}[engine] + " files use real Ruby Marshal 4.8.",
             "Scripts archive contains only original Floe Ruby source, not Enterbrain default scripts.",
             "No RTP, commercial art, DLL or font is bundled."],
            input_decl(engine, buttons=XP_KEYS if engine == "rpgMakerXP" else VX_KEYS),
        ))
    entries.append(delegated_entry(
        "rpgMakerMV", "RPG Maker MV", "index.html", "index.html",
        "sourceWithBuildTool",
        "MIT (Floe starter) + MIT RPG Maker MV CoreScript 1.3b",
        "MIT CoreScript; user supplies the prepared MIT runtime pack",
        "FloeGamePortableKit.GamePortableTemplateCatalog.install(.mv)",
        ["index.html", "js/main.js", "js/plugins.js", "js/floe_bridge.js",
         "data/System.json", "floe-inputs.json", "LICENSE-FLOE-STARTER-MIT.txt"],
        [prereq("resourcePack", "RPG Maker MV CoreScript", "1.3b",
                "https://github.com/rpgtkoolmv/corescript",
                "Prepared MIT CoreScript pack is required for the assembled Web player; no commercial RTP is included.",
                ["build", "play"])],
        ["Original MV starter project data and Floe bridge are MIT.",
         "The prepared CoreScript pack is on-demand; the template itself contains no RTP."],
        input_decl("rpgMakerMV", buttons=MV_KEYS),
        ["FloeAgent/Modules/FloeGamePortableKit",
         "CoreScript 182e31449707ba7e406db0485c44c2a9d11e2dcd"],
    ))
    entries.append(static_entry(
        "rpgMakerMZ", "RPG Maker MZ", "rpgMakerMZ", "Game.rmmzproject",
        "sourceWithEditor",
        "MIT (original JSON project data, plugin and synthetic art)",
        "RPG Maker MZ editor/runtime and rmmz_* core scripts: user-supplied proprietary license",
        [
            prereq("editor", "RPG Maker MZ", "1.0.0+", "https://www.rpgmakerweb.com/",
                   "Needed to open/edit and to supply the licensed MZ core runtime.", ["edit", "build", "play"]),
        ],
        ["Standard data/*.json and project paths are used.",
         "No rmmz_*.js, RTP, fonts or sample commercial art is bundled.",
         "The original Floe plugin uses only documented MZ APIs."],
        input_decl("rpgMakerMZ", buttons=MZ_KEYS),
    ))
    entries.append(runtime_entry(
        "phaser", "Phaser", "index.html",
        "FloeGameKit.GamePhaserTemplate.create(at:resources:title:)",
        ["vendor/phaser.js", "licenses/PHASER-MIT.txt", "licenses/THIRD-PARTY-NOTICES.txt",
         "licenses/FLOE-STARTER-MIT.txt", "index.html", "game.js", "game-config.json",
         "package.json", "floe-inputs.json"],
        [prereq("resourcePack", "Phaser", "3.90.0", "https://github.com/phaserjs/phaser",
                "The existing prepared Phaser 3.90.0 Arcade pack is required; it is MIT and pinned.",
                ["build", "play"])],
        ["The starter is the existing original Phaser template, not a new mock.",
         "The engine pack is verified by SHA-256 before files are written."],
        input_decl("phaser"),
        ["FloeGameKit/Sources/FloeGameCore/GamePhaserTemplate.swift",
         "phaser 3.90.0 a9965625f49cf366584f454556b039e06e8adad6"],
    ))
    for engine, display in [("kaplay", "KAPLAY"), ("babylon", "Babylon.js"),
                            ("playcanvas", "PlayCanvas")]:
        entries.append(runtime_entry(
            engine, display, "index.html",
            "FloeGameStarterKit.RuntimePackTemplate",
            ["runtime/engine.js", "licenses/ENGINE.txt", "game.js", "common.js",
             "index.html", "game.json", "package.json", "engine-provenance.json",
             "licenses/FLOE-STARTER-MIT.txt", "floe-inputs.json"],
            [prereq("resourcePack", display, runtime_pack(engine)["engineVersion"],
                    runtime_pack(engine)["upstream"],
                    "The pinned engine runtime pack is required and SHA-256 verified before writing.",
                    ["build", "play"]),
             prereq("runtime", "prepared Web engine pack", runtime_pack(engine)["id"],
                    runtime_pack(engine)["upstream"],
                    "Use the existing GameEnginePackStore prepared pack; KAPLAY is pinned to 3001.0.0, never 3001.0.19.",
                    ["build", "play"])],
            ["Uses the reviewed MIT/Apache engine bytes from the exact pinned pack.",
             "game.js/common.js/index.html are the original Floe starter files copied with hashes."],
            input_decl(engine),
            ["FloeGameRuntimeKit/Sources/FloeGameRuntime/Resources/Templates",
             runtime_pack(engine)["id"]],
        ))
    entries.append(static_entry(
        "godot", "Godot", "godot", "project.godot",
        "sourceWithBuildTool",
        "MIT (original GDScript starter and project files)",
        "Godot Engine 4.7.2: MIT; user supplies the editor/export toolchain",
        [prereq("editor", "Godot Engine", "4.7.2.stable", "https://godotengine.org/",
                "Needed to open, edit and export the Web build.", ["edit", "build"])],
        ["Original GDScript game and bridge; no native Godot executable is bundled.",
         "Web export is performed by the user's pinned Godot toolchain."],
        input_decl("godot"),
        web_entry="index.html",
    ))
    entries.append(delegated_entry(
        "love", "LÖVE", "main.lua", "index.html", "sourceWithBuildTool",
        "MIT (original Floe Lua starter)", "LÖVE 11.4 zlib; love.js 11.4.1 MIT plus component notices",
        "FloeGamePortableKit.GamePortableTemplateCatalog.install(.love)",
        ["main.lua", "conf.lua", "floe-inputs.json", "LICENSE-FLOE-STARTER-MIT.txt"],
        [prereq("buildTool", "love.js", "11.4.1", "https://github.com/Davidobot/love.js",
                "The pinned compatible runtime and its complete source/relink notices are required for Web packaging.",
                ["build", "play"])],
        ["Original LÖVE 11.4 source; the template is not a Web artifact by itself.",
         "Save/flush and component notices are supplied by the existing portable kit."],
        input_decl("love", buttons=[button("confirm", "Z (also Space)", ["z"]),
                                    button("cancel", "X", ["x"]),
                                    button("action1", "S", ["s"]),
                                    button("action2", "L", ["l"]),
                                    button("action3", "Esc", ["escape"])]),
        ["FloeAgent/Modules/FloeGamePortableKit",
         "love.js 11.4.1 8f9a7b85da9149b6d4d0af46442ead1e71f76477"],
    ))
    entries.append(delegated_entry(
        "renpy", "Ren'Py", "game/script.rpy", "index.html", "sourceWithBuildTool",
        "MIT (original Floe Ren'Py starter script)",
        "Ren'Py 8.5.3 MIT plus LGPL component addendum; user supplies the SDK/Web build",
        "FloeGamePortableKit.GamePortableTemplateCatalog.install(.renpy)",
        ["game/script.rpy", "game/screens.rpy", "game/options.rpy",
         "floe-inputs.json", "LICENSE-FLOE-STARTER-MIT.txt"],
        [prereq("buildTool", "Ren'Py SDK", "8.5.3.26051504", "https://www.renpy.org/",
                "Official launcher web_build and the retained LGPL source/relink records are required.",
                ["build", "play"])],
        ["The current portable-final Ren'Py template already contains Save/F5, Load/F9 and Continue.",
         "F5/F9 are explicit original project bindings, not a universal Ren'Py default."],
        input_decl("renpy", movement={"left": ["left"], "right": ["right"], "up": ["up"], "down": ["down"]},
                   buttons=[button("confirm", "Enter (also Space)", ["enter"]),
                            button("cancel", "Esc", ["escape"]),
                            button("action1", "Ctrl", ["control"]),
                            button("action2", "Tab", ["tab"]),
                            button("action3", "PageUp", ["pageUp"]),
                            button("action4", "PageDown", ["pageDown"]),
                            button("quicksave", "F5", ["f5"]),
                            button("quickload", "F9", ["f9"])]),
        ["FloeAgent/Modules/FloeGamePortableKit",
         "Ren'Py 8.5.3.26051504",
         "Ren'Py screens.rpy corrected focus: " + sha256(RENPY_SCREENS)],
    ))
    entries.append(delegated_entry(
        "tic80", "TIC-80", "cart.tic", "index.html", "sourceWithBuildTool",
        "MIT (original Floe cartridge code)",
        "TIC-80 1.4.1 MIT plus retained third-party/SOURCE-OFFER notices; user supplies the player pack",
        "FloeGameNarrativeKit.GameTIC80Adapter.createProject",
        ["cart.tic", "project.json", "floe-inputs.json", "licenses/LICENSE.tic80.txt",
         "licenses/FLOE-STARTER-MIT.txt"],
        [prereq("resourcePack", "TIC-80 Web player", "1.4.1", "https://github.com/nesbox/TIC-80",
                "The pinned player pack and its retained source-offer/notices are required for artifact build.",
                ["build", "play"])],
        ["Real .tic chunk container with CODE/LANG chunks; unknown chunks are preserved on import.",
         "The starter cartridge is original; no commercial cartridge or sample art is bundled."],
        input_decl("tic80", buttons=TIC_KEYS),
        ["FloeAgent/Modules/FloeGameNarrativeKit",
         "TIC-80 1.4.1"],
    ))
    entries.append(delegated_entry(
        "ink", "ink / inkjs", "story.ink", "index.html", "sourceWithBuildTool",
        "MIT (original Floe story)",
        "inkjs 2.4.0 MIT; user supplies the pinned compiler/runtime pack",
        "FloeGameNarrativeKit.GameInkAdapter.createProject",
        ["story.ink", "project.json", "floe-inputs.json", "licenses/INKJS-MIT.txt",
         "licenses/FLOE-STARTER-MIT.txt"],
        [prereq("resourcePack", "inkjs", "2.4.0", "https://www.npmjs.com/package/inkjs",
                "The pinned inkjs compiler/player pack is required to build the Web artifact.",
                ["build", "play"])],
        ["Plain standard ink source; imported INCLUDE graphs are bounded and canonicalized.",
         "The starter story is original and contains no commercial content."],
        input_decl("ink", movement={"left": [], "right": [], "up": ["up"], "down": ["down"]},
                   buttons=[button("confirm", "Enter", ["enter"])]),
        ["FloeAgent/Modules/FloeGameNarrativeKit",
         "inkjs 2.4.0"],
    ))
    entries.append(delegated_entry(
        "twine", "Twine / SugarCube", "story.twine.json", "index.html", "sourceWithBuildTool",
        "MIT (original Floe story)",
        "SugarCube 2.37.3 BSD-2-Clause plus bundled MIT/Unlicense notices; user supplies the pinned pack",
        "FloeGameNarrativeKit.GameTwineAdapter.createProject",
        ["story.twine.json", "project.json", "floe-inputs.json",
         "licenses/LICENSE.sugarcube.txt", "licenses/FLOE-STARTER-MIT.txt"],
        [prereq("resourcePack", "SugarCube", "2.37.3",
                "https://github.com/tmedwards/sugarcube-2/releases/tag/v2.37.3",
                "The pinned SugarCube format and its complete bundled notices are required for the Web artifact.",
                ["build", "play"])],
        ["Real Twine 2 story model with a standard tw-storydata export.",
         "Original Floe passages; no third-party story content."],
        input_decl("twine", movement={"left": [], "right": [], "up": ["up"], "down": ["down"]},
                   buttons=[button("confirm", "Enter", ["enter"])]),
        ["FloeAgent/Modules/FloeGameNarrativeKit",
         "SugarCube 2.37.3"],
    ))
    entries.append(delegated_entry(
        "gdevelop", "GDevelop", "game.json", "index.html", "sourceWithBuildTool",
        "MIT (original Floe project JSON and procedural art)",
        "GDevelop 5.6.287 MIT runtime/export; user supplies the pinned GDevelop toolchain",
        "FloeGameGDevelopKit.GameGDevelopTemplate.makeProject",
        ["game.json", "floe-inputs.json", "assets/floe_orb.png",
         "licenses/FLOE-STARTER-MIT.txt", "licenses/GDEVELOP-THIRD-PARTY-NOTICES.txt"],
        [prereq("buildTool", "GDevelop", "5.6.287", "https://gdevelop.io/",
                "The official GDevelop exporter/runtime is required to produce the Web artifact.",
                ["build", "play"])],
        ["The project JSON shape was produced by official GDevelop Core 2.0.0-gd-v5.6.269.",
         "The starter orb is a procedurally generated original PNG."],
        input_decl("gdevelop", buttons=[button("reset", "Z", ["z"])]),
        ["FloeAgent/Modules/FloeGameGDevelopKit",
         "GDevelop 5.6.287"],
    ))
    entries.append(static_entry(
        "cocosCreator", "Cocos Creator", "cocosCreator", "assets/Scenes/Main.scene",
        "sourceWithEditor",
        "MIT (original TypeScript, scene, metadata and synthetic orb)",
        "Cocos Creator 3.8.6: user-supplied editor and Web Mobile build support",
        [prereq("editor", "Cocos Creator", "3.8.6", "https://www.cocos.com/creator",
                "Pinned supported editor; needed to open and build the project.", ["edit", "build"])],
        ["Package.json, assets/, settings/v2/packages/ and serialized .scene follow the 3.8 layout.",
         "One custom TypeScript component builds a Canvas/Camera scene at runtime.",
         "No Cocos engine binaries or third-party art are bundled; no editor/build was run here."],
        input_decl("cocosCreator", buttons=[button("confirm", "Z (also Enter/Space)", ["z"]),
                                            button("cancel", "X (also Esc)", ["x"]),
                                            button("pageLeft", "Q", ["q"]),
                                            button("pageRight", "W", ["w"]),
                                            button("save", "F5", ["f5"]),
                                            button("load", "F9", ["f9"])]),
        web_entry="build/web-mobile/index.html",
    ))
    entries.append(delegated_entry(
        "microStudio", "microStudio", "src/main.ms", "index.html", "sourceWithBuildTool",
        "MIT (original microScript source)",
        "microStudio 1.0.0 MIT runtime; user supplies the pinned prepared pack",
        "FloeGameNarrativeKit.GameMicroStudioAdapter.createProject",
        ["src/main.ms", "project.json", "floe-inputs.json",
         "licenses/LICENSE.microstudio.txt", "licenses/FLOE-STARTER-MIT.txt"],
        [prereq("resourcePack", "microStudio runtime", "1.0.0",
                "https://github.com/pmgl/microstudio",
                "Pinned official exporter/runtime scripts are required for the Web artifact.",
                ["build", "play"])],
        ["Original microScript 2.0 source; imported assets are preserved byte-exact.",
         "No microStudio engine binary is bundled in the source project."],
        input_decl("microStudio"),
        ["FloeAgent/Modules/FloeGameNarrativeKit",
         "microStudio 80594cff51312b32db874a33d928876b23ab7718"],
    ))
    entries.append(delegated_entry(
        "wasm4", "WASM-4", "cart.wasm", "index.html", "sourceWithBuildTool",
        "MIT (procedurally encoded original cartridge)",
        "WASM-4 2.7.1 ISC runtime plus Lit/OFL notices; user supplies the pinned pack",
        "FloeGameNarrativeKit.GameWasm4Adapter.createProject",
        ["cart.wasm", "project.json", "floe-inputs.json",
         "licenses/LICENSE.wasm4.txt", "licenses/FLOE-STARTER-MIT.txt"],
        [prereq("resourcePack", "WASM-4 Web runtime", "2.7.1",
                "https://github.com/aduros/wasm4",
                "The pinned web runtime and its notice bundle are required for artifact build.",
                ["build", "play"])],
        ["A real .wasm cartridge is emitted with the documented WASM-4 ABI.",
         "The cartridge is original and under the 64 KiB upstream limit."],
        input_decl("wasm4", buttons=WASM_KEYS),
        ["FloeAgent/Modules/FloeGameNarrativeKit",
         "WASM-4 2.7.1"],
    ))
    entries.append(static_entry(
        "unity", "Unity", "unity", "Assets/Scenes/Main.unity",
        "sourceWithEditor",
        "MIT (original C#, scene and project metadata)",
        "Unity 2022.3 LTS and WebGL Build Support: user-supplied Unity license/editor",
        [prereq("editor", "Unity", "2022.3.0f1", "https://unity.com/",
                "Exact pinned LTS editor; needed to open, play and build.", ["edit", "build"]),
         prereq("buildTool", "WebGL Build Support", "2022.3.0f1", "https://unity.com/",
                "Editor module required for the WebGL build bootstrap.", ["build"])],
        ["Original C# game bootstraps after scene load and draws with IMGUI.",
         "ProjectVersion.txt, Packages/manifest.json, scene and editor build bootstrap are versioned.",
         "No Unity engine binaries, packages, third-party assets or WebGL output are bundled.",
         "No Unity or WebGL build was executed by this fixture generator."],
        input_decl("unity", buttons=[button("confirm", "Z (also Enter/Space)", ["z"]),
                                     button("cancel", "X (also Esc)", ["x"]),
                                     button("pageLeft", "Q", ["q"]),
                                     button("pageRight", "W", ["w"]),
                                     button("save", "F5", ["f5"]),
                                     button("load", "F9", ["f9"])]),
        web_entry="Build/WebGL/index.html",
    ))
    entries.sort(key=lambda item: ENGINE_ORDER.index(item["engine"]))
    if [item["engine"] for item in entries] != ENGINE_ORDER:
        raise SystemExit("catalog engine order mismatch")
    # Validate default input declarations with the same bounded vocabulary.
    for item in entries:
        decl = item["defaultInput"]
        if decl["engine"] != item["engine"] or decl["schemaVersion"] != 1:
            raise SystemExit(f"{item['engine']}: bad declaration identity")
        for direction, keys in decl["movement"].items():
            if direction not in ("left", "right", "up", "down"):
                raise SystemExit(f"{item['engine']}: bad direction")
            if keys and (len(keys) > 8 or len(set(keys)) != len(keys) or
                         any(key not in KEY_VOCABULARY for key in keys)):
                raise SystemExit(f"{item['engine']}: bad movement chord {keys}")
        ids = [button["id"] for button in decl["buttons"]]
        if len(ids) != len(set(ids)):
            raise SystemExit(f"{item['engine']}: duplicate button ids")
        for button_value in decl["buttons"]:
            keys = button_value["keys"]
            if not (1 <= len(keys) <= 8) or len(set(keys)) != len(keys) or any(key not in KEY_VOCABULARY for key in keys):
                raise SystemExit(f"{item['engine']}: bad button keys {keys}")
    provenance = {
        "schemaVersion": 1,
        "runtimeTemplateSource": "FloeAgent/Modules/FloeGameRuntimeKit/Sources/FloeGameRuntime/Resources",
        "runtimeTemplateHashes": runtime_template_hashes,
        "godotTemplateHashes": {
            name: sha256(TEMPLATES / "godot" / name)
            for name in ["project.godot", "main.tscn", "main.gd", "bridge.js",
                         "GODOT-LICENSE.txt", "GODOT-THIRD-PARTY.txt",
                         "LICENSE-FLOE-STARTER-MIT.txt"]
        },
        "staticTemplates": {
            item["engine"]: {
                "root": item["templateRoot"],
                "files": len(item["files"]),
                "bytes": sum(file["bytes"] for file in item["files"]),
                "treeSHA256": hashlib.sha256("\n".join(
                    file["path"] + ":" + file["sha256"] for file in item["files"]
                ).encode()).hexdigest(),
            }
            for item in entries if item["templateKind"] == "static"
        },
    }
    return {
        "schemaVersion": 1,
        "catalogVersion": "1.0.0",
        "generatedBy": "FloeGameStarterKit/Scripts/make_catalog.py",
        "engines": entries,
        "provenance": provenance,
    }


def main() -> None:
    CATALOG.mkdir(parents=True, exist_ok=True)
    catalog = build()
    (CATALOG / "engines.json").write_text(
        json.dumps(catalog, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (CATALOG / "PROVENANCE.json").write_text(
        json.dumps(catalog["provenance"], indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8")
    summary = {
        "engines": len(catalog["engines"]),
        "static": sum(1 for item in catalog["engines"] if item["templateKind"] == "static"),
        "delegated": sum(1 for item in catalog["engines"] if item["templateKind"] == "delegated"),
        "runtimePack": sum(1 for item in catalog["engines"] if item["templateKind"] == "runtimePack"),
        "catalogBytes": (CATALOG / "engines.json").stat().st_size,
    }
    print(json.dumps(summary, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
