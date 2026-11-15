# Floe GDevelop / Cocos Creator project hooks — source notice

SPDX-License-Identifier: MPL-2.0

This directory contains the source form of the Floe developer helpers installed
into GDevelop and Cocos Creator 3.8 projects by `FloeGameInstrumentation`.

- Origin: Floe Agent predevelopment SDK.
- Frozen source revision: `3763b5ce836c0fb7b980b02a2becaa5c6234100f`.
- GDevelop bridge: `Project/gdevelop-floe-developer.js`, byte-identical to the
  reviewed `FloeGameGDevelopKit` export bridge resource.
- Cocos Creator component: `Project/cocos-floe-developer.ts`.
- License: Mozilla Public License 2.0. The complete license is `LICENSE`.

The GDevelop file is installed in a project revision as provenance and is also
stamped byte-for-byte into a private exported playable copy by the reviewed
exporter. A source project JSON or an imported playable export is never edited
in place. The Cocos component and its generated `.meta` are installed through the
existing project repository CAS; an explicit scene is patched with a
byte-preserving insertion.

These helpers are development instrumentation, not game content. They are inert
unless the Floe host injects `window.FloeDeveloper` for a Floe-owned development
session. A normal exported game has no developer menu, HUD, polling loop or
player-reachable command surface.

The surrounding game project, imported code/assets and engine binaries remain
under their own licenses. Cocos Creator and GDevelop retain their own terms; no
legal clearance is claimed by this notice.

中文说明：本目录是 Floe 为 GDevelop 与 Cocos Creator 3.8 工程安装的开发辅助源码，
采用 MPL-2.0。GDevelop 辅助文件仅作为工程来源记录，并由审核过的导出器逐字节写入私有
试玩副本；不会原地修改工程 JSON 或导入的导出。Cocos 组件及其生成的 `.meta` 通过现有
工程仓库 CAS 安装，场景以保留字节的插入方式修改。辅助代码仅在 Floe 宿主注入
`window.FloeDeveloper` 时生效；普通导出没有开发者菜单、轮询或作弊入口。
