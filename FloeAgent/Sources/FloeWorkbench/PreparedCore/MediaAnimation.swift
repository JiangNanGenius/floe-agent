// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct MediaCubicBezier: Sendable, Codable, Hashable {
    public var control1: ImageFreehandStroke.Point
    public var control2: ImageFreehandStroke.Point
    public init(control1: ImageFreehandStroke.Point = .init(x: 0.25, y: 0.1),
                control2: ImageFreehandStroke.Point = .init(x: 0.25, y: 1)) {
        self.control1 = control1; self.control2 = control2
    }
    public func validate() throws {
        guard [control1.x, control1.y, control2.x, control2.y].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw MediaPreparedCoreError.invalidOperation("animation curve handles must be in 0...1")
        }
    }
}

public struct MediaMotionTitle: Sendable, Codable, Hashable {
    public var text: String
    public var fontSize: Double
    public var colorHex: String
    public var backgroundHex: String?
    public init(text: String, fontSize: Double = 48, colorHex: String = "#FFFFFF", backgroundHex: String? = nil) {
        self.text = text; self.fontSize = fontSize; self.colorHex = colorHex; self.backgroundHex = backgroundHex
    }
    public func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 20_000,
              fontSize.isFinite, (1...512).contains(fontSize) else {
            throw MediaPreparedCoreError.invalidOperation("title text or size is outside its limit")
        }
        _ = try PreparedVideoColor(hex: colorHex)
        if let backgroundHex { _ = try PreparedVideoColor(hex: backgroundHex) }
    }
}

public enum MediaAnimationPreset: String, Sendable, Codable, CaseIterable {
    case fade, slideLeft = "slide-left", rise, zoomIn = "zoom-in", pulse, spin
}

/// Document keyframes are projected once into the existing native evaluator.
/// UI curves, previews and export therefore share values and interpolation.
public enum MediaAnimation {
    public static func preparedKey(_ key: MediaKeyframe, timescale: Int32) throws -> PreparedVideoKeyframe {
        guard case .number(let value) = key.value,
              let interpolation = PreparedVideoInterpolation(rawValue: key.interpolation.rawValue) else {
            throw MediaPreparedCoreError.invalidOperation("numeric animation keyframe required")
        }
        let curve = key.curve ?? .init()
        try curve.validate()
        return .init(time: try .init(seconds: key.time.seconds, timescale: timescale), value: value,
            interpolation: interpolation, control1X: curve.control1.x, control1Y: curve.control1.y,
            control2X: curve.control2.x, control2Y: curve.control2.y)
    }
    public static func preparedTracks(_ tracks: [MediaKeyframeTrack], timescale: Int32) throws -> [PreparedVideoKeyframeTrack] {
        try tracks.map { track in
            guard let property = PreparedVideoAnimatableProperty(rawValue: track.property.replacingOccurrences(of: "transform.", with: "")) else {
                throw MediaPreparedCoreError.invalidOperation("unsupported animation property")
            }
            return .init(property: property, keyframes: try track.keyframes.map { try preparedKey($0, timescale: timescale) })
        }
    }
    private static func time(_ seconds: Double) throws -> MediaRationalTime {
        guard seconds.isFinite, (0...100_000).contains(seconds) else {
            throw MediaPreparedCoreError.invalidOperation("animation time is outside its limit")
        }
        return try .init(value: Int64((seconds * 90_000).rounded()), timescale: 90_000)
    }
    private static func key(_ seconds: Double, _ value: Double, _ interpolation: MediaKeyframeInterpolation = .linear) throws -> MediaKeyframe {
        .init(time: try time(seconds), value: .number(value), interpolation: interpolation)
    }
    /// Presets replace only their named properties. Unrelated animation stays.
    public static func applying(_ preset: MediaAnimationPreset, to clip: MediaPreparedClip) throws -> [MediaKeyframeTrack] {
        let duration = clip.timelineRange.durationSeconds
        guard duration > 0 else { throw MediaPreparedCoreError.invalidOperation("animation needs a positive duration") }
        let edge = min(0.6, duration / 3)
        var edits: [MediaKeyframeTrack] = []
        switch preset {
        case .fade:
            edits = [.init(property: "opacity", keyframes: try [key(0, 0, .easeOut), key(edge, 1), key(duration - edge, 1, .easeIn), key(duration, 0)])]
        case .slideLeft:
            edits = [.init(property: "centerX", keyframes: try [key(0, -0.5, .easeOut), key(edge, 0.5)])]
        case .rise:
            edits = [.init(property: "centerY", keyframes: try [key(0, 1.5, .easeOut), key(edge, 0.5)])]
        case .zoomIn:
            edits = [.init(property: "scale", keyframes: try [key(0, 0.2, .easeOut), key(edge, 1)])]
        case .pulse:
            edits = [.init(property: "scale", keyframes: try [key(0, 1, .easeIn), key(duration / 2, 1.15, .easeOut), key(duration, 1)])]
        case .spin:
            edits = [.init(property: "rotationDegrees", keyframes: try [key(0, clip.rotationDegrees), key(duration, clip.rotationDegrees + 360)])]
        }
        let names = Set(edits.map(\.property))
        return clip.keyframeTracks.filter { !names.contains($0.property.replacingOccurrences(of: "transform.", with: "")) } + edits
    }
    /// Uniform speed along the supplied polyline. Each supplied vertex is
    /// retained; zero-length duplicates have no segment and are rejected.
    public static func motionPath(_ points: [ImageFreehandStroke.Point], start: Double = 0,
                                  duration: Double, in clip: MediaPreparedClip) throws -> [MediaKeyframeTrack] {
        guard (2...512).contains(points.count), start.isFinite, start >= 0, duration.isFinite, duration > 0,
              start + duration <= clip.timelineRange.durationSeconds + 0.000_001,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
            throw MediaPreparedCoreError.invalidOperation("motion path needs 2...512 normalized points within the clip")
        }
        var distances = [0.0]
        for i in 1..<points.count {
            let length = hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
            guard length > 0 else { throw MediaPreparedCoreError.invalidOperation("motion path has a zero-length segment") }
            distances.append(distances.last! + length)
        }
        let total = distances.last!
        var xs: [MediaKeyframe] = [], ys: [MediaKeyframe] = []
        for i in points.indices {
            let at = start + duration * distances[i] / total
            let stamp = try time(at)
            guard xs.last.map({ $0.time < stamp }) ?? true else {
                throw MediaPreparedCoreError.invalidOperation("motion-path segments are shorter than its time precision")
            }
            xs.append(.init(time: stamp, value: .number(points[i].x)))
            ys.append(.init(time: stamp, value: .number(points[i].y)))
        }
        return clip.keyframeTracks.filter { !["centerX", "centerY"].contains($0.property.replacingOccurrences(of: "transform.", with: "")) }
            + [.init(property: "centerX", keyframes: xs), .init(property: "centerY", keyframes: ys)]
    }

    /// Slice numeric animation without changing the visible curve. An easing
    /// segment is represented as its exact cubic subcurve, not restarted at
    /// its original control handles after a timeline trim.
    public static func sliced(_ tracks: [MediaKeyframeTrack], from offset: Double, duration: Double) throws -> [MediaKeyframeTrack] {
        guard offset.isFinite, duration.isFinite, duration > 0 else {
            throw MediaPreparedCoreError.invalidOperation("invalid animation slice")
        }
        return try tracks.map { track in
            guard !track.keyframes.isEmpty else { return track }
            let prepared = try preparedTracks([track], timescale: 90_000)[0]
            let end = offset + duration
            let sourceTimes = [offset] + track.keyframes.map(\.time.seconds).filter { $0 > offset && $0 < end } + [end]
            var keys: [MediaKeyframe] = []
            for (i, at) in sourceTimes.enumerated() {
                let value = try PreparedVideoFrameEvaluator.interpolate(track: prepared,
                    at: .init(seconds: max(0, at), timescale: 90_000)) ?? 0
                var result = try key(at - offset, value)
                if i + 1 < sourceTimes.count,
                   let leftIndex = track.keyframes.indices.last(where: { track.keyframes[$0].time.seconds <= at }),
                   leftIndex + 1 < track.keyframes.count {
                    let left = track.keyframes[leftIndex], right = track.keyframes[leftIndex + 1]
                    let span = right.time.seconds - left.time.seconds
                    if left.interpolation == .hold { result.interpolation = .hold }
                    else if let curve = cubic(for: left) {
                        let a = max(0, min(1, (at - left.time.seconds) / span))
                        let b = max(0, min(1, (sourceTimes[i + 1] - left.time.seconds) / span))
                        result.interpolation = .cubicBezier
                        result.curve = subcurve(curve, from: a, to: b)
                    }
                }
                keys.append(result)
            }
            return .init(property: track.property, keyframes: keys)
        }
    }
    private static func cubic(for key: MediaKeyframe) -> MediaCubicBezier? {
        switch key.interpolation {
        case .hold, .linear: nil
        case .easeIn: .init(control1: .init(x: 1 / 3, y: 0), control2: .init(x: 2 / 3, y: 1 / 3))
        case .easeOut: .init(control1: .init(x: 1 / 3, y: 2 / 3), control2: .init(x: 2 / 3, y: 1))
        case .cubicBezier: key.curve ?? .init()
        }
    }
    private static func subcurve(_ curve: MediaCubicBezier, from a: Double, to b: Double) -> MediaCubicBezier {
        typealias P = ImageFreehandStroke.Point
        func mix(_ a: P, _ b: P, _ t: Double) -> P { .init(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        func split(_ p: [P], _ t: Double) -> ([P], [P]) {
            let a = mix(p[0],p[1],t), b = mix(p[1],p[2],t), c = mix(p[2],p[3],t)
            let d = mix(a,b,t), e = mix(b,c,t), f = mix(d,e,t)
            return ([p[0],a,d,f],[f,e,c,p[3]])
        }
        let points = [P(x:0,y:0),curve.control1,curve.control2,P(x:1,y:1)]
        func parameter(_ x: Double) -> Double {
            var low = 0.0, high = 1.0
            for _ in 0..<48 { let t = (low + high) / 2, value = split(points,t).0[3].x; if value < x { low = t } else { high = t } }
            return (low + high) / 2
        }
        let ta = parameter(a), tb = parameter(b), prefix = split(points,tb).0
        let piece = split(prefix,tb > 0 ? ta / tb : 0).1
        let dx = piece[3].x - piece[0].x, dy = piece[3].y - piece[0].y
        guard dx > 0.000_000_001, dy > 0.000_000_001 else { return .init(control1:.init(x:1/3,y:1/3),control2:.init(x:2/3,y:2/3)) }
        func normalized(_ p: P) -> P { .init(x:max(0,min(1,(p.x-piece[0].x)/dx)), y:max(0,min(1,(p.y-piece[0].y)/dy))) }
        return .init(control1:normalized(piece[1]),control2:normalized(piece[2]))
    }
}
