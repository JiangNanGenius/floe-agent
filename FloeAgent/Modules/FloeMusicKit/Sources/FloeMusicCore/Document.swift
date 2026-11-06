import Foundation

/// The canonical, versioned music document: the single source of truth for a
/// music project. Edits never mutate a committed document in place; the store
/// produces a new value with a monotonically increased `revision`.
///
/// Decoding re-runs every constructor rule plus cross-field validation
/// (identity uniqueness, clip/track kind matching, asset bounds, overlap and
/// routing acyclicity), so a malformed payload can never produce a document.
public struct MusicDocument: Sendable, Codable, Hashable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: MusicProjectID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Monotonic commit sequence; every committed batch (including undo/redo)
    /// advances this exactly once, so a revision never aliases two states.
    public var revision: Int64
    public var tempoMap: MusicTempoMap
    public var assets: [MusicAsset]
    public var tracks: [MusicTrack]
    public var buses: [MusicBus]
    public var masterStrip: MusicStripSettings
    public var automationLanes: [MusicAutomationLane]

    /// Designated throwing initializer. `schemaVersion` is a parameter so the
    /// decoder can route persisted values through the same strict check.
    public init(schemaVersion: Int = Self.currentSchemaVersion,
                id: MusicProjectID = MusicProjectID(), name: String,
                createdAt: Date = Date(), updatedAt: Date = Date(), revision: Int64 = 0,
                tempoMap: MusicTempoMap = try! MusicTempoMap(segments: [
                    try! MusicTempoSegment(startTick: MusicTick(0), bpm: 120,
                                           beatsPerBar: 4, beatUnit: 4)
                ]),
                assets: [MusicAsset] = [], tracks: [MusicTrack] = [],
                buses: [MusicBus] = [],
                masterStrip: MusicStripSettings = try! MusicStripSettings(),
                automationLanes: [MusicAutomationLane] = []) throws {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.tempoMap = tempoMap
        self.assets = assets
        self.tracks = tracks
        self.buses = buses
        self.masterStrip = masterStrip
        self.automationLanes = automationLanes
        try validate()
    }

    /// Full validation. The decoder and every edit batch call this; passing
    /// it is the definition of a well-formed document.
    ///
    /// Nested model types expose mutable fields for drafting convenience, so
    /// this method does not trust prior construction: it re-runs every
    /// throwing constructor on the current values (tempo map and segments,
    /// assets, strips, plugin states, clip payloads, MIDI notes and
    /// controllers, automation lanes and points) before cross-field checks.
    /// Any host entrypoint that commits, renders or hands state to a session
    /// must go through here.
    public func validate() throws {
        // No historical-version migration exists yet: the document must carry
        // exactly the current schema version (rejects zero/negative, older
        // and newer payloads rather than guessing).
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MusicError.invalidBatch(reason: "unsupported schemaVersion \(schemaVersion)")
        }
        guard revision >= 0 else {
            throw MusicError.invalidBatch(reason: "negative revision")
        }
        // Deep revalidation of nested mutable state.
        _ = try MusicTempoMap(ticksPerQuarter: tempoMap.ticksPerQuarter,
                              sampleRate: tempoMap.sampleRate,
                              segments: tempoMap.segments)
        for asset in assets {
            _ = try MusicAsset(id: asset.id, sourceLocator: asset.sourceLocator,
                               contentHashAlgorithm: asset.contentHashAlgorithm,
                               contentHash: asset.contentHash,
                               sourceRevision: asset.sourceRevision, kind: asset.kind,
                               durationSamples: asset.durationSamples, name: asset.name,
                               provenance: asset.provenance)
        }
        for lane in automationLanes {
            _ = try MusicAutomationLane(id: lane.id, ownerID: lane.ownerID, target: lane.target,
                                        parameterKey: lane.parameterKey, points: lane.points)
            for point in lane.points {
                _ = try MusicAutomationPoint(sample: point.sample, value: point.value)
            }
        }
        var seenAssetIDs = Set<MusicAssetID>()
        for asset in assets {
            guard seenAssetIDs.insert(asset.id).inserted else {
                throw MusicError.invalidAsset(reason: "duplicate asset id \(asset.id)")
            }
        }
        var seenTrackIDs = Set<MusicTrackID>()
        var seenClipIDs = Set<MusicClipID>()
        for track in tracks {
            // Revalidate strip, instrument and effects against public mutation.
            _ = try MusicStripSettings(gain: track.strip.gain, pan: track.strip.pan,
                                       muted: track.strip.muted, soloed: track.strip.soloed,
                                       recordArmed: track.strip.recordArmed,
                                       inputMonitoring: track.strip.inputMonitoring)
            if let instrument = track.instrument {
                _ = try MusicPluginState(pluginID: instrument.pluginID, enabled: instrument.enabled,
                                         presetIndex: instrument.presetIndex,
                                         parameters: instrument.parameters, stateBlob: instrument.stateBlob)
            }
            for effect in track.effects {
                _ = try MusicPluginState(pluginID: effect.pluginID, enabled: effect.enabled,
                                         presetIndex: effect.presetIndex,
                                         parameters: effect.parameters, stateBlob: effect.stateBlob)
            }
            _ = try MusicTrack(id: track.id, name: track.name, kind: track.kind, clips: track.clips,
                               strip: track.strip, instrument: track.instrument, effects: track.effects,
                               outputBusID: track.outputBusID, sends: track.sends)
            guard seenTrackIDs.insert(track.id).inserted else {
                throw MusicError.invalidTrack(reason: "duplicate track id \(track.id)")
            }
            // Clips on one track MAY overlap: layered/spliced arrangement with
            // additive mixing is standard DAW behaviour and is required by the
            // approved crossfade/splice scope. Bounds are validated per clip
            // (asset duration, fades, note containment) instead of rejecting
            // overlaps globally.
            for clip in track.clips {
                // Revalidate clip and payload against public mutation.
                switch clip.body {
                case .audio(let payload):
                    _ = try MusicAudioClipPayload(assetID: payload.assetID,
                                                  trimStartSamples: payload.trimStartSamples,
                                                  durationSamples: payload.durationSamples,
                                                  fadeInSamples: payload.fadeInSamples,
                                                  fadeOutSamples: payload.fadeOutSamples,
                                                  gain: payload.gain, pan: payload.pan)
                case .midi(let payload):
                    var revalidatedNotes: [MusicMIDINote] = []
                    for note in payload.notes {
                        _ = try MusicMIDINote(id: note.id, pitch: note.pitch, startTick: note.startTick,
                                              durationTicks: note.durationTicks, velocity: note.velocity,
                                              channel: note.channel)
                        let (end, overflow) = note.startTick.value.addingReportingOverflow(note.durationTicks)
                        if overflow {
                            throw MusicError.invalidMIDI(
                                reason: "note \(note.id) start+duration overflows Int64")
                        }
                        if end > payload.durationTicks {
                            throw MusicError.invalidMIDI(
                                reason: "note ends at tick \(end), past clip length \(payload.durationTicks)")
                        }
                        revalidatedNotes.append(note)
                    }
                    for point in payload.controllerPoints {
                        _ = try MusicMIDIControllerPoint(controller: point.controller,
                                                         tick: point.tick, value: point.value)
                    }
                    _ = try MusicMIDIClipPayload(durationTicks: payload.durationTicks,
                                                 notes: revalidatedNotes,
                                                 controllerPoints: payload.controllerPoints)
                }
                _ = try MusicClip(id: clip.id, name: clip.name, trackID: clip.trackID,
                                  offset: clip.offset, body: clip.body)
                guard clip.trackID == track.id else {
                    throw MusicError.invalidClip(
                        reason: "clip \(clip.id) claims track \(clip.trackID) but lives on \(track.id)")
                }
                guard seenClipIDs.insert(clip.id).inserted else {
                    throw MusicError.invalidClip(reason: "duplicate clip id \(clip.id)")
                }
                switch clip.body {
                case .audio(let payload):
                    guard track.kind == .audio else {
                        throw MusicError.invalidClip(reason: "audio clip on MIDI track \(track.id)")
                    }
                    if let asset = assets.first(where: { $0.id == payload.assetID }) {
                        switch asset.kind {
                        case .audioPCM, .audioMP3, .audioM4A, .unsupportedRaw:
                            break // unknown audio kinds are still audio payloads
                        case .midiFile:
                            throw MusicError.invalidClip(reason: "audio clip references MIDI asset \(asset.id)")
                        }
                        if asset.durationSamples.value > 0 {
                            let (readEnd, overflow) =
                                payload.trimStartSamples.addingReportingOverflow(payload.durationSamples)
                            if overflow || readEnd > asset.durationSamples.value {
                                throw MusicError.invalidClip(
                                    reason: "clip \(clip.id) reads past asset \(asset.id) duration")
                            }
                        }
                    } else {
                        throw MusicError.invalidClip(reason: "clip references unknown asset \(payload.assetID)")
                    }
                case .midi(let payload):
                    guard track.kind == .midi else {
                        throw MusicError.invalidClip(reason: "MIDI clip on audio track \(track.id)")
                    }
                    // MIDI clip duration must convert through the tempo map;
                    // this also guards mutated/overflowing tick lengths.
                    _ = try clip.endSample(tempoMap: tempoMap)
                }
            }
        }
        for bus in buses {
            _ = try MusicBus(id: bus.id, name: bus.name, strip: bus.strip,
                             effects: bus.effects, sends: bus.sends)
        }
        _ = try MusicStripSettings(gain: masterStrip.gain, pan: masterStrip.pan,
                                   muted: masterStrip.muted, soloed: masterStrip.soloed,
                                   recordArmed: masterStrip.recordArmed,
                                   inputMonitoring: masterStrip.inputMonitoring)
        try validateRouting()
        // Automation owners must resolve.
        for lane in automationLanes {
            let known = tracks.contains(where: { $0.id.rawValue == lane.ownerID })
                || buses.contains(where: { $0.id.rawValue == lane.ownerID })
                || lane.ownerID == MusicBus.masterBusID.rawValue
            guard known else {
                throw MusicError.invalidAutomation(reason: "automation owner \(lane.ownerID) does not exist")
            }
        }
    }

    /// Bus routing graph must be acyclic.
    public func validateRouting() throws {
        var busIDs = Set(buses.map { $0.id })
        guard busIDs.count == buses.count, !busIDs.contains(MusicBus.masterBusID) else {
            throw MusicError.invalidMixer(reason: "duplicate or reserved bus id")
        }
        busIDs.insert(MusicBus.masterBusID)
        for track in tracks {
            guard busIDs.contains(track.outputBusID), track.sends.allSatisfy({ busIDs.contains($0.busID) }) else {
                throw MusicError.invalidMixer(reason: "track routes to an unknown bus")
            }
        }
        var edges: [MusicBus.MusicBusID: [MusicBus.MusicBusID]] = [:]
        for bus in buses {
            for send in bus.sends {
                guard busIDs.contains(send) else {
                    throw MusicError.invalidMixer(reason: "bus \(bus.id) sends to unknown bus \(send)")
                }
                edges[bus.id, default: []].append(send)
            }
        }
        var visiting = Set<MusicBus.MusicBusID>()
        var done = Set<MusicBus.MusicBusID>()
        func dfs(_ node: MusicBus.MusicBusID, path: [MusicBus.MusicBusID]) throws {
            if done.contains(node) { return }
            if visiting.contains(node) {
                throw MusicError.invalidMixer(reason: "routing cycle: \(path.map(\.rawValue).joined(separator: " -> ")) -> \(node.rawValue)")
            }
            visiting.insert(node)
            for next in edges[node] ?? [] {
                try dfs(next, path: path + [node])
            }
            visiting.remove(node)
            done.insert(node)
        }
        for id in busIDs { try dfs(id, path: []) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        let id = try c.decode(MusicProjectID.self, forKey: .id)
        let name = try c.decode(String.self, forKey: .name)
        let createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        let updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        let revision = try c.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
        let tempoMap = try c.decode(MusicTempoMap.self, forKey: .tempoMap)
        let assets = try c.decodeIfPresent([MusicAsset].self, forKey: .assets) ?? []
        let tracks = try c.decodeIfPresent([MusicTrack].self, forKey: .tracks) ?? []
        let buses = try c.decodeIfPresent([MusicBus].self, forKey: .buses) ?? []
        let master = try c.decodeIfPresent(MusicStripSettings.self, forKey: .masterStrip) ?? (try! MusicStripSettings())
        let lanes = try c.decodeIfPresent([MusicAutomationLane].self, forKey: .automationLanes) ?? []
        do {
            try self.init(schemaVersion: schemaVersion, id: id, name: name,
                          createdAt: createdAt, updatedAt: updatedAt,
                          revision: revision, tempoMap: tempoMap, assets: assets,
                          tracks: tracks, buses: buses, masterStrip: master,
                          automationLanes: lanes)
        } catch let error as MusicError {
            throw DecodingError.dataCorruptedError(forKey: .tracks, in: c,
                                                   debugDescription: error.description)
        }
    }
}
