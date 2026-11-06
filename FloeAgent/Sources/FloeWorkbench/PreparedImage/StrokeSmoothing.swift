// SPDX-License-Identifier: MPL-2.0
// Adapted from the qualified Floe per-sample brush contracts.
// FloeBrushCore — smoothing contract.
//
// The midpoint quadratic construction below is the same shape Drawsana uses
// in PenShape.render(in:) (pinned 3862163d899830cd0756f7b00d01628b6048ed9b):
// line to the first midpoint, quadratic through each interior sample, then a
// line to the final sample. We keep it here as an inspectable comparison
// contract; the iOS adapter calls Drawsana's actual PenShape renderer.

import Foundation

public struct MediaPreparedCurveSegment: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case line
        case quad
    }

    public var kind: Kind
    public var start: MediaPreparedBrushPoint
    public var control: MediaPreparedBrushPoint?
    public var end: MediaPreparedBrushPoint
    /// Width at the start/end of this segment. Rendering adapters interpolate
    /// or split segments when a renderer only accepts one width per path.
    public var startWidth: Double
    public var endWidth: Double
    public var startOpacity: Double
    public var endOpacity: Double

    public init(
        kind: Kind,
        start: MediaPreparedBrushPoint,
        control: MediaPreparedBrushPoint? = nil,
        end: MediaPreparedBrushPoint,
        startWidth: Double,
        endWidth: Double,
        startOpacity: Double,
        endOpacity: Double
    ) {
        self.kind = kind
        self.start = start
        self.control = control
        self.end = end
        self.startWidth = startWidth
        self.endWidth = endWidth
        self.startOpacity = startOpacity
        self.endOpacity = endOpacity
    }

    public func point(at t: Double) -> MediaPreparedBrushPoint {
        let t = min(max(t, 0), 1)
        switch kind {
        case .line:
            return MediaPreparedBrushPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            )
        case .quad:
            let c = control ?? start
            let oneMinusT = 1 - t
            return MediaPreparedBrushPoint(
                x: oneMinusT * oneMinusT * start.x + 2 * oneMinusT * t * c.x + t * t * end.x,
                y: oneMinusT * oneMinusT * start.y + 2 * oneMinusT * t * c.y + t * t * end.y
            )
        }
    }

    public func width(at t: Double) -> Double {
        startWidth + (endWidth - startWidth) * min(max(t, 0), 1)
    }

    public func opacity(at t: Double) -> Double {
        startOpacity + (endOpacity - startOpacity) * min(max(t, 0), 1)
    }
}

public struct MediaPreparedSmoothedStroke: Codable, Hashable, Sendable {
    public var segments: [MediaPreparedCurveSegment]
    /// A stroke with one sample renders as a dot rather than an empty path.
    public var dot: MediaPreparedResolvedSample?
    public var sampleCount: Int

    public init(segments: [MediaPreparedCurveSegment], dot: MediaPreparedResolvedSample? = nil, sampleCount: Int) {
        self.segments = segments
        self.dot = dot
        self.sampleCount = sampleCount
    }

    public var isEmpty: Bool {
        segments.isEmpty && dot == nil
    }

    /// Samples the smoothed path for geometry assertions and deterministic
    /// raster fallbacks.
    public func sampledPoints(stepsPerSegment: Int = 12) -> [MediaPreparedBrushPoint] {
        guard stepsPerSegment > 0 else { return [] }
        if let dot {
            return [dot.point]
        }
        guard let first = segments.first else { return [] }
        var points: [MediaPreparedBrushPoint] = [first.start]
        for segment in segments {
            for step in 1...stepsPerSegment {
                points.append(segment.point(at: Double(step) / Double(stepsPerSegment)))
            }
        }
        return points
    }

    public var maximumWidth: Double {
        if let dot { return dot.width }
        return segments.reduce(0) { max($0, max($1.startWidth, $1.endWidth)) }
    }

    public var minimumWidth: Double {
        if let dot { return dot.width }
        return segments.reduce(Double.greatestFiniteMagnitude) {
            min($0, min($1.startWidth, $1.endWidth))
        }
    }

    public var maximumOpacity: Double {
        if let dot { return dot.opacity }
        return segments.reduce(0) { max($0, max($1.startOpacity, $1.endOpacity)) }
    }

    public var minimumOpacity: Double {
        if let dot { return dot.opacity }
        return segments.reduce(Double.greatestFiniteMagnitude) {
            min($0, min($1.startOpacity, $1.endOpacity))
        }
    }
}

public enum MediaPreparedStrokeSmoother {
    /// Builds a quadratic midpoint path from resolved per-sample values.
    /// Two samples produce one line segment (Drawsana's one-segment case);
    /// three or more produce the first line + interior quads + final line.
    public static func smooth(_ samples: [MediaPreparedResolvedSample]) -> MediaPreparedSmoothedStroke {
        guard !samples.isEmpty else {
            return MediaPreparedSmoothedStroke(segments: [], dot: nil, sampleCount: 0)
        }
        guard samples.count > 1 else {
            return MediaPreparedSmoothedStroke(segments: [], dot: samples[0], sampleCount: 1)
        }
        if samples.count == 2 {
            let a = samples[0]
            let b = samples[1]
            return MediaPreparedSmoothedStroke(
                segments: [
                    MediaPreparedCurveSegment(
                        kind: .line,
                        start: a.point,
                        end: b.point,
                        startWidth: a.width,
                        endWidth: b.width,
                        startOpacity: a.opacity,
                        endOpacity: b.opacity
                    )
                ],
                sampleCount: 2
            )
        }

        var segments: [MediaPreparedCurveSegment] = []
        let firstMid = midpoint(samples[0].point, samples[1].point)
        segments.append(
            MediaPreparedCurveSegment(
                kind: .line,
                start: samples[0].point,
                end: firstMid,
                startWidth: samples[0].width,
                endWidth: samples[1].width,
                startOpacity: samples[0].opacity,
                endOpacity: samples[1].opacity
            )
        )

        for index in 1..<(samples.count - 1) {
            let previousMid = midpoint(samples[index - 1].point, samples[index].point)
            let nextMid = midpoint(samples[index].point, samples[index + 1].point)
            segments.append(
                MediaPreparedCurveSegment(
                    kind: .quad,
                    start: previousMid,
                    control: samples[index].point,
                    end: nextMid,
                    startWidth: samples[index].width,
                    endWidth: samples[index].width,
                    startOpacity: samples[index].opacity,
                    endOpacity: samples[index].opacity
                )
            )
        }

        let lastMid = midpoint(samples[samples.count - 2].point, samples[samples.count - 1].point)
        let last = samples[samples.count - 1]
        segments.append(
            MediaPreparedCurveSegment(
                kind: .line,
                start: lastMid,
                end: last.point,
                startWidth: last.width,
                endWidth: last.width,
                startOpacity: last.opacity,
                endOpacity: last.opacity
            )
        )
        return MediaPreparedSmoothedStroke(segments: segments, sampleCount: samples.count)
    }

    private static func midpoint(_ a: MediaPreparedBrushPoint, _ b: MediaPreparedBrushPoint) -> MediaPreparedBrushPoint {
        MediaPreparedBrushPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// Maximum direction change (degrees) between consecutive sampled points.
    /// Used by tests to prove a right-angle polyline is rounded rather than
    /// passed through as an abrupt corner.
    public static func maximumTurnDegrees(_ points: [MediaPreparedBrushPoint]) -> Double {
        guard points.count >= 3 else { return 0 }
        var maximum = 0.0
        for index in 2..<points.count {
            let a = points[index - 2]
            let b = points[index - 1]
            let c = points[index]
            let v1 = (b.x - a.x, b.y - a.y)
            let v2 = (c.x - b.x, c.y - b.y)
            let l1 = (v1.0 * v1.0 + v1.1 * v1.1).squareRoot()
            let l2 = (v2.0 * v2.0 + v2.1 * v2.1).squareRoot()
            guard l1 > 1e-9, l2 > 1e-9 else { continue }
            let dot = min(max((v1.0 * v2.0 + v1.1 * v2.1) / (l1 * l2), -1), 1)
            maximum = max(maximum, acos(dot) * 180 / .pi)
        }
        return maximum
    }
}
