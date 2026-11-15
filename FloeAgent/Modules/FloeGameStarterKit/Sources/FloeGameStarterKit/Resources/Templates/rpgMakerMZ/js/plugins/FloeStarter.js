/*:
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
