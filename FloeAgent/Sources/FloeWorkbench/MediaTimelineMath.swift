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
