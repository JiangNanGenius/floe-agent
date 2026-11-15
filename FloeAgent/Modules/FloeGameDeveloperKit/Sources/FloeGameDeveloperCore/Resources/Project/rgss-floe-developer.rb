# encoding: utf-8
# SPDX-License-Identifier: MPL-2.0
# Floe RGSS developer overlay 1.0.0
#
# This file is inserted into a project revision by the existing owned project
# plan. It is not game code and is not required by a production export. It
# implements a bounded file RPC under <run>/floe-developer: requests are binary
# TLV files, responses are binary TLV files. It exposes live party gold, party
# actors, variables, switches, map transfer and a primitive-only snapshot.
# There is no eval, shell, host filesystem mount, network or Marshal.load of
# external bytes.
module FloeDeveloper
  VERSION = '1.0.0'
  # Bounded coverage for primitive checkpoint state. Larger projects still
  # use the live fields/actions; snapshots report coverage via notices.
  MAX_SNAPSHOT_ITEMS = 2048
  MAX_SNAPSHOT_VARIABLES = 2048
  MAX_SNAPSHOT_SWITCHES = 2048
  # Snapshot bodies need a larger internal record budget than a request, but
  # remain bounded (2048 variables + 2048 switches + items + actors).
  MAX_SNAPSHOT_RECORDS = 8192
  ROOT = File.expand_path(File.dirname(__FILE__))
  REQUESTS = File.join(ROOT, 'requests')
  RESPONSES = File.join(ROOT, 'responses')
  MAX_ACTORS = 8
  MAX_NAMED_VARIABLES = 48
  MAX_NAMED_SWITCHES = 48

  @tick_count = 0
  @revision = 0
  @last_log = ''

  class << self
    def revision
      @revision
    end

    def last_log
      @last_log
    end

    def log(message)
      @last_log = message.to_s.slice(0, 1024)
    end

    def tick
      @tick_count += 1
      return if (@tick_count % 2) != 0
      return unless ensure_directories
      names = Dir.entries(REQUESTS).select { |name| name.size > 4 && name[-4, 4] == '.req' }.sort
      names.first(2).each do |name|
        process(File.join(REQUESTS, name))
      end
    rescue Exception => error
      log("tick: #{error.message}")
    end

    def ensure_directories
      [ROOT, REQUESTS, RESPONSES].each do |directory|
        Dir.mkdir(directory) unless File.exist?(directory)
      end
      true
    rescue Exception
      false
    end

    # MARK: - Binary TLV

    def u16(value)
      [(value >> 8) & 0xFF, value & 0xFF].pack('C*')
    end

    def u32(value)
      [(value >> 24) & 0xFF, (value >> 16) & 0xFF,
       (value >> 8) & 0xFF, value & 0xFF].pack('C*')
    end

    # Old embedded Ruby builds may decode native-width network integers
    # differently on ARM64. The wire format is fixed bytes on every engine.
    def read_u16(data)
      bytes = data.unpack('C*')
      raise 'short u16' unless bytes.size == 2
      (bytes[0] << 8) | bytes[1]
    end

    def read_u32(data)
      bytes = data.unpack('C*')
      raise 'short u32' unless bytes.size == 4
      (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]
    end

    def byte_size(value)
      value.respond_to?(:bytesize) ? value.bytesize : value.size
    end

    def binary_string(value)
      text = value.to_s
      text = text.dup if text.frozen?
      # The embedded Ruby1.9 build has the canonical encoding but does not
      # load the standard interpreter's optional BINARY alias table.
      text = text.force_encoding('ASCII-8BIT') if text.respond_to?(:force_encoding)
      text
    end

    def record(key, type, bytes)
      key = binary_string(key)
      bytes = binary_string(bytes)
      [type & 0xFF].pack('C') + u16(byte_size(key)) + key + u32(byte_size(bytes)) + bytes
    end

    def string_record(key, value)
      record(key, 1, value.to_s)
    end

    def int_record(key, value)
      record(key, 2, value.to_i.to_s)
    end

    def number_record(key, value)
      record(key, 3, sprintf('%.17g', value.to_f))
    end

    def bool_record(key, value)
      record(key, 4, value ? "\1" : "\0")
    end

    def binary_record(key, value)
      record(key, 5, value.to_s)
    end

    def null_record(key)
      record(key, 6, '')
    end

    def read_exact(file, count)
      data = ''
      while data.size < count
        chunk = file.read(count - data.size)
        raise 'truncated guest request' if chunk.nil? || chunk.empty?
        data << chunk
      end
      data
    end

    def parse_records(data, maximum_records = 512)
      raise 'short payload' if data.nil? || data.size < 2
      count = read_u16(data[0, 2])
      raise 'too many records' if count > maximum_records
      offset = 2
      records = []
      count.times do
        raise 'short record' if offset + 3 > data.size
        type = data[offset, 1].unpack('C')[0]
        offset += 1
        key_size = read_u16(data[offset, 2])
        offset += 2
        raise 'long key' if key_size <= 0 || key_size > 128
        raise 'short key' if offset + key_size + 4 > data.size
        key = data[offset, key_size]
        offset += key_size
        value_size = read_u32(data[offset, 4])
        offset += 4
        raise 'long value' if value_size > 4 * 1024 * 1024
        raise 'short value' if offset + value_size > data.size
        value = data[offset, value_size]
        offset += value_size
        records << [key, type, value]
      end
      raise 'trailing bytes' unless offset == data.size
      records
    end

    def record_value(records, key)
      records.each do |record|
        return record if record[0] == key
      end
      nil
    end

    def record_string(records, key)
      item = record_value(records, key)
      item && item[1] == 1 ? item[2] : nil
    end

    def record_int(records, key)
      item = record_value(records, key)
      return nil unless item
      item[1] == 2 ? item[2].to_i : (item[1] == 3 ? item[2].to_f.to_i : nil)
    end

    def record_bool(records, key)
      item = record_value(records, key)
      item && item[1] == 4 ? (item[2] == "\1") : nil
    end

    def response_payload(records)
      body = binary_string(u16(records.size) + records.join)
      binary_string('FLDS' + [1].pack('C') + body)
    end

    def write_response(uuid, records)
      body = binary_string(u16(records.size) + records.join)
      payload = binary_string('FLDS' + [1].pack('C') + binary_string(uuid) + u32(byte_size(body)) + body)
      final = File.join(RESPONSES, uuid + '.res')
      temporary = File.join(RESPONSES, uuid + '.res.tmp')
      File.open(temporary, 'wb') { |file| file.write(payload) }
      File.rename(temporary, final)
      final
    end

    def process(path)
      uuid = nil
      records = []
      begin
        File.open(path, 'rb') do |file|
          magic = read_exact(file, 4)
          raise 'request magic' unless magic == 'FLDR'
          version = read_exact(file, 1).unpack('C')[0]
          raise 'request version' unless version == 1
          operation = read_exact(file, 1).unpack('C')[0]
          uuid = read_exact(file, 36)
          size = read_u32(read_exact(file, 4))
          raise 'request size' if size > 4 * 1024 * 1024
          records = parse_records(read_exact(file, size))
          response = dispatch(operation, records)
          write_response(uuid, response)
        end
      rescue Exception => error
        log("process: #{error.message}")
        if uuid
          begin
            write_response(uuid, [int_record('@status', 1),
                                  string_record('@message', "Overlay error: #{error.message}"),
                                  string_record('@messageZh', "覆盖层错误：#{error.message}"),
                                  int_record('@revision', @revision)])
          rescue Exception
          end
        end
      ensure
        begin
          File.delete(path) if File.exist?(path)
        rescue Exception
        end
      end
    end

    # MARK: - Dispatch

    def dispatch(operation, records)
      case operation
      when 1 then probe(records)
      when 2 then read_state(records)
      when 3 then apply_changes(records)
      when 4 then invoke(records)
      when 5 then take_snapshot(records)
      when 6 then restore_snapshot(records)
      when 7 then reset_game(records)
      when 8 then [int_record('@status', 0), int_record('@revision', @revision)]
      when 9 then diagnostics(records)
      else [int_record('@status', 2), string_record('@message', 'Unknown operation.'),
            string_record('@messageZh', '未知操作。'), int_record('@revision', @revision)]
      end
    end

    # MARK: - Game bindings

    def party
      defined?($game_party) && $game_party ? $game_party : nil
    end

    def actors
      current = party
      return [] unless current
      return current.members if current.respond_to?(:members)
      return current.actors if current.respond_to?(:actors)
      []
    end

    def gold
      current = party
      return 0 unless current && current.respond_to?(:gold)
      current.gold.to_i
    rescue Exception
      0
    end

    def max_hp(actor)
      return actor.maxhp.to_i if actor.respond_to?(:maxhp)
      return actor.mhp.to_i if actor.respond_to?(:mhp)
      actor.hp.to_i
    rescue Exception
      0
    end

    def xp?
      engine_id == 'rpgMakerXP'
    end

    def mp_key
      xp? ? 'sp' : 'mp'
    end

    def actor_mp(actor)
      return 0 unless actor
      key = mp_key
      return actor.send(key).to_i if actor.respond_to?(key.to_sym)
      0
    rescue Exception
      0
    end

    def max_mp(actor)
      if xp?
        return actor.maxsp.to_i if actor.respond_to?(:maxsp)
        return actor.msp.to_i if actor.respond_to?(:msp)
      end
      return actor.maxmp.to_i if actor.respond_to?(:maxmp)
      return actor.mmp.to_i if actor.respond_to?(:mmp)
      actor_mp(actor)
    rescue Exception
      0
    end

    def set_actor_mp(actor, value)
      key = mp_key
      setter = "#{key}="
      return false unless actor.respond_to?(setter.to_sym)
      actor.send(setter.to_sym, value.to_i)
      true
    rescue Exception
      false
    end

    def actor_id(actor, index)
      return actor.id.to_i if actor.respond_to?(:id)
      index + 1
    end

    def variable_count
      return 0 unless defined?($data_system) && $data_system
      return $data_system.variables.size if $data_system.respond_to?(:variables) && $data_system.variables
      0
    rescue Exception
      0
    end

    def switch_count
      return 0 unless defined?($data_system) && $data_system
      return $data_system.switches.size if $data_system.respond_to?(:switches) && $data_system.switches
      0
    rescue Exception
      0
    end

    def item_count
      defined?($data_items) && $data_items ? $data_items.size : 0
    rescue Exception
      0
    end

    def map_count
      defined?($data_mapinfos) && $data_mapinfos ? $data_mapinfos.size : 0
    rescue Exception
      0
    end

    def map_id
      defined?($game_map) && $game_map && $game_map.respond_to?(:map_id) ? $game_map.map_id.to_i : 0
    rescue Exception
      0
    end

    def player
      defined?($game_player) && $game_player ? $game_player : nil
    end

    def player_x
      player && player.respond_to?(:x) ? player.x.to_i : 0
    end

    def player_y
      player && player.respond_to?(:y) ? player.y.to_i : 0
    end

    def frame_count
      defined?(Graphics) && Graphics.respond_to?(:frame_count) ? Graphics.frame_count.to_i : 0
    rescue Exception
      0
    end

    def frame_rate
      defined?(Graphics) && Graphics.respond_to?(:frame_rate) ? Graphics.frame_rate.to_i : 0
    rescue Exception
      0
    end

    def playtime_text
      rate = frame_rate
      return '—' if rate <= 0
      seconds = frame_count / rate
      sprintf('%02d:%02d:%02d', seconds / 3600, (seconds / 60) % 60, seconds % 60)
    end

    def can_set_level?(actor)
      actor.respond_to?(:change_level) ||
        (actor.respond_to?(:change_exp) && actor.respond_to?(:exp_for_level)) ||
        actor.respond_to?(:level=)
    rescue Exception
      false
    end

    def can_reset?
      defined?(Scene_Title) && defined?($scene)
    rescue Exception
      false
    end

    def item_name(item_id)
      return "Item #{item_id}" unless defined?($data_items) && $data_items && $data_items[item_id]
      $data_items[item_id].respond_to?(:name) ? $data_items[item_id].name.to_s.slice(0, 128) : "Item #{item_id}"
    end

    def party_item_count(id)
      current = party
      return 0 unless current
      if xp? && current.respond_to?(:item_number)
        return current.item_number(id).to_i
      end
      item = defined?($data_items) && $data_items ? $data_items[id] : nil
      return 0 unless item
      return current.num_items(item).to_i if current.respond_to?(:num_items)
      return current.item_number(item).to_i if current.respond_to?(:item_number)
      0
    rescue Exception
      0
    end

    def change_item_count(id, delta)
      return false if delta == 0
      current = party
      item = defined?($data_items) && $data_items ? $data_items[id] : nil
      return false unless current && item
      before = party_item_count(id)
      if xp?
        current.gain_item(id, delta)
      else
        begin
          current.gain_item(item, delta)
        rescue ArgumentError
          current.gain_item(item, delta, false)
        end
      end
      # Standard game setters may return nil. Confirm the actual inventory.
      party_item_count(id) == before + delta
    rescue Exception
      false
    end

    def party_items_text
      current = party
      return '—' unless current
      entries = []
      if current.respond_to?(:items)
        begin
          entries = current.items || []
        rescue Exception
          entries = []
        end
      end
      # XP may expose item ids or item objects; VX/Ace expose item objects.
      if entries.empty? && defined?($data_items) && $data_items
        (1...$data_items.size).each do |id|
          number = party_item_count(id)
          entries << id if number.to_i > 0
        end
      end
      entries.map do |entry|
        if entry.is_a?(Integer)
          item_id = entry
          number = party_item_count(item_id)
          "#{item_name(item_id)} x#{number.to_i}"
        else
          item_id = entry.respond_to?(:id) ? entry.id : nil
          number = item_id ? party_item_count(item_id) : 0
          "#{entry.respond_to?(:name) ? entry.name.to_s.slice(0, 128) : item_name(item_id)} x#{number.to_i}"
        end
      end.join(', ').slice(0, 2048)
    rescue Exception
      '—'
    end

    def actors_text
      actors.map do |actor|
        level = actor.respond_to?(:level) ? actor.level.to_i : 0
        hp = actor.respond_to?(:hp) ? actor.hp.to_i : 0
        mp = actor_mp(actor)
        mp_label = xp? ? 'SP' : 'MP'
        "#{actor.respond_to?(:name) ? actor.name : 'Actor'} L#{level} HP#{hp}/#{max_hp(actor)} #{mp_label}#{mp}/#{max_mp(actor)}"
      end.join('; ').slice(0, 2048)
    rescue Exception
      '—'
    end

    # MARK: - Probe / state

    def probe(records)
      list = actors
      output = [
        int_record('@status', 0),
        string_record('@overlayVersion', VERSION),
        string_record('@engine', engine_id),
        string_record('@runtime', 'RGSS guest'),
        int_record('@actorCount', [list.size, MAX_ACTORS].min),
        int_record('@itemCount', item_count),
        int_record('@variableCount', variable_count),
        int_record('@switchCount', switch_count),
        int_record('@mapCount', map_count),
        bool_record('@levelAction', !list.empty? && list.all? { |actor| can_set_level?(actor) }),
        bool_record('@resetAvailable', can_reset?),
        bool_record('@snapshotAvailable', true),
        string_record('@mpField', mp_key),
        int_record('@revision', @revision)
      ]
      [list.size, MAX_ACTORS].min.times do |index|
        actor = list[index]
        id = actor_id(actor, index)
        output << int_record("actor.#{index}.id", id)
        output << string_record("actor.#{index}.name", actor.respond_to?(:name) ? actor.name.to_s.slice(0, 256) : "Actor #{id}")
        output << int_record("actor.#{index}.level", actor.respond_to?(:level) ? actor.level.to_i : 0)
        output << int_record("actor.#{index}.hp", actor.respond_to?(:hp) ? actor.hp.to_i : 0)
        output << int_record("actor.#{index}.maxHP", max_hp(actor))
        output << int_record("actor.#{index}.mp", actor_mp(actor))
        output << int_record("actor.#{index}.maxMP", max_mp(actor))
      end
      output
    end

    def engine_id
      defined?($floe_engine_id) && $floe_engine_id ? $floe_engine_id.to_s : 'rpgMakerXP'
    end

    def read_state(records)
      output = [int_record('@status', 0), int_record('@revision', @revision)]
      output << int_record('field.party.gold', gold)
      output << string_record('field.party.actors', actors_text)
      list = actors
      [list.size, MAX_ACTORS].min.times do |index|
        actor = list[index]
        id = actor_id(actor, index)
        prefix = "party.actor.#{id}"
        output << int_record("field.#{prefix}.level", actor.respond_to?(:level) ? actor.level.to_i : 0)
        output << int_record("field.#{prefix}.hp", actor.respond_to?(:hp) ? actor.hp.to_i : 0)
        output << int_record("field.#{prefix}.#{mp_key}", actor_mp(actor))
      end
      output << string_record('field.party.items', party_items_text)
      output << int_record('field.map.id', map_id)
      output << int_record('field.player.x', player_x)
      output << int_record('field.player.y', player_y)
      output << string_record('field.system.playtime', playtime_text)
      output << int_record('field.system.frames', frame_count)
      variables = [variable_count - 1, MAX_NAMED_VARIABLES].min
      if variables > 0
        (1..variables).each do |id|
          output << string_record("field.variables.v#{id}", variable_text(id))
        end
      end
      switches = [switch_count - 1, MAX_NAMED_SWITCHES].min
      if switches > 0
        (1..switches).each do |id|
          output << bool_record("field.switches.s#{id}", switch_value(id))
        end
      end
      output << string_record('@log', @last_log) unless @last_log.empty?
      output
    end

    def variable_text(id)
      return '' unless defined?($game_variables) && $game_variables
      value = $game_variables[id]
      case value
      when Integer, Float, String, TrueClass, FalseClass, NilClass
        value.to_s.slice(0, 8192)
      else
        value.class.to_s
      end
    rescue Exception
      ''
    end

    def switch_value(id)
      return false unless defined?($game_switches) && $game_switches
      !!$game_switches[id]
    rescue Exception
      false
    end

    # MARK: - Writes and actions

    def apply_changes(records)
      count = record_int(records, 'changeCount') || 0
      count = 32 if count > 32
      applied = []
      rejected = []
      count.times do |index|
        id = record_string(records, "change.#{index}.id")
        value = value_from_records(records, "change.#{index}.value")
        if id.nil? || value.nil?
          rejected << (id || "change#{index}")
          next
        end
        if apply_field(id, value)
          after = field_value(id)
          if after == value || (value == true && after == true) || (value == false && after == false)
            applied << id
          else
            rejected << id
          end
        else
          rejected << id
        end
      end
      @revision += 1 if !applied.empty?
      output = [int_record('@status', rejected.empty? ? 0 : 1),
                string_record('@message', rejected.empty? ? "Applied #{applied.size} field(s)." : "Applied #{applied.size}, rejected #{rejected.size}."),
                string_record('@messageZh', rejected.empty? ? "已应用 #{applied.size} 个字段。" : "已应用 #{applied.size} 个，拒绝 #{rejected.size} 个。"),
                int_record('@revision', @revision)]
      applied.each { |id| output << string_record("changed.#{applied.index(id)}", id) }
      output.concat(read_state(records)[1..-1])
      output << string_record('@log', @last_log) unless @last_log.empty?
      output
    end

    def field_value(id)
      return gold if id == 'party.gold'
      if id =~ /\Aparty\.actor\.(\d+)\.(level|hp|mp|sp)\z/
        actor = actors.detect { |item| actor_id(item, 0) == $1.to_i }
        return nil unless actor
        return actor_mp(actor) if $2 == mp_key
        return actor.respond_to?($2) ? actor.send($2).to_i : nil
      end
      if id =~ /\Aplayer\.(x|y)\z/
        return $1 == 'x' ? player_x : player_y
      end
      if id =~ /\Aswitches\.s(\d+)\z/
        return switch_value($1.to_i)
      end
      if id =~ /\Avariables\.v(\d+)\z/
        return variable_text($1.to_i)
      end
      return map_id if id == 'map.id'
      return playtime_text if id == 'system.playtime'
      return frame_count if id == 'system.frames'
      nil
    end

    def apply_field(id, value)
      if id == 'party.gold'
        current = party
        return false unless current
        target = value.to_i
        delta = target - gold
        if current.respond_to?(:gain_gold)
          current.gain_gold(delta)
          return true
        end
        return false
      end
      if id =~ /\Aparty\.actor\.(\d+)\.(hp|mp|sp)\z/
        actor = actors.detect { |item| actor_id(item, 0) == $1.to_i }
        return false unless actor
        return set_actor_mp(actor, value) if $2 == mp_key
        setter = "#{$2}="
        if actor.respond_to?(setter.to_sym)
          actor.send(setter.to_sym, value.to_i)
          return true
        end
        return false
      end
      if id =~ /\Aplayer\.(x|y)\z/
        target = player
        return false unless target
        x = $1 == 'x' ? value.to_i : player_x
        y = $1 == 'y' ? value.to_i : player_y
        if target.respond_to?(:moveto)
          target.moveto(x, y)
          return true
        end
        return false
      end
      if id =~ /\Aswitches\.s(\d+)\z/
        return false unless defined?($game_switches) && $game_switches
        $game_switches[$1.to_i] = (value == true || value.to_s == 'true')
        return true
      end
      false
    end

    def invoke(records)
      action = record_string(records, 'actionID')
      count = record_int(records, 'argCount') || 0
      count = 8 if count > 8
      arguments = {}
      count.times do |index|
        id = record_string(records, "arg.#{index}.id")
        value = value_from_records(records, "arg.#{index}.value")
        arguments[id] = value if id && !value.nil?
      end
      before = state_hash
      status = 0
      case action
      when 'party.gainGold'
        current = party
        amount = (arguments['amount'] || 0).to_i
        if current && current.respond_to?(:gain_gold)
          current.gain_gold(amount)
          log("Gained #{amount} gold.")
        else
          status = 1
        end
      when 'party.healAll'
        list = actors
        if list.empty?
          status = 1
        else
          list.each do |actor|
            actor.hp = max_hp(actor) if actor.respond_to?(:hp=)
            set_actor_mp(actor, max_mp(actor))
          end
          log('Healed the party.')
        end
      when 'party.levelAll'
        level = (arguments['level'] || 1).to_i
        list = actors
        success = !list.empty? && list.all? { |actor| set_level(actor, level) }
        status = success ? 0 : 2
        log("Set party level to #{level}.") if success
      when 'party.addItem'
        item_id = (arguments['itemID'] || 0).to_i
        amount = (arguments['count'] || 1).to_i
        item = defined?($data_items) && $data_items ? $data_items[item_id] : nil
        if item && item_id > 0 && item_id <= MAX_SNAPSHOT_ITEMS && party && party.respond_to?(:gain_item)
          if xp?
            party.gain_item(item_id, amount)
          else
            begin
              party.gain_item(item, amount)
            rescue ArgumentError
              party.gain_item(item, amount, false)
            end
          end
          log("Added #{amount} #{item.name}.")
        else
          status = 1
        end
      when 'player.transfer'
        map = (arguments['mapID'] || 0).to_i
        x = (arguments['x'] || 0).to_i
        y = (arguments['y'] || 0).to_i
        if schedule_transfer(map, x, y)
          log("Transfer to map #{map}.")
        else
          status = 2
        end
      when 'variables.set'
        variable_id = (arguments['variableID'] || 0).to_i
        value = arguments['value'].to_s.slice(0, 512)
        if defined?($game_variables) && $game_variables && variable_id > 0 &&
            variable_id <= MAX_SNAPSHOT_VARIABLES
          current_value = $game_variables[variable_id]
          unless current_value.nil? || current_value.is_a?(Integer) || current_value.is_a?(Float) ||
              current_value.is_a?(String) || current_value == true || current_value == false
            status = 2
            log("Variable #{variable_id} is opaque and is not editable by checkpoints.")
          else
            parsed = if value =~ /\A-?\d+\z/ then value.to_i
                     elsif value == 'true' then true
                     elsif value == 'false' then false
                     else value end
            $game_variables[variable_id] = parsed
            log("Set variable #{variable_id}.")
          end
        else
          status = variable_id > MAX_SNAPSHOT_VARIABLES ? 2 : 1
        end
      when 'switches.set'
        switch_id = (arguments['switchID'] || 0).to_i
        if defined?($game_switches) && $game_switches && switch_id > 0 &&
            switch_id <= MAX_SNAPSHOT_SWITCHES
          $game_switches[switch_id] = (arguments['value'] == true)
          log("Set switch #{switch_id}.")
        else
          status = switch_id > MAX_SNAPSHOT_SWITCHES ? 2 : 1
        end
      else
        status = 2
      end
      @revision += 1 if status == 0
      changed = state_hash
      changed_keys = []
      changed.each do |key, value|
        changed_keys << key unless before[key] == value
      end
      output = [int_record('@status', status),
                string_record('@message', status == 0 ? 'Action applied.' : 'Action not supported by this RGSS project.'),
                string_record('@messageZh', status == 0 ? '动作已应用。' : '此 RGSS 工程不支持该动作。'),
                string_record('@actionID', action.to_s),
                int_record('@revision', @revision)]
      changed_keys.first(32).each_with_index { |key, index| output << string_record("changed.#{index}", key) }
      output.concat(read_state(records)[1..-1])
      output << string_record('@log', @last_log) unless @last_log.empty?
      output
    end

    def set_level(actor, level)
      if actor.respond_to?(:change_level)
        actor.change_level(level, false)
        return true
      end
      if actor.respond_to?(:change_exp) && actor.respond_to?(:exp_for_level)
        actor.change_exp(actor.exp_for_level(level), false)
        return true
      end
      if actor.respond_to?(:level=)
        actor.level = level
        return true
      end
      false
    rescue Exception
      false
    end

    def state_hash
      values = {}
      values['party.gold'] = gold
      actors.each do |actor|
        id = actor_id(actor, 0)
        values["party.actor.#{id}.level"] = actor.respond_to?(:level) ? actor.level.to_i : 0
        values["party.actor.#{id}.hp"] = actor.respond_to?(:hp) ? actor.hp.to_i : 0
        values["party.actor.#{id}.#{mp_key}"] = actor_mp(actor)
      end
      values
    end

    # MARK: - Snapshot / restore (primitive-only, no Marshal.load)

    def take_snapshot(records)
      snapshot = [int_record('gold', gold)]
      actors.each do |actor|
        id = actor_id(actor, 0)
        snapshot << int_record("actor.#{id}.level", actor.respond_to?(:level) ? actor.level.to_i : 0)
        snapshot << int_record("actor.#{id}.hp", actor.respond_to?(:hp) ? actor.hp.to_i : 0)
        snapshot << int_record("actor.#{id}.#{mp_key}", actor_mp(actor))
      end

      item_max = [item_count - 1, MAX_SNAPSHOT_ITEMS].min
      snapshot << int_record('itemMax', item_max)
      if item_max > 0
        (1..item_max).each do |id|
          count = party_item_count(id)
          snapshot << int_record("item.#{id}", count) if count > 0
        end
      end

      variable_max = [variable_count - 1, MAX_SNAPSHOT_VARIABLES].min
      snapshot << int_record('variableMax', variable_max)
      if variable_max > 0
        (1..variable_max).each do |id|
          value = variable_primitive(id)
          snapshot << string_record("variable.#{id}", value) if value
        end
      end

      switch_max = [switch_count - 1, MAX_SNAPSHOT_SWITCHES].min
      snapshot << int_record('switchMax', switch_max)
      if switch_max > 0
        (1..switch_max).each { |id| snapshot << bool_record("switch.#{id}", switch_value(id)) }
      end

      snapshot << int_record('map', map_id)
      snapshot << int_record('x', player_x)
      snapshot << int_record('y', player_y)
      body = u16(snapshot.size) + snapshot.join
      [int_record('@status', 0), binary_record('@snapshot', body),
       int_record('@revision', @revision), string_record('@log',
         "Snapshot captured: gold/party, items 1-#{item_max}, variables 1-#{variable_max}, switches 1-#{switch_max}, map position.")]
    end

    def variable_primitive(id)
      return nil unless defined?($game_variables) && $game_variables
      value = $game_variables[id]
      case value
      when Integer then "i:#{value}"
      when Float then "f:#{sprintf('%.17g', value)}"
      when String then "s:#{value.to_s.slice(0, 512)}"
      when TrueClass then 'b:true'
      when FalseClass then 'b:false'
      when NilClass then 'n:'
      else nil
      end
    rescue Exception
      nil
    end

    def restore_snapshot(records)
      item = record_value(records, 'snapshot')
      unless item && item[1] == 5
        return [int_record('@status', 1), string_record('@message', 'Missing snapshot.'),
                string_record('@messageZh', '缺少快照。'), int_record('@revision', @revision)]
      end
      parsed = parse_records(item[2], MAX_SNAPSHOT_RECORDS)
      lookup = {}
      parsed.each { |record| lookup[record[0]] = record }
      failed = false

      parsed.each do |record|
        key, type, value = record
        if key == 'gold' && type == 2
          failed = true unless apply_field('party.gold', value.to_i)
        elsif key =~ /\Aactor\.(\d+)\.(level|hp|mp|sp)\z/
          actor = actors.detect { |entry| actor_id(entry, 0) == $1.to_i }
          next unless actor
          if $2 == 'level'
            failed = true unless set_level(actor, value.to_i)
          elsif $2 == mp_key
            failed = true unless set_actor_mp(actor, value.to_i)
          elsif actor.respond_to?("#{$2}=".to_sym)
            actor.send("#{$2}=".to_sym, value.to_i)
          else
            failed = true
          end
        end
      end

      item_max = record_int(parsed, 'itemMax') || 0
      (1..item_max).each do |id|
        record = lookup["item.#{id}"]
        target = record && record[1] == 2 ? record[2].to_i : 0
        delta = target - party_item_count(id)
        failed = true if delta != 0 && !change_item_count(id, delta)
      end

      variable_max = record_int(parsed, 'variableMax') || 0
      (1..variable_max).each do |id|
        record = lookup["variable.#{id}"]
        next unless record && record[1] == 1
        set_variable_primitive(id, record[2])
      end

      switch_max = record_int(parsed, 'switchMax') || 0
      if defined?($game_switches) && $game_switches
        (1..switch_max).each do |id|
          record = lookup["switch.#{id}"]
          $game_switches[id] = record && record[1] == 4 ? (record[2] == "\1") : false
        end
      end

      parsed.each do |record|
        key, type, value = record
        if key == 'map' && type == 2
          @pending_map = value.to_i
        elsif key == 'x' && type == 2
          @pending_x = value.to_i
        elsif key == 'y' && type == 2
          @pending_y = value.to_i
        end
      end
      schedule_transfer(@pending_map, @pending_x || 0, @pending_y || 0) if @pending_map
      @pending_map = nil; @pending_x = nil; @pending_y = nil

      status = failed ? 1 : 0
      @revision += 1
      message = failed ? 'Snapshot restored with unsupported item/actor entries.' : 'Snapshot restored.'
      message_zh = failed ? '快照已恢复，但部分物品/角色项不受支持。' : '快照已恢复。'
      output = [int_record('@status', status), string_record('@message', message),
                string_record('@messageZh', message_zh), int_record('@revision', @revision)]
      output.concat(read_state(records)[1..-1])
      output
    rescue Exception => error
      [int_record('@status', 1), string_record('@message', "Restore failed: #{error.message}"),
       string_record('@messageZh', "恢复失败：#{error.message}"), int_record('@revision', @revision)]
    end

    def set_variable_primitive(id, encoded)
      return unless defined?($game_variables) && $game_variables
      prefix = encoded[0, 2]
      body = encoded[2..-1] || ''
      value = case prefix
              when 'i:' then body.to_i
              when 'f:' then body.to_f
              when 's:' then body
              when 'b:' then body == 'true'
              when 'n:' then nil
              else body end
      $game_variables[id] = value
    end

    # MARK: - Transfer helper

    def schedule_transfer(map, x, y)
      if xp?
        return false unless defined?($game_temp) && $game_temp
        $game_temp.player_transferring = true
        $game_temp.player_new_map_id = map
        $game_temp.player_new_x = x
        $game_temp.player_new_y = y
        $game_temp.player_new_direction = 0
        return true
      end
      target = player
      return false unless target && target.respond_to?(:reserve_transfer)
      begin
        target.reserve_transfer(map, x, y)
      rescue ArgumentError
        begin
          target.reserve_transfer(map, x, y, 0, 0)
        rescue Exception
          return false
        end
      end
      true
    rescue Exception
      false
    end

    # MARK: - Reset / diagnostics

    def reset_game(records)
      if defined?(Scene_Title) && defined?($scene)
        $scene = Scene_Title.new
        @revision += 1
        [int_record('@status', 0), string_record('@message', 'Returned to the title scene.'),
         string_record('@messageZh', '已返回标题场景。'), int_record('@revision', @revision)]
      else
        [int_record('@status', 2), string_record('@message', 'No Scene_Title is available.'),
         string_record('@messageZh', '没有可用的 Scene_Title。'), int_record('@revision', @revision)]
      end
    rescue Exception => error
      [int_record('@status', 1), string_record('@message', "Reset failed: #{error.message}"),
       string_record('@messageZh', "重置失败：#{error.message}"), int_record('@revision', @revision)]
    end

    def diagnostics(records)
      [int_record('@status', 0), int_record('@revision', @revision),
       number_record('@fps', frame_rate), int_record('@frames', frame_count),
       int_record('@mapID', map_id), string_record('@playtime', playtime_text),
       string_record('@log', @last_log)]
    end

    def value_from_records(records, prefix)
      item = record_value(records, prefix)
      return nil unless item
      case item[1]
      when 1 then item[2]
      when 2 then item[2].to_i
      when 3 then item[2].to_f
      when 4 then item[2] == "\1"
      when 6 then nil
      else nil
      end
    end
  end
end

# Hook the real RGSS frame loop. The alias is installed only if Graphics.update
# exists; a missing/failed hook leaves the menu's attach handshake actionable.
begin
  if defined?(Graphics) && Graphics.respond_to?(:update)
    class << Graphics
      unless method_defined?(:floe_developer_original_update)
        alias_method :floe_developer_original_update, :update
        def update
          FloeDeveloper.tick
          floe_developer_original_update
        end
      end
    end
  end
rescue Exception => error
  FloeDeveloper.log("hook: #{error.message}")
end
