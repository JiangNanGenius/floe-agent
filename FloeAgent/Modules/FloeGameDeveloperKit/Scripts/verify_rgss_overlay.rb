#!/usr/bin/env ruby
# SPDX-License-Identifier: MPL-2.0
# Real Ruby execution of the RGSS overlay under engine-shaped RGSS stubs.
# Run once per engine: FLOE_TEST_ENGINE=rpgMakerXP|rpgMakerVX|rpgMakerVXAce.
# This proves the overlay/file protocol and engine-specific state paths; it is
# not a Tapir/RGSS engine or display acceptance.
require 'tmpdir'
require 'fileutils'

ENGINE = ENV.fetch('FLOE_TEST_ENGINE', 'rpgMakerXP')
OVERLAY = File.expand_path('../Sources/FloeGameDeveloperCore/Resources/Project/rgss-floe-developer.rb', __dir__)
XP = ENGINE == 'rpgMakerXP'

class TestActor
  attr_reader :id, :name, :level
  attr_accessor :hp
  def initialize(id, name, level, hp, maxhp, mp, maxmp)
    @id, @name, @level, @hp = id, name, level, hp
    if XP
      @maxhp, @sp, @maxsp = maxhp, mp, maxmp
    elsif ENGINE == 'rpgMakerVX'
      @maxhp, @mp, @maxmp = maxhp, mp, maxmp
    else
      @mhp, @mp, @mmp = maxhp, mp, maxmp
    end
  end
  def change_exp(exp, _show)
    @level = [exp.to_i / 100, 1].max
  end
  def exp_for_level(level)
    level.to_i * 100
  end
  if XP
    def maxhp; @maxhp; end
    attr_accessor :sp
    def maxsp; @maxsp; end
  elsif ENGINE == 'rpgMakerVX'
    def maxhp; @maxhp; end
    attr_accessor :mp
    def maxmp; @maxmp; end
  else
    def mhp; @mhp; end
    attr_accessor :mp
    def mmp; @mmp; end
  end
end

class TestItem
  attr_reader :id, :name
  def initialize(id, name)
    @id, @name = id, name
  end
end

class TestParty
  attr_reader :last_gain
  def initialize
    @gold = 120
    @actors = [TestActor.new(1, 'Hero', 5, 10, 100, 5, 20),
               TestActor.new(2, 'Mage', 4, 20, 60, 8, 30)]
    @items = { 1 => 2 }
  end
  def gold; @gold; end
  def gain_gold(amount); @gold += amount; end
  def items; XP ? [1] : [ITEM]; end
  if XP
    attr_reader :actors
    def item_number(item_id); @items[item_id.to_i] || 0; end
    def gain_item(item_id, amount)
      raise 'XP gain_item must receive an integer item id' unless item_id.is_a?(Integer)
      @last_gain = [item_id, amount]
      @items[item_id] = (@items[item_id] || 0) + amount
    end
  else
    def members; @actors; end
    if ENGINE == 'rpgMakerVX'
      def item_number(item)
        raise 'VX item_number must receive an item object' unless item.respond_to?(:id)
        @items[item.id] || 0
      end
    else
      def num_items(item); @items[item.id] || 0; end
    end
    def gain_item(item, amount)
      raise 'VX/Ace gain_item must receive an item object' unless item.respond_to?(:id)
      @last_gain = [item, amount]
      @items[item.id] = (@items[item.id] || 0) + amount
    end
  end
end

class TestVariables
  def initialize; @data = { 1 => 7, 2 => 'hello', 600 => nil }; end
  def [](id); @data[id]; end
  def []=(id, value); @data[id] = value; end
end

class TestSwitches
  def initialize; @data = { 1 => true, 600 => nil }; end
  def [](id); @data[id]; end
  def []=(id, value); @data[id] = value; end
end

class TestGameTemp
  attr_accessor :player_transferring, :player_new_map_id, :player_new_x,
                :player_new_y, :player_new_direction
end

class TestPlayer
  attr_accessor :x, :y
  attr_reader :transfers
  def initialize
    @x, @y = 4, 6
    @transfers = []
  end
  def moveto(x, y); @x, @y = x, y; end
  unless XP
    def reserve_transfer(map, x, y, *_rest)
      @transfers << [map, x, y]
    end
  end
end

class TestMap
  def map_id; 3; end
end

class TestSystem
  def playtime_text; '00:01:00'; end
end

module Graphics
  @frame_count = 600
  @frame_rate = 60
  class << self
    attr_accessor :frame_count, :frame_rate
    def update; end
  end
end

class Scene_Title; end
ITEM = TestItem.new(1, 'Potion')
$floe_engine_id = ENGINE
$game_party = TestParty.new
$game_variables = TestVariables.new
$game_switches = TestSwitches.new
$game_player = TestPlayer.new
$game_temp = TestGameTemp.new
$game_map = TestMap.new
$game_system = TestSystem.new
$game_actors = [1, 2]
$data_items = [nil, ITEM] + (2..600).map { |id| TestItem.new(id, "Item #{id}") }
$data_mapinfos = [nil, { name: 'Town' }, { name: 'Cave' }, { name: 'Field' }]
variables = Array.new(601)
variables[1] = 'Gold'
variables[2] = 'Name'
variables[600] = 'Six hundred'
switches = Array.new(601)
switches[1] = 'Door'
switches[600] = 'Six hundred switch'
$data_system = Struct.new(:variables, :switches).new(variables, switches)
$scene = nil

failures = []
def check(failures, label)
  if yield
    puts "PASS #{ENGINE} #{label}"
  else
    failures << label
    puts "FAIL #{ENGINE} #{label}"
  end
rescue Exception => error
  failures << "#{label}: #{error.message}"
  puts "FAIL #{ENGINE} #{label}: #{error.message}"
end

def write_request(dir, operation, uuid, records)
  body = [records.size].pack('n') + records.join
  data = 'FLDR' + [1, operation].pack('C2') + uuid + [body.size].pack('N') + body
  File.open(File.join(dir, 'requests', uuid + '.req'), 'wb') { |file| file.write(data) }
end

def read_response(dir, uuid)
  path = File.join(dir, 'responses', uuid + '.res')
  raise 'missing response' unless File.exist?(path)
  data = File.binread(path)
  raise 'response magic' unless data[0, 4] == 'FLDS'
  raise 'response version' unless data[4, 1].unpack('C')[0] == 1
  raise 'response uuid' unless data[5, 36] == uuid
  size = data[41, 4].unpack('N')[0]
  FloeDeveloper.parse_records(data[45, size])
end

def exchange(dir, operation, records = [])
  uuid = format('%08x-%04x-%04x-%04x-%012x', rand(2**32), rand(2**16), rand(2**16), rand(2**16), rand(2**48))
  write_request(dir, operation, uuid, records)
  2.times { Graphics.update }
  read_response(dir, uuid)
end

def value(records, key)
  item = records.detect { |record| record[0] == key }
  item && item[2]
end

Dir.mktmpdir('floe-rgss-overlay-') do |root|
  dir = File.join(root, 'floe-developer')
  FileUtils.mkdir_p(File.join(dir, 'requests'))
  FileUtils.mkdir_p(File.join(dir, 'responses'))
  FileUtils.cp(OVERLAY, File.join(dir, 'floe_developer.rb'))
  load File.join(dir, 'floe_developer.rb')

  mp_key = XP ? 'sp' : 'mp'
  max_mp = 20
  first_actor = XP ? $game_party.actors[0] : $game_party.members[0]

  probe = exchange(dir, 1)
  check(failures, 'probe engine/party/mp-field') do
    value(probe, '@engine') == ENGINE &&
      value(probe, '@overlayVersion') == '1.0.0' &&
      value(probe, '@actorCount').to_i == 2 &&
      value(probe, '@mpField') == mp_key &&
      value(probe, 'actor.0.mp').to_i == 5 &&
      value(probe, '@variableCount').to_i == 601 &&
      value(probe, '@itemCount').to_i == 601 &&
      value(probe, '@switchCount').to_i == 601 &&
      value(probe, '@levelAction') == "\1"
  end

  state = exchange(dir, 2)
  check(failures, "read gold/hp/#{mp_key}/variable/switch") do
    value(state, 'field.party.gold').to_i == 120 &&
      value(state, 'field.party.actor.1.hp').to_i == 10 &&
      value(state, "field.party.actor.1.#{mp_key}").to_i == 5 &&
      value(state, 'field.switches.s1') == "\1" &&
      value(state, 'field.variables.v1') == '7' &&
      value(state, 'field.party.items').include?('Potion') &&
      value(state, 'field.party.actors').include?(XP ? 'SP' : 'MP')
  end

  write = exchange(dir, 3, [
    FloeDeveloper.record('changeCount', 2, '3'),
    FloeDeveloper.string_record('change.0.id', 'party.gold'),
    FloeDeveloper.int_record('change.0.value', 500),
    FloeDeveloper.string_record('change.1.id', 'party.actor.1.hp'),
    FloeDeveloper.int_record('change.1.value', 77),
    FloeDeveloper.string_record('change.2.id', "party.actor.1.#{mp_key}"),
    FloeDeveloper.int_record('change.2.value', 15)
  ])
  check(failures, "write gold/hp/#{mp_key} and read back") do
    value(write, '@status').to_i == 0 &&
      value(write, 'field.party.gold').to_i == 500 &&
      value(write, 'field.party.actor.1.hp').to_i == 77 &&
      value(write, "field.party.actor.1.#{mp_key}").to_i == 15
  end

  heal = exchange(dir, 4, [
    FloeDeveloper.string_record('actionID', 'party.healAll'),
    FloeDeveloper.int_record('argCount', 0)
  ])
  check(failures, "invoke healAll restores #{mp_key}") do
    value(heal, '@status').to_i == 0 &&
      value(heal, 'field.party.actor.1.hp').to_i == 100 &&
      value(heal, "field.party.actor.1.#{mp_key}").to_i == max_mp
  end

  level = exchange(dir, 4, [
    FloeDeveloper.string_record('actionID', 'party.levelAll'),
    FloeDeveloper.int_record('argCount', 1),
    FloeDeveloper.string_record('arg.0.id', 'level'),
    FloeDeveloper.int_record('arg.0.value', 10)
  ])
  check(failures, 'invoke levelAll uses engine exp/level path') do
    value(level, '@status').to_i == 0 && first_actor.level == 10
  end

  gain = exchange(dir, 4, [
    FloeDeveloper.string_record('actionID', 'party.addItem'),
    FloeDeveloper.int_record('argCount', 2),
    FloeDeveloper.string_record('arg.0.id', 'itemID'),
    FloeDeveloper.int_record('arg.0.value', 1),
    FloeDeveloper.string_record('arg.1.id', 'count'),
    FloeDeveloper.int_record('arg.1.value', 2)
  ])
  check(failures, "invoke addItem uses #{XP ? 'item_id' : 'item object'} shape") do
    value(gain, '@status').to_i == 0 &&
      (XP ? ($game_party.last_gain == [1, 2] && $game_party.last_gain[0].is_a?(Integer)) :
        ($game_party.last_gain[1] == 2 && $game_party.last_gain[0].respond_to?(:id)))
  end

  transfer = exchange(dir, 4, [
    FloeDeveloper.string_record('actionID', 'player.transfer'),
    FloeDeveloper.int_record('argCount', 3),
    FloeDeveloper.string_record('arg.0.id', 'mapID'),
    FloeDeveloper.int_record('arg.0.value', 2),
    FloeDeveloper.string_record('arg.1.id', 'x'),
    FloeDeveloper.int_record('arg.1.value', 8),
    FloeDeveloper.string_record('arg.2.id', 'y'),
    FloeDeveloper.int_record('arg.2.value', 9)
  ])
  check(failures, "invoke map transfer uses #{XP ? '$game_temp' : 'reserve_transfer'}") do
    if XP
      value(transfer, '@status').to_i == 0 && $game_temp.player_transferring == true &&
        $game_temp.player_new_map_id == 2 && $game_temp.player_new_x == 8 &&
        $game_temp.player_new_y == 9
    else
      value(transfer, '@status').to_i == 0 && $game_player.transfers.last == [2, 8, 9]
    end
  end

  switch = exchange(dir, 4, [
    FloeDeveloper.string_record('actionID', 'switches.set'),
    FloeDeveloper.int_record('argCount', 2),
    FloeDeveloper.string_record('arg.0.id', 'switchID'),
    FloeDeveloper.int_record('arg.0.value', 2),
    FloeDeveloper.string_record('arg.1.id', 'value'),
    FloeDeveloper.bool_record('arg.1.value', true)
  ])
  check(failures, 'invoke switch write') { value(switch, '@status').to_i == 0 && value(switch, 'field.switches.s2') == "\1" }

  malformed = exchange(dir, 3, [
    FloeDeveloper.int_record('changeCount', 1),
    FloeDeveloper.string_record('change.0.id', 'party.unknown'),
    FloeDeveloper.bool_record('change.0.value', false)
  ])
  check(failures, 'malformed field is rejected, not silently successful') do
    value(malformed, '@status').to_i == 1
  end

  switch_off = exchange(dir, 3, [
    FloeDeveloper.int_record('changeCount', 1),
    FloeDeveloper.string_record('change.0.id', 'switches.s1'),
    FloeDeveloper.bool_record('change.0.value', false)
  ])
  check(failures, 'boolean false switch is applied and read back') do
    value(switch_off, '@status').to_i == 0 &&
      value(switch_off, 'field.switches.s1') == "\0"
  end

  variable = exchange(dir, 4, [
    FloeDeveloper.string_record('actionID', 'variables.set'),
    FloeDeveloper.int_record('argCount', 2),
    FloeDeveloper.string_record('arg.0.id', 'variableID'),
    FloeDeveloper.int_record('arg.0.value', 2),
    FloeDeveloper.string_record('arg.1.id', 'value'),
    FloeDeveloper.string_record('arg.1.value', '42')
  ])
  check(failures, 'invoke variable write') { value(variable, '@status').to_i == 0 && value(variable, 'field.variables.v2') == '42' }

  snapshot = exchange(dir, 5)
  snapshot_bytes = value(snapshot, '@snapshot')
  check(failures, 'snapshot is a non-empty primitive document') { snapshot_bytes && snapshot_bytes.size > 10 }
  check(failures, 'snapshot internal record count exceeds the 512 request limit') do
    FloeDeveloper.parse_records(snapshot_bytes, FloeDeveloper::MAX_SNAPSHOT_RECORDS).size > 512
  end
  # Add/change post-snapshot state that supported actions can mutate.
  add_after = exchange(dir, 4, [
    FloeDeveloper.string_record('actionID', 'party.addItem'),
    FloeDeveloper.int_record('argCount', 2),
    FloeDeveloper.string_record('arg.0.id', 'itemID'),
    FloeDeveloper.int_record('arg.0.value', 600),
    FloeDeveloper.string_record('arg.1.id', 'count'),
    FloeDeveloper.int_record('arg.1.value', 1)
  ])
  set_variable = exchange(dir, 4, [
    FloeDeveloper.string_record('actionID', 'variables.set'),
    FloeDeveloper.int_record('argCount', 2),
    FloeDeveloper.string_record('arg.0.id', 'variableID'),
    FloeDeveloper.int_record('arg.0.value', 600),
    FloeDeveloper.string_record('arg.1.id', 'value'),
    FloeDeveloper.string_record('arg.1.value', '123')
  ])
  set_switch = exchange(dir, 4, [
    FloeDeveloper.string_record('actionID', 'switches.set'),
    FloeDeveloper.int_record('argCount', 2),
    FloeDeveloper.string_record('arg.0.id', 'switchID'),
    FloeDeveloper.int_record('arg.0.value', 600),
    FloeDeveloper.string_record('arg.1.id', 'value'),
    FloeDeveloper.bool_record('arg.1.value', true)
  ])
  check(failures, 'post-snapshot inventory/variable/switch mutations applied') do
    value(add_after, '@status').to_i == 0 &&
      value(set_variable, '@status').to_i == 0 &&
      value(set_switch, '@status').to_i == 0 &&
      $game_party.last_gain[0] == (XP ? 600 : $data_items[600]) &&
      $game_variables[600] == 123 && $game_switches[600] == true
  end
  $game_party.gain_gold(5000)
  first_actor.hp = 1
  first_actor.mp = 1 if first_actor.respond_to?(:mp=)
  first_actor.sp = 1 if first_actor.respond_to?(:sp=)
  restore = exchange(dir, 6, [FloeDeveloper.binary_record('snapshot', snapshot_bytes)])
  check(failures, 'restore returns original gold/party') do
    value(restore, '@status').to_i == 0 &&
      $game_party.gold == 500 &&
      first_actor.hp == 100 &&
      first_actor.send(mp_key.to_sym) == max_mp &&
      FloeDeveloper.party_item_count(600) == 0 &&
      $game_variables[600].nil? &&
      $game_switches[1] == false && $game_switches[600] == false
  end

  reset = exchange(dir, 7)
  check(failures, 'reset selects Scene_Title') { value(reset, '@status').to_i == 0 && $scene.is_a?(Scene_Title) }

  diagnostics = exchange(dir, 9)
  check(failures, 'diagnostics reports frames/map') do
    value(diagnostics, '@frames').to_i == 600 && value(diagnostics, '@mapID').to_i == 3
  end
end

if failures.empty?
  puts "ALL RGSS OVERLAY CHECKS PASSED (#{ENGINE})"
  exit 0
else
  puts "RGSS OVERLAY FAILURES (#{ENGINE}): #{failures.join('; ')}"
  exit 1
end
