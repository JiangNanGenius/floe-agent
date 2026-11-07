// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import AVFoundation
import UIKit
import FloeCAD
import FloeSimulationCore
import FloeSimulationAnimation

@MainActor private final class SimulationVideoWriterControl {
    let writer:AVAssetWriter
    init(_ writer:AVAssetWriter) { self.writer = writer }
    func cancel() { if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() } }
}

@MainActor enum CADSimulationVideoExporter {
    static func render(bake:SimulationAnimationBake,to output:URL,width:Int = 1280,height:Int = 720,
                       maximumBytes:Int = 256_000_000,
                       frame:@escaping @Sendable (Int) async throws -> CADSimulationDisplay,
                       progress:@escaping SimulationProgressHandler) async throws {
        let fps = bake.framesPerSecond
        guard (1...60).contains(fps), let duration = bake.frames.last?.timeSeconds, duration > 0, duration <= 600,
              bake.frames.first?.timeSeconds == 0, width.isMultiple(of:2), height.isMultiple(of:2),
              (64...1920).contains(width),(64...1080).contains(height),output.isFileURL,output.pathExtension == "mp4",
              !FileManager.default.fileExists(atPath:output.path) else { throw SimulationError.invalidInput("Use a new project-owned MP4 destination and a valid frame size.") }
        let count = Int(ceil(duration*Double(fps)))
        guard count > 0, count <= 36_000, bake.frames.count >= count else { throw SimulationError.resourceLimit("The video exceeds its frame budget.") }
        let renderer = try CADSimulationFrameRenderer()
        // Frame the actual motion envelope once; a falling or deforming model
        // must not leave a camera fitted only to its initial CAD position.
        var lo = SIMD3<Float>(repeating:.infinity), hi = SIMD3<Float>(repeating:-.infinity)
        for index in 0..<count {
            try Task.checkCancellation()
            let display = try await frame(index)
            for surface in display.surfaces { for p in surface.positionsMM {
                lo = SIMD3(min(lo.x,p.x),min(lo.y,p.y),min(lo.z,p.z)); hi = SIMD3(max(hi.x,p.x),max(hi.y,p.y),max(hi.z,p.z))
            } }
            if index%8 == 0 { await progress(.init(stage:"framing",completed:index+1,total:count)) }
        }
        guard lo.x.isFinite else { throw SimulationError.invalidInput("The animation has no visible geometry.") }
        renderer.fit(boundsMinMM:lo,boundsMaxMM:hi,width:width,height:height)
        let writer = try AVAssetWriter(outputURL:output,fileType:.mp4), control = SimulationVideoWriterControl(writer)
        let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height,
            AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:3_000_000,AVVideoExpectedSourceFrameRateKey:fps,AVVideoMaxKeyFrameIntervalKey:fps*2]])
        input.expectsMediaDataInRealTime = false
        let attributes:[String:Any] = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,
            kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:attributes)
        guard writer.canAdd(input) else { throw SimulationError.solverFailure("The video encoder cannot accept these settings.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? SimulationError.solverFailure("The video encoder could not start.") }
        writer.startSession(atSourceTime:.zero)
        var completed = false
        defer { if !completed { control.cancel(); try? FileManager.default.removeItem(at:output) } }
        try await withTaskCancellationHandler {
            for index in 0..<count {
                try Task.checkCancellation()
                let display = try await frame(index), png = try renderer.capturePNG(display,width:width,height:height)
                guard let image = UIImage(data:png)?.cgImage, let pool = adaptor.pixelBufferPool else { throw SimulationError.solverFailure("The rendered video frame could not be decoded.") }
                let start = ContinuousClock.now
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    guard writer.status == .writing, start.duration(to:.now) < .seconds(30) else { throw writer.error ?? SimulationError.solverFailure("The video encoder stopped accepting frames.") }
                    try await Task.sleep(for:.milliseconds(5))
                }
                try autoreleasepool {
                    var buffer:CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,pool,&buffer) == kCVReturnSuccess, let buffer else { throw SimulationError.resourceLimit("The video encoder could not allocate a frame.") }
                    CVPixelBufferLockBaseAddress(buffer,[])
                    defer { CVPixelBufferUnlockBaseAddress(buffer,[]) }
                    let flags = CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedFirst.rawValue
                    guard let context = CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:width,height:height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:flags) else { throw SimulationError.solverFailure("The video frame buffer is unavailable.") }
                    context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
                    guard adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(index),timescale:Int32(fps))) else { throw writer.error ?? SimulationError.solverFailure("The video encoder rejected a frame.") }
                }
                if index%8 == 0 || index == count-1 {
                    await progress(.init(stage:"encoding",completed:index+1,total:count))
                    let bytes = (try? output.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
                    guard bytes <= maximumBytes else { throw SimulationError.resourceLimit("The MP4 exceeds its export budget.") }
                }
            }
            input.markAsFinished(); writer.endSession(atSourceTime:CMTime(seconds:duration,preferredTimescale:600_000))
            await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? SimulationError.solverFailure("The video encoder did not finish.") }
        } onCancel: { Task { @MainActor in control.cancel() } }
        let asset = AVURLAsset(url:output)
        let tracks = try await asset.loadTracks(withMediaType:.video), actualDuration = try await asset.load(.duration).seconds
        guard tracks.count == 1, abs(actualDuration-duration) <= 1/Double(fps)+0.002,
              let track = tracks.first, try await track.load(.naturalSize) == CGSize(width:width,height:height) else { throw SimulationError.solverFailure("The encoded video does not match its requested dimensions or duration.") }
        let reader = try AVAssetReader(asset:asset), samples = AVAssetReaderTrackOutput(track:track,outputSettings:nil)
        defer { if reader.status == .reading { reader.cancelReading() } }
        guard reader.canAdd(samples) else { throw SimulationError.solverFailure("The encoded video could not be read back.") }
        reader.add(samples); guard reader.startReading() else { throw reader.error ?? SimulationError.solverFailure("The encoded video could not be verified.") }
        var frames = 0
        while let sample = samples.copyNextSampleBuffer() {
            try Task.checkCancellation(); frames += CMSampleBufferGetNumSamples(sample)
            guard frames <= count else { reader.cancelReading(); throw SimulationError.solverFailure("The encoded video contains unexpected extra frames.") }
        }
        guard reader.status == .completed, frames == count,
              (try output.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= maximumBytes else { throw SimulationError.solverFailure("The encoded video has missing frames or exceeds its size budget.") }
        completed = true
    }
}
#endif
