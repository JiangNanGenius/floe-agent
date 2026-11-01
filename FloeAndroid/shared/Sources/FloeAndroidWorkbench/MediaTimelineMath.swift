// FloeWorkbench — Pure timeline math.
//
// Maps per-clip source ranges onto the unified timeline after speed retiming,
// locates the clip under the playhead, and computes cross-dissolve overlap
// windows. No AVFoundation here so the exact audio/video sync behavior is
// unit-testable on every platform.

import Foundation
import FloeCore

public struct PlacedClip: Sendable, Hashable {
    public var clip: VideoClip
    public var timelineStart: Double
    public var timelineEnd: Double
    public var duration: Double { timelineEnd - timelineStart }
}

public struct PlacedMusic: Sendable, Hashable {
    public var music: MusicClip
    public var timelineStart: Double
    public var timelineEnd: Double
}

public struct DissolveWindow: Sendable, Hashable {
    public var fromClipID: UUID
    public var toClipID: UUID
    public var start: Double
    public var end: Double
    public var duration: Double { end - start }
}

public enum MediaTimelineMath {
    /// Lays clips onto the unified timeline, applying per-clip speed. A
    /// leading cross-dissolve overlaps the head of a clip with the tail of
    /// its predecessor, which contracts the timeline by the dissolved
    /// duration — the same ripple semantics a non-linear editor uses. Every
    /// other time base (playhead, captions, music, export verification) uses
    /// THESE placements, so audio/video sync and caption timing stay exact.
    public static func placeClips(_ clips: [VideoClip]) -> [PlacedClip] {
        var cursor = 0.0
        return clips.enumerated().map { index, clip in
            let duration = clip.timelineDuration
            var start = cursor
            if index > 0, clip.leadingTransition == .crossDissolve {
                let overlap = min(clip.transitionDuration, duration, cursor)
                start -= max(0, overlap)
            }
            let placed = PlacedClip(clip: clip, timelineStart: max(0, start), timelineEnd: max(0, start) + duration)
            cursor = placed.timelineEnd
            return placed
        }
    }

    public static func placeMusic(_ music: [MusicClip]) -> [PlacedMusic] {
        music.map { PlacedMusic(music: $0, timelineStart: $0.offsetSeconds,
                                timelineEnd: $0.offsetSeconds + $0.lengthSeconds) }
    }

    /// Dissolve windows from placements: each dissolving clip's first
    /// `overlap` seconds on the timeline. Both neighbor tracks carry frames
    /// during the window; the compositor ramps opacity.
    public static func dissolveWindows(_ placed: [PlacedClip]) -> [DissolveWindow] {
        var windows: [DissolveWindow] = []
        for index in placed.indices.dropFirst() {
            let current = placed[index]
            guard current.clip.leadingTransition == .crossDissolve else { continue }
            let previous = placed[index - 1]
            let overlap = min(current.clip.transitionDuration, current.duration, previous.duration)
            guard overlap > 0.05 else { continue }
            windows.append(DissolveWindow(fromClipID: previous.clip.id, toClipID: current.clip.id,
                                          start: current.timelineStart, end: current.timelineStart + overlap))
        }
        return windows
    }

    /// Converts a timeline position to source seconds within a clip (speed
    /// retimed). Returns nil outside the clip.
    public static func sourceTime(for placed: PlacedClip, timeline seconds: Double) -> Double? {
        guard seconds >= placed.timelineStart, seconds <= placed.timelineEnd else { return nil }
        let local = seconds - placed.timelineStart
        return placed.clip.trimStart + local * placed.clip.speed
    }

    /// Finds the placed clip under a playhead position.
    public static func clip(at seconds: Double, in placed: [PlacedClip]) -> PlacedClip? {
        placed.first { seconds >= $0.timelineStart && seconds < $0.timelineEnd } ?? placed.last { $0.duration > 0 }
    }

    /// Caption active at a timeline position. Shared by the export compositor
    /// and the live preview overlay so both show the same segment.
    public static func caption(at seconds: Double, in captions: [CaptionSegment]) -> CaptionSegment? {
        captions.first { seconds >= $0.start && seconds <= $0.end }
    }

    /// Splits a placed clip at a timeline position, returning source-time
    /// boundaries used by the renderer and the edit command.
    public static func splitPoint(clip: VideoClip, atTimelineSeconds withinClip: Double) throws -> Double {
        let sourceSeconds = clip.trimStart + withinClip * clip.speed
        guard sourceSeconds > clip.trimStart + 0.05,
              sourceSeconds < clip.trimEnd - 0.05 else {
            throw FloeError.validationFailed("Split point is too close to a clip edge")
        }
        return sourceSeconds
    }

    /// Total duration of the video export: the primary track tail, extended by
    /// any music that deliberately continues past the last frame is clamped at
    /// export (audio-only tails are not a video). Caption end is advisory.
    public static func primaryDuration(_ timeline: VideoTimeline) -> Double {
        timeline.primaryDuration
    }

    /// Retimes caption timestamps when a clip's duration changes (speed or
    /// trim). `clipAfter` is the placement with the NEW duration and
    /// `previousDuration` the clip's duration before the change; captions at
    /// or after the old clip end shift by the delta so burned text stays
    /// aligned with the retimed content.
    public static func retimeCaptions(_ captions: [CaptionSegment],
                                      clipAfter: PlacedClip,
                                      previousDuration: Double) -> [CaptionSegment] {
        let delta = clipAfter.duration - previousDuration
        guard abs(delta) > 0.001 else { return captions }
        let boundary = clipAfter.timelineStart + min(previousDuration, clipAfter.duration)
        return captions.map { caption in
            var copy = caption
            if caption.start >= boundary - 0.001 {
                copy.start = max(0, caption.start + delta)
                copy.end = max(copy.start + 0.01, caption.end + delta)
            }
            return copy
        }
    }
}

// MARK: - Resource guards

/// Explicit export geometry presets. Resolution and frame rate are always
/// concrete numbers; a preset never silently substitutes another value.
public enum VideoExportPreset: String, Sendable, Codable, Hashable, CaseIterable {
    case landscape1080p
    case portrait1080p
    case square1080

    public var width: Int {
        switch self {
        case .landscape1080p: 1920
        case .portrait1080p: 1080
        case .square1080: 1080
        }
    }

    public var height: Int {
        switch self {
        case .landscape1080p: 1080
        case .portrait1080p: 1920
        case .square1080: 1080
        }
    }

    public var defaultFrameRate: Double {
        switch self {
        case .landscape1080p, .portrait1080p: 30
        case .square1080: 30
        }
    }

    public func options(frameRate: Double?, codec: VideoExportCodec,
                        fileName: String) -> VideoExportOptions {
        VideoExportOptions(codec: codec, width: width, height: height,
                           frameRate: frameRate ?? defaultFrameRate,
                           fileName: fileName)
    }
}

public extension MediaTimelineMath {
    /// Exact timecode `HH:MM:SS:FF` for a timeline position.
    static func timecode(seconds: Double, frameRate: Double) -> String {
        let fps = frameRate > 0 ? frameRate : 30
        let totalFrames = Int((max(0, seconds) * fps).rounded())
        let framesPerHour = Int((fps * 3600).rounded())
        let framesPerMinute = Int((fps * 60).rounded())
        let hours = totalFrames / max(1, framesPerHour)
        let minutes = (totalFrames % max(1, framesPerHour)) / max(1, framesPerMinute)
        let secondsPart = (totalFrames % max(1, framesPerMinute)) / max(1, Int(fps.rounded()))
        let frames = totalFrames % max(1, Int(fps.rounded()))
        return String(format: "%02d:%02d:%02d:%02d", hours, minutes, secondsPart, frames)
    }

    /// One frame step from `seconds`; negative delta steps backwards. The
    /// result is clamped to `0...duration` and quantized to the frame grid.
    static func frameStep(seconds: Double, deltaFrames: Int, frameRate: Double,
                          duration: Double) -> Double {
        let fps = frameRate > 0 ? frameRate : 30
        let frame = (max(0, seconds) * fps).rounded()
        let next = max(0, frame + Double(deltaFrames)) / fps
        return min(max(0, next), max(0, duration))
    }

    /// Snaps `seconds` to the nearest candidate within `tolerance` seconds.
    /// Returns the input unchanged when nothing is close enough.
    static func snap(seconds: Double, to candidates: [Double], tolerance: Double) -> Double {
        guard tolerance > 0 else { return seconds }
        var best = seconds
        var bestDistance = tolerance
        for candidate in candidates where candidate.isFinite {
            let distance = abs(candidate - seconds)
            if distance <= bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best
    }

    /// Clip edges plus zero for timeline snapping; playhead is the caller's
    /// current position, which is never treated as a snap target.
    static func snapCandidates(_ timeline: VideoTimeline) -> [Double] {
        var values: [Double] = [0]
        var cursor = 0.0
        for clip in timeline.clips {
            values.append(cursor)
            cursor += clip.timelineDuration
            values.append(cursor)
        }
        return values
    }

    /// Validated explicit cover time: clamps into the timeline and rejects
    /// non-finite input instead of guessing a frame.
    static func coverTime(_ requested: Double?, timeline: VideoTimeline) -> Double? {
        guard let requested, requested.isFinite else { return nil }
        let duration = self.primaryDuration(timeline)
        guard duration > 0 else { return nil }
        return min(max(0, requested), duration)
    }

    /// Shifts every caption by `offset` while keeping order and validity.
    static func shiftCaptions(_ captions: [CaptionSegment], by offset: Double,
                              duration: Double) -> [CaptionSegment] {
        guard offset.isFinite, offset != 0 else { return captions }
        return captions.compactMap { caption in
            var shifted = caption
            shifted.start = max(0, caption.start + offset)
            shifted.end = max(shifted.start + 0.01, caption.end + offset)
            guard shifted.start < duration + 0.5 else { return nil }
            shifted.end = min(shifted.end, max(duration, shifted.start + 0.01))
            return shifted
        }
    }

    /// Duplicates a clip directly after its original, preserving source range
    /// and all per-clip options; the copy receives a fresh identity.
    static func duplicatedClip(_ clip: VideoClip) -> VideoClip {
        var copy = clip
        copy.id = UUID()
        return copy
    }
}

public enum MediaResourceGuard {
    public struct ImageBudget: Sendable {
        public var maximumPixelCount: Int
        public var maximumEdge: Int
        public var maximumDecodeBytes: Int
        /// Preview longest edge; full resolution stays on the export path.
        public var previewLongestEdge: Int

        public init(maximumPixelCount: Int = 24_000_000, maximumEdge: Int = 16_384,
                    maximumDecodeBytes: Int = 256 * 1024 * 1024, previewLongestEdge: Int = 2048) {
            self.maximumPixelCount = maximumPixelCount
            self.maximumEdge = maximumEdge
            self.maximumDecodeBytes = maximumDecodeBytes
            self.previewLongestEdge = previewLongestEdge
        }
    }

    public enum Decision: Sendable, Hashable {
        case fullResolution
        case scaledPreview(maxEdge: Int)
        case offerScaledCopy(requestedMaxEdge: Int)
        case rejected(String)
    }

    /// Evaluates a source image. Oversized sources never crash the editor: the
    /// UI is offered a scaled working copy instead of a forced full decode.
    public static func evaluateImage(width: Int, height: Int, budget: ImageBudget = .init()) -> Decision {
        let longestEdge = max(width, height)
        let pixels = width * height
        if longestEdge > budget.maximumEdge || pixels > budget.maximumPixelCount {
            let scaled = min(budget.previewLongestEdge, longestEdge)
            return .offerScaledCopy(requestedMaxEdge: scaled)
        }
        // Rough decoded RGBA cost; guard against an allocation failure path.
        if pixels * 4 > budget.maximumDecodeBytes {
            return .offerScaledCopy(requestedMaxEdge: budget.previewLongestEdge)
        }
        if longestEdge > budget.previewLongestEdge {
            return .scaledPreview(maxEdge: budget.previewLongestEdge)
        }
        return .fullResolution
    }

    /// Even dimension used by the H264/HEVC encoder.
    public static func even(_ value: Int) -> Int {
        max(2, value % 2 == 0 ? value : value - 1)
    }
}
