#!/usr/bin/env ruby
# frozen_string_literal: true
# Fixture generator for FloeRPGProjectKit tests.
#
# Generates REAL Ruby Marshal 4.8 streams and RPG Maker-shaped data files
# using the developer host's Ruby (the format oracle). All game content is
# original to this project — no RTP data, default Enterbrain scripts, or
# proprietary material of any kind is generated.
#
# Usage: ruby generate.rb <output-dir>
require "fileutils"
require "json"
require "zlib"

OUT = File.expand_path(ARGV[0] || "generated")
if File.exist?(File.join(OUT, "generate.rb"))
  raise "refusing to wipe the generator directory itself: #{OUT}"
end

class Table
  attr_reader :dim, :xsize, :ysize, :zsize, :data
  def initialize(dim, xsize, ysize, zsize)
    @dim, @xsize, @ysize, @zsize = dim, xsize, ysize, zsize
    @data = Array.new(xsize * ysize * zsize, 0)
  end
  def [](x, y, z = 0)
    @data[(z * @ysize + y) * @xsize + x]
  end
  def []=(x, y, z, v)
    @data[(z * @ysize + y) * @xsize + x] = v
  end
  def _dump(_level)
    [@dim, @xsize, @ysize, @zsize, @data.size].pack("L5") + @data.pack("s*")
  end
  def self._load(bytes)
    dim, xs, ys, zs, count = bytes[0, 20].unpack("L5")
    table = new(dim, xs, ys, zs)
    table.instance_variable_set(:@data, bytes[20, count * 2].unpack("s*"))
    table
  end
end

class Color
  def initialize(r = 0.0, g = 0.0, b = 0.0, a = 0.0)
    @r, @g, @b, @a = r, g, b, a
  end
  def _dump(_l)
    [@r, @g, @b, @a].pack("D4")
  end
  def self._load(s)
    new(*s.unpack("D4"))
  end
end

class Tone
  def initialize(r = 0.0, g = 0.0, b = 0.0, gr = 0.0)
    @r, @g, @b, @gr = r, g, b, gr
  end
  def _dump(_l)
    [@r, @g, @b, @gr].pack("D4")
  end
  def self._load(s)
    new(*s.unpack("D4"))
  end
end

# Real RPG Maker class shapes (data-only shells; no engine code).
module RPG
  class Actor
    attr_accessor :id, :name, :class_id, :initial_level, :final_level, :exp_basis, :exp_inflation,
                  :character_name, :character_hue, :battler_name, :battler_hue, :parameters,
                  :weapon_id, :armor1_id, :armor2_id, :armor3_id, :armor4_id, :weapon_fix,
                  :armor1_fix, :armor2_fix, :armor3_fix, :armor4_fix
  end
  class Item
    attr_accessor :id, :name, :icon_name, :description, :scope, :occasion, :speed, :animation_id,
                  :common_event_id, :price, :consumable, :parameter_type, :parameter_points, :recover_hp,
                  :recover_mp, :hit, :pdef_f, :mdef_f, :variance, :element_set, :state_set
  end
  class Enemy
    attr_accessor :id, :name, :battler_name, :battler_hue, :maxhp, :maxsp, :str, :dex, :agi, :int,
                  :atk, :pdef, :mdef, :eva, :animation1_id, :animation2_id, :element_ranks, :state_ranks,
                  :actions, :exp, :gold, :item_id, :weapon_id, :armor_id, :treasure_prob
  end
  class State
    attr_accessor :id, :name, :animation_id, :restriction, :nonrestoration_hp, :nonrestoration_sp,
                  :message1, :message2, :message3, :message4, :element_set, :state_set, :plus_state_set,
                  :minus_state_set, :rating, :hit_rate, :maxhp_rate, :maxsp_rate, :str_rate, :dex_rate,
                  :agi_rate, :int_rate, :atk_rate, :pdef_rate, :mdef_rate, :eva, :battle_only,
                  :hold_turn, :auto_release_prob, :shock_release_prob, :guard_element_set, :guard_state_set
  end
  class EventCommand
    attr_accessor :code, :indent, :parameters
    def initialize(code = 0, indent = 0, parameters = [])
      @code, @indent, @parameters = code, indent, parameters
    end
  end
  class Event
    class Page
      attr_accessor :condition, :graphic, :type, :span, :move_route, :through, :always_on_top,
                    :trigger, :list
    end
    attr_accessor :id, :name, :x, :y, :pages
  end
  class Map
    attr_accessor :tileset_id, :width, :height, :autoplay_bgm, :bgm, :autoplay_bgs, :bgs,
                  :encounter_list, :encounter_step, :data, :events, :scroll_type
  end
  class CommonEvent
    attr_accessor :id, :name, :trigger, :switch_id, :list
  end
  class AudioFile
    attr_accessor :name, :volume, :pitch
    def initialize(name = "", volume = 100, pitch = 100)
      @name, @volume, @pitch = name, volume, pitch
    end
  end
  class System
    attr_accessor :magic_number, :party_members, :elements, :switches, :variables, :windowskin_name,
                  :title_name, :gameover_name, :battle_transition, :title_bgm, :battle_bgm, :battle_end_me,
                  :gameover_me, :cursor_se, :decision_se, :cancel_se, :buzzer_se, :equip_se, :shop_se,
                  :save_se, :load_se, :battle_start_se, :escape_se, :actor_collapse_se, :enemy_collapse_se,
                  :words, :test_battlers, :test_troop_id, :start_map_id, :start_x, :start_y, :edit_map_id
  end
end

def xp_actor(id, name, klass, level, params)
  a = RPG::Actor.new
  a.id, a.name, a.class_id, a.initial_level = id, name, klass, level
  a.final_level, a.exp_basis, a.exp_inflation = 99, 30, 30
  a.character_name, a.character_hue = "hero_#{id}", 0
  a.battler_name, a.battler_hue = "hero_#{id}_bt", 0
  t = Table.new(1, 6, 100, 1)
  (0...100).each { |lv| (0...6).each { |i| t[i, lv, 0] = params[lv] ? params[lv][i] : 10 + i + lv } }
  a.parameters = t
  a.weapon_id, a.armor1_id, a.armor2_id, a.armor3_id, a.armor4_id = 0, 0, 0, 0, 0
  a.weapon_fix = a.armor1_fix = a.armor2_fix = a.armor3_fix = a.armor4_fix = false
  a
end

def xp_item(id, name, price, desc)
  i = RPG::Item.new
  i.id, i.name, i.description, i.price = id, name, desc, price
  i.icon_name = "icon_#{id}"
  i.scope, i.occasion, i.speed, i.animation_id = 0, 0, 0, 0
  i.common_event_id = 0
  i.consumable = true
  i.parameter_type = 0
  i.parameter_points = 0
  i.recover_hp = 50
  i.recover_mp = 0
  i.hit = 100
  i.pdef_f, i.mdef_f, i.variance = 0, 0, 0
  i.element_set = []
  i.state_set = []
  i
end

def xp_enemy(id, name)
  e = RPG::Enemy.new
  e.id, e.name = id, name
  e.battler_name, e.battler_hue = "mob_#{id}", 0
  e.maxhp, e.maxsp, e.str, e.dex, e.agi, e.int = 120, 30, 25, 20, 15, 10
  e.atk, e.pdef, e.mdef, e.eva = 30, 12, 8, 5
  e.animation1_id, e.animation2_id = 0, 0
  e.element_ranks = Table.new(1, 1, 1, 1)
  e.state_ranks = Table.new(1, 1, 1, 1)
  e.actions = []
  e.exp, e.gold = 15, 8
  e.item_id, e.weapon_id, e.armor_id, e.treasure_prob = 0, 0, 0, 0
  e
end

def xp_state(id, name)
  s = RPG::State.new
  s.id, s.name = id, name
  s.animation_id = 0
  s.restriction = 0
  s.nonrestoration_hp = s.nonrestoration_sp = false
  s.message1, s.message2 = "%s is afflicted.", ""
  s.message3, s.message4 = "", "%s recovered."
  s.element_set, s.state_set = [], []
  s.plus_state_set, s.minus_state_set = [], []
  s.rating = 5
  s.hit_rate = 100
  s.maxhp_rate = s.maxsp_rate = s.str_rate = s.dex_rate = s.agi_rate = s.int_rate = 100
  s.atk_rate = s.pdef_rate = s.mdef_rate = s.eva = 100
  s.battle_only = true
  s.hold_turn, s.auto_release_prob, s.shock_release_prob = 0, 0, 0
  s.guard_element_set, s.guard_state_set = [], []
  s
end

def xp_event(id, name, x, y)
  e = RPG::Event.new
  e.id, e.name, e.x, e.y = id, name, x, y
  page = RPG::Event::Page.new
  page.type, page.span, page.through, page.always_on_top, page.trigger = 0, 0, false, false, 0
  page.move_route = nil
  page.list = [
    RPG::EventCommand.new(101, 0, ["hero_1", 0, 0, 2]),
    RPG::EventCommand.new(401, 0, ["The ferry leaves at dawn. Bring rope."]),
    RPG::EventCommand.new(117, 0, [3]),
    RPG::EventCommand.new(999, 0, ["custom-plugin-payload", 42, true]),
    RPG::EventCommand.new(0, 0, []),
  ]
  e.pages = [page]
  e
end

def xp_map(width, height, events)
  m = RPG::Map.new
  m.tileset_id = 1
  m.width, m.height = width, height
  m.autoplay_bgm = false
  m.bgm = RPG::AudioFile.new
  m.autoplay_bgs = false
  m.bgs = RPG::AudioFile.new
  m.encounter_list = []
  m.encounter_step = 30
  t = Table.new(3, width, height, 3)
  (0...width).each do |x|
    (0...height).each do |y|
      t[x, y, 0] = (x + y) % 8
      t[x, y, 1] = (x * 3 + y) % 16
      t[x, y, 2] = (x + y * 2) % 12
    end
  end
  m.data = t
  m.events = events.each_with_object({}) { |e, h| h[e.id] = e }
  m.scroll_type = 0
  m
end

def xp_system
  s = RPG::System.new
  s.magic_number = 123_456
  s.party_members = [1]
  s.elements = [nil, "Fire", "Ice", "Spark"]
  s.switches = [nil, "ferry_available"] + Array.new(19)
  s.variables = [nil, "rope_count"] + Array.new(19)
  s.windowskin_name = "skin_1"
  s.title_name = "title_brackenfell"
  s.gameover_name = "gameover_1"
  s.battle_transition = "fade"
  s.title_bgm = RPG::AudioFile.new("title_theme")
  s.battle_bgm = RPG::AudioFile.new("battle_theme")
  s.battle_end_me = RPG::AudioFile.new("fanfare")
  s.gameover_me = RPG::AudioFile.new("gameover")
  %i[cursor_se decision_se cancel_se buzzer_se equip_se shop_se save_se load_se battle_start_se
     escape_se actor_collapse_se enemy_collapse_se].each { |se| s.send("#{se}=", RPG::AudioFile.new("se_#{se}")) }
  s.words = { "gold" => "Glimmer", "hp" => "Stamina", "sp" => "Focus" }
  s.test_battlers = []
  s.test_troop_id = 1
  s.start_map_id, s.start_x, s.start_y = 1, 3, 4
  s.edit_map_id = 1
  s
end

def xp_common_event(id, name, trigger, switch_id, list)
  e = RPG::CommonEvent.new
  e.id, e.name, e.trigger, e.switch_id, e.list = id, name, trigger, switch_id, list
  e
end

def dump(name, object)
  File.binwrite(File.join(OUT, name), Marshal.dump(object))
end

FileUtils.rm_rf(OUT)
FileUtils.mkdir_p(OUT)

# ---------------------------------------------------------------- edge cases
shared = [1, 2, 3]
cycle = { "name" => "cycle-root" }
cycle["self"] = cycle
WardenStruct = Struct.new(:title, :rank)
edge = {
  "nil" => nil, "true" => true, "false" => false,
  "ints" => [0, 1, 122, 123, 255, 256, 65_535, 65_536, 2**30 - 1, 2**30, -(2**30), -(2**30) - 1, -124, -123, -1],
  "bigint" => 2**100,
  "bigint-neg" => -(2**100),
  "floats" => [3.14, 3.0, -0.5, 1.0 / 3, 1e10],
  "utf8" => "Brécyll 港",
  "sjis-labeled" => "abc".dup.force_encoding("Shift_JIS"),
  "binary" => [0, 1, 255, 128].pack("C*"),
  "symbols" => %i[alpha beta alpha],
  "shared" => [shared, shared],
  "cycle" => cycle,
  "hash-default" => Hash.new(7),
  "table" => Table.new(2, 3, 4, 2),
  "color" => Color.new(1.0, 0.5, 0.25, 1.0),
  "tone3" => Tone.new(-10.0, 20.0, 30.0),
  "struct" => WardenStruct.new("Warden", 3),
  "object" => xp_actor(7, "Odo", 2, 5, {}),
}
dump("edge-cases.rxdata", edge)

# ------------------------------------------------------------ XP fixture set
FileUtils.mkdir_p(File.join(OUT, "xp-project/Data"))
File.write(File.join(OUT, "xp-project/Game.ini"), <<~INI)
  [Game]
  Library=RGSS100J.dll
  Scripts=Data\\Scripts.rxdata
  Title=Brackenfell
INI

dump_to = lambda do |path, object|
  full = File.join(OUT, "xp-project", path)
  FileUtils.mkdir_p(File.dirname(full))
  File.binwrite(full, Marshal.dump(object))
end
params = (0...100).map { |lv| [45 + lv, 18 + lv / 2, 9 + lv / 4, 7 + lv / 4, 6 + lv / 3, 5 + lv / 3] }
dump_to.call("Data/Actors.rxdata", [nil, xp_actor(1, "Kestrel", 1, 1, params), xp_actor(2, "Marlow", 2, 3, params)])
dump_to.call("Data/Items.rxdata", [nil, xp_item(1, "Rope Coil", 12, "Sturdy hemp rope."), xp_item(2, "Glimmercap Tonic", 30, "Restores stamina.")])
dump_to.call("Data/Enemies.rxdata", [nil, xp_enemy(1, "Marsh Drake"), xp_enemy(2, "Fen Wisp")])
dump_to.call("Data/States.rxdata", [nil, xp_state(1, "Mired"), xp_state(2, "Glimmered")])
dump_to.call("Data/Tilesets.rxdata", [nil])
dump_to.call("Data/System.rxdata", xp_system)
dump_to.call("Data/Map001.rxdata", xp_map(20, 15, [xp_event(1, "Ferryman", 4, 3), xp_event(2, "Signpost", 9, 7)]))
dump_to.call("Data/CommonEvents.rxdata", [nil,
  xp_common_event(1, "GiveRope", 0, 0, [RPG::EventCommand.new(122, 0, [1, 1, 0, 0, 1])]),
  xp_common_event(3, "FerryDeparts", 0, 0, [RPG::EventCommand.new(355, 0, ["$game_map.need_refresh = true"])])])
scripts = [
  [1, "Main", Zlib::Deflate.deflate("puts 'Brackenfell boot'")],
  [2, "FerryPlugin", Zlib::Deflate.deflate("# encoding: utf-8\ndef ferry_ready?\n  true\nend")],
  [3, "UnknownGameData", Zlib::Deflate.deflate([137, 80, 0, 255].pack("C*"))],
]
dump_to.call("Data/Scripts.rxdata", scripts)

# ------------------------------------------------------------ VX mini set
FileUtils.mkdir_p(File.join(OUT, "vx-project/Data"))
vx_map = xp_map(10, 8, [xp_event(1, "Harbormaster", 2, 2)])
dump_vx = lambda do |path, object|
  full = File.join(OUT, "vx-project", path)
  FileUtils.mkdir_p(File.dirname(full))
  File.binwrite(full, Marshal.dump(object))
end
# VX maps use 3 z-layers.
t3 = Table.new(3, 10, 8, 3)
(0...10).each { |x| (0...8).each { |y| (0...3).each { |z| t3[x, y, z] = (x + y + z) % 12 } } }
vx_map.data = t3
vx_map.events = { 1 => xp_event(1, "Harbormaster", 2, 2) }
dump_vx.call("Data/Map002.rvdata", vx_map)
dump_vx.call("Data/Actors.rvdata", [nil, xp_actor(1, "Tamsin", 1, 2, params)])
dump_vx.call("Data/Scripts.rvdata", [[1, "Main", Zlib::Deflate.deflate("puts 'vx boot'")]])

# --------------------------------------------------------- VX Ace mini set
FileUtils.mkdir_p(File.join(OUT, "ace-project/Data"))
dump_ace = lambda do |path, object|
  full = File.join(OUT, "ace-project", path)
  FileUtils.mkdir_p(File.dirname(full))
  File.binwrite(full, Marshal.dump(object))
end
ace_actor = xp_actor(1, "Wren", 1, 1, params)
# VX Ace actor extras (plain ivars; accessors would create a singleton).
ace_actor.instance_variable_set(:@nickname, "the Sparrow")
ace_actor.instance_variable_set(:@profile, "A courier who maps the fenlands.".encode("UTF-8"))
ace_actor.instance_variable_set(:@note, "<currency:glitter>")
dump_ace.call("Data/Actors.rvdata2", [nil, ace_actor])
ace_map = xp_map(12, 10, [xp_event(1, "Lighthouse Keeper", 5, 5)])
ace_map.data = t3
dump_ace.call("Data/Map003.rvdata2", ace_map)
dump_ace.call("Data/CommonEvents.rvdata2", [nil,
  xp_common_event(2, "LightBeam", 0, 0, [RPG::EventCommand.new(355, 0, ["beam_on = true"])])])
dump_ace.call("Data/Scripts.rvdata2", [[1, "Main", Zlib::Deflate.deflate("# encoding: utf-8\nputs 'ace boot'")]])

# ------------------------------------------------------------- MV JSON set
FileUtils.mkdir_p(File.join(OUT, "mv-project/data"))
FileUtils.mkdir_p(File.join(OUT, "mv-project/js"))
File.write(File.join(OUT, "mv-project/js/rpg_core.js"), "// mv core stub for fixture\n")
File.write(File.join(OUT, "mv-project/js/plugins.js"), "// plugins stub\n")
mv_actors = [nil,
               { "id" => 1, "battlerName" => "kestrel_bt", "characterIndex" => 0, "characterName" => "kestrel",
                 "classId" => 1, "equips" => [1, 0, 0, 0, 0], "faceIndex" => 0, "faceName" => "kestrel_face",
                 "features" => [], "initialLevel" => 1, "maxLevel" => 99, "name" => "Kestrel",
                 "nickname" => "Ferry Warden", "note" => "", "profile" => "Keeps the crossing safe." },
               { "id" => 2, "battlerName" => "", "characterIndex" => 0, "characterName" => "marlow",
                 "classId" => 2, "equips" => [0, 0, 0, 0, 0], "faceIndex" => 1, "faceName" => "marlow_face",
                 "features" => [], "initialLevel" => 3, "maxLevel" => 99, "name" => "Marlow",
                 "nickname" => "", "note" => "<custom:tag>", "profile" => "" }]
File.write(File.join(OUT, "mv-project/data/Actors.json"), JSON.generate(mv_actors))
mv_system = {
  "gameTitle" => "Brackenfell", "currencyUnit" => "G", "startMapId" => 1, "startX" => 3, "startY" => 4,
  "switches" => [nil, "ferry_available"], "variables" => [nil, "rope_count"],
  "battleBgm" => { "name" => "battle_theme", "pan" => 0, "pitch" => 100, "volume" => 90 },
}
File.write(File.join(OUT, "mv-project/data/System.json"), JSON.generate(mv_system))
w, h = 6, 5
data = Array.new(w * h * 4, 0)
(0...w).each { |x| (0...h).each { |y| (0...4).each { |z| data[(z * h + y) * w + x] = (x + y * 2 + z) % 9 } } }
mv_map = {
  "autoplayBgm" => false, "autoplayBgs" => false, "battleback1Name" => "", "battleback2Name" => "",
  "bgm" => { "name" => "", "pan" => 0, "pitch" => 100, "volume" => 90 },
  "bgs" => { "name" => "", "pan" => 0, "pitch" => 100, "volume" => 90 },
  "disableDashing" => false, "displayName" => "Bracken Quay", "encounterList" => [], "encounterStep" => 30,
  "height" => h, "note" => "<mapnote:original>", "parallaxLoopX" => false, "parallaxLoopY" => false,
  "parallaxName" => "", "parallaxShow" => false, "parallaxSx" => 0, "parallaxSy" => 0, "scrollType" => 0,
  "specifyBattleback" => false, "tilesetId" => 1, "width" => w, "data" => data,
  "events" => [nil,
               { "id" => 1, "name" => "Ferryman", "x" => 2, "y" => 2,
                 "pages" => [{ "conditions" => { "actorId" => 1, "actorValid" => false, "itemId" => 1, "itemValid" => false, "selfSwitchCh" => "A", "selfSwitchValid" => false, "switch1Id" => 1, "switch1Valid" => false, "switch2Id" => 1, "switch2Valid" => false, "variableId" => 1, "variableValid" => false, "variableValue" => 0 },
                               "directionFix" => false, "image" => { "characterIndex" => 0, "characterName" => "ferryman", "direction" => 2, "pattern" => 1, "tileId" => 0 },
                               "list" => [
                                 { "code" => 101, "indent" => 0, "parameters" => ["ferryman", 0, 0, 2] },
                                 { "code" => 401, "indent" => 0, "parameters" => ["The tide turns soon."] },
                                 { "code" => 999, "indent" => 0, "parameters" => ["plugin-marker", { "k" => 1 }] },
                                 { "code" => 0, "indent" => 0, "parameters" => [] },
                               ],
                               "moveFrequency" => 3, "moveRoute" => { "list" => [{ "code" => 0, "parameters" => [] }], "repeat" => true, "skippable" => false, "wait" => false },
                               "moveSpeed" => 3, "moveType" => 0, "priorityType" => 1, "stepAnime" => false, "through" => false, "trigger" => 0, "walkAnime" => true }] },
               { "id" => 2, "name" => "Notice Board", "x" => 4, "y" => 3,
                 "pages" => [{ "conditions" => { "actorId" => 1, "actorValid" => false, "itemId" => 1, "itemValid" => false, "selfSwitchCh" => "A", "selfSwitchValid" => false, "switch1Id" => 1, "switch1Valid" => false, "switch2Id" => 1, "switch2Valid" => false, "variableId" => 1, "variableValid" => false, "variableValue" => 0 },
                               "directionFix" => false, "image" => { "characterIndex" => 0, "characterName" => "", "direction" => 2, "pattern" => 0, "tileId" => 0 },
                               "list" => [
                                 { "code" => 108, "indent" => 0, "parameters" => ["notice: ferry rates"] },
                                 { "code" => 408, "indent" => 0, "parameters" => ["two glimmer per crossing"] },
                                 { "code" => 0, "indent" => 0, "parameters" => [] },
                               ],
                               "moveFrequency" => 3, "moveRoute" => { "list" => [{ "code" => 0, "parameters" => [] }], "repeat" => true, "skippable" => false, "wait" => false },
                               "moveSpeed" => 3, "moveType" => 0, "priorityType" => 1, "stepAnime" => false, "through" => false, "trigger" => 0, "walkAnime" => true }] }],
}
File.write(File.join(OUT, "mv-project/data/Map001.json"), JSON.generate(mv_map))
mv_common = [nil,
             { "id" => 1, "list" => [
               { "code" => 121, "indent" => 0, "parameters" => [1, 1, 0] },
               { "code" => 0, "indent" => 0, "parameters" => [] },
             ], "name" => "EnableFerry", "switchId" => 1, "trigger" => 0 }]
File.write(File.join(OUT, "mv-project/data/CommonEvents.json"), JSON.generate(mv_common))
mv_items = [nil, { "id" => 1, "name" => "Rope Coil", "description" => "Sturdy hemp rope.", "price" => 12, "note" => "", "consumable" => true },
            { "id" => 2, "name" => "Lantern", "description" => "Burns steady.", "price" => 8, "note" => "<plugin:keep>", "consumable" => true }]
File.write(File.join(OUT, "mv-project/data/Items.json"), JSON.generate(mv_items))

# ------------------------------------------------------------- MZ JSON set
FileUtils.mkdir_p(File.join(OUT, "mz-project/data"))
FileUtils.mkdir_p(File.join(OUT, "mz-project/js"))
File.write(File.join(OUT, "mz-project/js/rmmz_core.js"), "// mz core stub for fixture\n")
mz_actors = JSON.parse(JSON.generate(mv_actors))
mz_actors[1]["nickname"] = "Quay Warden"
File.write(File.join(OUT, "mz-project/data/Actors.json"), JSON.generate(mz_actors))
mz_system = JSON.parse(JSON.generate(mv_system))
mz_system["advanced"] = { "gameId" => 812_001, "screenWidth" => 816, "screenHeight" => 624 }
File.write(File.join(OUT, "mz-project/data/System.json"), JSON.generate(mz_system))
mz_map = JSON.parse(JSON.generate(mv_map))
mz_map["events"][1]["pages"][0]["list"].insert(2, { "code" => 357, "indent" => 0, "parameters" => ["MZPlugin", "setWeather", "rain", {}] })
File.write(File.join(OUT, "mz-project/data/Map002.json"), JSON.generate(mz_map))

# --------------------------------------------- published-game distribution XP
pub = File.join(OUT, "published-xp")
FileUtils.mkdir_p(pub)
File.binwrite(File.join(pub, "Game.exe"), "MZ\x90\x00\x03\x00\x00\x00fake-exe-stub".b)
File.binwrite(File.join(pub, "RGSS100J.dll"), "fake-dll-stub".b)
File.write(File.join(pub, "Game.ini"), <<~INI)
  [Game]
  Library=RGSS100J.dll
  Scripts=Data\\Scripts.rxdata
  Title=Glimmerfen
  RTP1=Standard
INI
File.binwrite(File.join(pub, "Game.rgssad"), "RGSS\x00\x00\x00\x01fake-archive".b)
FileUtils.mkdir_p(File.join(pub, "Fonts"))

puts "fixtures written to #{OUT}"
