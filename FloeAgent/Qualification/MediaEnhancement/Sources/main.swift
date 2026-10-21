// Floe media-enhancement native qualification host.
//
// Runs the production FloeMedia enhancement pipeline on macOS against
// synthetic CFR video (with audio), a rotated video, and a still image. The
// cases exercise the real VideoToolbox frame processors, the Core ML
// RIFE/Real-ESRGAN bundles installed through the production local-install
// path, MetalFX spatial scaling, the image path, the guards (overwrite,
// path escape, wrong-engine rejection) and cancellation.
//
// Simulator is intentionally not used: Apple's headers exclude the
// VTFrameProcessor frame-rate/super-resolution processors from Simulator
// builds, and values measured here are macOS-native evidence only.

import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import FloeCore
import FloeTools
import FloeMedia

#if canImport(AppKit)
import AppKit
#endif

struct CaseResult: Codable {
    var name: String
    var status: String
    var detail: String
    var metrics: [String: String]
    var required: Bool
}

let arguments = CommandLine.arguments
func argument(_ name: String, default defaultValue: String? = nil) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return defaultValue }
    return arguments[index + 1]
}

let workRoot = URL(fileURLWithPath: argument("--work", default: NSTemporaryDirectory() + "floe-media-t2-\(UUID().uuidString)")!)
let bundlesRoot = URL(fileURLWithPath: argument("--bundles", default: "Local/Artifacts/capability-closure-20261014/media/bundles")!)

try? FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
let workspace = workRoot.appendingPathComponent("workspace", isDirectory: true)
try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

if arguments.contains("--synth-only") {
    do {
        try Synthesizer.video(url: workRoot.appendingPathComponent("synth-only.mp4"), width: 320, height: 180, fps: 30, seconds: 2)
        print("SYNTH_OK")
        exit(0)
    } catch {
        print("SYNTH_FAIL \(error)")
        exit(1)
    }
}

var results: [CaseResult] = []
var reportEnvironment: [String: String] = [:]

@MainActor
func record(_ name: String, status: String, detail: String, metrics: [String: String] = [:], required: Bool = true) {
    results.append(CaseResult(name: name, status: status, detail: detail, metrics: metrics, required: required))
    let line = "[\(status.uppercased())] \(name) — \(detail)"
    FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
}

func sha256(_ url: URL) -> String { (try? FloeDigest.sha256Hex(ofFileAt: url)) ?? "" }

// MARK: - Synthetic media

enum Synthesizer {
    static func makePixelBuffer(width: Int, height: Int, index: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        // Deliberately not IOSurface-backed: the harness writer stalls after
        // ~1.6s when surface-backed source frames are appended while the audio
        // input has not been fed yet. Production frames are written with the
        // audio stream running in parallel, so this only affects synthesis.
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
              let buffer else {
            throw FloeError.internalError("could not allocate a synthesis buffer")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let boxX = (index * 7) % max(1, width - 48)
        let boxY = (index * 3) % max(1, height - 48)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                var r = UInt8((x * 255) / max(1, width - 1))
                var g = UInt8((y * 255) / max(1, height - 1))
                var b = UInt8(60 + ((x + y + index * 11) % 120))
                if x >= boxX, x < boxX + 48, y >= boxY, y < boxY + 48 {
                    r = 255; g = 255; b = 255
                }
                base[offset] = b
                base[offset + 1] = g
                base[offset + 2] = r
                base[offset + 3] = 255
            }
        }
        return buffer
    }

    static func video(
        url: URL, width: Int, height: Int, fps: Double, seconds: Double,
        rotate: Bool = false, withAudio: Bool = true
    ) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        if rotate {
            input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        // The video input must be added before the audio input: AVAssetWriter
        // holds video readiness until the earliest-added effectful input has
        // data, and an audio-first order stalls the first video append.
        guard writer.canAdd(input) else { throw FloeError.internalError("synthesis writer rejected video input") }
        writer.add(input)
        var audioInput: AVAssetWriterInput?
        if withAudio, let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1
            ])
            audio.expectsMediaDataInRealTime = false
            if writer.canAdd(audio) { writer.add(audio); audioInput = audio }
            _ = format
        }
        guard writer.startWriting() else { throw writer.error ?? FloeError.internalError("synthesis writer failed") }
        writer.startSession(atSourceTime: .zero)

        // Audio is written first: a pending audio input with no samples
        // stalls video readiness after ~1.6s of video in AVAssetWriter.
        if let audioInput, let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) {
            let sampleRate = 44100.0
            let total = Int(seconds * sampleRate)
            var written = 0
            let chunk = 4410
            while written < total {
                var spins = 0
                while !audioInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.002)
                    spins += 1
                    if spins > 2500 { throw FloeError.internalError("synthesis audio input never became ready (status \(writer.status.rawValue))") }
                }
                let frames = min(chunk, total - written)
                var samples = [Float](repeating: 0, count: frames)
                for index in 0..<frames {
                    samples[index] = Float(sin(2.0 * Double.pi * 440.0 * (Double(written + index) / sampleRate))) * 0.2
                }
                let byteCount = frames * MemoryLayout<Float>.size
                var blockBuffer: CMBlockBuffer?
                guard CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                    blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                    offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &blockBuffer
                ) == kCVReturnSuccess, let blockBuffer else {
                    throw FloeError.internalError("synthesis audio block failed")
                }
                samples.withUnsafeBytes { raw in
                    _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
                }
                var timing = CMSampleTimingInfo(
                    duration: CMTime(value: 1, timescale: Int32(sampleRate)),
                    presentationTimeStamp: CMTime(value: Int64(written), timescale: Int32(sampleRate)),
                    decodeTimeStamp: .invalid
                )
                var sampleBuffer: CMSampleBuffer?
                guard CMSampleBufferCreateReady(
                    allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
                    formatDescription: format.formatDescription, sampleCount: CMItemCount(frames),
                    sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                    sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer
                ) == noErr, let sampleBuffer else {
                    throw FloeError.internalError("synthesis audio sample failed")
                }
                guard audioInput.append(sampleBuffer) else {
                    throw writer.error ?? FloeError.internalError("synthesis audio append failed")
                }
                written += frames
            }
            audioInput.markAsFinished()
        }
        let frameCount = Int(seconds * fps)
        for index in 0..<frameCount {
            var spins = 0
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
                spins += 1
                if spins > 2500 { throw FloeError.internalError("synthesis video input never became ready at frame \(index)/\(frameCount) (status \(writer.status.rawValue), pool=\(adaptor.pixelBufferPool != nil))") }
            }
            let buffer = try makePixelBuffer(width: width, height: height, index: index)
            let time = CMTime(value: Int64((Double(index) * 600.0 / fps).rounded()), timescale: 600)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? FloeError.internalError("synthesis append failed")
            }
        }
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status == .completed else {
            throw writer.error ?? FloeError.internalError("synthesis finish failed")
        }
    }

    /// Real linear highlights (>1) encoded through a 10-bit PQ YUV buffer.
    /// This replaces the historical tag-only RGB8 guard fixture; the source
    /// itself must pass decoded-pixel verification before qualification.
    @discardableResult
    static func hdrVideo(url: URL, width: Int, height: Int, fps: Double, seconds: Double) throws -> Bool {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: "HEVC_Main10_AutoLevel"],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
        )
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<Int(seconds * fps) {
            var spins = 0
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
                spins += 1
                if spins > 2500 { throw FloeError.internalError("HDR synthesis stalled") }
            }
            var created: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &created) == kCVReturnSuccess,
                let buffer = created else { throw FloeError.internalError("Could not allocate HDR10 fixture") }
            let linear = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
            let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
            let context = CIContext(options: [.workingColorSpace: linear])
            let extent = CGRect(x: 0, y: 0, width: width, height: height)
            let image = CIImage(color: CIColor(red: 4, green: 2, blue: 1, alpha: 1)).cropped(to: extent)
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            context.render(image, to: buffer, bounds: extent, colorSpace: pq)
            let time = CMTime(value: Int64((Double(index) * 600.0 / fps).rounded()), timescale: 600)
            guard adaptor.append(buffer, withPresentationTime: time) else { return false }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600_000))
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        return writer.status == .completed
    }

    /// Real transparent, translucent and opaque bands for pixel verification.
    static func transparentImage(url: URL, width: Int, height: Int) throws {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw FloeError.internalError("could not create the transparency fixture")
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        for (band, alpha) in [CGFloat(0), 0.25, 0.5, 1].enumerated() {
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: alpha))
            context.fill(CGRect(x: band * width / 4, y: 0, width: width / 4, height: height))
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw FloeError.internalError("could not create the transparency fixture")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FloeError.internalError("could not write the transparency fixture")
        }
    }

    static func timedVideo(url: URL, timestamps: [Double], duration: Double) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard writer.canAdd(input) else { throw FloeError.validationFailed("Timed fixture writer is unavailable") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FloeError.validationFailed("Timed fixture cannot start") }
        writer.startSession(atSourceTime: .zero)
        for (index, seconds) in timestamps.enumerated() {
            var spins = 0
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002); spins += 1
                if spins > 2500 { throw FloeError.validationFailed("Timed fixture writer stalled") }
            }
            guard adaptor.append(try makePixelBuffer(width: 320, height: 180, index: index),
                                 withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600_000)) else {
                throw writer.error ?? FloeError.validationFailed("Timed fixture append failed")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600_000))
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }; semaphore.wait()
        guard writer.status == .completed else { throw writer.error ?? FloeError.validationFailed("Timed fixture failed") }
    }

    static func image(url: URL, width: Int, height: Int) throws {
        let context = CIContext(options: nil)
        let filter = CIFilter(name: "CICheckerboardGenerator")!
        filter.setValue(CIColor.white, forKey: "inputColor0")
        filter.setValue(CIColor.black, forKey: "inputColor1")
        filter.setValue(24.0, forKey: "inputWidth")
        let image = filter.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        guard let alphaImage = context.createCGImage(image, from: image.extent) else {
            throw FloeError.internalError("could not render the test image")
        }
        // This baseline fixture deliberately uses an opaque RGB image.
        guard let opaqueContext = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw FloeError.internalError("could not create the test image context")
        }
        opaqueContext.draw(alphaImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = opaqueContext.makeImage() else {
            throw FloeError.internalError("could not flatten the test image")
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw FloeError.internalError("could not create the test image")
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FloeError.internalError("could not write the test image")
        }
    }
}

// MARK: - Environment probes

reportEnvironment["osVersion"] = ProcessInfo.processInfo.operatingSystemVersionString
reportEnvironment["appBuild"] = "qualification"

let capabilities = MediaCapabilities.probe(appBuild: "qualification")
reportEnvironment["native"] = (try? String(data: JSONEncoder().encode(capabilities.native), encoding: .utf8)) ?? "{}"
let capabilityNotes = capabilities.notes

// MARK: - Model installation (production local-bundle path)

let modelRoot = workspace.appendingPathComponent("models", isDirectory: true)
let modelStore = ModelArtifactStore(rootURL: modelRoot) { _, _ in
    throw FloeError.invalidConfiguration("qualification store never downloads")
}
var installedModels: [(id: String, rootPath: String)] = []
for name in ["floe-model-rife-v4", "floe-model-realesrgan-x4plus", "floe-model-realesrgan-x2plus"] {
    let bundle = bundlesRoot.appendingPathComponent(name, isDirectory: true)
    guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent("manifest.json").path) else {
        record("install-\(name)", status: "fail", detail: "bundle missing at \(bundle.path)")
        continue
    }
    do {
        let recordInstalled = try await modelStore.installLocalBundle(at: bundle, scope: .shared)
        installedModels.append((recordInstalled.id, recordInstalled.rootPath))
        record("install-\(name)", status: "pass", detail: "installed \(recordInstalled.id) \(recordInstalled.version) at \(recordInstalled.rootPath)")
    } catch {
        record("install-\(name)", status: "fail", detail: "install failed: \(error)")
    }
}

// Readiness must be a real bounded inference on the installed bytes.
let readinessModels = await MediaModelReadiness.report(installed: installedModels)
for model in readinessModels {
    let runnable = model.runnable
    record("readiness-\(model.id)", status: runnable ? "pass" : "fail",
           detail: runnable ? "runnable = true (hash-verified fixture inference)" : "runnable = false: \(model.unavailableReason ?? "unknown")",
           metrics: ["capability": model.capability, "installed": String(model.installed)])
}

// Readiness cache evidence: the second model list must reuse the qualified
// record without a second inference, and a changed byte must invalidate it.
do {
    let cacheRoot = workspace.appendingPathComponent("models-cache", isDirectory: true)
    let cacheStore = ModelArtifactStore(rootURL: cacheRoot) { _, _ in
        throw FloeError.invalidConfiguration("qualification store never downloads")
    }
    let installedCache = try await cacheStore.installLocalBundle(
        at: bundlesRoot.appendingPathComponent("floe-model-realesrgan-x2plus"), scope: .shared
    )
    let bundlePath = URL(fileURLWithPath: installedCache.rootPath)
    let readinessURL = bundlePath.appendingPathComponent(".floe-readiness.json")
    func readinessSnapshot() -> [String: Any] {
        guard let data = try? Data(contentsOf: readinessURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }
    let firstReport = await MediaModelReadiness.report(installed: [(installedCache.id, installedCache.rootPath)])
    let firstRecord = readinessSnapshot()
    let secondReport = await MediaModelReadiness.report(installed: [(installedCache.id, installedCache.rootPath)])
    let secondRecord = readinessSnapshot()
    let firstInference = firstRecord["lastInferenceAt"] as? String
    let cacheHit = firstReport.first?.runnable == true
        && secondReport.first?.runnable == true
        && firstInference != nil
        && firstInference == (secondRecord["lastInferenceAt"] as? String)
        && (secondRecord["qualified"] as? Bool) == true
    // Change one byte of the expected-output fixture: the record must flip.
    let fixture = bundlePath.appendingPathComponent("fixtures").appendingPathComponent("expected.png")
    if var data = try? Data(contentsOf: fixture) {
        data.append(0x00)
        try? data.write(to: fixture)
    }
    let thirdReport = await MediaModelReadiness.report(installed: [(installedCache.id, installedCache.rootPath)])
    let thirdRecord = readinessSnapshot()
    let invalidated = thirdReport.first?.runnable == false
        && (thirdRecord["qualified"] as? Bool) == false
        && ((thirdRecord["detail"] as? String)?.contains("sha256 mismatch") == true)
    record("readiness-cache-hit-and-invalidation",
           status: cacheHit && invalidated ? "pass" : "fail",
           detail: cacheHit && invalidated
               ? "second check reused the record (no second inference); a changed fixture byte invalidated it"
               : "cacheHit=\(cacheHit) invalidated=\(invalidated)",
           metrics: [
               "firstInferenceAt": firstInference ?? "nil",
               "secondInferenceAt": (secondRecord["lastInferenceAt"] as? String) ?? "nil",
               "invalidatedDetail": (thirdRecord["detail"] as? String) ?? "nil"
           ])
} catch {
    record("readiness-cache-hit-and-invalidation", status: "fail", detail: "cache evidence failed: \(error)")
}

// MARK: - Media synthesis

let sourceVideo = workspace.appendingPathComponent("source_320x180_30fps_2s.mp4")
let rotatedVideo = workspace.appendingPathComponent("source_rotated.mp4")
let imageSource = workspace.appendingPathComponent("source_256.png")
do {
    try Synthesizer.video(url: sourceVideo, width: 320, height: 180, fps: 30, seconds: 2)
    record("synthesize-video", status: "pass", detail: "320x180@30fps 2s with audio, sha256=\(sha256(sourceVideo).prefix(12))")
    try Synthesizer.video(url: rotatedVideo, width: 320, height: 180, fps: 30, seconds: 1, rotate: true, withAudio: false)
    record("synthesize-rotated", status: "pass", detail: "90° rotated 1s clip")
    try Synthesizer.image(url: imageSource, width: 256, height: 256)
    record("synthesize-image", status: "pass", detail: "256x256 checkerboard PNG")
} catch {
    record("synthesize", status: "fail", detail: "synthesis failed: \(error)")
}

// MARK: - Service

// The service holds no workspace state at all: every request below carries
// the caller's immutable scope, exactly like a task/tool adapter would.
let service = MediaEnhancementService(
    modelResolver: MediaModelResolution.store(modelStore)
)

@MainActor
func runCase(
    name: String,
    input: URL,
    output: URL,
    operation: MediaEnhancementOperation,
    mode: String,
    modelID: String? = nil,
    quality: String? = nil,
    overwrite: Bool = false,
    expectFailure: Bool = false,
    cancellationAfter: Double? = nil,
    validator: ((MediaEnhancementResult) -> String?)? = nil
) async {
    let token = CancellationToken()
    if let cancellationAfter {
        Task {
            try? await Task.sleep(for: .seconds(cancellationAfter))
            token.cancel()
        }
    }
    let sourceHash = sha256(input)
    let outputExisted = FileManager.default.fileExists(atPath: output.path)
    let outputHashBefore = outputExisted ? sha256(output) : ""
    do {
        let result = try await service.enhance(FrameProcessingRequest(
            operation: operation, input: input, output: output, mode: mode,
            modelID: modelID, quality: quality, overwrite: overwrite,
            workspaceRoot: workspace, cancellation: token
        ))
        if expectFailure {
            record(name, status: "fail", detail: "expected failure but the run succeeded")
            return
        }
        if token.isCancelled {
            record(name, status: "fail", detail: "expected cancellation but the run completed before the cancel fired")
            return
        }
        if let problem = validator?(result) {
            record(name, status: "fail", detail: problem, metrics: ["engine": result.engine])
            return
        }
        var metrics: [String: String] = [
            "engine": result.engine,
            "output": "\(result.outputWidth)x\(result.outputHeight)@\(String(format: "%.3f", result.outputFPS))",
            "frames": "\(result.outputFrameCount)/\(result.sourceFrameCount)",
            "interpolated": String(result.interpolatedFrameCount),
            "audio": String(result.audioCopied),
            "bytes": String(result.outputBytes),
            "sha256": String(result.outputSHA256.prefix(16)),
            "warnings": result.warnings.joined(separator: " | ")
        ]
        if sha256(input) != sourceHash { record(name, status: "fail", detail: "source file was modified") ; return }
        metrics["outputExists"] = String(FileManager.default.fileExists(atPath: output.path))
        record(name, status: "pass", detail: "engine=\(result.engine) \(metrics["output"] ?? "") frames=\(metrics["frames"] ?? "")", metrics: metrics)
    } catch let error as FloeError {
        if cancellationAfter != nil, case .cancelled = error, token.isCancelled {
            let outputExists = FileManager.default.fileExists(atPath: output.path)
            let sourceIntact = sha256(input) == sourceHash
            if outputExists || !sourceIntact {
                record(name, status: "fail", detail: "cancelled run left output=\(outputExists) sourceIntact=\(sourceIntact)")
                return
            }
            record(name, status: "pass", detail: "cancelled safely: no output, source byte-identical", metrics: ["reason": error.reason])
            return
        }
        if expectFailure {
            if case .cancelled = error, !token.isCancelled {
                record(name, status: "fail", detail: "cancelled without an explicit cancel request")
                return
            }
            // A protected destination must be byte-identical after a refusal.
            if outputExisted {
                let after = sha256(output)
                guard after == outputHashBefore else {
                    record(name, status: "fail", detail: "refused run still modified the existing destination")
                    return
                }
            } else if FileManager.default.fileExists(atPath: output.path) {
                record(name, status: "fail", detail: "failed run left an output file behind")
                return
            }
            if sha256(input) != sourceHash {
                record(name, status: "fail", detail: "failed run modified the source")
                return
            }
            let expectedCancellation = cancellationAfter != nil
            if expectedCancellation, case .cancelled = error {
                record(name, status: "pass", detail: "cancelled safely: \(error.reason)", metrics: ["reason": error.reason])
                return
            }
            record(name, status: "pass", detail: "rejected as expected: \(error.reason)")
            return
        }
        record(name, status: "fail", detail: "unexpected FloeError: \(error.reason)")
    } catch {
        record(name, status: "fail", detail: "unexpected error: \(error)")
    }
}

func requireHDRHighlight(_ url: URL) async throws {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw FloeError.validationFailed("HDR output missing") }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
    reader.add(output)
    guard reader.startReading(), let sample = output.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) else {
        throw FloeError.validationFailed("Cannot reopen real HDR10 pixels")
    }
    defer { reader.cancelReading() }
    let linear = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    let context = CIContext(options: [.workingColorSpace: linear])
    let image = CIImage(cvPixelBuffer: pixels).transformed(by: CGAffineTransform(scaleX: 16.0 / 320, y: 16.0 / 180))
    var values = [Float](repeating: 0, count: 16 * 16 * 4)
    values.withUnsafeMutableBytes { bytes in context.render(image, toBitmap: bytes.baseAddress!, rowBytes: 16 * 16,
        bounds: CGRect(x: 0, y: 0, width: 16, height: 16), format: .RGBAf, colorSpace: linear) }
    guard values.allSatisfy(\.isFinite), (values.max() ?? 0) > 1.1 else { throw FloeError.validationFailed("HDR tags without actual highlight range") }
}

func requireOutputClock(_ url: URL, fps: Double, duration: Double) async throws {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw FloeError.validationFailed("Timed output missing") }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    guard reader.startReading() else { throw FloeError.validationFailed("Timed output cannot reopen") }
    defer { reader.cancelReading() }
    var index = 0
    while let sample = output.copyNextSampleBuffer() {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard abs(pts - Double(index) / fps) < 0.00001 else { throw FloeError.validationFailed("Off-grid output PTS at \(index): \(pts)") }
        index += 1
    }
    guard index == Int(ceil(duration * fps)) else { throw FloeError.validationFailed("Wrong timed output count: \(index)") }
    let actualDuration = try await asset.load(.duration).seconds
    guard abs(actualDuration - duration) < 0.005 else { throw FloeError.validationFailed("Tail duration changed") }
}

// MARK: - Cases

// 1. VideoToolbox frame rate conversion 30 -> 60.
await runCase(
    name: "vt-interpolation-quality-2x",
    input: sourceVideo,
    output: workspace.appendingPathComponent("out_vt_interp_60.mp4"),
    operation: .interpolation(targetFPS: 60),
    mode: "quality"
) { result in
    result.outputFPS == 60 ? nil : "fps \(result.outputFPS) != 60"
}

// 2. Low-latency interpolation (2x only).
await runCase(
    name: "vt-interpolation-lowlatency-2x",
    input: sourceVideo,
    output: workspace.appendingPathComponent("out_vt_ll_interp_60.mp4"),
    operation: .interpolation(targetFPS: 60),
    mode: "lowLatency"
)

// 3. Core ML RIFE 4.25 Lite interpolation.
await runCase(
    name: "coreml-interpolation-rife-2x",
    input: sourceVideo,
    output: workspace.appendingPathComponent("out_coreml_interp_60.mp4"),
    operation: .interpolation(targetFPS: 60),
    mode: "coreml",
    modelID: "floe/model-rife-v4"
) { result in
    result.engine.contains("rife") ? nil : "unexpected engine \(result.engine)"
}

// Rational clock integration: actual CFR 24->60 and VFR gaps with a held tail.
for (label, timestamps, duration) in [
    ("24-to-60", (0..<24).map { Double($0) / 24 }, 1.0),
    ("VFR-tail", [0, 0.04, 0.083333, 0.14, 0.18, 0.225, 0.27, 0.31, 0.36], 0.405)
] {
    let input = workspace.appendingPathComponent("clock-\(label).mov")
    let output = workspace.appendingPathComponent("clock-\(label)-out.mov")
    do {
        try Synthesizer.timedVideo(url: input, timestamps: timestamps, duration: duration)
        await runCase(name: "coreml-clock-\(label)", input: input, output: output,
            operation: .interpolation(targetFPS: 60), mode: "coreml", modelID: "floe/model-rife-v4")
        try await requireOutputClock(output, fps: 60, duration: duration)
        record("clock-PTS-\(label)", status: "pass", detail: "every actual output PTS, exact count and tail reopened")
    } catch { record("clock-PTS-\(label)", status: "fail", detail: "\(error)") }
}

// 4. VideoToolbox super resolution 4x.
await runCase(
    name: "vt-superresolution-4x",
    input: sourceVideo,
    output: workspace.appendingPathComponent("out_vt_sr_4x.mp4"),
    operation: .superResolution(scaleFactor: 4),
    mode: "quality"
) { result in
    result.outputWidth == result.sourceWidth * 4 ? nil : "width \(result.outputWidth) != 4x"
}

// 5. Core ML Real-ESRGAN x4plus.
await runCase(
    name: "coreml-superresolution-x4plus",
    input: sourceVideo,
    output: workspace.appendingPathComponent("out_coreml_sr_4x.mp4"),
    operation: .superResolution(scaleFactor: 4),
    mode: "coreml",
    modelID: "floe/model-realesrgan-x4plus"
) { result in
    result.outputWidth == result.sourceWidth * 4 ? nil : "width \(result.outputWidth) != 4x"
}

// 6. Core ML Real-ESRGAN x2plus.
await runCase(
    name: "coreml-superresolution-x2plus",
    input: sourceVideo,
    output: workspace.appendingPathComponent("out_coreml_sr_2x.mp4"),
    operation: .superResolution(scaleFactor: 2),
    mode: "coreml",
    modelID: "floe/model-realesrgan-x2plus"
) { result in
    result.outputWidth == result.sourceWidth * 2 ? nil : "width \(result.outputWidth) != 2x"
}

// 7. MetalFX spatial scaling (GPU spatial upscale, not learned SR).
await runCase(
    name: "metalfx-spatial-2x",
    input: sourceVideo,
    output: workspace.appendingPathComponent("out_metalfx_spatial_2x.mp4"),
    operation: .superResolution(scaleFactor: 2),
    mode: "metalFX"
) { result in
    result.engine.contains("metalFX") ? nil : "unexpected engine \(result.engine)"
}

// 8. Still-image super resolution (Core ML x4).
await runCase(
    name: "image-coreml-superresolution-x4",
    input: imageSource,
    output: workspace.appendingPathComponent("out_image_sr_4x.png"),
    operation: .superResolution(scaleFactor: 4),
    mode: "coreml",
    modelID: "floe/model-realesrgan-x4plus"
) { result in
    result.inputKind == "image" && result.outputWidth == 256 * 4 ? nil : "image dims \(result.outputWidth)x\(result.outputHeight)"
}

// 9. Still-image super resolution (VT image input, 4x).
await runCase(
    name: "image-vt-superresolution-4x",
    input: imageSource,
    output: workspace.appendingPathComponent("out_image_vt_sr_4x.png"),
    operation: .superResolution(scaleFactor: 4),
    mode: "quality"
) { result in
    result.outputWidth == 256 * 4 ? nil : "image dims \(result.outputWidth)x\(result.outputHeight)"
}

// 10. Rotation is normalized upright.
await runCase(
    name: "rotation-normalized",
    input: rotatedVideo,
    output: workspace.appendingPathComponent("out_rotated_interp.mp4"),
    operation: .interpolation(targetFPS: 60),
    mode: "quality"
) { result in
    result.hadRotation && result.outputWidth == 180 && result.outputHeight == 320
        ? nil
        : "expected upright 180x320, got \(result.outputWidth)x\(result.outputHeight) hadRotation=\(result.hadRotation)"
}

// 11. Overwrite protection: a second run must be refused and byte-preserve.
let protectedOutput = workspace.appendingPathComponent("out_vt_interp_60.mp4")
await runCase(
    name: "guard-overwrite-refused",
    input: sourceVideo,
    output: protectedOutput,
    operation: .interpolation(targetFPS: 60),
    mode: "quality",
    expectFailure: true
)

// 12. Explicit overwrite consent still works.
await runCase(
    name: "guard-overwrite-consented",
    input: sourceVideo,
    output: protectedOutput,
    operation: .interpolation(targetFPS: 60),
    mode: "quality",
    overwrite: true
)

// 13. MetalFX interpolation is rejected with a reason (no silent swap).
await runCase(
    name: "guard-metalfx-interpolation-rejected",
    input: sourceVideo,
    output: workspace.appendingPathComponent("out_metalfx_interp.mp4"),
    operation: .interpolation(targetFPS: 60),
    mode: "metalFX",
    expectFailure: true
)

// 14. A Core ML scale that the installed model does not provide is refused.
await runCase(
    name: "guard-coreml-scale-mismatch",
    input: sourceVideo,
    output: workspace.appendingPathComponent("out_coreml_wrong_scale.mp4"),
    operation: .superResolution(scaleFactor: 2),
    mode: "coreml",
    modelID: "floe/model-realesrgan-x4plus",
    expectFailure: true
)

// 15. Path escape is refused.
await runCase(
    name: "guard-path-escape",
    input: workspace.appendingPathComponent("../outside.mp4"),
    output: workspace.appendingPathComponent("out_escape.mp4"),
    operation: .interpolation(targetFPS: 60),
    mode: "quality",
    expectFailure: true
)

// 16. HDR preserves actual pixels on native quality; RGB8 CoreML is refused.
let hdrSource = workspace.appendingPathComponent("source_hdr.mov")
if (try? Synthesizer.hdrVideo(url: hdrSource, width: 320, height: 180, fps: 30, seconds: 0.5)) == true {
    await runCase(
        name: "guard-hdr-coreml-rejected",
        input: hdrSource,
        output: workspace.appendingPathComponent("out_hdr.mp4"),
        operation: .interpolation(targetFPS: 60),
        mode: "coreml",
        modelID: "floe/model-rife-v4",
        expectFailure: true
    )
    do {
        try await requireHDRHighlight(hdrSource)
        await runCase(name: "hdr-native-quality-pixel-roundtrip", input: hdrSource,
            output: workspace.appendingPathComponent("out_hdr_preserved.mov"), operation: .interpolation(targetFPS: 60), mode: "quality") { result in
            result.warnings.contains(where: { $0.hasPrefix("reopenedPixelSamples=") }) ? nil : "missing reopened HDR pixel evidence"
        }
        try await requireHDRHighlight(workspace.appendingPathComponent("out_hdr_preserved.mov"))
        record("hdr-independent-pixel-reopen", status: "pass", detail: "source and output both decode real linear highlights above 1")
    } catch { record("hdr-independent-pixel-reopen", status: "fail", detail: "\(error)") }
    record("synthesize-hdr", status: "pass", detail: "real 10-bit PQ highlight fixture written")
} else {
    record("synthesize-hdr", status: "skipped", detail: "host encoder refused HDR tags", required: false)
    record("hdr-native-quality-pixel-roundtrip", status: "fail", detail: "no real HDR fixture available")
}

// 17. Alpha-capable PNG succeeds; flattening JPEG remains explicitly refused.
let alphaSource = workspace.appendingPathComponent("source_alpha.png")
do {
    try Synthesizer.transparentImage(url: alphaSource, width: 128, height: 128)
    await runCase(
        name: "guard-alpha-jpeg-rejected",
        input: alphaSource,
        output: workspace.appendingPathComponent("out_alpha.jpg"),
        operation: .superResolution(scaleFactor: 2),
        mode: "coreml",
        modelID: "floe/model-realesrgan-x2plus",
        expectFailure: true
    )
    await runCase(name: "coreml-alpha-PNG-roundtrip", input: alphaSource,
        output: workspace.appendingPathComponent("out_alpha.png"), operation: .superResolution(scaleFactor: 2),
        mode: "coreml", modelID: "floe/model-realesrgan-x2plus")
} catch {
    record("coreml-alpha-PNG-roundtrip", status: "fail", detail: "alpha fixture failed: \(error)")
}

// 18. Cancellation mid-run: no output, source preserved.
await runCase(
    name: "cancel-coreml-interpolation",
    input: sourceVideo,
    output: workspace.appendingPathComponent("out_cancelled.mp4"),
    operation: .interpolation(targetFPS: 60),
    mode: "coreml",
    modelID: "floe/model-rife-v4",
    cancellationAfter: 0.15
)

// 17. A request whose paths fall outside its snapshotted scope is refused.
let otherWorkspace = workRoot.appendingPathComponent("workspace-b", isDirectory: true)
try? FileManager.default.createDirectory(at: otherWorkspace, withIntermediateDirectories: true)
do {
    _ = try await service.enhance(FrameProcessingRequest(
        operation: .interpolation(targetFPS: 60),
        input: sourceVideo,
        output: otherWorkspace.appendingPathComponent("out_escape.mp4"),
        mode: "quality",
        workspaceRoot: workspace
    ))
    record("guard-cross-workspace-output-rejected", status: "fail", detail: "cross-workspace output was accepted")
} catch let error as FloeError {
    let leaked = FileManager.default.fileExists(atPath: otherWorkspace.appendingPathComponent("out_escape.mp4").path)
    record("guard-cross-workspace-output-rejected", status: leaked ? "fail" : "pass",
           detail: "rejected: \(error.reason)", metrics: ["reason": error.reason])
} catch {
    record("guard-cross-workspace-output-rejected", status: "fail", detail: "unexpected error \(error)")
}

// 18. A request without a scope fails closed (no current-selection fallback).
do {
    _ = try await service.enhance(FrameProcessingRequest(
        operation: .interpolation(targetFPS: 60),
        input: sourceVideo,
        output: workspace.appendingPathComponent("out_unscoped.mp4"),
        mode: "quality"
    ))
    record("guard-missing-scope-rejected", status: "fail", detail: "unscoped request was accepted")
} catch let error as FloeError {
    let leaked = FileManager.default.fileExists(atPath: workspace.appendingPathComponent("out_unscoped.mp4").path)
    record("guard-missing-scope-rejected", status: leaked ? "fail" : "pass",
           detail: "rejected: \(error.reason)", metrics: ["reason": error.reason])
} catch {
    record("guard-missing-scope-rejected", status: "fail", detail: "unexpected error \(error)")
}

// 19. Two workspaces, sequential requests: each resolves against its own
// snapshot even though the "current" workspace differs between the calls.
do {
    let workspaceB = otherWorkspace
    try Synthesizer.video(url: workspaceB.appendingPathComponent("source_b.mp4"), width: 160, height: 96, fps: 30, seconds: 1)
    let resultA = try await service.enhance(FrameProcessingRequest(
        operation: .interpolation(targetFPS: 60),
        input: workspace.appendingPathComponent("source_320x180_30fps_2s.mp4"),
        output: workspace.appendingPathComponent("out_scope_a.mp4"),
        mode: "quality",
        workspaceRoot: workspace
    ))
    let resultB = try await service.enhance(FrameProcessingRequest(
        operation: .interpolation(targetFPS: 60),
        input: workspaceB.appendingPathComponent("source_b.mp4"),
        output: workspaceB.appendingPathComponent("out_scope_b.mp4"),
        mode: "quality",
        workspaceRoot: workspaceB
    ))
    let aOK = FileManager.default.fileExists(atPath: resultA.outputPath) && resultA.outputPath.hasPrefix(workspace.path)
    let bOK = FileManager.default.fileExists(atPath: resultB.outputPath) && resultB.outputPath.hasPrefix(workspaceB.path)
    record("guard-two-workspace-isolation", status: aOK && bOK ? "pass" : "fail",
           detail: aOK && bOK ? "both scoped runs wrote inside their own roots" : "a=\(aOK) b=\(bOK)",
           metrics: ["workspaceA": resultA.outputPath, "workspaceB": resultB.outputPath])
} catch {
    record("guard-two-workspace-isolation", status: "fail", detail: "scoped runs failed: \(error)")
}

// 20. The registered tool boundary: relative paths, schema mapping, overwrite.
do {
    let tool = VideoInterpolateTool(processor: service)
    let context = ToolContext(runID: UUID(), workspaceRootURL: workspace, cancellation: CancellationToken())
    let arguments = VideoInterpolateTool.Arguments(
        input: "source_320x180_30fps_2s.mp4",
        output: "out_tool_interp_60.mp4",
        targetFPS: 60,
        mode: "quality",
        modelID: nil,
        quality: "quality",
        overwrite: nil
    )
    do {
        let output = try await tool.execute(arguments, context: context)
        let hasEngine = output.summary.contains("engine=")
        let exists = FileManager.default.fileExists(atPath: workspace.appendingPathComponent("out_tool_interp_60.mp4").path)
        record("tool-boundary-interpolate", status: hasEngine && exists ? "pass" : "fail",
               detail: hasEngine && exists ? "tool produced a measured digest and a real file" : "tool digest missing engine/file",
               metrics: ["digest": String(output.summary.prefix(120))])
    } catch {
        record("tool-boundary-interpolate", status: "fail", detail: "tool failed: \(error)")
    }
}

// MARK: - Report

let requiredFailures = results.filter { $0.required && $0.status != "pass" }
let passed = results.filter { $0.status == "pass" }.count
let summary: [String: Any] = [
    "passed": passed,
    "total": results.count,
    "allRequiredPassed": requiredFailures.isEmpty,
    "environment": reportEnvironment,
    "capabilityNotes": capabilityNotes,
    "cases": results.map { [
        "name": $0.name,
        "status": $0.status,
        "detail": $0.detail,
        "metrics": $0.metrics,
        "required": $0.required
    ] }
]
let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write("\n".data(using: .utf8)!)
exit(requiredFailures.isEmpty ? 0 : 1)
