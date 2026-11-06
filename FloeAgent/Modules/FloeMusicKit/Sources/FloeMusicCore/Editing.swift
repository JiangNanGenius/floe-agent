import Foundation

/// One atomic document mutation. Every case carries fully formed, validated
/// values; `MusicProjectStore` re-validates the whole resulting document, so
/// an invalid op anywhere in a batch leaves the store untouched.
public enum MusicEditOp: Sendable, Hashable, Codable {
    case insertAsset(MusicAsset)
    case insertTrack(MusicTrack)
    case removeTrack(MusicTrackID)
    case renameTrack(MusicTrackID, String)
    case setStrip(MusicTrackID, MusicStripSettings)
    case setInstrument(MusicTrackID, MusicPluginState?)
    case setEffects(MusicTrackID, [MusicPluginState])
    case setTrackRouting(MusicTrackID, output: MusicBus.MusicBusID, sends: [MusicTrackSend])
    case insertClip(MusicClip)
    case removeClip(MusicClipID)
    case updateClip(MusicClip)
    case setTempo(atTick: MusicTick, bpm: Double, beatsPerBar: Int, beatUnit: Int)
    case setTempoMap(MusicTempoMap)
    case insertBus(MusicBus)
    case removeBus(MusicBus.MusicBusID)
    case setBusSends(MusicBus.MusicBusID, [MusicBus.MusicBusID])
    case upsertAutomationLane(MusicAutomationLane)
    case removeAutomationLane(String)
    case setName(String)
}

/// A draft-then-commit batch: a set of ops claimed against `baseRevision`.
/// The store applies all ops to a private draft, validates the whole draft,
/// and only then swaps it in — a failed batch changes nothing.
public struct MusicEditBatch: Sendable, Hashable {
    public var baseRevision: Int64
    public var author: String
    public var ops: [MusicEditOp]

    public init(baseRevision: Int64, author: String = "", ops: [MusicEditOp]) {
        self.baseRevision = baseRevision
        self.author = author
        self.ops = ops
    }
}

extension MusicDocument {
    /// Apply one op to a draft copy. Kind-matching and existence checks live
    /// here; value-level validation happened at construction and is re-run by
    /// `validate()` on the finished draft.
    mutating func apply(_ op: MusicEditOp) throws {
        switch op {
        case .insertAsset(let asset):
            guard !assets.contains(where: { $0.id == asset.id }) else {
                throw MusicError.invalidAsset(reason: "duplicate asset id \(asset.id)")
            }
            assets.append(asset)
        case .insertTrack(let track):
            guard !tracks.contains(where: { $0.id == track.id }) else {
                throw MusicError.invalidTrack(reason: "duplicate track id \(track.id)")
            }
            tracks.append(track)
        case .removeTrack(let id):
            guard let index = tracks.firstIndex(where: { $0.id == id }) else {
                throw MusicError.invalidTrack(reason: "unknown track \(id)")
            }
            tracks.remove(at: index)
            automationLanes.removeAll { $0.ownerID == id.rawValue }
        case .renameTrack(let id, let name):
            guard let index = tracks.firstIndex(where: { $0.id == id }) else {
                throw MusicError.invalidTrack(reason: "unknown track \(id)")
            }
            tracks[index].name = name
        case .setStrip(let id, let strip):
            guard let index = tracks.firstIndex(where: { $0.id == id }) else {
                throw MusicError.invalidTrack(reason: "unknown track \(id)")
            }
            tracks[index].strip = strip
        case .setInstrument(let id, let instrument):
            guard let index = tracks.firstIndex(where: { $0.id == id }) else {
                throw MusicError.invalidTrack(reason: "unknown track \(id)")
            }
            tracks[index].instrument = instrument
        case .setEffects(let id, let effects):
            guard let index = tracks.firstIndex(where: { $0.id == id }) else {
                throw MusicError.invalidTrack(reason: "unknown track \(id)")
            }
            tracks[index].effects = effects
        case .setTrackRouting(let id, let output, let sends):
            guard let index = tracks.firstIndex(where: { $0.id == id }) else {
                throw MusicError.invalidTrack(reason: "unknown track \(id)")
            }
            tracks[index].outputBusID = output
            tracks[index].sends = sends
        case .insertClip(let clip):
            guard let index = tracks.firstIndex(where: { $0.id == clip.trackID }) else {
                throw MusicError.invalidClip(reason: "unknown track \(clip.trackID)")
            }
            guard !tracks[index].clips.contains(where: { $0.id == clip.id }) else {
                throw MusicError.invalidClip(reason: "duplicate clip id \(clip.id)")
            }
            tracks[index].clips.append(clip)
        case .removeClip(let id):
            guard let trackIndex = tracks.firstIndex(where: { $0.clips.contains(where: { $0.id == id }) }) else {
                throw MusicError.invalidClip(reason: "unknown clip \(id)")
            }
            tracks[trackIndex].clips.removeAll { $0.id == id }
        case .updateClip(let clip):
            guard let trackIndex = tracks.firstIndex(where: { $0.id == clip.trackID }) else {
                throw MusicError.invalidClip(reason: "unknown track \(clip.trackID)")
            }
            guard let clipIndex = tracks[trackIndex].clips.firstIndex(where: { $0.id == clip.id }) else {
                throw MusicError.invalidClip(reason: "unknown clip \(clip.id)")
            }
            tracks[trackIndex].clips[clipIndex] = clip
        case .setTempo(let tick, let bpm, let beatsPerBar, let beatUnit):
            tempoMap = try tempoMap.changingTempo(atTick: tick, bpm: bpm,
                                                  beatsPerBar: beatsPerBar, beatUnit: beatUnit)
        case .setTempoMap(let map):
            tempoMap = map
        case .insertBus(let bus):
            guard !buses.contains(where: { $0.id == bus.id }) else {
                throw MusicError.invalidMixer(reason: "duplicate bus id \(bus.id)")
            }
            buses.append(bus)
        case .removeBus(let id):
            guard id != MusicBus.masterBusID else {
                throw MusicError.invalidMixer(reason: "master bus cannot be removed")
            }
            guard let index = buses.firstIndex(where: { $0.id == id }) else {
                throw MusicError.invalidMixer(reason: "unknown bus \(id)")
            }
            buses.remove(at: index)
            for i in tracks.indices {
                if tracks[i].outputBusID == id { tracks[i].outputBusID = MusicBus.masterBusID }
                tracks[i].sends.removeAll { $0.busID == id }
            }
            for i in buses.indices where buses[i].sends.contains(id) {
                buses[i].sends.removeAll { $0 == id }
            }
            automationLanes.removeAll { $0.ownerID == id.rawValue }
        case .setBusSends(let id, let sends):
            guard let index = buses.firstIndex(where: { $0.id == id }) else {
                throw MusicError.invalidMixer(reason: "unknown bus \(id)")
            }
            buses[index].sends = sends
        case .upsertAutomationLane(let lane):
            if let index = automationLanes.firstIndex(where: { $0.id == lane.id }) {
                automationLanes[index] = lane
            } else {
                automationLanes.append(lane)
            }
        case .removeAutomationLane(let id):
            automationLanes.removeAll { $0.id == id }
        case .setName(let name):
            self.name = name
        }
    }
}
