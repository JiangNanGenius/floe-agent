#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Generate original, standard-format RPG Maker XP/VX/VX Ace starter projects.

The generated project data uses real Ruby Marshal 4.8 streams, standard
Data/Map###.<ext>, database, System and Scripts archive layouts, and original
synthetic PNG assets. No RPG Maker RTP, Enterbrain scripts, DLLs or sample art
is produced or copied. The script archive contains only original Floe starter
Ruby code using documented RGSS low-level APIs.
"""

from __future__ import annotations

import hashlib
import json
import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import marshal_codec as m  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Sources" / "FloeGameStarterKit" / "Resources" / "Templates"

STARTER_ENGINE_VERSION = "1.0.0"
MIT_TEXT = """MIT License

Copyright (c) 2026 Floe contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""

ENGINE_NOTES = """# Engine prerequisite

This project is an original Floe starter in the standard {engine} project
format. It does not contain the RPG Maker editor, the RGSS runtime, any
Enterbrain default scripts, RTP data, DLLs, fonts or commercial sample art.

To open and edit the project, the user must supply a licensed RPG Maker
{editor} installation. To play it, the user must supply an RGSS-compatible
runtime for {engine}. The original starter Ruby source and project data in this
folder are licensed MIT; the engine/editor and any imported assets retain their
own terms.
"""


def s(text: str) -> m.RString:
    return m.RString(text.encode("utf-8"), "utf8")


def b(data: bytes) -> m.RString:
    return m.RString(data, "binary")


def obj(name: str, **ivars):
    return m.RObject(name, list(ivars.items()))


def cmd(code: int, params: list):
    return obj("RPG::EventCommand", **{"@code": code, "@indent": 0, "@parameters": params})


def audio(name: str = "") -> m.RObject:
    return obj("RPG::AudioFile", **{"@name": s(name), "@volume": 100, "@pitch": 100})


def table(x: int, y: int, z: int, values: list[int], dimensions: int = 3) -> m.RTable:
    return m.RTable(dimensions, x, y, z, values)


def table_1d(length: int, values: list[int]) -> m.RTable:
    return m.RTable(1, length, 1, 1, values)


def table_2d(x: int, y: int, values: list[int]) -> m.RTable:
    return m.RTable(2, x, y, 1, values)


def png(width: int, height: int, pixel) -> bytes:
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw.extend(pixel(x, y))
    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))
    header = struct.pack(">2I5B", width, height, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def color_tile(x: int, y: int, size: int, index: int) -> bytes:
    tx, ty = x // size, y // size
    px, py = x % size, y % size
    palettes = [
        (36, 74, 59), (48, 96, 70), (72, 112, 80), (94, 76, 56),
        (128, 96, 62), (55, 88, 108), (84, 120, 140), (150, 154, 116),
    ]
    r, g, bl = palettes[(tx + ty * 3 + index) % len(palettes)]
    edge = px == 0 or py == 0 or px == size - 1 or py == size - 1
    if edge:
        r, g, bl = max(0, r - 22), max(0, g - 22), max(0, bl - 18)
    if (tx * 7 + ty * 11 + index) % 9 == 0 and size // 4 <= px <= size // 2 and size // 3 <= py <= size // 2:
        r, g, bl = min(255, r + 40), min(255, g + 28), min(255, bl + 12)
    return bytes((r, g, bl, 255))


def make_tileset_png(path: Path, tile_size: int, rows: int) -> None:
    width, height = tile_size * 8, tile_size * rows
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png(width, height, lambda x, y: color_tile(x, y, tile_size, 0)))


def make_hero(path: Path, tile_size: int, columns: int) -> None:
    width, height = tile_size * columns, tile_size * 4
    def pixel(x: int, y: int) -> bytes:
        cx, cy = x % tile_size, y % tile_size
        center = tile_size / 2
        dx, dy = cx - center, cy - center
        if dx * dx + dy * dy <= (tile_size * 0.36) ** 2:
            return (142, 214, 255, 255)
        if abs(dx) <= 2 and cy > tile_size * 0.6:
            return (32, 64, 82, 255)
        return (0, 0, 0, 0)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png(width, height, pixel))


def make_ui(path: Path, width: int, height: int, title: str = "") -> None:
    def pixel(x: int, y: int) -> bytes:
        border = 8
        if x < border or y < border or x >= width - border or y >= height - border:
            return (200, 184, 126, 255)
        if x < border + 2 or y < border + 2 or x >= width - border - 2 or y >= height - border - 2:
            return (44, 58, 52, 255)
        return (24, 38, 34, 255)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png(width, height, pixel))


def make_map(base: int, width: int, height: int, tile_size: int) -> m.RTable:
    values = [0] * (width * height * 3)
    for y in range(height):
        for x in range(width):
            edge = x in (0, width - 1) or y in (0, height - 1)
            tile = base + ((x * 3 + y * 5) % 24 if not edge else 0)
            values[(0 * height + y) * width + x] = tile
            values[(1 * height + y) * width + x] = base + 24 + ((x + y) % 8)
            values[(2 * height + y) * width + x] = 0
    return table(width, height, 3, values)


def event_condition() -> m.RObject:
    return obj("RPG::Event::Page::Condition",
               **{"@switch1_valid": False, "@switch2_valid": False,
                  "@variable_valid": False, "@self_switch_valid": False,
                  "@switch1_id": 1, "@switch2_id": 1, "@variable_id": 1,
                  "@variable_value": 0, "@self_switch_ch": s("A")})


def event_graphic() -> m.RObject:
    return obj("RPG::Event::Page::Graphic",
               **{"@character_name": s("FloeHero"), "@character_index": 0,
                  "@direction": 2, "@pattern": 1, "@tile_id": 0})


def move_route() -> m.RObject:
    return obj("RPG::MoveRoute",
               **{"@list": [obj("RPG::MoveCommand", **{"@code": 0, "@parameters": []})],
                  "@repeat": True, "@skippable": False, "@wait": False})


def event_page(text: str) -> m.RObject:
    return obj("RPG::Event::Page",
               **{"@condition": event_condition(), "@graphic": event_graphic(),
                  "@type": 0, "@span": 0, "@move_route": move_route(),
                  "@through": False, "@always_on_top": False,
                  "@move_type": 0, "@move_speed": 3, "@move_frequency": 3,
                  "@walk_anime": True, "@step_anime": False,
                  "@direction_fix": False, "@priority_type": 1, "@trigger": 0,
                  "@list": [cmd(101, [s(""), 0, 0, 2]), cmd(401, [s(text)]), cmd(0, [])]})


def make_event(event_id: int, name: str, x: int, y: int, text: str) -> m.RObject:
    return obj("RPG::Event", **{"@id": event_id, "@name": s(name), "@x": x, "@y": y,
                                "@pages": [event_page(text)]})


def make_map_document(ext: str, base: int, width: int, height: int, tile_size: int) -> bytes:
    events = m.RHash([
        (1, make_event(1, "Ferry Keeper", 4, 3,
                       "The tide is turning. Rest at the quay before you cross.")),
        (2, make_event(2, "Notice Stone", 8, 6,
                       "Glimmerfen ferry: one rope coil for a safe crossing.")),
    ])
    return m.dump(obj("RPG::Map",
                      **{"@tileset_id": 1, "@width": width, "@height": height,
                         "@autoplay_bgm": False, "@bgm": audio(), "@autoplay_bgs": False,
                         "@bgs": audio(), "@encounter_list": [], "@encounter_step": 30,
                         "@data": make_map(base, width, height, tile_size),
                         "@events": events, "@scroll_type": 0}))


def actor_parameters() -> m.RTable:
    values: list[int] = []
    for level in range(100):
        values.extend([45 + level, 18 + level // 2, 9 + level // 4,
                       7 + level // 4, 6 + level // 3, 5 + level // 3])
    return m.RTable(1, 6, 100, 1, values)


def make_actor(engine: str) -> bytes:
    actor = obj("RPG::Actor",
                **{"@id": 1, "@name": s("Kestrel"), "@class_id": 1,
                   "@initial_level": 1, "@final_level": 99, "@max_level": 99,
                   "@exp_basis": 30, "@exp_inflation": 30,
                   "@character_name": s("FloeHero"), "@character_index": 0,
                   "@character_hue": 0, "@battler_name": s(""), "@battler_hue": 0,
                   "@face_name": s(""), "@face_index": 0,
                   "@parameters": actor_parameters(),
                   "@weapon_id": 1, "@armor1_id": 1, "@armor2_id": 0,
                   "@armor3_id": 0, "@armor4_id": 0, "@weapon_fix": False,
                   "@armor1_fix": False, "@armor2_fix": False, "@armor3_fix": False,
                   "@armor4_fix": False, "@nickname": s("Quay Warden"),
                   "@profile": s("A courier who maps the fenland crossings."),
                   "@note": s("Original Floe starter actor."),
                   "@features": [], "@equips": [1, 0, 0, 0, 0]})
    return m.dump([None, actor])


def make_class() -> bytes:
    params = m.RTable(2, 8, 100, 1, [10 + i for i in range(800)])
    learning = obj("RPG::Class::Learning", **{"@level": 1, "@skill_id": 1, "@note": s("")})
    klass = obj("RPG::Class",
                **{"@id": 1, "@name": s("Wayfarer"), "@position": 0,
                   "@weapon_set": [1], "@armor_set": [1],
                   "@element_ranks": table_1d(16, [1] * 16),
                   "@state_ranks": table_1d(16, [1] * 16),
                   "@exp_params": [30, 20, 30, 30],
                   "@params": params, "@learnings": [learning],
                   "@traits": [], "@note": s("Original Floe starter class.")})
    return m.dump([None, klass])


def make_skill() -> bytes:
    skill = obj("RPG::Skill",
                **{"@id": 1, "@name": s("Tide Step"), "@icon_index": 1,
                   "@description": s("A steady step over wet stone."),
                   "@scope": 0, "@occasion": 0, "@mp_cost": 0, "@tp_cost": 0,
                   "@hit": 100, "@animation_id": 1, "@damage": obj("RPG::UsableItem::Damage",
                       **{"@type": 0, "@element_id": 0, "@formula": s("0"),
                          "@variance": 0, "@critical": False}), "@effects": [],
                   "@note": s("Original Floe starter skill.")})
    return m.dump([None, skill])


def make_item() -> bytes:
    item = obj("RPG::Item",
               **{"@id": 1, "@name": s("Rope Coil"), "@icon_index": 2,
                  "@description": s("Sturdy hemp rope for the ferry."),
                  "@price": 12, "@consumable": True, "@scope": 0, "@occasion": 0,
                  "@animation_id": 0, "@damage": obj("RPG::UsableItem::Damage",
                      **{"@type": 0, "@element_id": 0, "@formula": s("0"),
                         "@variance": 0, "@critical": False}), "@effects": [],
                  "@note": s("Original Floe starter item.")})
    return m.dump([None, item])


def make_weapon() -> bytes:
    weapon = obj("RPG::Weapon",
                 **{"@id": 1, "@name": s("Ferry Hook"), "@icon_index": 3,
                    "@description": s("A balanced hook for pulling lines."),
                    "@price": 40, "@wtype_id": 1, "@atk": 8, "@def": 0,
                    "@note": s("Original Floe starter weapon.")})
    return m.dump([None, weapon])


def make_armor() -> bytes:
    armor = obj("RPG::Armor",
                **{"@id": 1, "@name": s("Oilskin"), "@icon_index": 4,
                   "@description": s("Keeps the fen rain out."), "@price": 30,
                   "@atype_id": 1, "@etype_id": 0, "@def": 4,
                   "@note": s("Original Floe starter armor.")})
    return m.dump([None, armor])


def make_enemy() -> bytes:
    enemy = obj("RPG::Enemy",
                **{"@id": 1, "@name": s("Marsh Wisp"), "@battler_name": s(""),
                   "@battler_hue": 0, "@maxhp": 120, "@maxmp": 30,
                   "@atk": 25, "@def": 12, "@spi": 8, "@agi": 15,
                   "@hit": 95, "@eva": 5, "@exp": 15, "@gold": 8,
                   "@drop_items": [], "@actions": [], "@note": s("Original Floe starter enemy.")})
    return m.dump([None, enemy])


def make_troop() -> bytes:
    troop = obj("RPG::Troop",
                **{"@id": 1, "@name": s("Quay Watch"),
                   "@members": [obj("RPG::Troop::Member", **{"@enemy_id": 1, "@x": 0, "@y": 0, "@hidden": False})],
                   "@pages": [], "@note": s("Original Floe starter troop.")})
    return m.dump([None, troop])


def make_state() -> bytes:
    state = obj("RPG::State",
                **{"@id": 1, "@name": s("Mired"), "@icon_index": 5,
                   "@restriction": 0, "@priority": 50,
                   "@message1": s(" sinks into the mud."), "@message2": s(""),
                   "@message3": s(""), "@message4": s(" shakes it off."),
                   "@note": s("Original Floe starter state.")})
    return m.dump([None, state])


def make_animation() -> bytes:
    anim = obj("RPG::Animation",
               **{"@id": 1, "@name": s("Tide Step"), "@animation1_name": s(""),
                  "@animation2_name": s(""), "@position": 1, "@frame_max": 4,
                  "@frames": [], "@timings": [], "@note": s("Original Floe starter animation.")})
    return m.dump([None, anim])


def make_tileset(engine: str) -> bytes:
    if engine == "xp":
        tileset = obj("RPG::Tileset",
                      **{"@id": 1, "@name": s("Glimmerfen Tiles"),
                         "@tileset_name": s("FloeTiles"),
                         "@autotile_names": [s("FloeAuto%d" % i) for i in range(1, 8)],
                         "@panorama_name": s(""), "@fog_name": s(""),
                         "@battleback_name": s(""),
                         "@passages": table_1d(384, [0] * 384),
                         "@priorities": table_1d(384, [0] * 384),
                         "@terrain_tags": table_1d(384, [0] * 384)})
    else:
        tileset = obj("RPG::Tileset",
                      **{"@id": 1, "@mode": 0, "@name": s("Glimmerfen Tiles"),
                         "@tileset_names": [s(""), s(""), s(""), s(""), s(""),
                                            s("FloeTiles"), s(""), s(""), s("")],
                         "@note": s("Original Floe synthetic starter tileset. No RTP content.")})
    return m.dump([None, tileset])


def make_system(engine: str) -> bytes:
    terms = obj("RPG::System::Terms",
                **{"@basic": [s("Level"), s("HP"), s("MP")],
                   "@params": [s("Attack"), s("Defense"), s("Spirit"), s("Agility")],
                   "@etypes": [s("")] * 5})
    system = obj("RPG::System",
                 **{"@magic_number": 123456, "@party_members": [1],
                    "@elements": [None, s("Fire"), s("Ice"), s("Spark")],
                    "@switches": [None, s("ferry_available")] + [None] * 19,
                    "@variables": [None, s("rope_count")] + [None] * 19,
                    "@windowskin_name": s("FloeSkin"), "@title_name": s("FloeTitle"),
                    "@gameover_name": s("FloeGameOver"), "@battle_transition": s("fade"),
                    "@title_bgm": audio(), "@battle_bgm": audio(),
                    "@battle_end_me": audio(), "@gameover_me": audio(),
                    "@cursor_se": audio(), "@decision_se": audio(), "@cancel_se": audio(),
                    "@buzzer_se": audio(), "@equip_se": audio(), "@shop_se": audio(),
                    "@save_se": audio(), "@load_se": audio(), "@battle_start_se": audio(),
                    "@escape_se": audio(), "@actor_collapse_se": audio(),
                    "@enemy_collapse_se": audio(),
                    "@words": m.RHash([(s("gold"), s("Glimmer")), (s("hp"), s("Stamina")),
                                       (s("sp"), s("Focus"))]),
                    "@test_battlers": [], "@test_troop_id": 1,
                    "@start_map_id": 1, "@start_x": 2, "@start_y": 2,
                    "@edit_map_id": 1, "@game_title": s("Glimmerfen"),
                    "@version_id": 1, "@currency_unit": s("Glimmer"),
                    "@terms": terms, "@sounds": [], "@advanced": m.RHash([]),
                    "@title1_name": s("FloeTitle"), "@title2_name": s(""),
                    "@title_bgm": audio(), "@battle_bgm": audio()})
    return m.dump(system)


def make_map_infos() -> bytes:
    info = obj("RPG::MapInfo",
               **{"@id": 1, "@name": s("Bracken Quay"), "@parent_id": 0,
                  "@order": 1, "@expanded": False, "@scroll_x": 0, "@scroll_y": 0})
    return m.dump([None, info])


def make_common_events() -> bytes:
    event = obj("RPG::CommonEvent",
                **{"@id": 1, "@name": s("Ferry Fare"), "@trigger": 0,
                   "@switch_id": 1,
                   "@list": [cmd(101, [s(""), 0, 0, 2]),
                             cmd(401, [s("One rope coil, one crossing.")]), cmd(0, [])]})
    return m.dump([None, event])


def starter_script(engine: str) -> str:
    ext = {"xp": "rxdata", "vx": "rvdata", "ace": "rvdata2"}[engine]
    tileset_path = ("Graphics/Tilesets/FloeTiles" if engine == "xp"
                    else "Graphics/System/FloeTiles")
    tile = 32
    base = 384 if engine == "xp" else 1
    screen = (640, 480) if engine == "xp" else (544, 416)
    library = {"xp": "RGSS1", "vx": "RGSS2", "ace": "RGSS3"}[engine]
    return """# encoding: utf-8
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Floe contributors. See licenses/FLOE-STARTER-MIT.txt.
#
# Original, self-contained Floe starter for __ENGINE__. It uses only documented
# __LIBRARY__ low-level classes. No commercial default scripts, RTP, DLLs or
# sample commercial art are included or required by this file.

module FloeStarter
  TITLE = "Glimmerfen"
  SAVE_FILE = "Save01.__EXT__"
  TILE = __TILE__
  TILE_BASE = __BASE__
  SCREEN_W = __SCREEN_W__
  SCREEN_H = __SCREEN_H__
  SAVE_VERSION = 1
end

# Minimal shells for the standard RPG Maker map objects we load. Marshal.load
# needs these class names; unknown fields remain preserved on the loaded data.
module RPG
  class Map
    attr_accessor :tileset_id, :width, :height, :data, :events
  end
  class Tileset
    attr_accessor :id, :name, :tileset_name, :autotile_names, :tileset_names, :mode
  end
  class Event
    attr_accessor :id, :name, :x, :y, :pages
    class Page
      attr_accessor :condition, :graphic, :list, :trigger
      class Condition
        attr_accessor :switch1_valid, :switch2_valid, :variable_valid,
                      :self_switch_valid, :switch1_id, :switch2_id,
                      :variable_id, :variable_value, :self_switch_ch
      end
      class Graphic
        attr_accessor :character_name, :character_index, :direction, :pattern, :tile_id
      end
    end
  end
  class EventCommand
    attr_accessor :code, :indent, :parameters
  end
  class MoveRoute
    attr_accessor :list, :repeat, :skippable, :wait
  end
  class MoveCommand
    attr_accessor :code, :parameters
  end
end

class FloeStarterScene
  def read_binary(path)
    File.open(path, "rb") { |file| file.read }
  end

  def write_binary(path, data)
    File.open(path, "wb") { |file| file.write(data) }
  end

  def initialize
    @map = Marshal.load(read_binary("Data/Map001.__EXT__"))
    @tiles = Bitmap.new("__TILESET__")
    @player_x = 2
    @player_y = 2
    @steps = 0
    @score = 0
    @menu = false
    @menu_index = 0
    @message = nil
    @message_frames = 0
    @map_bitmap = build_map_bitmap
    @map_sprite = Sprite.new
    @map_sprite.bitmap = @map_bitmap
    @player = Sprite.new
    @player.bitmap = build_player_bitmap
    @player.z = 10
    @hud = Sprite.new
    @hud.bitmap = Bitmap.new(FloeStarter::SCREEN_W, 52)
    @hud.z = 20
    @menu_sprite = Sprite.new
    @menu_sprite.bitmap = Bitmap.new(250, 150)
    @menu_sprite.z = 30
    @menu_sprite.visible = false
    @message_sprite = Sprite.new
    @message_sprite.bitmap = Bitmap.new(FloeStarter::SCREEN_W, 92)
    @message_sprite.y = FloeStarter::SCREEN_H - 92
    @message_sprite.z = 25
    @message_sprite.visible = false
    refresh
  end

  def build_map_bitmap
    width = @map.width * FloeStarter::TILE
    height = @map.height * FloeStarter::TILE
    bitmap = Bitmap.new(width, height)
    bitmap.fill_rect(Rect.new(0, 0, width, height), Color.new(18, 30, 27, 255))
    for y in 0...@map.height
      for x in 0...@map.width
        tile = ((@map.data && @map.data[x, y, 0]) || 0) - FloeStarter::TILE_BASE
        next if tile < 0
        sx = (tile % 8) * FloeStarter::TILE
        sy = (tile / 8) * FloeStarter::TILE
        bitmap.blt(x * FloeStarter::TILE, y * FloeStarter::TILE, @tiles,
                   Rect.new(sx, sy, FloeStarter::TILE, FloeStarter::TILE))
      end
    end
    bitmap
  end

  def build_player_bitmap
    bitmap = Bitmap.new(24, 24)
    bitmap.fill_rect(Rect.new(2, 2, 20, 20), Color.new(142, 214, 255, 255))
    bitmap.fill_rect(Rect.new(6, 8, 4, 5), Color.new(28, 52, 68, 255))
    bitmap.fill_rect(Rect.new(14, 8, 4, 5), Color.new(28, 52, 68, 255))
    bitmap
  end

  def refresh
    @hud.bitmap.clear
    @hud.bitmap.fill_rect(Rect.new(0, 0, FloeStarter::SCREEN_W, 52),
                          Color.new(12, 24, 22, 220))
    @hud.bitmap.font.size = 20
    @hud.bitmap.font.color = Color.new(235, 238, 218, 255)
    @hud.bitmap.draw_text(12, 12, 330, 28,
      "Glimmerfen  steps " + @steps.to_s + "  rope " + @score.to_s)
    @hud.bitmap.draw_text(FloeStarter::SCREEN_W - 230, 12, 220, 28,
      "C talk   B menu")
    @player.x = @player_x * FloeStarter::TILE + 4
    @player.y = @player_y * FloeStarter::TILE + 4
    if @menu
      @menu_sprite.visible = true
      @menu_sprite.bitmap.clear
      @menu_sprite.bitmap.fill_rect(Rect.new(0, 0, 250, 150),
                                    Color.new(20, 34, 30, 245))
      @menu_sprite.bitmap.font.size = 20
      @menu_sprite.bitmap.font.color = Color.new(240, 232, 196, 255)
      ["Resume", "Save", "Load"].each_with_index do |item, index|
        color = index == @menu_index ? Color.new(255, 207, 85, 255) : Color.new(230, 230, 220, 255)
        @menu_sprite.bitmap.font.color = color
        @menu_sprite.bitmap.draw_text(20, 16 + index * 36, 210, 30, item)
      end
    else
      @menu_sprite.visible = false
    end
    if @message
      @message_sprite.visible = true
      @message_sprite.bitmap.clear
      @message_sprite.bitmap.fill_rect(Rect.new(0, 0, FloeStarter::SCREEN_W, 92),
                                       Color.new(18, 30, 27, 235))
      @message_sprite.bitmap.font.size = 19
      @message_sprite.bitmap.font.color = Color.new(245, 240, 210, 255)
      @message_sprite.bitmap.draw_text(18, 16, FloeStarter::SCREEN_W - 36, 60, @message)
    else
      @message_sprite.visible = false
    end
  end

  def passable?(x, y)
    x >= 0 && y >= 0 && x < @map.width && y < @map.height
  end

  def try_move(dx, dy)
    nx, ny = @player_x + dx, @player_y + dy
    return unless passable?(nx, ny)
    @player_x, @player_y = nx, ny
    @steps += 1
    if @player_x == 8 && @player_y == 6 && @score == 0
      @score = 1
      say("You pocket a coil of rope from the notice stone.")
    end
    refresh
  end

  def say(text)
    @message = text
    @message_frames = 180
    refresh
  end

  def near_event
    (@map.events || {}).each_value do |event|
      next unless event
      return event if (event.x - @player_x).abs + (event.y - @player_y).abs <= 1
    end
    nil
  end

  def interact
    event = near_event
    unless event
      say("The fen is quiet. The ferry waits to the east.")
      return
    end
    page = event.pages && event.pages[0]
    lines = []
    if page && page.list
      page.list.each do |command|
        if command.code == 401 && command.parameters && command.parameters[0]
          lines << command.parameters[0].to_s
        end
      end
    end
    say(lines.empty? ? "The quay keeps its own counsel." : lines.join(" "))
  end

  def save_game
    data = { "version" => FloeStarter::SAVE_VERSION, "x" => @player_x,
             "y" => @player_y, "steps" => @steps, "score" => @score }
    write_binary(FloeStarter::SAVE_FILE, Marshal.dump(data))
    say("Saved to " + FloeStarter::SAVE_FILE + ".")
  end

  def load_game
    unless File.exist?(FloeStarter::SAVE_FILE)
      say("No save file yet.")
      return
    end
    begin
      data = Marshal.load(read_binary(FloeStarter::SAVE_FILE))
      if data.is_a?(Hash) && data["version"] == FloeStarter::SAVE_VERSION &&
         data["x"].is_a?(Integer) && data["y"].is_a?(Integer)
        @player_x = [[data["x"], 0].max, @map.width - 1].min
        @player_y = [[data["y"], 0].max, @map.height - 1].min
        @steps = data["steps"].is_a?(Integer) ? data["steps"] : @steps
        @score = data["score"].is_a?(Integer) ? data["score"] : @score
        say("Loaded from " + FloeStarter::SAVE_FILE + ".")
      else
        say("That save is not compatible with this starter.")
      end
    rescue StandardError
      say("The save could not be read.")
    end
  end

  def update
    if @message_frames > 0
      @message_frames -= 1
      if @message_frames == 0
        @message = nil
        refresh
      end
    end
    if @menu
      if Input.trigger?(Input::UP)
        @menu_index = (@menu_index - 1) % 3
        refresh
      elsif Input.trigger?(Input::DOWN)
        @menu_index = (@menu_index + 1) % 3
        refresh
      elsif Input.trigger?(Input::C)
        case @menu_index
        when 1 then save_game
        when 2 then load_game
        end
        @menu = false
        refresh
      elsif Input.trigger?(Input::B)
        @menu = false
        refresh
      end
      return
    end
    if Input.trigger?(Input::B)
      @menu = true
      @menu_index = 0
      refresh
    elsif Input.trigger?(Input::C)
      interact
    else
      dash = Input.press?(Input::A) ? 2 : 1
      if Input.press?(Input::LEFT)
        dash.times { try_move(-1, 0) }
      elsif Input.press?(Input::RIGHT)
        dash.times { try_move(1, 0) }
      elsif Input.press?(Input::UP)
        dash.times { try_move(0, -1) }
      elsif Input.press?(Input::DOWN)
        dash.times { try_move(0, 1) }
      end
    end
  end
end

Graphics.frame_rate = 60
scene = FloeStarterScene.new
loop do
  Input.update
  scene.update
  Graphics.update
end
""".replace("__EXT__", ext).replace("__TILE__", str(tile)).replace("__BASE__", str(base)).replace("__SCREEN_W__", str(screen[0])).replace("__SCREEN_H__", str(screen[1])).replace("__TILESET__", tileset_path).replace("__LIBRARY__", library).replace("__ENGINE__", engine)


def make_scripts(engine: str) -> bytes:
    src = starter_script(engine).encode("utf-8")
    payload = zlib.compress(src, 9)
    return m.dump([[1, s("FloeStarter"), m.RString(payload, "binary")]])


def input_declaration(engine: str) -> dict:
    if engine == "xp":
        buttons = [
            {"id": "confirm", "label": "C (also Enter/Space)", "keys": ["c"]},
            {"id": "cancel", "label": "X (also Esc)", "keys": ["x"]},
            {"id": "actionA", "label": "Shift (also Z)", "keys": ["shift"]},
        ]
    else:
        buttons = [
            {"id": "confirm", "label": "Z (also Enter/Space)", "keys": ["z"]},
            {"id": "cancel", "label": "X (also Esc)", "keys": ["x"]},
            {"id": "actionA", "label": "Shift", "keys": ["shift"]},
            {"id": "pageLeft", "label": "Q", "keys": ["q"]},
            {"id": "pageRight", "label": "W", "keys": ["w"]},
        ]
    return {
        "schemaVersion": 1,
        "engine": {"xp": "rpgMakerXP", "vx": "rpgMakerVX", "ace": "rpgMakerVXAce"}[engine],
        "movement": {"left": ["left"], "right": ["right"],
                     "up": ["up"], "down": ["down"]},
        "buttons": buttons,
    }


def write(path: Path, data: bytes | str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(data, str):
        data = data.encode("utf-8")
    path.write_bytes(data)


def generate(engine: str) -> dict:
    ext = {"xp": "rxdata", "vx": "rvdata", "ace": "rvdata2"}[engine]
    name = {"xp": "rpgMakerXP", "vx": "rpgMakerVX", "ace": "rpgMakerVXAce"}[engine]
    root = OUT / name
    if root.exists():
        import shutil
        shutil.rmtree(root)
    root.mkdir(parents=True)
    library = {"xp": "RGSS100J.dll", "vx": "RGSS200J.dll", "ace": "RGSS300.dll"}[engine]
    title = {"xp": "RPGXP 1.02", "vx": "RPGVX 1.02", "ace": "RPGVXAce 1.00"}[engine]
    marker = {"xp": "Game.rxproj", "vx": "Game.rvproj", "ace": "Game.rvproj2"}[engine]
    tile_size = 32
    width, height = 12, 10
    tile_base = 384 if engine == "xp" else 1
    write(root / "Game.ini", f"[Game]\nLibrary={library}\nScripts=Data\\Scripts.{ext}\nTitle=Glimmerfen\n")
    write(root / marker, title + "\n")
    write(root / "README.md", f"""# Glimmerfen ({engine})

Original Floe starter project in the standard RPG Maker {engine} layout.
The map, database, events and Ruby scripts are original and MIT-licensed.
No RTP, Enterbrain default scripts, DLLs or commercial sample art are bundled.

Open with a licensed RPG Maker {engine} editor, or inspect the standard
Data/*.{ext}, Game.ini and Scripts archive with Floe's RPG adapters. To play,
supply an RGSS-compatible runtime for this engine. See
licenses/ENGINE-NOTES.md and licenses/FLOE-STARTER-MIT.txt.
""")
    write(root / "licenses/FLOE-STARTER-MIT.txt", MIT_TEXT)
    write(root / "licenses/ENGINE-NOTES.md", ENGINE_NOTES.format(
        engine=engine, editor={"xp": "XP", "vx": "VX", "ace": "VX Ace"}[engine]))
    write(root / "floe-inputs.json", json.dumps(input_declaration(engine), indent=2,
                                                ensure_ascii=False) + "\n")
    data_dir = root / "Data"
    write(data_dir / f"Actors.{ext}", make_actor(engine))
    write(data_dir / f"Classes.{ext}", make_class())
    write(data_dir / f"Skills.{ext}", make_skill())
    write(data_dir / f"Items.{ext}", make_item())
    write(data_dir / f"Weapons.{ext}", make_weapon())
    write(data_dir / f"Armors.{ext}", make_armor())
    write(data_dir / f"Enemies.{ext}", make_enemy())
    write(data_dir / f"Troops.{ext}", make_troop())
    write(data_dir / f"States.{ext}", make_state())
    write(data_dir / f"Animations.{ext}", make_animation())
    write(data_dir / f"Tilesets.{ext}", make_tileset(engine))
    write(data_dir / f"CommonEvents.{ext}", make_common_events())
    write(data_dir / f"System.{ext}", make_system(engine))
    write(data_dir / f"MapInfos.{ext}", make_map_infos())
    write(data_dir / f"Map001.{ext}", make_map_document(ext, tile_base, width, height, tile_size))
    write(data_dir / f"Scripts.{ext}", make_scripts(engine))
    graph = root / "Graphics"
    if engine == "xp":
        make_tileset_png(graph / "Tilesets/FloeTiles.png", tile_size, 8)
        make_hero(graph / "Characters/FloeHero.png", tile_size, 4)
        for index in range(1, 8):
            make_tileset_png(graph / f"Autotiles/FloeAuto{index}.png", tile_size // 2, 3)
    else:
        make_tileset_png(graph / "System/FloeTiles.png", tile_size, 16)
        make_hero(graph / "Characters/FloeHero.png", tile_size, 3)
    make_ui(graph / "Windowskins/FloeSkin.png", 192, 192)
    make_ui(graph / "Titles/FloeTitle.png", 640 if engine == "xp" else 544,
            480 if engine == "xp" else 416)
    make_ui(graph / "Titles/FloeGameOver.png", 640 if engine == "xp" else 544,
            480 if engine == "xp" else 416)
    # Validate every Marshal file we just wrote with the same reader.
    files = []
    for path in sorted(root.rglob("*")):
        if path.is_file():
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            files.append({"path": path.relative_to(root).as_posix(), "sha256": digest,
                          "bytes": path.stat().st_size})
            if path.parent.name == "Data" and path.suffix in (".rxdata", ".rvdata", ".rvdata2"):
                m.load(path.read_bytes())
    return {"engine": name, "root": str(root), "files": len(files),
            "bytes": sum(x["bytes"] for x in files), "manifest": files}


def main() -> None:
    results = [generate(engine) for engine in ("xp", "vx", "ace")]
    print(json.dumps({"starters": results}, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
