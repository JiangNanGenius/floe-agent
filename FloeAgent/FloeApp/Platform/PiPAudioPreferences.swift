// FloeApp — persisted preferences for the task PiP sound surface.
//
// SPDX-License-Identifier: MPL-2.0
//
// The picture-in-picture run surface can carry real audio: an ambient loop,
// generic task-stage speech and short attention cues. Each channel has its
// own switch and gain so the user composes exactly what they hear. Values
// persist as one versioned JSON object through the SettingsStore
// (`app_settings`) so a partially written surface can never mix generations.

import Foundation
import FloeCore

/// The ambient loop the user picks for the PiP surface. Both sounds are
/// generated locally from a deterministic seed (no network, no bundled
/// assets, no third-party licence) and are audibly distinct.
enum PiPAmbientSound: String, Codable, Sendable, CaseIterable {
    case rain
    case brownNoise

    var localizationKey: String {
        switch self {
        case .rain: "pip.audio.sound.rain"
        case .brownNoise: "pip.audio.sound.brown"
        }
    }

    var title: String { FloeL10n.l(localizationKey) }

    /// Unknown stored values decode to the default sound instead of failing
    /// the whole preference object.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PiPAmbientSound(rawValue: raw) ?? .rain
    }
}

/// Versioned PiP sound preferences. Field additions must keep decoding old
/// versions (provide defaults) and must bump `currentVersion` only when an
/// actual migration is required; `normalized` clamps stored values so a
/// corrupted record can never drive the audio backend out of range.
struct PiPAudioPreferences: Codable, Equatable, Sendable {
    /// Persisted schema version. Version 1 is the first shipped shape.
    static let currentVersion = 1
    /// The single `app_settings` key carrying the whole object atomically.
    static let settingsKey = "pip.audio.preferences.v1"

    var version: Int = PiPAudioPreferences.currentVersion
    /// Ambient sound: independent switch, default on.
    var ambientEnabled: Bool = true
    /// Which generated loop plays.
    var ambientSound: PiPAmbientSound = .rain
    /// Ambient gain 0…1. The feature ships muted: 0 means the loop is
    /// really playing, just silent, so raising it is instant.
    var ambientGain: Double = 0
    /// Generic task-stage speech: independent switch, default off.
    var taskSpeechEnabled: Bool = false
    /// Speech volume 0…1 (AVSpeechUtterance volume scale).
    var taskSpeechGain: Double = 0.7
    /// Short attention/terminal cues: independent switch, default off.
    /// Cues share the narration volume channel.
    var cuesEnabled: Bool = false

    init() {}

    init(
        ambientEnabled: Bool,
        ambientSound: PiPAmbientSound,
        ambientGain: Double,
        taskSpeechEnabled: Bool,
        taskSpeechGain: Double,
        cuesEnabled: Bool
    ) {
        self.ambientEnabled = ambientEnabled
        self.ambientSound = ambientSound
        self.ambientGain = ambientGain
        self.taskSpeechEnabled = taskSpeechEnabled
        self.taskSpeechGain = taskSpeechGain
        self.cuesEnabled = cuesEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case ambientEnabled
        case ambientSound
        case ambientGain
        case taskSpeechEnabled
        case taskSpeechGain
        case cuesEnabled
    }

    /// Lenient decoding: a record written by an older (or partially
    /// corrupted) version repairs field-by-field from the shipping defaults
    /// instead of failing the whole object. `normalized` then clamps ranges.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PiPAudioPreferences()
        version = (try? container.decode(Int.self, forKey: .version)) ?? defaults.version
        ambientEnabled = (try? container.decode(Bool.self, forKey: .ambientEnabled))
            ?? defaults.ambientEnabled
        ambientSound = (try? container.decode(PiPAmbientSound.self, forKey: .ambientSound))
            ?? defaults.ambientSound
        ambientGain = (try? container.decode(Double.self, forKey: .ambientGain))
            ?? defaults.ambientGain
        taskSpeechEnabled = (try? container.decode(Bool.self, forKey: .taskSpeechEnabled))
            ?? defaults.taskSpeechEnabled
        taskSpeechGain = (try? container.decode(Double.self, forKey: .taskSpeechGain))
            ?? defaults.taskSpeechGain
        cuesEnabled = (try? container.decode(Bool.self, forKey: .cuesEnabled))
            ?? defaults.cuesEnabled
    }

    /// Clamp every user-facing range after decode or direct mutation before
    /// persistence/use. Out-of-range stored data repairs itself silently;
    /// the backend never receives NaN or >1.0 gains.
    var normalized: Self {
        var copy = self
        copy.version = Self.currentVersion
        copy.ambientGain = Self.clamp(copy.ambientGain, to: 0...1, fallback: 0)
        copy.taskSpeechGain = Self.clamp(copy.taskSpeechGain, to: 0...1, fallback: 0.7)
        return copy
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}
