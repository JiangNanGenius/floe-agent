// FloeWorkbench — PreparedVideo: one frame evaluator for preview and export.
//
// `PreparedVideoFrameEvaluator` is pure and synchronous. It answers "which
// layers, at what source times, opacity and transform, are visible at this
// frame?" The current-frame preview and the export writer both call it; there
// is no second composition path and no AVPlayerLayer-specific behavior.
//
// This is intentionally not a playback engine. It evaluates bounded frames on
// demand, which is what allows a preview proxy to invalidate only the edited
// interval instead of re-rendering the whole project for every edit.

import Foundation

// MARK: - Evaluated state

public struct PreparedVideoLayerEvaluation: Sendable, Hashable {
    public let clipID: UUID
    public let trackID: UUID
    public let content: PreparedVideoVisualContent
    public let zIndex: Int
    /// Source time for media clips; nil for text/graphic clips.
    public let sourceTime: PreparedVideoTime?
    public let opacity: Double
    public let transform: PreparedVideoTransform
    public let mask: PreparedVideoMask?
    public let clipLocalTime: PreparedVideoTime
    public let sourceRange: PreparedVideoTimeRange?

    public init(clipID: UUID, trackID: UUID, content: PreparedVideoVisualContent,
                zIndex: Int, sourceTime: PreparedVideoTime?, opacity: Double,
                transform: PreparedVideoTransform, mask: PreparedVideoMask?,
                clipLocalTime: PreparedVideoTime,
                sourceRange: PreparedVideoTimeRange?) {
        self.clipID = clipID
        self.trackID = trackID
        self.content = content
        self.zIndex = zIndex
        self.sourceTime = sourceTime
        self.opacity = opacity
        self.transform = transform
        self.mask = mask
        self.clipLocalTime = clipLocalTime
        self.sourceRange = sourceRange
    }
}

public struct PreparedVideoCaptionEvaluation: Sendable, Hashable {
    public let captionID: UUID
    public let text: String
    public let style: PreparedVideoCaptionStyle

    public init(captionID: UUID, text: String, style: PreparedVideoCaptionStyle) {
        self.captionID = captionID
        self.text = text
        self.style = style
    }
}

public struct PreparedVideoFrameEvaluation: Sendable, Hashable {
    public let planID: PreparedVideoPlanID
    public let frameIndex: Int64
    public let time: PreparedVideoTime
    public let background: PreparedVideoColor
    public let layers: [PreparedVideoLayerEvaluation]
    public let captions: [PreparedVideoCaptionEvaluation]

    public init(planID: PreparedVideoPlanID, frameIndex: Int64,
                time: PreparedVideoTime, background: PreparedVideoColor,
                layers: [PreparedVideoLayerEvaluation],
                captions: [PreparedVideoCaptionEvaluation]) {
        self.planID = planID
        self.frameIndex = frameIndex
        self.time = time
        self.background = background
        self.layers = layers
        self.captions = captions
    }
}

// MARK: - Evaluator

public enum PreparedVideoFrameEvaluator {
    /// Evaluates a rational timeline time. Times outside the plan are rejected
    /// rather than silently clamped; callers use `frameIndex` for frame math.
    public static func evaluate(plan: PreparedVideoPlan,
                                at time: PreparedVideoTime) throws -> PreparedVideoFrameEvaluation {
        try plan.validateForRender()
        guard time.timescale == plan.timeScale else {
            throw PreparedVideoError.invalidTime("query time must use the plan timescale")
        }
        guard time.seconds >= 0, time.seconds <= plan.duration.seconds + 0.000_001 else {
            throw PreparedVideoError.invalidTime("query time lies outside the plan")
        }
        let frameIndex = plan.frameRate.frameIndex(for: time, rounding: .nearest)

        var layers: [PreparedVideoLayerEvaluation] = []
        var zIndex = 0
        for track in plan.visualTracks {
            guard !track.isHidden else { continue }
            let active = try activeClips(in: track, at: time)
            for evaluated in active {
                let clip = evaluated.clip
                guard clip.isVisible, clip.opacity > 0 else { continue }
                let local = try time.subtracting(clip.timelineRange.start)
                let animated = try animatedTransform(clip: clip, localTime: local)
                let opacity = min(1, max(0, clip.opacity * track.opacity
                    * animated.opacity * evaluated.transitionOpacity))
                guard opacity > 0 else { continue }
                let sourceTime = try clip.sourceTime(at: time)
                layers.append(PreparedVideoLayerEvaluation(
                    clipID: clip.id, trackID: track.id, content: clip.content,
                    zIndex: zIndex, sourceTime: sourceTime, opacity: opacity,
                    transform: animated.transform, mask: clip.mask,
                    clipLocalTime: local, sourceRange: clip.sourceRange))
                zIndex += 1
            }
        }

        let activeCaptions = plan.captions
            .filter { $0.timelineRange.contains(time) }
            .sorted { $0.timelineRange.start < $1.timelineRange.start }
            .map { PreparedVideoCaptionEvaluation(captionID: $0.id, text: $0.text,
                                                  style: plan.captionStyle) }

        return PreparedVideoFrameEvaluation(planID: plan.id, frameIndex: frameIndex,
                                            time: time, background: plan.canvas.backgroundColor,
                                            layers: layers, captions: activeCaptions)
    }

    public static func evaluate(plan: PreparedVideoPlan,
                                frameIndex: Int64) throws -> PreparedVideoFrameEvaluation {
        let time = try plan.frameRate.time(forFrame: frameIndex, timescale: plan.timeScale)
        return try evaluate(plan: plan, at: time)
    }

    // MARK: Active clips / transitions

    private struct ActiveClip {
        var clip: PreparedVideoClip
        var transitionOpacity: Double
    }

    /// Resolved plans may overlap adjacent clips only at an explicit leading
    /// transition. At most two clips are active on a track at one time.
    private static func activeClips(in track: PreparedVideoTrack,
                                    at time: PreparedVideoTime) throws -> [ActiveClip] {
        let active = track.clips.filter { $0.timelineRange.contains(time) }
            .sorted { $0.timelineRange.start < $1.timelineRange.start }
        guard active.count <= 2 else {
            throw PreparedVideoError.invalidPlan("more than two clips overlap on one visual track")
        }
        guard active.count == 2 else {
            return active.map { ActiveClip(clip: $0, transitionOpacity: 1) }
        }
        let outgoing = active[0]
        let incoming = active[1]
        guard let transition = incoming.leadingTransition else {
            throw PreparedVideoError.invalidPlan("overlapping clips require an explicit transition")
        }
        guard let outgoingEnd = try? outgoing.timelineRange.endTime() else {
            throw PreparedVideoError.invalidPlan("outgoing clip range is invalid")
        }
        let overlap = outgoingEnd.seconds - incoming.timelineRange.start.seconds
        guard overlap > 0 else {
            return [ActiveClip(clip: outgoing, transitionOpacity: 1),
                    ActiveClip(clip: incoming, transitionOpacity: 1)]
        }
        let elapsed = time.seconds - incoming.timelineRange.start.seconds
        let progress = min(1, max(0, elapsed / overlap))
        switch transition.kind {
        case .crossDissolve:
            let eased = smoothStep(progress)
            return [ActiveClip(clip: outgoing, transitionOpacity: 1 - eased),
                    ActiveClip(clip: incoming, transitionOpacity: eased)]
        case .dipToBlack:
            let outgoingOpacity = max(0, 1 - progress * 2)
            let incomingOpacity = max(0, progress * 2 - 1)
            return [ActiveClip(clip: outgoing, transitionOpacity: outgoingOpacity),
                    ActiveClip(clip: incoming, transitionOpacity: incomingOpacity)]
        }
    }

    // MARK: Keyframes

    private struct AnimatedTransform {
        var transform: PreparedVideoTransform
        var opacity: Double
    }

    private static func animatedTransform(clip: PreparedVideoClip,
                                          localTime: PreparedVideoTime) throws -> AnimatedTransform {
        var centerX = clip.transform.centerX
        var centerY = clip.transform.centerY
        var scale = clip.transform.scale
        var rotation = clip.transform.rotationDegrees
        var opacity = 1.0
        for track in clip.keyframes {
            guard let value = try interpolate(track: track, at: localTime) else { continue }
            switch track.property {
            case .opacity: opacity = min(1, max(0, value))
            case .centerX: centerX = value
            case .centerY: centerY = value
            case .scale: scale = value
            case .rotationDegrees: rotation = value
            }
        }
        let transform = PreparedVideoTransform(centerX: centerX, centerY: centerY,
                                               scale: scale, rotationDegrees: rotation,
                                               fit: clip.transform.fit)
        return AnimatedTransform(transform: transform, opacity: opacity)
    }

    /// Evaluates one property track. Values outside the first/last keyframe
    /// hold the edge value; an empty track has no effect.
    public static func interpolate(track: PreparedVideoKeyframeTrack,
                                   at localTime: PreparedVideoTime) throws -> Double? {
        guard !track.keyframes.isEmpty else { return nil }
        guard track.keyframes.allSatisfy({ $0.time.timescale == localTime.timescale }) else {
            throw PreparedVideoError.invalidTime("keyframe and query timescales differ")
        }
        if localTime <= track.keyframes[0].time {
            return track.keyframes[0].value
        }
        guard let last = track.keyframes.last else { return nil }
        if localTime >= last.time {
            return last.value
        }
        for index in 1..<track.keyframes.count {
            let left = track.keyframes[index - 1]
            let right = track.keyframes[index]
            guard localTime <= right.time else { continue }
            let span = right.time.seconds - left.time.seconds
            guard span > 0 else { return right.value }
            let linear = (localTime.seconds - left.time.seconds) / span
            let mapped: Double
            switch left.interpolation {
            case .hold:
                return left.value
            case .linear:
                mapped = linear
            case .easeIn:
                mapped = linear * linear
            case .easeOut:
                mapped = 1 - (1 - linear) * (1 - linear)
            case .easeInOut:
                mapped = smoothStep(linear)
            case .cubicBezier:
                mapped = cubicBezier(linear,
                                     x1: left.control1X, y1: left.control1Y,
                                     x2: left.control2X, y2: left.control2Y)
            }
            return left.value + (right.value - left.value) * mapped
        }
        return last.value
    }

    private static func smoothStep(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    /// Solve x(t) = progress for t, then evaluate y(t). Control x values are
    /// validated to 0...1; bisection is deterministic and branch-safe.
    private static func cubicBezier(_ progress: Double, x1: Double, y1: Double,
                                    x2: Double, y2: Double) -> Double {
        let x = min(1, max(0, progress))
        var low = 0.0
        var high = 1.0
        var t = x
        for _ in 0..<32 {
            let current = bezier(t, control1: x1, control2: x2)
            if abs(current - x) < 0.000_001 { break }
            if current < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return bezier(t, control1: y1, control2: y2)
    }

    private static func bezier(_ t: Double, control1: Double, control2: Double) -> Double {
        let oneMinus = 1 - t
        return 3 * oneMinus * oneMinus * t * control1
            + 3 * oneMinus * t * t * control2
            + t * t * t
    }
}
