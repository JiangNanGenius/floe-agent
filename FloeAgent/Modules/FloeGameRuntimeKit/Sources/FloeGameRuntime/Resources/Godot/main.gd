# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Floe contributors. See licenses/FLOE-STARTER-MIT.txt.
extends Node2D

var state: Dictionary = {"engine": "godot", "x": 80.0, "y": 200.0, "score": 0, "frames": 0}
var config: Dictionary = {}
var keys: Dictionary = {"left": false, "right": false, "up": false, "down": false}
var bridge = null
var input_callback = null
var restore_callback = null
var pointer_callback = null
var goal = null

func _ready() -> void:
    state["engineVersion"] = Engine.get_version_info().get("string", "unknown")
    var file = FileAccess.open("res://game.json", FileAccess.READ)
    if file:
        var parsed = JSON.parse_string(file.get_as_text())
        if parsed is Dictionary:
            config = parsed
    if OS.has_feature("web"):
        bridge = JavaScriptBridge.get_interface("FloeGodot")
        input_callback = JavaScriptBridge.create_callback(_on_host_input)
        restore_callback = JavaScriptBridge.create_callback(_on_host_restore)
        pointer_callback = JavaScriptBridge.create_callback(_on_host_pointer)
        bridge.inputCallback = input_callback
        bridge.restoreCallback = restore_callback
        bridge.pointerCallback = pointer_callback
        _publish()

func _on_host_input(args: Array) -> void:
    if args.size() == 2 and keys.has(str(args[0])):
        keys[str(args[0])] = bool(args[1])
        goal = null

func _on_host_restore(args: Array) -> void:
    if args.size() != 1:
        return
    var saved = JSON.parse_string(str(args[0]))
    if not saved is Dictionary or saved.get("engine") != "godot" or saved.get("engineVersion") != state["engineVersion"]:
        return
    state["x"] = clampf(float(saved.get("x", 80)), 16, 784)
    state["y"] = clampf(float(saved.get("y", 200)), 16, 464)
    state["score"] = clampi(int(saved.get("score", 0)), 0, 3)
    goal = null
    for key in keys:
        keys[key] = false
    _publish()
    queue_redraw()

func _on_host_pointer(args: Array) -> void:
    if args.size() == 2:
        goal = Vector2(clampf(float(args[0]), 0, 1) * 800, clampf(float(args[1]), 0, 1) * 480)

func _publish() -> void:
    if bridge:
        bridge.update(JSON.stringify(state))

func _process(delta: float) -> void:
    state["frames"] += 1
    var direction = Vector2(float(keys["right"] or Input.is_physical_key_pressed(KEY_RIGHT)) - float(keys["left"] or Input.is_physical_key_pressed(KEY_LEFT)), float(keys["down"] or Input.is_physical_key_pressed(KEY_DOWN)) - float(keys["up"] or Input.is_physical_key_pressed(KEY_UP)))
    var position = Vector2(float(state["x"]), float(state["y"]))
    if goal != null:
        direction = (goal - position).normalized() if position.distance_to(goal) > 4 else Vector2.ZERO
    position += direction.normalized() * clampf(float(config.get("speed", 180)), 20, 600) * minf(delta, 0.05)
    state["x"] = clampf(position.x, 16, 784)
    state["y"] = clampf(position.y, 16, 464)
    var coins = [160.0, 300.0, 440.0]
    if int(state["score"]) < 3 and position.distance_to(Vector2(coins[int(state["score"])], 200)) < 24:
        state["score"] += 1
    $Score.text = str(config.get("title", "Floe Godot")) + " · " + str(state["score"]) + " / 3"
    _publish()
    queue_redraw()

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseButton and event.pressed:
        goal = event.position
    if event is InputEventScreenTouch and event.pressed:
        goal = event.position

func _draw() -> void:
    for y in range(0, 480, 64):
        for x in range(0, 800, 64):
            draw_rect(Rect2(x + 2, y + 2, 60, 60), Color("315f48"))
    draw_rect(Rect2(550, 80, 170, 120), Color("976c43"))
    var coins = [160, 300, 440]
    for index in range(int(state["score"]), 3):
        draw_circle(Vector2(coins[index], 200), 9, Color("ffcf55"))
    draw_circle(Vector2(float(state["x"]), float(state["y"])), 14, Color("8ed6ff"))
