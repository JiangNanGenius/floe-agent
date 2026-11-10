import Foundation

/// Opaque instrument/effect plugin state. `parameters` holds typed, known
/// parameters; `stateBlob` preserves the host/plugin-native state verbatim so
/// unsupported or future plugins survive decode/re-encode without loss.
public struct MusicPluginState: Sendable, Codable, Hashable {
    /// Stable plugin identifier (e.g. Audio Unit component description string).
    public var pluginID: String
    public var enabled: Bool
    /// Program/preset index when known.
    public var presetIndex: Int
    /// Named parameter values. The core does not interpret them.
    public var parameters: [String: Double]
    /// Plugin-native state bytes preserved verbatim.
    public var stateBlob: Data

    public init(pluginID: String, enabled: Bool = true, presetIndex: Int = 0,
                parameters: [String: Double] = [:], stateBlob: Data = Data()) throws {
        guard !pluginID.isEmpty else {
            throw MusicError.invalidTrack(reason: "empty pluginID")
        }
        guard presetIndex >= 0 else {
            throw MusicError.invalidTrack(reason: "negative presetIndex")
        }
        for (key, value) in parameters {
            guard !key.isEmpty else {
                throw MusicError.invalidTrack(reason: "empty parameter key")
            }
            guard value.isFinite else {
                throw MusicError.invalidTrack(reason: "non-finite value for parameter \(key)")
            }
        }
        self.pluginID = pluginID
        self.enabled = enabled
        self.presetIndex = presetIndex
        self.parameters = parameters
        self.stateBlob = stateBlob
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .pluginID)
        let enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let preset = try c.decodeIfPresent(Int.self, forKey: .presetIndex) ?? 0
        let params = try c.decodeIfPresent([String: Double].self, forKey: .parameters) ?? [:]
        let blob = try c.decodeIfPresent(Data.self, forKey: .stateBlob) ?? Data()
        do {
            try self.init(pluginID: id, enabled: enabled, presetIndex: preset,
                          parameters: params, stateBlob: blob)
        } catch let error as MusicError {
            throw DecodingError.dataCorruptedError(forKey: .pluginID, in: c,
                                                   debugDescription: error.description)
        }
    }
}

/// Per-track strip/mixer settings.
public struct MusicStripSettings: Sendable, Codable, Hashable {
    /// Linear gain 0...16 (0 = silence, 1 = unity, ~+24 dB max).
    public static let maxGain: Double = 16

    public var gain: Double
    /// Stereo pan -1 (full left) ... 1 (full right); 0 = center.
    public var pan: Double
    public var muted: Bool
    public var soloed: Bool
    public var recordArmed: Bool
    public var inputMonitoring: Bool

    public init(gain: Double = 1, pan: Double = 0, muted: Bool = false,
                soloed: Bool = false, recordArmed: Bool = false,
                inputMonitoring: Bool = false) throws {
        guard gain.isFinite, gain >= 0, gain <= Self.maxGain else {
            throw MusicError.invalidMixer(reason: "gain \(gain) outside [0, \(Self.maxGain)]")
        }
        guard pan.isFinite, pan >= -1, pan <= 1 else {
            throw MusicError.invalidMixer(reason: "pan \(pan) outside [-1, 1]")
        }
        self.gain = gain
        self.pan = pan
        self.muted = muted
        self.soloed = soloed
        self.recordArmed = recordArmed
        self.inputMonitoring = inputMonitoring
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? 1
        let pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        let muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        let soloed = try c.decodeIfPresent(Bool.self, forKey: .soloed) ?? false
        let armed = try c.decodeIfPresent(Bool.self, forKey: .recordArmed) ?? false
        let monitor = try c.decodeIfPresent(Bool.self, forKey: .inputMonitoring) ?? false
        do {
            try self.init(gain: gain, pan: pan, muted: muted, soloed: soloed,
                          recordArmed: armed, inputMonitoring: monitor)
        } catch let error as MusicError {
            throw DecodingError.dataCorruptedError(forKey: .gain, in: c,
                                                   debugDescription: error.description)
        }
    }
}

/// Audio clip payload: an immutable asset reference placed on a timeline with
/// trim, duration, fades, gain and pan.
public struct MusicAudioClipPayload: Sendable, Codable, Hashable {
    public var assetID: MusicAssetID
    /// In-point into the source asset, in samples.
    public var trimStartSamples: Int64
    /// Audible length on the timeline, in samples.
    public var durationSamples: Int64
    public var fadeInSamples: Int64
    public var fadeOutSamples: Int64
    /// Clip gain multiplier 0...16.
    public var gain: Double
    public var pan: Double

    public init(assetID: MusicAssetID, trimStartSamples: Int64 = 0, durationSamples: Int64,
                fadeInSamples: Int64 = 0, fadeOutSamples: Int64 = 0,
                gain: Double = 1, pan: Double = 0) throws {
        guard trimStartSamples >= 0 else {
            throw MusicError.invalidClip(reason: "negative trimStartSamples")
        }
        guard durationSamples > 0 else {
            throw MusicError.invalidClip(reason: "audio clip duration must be positive")
        }
        guard fadeInSamples >= 0, fadeOutSamples >= 0 else {
            throw MusicError.invalidClip(reason: "fade lengths must be non-negative")
        }
        guard fadeInSamples + fadeOutSamples <= durationSamples else {
            throw MusicError.invalidClip(reason: "fadeIn + fadeOut exceeds clip duration")
        }
        guard gain.isFinite, gain >= 0, gain <= MusicStripSettings.maxGain else {
            throw MusicError.invalidClip(reason: "clip gain \(gain) outside [0, \(MusicStripSettings.maxGain)]")
        }
        guard pan.isFinite, pan >= -1, pan <= 1 else {
            throw MusicError.invalidClip(reason: "clip pan \(pan) outside [-1, 1]")
        }
        self.assetID = assetID
        self.trimStartSamples = trimStartSamples
        self.durationSamples = durationSamples
        self.fadeInSamples = fadeInSamples
        self.fadeOutSamples = fadeOutSamples
        self.gain = gain
        self.pan = pan
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let asset = try c.decode(MusicAssetID.self, forKey: .assetID)
        let trim = try c.decodeIfPresent(Int64.self, forKey: .trimStartSamples) ?? 0
        let dur = try c.decode(Int64.self, forKey: .durationSamples)
        let fin = try c.decodeIfPresent(Int64.self, forKey: .fadeInSamples) ?? 0
        let fout = try c.decodeIfPresent(Int64.self, forKey: .fadeOutSamples) ?? 0
        let gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? 1
        let pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        do {
            try self.init(assetID: asset, trimStartSamples: trim, durationSamples: dur,
                          fadeInSamples: fin, fadeOutSamples: fout, gain: gain, pan: pan)
        } catch let error as MusicError {
            throw DecodingError.dataCorruptedError(forKey: .durationSamples, in: c,
                                                   debugDescription: error.description)
        }
    }
}

/// MIDI clip payload: bounded notes and controller points.
public struct MusicMIDIClipPayload: Sendable, Codable, Hashable {
    public static let maxNotesPerClip = 100_000
    public static let maxControllerPoints = 50_000

    /// Clip length in ticks. Every note must fit inside this length.
    public var durationTicks: Int64
    public var notes: [MusicMIDINote]
    public var controllerPoints: [MusicMIDIControllerPoint]
    public var programChanges: [MusicMIDIProgramChange]

    public init(durationTicks: Int64, notes: [MusicMIDINote] = [],
                controllerPoints: [MusicMIDIControllerPoint] = [], programChanges: [MusicMIDIProgramChange] = []) throws {
        guard durationTicks > 0 else {
            throw MusicError.invalidClip(reason: "MIDI clip duration must be positive")
        }
        guard notes.count <= Self.maxNotesPerClip else {
            throw MusicError.boundsExceeded(field: "notes", limit: Self.maxNotesPerClip)
        }
        guard controllerPoints.count <= Self.maxControllerPoints else {
            throw MusicError.boundsExceeded(field: "controllerPoints", limit: Self.maxControllerPoints)
        }
        guard programChanges.count <= Self.maxControllerPoints else { throw MusicError.boundsExceeded(field: "programChanges", limit: Self.maxControllerPoints) }
        for note in notes {
            let (end, overflow) = note.startTick.value.addingReportingOverflow(note.durationTicks)
            guard !overflow, end <= durationTicks else {
                throw MusicError.invalidMIDI(reason: "note ends at tick \(end), past clip length \(durationTicks)")
            }
        }
        for point in controllerPoints {
            _ = try MusicMIDIControllerPoint(controller: point.controller, tick: point.tick, value: point.value, channel: point.channel)
            guard point.tick.value <= durationTicks else { throw MusicError.invalidMIDI(reason: "controller outside clip") }
        }
        for change in programChanges {
            _ = try MusicMIDIProgramChange(tick: change.tick, channel: change.channel, program: change.program)
            guard change.tick.value <= durationTicks else { throw MusicError.invalidMIDI(reason: "program outside clip") }
        }
        // Preserve the legacy order for channel zero, distinguishing channels.
        for i in controllerPoints.indices.dropFirst() {
            let prev = controllerPoints[i - 1], cur = controllerPoints[i]
            guard (prev.controller, prev.channel, prev.tick.value) < (cur.controller, cur.channel, cur.tick.value) else {
                throw MusicError.invalidMIDI(reason: "controller points must be sorted by (controller, channel, tick)")
            }
        }
        for i in programChanges.indices.dropFirst() {
            let a = programChanges[i - 1], b = programChanges[i]
            guard (a.channel, a.tick.value) < (b.channel, b.tick.value) else { throw MusicError.invalidMIDI(reason: "program changes must be sorted by (channel, tick)") }
        }
        self.durationTicks = durationTicks
        self.notes = notes
        self.controllerPoints = controllerPoints
        self.programChanges = programChanges
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let dur = try c.decode(Int64.self, forKey: .durationTicks)
        let notes = try c.decodeIfPresent([MusicMIDINote].self, forKey: .notes) ?? []
        let points = try c.decodeIfPresent([MusicMIDIControllerPoint].self, forKey: .controllerPoints) ?? []
        let programs = try c.decodeIfPresent([MusicMIDIProgramChange].self, forKey: .programChanges) ?? []
        do {
            try self.init(durationTicks: dur, notes: notes, controllerPoints: points, programChanges: programs)
        } catch let error as MusicError {
            throw DecodingError.dataCorruptedError(forKey: .durationTicks, in: c,
                                                   debugDescription: error.description)
        }
    }
}

/// A timeline clip on a track. `offset` is the clip start in samples; the
/// body carries audio or MIDI content.
public struct MusicClip: Sendable, Codable, Hashable, Identifiable {
    public enum Body: Sendable, Codable, Hashable {
        case audio(MusicAudioClipPayload)
        case midi(MusicMIDIClipPayload)

        private enum CodingKeys: String, CodingKey { case kind, audio, midi }
        private enum Kind: String, Codable { case audio, midi }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try c.decode(Kind.self, forKey: .kind)
            switch kind {
            case .audio: self = .audio(try c.decode(MusicAudioClipPayload.self, forKey: .audio))
            case .midi: self = .midi(try c.decode(MusicMIDIClipPayload.self, forKey: .midi))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .audio(let payload):
                try c.encode(Kind.audio, forKey: .kind)
                try c.encode(payload, forKey: .audio)
            case .midi(let payload):
                try c.encode(Kind.midi, forKey: .kind)
                try c.encode(payload, forKey: .midi)
            }
        }
    }

    public var id: MusicClipID
    public var name: String
    public var trackID: MusicTrackID
    public var offset: MusicSampleTime
    public var body: Body

    public init(id: MusicClipID = MusicClipID(), name: String = "", trackID: MusicTrackID,
                offset: MusicSampleTime, body: Body) throws {
        guard offset.value >= 0 else {
            throw MusicError.invalidClip(reason: "negative clip offset")
        }
        self.id = id
        self.name = name
        self.trackID = trackID
        self.offset = offset
        self.body = body
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(MusicClipID.self, forKey: .id)
        let name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        let track = try c.decode(MusicTrackID.self, forKey: .trackID)
        let offset = try c.decode(MusicSampleTime.self, forKey: .offset)
        let body = try c.decode(Body.self, forKey: .body)
        do {
            try self.init(id: id, name: name, trackID: track, offset: offset, body: body)
        } catch let error as MusicError {
            throw DecodingError.dataCorruptedError(forKey: .offset, in: c,
                                                   debugDescription: error.description)
        }
    }

    /// Audible end of the clip in samples.
    public func endSample(tempoMap: MusicTempoMap) throws -> MusicSampleTime {
        switch body {
        case .audio(let payload):
            return try offset + MusicSampleTime(payload.durationSamples)
        case .midi(let payload):
            return try sample(atRelativeTick: payload.durationTicks, tempoMap: tempoMap)
        }
    }

    /// Relative musical time follows the tempo at the clip's absolute start.
    public func sample(atRelativeTick tick: Int64, tempoMap: MusicTempoMap) throws -> MusicSampleTime {
        guard tick >= 0 else { throw MusicError.invalidMIDI(reason: "negative relative tick") }
        let anchorTick = try tempoMap.tick(atSample: offset)
        let (endTick, overflow) = anchorTick.value.addingReportingOverflow(tick)
        guard !overflow else { throw MusicError.invalidMIDI(reason: "relative tick overflow") }
        let anchor = try tempoMap.sample(atTick: anchorTick)
        let end = try tempoMap.sample(atTick: MusicTick(endTick))
        return try offset + (end - anchor)
    }
}

public struct MusicTrackSend: Sendable, Codable, Hashable {
    public var busID: MusicBus.MusicBusID
    public var gain: Double
    public var preFader: Bool
    public init(busID: MusicBus.MusicBusID, gain: Double = 1, preFader: Bool = false) throws {
        guard !busID.rawValue.isEmpty, gain.isFinite, gain >= 0, gain <= MusicStripSettings.maxGain else {
            throw MusicError.invalidMixer(reason: "invalid track send")
        }
        self.busID = busID
        self.gain = gain
        self.preFader = preFader
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(busID: c.decode(MusicBus.MusicBusID.self, forKey: .busID),
                      gain: c.decode(Double.self, forKey: .gain),
                      preFader: c.decodeIfPresent(Bool.self, forKey: .preFader) ?? false)
    }
}

/// A music track: audio or MIDI, with clips, strip settings, instrument and
/// insert effects.
public struct MusicTrack: Sendable, Codable, Hashable, Identifiable {
    public static let maxClipsPerTrack = 10_000
    public static let maxEffectsPerTrack = 16

    public enum Kind: String, Sendable, Codable, Hashable {
        case audio
        case midi
    }

    public var id: MusicTrackID
    public var name: String
    public var kind: Kind
    public var clips: [MusicClip]
    public var strip: MusicStripSettings
    /// Instrument assignment for MIDI tracks (audio tracks may set none).
    public var instrument: MusicPluginState?
    /// Insert effects, in processing order.
    public var effects: [MusicPluginState]
    public var outputBusID: MusicBus.MusicBusID
    public var sends: [MusicTrackSend]

    public init(id: MusicTrackID = MusicTrackID(), name: String, kind: Kind,
                clips: [MusicClip] = [], strip: MusicStripSettings = try! MusicStripSettings(),
                instrument: MusicPluginState? = nil, effects: [MusicPluginState] = [],
                outputBusID: MusicBus.MusicBusID = MusicBus.masterBusID,
                sends: [MusicTrackSend] = []) throws {
        guard clips.count <= Self.maxClipsPerTrack else {
            throw MusicError.boundsExceeded(field: "clips", limit: Self.maxClipsPerTrack)
        }
        guard effects.count <= Self.maxEffectsPerTrack else {
            throw MusicError.boundsExceeded(field: "effects", limit: Self.maxEffectsPerTrack)
        }
        self.id = id
        self.name = name
        self.kind = kind
        self.clips = clips
        self.strip = strip
        self.instrument = instrument
        self.effects = effects
        var destinations = Set<MusicBus.MusicBusID>()
        for send in sends {
            _ = try MusicTrackSend(busID: send.busID, gain: send.gain, preFader: send.preFader)
            guard destinations.insert(send.busID).inserted else { throw MusicError.invalidMixer(reason: "duplicate track send") }
        }
        self.outputBusID = outputBusID
        self.sends = sends
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(MusicTrackID.self, forKey: .id)
        let name = try c.decode(String.self, forKey: .name)
        let kind = try c.decode(Kind.self, forKey: .kind)
        let clips = try c.decodeIfPresent([MusicClip].self, forKey: .clips) ?? []
        let strip = try c.decodeIfPresent(MusicStripSettings.self, forKey: .strip) ?? (try! MusicStripSettings())
        let instrument = try c.decodeIfPresent(MusicPluginState.self, forKey: .instrument)
        let effects = try c.decodeIfPresent([MusicPluginState].self, forKey: .effects) ?? []
        do {
            try self.init(id: id, name: name, kind: kind, clips: clips, strip: strip,
                          instrument: instrument, effects: effects,
                          outputBusID: c.decodeIfPresent(MusicBus.MusicBusID.self, forKey: .outputBusID) ?? MusicBus.masterBusID,
                          sends: c.decodeIfPresent([MusicTrackSend].self, forKey: .sends) ?? [])
        } catch let error as MusicError {
            throw DecodingError.dataCorruptedError(forKey: .clips, in: c,
                                                   debugDescription: error.description)
        }
    }
}
