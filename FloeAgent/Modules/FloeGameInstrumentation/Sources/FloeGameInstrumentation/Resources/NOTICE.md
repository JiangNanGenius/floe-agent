# Floe Game Developer Instrumentation — source notice

SPDX-License-Identifier: MPL-2.0

This directory contains the source form of the Floe developer helper files that
are compiled into a Floe-owned development build of a Unity WebGL or Godot Web
project.

- Origin: `FloeGameDeveloperKit`, part of the Floe Agent predevelopment SDK.
- Frozen source revision: `3763b5ce836c0fb7b980b02a2becaa5c6234100f`.
- Template resources: `Project/unity-floe-developer.jslib`,
  `Project/unity-floe-developer.cs`, `Project/unity-floe-developer-behaviour.cs`,
  `Project/godot-floe-developer.gd`.
- License: Mozilla Public License 2.0. The complete license text is in
  `LICENSE` in this directory.
- Modifications: none. The installed helper sources are byte-identical to the
  reviewed `FloeGameDeveloperKit` templates.

These helpers are development instrumentation, not game content. They are inert
unless the Floe host injects `window.FloeDeveloper` for a Floe-owned development
session. A normal exported game has no developer menu, on-screen control or
player-reachable command surface.

The surrounding game project remains under its own license. No imported game
code, asset, native library or engine binary is relicensed by this notice.

中文说明：本目录是 Floe 开发辅助源码及其 MPL-2.0 许可证。辅助代码仅在 Floe
宿主为开发会话注入 `window.FloeDeveloper` 时生效；普通导出的游戏不包含可用的
开发者菜单或作弊入口。导入的游戏代码、资源和引擎仍遵循其原有许可。

Local MPL-2.0 amendment (2026-11-14): Unity checks the explicit Floe host before creating its automatic MonoBehaviour; Godot disables processing before checking the host, and stops processing after host loss. TEMPLATE-PINS.json records the original and modified file digests. The frozen SDK is not modified by this overlay.
