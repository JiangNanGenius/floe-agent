// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import CoreImage

/// Motion is sampled in the oriented source image, before clip placement or
/// retiming. Coordinates use a top-left origin and normalized source pixels.
public struct MediaVideoMotionSource: Sendable, Codable, Hashable {
    public var assetID: UUID
    public var assetRevision: UInt64
    public var contentHash: String
    public var startSeconds: Double
    public var durationSeconds: Double
    public var frameDuration: Double
    public var width: Int
    public var height: Int
    public var endSeconds: Double { startSeconds + durationSeconds }

    public init(assetID: UUID, assetRevision: UInt64, contentHash: String,
                startSeconds: Double, durationSeconds: Double, frameDuration: Double,
                width: Int, height: Int) {
        self.assetID = assetID; self.assetRevision = assetRevision; self.contentHash = contentHash
        self.startSeconds = startSeconds; self.durationSeconds = durationSeconds
        self.frameDuration = frameDuration; self.width = width; self.height = height
    }
    public func validate() throws {
        guard assetRevision < UInt64.max,
              contentHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              startSeconds.isFinite, startSeconds >= 0,
              durationSeconds.isFinite, durationSeconds > 0, durationSeconds <= 120,
              frameDuration.isFinite, frameDuration > 0, frameDuration <= 1,
              durationSeconds >= frameDuration, (1...16384).contains(width), (1...16384).contains(height) else {
            throw MediaPreparedCoreError.invalidDocument("invalid motion source binding")
        }
    }
    public func contains(_ seconds: Double) -> Bool {
        seconds.isFinite && seconds >= startSeconds - 0.00002 && seconds < endSeconds + 0.00002
    }
    public func matches(clip: MediaPreparedClip) -> Bool {
        clip.assetID == assetID && clip.sourceRange.startSeconds >= startSeconds - 0.00002
            && clip.sourceRange.endSeconds <= endSeconds + 0.00002
    }
}

public struct MediaVideoTrackingSample: Sendable, Codable, Hashable {
    public enum State: String, Sendable, Codable, Hashable { case seed, tracked, lost }
    public var sourceSeconds: Double
    public var region: NormalizedRect?
    public var confidence: Double
    public var state: State
    public init(sourceSeconds: Double, region: NormalizedRect?, confidence: Double, state: State) {
        self.sourceSeconds = sourceSeconds; self.region = region
        self.confidence = confidence; self.state = state
    }
}

public struct MediaVideoTracking: Sendable, Codable, Hashable {
    public var source: MediaVideoMotionSource
    public var minimumConfidence: Double
    public var samples: [MediaVideoTrackingSample]
    public init(source: MediaVideoMotionSource, minimumConfidence: Double, samples: [MediaVideoTrackingSample]) {
        self.source = source; self.minimumConfidence = minimumConfidence; self.samples = samples
    }
    public func validate() throws {
        try source.validate()
        guard minimumConfidence.isFinite, (0.05...0.95).contains(minimumConfidence) else {
            throw MediaPreparedCoreError.invalidDocument("invalid tracking threshold")
        }
        try MediaVideoMotionMath.validateTimes(samples.map(\.sourceSeconds), source: source)
        for (index, sample) in samples.enumerated() {
            guard sample.confidence.isFinite, (0...1).contains(sample.confidence),
                  (sample.state == .seed) == (index == 0),
                  (sample.state == .lost) == (sample.region == nil) else {
                throw MediaPreparedCoreError.invalidDocument("invalid tracking observation")
            }
            if let region = sample.region { try MediaVideoMotionMath.validateRegion(region) }
            if sample.state == .tracked, sample.confidence < minimumConfidence {
                throw MediaPreparedCoreError.invalidDocument("tracking confidence is below the accepted threshold")
            }
        }
    }
    /// Lost observations remain lost. Never interpolate through an occlusion.
    public func observation(at sourceSeconds: Double) -> MediaVideoTrackingSample? {
        guard source.contains(sourceSeconds), let first = samples.first, let last = samples.last else { return nil }
        if sourceSeconds <= first.sourceSeconds { return first }
        if sourceSeconds >= last.sourceSeconds { return last }
        let upper = samples.firstIndex { $0.sourceSeconds >= sourceSeconds }!
        let a = samples[upper - 1], b = samples[upper]
        guard a.state != .lost, b.state != .lost, let ar = a.region, let br = b.region else {
            return .init(sourceSeconds: sourceSeconds, region: nil, confidence: 0, state: .lost)
        }
        let f = (sourceSeconds - a.sourceSeconds) / (b.sourceSeconds - a.sourceSeconds)
        return .init(sourceSeconds: sourceSeconds,
            region: .init(x: ar.x + (br.x-ar.x)*f, y: ar.y + (br.y-ar.y)*f,
                          width: ar.width + (br.width-ar.width)*f, height: ar.height + (br.height-ar.height)*f),
            confidence: min(a.confidence, b.confidence), state: .tracked)
    }
}

public struct MediaVideoStabilizationSample: Sendable, Codable, Hashable {
    public var sourceSeconds: Double
    /// Cumulative measured camera displacement, in normalized source pixels.
    public var motionX: Double
    public var motionY: Double
    /// Smoothed path minus measured path; translations applied by the renderer.
    public var correctionX: Double
    public var correctionY: Double
    public init(sourceSeconds: Double, motionX: Double, motionY: Double, correctionX: Double = 0, correctionY: Double = 0) {
        self.sourceSeconds = sourceSeconds; self.motionX = motionX; self.motionY = motionY
        self.correctionX = correctionX; self.correctionY = correctionY
    }
}

public struct MediaVideoStabilization: Sendable, Codable, Hashable {
    public var source: MediaVideoMotionSource
    public var smoothingSeconds: Double
    public var strength: Double
    public var cropEdges: Bool
    public var cropScale: Double
    public var samples: [MediaVideoStabilizationSample]
    public init(source: MediaVideoMotionSource, smoothingSeconds: Double, strength: Double,
                cropEdges: Bool, cropScale: Double, samples: [MediaVideoStabilizationSample]) {
        self.source = source; self.smoothingSeconds = smoothingSeconds; self.strength = strength
        self.cropEdges = cropEdges; self.cropScale = cropScale; self.samples = samples
    }
    public func validate() throws {
        try source.validate()
        guard smoothingSeconds.isFinite, (0.05...2).contains(smoothingSeconds),
              strength.isFinite, (0...1).contains(strength), cropScale.isFinite,
              (1...1.35).contains(cropScale), cropEdges || cropScale == 1 else {
            throw MediaPreparedCoreError.invalidDocument("invalid stabilization controls")
        }
        try MediaVideoMotionMath.validateTimes(samples.map(\.sourceSeconds), source: source)
        for sample in samples {
            guard [sample.motionX, sample.motionY, sample.correctionX, sample.correctionY]
                .allSatisfy({ $0.isFinite && abs($0) <= 8 }) else {
                throw MediaPreparedCoreError.invalidDocument("invalid stabilization observation")
            }
            if cropEdges, cropScale + 0.00001 < 1 + 2 * max(abs(sample.correctionX), abs(sample.correctionY)) {
                throw MediaPreparedCoreError.invalidDocument("stabilization crop does not cover translated edges")
            }
        }
    }
    public func correction(at seconds: Double) throws -> (x: Double, y: Double) {
        guard source.contains(seconds), let a = samples.first, let z = samples.last else {
            throw MediaPreparedCoreError.invalidOperation("re-analyze the extended source range before stabilizing")
        }
        if seconds <= a.sourceSeconds { return (a.correctionX, a.correctionY) }
        if seconds >= z.sourceSeconds { return (z.correctionX, z.correctionY) }
        let i = samples.firstIndex { $0.sourceSeconds >= seconds }!, b = samples[i], p = samples[i-1]
        let f = (seconds-p.sourceSeconds)/(b.sourceSeconds-p.sourceSeconds)
        return (p.correctionX+(b.correctionX-p.correctionX)*f,p.correctionY+(b.correctionY-p.correctionY)*f)
    }
    /// Same source-space operation is used before grading/masks/placement by
    /// the current-frame preview and the export renderer.
    public func apply(to image: CIImage, sourceSeconds: Double) throws -> CIImage {
        let c = try correction(at: sourceSeconds), bounds = image.extent
        guard bounds.width > 0, bounds.height > 0 else { throw PreparedVideoError.renderFailed("empty motion source") }
        let centered = CGAffineTransform(translationX: -bounds.midX, y: -bounds.midY)
            .concatenating(.init(scaleX: cropScale, y: cropScale))
            .concatenating(.init(translationX: bounds.midX+c.x*bounds.width, y: bounds.midY-c.y*bounds.height))
        return image.transformed(by: centered).cropped(to: bounds)
    }
}

public enum MediaVideoMotionMath {
    public static func sourceSeconds(clip: MediaPreparedClip, timelineSeconds: Double) throws -> Double? {
        guard timelineSeconds.isFinite, timelineSeconds >= clip.timelineRange.startSeconds,
              timelineSeconds < clip.timelineRange.endSeconds else { return nil }
        return try MediaSourcePlaybackMath.sourceSeconds(sourceStart: clip.sourceRange.startSeconds,
            sourceDuration: clip.sourceRange.durationSeconds, speed: clip.speed,
            localTime: timelineSeconds-clip.timelineRange.startSeconds, playback: clip.sourcePlayback,
            frameDuration: clip.stabilization?.source.frameDuration ?? clip.videoTracking?.source.frameDuration ?? 1/30)
    }
    /// A viewing overlay, never burned into exported media. Uses the same
    /// retiming, keyframe evaluator and source-space stabilization as rendering.
    public static func trackingCorners(clip: MediaPreparedClip, canvas: MediaCanvas,
                                       timelineSeconds: Double) throws -> [ImageFreehandStroke.Point]? {
        guard let tracking = clip.videoTracking, let seconds = try sourceSeconds(clip: clip,timelineSeconds: timelineSeconds),
              let r = tracking.observation(at: seconds)?.region else { return nil }
        let width = Double(tracking.source.width), height = Double(tracking.source.height)
        let cw = Double(canvas.width), ch = Double(canvas.height)
        var cx = 0.5, cy = 0.5, scale = 1.0, rotation = clip.rotationDegrees, opacity = clip.visualOpacity ?? 1
        let time = try PreparedVideoTime(seconds: timelineSeconds-clip.timelineRange.startSeconds,timescale: 90_000)
        for track in try MediaAnimation.preparedTracks(clip.keyframeTracks,timescale: 90_000) {
            guard let value = try PreparedVideoFrameEvaluator.interpolate(track: track,at: time) else { continue }
            switch track.property {
            case .centerX: cx = value
            case .centerY: cy = value
            case .scale: scale = value
            case .rotationDegrees: rotation = value
            case .opacity: opacity *= value
            }
        }
        guard opacity > 0 else { return nil }
        let fit = min(cw/width,ch/height)*scale, angle = rotation * .pi/180
        let correction = try clip.stabilization?.correction(at: seconds) ?? (x: 0.0,y: 0.0)
        let zoom = clip.stabilization?.cropScale ?? 1
        return [(r.x,r.y),(r.x+r.width,r.y),(r.x+r.width,r.y+r.height),(r.x,r.y+r.height)].map { x,y in
            let dx = ((x-0.5)*zoom+correction.x)*width*fit
            let dy = ((y-0.5)*zoom+correction.y)*height*fit
            return .init(x: cx+(dx*cos(angle)-dy*sin(angle))/cw, y: cy+(dx*sin(angle)+dy*cos(angle))/ch)
        }
    }
    static func validateTimes(_ times: [Double], source: MediaVideoMotionSource) throws {
        guard (2...3600).contains(times.count), let first = times.first, let last = times.last,
              abs(first-source.startSeconds) <= 0.00002,
              last >= source.endSeconds-source.frameDuration-0.00002,
              times.allSatisfy({ source.contains($0) }),
              zip(times,times.dropFirst()).allSatisfy({ $0 < $1 && $1-$0 <= 1.00001 }) else {
            throw MediaPreparedCoreError.invalidDocument("motion samples must cover the source interval in order")
        }
    }
    public static func validateRegion(_ r: NormalizedRect) throws {
        guard [r.x,r.y,r.width,r.height].allSatisfy(\.isFinite), r.width >= 0.01, r.height >= 0.01,
              r.x >= 0, r.y >= 0, r.x+r.width <= 1.00001, r.y+r.height <= 1.00001 else {
            throw MediaPreparedCoreError.invalidOperation("select a rectangular object inside the source frame")
        }
    }
    public static func stabilize(source: MediaVideoMotionSource, measured: [MediaVideoStabilizationSample],
                                 smoothingSeconds: Double, strength: Double, cropEdges: Bool) throws -> MediaVideoStabilization {
        guard smoothingSeconds.isFinite, (0.05...2).contains(smoothingSeconds), strength.isFinite, (0...1).contains(strength) else {
            throw MediaPreparedCoreError.invalidOperation("invalid stabilization controls")
        }
        try source.validate(); try validateTimes(measured.map(\.sourceSeconds), source: source)
        guard measured.allSatisfy({ [$0.motionX,$0.motionY].allSatisfy({ $0.isFinite && abs($0) <= 8 }) }) else {
            throw MediaPreparedCoreError.invalidOperation("motion path exceeds the analysis bound")
        }
        var corrected = measured
        for i in measured.indices {
            let center = measured[i], window = measured.filter { abs($0.sourceSeconds-center.sourceSeconds) <= smoothingSeconds/2+0.000001 }
            let x = window.reduce(0) { $0+$1.motionX }/Double(window.count)
            let y = window.reduce(0) { $0+$1.motionY }/Double(window.count)
            corrected[i].correctionX = (x-center.motionX)*strength
            corrected[i].correctionY = (y-center.motionY)*strength
        }
        let margin = corrected.reduce(0) { max($0,abs($1.correctionX),abs($1.correctionY)) }
        let zoom = cropEdges ? 1+2*margin+0.000001 : 1
        guard zoom <= 1.35 else {
            throw MediaPreparedCoreError.invalidOperation("motion needs excessive cropping; reduce smoothing or allow visible borders")
        }
        let result = MediaVideoStabilization(source: source, smoothingSeconds: smoothingSeconds, strength: strength,
            cropEdges: cropEdges, cropScale: zoom, samples: corrected)
        try result.validate(); return result
    }
}
