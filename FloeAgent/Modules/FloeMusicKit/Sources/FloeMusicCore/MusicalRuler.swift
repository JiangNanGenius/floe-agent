import Foundation

public struct MusicBarBeatMark: Sendable, Hashable {
    public let tick: Int64
    public let bar: Int
    public let beat: Int
}

public enum MusicMusicalRuler {
    /// Meter changes begin a new bar; tempo-only changes preserve the grid.
    public static func marks(tempoMap: MusicTempoMap, through end: Int64, limit: Int = 4096) -> [MusicBarBeatMark] {
        guard end >= 0, limit > 0 else { return [] }
        var meters: [MusicTempoSegment] = []
        for segment in tempoMap.segments {
            if let last = meters.last, last.beatsPerBar == segment.beatsPerBar, last.beatUnit == segment.beatUnit { continue }
            meters.append(segment)
        }
        var marks: [MusicBarBeatMark] = [], bar = 1
        for index in meters.indices {
            let segment = meters[index]
            let stop = index + 1 < meters.count ? min(end + (end < Int64.max ? 1 : 0), meters[index + 1].startTick.value) : end
            let step = max(1, Int64(tempoMap.ticksPerQuarter * 4 / segment.beatUnit))
            var tick = segment.startTick.value, beat = 1
            while tick <= end && (index + 1 == meters.count || tick < stop), marks.count < min(limit, 16_384) {
                marks.append(MusicBarBeatMark(tick: tick, bar: bar, beat: beat))
                let (next, overflow) = tick.addingReportingOverflow(step)
                if overflow { return marks }; tick = next
                beat += 1
                if beat > segment.beatsPerBar { beat = 1; bar += 1 }
            }
            if marks.count >= min(limit, 16_384) { break }
            if beat != 1 { bar += 1 }
        }
        return marks
    }
}
