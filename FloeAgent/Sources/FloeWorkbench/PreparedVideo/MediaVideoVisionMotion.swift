// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import Vision

/// Request state is owned by the motion service actor. No Vision request,
/// observation or sequence handler crosses actors or survives an operation.
final class MediaVideoObjectTracker {
    private let handler = VNSequenceRequestHandler()
    private let request: VNTrackObjectRequest
    private let seed: NormalizedRect
    private let threshold: Double
    private var started = false
    private var lost = false

    init(region: NormalizedRect, minimumConfidence: Double) throws {
        try MediaVideoMotionMath.validateRegion(region)
        guard minimumConfidence.isFinite, (0.05...0.95).contains(minimumConfidence) else {
            throw MediaPreparedCoreError.invalidOperation("invalid tracking confidence")
        }
        self.seed = region; self.threshold = minimumConfidence
        let observation = VNDetectedObjectObservation(boundingBox: CGRect(x: region.x,
            y: 1-region.y-region.height, width: region.width, height: region.height))
        request = VNTrackObjectRequest(detectedObjectObservation: observation)
        request.trackingLevel = .accurate
    }
    func consume(_ image: CGImage, sourceSeconds: Double, last: Bool,
                 cancellation: PreparedVideoCancellation) throws -> MediaVideoTrackingSample {
        try Task.checkCancellation(); try cancellation.check()
        if lost { return .init(sourceSeconds: sourceSeconds, region: nil, confidence: 0, state: .lost) }
        request.isLastFrame = last
        try handler.perform([request], on: image, orientation: .up)
        try cancellation.check(); try Task.checkCancellation()
        if !started {
            started = true
            if let observation = request.results?.first as? VNDetectedObjectObservation { request.inputObservation = observation }
            return .init(sourceSeconds: sourceSeconds, region: seed, confidence: 1, state: .seed)
        }
        guard let observation = request.results?.first as? VNDetectedObjectObservation, Double(observation.confidence) >= threshold else {
            lost = true
            return .init(sourceSeconds: sourceSeconds, region: nil, confidence: Double(request.results?.first?.confidence ?? 0), state: .lost)
        }
        let r = observation.boundingBox
        let region = NormalizedRect(x: r.minX, y: 1-r.maxY, width: r.width, height: r.height)
        guard (try? MediaVideoMotionMath.validateRegion(region)) != nil else {
            lost = true; return .init(sourceSeconds: sourceSeconds, region: nil, confidence: 0, state: .lost)
        }
        request.inputObservation = observation
        return .init(sourceSeconds: sourceSeconds, region: region, confidence: Double(observation.confidence), state: .tracked)
    }
}

final class MediaVideoTranslationTracker {
    private var previous: CGImage?
    private var x: Double = 0
    private var y: Double = 0
    func consume(_ image: CGImage, sourceSeconds: Double,
                 cancellation: PreparedVideoCancellation) throws -> MediaVideoStabilizationSample {
        try cancellation.check(); try Task.checkCancellation()
        defer { previous = image }
        guard let previous else { return .init(sourceSeconds: sourceSeconds, motionX: 0, motionY: 0) }
        guard previous.width == image.width, previous.height == image.height else {
            throw MediaPreparedCoreError.invalidOperation("source dimensions changed during motion analysis")
        }
        // SDK contract: targeted image is floating; handler image is reference.
        // Alignment maps current -> previous. Negate it to accumulate camera
        // displacement, and invert Y exactly once for our top-left coordinates.
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: image, options: [:])
        try VNImageRequestHandler(cgImage: previous, options: [:]).perform([request])
        try cancellation.check(); try Task.checkCancellation()
        guard let observation = request.results?.first else {
            throw MediaPreparedCoreError.invalidOperation("the frames have insufficient matching detail for stabilization")
        }
        let t = observation.alignmentTransform
        let dx = -t.tx / Double(image.width), dy = t.ty / Double(image.height)
        guard [t.a,t.b,t.c,t.d,t.tx,t.ty].allSatisfy(\.isFinite),
              abs(t.a-1) < 0.0001, abs(t.d-1) < 0.0001, abs(t.b) < 0.0001, abs(t.c) < 0.0001,
              abs(dx) <= 0.15, abs(dy) <= 0.15 else {
            throw MediaPreparedCoreError.invalidOperation("large motion or a scene cut interrupted stabilization; split the clip and retry")
        }
        x += dx; y += dy
        return .init(sourceSeconds: sourceSeconds, motionX: x, motionY: y)
    }
}
