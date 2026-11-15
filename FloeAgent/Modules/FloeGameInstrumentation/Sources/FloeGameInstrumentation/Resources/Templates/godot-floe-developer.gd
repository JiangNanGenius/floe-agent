# SPDX-License-Identifier: MPL-2.0
# Godot 4 Web export push bridge. Add as an autoload in the project revision.
extends Node

var _ready_sent := false

func _has_host() -> bool:
	if not OS.has_feature("web"):
		return false
	return bool(JavaScriptBridge.eval("typeof window !== 'undefined' && !!window.FloeDeveloper && typeof window.FloeDeveloper.registerPushed === 'function' && typeof window.FloeDeveloper.takeCommands === 'function'"))

func _ready() -> void:
	set_process(false)
	if not _has_host():
		return
	# A host-enabled autoload must consume Resume even while the tree is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_register()
	set_process(true)

func _register() -> void:
	var script := """
		(function(){
		  var D = window.FloeDeveloper; if (!D) return;
		  D.registerPushed({
		    runtime: 'Godot Web export',
		    fields: [
		      { id: 'scene.name', label: 'Scene', labelZhHans: '场景', group: 'Godot', groupZhHans: 'Godot', kind: 'readOnlyText', symbol: 'square.stack' },
		      { id: 'engine.paused', label: 'Paused', labelZhHans: '已暂停', group: 'Godot', groupZhHans: 'Godot', kind: 'readOnlyBoolean', symbol: 'pause' },
		      { id: 'engine.timescale', label: 'Time scale', labelZhHans: '时间缩放', group: 'Godot', groupZhHans: 'Godot', kind: 'number', symbol: 'gauge.with.dots.needle.67percent', minimum: 0.05, maximum: 4, step: 0.05 },
		      { id: 'engine.frames', label: 'Frames', labelZhHans: '帧数', group: 'Godot', groupZhHans: 'Godot', kind: 'readOnlyNumber', symbol: 'film' }
		    ],
		    actions: [
		      { id: 'engine.pause', label: 'Pause', labelZhHans: '暂停', group: 'Godot', groupZhHans: 'Godot', symbol: 'pause.fill', isQuick: true },
		      { id: 'engine.resume', label: 'Resume', labelZhHans: '继续', group: 'Godot', groupZhHans: 'Godot', symbol: 'play.fill', isQuick: true }
		    ]
		  });
		})();
	"""
	JavaScriptBridge.eval(script)

func _process(_delta: float) -> void:
	if not _has_host():
		set_process(false)
		return
	var current := get_tree().current_scene
	var values := {
		"scene.name": current.name if current != null else "—",
		"engine.paused": get_tree().paused,
		"engine.timescale": Engine.time_scale,
		"engine.frames": Engine.get_process_frames()
	}
	JavaScriptBridge.eval("window.FloeDeveloper && window.FloeDeveloper.updatePushed(" + JSON.stringify(values) + ");")
	var command_text = JavaScriptBridge.eval("JSON.stringify(window.FloeDeveloper ? window.FloeDeveloper.takeCommands() : [])")
	var commands = JSON.parse_string(str(command_text))
	if commands == null:
		return
	for command in commands:
		var id := int(command.get("id", 0))
		var applied := false
		if command.get("kind", "") == "set" and command.get("field", "") == "engine.timescale":
			Engine.time_scale = float(command.get("value", 1.0))
			applied = true
		elif command.get("kind", "") == "action" and command.get("action", "") == "engine.pause":
			get_tree().paused = true
			applied = true
		elif command.get("kind", "") == "action" and command.get("action", "") == "engine.resume":
			get_tree().paused = false
			applied = true
		JavaScriptBridge.eval("window.FloeDeveloper && window.FloeDeveloper.ackCommand(" + str(id) + ",{ok:" + ("true" if applied else "false") + "});")
