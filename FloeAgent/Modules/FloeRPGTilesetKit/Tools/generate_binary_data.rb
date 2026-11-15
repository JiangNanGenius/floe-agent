#!/usr/bin/env ruby
# SPDX-License-Identifier: MPL-2.0
# frozen_string_literal: true
# Original synthetic RPG Maker binary data fixtures (real Ruby Marshal 4.8).
# No RTP, Enterbrain scripts or proprietary game content is produced.
require "fileutils"

ROOT = File.expand_path("..", __dir__)
FIX = File.join(ROOT, "Tests", "FloeRPGTilesetKitTests", "Fixtures")

class Table
  def initialize(dim, xsize, ysize, zsize)
    @dim, @xsize, @ysize, @zsize = dim, xsize, ysize, zsize
    @data = Array.new(xsize * ysize * zsize, 0)
  end
  def []=(x, y, z, value)
    @data[(z * @ysize + y) * @xsize + x] = value
  end
  def _dump(_level)
    [@dim, @xsize, @ysize, @zsize, @data.size].pack("L5") + @data.pack("s*")
  end
end

module RPG
  class Tileset
    attr_accessor :id, :name, :tileset_name, :autotile_names, :panorama_name,
                  :fog_name, :battleback_name, :passages, :priorities,
                  :terrain_tags, :mode, :tileset_names, :note, :floe_unknown
  end
  class Map
    attr_accessor :tileset_id, :width, :height, :data, :events, :scroll_type,
                  :encounter_list, :floe_unknown
  end
  class Event
    class Page
      class Graphic
        attr_accessor :character_name, :character_index, :direction, :pattern,
                      :tile_id, :floe_unknown
      end
      attr_accessor :graphic, :list, :trigger, :floe_unknown
    end
    attr_accessor :id, :name, :x, :y, :pages, :floe_unknown
  end
end

def table3(w, h, fills)
  t = Table.new(3, w, h, 3)
  fills.each { |z, x, y, gid| t[x, y, z] = gid }
  t
end

def event(id, name, x, y, char_index, direction)
  g = RPG::Event::Page::Graphic.new
  g.character_name = "FloeHero"
  g.character_index = char_index
  g.direction = direction
  g.pattern = 1
  g.tile_id = 0
  g.floe_unknown = "keep-graphic-#{id}"
  p = RPG::Event::Page.new
  p.graphic = g
  p.list = []
  p.trigger = 0
  p.floe_unknown = "keep-page-#{id}"
  e = RPG::Event.new
  e.id = id
  e.name = name
  e.x = x
  e.y = y
  e.pages = [p]
  e.floe_unknown = "keep-event-#{id}"
  e
end

def write_map(path, tileset_id, width, height, table, events)
  m = RPG::Map.new
  m.tileset_id = tileset_id
  m.width = width
  m.height = height
  m.data = table
  m.events = events.each_with_object({}) { |e, h| h[e.id] = e }
  m.scroll_type = 0
  m.encounter_list = []
  m.floe_unknown = "keep-map"
  FileUtils.mkdir_p(File.dirname(path))
  File.binwrite(path, Marshal.dump(m))
end

def xp
  d = File.join(FIX, "xp-project")
  t = RPG::Tileset.new
  t.id = 1
  t.name = "Floe XP"
  t.tileset_name = "FloeXP_Tiles"
  t.autotile_names = (1..7).map { |i| "FloeXP_A#{i}" }
  t.panorama_name = ""
  t.fog_name = ""
  t.battleback_name = ""
  t.passages = Table.new(1, 384, 1, 1)
  t.priorities = Table.new(1, 384, 1, 1)
  t.terrain_tags = Table.new(1, 384, 1, 1)
  t.floe_unknown = "keep-xp-tileset"
  FileUtils.mkdir_p(File.join(d, "Data"))
  File.binwrite(File.join(d, "Data/Tilesets.rxdata"), Marshal.dump([nil, t]))

  fills = []
  12.times { |x| fills << [0, x, 0, 384 + x] }
  fills += [
    [0, 0, 1, 48 + 47], [0, 1, 1, 48 + 0], [0, 2, 1, 48 + 8],
    [0, 3, 1, 48 + 48 + 47], [0, 4, 1, 384 + 0],
    [1, 0, 0, 48 + 96 + 47], [1, 1, 0, 384 + 16], [1, 2, 0, 384 + 24],
    [2, 0, 0, 48 + 144 + 0], [2, 1, 0, 384 + 32]
  ]
  write_map(File.join(d, "Data/Map001.rxdata"), 1, 12, 10, table3(12, 10, fills),
            [event(1, "Hero", 2, 2, 0, 2), event(2, "Guard", 8, 6, 1, 4)])
end

def vx_like(name, ext, prefix)
  d = File.join(FIX, name)
  t = RPG::Tileset.new
  t.id = 1
  t.mode = 0
  t.name = "Floe #{prefix}"
  t.tileset_names = %w[A1 A2 A3 A4 A5 B C D E].map { |k| "#{prefix}_#{k}" }
  t.note = "Original synthetic fixture. No RTP content."
  t.floe_unknown = "keep-#{prefix}-tileset"
  FileUtils.mkdir_p(File.join(d, "Data"))
  File.binwrite(File.join(d, "Data/Tilesets.#{ext}"), Marshal.dump([nil, t]))
  fills = []
  12.times { |x| fills << [0, x, 0, 2816 + (x % 4) * 48 + 47] }
  fills += [
    [0, 0, 1, 2816 + 0 * 48 + 0], [0, 1, 1, 2816 + 0 * 48 + 8],
    [0, 2, 1, 2816 + 0 * 48 + 16], [0, 3, 1, 2816 + 0 * 48 + 24],
    [0, 4, 1, 2048 + 0 * 48 + 47], [0, 5, 1, 2048 + 5 * 48 + 0],
    [0, 6, 1, 1536 + 0], [0, 7, 1, 1], [0, 8, 1, 257],
    [0, 9, 1, 513], [0, 10, 1, 769],
    [1, 0, 0, 4352 + 0 * 48 + 0], [1, 1, 0, 4352 + 0 * 48 + 8],
    [1, 2, 0, 5888 + 0 * 48 + 47], [1, 3, 0, 2048 + 88 * 48 + 0],
    [1, 4, 0, 1536 + 16], [1, 5, 0, 2], [1, 6, 0, 258],
    [2, 0, 0, 2816 + 3 * 48 + 47], [2, 1, 0, 513 + 3]
  ]
  write_map(File.join(d, "Data/Map001.#{ext}"), 1, 12, 10, table3(12, 10, fills),
            [event(1, "Hero", 2, 2, 0, 2), event(2, "Guard", 8, 6, 1, 4)])
end

xp
vx_like("vx-project", "rvdata", "FloeVX")
vx_like("ace-project", "rvdata2", "FloeAce")
puts "generated binary fixtures"
