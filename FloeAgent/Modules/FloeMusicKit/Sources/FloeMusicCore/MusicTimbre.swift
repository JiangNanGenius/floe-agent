// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Portable, data-only parameters for the same synth used by playback and export.
public struct MusicTimbre: Hashable, Sendable, Codable {
    public static let synthID = "floe.synth"
    public static let maximumFileBytes = 16_384
    public let name: String
    public let presetIndex: Int
    public let parameters: [String: Double]

    public static let parameterRanges: [String: ClosedRange<Double>] = {
        var ranges: [String: ClosedRange<Double>] = [
            "waveform": 0...8, "attack": 0...99, "decay": 0...99,
            "sustain": 0...1, "release": 0...99, "gain": 0...1,
            "pulseWidth": 0.05...0.95, "fmRatio": 0.1...16, "fmIndex": 0...12,
            "transpose": -48...48, "fixedNote": -1...127, "detune": -50...50,
            "highpass": 0...20_000, "lowpass": 20...20_000
        ]
        for harmonic in 2...8 { ranges["harmonic\(harmonic)"] = 0...1 }
        return ranges
    }()

    public static func resolvedParameters(presetIndex: Int, overrides: [String: Double]) throws -> [String: Double] {
        guard let base = MusicPresetCatalog.preset(index: presetIndex) else {
            throw MusicError.invalidTrack(reason: "Unknown synth preset \(presetIndex)")
        }
        let values = base.parameters.merging(overrides) { _, new in new }
        for (key, value) in values {
            guard value.isFinite, parameterRanges[key]?.contains(value) == true else {
                throw MusicError.invalidTrack(reason: "Invalid synth parameter: \(key)")
            }
        }
        guard let waveform = values["waveform"], waveform.rounded() == waveform,
              (values["fixedNote"] ?? -1).rounded() == (values["fixedNote"] ?? -1),
              (values["highpass"] ?? 0) < (values["lowpass"] ?? 20_000) else {
            throw MusicError.invalidTrack(reason: "Invalid waveform, fixed note or filter range")
        }
        if waveform == 8 && !Set(overrides.keys).isSubset(of: ["waveform", "attack", "decay", "sustain", "release", "gain"]) {
            throw MusicError.invalidTrack(reason: "Unsupported drum kit parameter")
        }
        return values
    }

    public init(name: String, presetIndex: Int, parameters: [String: Double]) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 80, clean.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw MusicError.invalidTrack(reason: "Use a timbre name of 1–80 characters")
        }
        _ = try Self.resolvedParameters(presetIndex: presetIndex, overrides: parameters)
        self.name = clean
        self.presetIndex = presetIndex
        self.parameters = parameters
    }

    public init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(name: data.decode(String.self, forKey: .name),
                      presetIndex: data.decode(Int.self, forKey: .presetIndex),
                      parameters: data.decode([String: Double].self, forKey: .parameters))
    }

    public func instrument() throws -> MusicPluginState {
        try MusicPluginState(pluginID: Self.synthID, presetIndex: presetIndex, parameters: parameters, timbreName: name)
    }
}
