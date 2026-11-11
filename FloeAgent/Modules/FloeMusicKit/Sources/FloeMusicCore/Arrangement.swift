import Foundation

/// Shared arrangement playback facts. The live accompaniment transport, the
/// offline renderer and the session all resolve "what should sound now"
/// through these helpers so mute/solo behaviour can never drift between the
/// recording transport, export rendering and UI metering.
extension MusicDocument {
    /// Tracks that sound under the shared mute/solo rule: a muted track is
    /// silent; when any track is soloed only soloed tracks sound. This is the
    /// same resolution the offline renderer has always used, now in one place.
    public var audibleTracks: [MusicTrack] {
        let soloed = tracks.contains { $0.strip.soloed }
        return tracks.filter { !$0.strip.muted && (!soloed || $0.strip.soloed) }
    }

    /// Sample position one past the last audible clip end, 0 when the project
    /// has no clips. Playback/reconcile code treats this as content end.
    public var contentEndSample: MusicSampleTime {
        let last = tracks.flatMap(\.clips).compactMap { try? $0.endSample(tempoMap: tempoMap).value }.max() ?? 0
        return MusicSampleTime(last)
    }
}
