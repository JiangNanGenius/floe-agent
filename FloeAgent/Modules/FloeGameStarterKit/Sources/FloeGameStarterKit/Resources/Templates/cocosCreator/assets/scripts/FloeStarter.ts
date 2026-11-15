// SPDX-License-Identifier: MIT
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
