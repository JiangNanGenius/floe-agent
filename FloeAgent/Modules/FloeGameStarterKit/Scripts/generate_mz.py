#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Generate the original RPG Maker MZ starter source/data.

This starter deliberately ships no rmmz_*.js core scripts and no RTP. It
contains the standard .rmmzproject marker, data/*.json project data, original
synthetic PNGs, and an original MIT-licensed MZ plugin. A licensed RPG Maker MZ
editor/runtime is an explicit user prerequisite; the project can still be
created, inspected, edited and versioned without those proprietary files.
"""

from __future__ import annotations

import hashlib
import json
import sys
import shutil
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_legacy_rpg import MIT_TEXT, OUT, png, make_tileset_png, make_hero, make_ui  # noqa: E402

NAME = "rpgMakerMZ"
ROOT = OUT / NAME
JSON_INDENT = 2


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=JSON_INDENT, ensure_ascii=False) + "\n",
                    encoding="utf-8")


def audio(name: str = "", volume: int = 90, pitch: int = 100) -> dict:
    return {"name": name, "volume": volume, "pitch": pitch, "pan": 0}


def actor() -> dict:
    return {
        "id": 1, "name": "Kestrel", "className": "Wayfarer", "classId": 1,
        "initialLevel": 1, "maxLevel": 99, "characterName": "FloeHero",
        "characterIndex": 0, "faceName": "", "faceIndex": 0,
        "battlerName": "", "battlerHue": 0, "profile": "A courier who maps the fenland crossings.",
        "nickname": "Quay Warden", "note": "Original Floe starter actor.",
        "traits": [], "effects": [], "equips": [1, 0, 0, 0, 0],
        "params": [[45 + i, 18 + i // 2, 9 + i // 4, 7 + i // 4, 6 + i // 3, 5 + i // 3]
                   for i in range(100)],
        "expParams": [30, 20, 30, 30],
    }


def klass() -> dict:
    return {
        "id": 1, "name": "Wayfarer", "note": "Original Floe starter class.",
        "expParams": [30, 20, 30, 30],
        "params": [[10 + i, 8 + i, 6 + i, 5 + i, 4 + i, 3 + i] for i in range(100)],
        "learnings": [{"level": 1, "skillId": 1, "note": ""}],
        "traits": [], "iconIndex": 0, "description": "A steady traveller of the tidal flats.",
    }


def skill() -> dict:
    return {
        "id": 1, "name": "Tide Step", "iconIndex": 1, "description": "A steady step over wet stone.",
        "scope": 0, "occasion": 0, "mpCost": 0, "tpCost": 0, "hit": 100,
        "animationId": 1, "damage": {"type": 0, "elementId": 0, "formula": "0",
                                     "variance": 0, "critical": False},
        "effects": [], "note": "Original Floe starter skill.",
    }


def item() -> dict:
    return {
        "id": 1, "name": "Rope Coil", "iconIndex": 2, "description": "Sturdy hemp rope for the ferry.",
        "price": 12, "consumable": True, "scope": 0, "occasion": 0,
        "animationId": 0, "damage": {"type": 0, "elementId": 0, "formula": "0",
                                     "variance": 0, "critical": False},
        "effects": [], "note": "Original Floe starter item.", "itypeId": 1,
    }


def weapon() -> dict:
    return {
        "id": 1, "name": "Ferry Hook", "iconIndex": 3, "description": "A balanced hook for pulling lines.",
        "price": 40, "wtypeId": 1, "etypeId": 1, "params": [0, 8, 0, 0, 0, 0, 0, 0],
        "traits": [], "note": "Original Floe starter weapon.",
    }


def armor() -> dict:
    return {
        "id": 1, "name": "Oilskin", "iconIndex": 4, "description": "Keeps the fen rain out.",
        "price": 30, "atypeId": 1, "etypeId": 1, "params": [0, 0, 4, 0, 0, 0, 0, 0],
        "traits": [], "note": "Original Floe starter armor.",
    }


def enemy() -> dict:
    return {
        "id": 1, "name": "Marsh Wisp", "battlerName": "", "battlerHue": 0,
        "params": [120, 30, 25, 12, 8, 15, 95, 5], "exp": 15, "gold": 8,
        "dropItems": [], "actions": [], "traits": [], "note": "Original Floe starter enemy.",
    }


def troop() -> dict:
    return {
        "id": 1, "name": "Quay Watch",
        "members": [{"enemyId": 1, "x": 0, "y": 0, "hidden": False}],
        "pages": [{"conditions": {"turnEnding": False, "turnValid": False, "enemyValid": False,
                                  "actorValid": False, "switchValid": False},
                   "list": [{"code": 0, "indent": 0, "parameters": []}],
                   "span": 0}],
        "note": "Original Floe starter troop.",
    }


def state() -> dict:
    return {
        "id": 1, "name": "Mired", "iconIndex": 5, "restriction": 0, "priority": 50,
        "removeAtBattleEnd": False, "removeByRestriction": False, "autoRemovalTiming": 0,
        "minTurns": 1, "maxTurns": 3, "message1": " sinks into the mud.",
        "message2": "", "message3": "", "message4": " shakes it off.",
        "note": "Original Floe starter state.", "traits": [],
    }


def animation() -> dict:
    return {
        "id": 1, "name": "Tide Step", "animation1Name": "", "animation2Name": "",
        "position": 1, "frameMax": 4, "frames": [], "timings": [], "note": "Original Floe starter animation.",
    }


def tileset() -> dict:
    return {
        "id": 1, "mode": 0, "name": "Glimmerfen Tiles",
        "tilesetNames": ["", "", "", "", "", "FloeTiles", "", "", ""],
        "note": "Original Floe synthetic starter tileset. No RTP content.",
    }


def common_event() -> dict:
    return {
        "id": 1, "name": "Ferry Fare", "trigger": 0, "switchId": 1,
        "list": [{"code": 101, "indent": 0, "parameters": ["", 0, 0, 2]},
                 {"code": 401, "indent": 0, "parameters": ["One rope coil, one crossing."]},
                 {"code": 0, "indent": 0, "parameters": []}],
    }


def map_data() -> dict:
    width, height = 12, 10
    data = [0] * (width * height * 6)
    for y in range(height):
        for x in range(width):
            base = 1 + ((x * 3 + y * 5) % 16)
            data[(0 * height + y) * width + x] = base
            data[(1 * height + y) * width + x] = 17 + ((x + y) % 8) if x not in (0, width - 1) else 1
            data[(2 * height + y) * width + x] = 0
            data[(3 * height + y) * width + x] = 0
            data[(4 * height + y) * width + x] = 0
            data[(5 * height + y) * width + x] = 0
    def page(text: str) -> dict:
        return {
            "conditions": {"actorId": 1, "actorValid": False, "itemId": 1, "itemValid": False,
                           "selfSwitchCh": "A", "selfSwitchValid": False, "switch1Id": 1,
                           "switch1Valid": False, "switch2Id": 1, "switch2Valid": False,
                           "variableId": 1, "variableValid": False, "variableValue": 0},
            "directionFix": False, "image": {"characterIndex": 0, "characterName": "FloeHero",
                                              "direction": 2, "pattern": 1, "tileId": 0},
            "list": [{"code": 101, "indent": 0, "parameters": ["", 0, 0, 2]},
                     {"code": 401, "indent": 0, "parameters": [text]},
                     {"code": 0, "indent": 0, "parameters": []}],
            "moveFrequency": 3, "moveRoute": {"list": [{"code": 0, "parameters": []}],
                                              "repeat": True, "skippable": False, "wait": False},
            "moveSpeed": 3, "moveType": 0, "priorityType": 1, "stepAnime": False,
            "through": False, "trigger": 0, "walkAnime": True,
        }
    return {
        "autoplayBgm": False, "autoplayBgs": False, "battleback1Name": "", "battleback2Name": "",
        "bgm": audio(), "bgs": audio(), "disableDashing": False,
        "displayName": "Bracken Quay", "encounterList": [], "encounterStep": 30,
        "height": height, "note": "Original Floe starter map.",
        "parallaxLoopX": False, "parallaxLoopY": False, "parallaxName": "", "parallaxShow": False,
        "parallaxSx": 0, "parallaxSy": 0, "scrollType": 0, "specifyBattleback": False,
        "tilesetId": 1, "width": width, "data": data,
        "events": [None,
                   {"id": 1, "name": "Ferry Keeper", "x": 4, "y": 3,
                    "pages": [page("The tide is turning. Rest at the quay before you cross.")]},
                   {"id": 2, "name": "Notice Stone", "x": 8, "y": 6,
                    "pages": [page("Glimmerfen ferry: one rope coil for a safe crossing.")]}],
    }


def system() -> dict:
    return {
        "gameTitle": "Glimmerfen", "versionId": 1, "currencyUnit": "Glimmer",
        "partyMembers": [1], "startMapId": 1, "startX": 2, "startY": 2,
        "title1Name": "FloeTitle", "title2Name": "",
        "titleBgm": audio(), "battleBgm": audio(), "battleEndMe": audio(),
        "gameoverMe": audio(), "victoryMe": audio(), "defeatMe": audio(),
        "sounds": [audio() for _ in range(24)],
        "elements": ["", "Fire", "Ice", "Spark"],
        "switches": [None, "ferry_available"] + [None] * 19,
        "variables": [None, "rope_count"] + [None] * 19,
        "terms": {
            "basic": ["Level", "HP", "MP", "TP"],
            "commands": ["Fight", "Escape", "Attack", "Guard", "Item", "Skill", "Equip", "Status", "Formation", "Save", "Options"],
            "params": ["Attack", "Defense", "Spirit", "Agility"],
            "messages": {},
        },
        "hasEncryptedImages": False, "hasEncryptedAudio": False, "encryptionKey": "",
        "advanced": {"gameId": 812001, "screenWidth": 816, "screenHeight": 624,
                     "windowWidth": 816, "windowHeight": 624},
    }


PLUGIN_JS = r"""/*:
 * @target MZ
 * @plugindesc Original Floe starter HUD and save/load helpers.
 * @author Floe contributors
 * @help
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Floe contributors. See licenses/FLOE-STARTER-MIT.txt.
 *
 * This is an original plugin for the standard RPG Maker MZ plugin API. It uses
 * only documented core objects (Window_Base, Scene_Map, Input, DataManager,
 * SoundManager, $gamePlayer, $gameParty). It is not a replacement for the
 * licensed rmmz_* core scripts.
 */

(() => {
  'use strict';

  function WindowFloeHud() {
    this.initialize.apply(this, arguments);
  }
  WindowFloeHud.prototype = Object.create(Window_Base.prototype);
  WindowFloeHud.prototype.constructor = WindowFloeHud;
  WindowFloeHud.prototype.initialize = function(rect) {
    Window_Base.prototype.initialize.call(this, rect);
    this.refresh();
  };
  WindowFloeHud.prototype.refresh = function() {
    this.contents.clear();
    this.contents.fontSize = 18;
    const x = $gamePlayer ? $gamePlayer.x : 0;
    const y = $gamePlayer ? $gamePlayer.y : 0;
    const gold = $gameParty ? $gameParty.gold() : 0;
    this.drawText('Glimmerfen  x ' + x + '  y ' + y + '  ' + gold + ' Glimmer', 0, 0, this.contentsWidth(), 'left');
  };

  const _Scene_Map_createAllWindows = Scene_Map.prototype.createAllWindows;
  Scene_Map.prototype.createAllWindows = function() {
    _Scene_Map_createAllWindows.call(this);
    const rect = new Rectangle(12, 12, 420, this.calcWindowHeight(1, false));
    this._floeHud = new WindowFloeHud(rect);
    this.addWindow(this._floeHud);
  };

  const _Scene_Map_update = Scene_Map.prototype.update;
  Scene_Map.prototype.update = function() {
    _Scene_Map_update.call(this);
    if (this._floeHud && Graphics.frameCount % 30 === 0) {
      this._floeHud.refresh();
    }
    if (Input.isTriggered('f5')) {
      DataManager.saveGame(1);
      SoundManager.playSave();
    }
    if (Input.isTriggered('f9')) {
      DataManager.loadGame(1);
      SoundManager.playLoad();
    }
  };
})();
"""

PLUGINS_JS = """// Generated by the original Floe RPG Maker MZ starter.
// Add or remove plugin entries here. No rmmz core scripts are supplied.
var $plugins = [
  {
    "name": "FloeStarter",
    "status": true,
    "description": "Original Floe starter HUD and save/load helpers.",
    "parameters": {}
  }
];
"""


def generate() -> dict:
    if ROOT.exists():
        shutil.rmtree(ROOT)
    ROOT.mkdir(parents=True)
    (ROOT / "Game.rmmzproject").write_text("RPGMZ 1.0.0\n", encoding="utf-8")
    (ROOT / "README.md").write_text(
        "# Glimmerfen (RPG Maker MZ)\n\n"
        "Original Floe starter project in the standard RPG Maker MZ layout.\n"
        "The project data, map, events, plugin and synthetic art are original and\n"
        "MIT-licensed. No licensed `rmmz_*.js` core scripts, RTP, fonts or sample\n"
        "commercial art are bundled.\n\n"
        "Open with a licensed RPG Maker MZ editor/runtime. The editor/runtime is an\n"
        "explicit user prerequisite; this project can still be created, inspected,\n"
        "edited and versioned without it. See licenses/ENGINE-NOTES.md and\n"
        "licenses/FLOE-STARTER-MIT.txt.\n", encoding="utf-8")
    (ROOT / "licenses").mkdir()
    (ROOT / "licenses/FLOE-STARTER-MIT.txt").write_text(MIT_TEXT, encoding="utf-8")
    (ROOT / "licenses/ENGINE-NOTES.md").write_text(
        "# Engine prerequisite\n\n"
        "This project uses the standard RPG Maker MZ data and resource layout but\n"
        "does not include the proprietary `rmmz_*.js` core scripts, the MZ editor,\n"
        "RTP or sample commercial assets. The user must supply a licensed RPG Maker\n"
        "MZ installation to play the project. The original Floe project data,\n"
        "plugin and synthetic art are MIT-licensed; the engine and any imported\n"
        "assets retain their own terms.\n", encoding="utf-8")
    (ROOT / "floe-inputs.json").write_text(json.dumps({
        "schemaVersion": 1, "engine": "rpgMakerMZ",
        "movement": {"left": ["left"], "right": ["right"], "up": ["up"], "down": ["down"]},
        "buttons": [
            {"id": "confirm", "label": "Z (also Enter/Space)", "keys": ["z"]},
            {"id": "cancel", "label": "X (also Esc)", "keys": ["x"]},
            {"id": "actionA", "label": "Shift", "keys": ["shift"]},
            {"id": "save", "label": "F5", "keys": ["f5"]},
            {"id": "load", "label": "F9", "keys": ["f9"]},
        ],
    }, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    data = ROOT / "data"
    write_json(data / "Actors.json", [None, actor()])
    write_json(data / "Classes.json", [None, klass()])
    write_json(data / "Skills.json", [None, skill()])
    write_json(data / "Items.json", [None, item()])
    write_json(data / "Weapons.json", [None, weapon()])
    write_json(data / "Armors.json", [None, armor()])
    write_json(data / "Enemies.json", [None, enemy()])
    write_json(data / "Troops.json", [None, troop()])
    write_json(data / "States.json", [None, state()])
    write_json(data / "Animations.json", [None, animation()])
    write_json(data / "Tilesets.json", [None, tileset()])
    write_json(data / "CommonEvents.json", [None, common_event()])
    write_json(data / "System.json", system())
    write_json(data / "MapInfos.json", [None, {
        "id": 1, "name": "Bracken Quay", "parentId": 0, "order": 1,
        "expanded": False, "scrollX": 0, "scrollY": 0,
    }])
    write_json(data / "Map001.json", map_data())
    js = ROOT / "js"
    js.mkdir()
    (js / "plugins").mkdir()
    (js / "plugins/FloeStarter.js").write_text(PLUGIN_JS, encoding="utf-8")
    (js / "plugins.js").write_text(PLUGINS_JS, encoding="utf-8")
    img = ROOT / "img"
    make_tileset_png(img / "tilesets/FloeTiles.png", 48, 16)
    make_hero(img / "characters/FloeHero.png", 48, 3)
    make_ui(img / "system/Window.png", 192, 192)
    make_ui(img / "system/IconSet.png", 512, 512)
    (ROOT / "fonts").mkdir()
    (ROOT / "fonts/gamefont.css").write_text(
        "/* Original Floe starter font stack; no font files are bundled. */\n"
        "body { font-family: system-ui, -apple-system, 'Segoe UI', sans-serif; }\n",
        encoding="utf-8")
    files = []
    for path in sorted(ROOT.rglob("*")):
        if path.is_file():
            blob = path.read_bytes()
            files.append({"path": path.relative_to(ROOT).as_posix(),
                          "sha256": hashlib.sha256(blob).hexdigest(), "bytes": len(blob)})
            if path.suffix == ".json":
                json.loads(blob.decode("utf-8"))
    assert not list(ROOT.rglob("rmmz_*.js"))
    return {"engine": NAME, "root": str(ROOT), "files": len(files),
            "bytes": sum(x["bytes"] for x in files), "manifest": files}


if __name__ == "__main__":
    print(json.dumps({"starter": generate()}, indent=2, ensure_ascii=False))
