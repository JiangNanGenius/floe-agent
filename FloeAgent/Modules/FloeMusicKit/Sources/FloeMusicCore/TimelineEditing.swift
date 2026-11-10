// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum MusicTimelineEditKind: String, Sendable, Hashable {
    case move, trimStart, trimEnd
}

/// Shared hit testing for the actual timeline input surface. A finger pan on
/// a clip's body scrolls; holding the clip first moves it. Pencil and pointer
/// drags edit directly. A selected clip's edges always resize directly.
public enum MusicTimelineInputPolicy {
    public static func editKind(x: Double, width: Double, selected: Bool,
                                finger: Bool, held: Bool = false) -> MusicTimelineEditKind? {
        guard x.isFinite, width.isFinite, width > 0, x >= 0, x <= width else { return nil }
        let edge = min(18, width / 3)
        if selected {
            if x <= edge { return .trimStart }
            if x >= width - edge { return .trimEnd }
        }
        return !finger || held ? .move : nil
    }
}

/// Produces an edit for the existing revision-checked, undoable store. Source
/// assets are never changed by a gesture. Preview and final commit use the
/// same captured clip and tempo map, so rounding cannot jump on finger-up.
public enum MusicTimelineEditing {
    private static let maxExactSample: Double = 9.0e15

    /// The editing cursor may pass the last clip, including in an empty song.
    /// Audio playback has its own duration; it must not constrain insertion.
    public static func cursor(seconds: Double, sampleRate: Int) -> Double? {
        guard seconds.isFinite, sampleRate > 0 else { return nil }
        return min(max(0, seconds), maxExactSample / Double(sampleRate))
    }

    public static func anchoredScrollOffset(offset: Double, anchorX: Double,
                                             oldScale: Double, newScale: Double) -> Double {
        guard offset.isFinite, anchorX.isFinite, oldScale.isFinite, newScale.isFinite,
              oldScale > 0, newScale > 0 else { return max(0, offset.isFinite ? offset : 0) }
        return max(0, (max(0, offset) + max(0, anchorX)) / oldScale * newScale - max(0, anchorX))
    }

    public static func edit(_ clip: MusicClip, kind: MusicTimelineEditKind,
                            deltaSeconds: Double, snapping: Bool,
                            tempoMap: MusicTempoMap, sourceDurationSamples: Int64? = nil) throws -> MusicClip {
        guard deltaSeconds.isFinite else { throw MusicError.invalidClip(reason: "non-finite timeline movement") }
        if deltaSeconds == 0 { return clip }
        let rate = Double(tempoMap.sampleRate)
        let end = try clip.endSample(tempoMap: tempoMap)
        let origin = kind == .trimEnd ? end.value : clip.offset.value
        let raw = Double(origin) + deltaSeconds * rate
        guard raw.isFinite, abs(raw) <= maxExactSample else {
            throw MusicError.invalidClip(reason: "timeline movement is outside the supported range")
        }
        var target = Int64(max(0, raw).rounded())
        if snapping {
            let tick = try tempoMap.tick(atSample: .init(target)).value
            let grid = Int64(max(1, tempoMap.ticksPerQuarter / 4))
            let snapped = Int64((Double(tick) / Double(grid)).rounded()) * grid
            target = try tempoMap.sample(atTick: .init(snapped)).value
        }
        var result = clip
        if kind == .move { result.offset = .init(target); return result }

        switch clip.body {
        case .audio(var payload):
            // The immutable source bounds allow an audio trim to be extended
            // again without a second import or destructive file rewrite.
            let (sourceEnd, sourceOverflow) = payload.trimStartSamples.addingReportingOverflow(payload.durationSamples)
            guard !sourceOverflow else { throw MusicError.invalidClip(reason: "audio source range overflow") }
            let sourceLength = max(sourceEnd, sourceDurationSamples ?? sourceEnd)
            if kind == .trimStart {
                let earliest = max(0, clip.offset.value - payload.trimStartSamples)
                let start = min(end.value - 1, max(earliest, target))
                payload.trimStartSamples += start - clip.offset.value
                payload.durationSamples = end.value - start
                result.offset = .init(start)
            } else {
                let (maximum, overflow) = clip.offset.value.addingReportingOverflow(sourceLength - payload.trimStartSamples)
                guard !overflow else { throw MusicError.invalidClip(reason: "audio source range overflow") }
                let finish = max(clip.offset.value + 1, min(maximum, target))
                payload.durationSamples = finish - clip.offset.value
            }
            payload.fadeInSamples = min(payload.fadeInSamples, payload.durationSamples / 2)
            payload.fadeOutSamples = min(payload.fadeOutSamples, payload.durationSamples / 2)
            result.body = .audio(payload)
        case .midi(var payload):
            let anchor = try tempoMap.tick(atSample: clip.offset).value
            let oldEnd = anchor + payload.durationTicks
            let targetTick = try tempoMap.tick(atSample: .init(target)).value
            if kind == .trimStart {
                let startTick = max(0, min(oldEnd - 1, targetTick))
                if startTick >= anchor {
                    return try MusicWorkbenchEditing.trim(clip,
                        start: tempoMap.sample(atTick: .init(startTick)), end: end, tempoMap: tempoMap)
                }
                let prepend = anchor - startTick
                payload.durationTicks += prepend
                for i in payload.notes.indices { payload.notes[i].startTick = .init(payload.notes[i].startTick.value + prepend) }
                for i in payload.controllerPoints.indices { payload.controllerPoints[i].tick = .init(payload.controllerPoints[i].tick.value + prepend) }
                for i in payload.programChanges.indices { payload.programChanges[i].tick = .init(payload.programChanges[i].tick.value + prepend) }
                result.offset = try tempoMap.sample(atTick: .init(startTick))
            } else {
                let finish = max(anchor + 1, targetTick)
                if finish < oldEnd {
                    return try MusicWorkbenchEditing.trim(clip, start: clip.offset,
                        end: tempoMap.sample(atTick: .init(finish)), tempoMap: tempoMap)
                }
                payload.durationTicks = finish - anchor
            }
            result.body = .midi(payload)
        }
        return result
    }
}
