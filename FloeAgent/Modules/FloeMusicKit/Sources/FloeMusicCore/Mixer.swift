import Foundation

/// A mixer bus (aux/effect/group bus). Tracks and buses route into buses;
/// every route ultimately terminates at the master bus.
public struct MusicBus: Sendable, Codable, Hashable, Identifiable {
    public static let masterBusID = MusicBusID(rawValue: "master")

    /// Typed bus ID.
    public struct MusicBusID: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
        public let rawValue: String
        public var id: String { rawValue }
        public init(rawValue: String) {
            precondition(!rawValue.isEmpty, "MusicBusID rawValue must be non-empty")
            self.rawValue = rawValue
        }
        public var description: String { rawValue }
    }

    public var id: MusicBusID
    public var name: String
    public var strip: MusicStripSettings
    public var effects: [MusicPluginState]
    /// Buses this bus feeds into. Must stay acyclic (validated at document level).
    public var sends: [MusicBusID]

    public init(id: MusicBusID, name: String,
                strip: MusicStripSettings = try! MusicStripSettings(),
                effects: [MusicPluginState] = [], sends: [MusicBusID] = []) throws {
        guard effects.count <= MusicTrack.maxEffectsPerTrack else {
            throw MusicError.boundsExceeded(field: "busEffects",
                                            limit: MusicTrack.maxEffectsPerTrack)
        }
        _ = try MusicStripSettings(gain: strip.gain, pan: strip.pan, muted: strip.muted, soloed: strip.soloed,
                                   recordArmed: strip.recordArmed, inputMonitoring: strip.inputMonitoring)
        for effect in effects {
            _ = try MusicPluginState(pluginID: effect.pluginID, enabled: effect.enabled, presetIndex: effect.presetIndex,
                                     parameters: effect.parameters, stateBlob: effect.stateBlob)
        }
        self.id = id
        self.name = name
        self.strip = strip
        self.effects = effects
        self.sends = sends
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(MusicBusID.self, forKey: .id)
        let name = try c.decode(String.self, forKey: .name)
        let strip = try c.decodeIfPresent(MusicStripSettings.self, forKey: .strip) ?? (try! MusicStripSettings())
        let effects = try c.decodeIfPresent([MusicPluginState].self, forKey: .effects) ?? []
        let sends = try c.decodeIfPresent([MusicBusID].self, forKey: .sends) ?? []
        do {
            try self.init(id: id, name: name, strip: strip, effects: effects, sends: sends)
        } catch let error as MusicError {
            throw DecodingError.dataCorruptedError(forKey: .effects, in: c,
                                                   debugDescription: error.description)
        }
    }
}

/// What an automation lane drives. Parameter values are normalized 0...1 and
/// interpreted by the host runtime against the concrete target.
public enum MusicAutomationTarget: String, Sendable, Codable, Hashable {
    case trackGain
    case trackPan
    case pluginParameter
    case busGain
    case crossfade
}

public struct MusicAutomationPoint: Sendable, Codable, Hashable {
    public var sample: MusicSampleTime
    /// Normalized value 0...1.
    public var value: Double

    public init(sample: MusicSampleTime, value: Double) throws {
        guard sample.value >= 0 else {
            throw MusicError.invalidAutomation(reason: "negative automation sample")
        }
        guard value.isFinite, value >= 0, value <= 1 else {
            throw MusicError.invalidAutomation(reason: "automation value \(value) outside [0, 1]")
        }
        self.sample = sample
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let s = try c.decode(MusicSampleTime.self, forKey: .sample)
        let v = try c.decode(Double.self, forKey: .value)
        do {
            try self.init(sample: s, value: v)
        } catch let error as MusicError {
            throw DecodingError.dataCorruptedError(forKey: .value, in: c,
                                                   debugDescription: error.description)
        }
    }
}

/// A bounded automation lane over one target of one owner (track/bus/plugin).
public struct MusicAutomationLane: Sendable, Codable, Hashable, Identifiable {
    public static let maxPointsPerLane = 100_000

    public var id: String
    public var ownerID: String
    public var target: MusicAutomationTarget
    /// Free-form parameter name for `.pluginParameter` targets.
    public var parameterKey: String?
    public var points: [MusicAutomationPoint]

    public init(id: String = UUID().uuidString.lowercased(), ownerID: String,
                target: MusicAutomationTarget, parameterKey: String? = nil,
                points: [MusicAutomationPoint] = []) throws {
        guard !ownerID.isEmpty else {
            throw MusicError.invalidAutomation(reason: "empty ownerID")
        }
        guard points.count <= Self.maxPointsPerLane else {
            throw MusicError.boundsExceeded(field: "automationPoints", limit: Self.maxPointsPerLane)
        }
        if target == .pluginParameter {
            guard let key = parameterKey, !key.isEmpty else {
                throw MusicError.invalidAutomation(reason: "pluginParameter target requires parameterKey")
            }
        }
        for i in points.indices.dropFirst() where points[i].sample.value <= points[i - 1].sample.value {
            throw MusicError.invalidAutomation(reason: "automation points must have strictly increasing sample positions")
        }
        self.id = id
        self.ownerID = ownerID
        self.target = target
        self.parameterKey = parameterKey
        self.points = points
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        let owner = try c.decode(String.self, forKey: .ownerID)
        let target = try c.decode(MusicAutomationTarget.self, forKey: .target)
        let key = try c.decodeIfPresent(String.self, forKey: .parameterKey)
        let points = try c.decodeIfPresent([MusicAutomationPoint].self, forKey: .points) ?? []
        do {
            try self.init(id: id, ownerID: owner, target: target, parameterKey: key, points: points)
        } catch let error as MusicError {
            throw DecodingError.dataCorruptedError(forKey: .points, in: c,
                                                   debugDescription: error.description)
        }
    }
}
