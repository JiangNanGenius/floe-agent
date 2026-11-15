/* SPDX-License-Identifier: MPL-2.0 */
/* Floe RPG Maker MV/MZ host hook. Runs only with window.FloeDeveloper. */
(function () {
  "use strict";
  var D = window.FloeDeveloper;
  if (!D) return;
  var attempts = 0;

  function boot() {
    if (!window.$gameParty || !window.$gameVariables || !window.$gamePlayer || !window.$gameMap) {
      attempts++;
      if (attempts < 300) setTimeout(boot, 100);
      return;
    }
    register();
  }

  function group(en, zh) { return { group: en, groupZhHans: zh }; }
  function label(en, zh) { return { label: en, labelZhHans: zh }; }
  function field(id, en, zh, g, gzh, kind, extra) {
    var value = { id: id, label: en, labelZhHans: zh, group: g, groupZhHans: gzh, kind: kind };
    if (extra) Object.keys(extra).forEach(function (key) { value[key] = extra[key]; });
    return value;
  }
  function action(id, en, zh, g, gzh, symbol, extra) {
    var value = { id: id, label: en, labelZhHans: zh, group: g, groupZhHans: gzh, symbol: symbol };
    if (extra) Object.keys(extra).forEach(function (key) { value[key] = extra[key]; });
    return value;
  }

  function members() {
    try { return $gameParty.members() || []; } catch (e) { return []; }
  }
  function actor(id, index) { return members().filter(function (a) { return a && a.actorId() === id; })[0] || members()[index]; }
  function actorName(a) { try { return a && a.name ? String(a.name()).slice(0, 128) : "Actor"; } catch (e) { return "Actor"; } }
  function itemName(id) { try { return $dataItems && $dataItems[id] ? String($dataItems[id].name).slice(0, 128) : "Item " + id; } catch (e) { return "Item " + id; } }
  function mapName(id) { try { return $dataMapInfos && $dataMapInfos[id] ? String($dataMapInfos[id].name).slice(0, 128) : "Map " + id; } catch (e) { return "Map " + id; } }
  function variableValue(id) { try { return $gameVariables.value(id); } catch (e) { return null; } }
  function variableName(id) { try { var name = $dataSystem.variables[id]; return name ? String(name).slice(0, 128) : "Variable " + id; } catch (e) { return "Variable " + id; } }
  function switchName(id) { try { var name = $dataSystem.switches[id]; return name ? String(name).slice(0, 128) : "Switch " + id; } catch (e) { return "Switch " + id; } }
  function gamePaused() { try { return !!SceneManager._stopped; } catch (e) { return false; } }
  function canPause() { try { return typeof SceneManager.stop === "function" && typeof SceneManager.resume === "function"; } catch (e) { return false; } }
  function canLevel() {
    var list = members();
    return list.length > 0 && list.every(function (a) { return a && typeof a.changeLevel === "function"; });
  }
  function canHeal() {
    var list = members();
    return list.length > 0 && list.every(function (a) {
      return a && (typeof a.setHp === "function" || typeof a.gainHp === "function") &&
        (typeof a.setMp === "function" || typeof a.gainMp === "function");
    });
  }
  function healActor(a) {
    if (typeof a.setHp === "function") a.setHp(a.mhp); else if (typeof a.gainHp === "function") a.gainHp(a.mhp - a.hp);
    if (typeof a.setMp === "function") a.setMp(a.mmp); else if (typeof a.gainMp === "function") a.gainMp(a.mmp - a.mp);
  }
  function itemSummary() {
    try {
      var result = [];
      var items = $gameParty.items() || [];
      for (var i = 0; i < items.length && result.length < 16; i++) {
        result.push(String(items[i].name).slice(0, 64) + " x" + $gameParty.numItems(items[i]));
      }
      return result.join(", ") || "—";
    } catch (e) { return "—"; }
  }
  function membersSummary() {
    try {
      return members().slice(0, 8).map(function (a) {
        return actorName(a) + " L" + a.level + " HP" + a.hp + "/" + a.mhp + " MP" + a.mp + "/" + a.mmp;
      }).join("; ").slice(0, 2048);
    } catch (e) { return "—"; }
  }
  function namedIDs(names, values, maximum) {
    var result = [];
    var length = names ? names.length : 0;
    for (var id = 1; id < length && result.length < maximum; id++) {
      var name = names[id];
      var value = values(id);
      if ((name && String(name).length > 0) || (value !== 0 && value !== false && value !== null && value !== "")) result.push(id);
    }
    return result;
  }

  function snapshotState() {
    try {
      if (typeof DataManager === "undefined" || typeof JsonEx === "undefined") return null;
      return JSON.parse(JsonEx.stringify(DataManager.makeSaveContents()));
    } catch (error) { return null; }
  }

  function restoreState(state) {
    try {
      if (!state || typeof DataManager === "undefined" || typeof JsonEx === "undefined") return false;
      DataManager.extractSaveContents(JsonEx.parse(JSON.stringify(state)));
      if (typeof $gamePlayer.refresh === "function") $gamePlayer.refresh();
      if (typeof $gameMap.requestRefresh === "function") $gameMap.requestRefresh();
      if (typeof Scene_Map !== "undefined" && typeof SceneManager.goto === "function") SceneManager.goto(Scene_Map);
      return true;
    } catch (error) { return false; }
  }

  function register() {
    var fields = [];
    var actions = [];
    fields.push(field("party.gold", "Party gold", "队伍金钱", "Party", "队伍", "integer", {
      symbol: "dollarsign.circle", minimum: 0, maximum: 99999999, step: 1,
      get: function () { return $gameParty.gold(); },
      set: function (value) { $gameParty.gainGold(value - $gameParty.gold()); }
    }));
    fields.push(field("party.members", "Party", "队伍成员", "Party", "队伍", "readOnlyText", { symbol: "person.3", get: membersSummary }));
    var list = members().slice(0, 4);
    list.forEach(function (a) {
      var id = a.actorId();
      var name = actorName(a);
      fields.push(field("party.actor." + id + ".level", name + " · level", name + " · 等级", "Party", "队伍", "readOnlyNumber", { symbol: "star", minimum: 1, maximum: 99, get: function () { return actor(id, 0).level; } }));
      fields.push(field("party.actor." + id + ".hp", name + " · HP", name + " · HP", "Party", "队伍", "integer", { symbol: "heart", minimum: 0, maximum: 999999, step: 1, get: function () { return actor(id, 0).hp; }, set: function (v) { var a = actor(id, 0); if (a.setHp) a.setHp(v); else a.gainHp(v - a.hp); } }));
      fields.push(field("party.actor." + id + ".mp", name + " · MP", name + " · MP", "Party", "队伍", "integer", { symbol: "drop", minimum: 0, maximum: 999999, step: 1, get: function () { return actor(id, 0).mp; }, set: function (v) { var a = actor(id, 0); if (a.setMp) a.setMp(v); else a.gainMp(v - a.mp); } }));
    });
    fields.push(field("party.items", "Party items", "队伍物品", "Items", "物品", "readOnlyText", { symbol: "shippingbox", get: itemSummary }));
    fields.push(field("map.id", "Map", "地图", "World", "世界", "readOnlyNumber", { symbol: "map", get: function () { return $gameMap.mapId(); } }));
    fields.push(field("player.x", "Player X", "玩家 X", "World", "世界", "integer", { symbol: "arrow.left.and.right", minimum: 0, maximum: 9999, step: 1, get: function () { return $gamePlayer.x; }, set: function (v) { $gamePlayer.locate(v, $gamePlayer.y); } }));
    fields.push(field("player.y", "Player Y", "玩家 Y", "World", "世界", "integer", { symbol: "arrow.up.and.down", minimum: 0, maximum: 9999, step: 1, get: function () { return $gamePlayer.y; }, set: function (v) { $gamePlayer.locate($gamePlayer.x, v); } }));
    fields.push(field("player.moveSpeed", "Move speed", "移动速度", "World", "世界", "integer", { symbol: "hare", minimum: 1, maximum: 6, step: 1, get: function () { return $gamePlayer._moveSpeed || 4; }, set: function (v) { $gamePlayer._moveSpeed = v; } }));
    fields.push(field("system.playtime", "Playtime", "游戏时长", "World", "世界", "readOnlyText", { symbol: "clock", get: function () { return $gameSystem.playtimeText(); } }));
    fields.push(field("system.battles", "Battles", "战斗次数", "World", "世界", "readOnlyNumber", { symbol: "shield", get: function () { return $gameSystem.battleCount(); } }));
    fields.push(field("system.saves", "Saves", "存档次数", "World", "世界", "readOnlyNumber", { symbol: "externaldrive", get: function () { return $gameSystem.saveCount(); } }));
    fields.push(field("system.steps", "Steps", "步数", "World", "世界", "readOnlyNumber", { symbol: "figure.walk", get: function () { return $gameParty.steps(); } }));
    if (canPause()) fields.push(field("engine.paused", "Paused", "已暂停", "Engine", "引擎", "readOnlyBoolean", { symbol: "pause", get: gamePaused }));

    namedIDs($dataSystem.variables, variableValue, 48).forEach(function (id) {
      var current = variableValue(id);
      var kind = (typeof current === "number") ? "number" : (typeof current === "boolean" ? "boolean" : "readOnlyText");
      var extra = { symbol: "number", get: function () { return variableValue(id); } };
      if (kind === "number") { extra.minimum = -1000000000000; extra.maximum = 1000000000000; extra.set = function (v) { $gameVariables.setValue(id, v); }; }
      if (kind === "boolean") extra.set = function (v) { $gameVariables.setValue(id, v); };
      fields.push(field("variables.v" + id, variableName(id), variableName(id), "Variables", "变量", kind, extra));
    });
    namedIDs($dataSystem.switches, function (id) { return $gameSwitches.value(id); }, 48).forEach(function (id) {
      fields.push(field("switches.s" + id, switchName(id), switchName(id), "Switches", "开关", "boolean", { symbol: "switch.2", get: function () { return $gameSwitches.value(id); }, set: function (v) { $gameSwitches.setValue(id, !!v); } }));
    });

    actions.push(action("engine.pause", "Pause", "暂停", "Engine", "引擎", "pause.fill", { isQuick: true, detail: "SceneManager.stop() freezes scene updates; audio continues.", detailZhHans: "SceneManager.stop() 冻结场景更新；音频继续。", invoke: function () { SceneManager.stop(); return { message: "Game paused.", messageZhHans: "游戏已暂停。" }; } }));
    actions.push(action("engine.resume", "Resume", "继续", "Engine", "引擎", "play.fill", { isQuick: true, invoke: function () { SceneManager.resume(); return { message: "Game resumed.", messageZhHans: "游戏已继续。" }; } }));
    actions.push(action("party.gainGold", "Gain gold", "增加金钱", "Party", "队伍", "dollarsign.circle", {
      parameters: [{ id: "amount", label: "Amount", labelZhHans: "数量", kind: "integer", minimum: -9999999, maximum: 9999999, step: 1, isRequired: true, defaultValue: 1000 }],
      invoke: function (args) { $gameParty.gainGold(args.amount); return { message: "Gold is now " + $gameParty.gold() + ".", messageZhHans: "当前金钱：" + $gameParty.gold() + "。" }; }
    }));
    if (canHeal()) actions.push(action("party.healAll", "Heal party", "治疗队伍", "Party", "队伍", "cross.case", { invoke: function () { members().forEach(healActor); return { message: "Party healed.", messageZhHans: "队伍已治疗。" }; } }));
    if (canLevel()) actions.push(action("party.levelAll", "Set party level", "设置队伍等级", "Party", "队伍", "star.circle", {
      parameters: [{ id: "level", label: "Level", labelZhHans: "等级", kind: "integer", minimum: 1, maximum: 99, step: 1, isRequired: true, defaultValue: 10 }],
      invoke: function (args) { members().forEach(function (a) { a.changeLevel(args.level, false); }); return { message: "Party level set.", messageZhHans: "队伍等级已设置。" }; }
    }));
    actions.push(action("party.addItem", "Add item", "添加物品", "Items", "物品", "plus.square", {
      parameters: [
        { id: "itemID", label: "Item ID", labelZhHans: "物品 ID", kind: "integer", minimum: 1, maximum: Math.max(1, ($dataItems ? $dataItems.length - 1 : 1)), step: 1, isRequired: true, defaultValue: 1 },
        { id: "count", label: "Count", labelZhHans: "数量", kind: "integer", minimum: 1, maximum: 99, step: 1, isRequired: true, defaultValue: 1 }
      ],
      invoke: function (args) { var item = $dataItems && $dataItems[args.itemID]; if (!item) throw new Error("Unknown item."); $gameParty.gainItem(item, args.count); return { message: "Added " + itemName(args.itemID) + " x" + args.count + ".", messageZhHans: "已添加 " + itemName(args.itemID) + " x" + args.count + "。" }; }
    }));
    actions.push(action("player.transfer", "Transfer player", "传送玩家", "World", "世界", "arrow.triangle.turn.up.right.diamond", {
      role: "jump",
      parameters: [
        { id: "mapID", label: "Map ID", labelZhHans: "地图 ID", kind: "integer", minimum: 1, maximum: Math.max(1, ($dataMapInfos ? $dataMapInfos.length - 1 : 1)), step: 1, isRequired: true, defaultValue: 1 },
        { id: "x", label: "X", labelZhHans: "X", kind: "integer", minimum: 0, maximum: 9999, step: 1, isRequired: true, defaultValue: 0 },
        { id: "y", label: "Y", labelZhHans: "Y", kind: "integer", minimum: 0, maximum: 9999, step: 1, isRequired: true, defaultValue: 0 }
      ],
      invoke: function (args) { $gamePlayer.reserveTransfer(args.mapID, args.x, args.y, 0, 0); return { message: "Transfer to " + mapName(args.mapID) + ".", messageZhHans: "正在传送到 " + mapName(args.mapID) + "。" }; }
    }));
    actions.push(action("variables.set", "Set variable", "设置变量", "Variables", "变量", "number", {
      parameters: [
        { id: "variableID", label: "Variable ID", labelZhHans: "变量 ID", kind: "integer", minimum: 1, maximum: Math.max(1, ($dataSystem.variables ? $dataSystem.variables.length - 1 : 1)), step: 1, isRequired: true, defaultValue: 1 },
        { id: "value", label: "Value", labelZhHans: "值", kind: "text", maximumLength: 8192, isRequired: true }
      ],
      invoke: function (args) { var raw = String(args.value); var value = /^-?\d+(\.\d+)?$/.test(raw) ? Number(raw) : raw; $gameVariables.setValue(args.variableID, value); return { message: "Variable updated.", messageZhHans: "变量已更新。" }; }
    }));
    actions.push(action("switches.set", "Set switch", "设置开关", "Switches", "开关", "switch.2", {
      parameters: [
        { id: "switchID", label: "Switch ID", labelZhHans: "开关 ID", kind: "integer", minimum: 1, maximum: Math.max(1, ($dataSystem.switches ? $dataSystem.switches.length - 1 : 1)), step: 1, isRequired: true, defaultValue: 1 },
        { id: "value", label: "Value", labelZhHans: "值", kind: "boolean", isRequired: true, defaultValue: true }
      ],
      invoke: function (args) { $gameSwitches.setValue(args.switchID, !!args.value); return { message: "Switch updated.", messageZhHans: "开关已更新。" }; }
    }));

    D.setRuntime("RPG Maker MV/MZ");
    if (!canPause()) D.notice("pause-unavailable", "Scene pause is not available in this runtime.", "此运行时无法暂停场景。");
    D.register({
      fields: fields,
      actions: actions,
      snapshot: snapshotState,
      restore: restoreState,
      diagnostics: function () {
        return { map: mapName($gameMap.mapId()), actors: String(members().length), paused: String(gamePaused()) };
      }
    });
  }

  boot();
})();
