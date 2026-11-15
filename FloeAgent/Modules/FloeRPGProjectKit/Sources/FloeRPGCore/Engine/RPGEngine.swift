// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// RPG Maker engine/version targets with on-device data adapters.
public enum RPGEngine: String, CaseIterable, Sendable {
    case rpgMakerXP
    case rpgMakerVX
    case rpgMakerVXAce
    case rpgMakerMV
    case rpgMakerMZ

    public var gameEngineID: GameEngineID {
        switch self {
        case .rpgMakerXP: return .rpgMakerXP
        case .rpgMakerVX: return .rpgMakerVX
        case .rpgMakerVXAce: return .rpgMakerVXAce
        case .rpgMakerMV: return .rpgMakerMV
        case .rpgMakerMZ: return .rpgMakerMZ
        }
    }

    /// Binary data file extension for the Ruby-Marshal engines.
    public var marshalExtension: String? {
        switch self {
        case .rpgMakerXP: return "rxdata"
        case .rpgMakerVX: return "rvdata"
        case .rpgMakerVXAce: return "rvdata2"
        case .rpgMakerMV, .rpgMakerMZ: return nil
        }
    }

    public var usesJSONData: Bool {
        marshalExtension == nil
    }

    /// Tile grid size in pixels (editor DTO geometry).
    public var tileSize: Int {
        switch self {
        case .rpgMakerMV, .rpgMakerMZ: return 48
        default: return 32
        }
    }

    /// Number of editable tile layers. XP/VX/VX Ace maps store three z-layers
    /// in their Table; MV/MZ maps store four visible tile layers.
    public var defaultTileLayers: Int {
        switch self {
        case .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce: return 3
        case .rpgMakerMV, .rpgMakerMZ: return 4
        }
    }

    /// Channels in an MV/MZ map `data` array: 4 tile layers + shadow bits +
    /// region ids. Only the first four are tile-editable; the rest are
    /// preserved untouched by tile editing.
    public var mapDataChannels: Int {
        switch self {
        case .rpgMakerMV, .rpgMakerMZ: return 6
        default: return defaultTileLayers
        }
    }
}

/// Classification of the standard RPG Maker data files.
public enum RPGDataFileKind: String, Sendable {
    case actors, classes, skills, items, weapons, armors, enemies, troops
    case states, animations, tilesets, commonEvents, system, map, scripts
    case other
}

public extension RPGDataFileKind {
    /// Maps a project-relative data path to a file kind for an engine.
    static func classify(_ path: String, engine: RPGEngine) -> RPGDataFileKind {
        let file = path.split(separator: "/").last.map(String.init) ?? path
        let stem = file.split(separator: ".").first.map(String.init) ?? file
        let lower = stem.lowercased()
        if lower == "scripts" { return .scripts }
        if lower == "system" { return .system }
        if lower.hasPrefix("map") {
            guard lower != "mapinfos" else { return .other }
            return .map
        }
        switch lower {
        case "actors": return .actors
        case "classes": return .classes
        case "skills": return .skills
        case "items": return .items
        case "weapons": return .weapons
        case "armors": return .armors
        case "enemies": return .enemies
        case "troops": return .troops
        case "states": return .states
        case "animations": return .animations
        case "tilesets": return .tilesets
        case "commonevents": return .commonEvents
        default: return .other
        }
    }

    /// Standard data file name (without extension) for this kind, if fixed.
    var standardName: String? {
        switch self {
        case .actors: return "Actors"
        case .classes: return "Classes"
        case .skills: return "Skills"
        case .items: return "Items"
        case .weapons: return "Weapons"
        case .armors: return "Armors"
        case .enemies: return "Enemies"
        case .troops: return "Troops"
        case .states: return "States"
        case .animations: return "Animations"
        case .tilesets: return "Tilesets"
        case .commonEvents: return "CommonEvents"
        case .system: return "System"
        case .scripts: return "Scripts"
        case .map, .other: return nil
        }
    }
}
