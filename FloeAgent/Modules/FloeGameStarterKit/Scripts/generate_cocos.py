#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Generate an original Cocos Creator 3.8.6 starter project.

The project uses the documented Creator 3.8 project layout (package.json +
assets + settings/v2/packages), a standard serialized .scene with one custom
component, TypeScript source and .meta files. All visuals are drawn at runtime
with Graphics; no third-party art or engine binaries are bundled. The user
supplies Cocos Creator 3.8.6 and its Web Mobile build support.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_legacy_rpg import MIT_TEXT, OUT, png  # noqa: E402


NAME = "cocosCreator"
ROOT = OUT / NAME
CREATOR_VERSION = "3.8.6"
PROJECT_UUID = "e6b0f7c2-6c31-4f24-9f33-6c0edc4f9a18"
SCRIPT_UUID = "0f10e5a1-7a2b-4c3d-8e4f-5a6b7c8d9e0f"
SCENE_UUID = "e2f7c9a4-2b7d-4f7e-8a1c-3d5b6e9f0a21"
TEXTURE_UUID = "7c1d2e3f-4a5b-4c6d-8e7f-9012a3b4c5d6"
SCENE_NODE_ID = "d1a2B3c4D5e6F7g8H9i0Jk"
COMPONENT_ID = "a1B2c3D4e5F6g7H8i9J0kL"

BASE64_KEYS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


def compress_uuid(value: str) -> str:
    raw = value.replace("-", "")
    if len(raw) != 32:
        raise ValueError("UUID must contain 32 hex digits")
    out = raw[:5]
    for index in range(5, 32, 3):
        c = int(raw[index], 16)
        d = int(raw[index + 1], 16)
        e = int(raw[index + 2], 16)
        out += BASE64_KEYS[(c << 2) | (d >> 2)]
        out += BASE64_KEYS[((d & 3) << 4) | e]
    return out


COMPONENT_TYPE = compress_uuid(SCRIPT_UUID)


TS_SOURCE = r"""// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floe contributors. See licenses/FLOE-STARTER-MIT.txt.
import {
  _decorator, Camera, Canvas, Color, Component, EventKeyboard, Graphics, Input,
  KeyCode, Label, Node, ResolutionPolicy, UITransform, Vec3, input, sys, view,
  HorizontalTextAlignment, VerticalTextAlignment,
} from 'cc';

const { ccclass, property } = _decorator;

const WIDTH = 816;
const HEIGHT = 624;
const TILE = 48;
const SAVE_KEY = 'floe.glimmerfen.save.v1';

@ccclass('FloeStarter')
export class FloeStarter extends Component {
  @property
  public speed = 180;

  private canvasNode: Node | null = null;
  private graphics: Graphics | null = null;
  private hud: Label | null = null;
  private message: Label | null = null;
  private menuLabel: Label | null = null;
  private keys = new Set<number>();
  private player = { x: 2, y: 2 };
  private steps = 0;
  private score = 0;
  private menu = false;
  private menuIndex = 0;
  private text = '';
  private textFrames = 0;
  private touchTarget: { x: number; y: number } | null = null;

  start() {
    view.setDesignResolutionSize(WIDTH, HEIGHT, ResolutionPolicy.SHOW_ALL);
    this.buildScene();
    input.on(Input.EventType.KEY_DOWN, this.onKeyDown, this);
    input.on(Input.EventType.KEY_UP, this.onKeyUp, this);
    input.on(Input.EventType.TOUCH_START, this.onTouch, this);
    input.on(Input.EventType.TOUCH_MOVE, this.onTouch, this);
    this.redraw();
  }

  onDestroy() {
    input.off(Input.EventType.KEY_DOWN, this.onKeyDown, this);
    input.off(Input.EventType.KEY_UP, this.onKeyUp, this);
    input.off(Input.EventType.TOUCH_START, this.onTouch, this);
    input.off(Input.EventType.TOUCH_MOVE, this.onTouch, this);
  }

  private buildScene() {
    const canvasNode = new Node('FloeCanvas');
    canvasNode.layer = 1 << 25;
    const canvas = canvasNode.addComponent(Canvas);
    const transform = canvasNode.addComponent(UITransform);
    transform.setContentSize(WIDTH, HEIGHT);
    this.node.scene.addChild(canvasNode);

    const cameraNode = new Node('FloeCamera');
    const camera = cameraNode.addComponent(Camera);
    camera.projection = Camera.ProjectionType.ORTHO;
    camera.orthoHeight = HEIGHT / 2;
    camera.clearFlags = Camera.ClearFlag.SOLID_COLOR;
    camera.clearColor = new Color(14, 28, 24, 255);
    camera.visibility = 1 << 25;
    canvasNode.addChild(cameraNode);
    canvas.cameraComponent = camera;
    this.canvasNode = canvasNode;

    const drawNode = new Node('FloeDraw');
    drawNode.layer = 1 << 25;
    this.graphics = drawNode.addComponent(Graphics);
    canvasNode.addChild(drawNode);

    this.hud = this.makeLabel('FloeHud', 18, new Color(238, 240, 218, 255), new Vec3(-380, 280, 0));
    this.message = this.makeLabel('FloeMessage', 18, new Color(255, 240, 190, 255), new Vec3(0, -250, 0));
    this.menuLabel = this.makeLabel('FloeMenu', 20, new Color(255, 225, 140, 255), new Vec3(240, 40, 0));
    this.menuLabel.node.active = false;
    this.message.node.active = false;
  }

  private makeLabel(name: string, size: number, color: Color, position: Vec3): Label {
    const node = new Node(name);
    node.layer = 1 << 25;
    node.setPosition(position);
    const label = node.addComponent(Label);
    label.fontSize = size;
    label.lineHeight = size + 6;
    label.color = color;
    label.horizontalAlign = HorizontalTextAlignment.LEFT;
    label.verticalAlign = VerticalTextAlignment.CENTER;
    label.overflow = Label.Overflow.SHRINK;
    const transform = node.addComponent(UITransform);
    transform.setContentSize(740, 48);
    this.canvasNode!.addChild(node);
    return label;
  }

  private onKeyDown(event: EventKeyboard) {
    this.keys.add(event.keyCode);
    if (this.isConfirm(event.keyCode)) this.activate();
    if (this.isCancel(event.keyCode)) this.toggleMenu();
    if (event.keyCode === KeyCode.KEY_Q) this.menuIndex = (this.menuIndex + 2) % 3;
    if (event.keyCode === KeyCode.KEY_W) this.menuIndex = (this.menuIndex + 1) % 3;
    if (event.keyCode === KeyCode.F5) this.saveGame();
    if (event.keyCode === KeyCode.F9) this.loadGame();
    if (this.menu) {
      if (event.keyCode === KeyCode.ARROW_UP) this.menuIndex = (this.menuIndex + 2) % 3;
      if (event.keyCode === KeyCode.ARROW_DOWN) this.menuIndex = (this.menuIndex + 1) % 3;
    }
  }

  private onKeyUp(event: EventKeyboard) {
    this.keys.delete(event.keyCode);
  }

  private onTouch(event: any) {
    if (!this.canvasNode) return;
    const location = event.getUILocation();
    const local = this.canvasNode.getComponent(UITransform)!.convertToNodeSpaceAR(new Vec3(location.x, location.y, 0));
    this.touchTarget = {
      x: Math.max(1, Math.min(10, Math.round((local.x + WIDTH / 2) / TILE))),
      y: Math.max(1, Math.min(8, Math.round((HEIGHT / 2 - local.y) / TILE))),
    };
  }

  private isConfirm(code: number) {
    return code === KeyCode.KEY_Z || code === KeyCode.ENTER || code === KeyCode.SPACE;
  }

  private isCancel(code: number) {
    return code === KeyCode.KEY_X || code === KeyCode.ESCAPE;
  }

  private activate() {
    if (this.menu) {
      if (this.menuIndex === 1) this.saveGame();
      if (this.menuIndex === 2) this.loadGame();
      this.menu = false;
      return;
    }
    const near = this.player.x === 4 && this.player.y === 3 || this.player.x === 8 && this.player.y === 6;
    this.say(near ? 'The ferry keeper nods. One rope coil, one crossing.' : 'The fen is quiet. The ferry waits to the east.');
    if (this.player.x === 8 && this.player.y === 6 && this.score === 0) {
      this.score = 1;
      this.say('You pocket a coil of rope from the notice stone.');
    }
  }

  private toggleMenu() {
    this.menu = !this.menu;
    this.menuIndex = 0;
    this.redraw();
  }

  private say(text: string) {
    this.text = text;
    this.textFrames = 240;
    this.redraw();
  }

  private saveGame() {
    sys.localStorage.setItem(SAVE_KEY, JSON.stringify({
      version: 1, x: this.player.x, y: this.player.y, steps: this.steps, score: this.score,
    }));
    this.say('Saved to local storage.');
  }

  private loadGame() {
    try {
      const raw = sys.localStorage.getItem(SAVE_KEY);
      if (!raw) { this.say('No save yet.'); return; }
      const value = JSON.parse(raw);
      if (!value || value.version !== 1 || !Number.isFinite(value.x) || !Number.isFinite(value.y)) {
        this.say('That save is not compatible.'); return;
      }
      this.player.x = Math.max(0, Math.min(11, value.x));
      this.player.y = Math.max(0, Math.min(9, value.y));
      this.steps = Number.isFinite(value.steps) ? value.steps : this.steps;
      this.score = Number.isFinite(value.score) ? Math.max(0, Math.min(1, value.score)) : this.score;
      this.say('Loaded from local storage.');
    } catch (_) {
      this.say('The save could not be read.');
    }
  }

  update(dt: number) {
    if (!this.menu) {
      let dx = 0, dy = 0;
      if (this.keys.has(KeyCode.ARROW_LEFT)) dx -= 1;
      if (this.keys.has(KeyCode.ARROW_RIGHT)) dx += 1;
      if (this.keys.has(KeyCode.ARROW_UP)) dy -= 1;
      if (this.keys.has(KeyCode.ARROW_DOWN)) dy += 1;
      if (this.touchTarget) {
        dx = Math.sign(this.touchTarget.x - this.player.x);
        dy = Math.sign(this.touchTarget.y - this.player.y);
        if (Math.abs(this.touchTarget.x - this.player.x) + Math.abs(this.touchTarget.y - this.player.y) <= 1) this.touchTarget = null;
      }
      if (dx || dy) {
        const step = Math.min(dt, 1 / 30) * this.speed / TILE;
        if (step > 0.5) {
          this.player.x = Math.max(0, Math.min(11, this.player.x + dx));
          this.player.y = Math.max(0, Math.min(9, this.player.y + dy));
          this.steps += 1;
          if (this.player.x === 8 && this.player.y === 6 && this.score === 0) {
            this.score = 1;
            this.say('You pocket a coil of rope from the notice stone.');
          }
        }
      }
    }
    if (this.textFrames > 0) {
      this.textFrames -= 1;
      if (this.textFrames === 0) this.text = '';
    }
    this.redraw();
  }

  private redraw() {
    if (!this.graphics || !this.hud) return;
    const g = this.graphics;
    g.clear();
    g.fillColor = new Color(19, 35, 30, 255);
    g.rect(-WIDTH / 2, -HEIGHT / 2, WIDTH, HEIGHT);
    g.fill();
    for (let y = 0; y < 10; y++) {
      for (let x = 0; x < 12; x++) {
        const edge = x === 0 || y === 0 || x === 11 || y === 9;
        g.fillColor = edge ? new Color(38, 62, 50, 255) : new Color(30 + (x + y) % 3 * 4, 58 + (x * 3 + y) % 4 * 3, 47, 255);
        g.rect(-WIDTH / 2 + x * TILE + 2, HEIGHT / 2 - (y + 1) * TILE + 2, TILE - 4, TILE - 4);
        g.fill();
      }
    }
    g.fillColor = new Color(151, 108, 67, 255);
    g.rect(-WIDTH / 2 + 4 * TILE, HEIGHT / 2 - 4 * TILE, TILE, TILE);
    g.fill();
    if (this.score === 0) {
      g.fillColor = new Color(255, 207, 85, 255);
      g.circle(-WIDTH / 2 + 8 * TILE + TILE / 2, HEIGHT / 2 - 7 * TILE + TILE / 2, 12);
      g.fill();
    }
    g.fillColor = new Color(142, 214, 255, 255);
    g.circle(-WIDTH / 2 + this.player.x * TILE + TILE / 2, HEIGHT / 2 - this.player.y * TILE - TILE / 2, 16);
    g.fill();
    this.hud.string = `Glimmerfen  steps ${this.steps}  rope ${this.score}/1`;
    this.message.string = this.text;
    this.message.node.active = !!this.text;
    this.menuLabel.node.active = this.menu;
    if (this.menu) {
      this.menuLabel.string = ['Resume', 'Save', 'Load'].map((item, index) =>
        `${index === this.menuIndex ? '▶ ' : '  '}${item}`).join('\n');
    }
  }
}
"""


def write(path: Path, data: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(data, encoding="utf-8")


def scene() -> str:
    return json.dumps([
        {"__type__": "cc.SceneAsset", "_name": "", "_objFlags": 0, "_native": "",
         "scene": {"__id__": 1}},
        {"__type__": "cc.Scene", "_name": "Main", "_objFlags": 0, "_parent": None,
         "_children": [{"__id__": 2}], "_active": True, "_components": [],
         "_prefab": None, "autoReleaseAssets": False,
         "_globals": {"__id__": 4}, "_id": SCENE_UUID},
        {"__type__": "cc.Node", "_name": "FloeStarter", "_objFlags": 0,
         "_parent": {"__id__": 1}, "_children": [], "_active": True,
         "_components": [{"__id__": 3}], "_prefab": None,
         "_lpos": {"__type__": "cc.Vec3", "x": 0, "y": 0, "z": 0},
         "_lrot": {"__type__": "cc.Quat", "x": 0, "y": 0, "z": 0, "w": 1},
         "_lscale": {"__type__": "cc.Vec3", "x": 1, "y": 1, "z": 1},
         "_mobility": 0, "_layer": 1073741824,
         "_euler": {"__type__": "cc.Vec3", "x": 0, "y": 0, "z": 0},
         "_id": SCENE_NODE_ID},
        {"__type__": COMPONENT_TYPE, "_name": "", "_objFlags": 0,
         "node": {"__id__": 2}, "_enabled": True, "__prefab": None,
         "speed": 180, "_id": COMPONENT_ID},
        {"__type__": "cc.SceneGlobals", "ambient": {"__id__": 5},
         "shadows": {"__id__": 6}, "_skybox": {"__id__": 7},
         "fog": {"__id__": 8}},
        {"__type__": "cc.AmbientInfo", "_skyColor": {"__type__": "cc.Color", "r": 51, "g": 128, "b": 204, "a": 1},
         "_skyIllum": 20000, "_groundAlbedo": {"__type__": "cc.Color", "r": 51, "g": 51, "b": 51, "a": 255}},
        {"__type__": "cc.ShadowsInfo", "_type": 0, "_enabled": False,
         "_normal": {"__type__": "cc.Vec3", "x": 0, "y": 1, "z": 0},
         "_distance": 0, "_shadowColor": {"__type__": "cc.Color", "r": 76, "g": 76, "b": 76, "a": 255},
         "_autoAdapt": True, "_pcf": 0, "_bias": 1e-05, "_near": 1, "_far": 30,
         "_aspect": 1, "_orthoSize": 5, "_maxReceived": 4,
         "_size": {"__type__": "cc.Vec2", "x": 512, "y": 512}},
        {"__type__": "cc.SkyboxInfo", "_envmap": None, "_isRGBE": False,
         "_enabled": False, "_useIBL": False},
        {"__type__": "cc.FogInfo", "_type": 0,
         "_fogColor": {"__type__": "cc.Color", "r": 200, "g": 200, "b": 200, "a": 255},
         "_enabled": False, "_fogDensity": 0.3, "_fogStart": 0.5,
         "_fogEnd": 300, "_fogAtten": 5, "_fogTop": 1.5, "_fogRange": 1.2},
    ], indent=2) + "\n"


def meta_script(path: str) -> dict:
    return {"ver": "4.0.23", "importer": "typescript", "imported": True,
            "uuid": SCRIPT_UUID, "files": [], "subMetas": {},
            "userData": {"moduleId": "project:///assets/scripts/FloeStarter.js",
                         "simulateGlobals": []}}


def meta_scene() -> dict:
    return {"ver": "1.1.45", "importer": "scene", "imported": True,
            "uuid": SCENE_UUID, "files": [".json"], "subMetas": {}, "userData": {}}


def meta_directory(uuid: str) -> dict:
    return {"ver": "1.2.0", "importer": "directory", "imported": True,
            "uuid": uuid, "files": [], "subMetas": {},
            "userData": {"compressionType": {}, "isRemoteBundle": {}}}


def meta_texture() -> dict:
    return {"ver": "1.0.26", "importer": "image", "imported": True,
            "uuid": TEXTURE_UUID, "files": [".json", ".png"],
            "subMetas": {"floe_orb": {
                "ver": "1.0.26", "importer": "texture", "imported": True,
                "uuid": TEXTURE_UUID, "files": [".json"], "subMetas": {},
                "userData": {"wrapMode": "clamp", "filterMode": "bilinear"}}},
            "userData": {"type": "sprite", "hasAlpha": True, "fixAlphaTransparencyArtifacts": False}}


def generate() -> dict:
    if ROOT.exists():
        shutil.rmtree(ROOT)
    ROOT.mkdir(parents=True)
    write(ROOT / "package.json", json.dumps({
        "name": "floe-glimmerfen-cocos",
        "type": "2d",
        "uuid": PROJECT_UUID,
        "version": CREATOR_VERSION,
        "creator": {"version": CREATOR_VERSION},
    }, indent=2) + "\n")
    write(ROOT / "tsconfig.json", json.dumps({
        "extends": "./temp/tsconfig.cocos.json",
        "compilerOptions": {
            "strict": False,
            "target": "ES2015",
            "module": "ES2015",
            "experimentalDecorators": True,
        },
    }, indent=2) + "\n")
    write(ROOT / "settings/v2/packages/project.json", json.dumps({
        "__version__": "1.0.1",
        "general": {"designResolution": {"width": 816, "height": 624,
                                         "fitWidth": False, "fitHeight": True}},
        "script": {},
    }, indent=2) + "\n")
    write(ROOT / "settings/v2/packages/builder.json", json.dumps({
        "__version__": "1.3.9",
        "common": {"buildPath": "build", "outputName": "web-mobile",
                   "mainBundleCompressionType": "merge_all_json",
                   "platform": "web-mobile"},
    }, indent=2) + "\n")
    # Explicit configs consumed by the shared Creator command-line CI route.
    # outputName + project://build must match the artifact packaging paths.
    common = {"name": "Glimmerfen", "buildPath": "project://build",
              "startScene": SCENE_UUID, "debug": True, "md5Cache": False,
              "mainBundleCompressionType": "merge_all_json"}
    write(ROOT / "floe-cocos-build.json", json.dumps({
        **common, "platform": "web-mobile", "outputName": "web-mobile"
    }, indent=2) + "\n")
    write(ROOT / "floe-cocos-android.json", json.dumps({
        **common, "platform": "android", "outputName": "android",
        "packages": {"android": {"packageName": "org.floe.glimmerfen"}}
    }, indent=2) + "\n")
    write(ROOT / "assets/scripts/FloeStarter.ts", TS_SOURCE)
    write(ROOT / "assets/scripts/FloeStarter.ts.meta", json.dumps(meta_script("assets/scripts/FloeStarter.ts"), indent=2) + "\n")
    write(ROOT / "assets/Scenes/Main.scene", scene())
    write(ROOT / "assets/Scenes/Main.scene.meta", json.dumps(meta_scene(), indent=2) + "\n")
    write(ROOT / "assets/Scenes.meta", json.dumps(meta_directory("3d8a9e11-2c4f-4b6d-8e7f-1a2b3c4d5e6f"), indent=2) + "\n")
    write(ROOT / "assets/scripts.meta", json.dumps(meta_directory("4e9b0f22-3d5a-4c7e-9f81-2b3c4d5e6f70"), indent=2) + "\n")
    write(ROOT / "assets/Textures.meta", json.dumps(meta_directory("5f0c1a33-4e6b-4d8f-a092-3c4d5e6f7081"), indent=2) + "\n")
    orb = png(64, 64, lambda x, y: (
        (255 if (x - 32) ** 2 + (y - 32) ** 2 < 24 ** 2 else 0),
        (207 if (x - 32) ** 2 + (y - 32) ** 2 < 24 ** 2 else 0),
        (85 if (x - 32) ** 2 + (y - 32) ** 2 < 24 ** 2 else 0),
        255 if (x - 32) ** 2 + (y - 32) ** 2 < 24 ** 2 else 0,
    ))
    (ROOT / "assets/Textures").mkdir(parents=True, exist_ok=True)
    (ROOT / "assets/Textures/FloeOrb.png").write_bytes(orb)
    write(ROOT / "assets/Textures/FloeOrb.png.meta", json.dumps(meta_texture(), indent=2) + "\n")
    write(ROOT / "floe-inputs.json", json.dumps({
        "schemaVersion": 1, "engine": "cocosCreator",
        "movement": {"left": ["left"], "right": ["right"], "up": ["up"], "down": ["down"]},
        "buttons": [
            {"id": "confirm", "label": "Z (also Enter/Space)", "keys": ["z"]},
            {"id": "cancel", "label": "X (also Esc)", "keys": ["x"]},
            {"id": "pageLeft", "label": "Q", "keys": ["q"]},
            {"id": "pageRight", "label": "W", "keys": ["w"]},
            {"id": "save", "label": "F5", "keys": ["f5"]},
            {"id": "load", "label": "F9", "keys": ["f9"]},
        ],
    }, indent=2, ensure_ascii=False) + "\n")
    write(ROOT / "README.md", f"""# Glimmerfen (Cocos Creator {CREATOR_VERSION})

Original Floe starter project. It uses the documented Cocos Creator 3.8 project
layout (`package.json`, `assets/`, `settings/v2/packages/`), a serialized
`Main.scene` with one original TypeScript component and a generated runtime
scene drawn with `Graphics`. No third-party art or engine binaries are bundled.

## Prerequisites

- Cocos Creator {CREATOR_VERSION} (the pinned supported editor version).
- The Web Mobile build target if you want to build a browser artifact.

Open the folder in Cocos Creator and run the `Main` scene, or build Web Mobile
from the editor. This source package does not claim an editor or Web build was
executed on this host. The original source and synthetic art are MIT-licensed;
the Cocos Creator engine retains its own terms.
""")
    write(ROOT / "licenses/FLOE-STARTER-MIT.txt", MIT_TEXT)
    write(ROOT / "licenses/ENGINE-NOTES.md",
          "# Engine prerequisite\n\n"
          f"This project targets Cocos Creator {CREATOR_VERSION}. It does not include the\n"
          "Cocos Creator editor or engine binaries. The user must install the pinned\n"
          "editor and its Web Mobile build support. The original Floe TypeScript\n"
          "source, scene data and synthetic art are MIT-licensed; Cocos Creator and\n"
          "any imported assets retain their own terms.\n")
    files = []
    for path in sorted(ROOT.rglob("*")):
        if path.is_file():
            blob = path.read_bytes()
            files.append({"path": path.relative_to(ROOT).as_posix(),
                          "sha256": hashlib.sha256(blob).hexdigest(), "bytes": len(blob)})
            if path.suffix == ".json" or path.suffix == ".scene" or path.suffix == ".meta":
                json.loads(blob.decode("utf-8"))
    catalog = json.loads((ROOT / "assets/Scenes/Main.scene").read_text())
    assert any(isinstance(item, dict) and item.get("__type__") == COMPONENT_TYPE for item in catalog)
    return {"engine": NAME, "root": str(ROOT), "files": len(files),
            "bytes": sum(x["bytes"] for x in files), "manifest": files,
            "componentType": COMPONENT_TYPE}


if __name__ == "__main__":
    print(json.dumps({"starter": generate()}, indent=2, ensure_ascii=False))
