// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public struct GameDeveloperRGSSActor: Equatable, Sendable {
    public let id: Int
    public let name: String
    public let level: Int
    public let hp: Int
    public let maxHP: Int
    public let mp: Int
    public let maxMP: Int

    public init(id: Int, name: String, level: Int, hp: Int,
                maxHP: Int, mp: Int, maxMP: Int) {
        self.id = id; self.name = name; self.level = level
        self.hp = hp; self.maxHP = maxHP; self.mp = mp; self.maxMP = maxMP
    }
}

public struct GameDeveloperRGSSProbe: Equatable, Sendable {
    public let engine: GameEngineID
    public let overlayVersion: String
    public let runtime: String
    public let actors: [GameDeveloperRGSSActor]
    public let itemCount: Int
    public let variableCount: Int
    public let switchCount: Int
    public let mapCount: Int
    public let levelAction: Bool
    public let resetAvailable: Bool
    public let snapshotAvailable: Bool

    public init(engine: GameEngineID, overlayVersion: String, runtime: String,
                actors: [GameDeveloperRGSSActor], itemCount: Int,
                variableCount: Int, switchCount: Int, mapCount: Int,
                levelAction: Bool, resetAvailable: Bool, snapshotAvailable: Bool) {
        self.engine = engine
        self.overlayVersion = overlayVersion
        self.runtime = runtime
        self.actors = actors
        self.itemCount = itemCount
        self.variableCount = variableCount
        self.switchCount = switchCount
        self.mapCount = mapCount
        self.levelAction = levelAction
        self.resetAvailable = resetAvailable
        self.snapshotAvailable = snapshotAvailable
    }

    public static func decode(records: [GameDeveloperRGSSRecord],
                              expectedEngine: GameEngineID) throws -> GameDeveloperRGSSProbe {
        let values = GameDeveloperRGSSCodec.dictionary(records)
        func string(_ key: String) -> String? { values[key]?.stringValue }
        func int(_ key: String) -> Int? { values[key]?.integerValue }
        func bool(_ key: String) -> Bool { values[key]?.booleanValue ?? false }
        guard let version = string("@overlayVersion"), !version.isEmpty,
              let engineRaw = string("@engine"),
              let engine = GameEngineID(rawValue: engineRaw),
              engine == expectedEngine else {
            throw GameDeveloperError.bridgeUnavailable("RGSS overlay handshake")
        }
        let actorCount = min(max(int("@actorCount") ?? 0, 0), 8)
        var actors: [GameDeveloperRGSSActor] = []
        for index in 0..<actorCount {
            guard let id = int("actor.\(index).id") else { continue }
            actors.append(.init(
                id: id,
                name: string("actor.\(index).name") ?? "Actor \(id)",
                level: int("actor.\(index).level") ?? 1,
                hp: int("actor.\(index).hp") ?? 0,
                maxHP: int("actor.\(index).maxHP") ?? 0,
                mp: int("actor.\(index).mp") ?? 0,
                maxMP: int("actor.\(index).maxMP") ?? 0))
        }
        return .init(
            engine: engine, overlayVersion: version,
            runtime: string("@runtime") ?? "RGSS guest",
            actors: actors,
            itemCount: max(int("@itemCount") ?? 0, 0),
            variableCount: max(int("@variableCount") ?? 0, 0),
            switchCount: max(int("@switchCount") ?? 0, 0),
            mapCount: max(int("@mapCount") ?? 0, 0),
            levelAction: bool("@levelAction"),
            resetAvailable: bool("@resetAvailable"),
            snapshotAvailable: bool("@snapshotAvailable"))
    }
}

/// Fixed RGSS field/action schema shared by XP, VX and VX Ace. The overlay
/// implements exactly these ids; the host never invents a money/party setter
/// for an engine that did not report it.
public enum GameDeveloperRGSSSchema {
    public static let maximumNamedVariables = 48
    public static let maximumNamedSwitches = 48
    /// Checkpoint coverage caps; they match the Ruby overlay constants.
    public static let maximumSnapshotItems = 2_048
    public static let maximumSnapshotVariables = 2_048
    public static let maximumSnapshotSwitches = 2_048

    public static func fields(engine: GameEngineID,
                              probe: GameDeveloperRGSSProbe) -> [GameDeveloperFieldDescriptor] {
        var fields: [GameDeveloperFieldDescriptor] = []
        fields.append(.init(
            id: "party.gold", label: "Party gold", labelZhHans: "队伍金钱",
            group: "Party", groupZhHans: "队伍", kind: .integer,
            symbol: "dollarsign.circle", minimum: 0, maximum: 99_999_999, step: 1))
        fields.append(.init(
            id: "party.actors", label: "Party", labelZhHans: "队伍成员",
            group: "Party", groupZhHans: "队伍", kind: .readOnlyText,
            symbol: "person.3", detail: "Names, levels, HP and MP from the live RGSS party.",
            detailZhHans: "来自实时 RGSS 队伍的名称、等级、HP 和 MP。"))
        for actor in probe.actors.prefix(8) {
            let prefix = "party.actor.\(actor.id)"
            fields.append(.init(
                id: "\(prefix).level", label: "\(actor.name) · level", labelZhHans: "\(actor.name) · 等级",
                group: "Party", groupZhHans: "队伍", kind: .readOnlyNumber,
                symbol: "star", minimum: 1, maximum: 99))
            fields.append(.init(
                id: "\(prefix).hp", label: "\(actor.name) · HP", labelZhHans: "\(actor.name) · HP",
                group: "Party", groupZhHans: "队伍", kind: .integer,
                symbol: "heart", minimum: 0, maximum: 999_999, step: 1))
            let mpField = engine == .rpgMakerXP ? "sp" : "mp"
            let mpLabel = engine == .rpgMakerXP ? "SP" : "MP"
            fields.append(.init(
                id: "\(prefix).\(mpField)", label: "\(actor.name) · \(mpLabel)", labelZhHans: "\(actor.name) · \(mpLabel)",
                group: "Party", groupZhHans: "队伍", kind: .integer,
                symbol: "drop", minimum: 0, maximum: 999_999, step: 1))
        }
        fields.append(.init(
            id: "party.items", label: "Party items", labelZhHans: "队伍物品",
            group: "Items", groupZhHans: "物品", kind: .readOnlyText,
            symbol: "shippingbox"))
        fields.append(.init(
            id: "map.id", label: "Map", labelZhHans: "地图",
            group: "World", groupZhHans: "世界", kind: .readOnlyNumber,
            symbol: "map"))
        fields.append(.init(
            id: "player.x", label: "Player X", labelZhHans: "玩家 X",
            group: "World", groupZhHans: "世界", kind: .integer,
            symbol: "arrow.left.and.right", minimum: 0, maximum: 999, step: 1))
        fields.append(.init(
            id: "player.y", label: "Player Y", labelZhHans: "玩家 Y",
            group: "World", groupZhHans: "世界", kind: .integer,
            symbol: "arrow.up.and.down", minimum: 0, maximum: 999, step: 1))
        fields.append(.init(
            id: "system.playtime", label: "Playtime", labelZhHans: "游戏时长",
            group: "World", groupZhHans: "世界", kind: .readOnlyText,
            symbol: "clock"))
        fields.append(.init(
            id: "system.frames", label: "Frames", labelZhHans: "帧数",
            group: "World", groupZhHans: "世界", kind: .readOnlyNumber,
            symbol: "film"))
        let variables = min(max(probe.variableCount - 1, 0), maximumNamedVariables)
        for id in 1...max(1, variables) where variables > 0 {
            fields.append(.init(
                id: "variables.v\(id)", label: "Variable \(id)", labelZhHans: "变量 \(id)",
                group: "Variables", groupZhHans: "变量", kind: .readOnlyText,
                symbol: "number"))
        }
        let switches = min(max(probe.switchCount - 1, 0), maximumNamedSwitches)
        for id in 1...max(1, switches) where switches > 0 {
            fields.append(.init(
                id: "switches.s\(id)", label: "Switch \(id)", labelZhHans: "开关 \(id)",
                group: "Switches", groupZhHans: "开关", kind: .boolean,
                symbol: "switch.2"))
        }
        return fields
    }

    public static func actions(engine: GameEngineID,
                               probe: GameDeveloperRGSSProbe) -> [GameDeveloperActionDescriptor] {
        var actions: [GameDeveloperActionDescriptor] = [
            .init(id: "party.gainGold",
                  label: "Gain gold", labelZhHans: "增加金钱",
                  group: "Party", groupZhHans: "队伍", symbol: "dollarsign.circle",
                  detail: "Adjusts the live party gold. The overlay clamps to the engine range.",
                  detailZhHans: "调整实时队伍金钱；覆盖层会按引擎范围限制。",
                  parameters: [.init(id: "amount", label: "Amount", labelZhHans: "数量",
                                     kind: .integer, minimum: -9_999_999, maximum: 9_999_999,
                                     step: 1, isRequired: true, defaultValue: .integer(1_000))]),
            .init(id: "party.healAll",
                  label: "Heal party", labelZhHans: "治疗队伍",
                  group: "Party", groupZhHans: "队伍", symbol: "cross.case",
                  detail: "Restores every party member to max HP and MP.",
                  detailZhHans: "将所有队员的 HP 和 MP 恢复到上限。"),
            .init(id: "party.addItem",
                  label: "Add item", labelZhHans: "添加物品",
                  group: "Items", groupZhHans: "物品", symbol: "plus.square",
                  parameters: [
                    .init(id: "itemID", label: "Item ID", labelZhHans: "物品 ID",
                          kind: .integer, minimum: 1,
                          maximum: Double(min(max(1, probe.itemCount - 1), maximumSnapshotItems)), step: 1,
                          isRequired: true, defaultValue: .integer(1)),
                    .init(id: "count", label: "Count", labelZhHans: "数量",
                          kind: .integer, minimum: 1, maximum: 99, step: 1,
                          isRequired: true, defaultValue: .integer(1))
                  ]),
            .init(id: "player.transfer",
                  label: "Transfer player", labelZhHans: "传送玩家",
                  group: "World", groupZhHans: "世界", symbol: "arrow.triangle.turn.up.right.diamond",
                  detail: "Schedules a map transfer through the engine-specific live RGSS path (XP $game_temp or VX/Ace reserve_transfer).",
                  detailZhHans: "通过引擎专属实时 RGSS 路径安排地图传送（XP $game_temp 或 VX/Ace reserve_transfer）。",
                  role: .jump,
                  parameters: [
                    .init(id: "mapID", label: "Map ID", labelZhHans: "地图 ID",
                          kind: .integer, minimum: 1, maximum: Double(max(1, probe.mapCount)),
                          step: 1, isRequired: true, defaultValue: .integer(1)),
                    .init(id: "x", label: "X", labelZhHans: "X",
                          kind: .integer, minimum: 0, maximum: 999, step: 1,
                          isRequired: true, defaultValue: .integer(0)),
                    .init(id: "y", label: "Y", labelZhHans: "Y",
                          kind: .integer, minimum: 0, maximum: 999, step: 1,
                          isRequired: true, defaultValue: .integer(0))
                  ]),
            .init(id: "variables.set",
                  label: "Set variable", labelZhHans: "设置变量",
                  group: "Variables", groupZhHans: "变量", symbol: "number",
                  detail: "Sets a numbered RGSS variable; integer-looking text becomes an integer.",
                  detailZhHans: "设置编号 RGSS 变量；整数形式文本会转为整数。",
                  parameters: [
                    .init(id: "variableID", label: "Variable ID", labelZhHans: "变量 ID",
                          kind: .integer, minimum: 1,
                          maximum: Double(min(max(1, probe.variableCount - 1), maximumSnapshotVariables)), step: 1,
                          isRequired: true, defaultValue: .integer(1)),
                    .init(id: "value", label: "Value", labelZhHans: "值",
                          kind: .text, maximumLength: 512, isRequired: true)
                  ]),
            .init(id: "switches.set",
                  label: "Set switch", labelZhHans: "设置开关",
                  group: "Switches", groupZhHans: "开关", symbol: "switch.2",
                  parameters: [
                    .init(id: "switchID", label: "Switch ID", labelZhHans: "开关 ID",
                          kind: .integer, minimum: 1,
                          maximum: Double(min(max(1, probe.switchCount - 1), maximumSnapshotSwitches)), step: 1,
                          isRequired: true, defaultValue: .integer(1)),
                    .init(id: "value", label: "Value", labelZhHans: "值",
                          kind: .boolean, isRequired: true, defaultValue: .boolean(true))
                  ])
        ]
        if probe.itemCount <= 1 { actions.removeAll { $0.id == "party.addItem" } }
        if probe.mapCount <= 0 { actions.removeAll { $0.id == "player.transfer" } }
        if probe.variableCount <= 1 { actions.removeAll { $0.id == "variables.set" } }
        if probe.switchCount <= 1 { actions.removeAll { $0.id == "switches.set" } }
        if probe.levelAction {
            actions.append(.init(
                id: "party.levelAll", label: "Set party level",
                labelZhHans: "设置队伍等级",
                group: "Party", groupZhHans: "队伍", symbol: "star.circle",
                detail: "Uses the engine's level/exp API; unsupported actors are reported.",
                detailZhHans: "使用引擎的等级/经验 API；不支持的队员会报告。",
                parameters: [.init(id: "level", label: "Level", labelZhHans: "等级",
                                   kind: .integer, minimum: 1, maximum: 99, step: 1,
                                   isRequired: true, defaultValue: .integer(10))]))
        }
        return actions
    }

    public static func supports(probe: GameDeveloperRGSSProbe) -> GameDeveloperSupports {
        .init(liveState: true, snapshot: probe.snapshotAvailable,
              restore: probe.snapshotAvailable, pause: false, resume: false,
              speed: false, reset: probe.resetAvailable ? .hook : .none,
              screenshot: false, fields: true, actions: true,
              projectRegistration: false)
    }

    public static func notices() -> [GameDeveloperNotice] {
        [.init(code: "guest-file-bridge",
               message: "The RGSS overlay is a bounded file RPC; no Ruby evaluator or host filesystem mount is exposed.",
               messageZhHans: "RGSS 覆盖层是有界文件 RPC；不暴露 Ruby 求值器或宿主文件系统挂载。"),
         .init(code: "snapshot-scope",
               message: "Checkpoints restore gold, party levels/HP/SP/MP, item counts, primitive variables/switches and map position within bounded ranges. They are game debug-state checkpoints, not an engine save file or opaque script state.",
               messageZhHans: "检查点恢复金钱、队伍等级/HP/SP/MP、物品数量、原始类型变量/开关和地图位置（有界范围）。它们是游戏调试状态检查点，不是引擎存档或不透明脚本状态。")]
    }
}
