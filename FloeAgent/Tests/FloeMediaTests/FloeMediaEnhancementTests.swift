// Floe media-enhancement focused tests (T2).
//
// These are the canonical app-target tests for the enhancement contract:
// request mapping, guards, path safety, model contract decoding, readiness
// fingerprinting and result digesting. They compile against FloeMedia alone
// and are runnable through the native qualification package (macOS) or an app
// test target once the primary wires `FloeAgent/Tests/FloeMediaTests` into
// `Package.swift` (see the T2 INTERFACES.md patch note).
//
// The real processor execution tests (VideoToolbox, Core ML bundles, MetalFX,
// cancellation, rotation) live in the native qualification host
// `FloeAgent/Qualification/MediaEnhancement`, because the VTFrameProcessor
// frame-rate/super-resolution headers are excluded from Simulator builds.

import Foundation
import Testing
@testable import FloeMedia
import FloeCore
import FloeTools

@Suite("Media enhancement contract")
struct MediaEnhancementContractTests {
    @Test func modeParsingIsCaseInsensitive() throws {
        #expect(MediaEnhancementMode(requested: "quality") == .quality)
        #expect(MediaEnhancementMode(requested: "lowLatency") == .lowLatency)
        #expect(MediaEnhancementMode(requested: "metalfx") == .metalFX)
        #expect(MediaEnhancementMode(requested: "coreml") == .coreml)
        #expect(MediaEnhancementMode(requested: "unknown") == nil)
    }

    @Test func qualityRejectsUnknownValuesInsteadOfDroppingThem() throws {
        #expect(try MediaEnhancementQuality(requested: nil) == nil)
        #expect(try MediaEnhancementQuality(requested: "quality") == .quality)
        #expect(try MediaEnhancementQuality(requested: "BALANCED") == .balanced)
        #expect(try MediaEnhancementQuality(requested: "fast") == .fast)
        #expect(throws: FloeError.self) { _ = try MediaEnhancementQuality(requested: "ultra") }
    }

    @Test func qualityMapsToDocumentedEngineBehaviour() {
        #expect(MediaEnhancementQuality.quality.tileOverlap == 16)
        #expect(MediaEnhancementQuality.fast.tileOverlap == 8)
        #expect(MediaEnhancementQuality.quality.vtPrioritizationIsQuality)
        #expect(!MediaEnhancementQuality.fast.vtPrioritizationIsQuality)
    }

    @Test func frameProcessingRequestCarriesQualityOverwriteAndCancellation() throws {
        let token = CancellationToken()
        let request = FrameProcessingRequest(
            operation: .superResolution(scaleFactor: 4),
            input: URL(fileURLWithPath: "/tmp/in.png"),
            output: URL(fileURLWithPath: "/tmp/out.png"),
            mode: "coreml",
            modelID: "floe/model-realesrgan-x4plus",
            quality: "fast",
            overwrite: true,
            cancellation: token
        )
        #expect(request.quality == "fast")
        #expect(request.overwrite)
        #expect(request.modelID == "floe/model-realesrgan-x4plus")
        #expect(request.operation == .superResolution(scaleFactor: 4))
        #expect(request.workspaceRoot == nil)
    }

    @Test func defaultFrameProcessingRefusesSilentOverwrite() async throws {
        let processor = UnavailableFrameProcessing()
        let request = FrameProcessingRequest(
            operation: .superResolution(scaleFactor: 2),
            input: URL(fileURLWithPath: "/tmp/in.png"),
            output: URL(fileURLWithPath: "/tmp/out.png"),
            mode: "quality",
            overwrite: true
        )
        await #expect(throws: FloeError.self) {
            _ = try await processor.process(request)
        }
    }

    @Test func defaultFrameProcessingReportsHonestUnavailability() async throws {
        let processor = UnavailableFrameProcessing()
        let request = FrameProcessingRequest(
            operation: .interpolation(targetFPS: 60),
            input: URL(fileURLWithPath: "/tmp/in.mp4"),
            output: URL(fileURLWithPath: "/tmp/out.mp4"),
            mode: "quality"
        )
        await #expect(throws: FloeError.self) {
            _ = try await processor.process(request)
        }
    }
}

@Suite("Media path guard")
struct MediaPathGuardTests {
    @Test func relativePathsResolveBeneathTheRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t2-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolved = try MediaPathGuard.resolve("nested/file.mp4", root: root)
        #expect(resolved.path.hasPrefix(root.resolvingSymlinksInPath().path))
    }

    @Test func parentTraversalIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t2-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: FloeError.self) {
            _ = try MediaPathGuard.resolve("../outside.mp4", root: root)
        }
        #expect(throws: FloeError.self) {
            _ = try MediaPathGuard.resolve("/etc/hosts", root: root)
        }
    }

    @Test func symlinkEscapeIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t2-guard-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("t2-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        #expect(throws: FloeError.self) {
            _ = try MediaPathGuard.resolve("link/escape.mp4", root: root)
        }
    }
}

@Suite("Media enhancement workspace scope")
struct MediaEnhancementWorkspaceScopeTests {
    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t2-scope-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func requestCodablePreservesTheImmutableScope() throws {
        let scope = try temporaryDirectory("codable")
        defer { try? FileManager.default.removeItem(at: scope) }
        let request = MediaEnhancementRequest(
            inputPath: scope.appendingPathComponent("in.mp4").path,
            outputPath: scope.appendingPathComponent("out.mp4").path,
            operation: .interpolation(targetFPS: 60),
            mode: "quality",
            workspaceRootPath: scope.path
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(MediaEnhancementRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.workspaceRootPath == scope.path)
    }

    @Test func frameProcessingRequestCarriesTheScope() throws {
        let scope = try temporaryDirectory("request")
        defer { try? FileManager.default.removeItem(at: scope) }
        let request = FrameProcessingRequest(
            operation: .superResolution(scaleFactor: 2),
            input: scope.appendingPathComponent("in.png"),
            output: scope.appendingPathComponent("out.png"),
            mode: "quality",
            workspaceRoot: scope
        )
        #expect(request.workspaceRoot == scope)
    }

    @Test func serviceRefusesARequestWithoutScope() async throws {
        let service = MediaEnhancementService()
        let request = FrameProcessingRequest(
            operation: .interpolation(targetFPS: 60),
            input: URL(fileURLWithPath: "/etc/hosts"),
            output: URL(fileURLWithPath: "/tmp/out.mp4"),
            mode: "quality"
        )
        await #expect(throws: FloeError.self) {
            _ = try await service.enhance(request)
        }
    }

    @Test func serviceRefusesLegacyUnscopedEntryPoints() async throws {
        let service = MediaEnhancementService()
        await #expect(throws: FloeError.self) {
            _ = try await service.interpolate(
                input: URL(fileURLWithPath: "/etc/hosts"),
                output: URL(fileURLWithPath: "/tmp/out.mp4"),
                targetFPS: 60, mode: "quality", modelID: nil
            )
        }
    }

    @Test func pathsOutsideTheSnapshotAreRefusedBeforeAnyFileWork() async throws {
        let scopeA = try temporaryDirectory("a")
        let scopeB = try temporaryDirectory("b")
        defer {
            try? FileManager.default.removeItem(at: scopeA)
            try? FileManager.default.removeItem(at: scopeB)
        }
        let service = MediaEnhancementService()
        // Output in a second workspace, scope is A: refused even though both
        // directories exist, because the scope is A for the whole request.
        await #expect(throws: FloeError.self) {
            _ = try await service.enhance(FrameProcessingRequest(
                operation: .interpolation(targetFPS: 60),
                input: scopeA.appendingPathComponent("in.mp4"),
                output: scopeB.appendingPathComponent("out.mp4"),
                mode: "quality",
                workspaceRoot: scopeA
            ))
        }
    }

    @Test func scopedRequestResolvesAgainstItsOwnRoot() async throws {
        let scope = try temporaryDirectory("own")
        defer { try? FileManager.default.removeItem(at: scope) }
        let service = MediaEnhancementService()
        // No global/current workspace exists on the service; the request's
        // scope is honoured and resolution proceeds inside it, so the failure
        // is the missing input, not a missing workspace.
        do {
            _ = try await service.enhance(FrameProcessingRequest(
                operation: .interpolation(targetFPS: 60),
                input: scope.appendingPathComponent("missing.mp4"),
                output: scope.appendingPathComponent("out.mp4"),
                mode: "quality",
                workspaceRoot: scope
            ))
            Issue.record("missing input should not succeed")
        } catch let error as FloeError {
            #expect(error.reason.contains("missing.mp4"))
        }
    }
}

@Suite("Model readiness cache")
struct MediaModelReadinessCacheTests {
    private func record(
        fingerprint: String = "fp",
        bytes: String = "bytes",
        contractID: String = "floe/model-x",
        version: String = "1.0.0",
        runtime: String = "runtime",
        qualified: Bool = true,
        checkedAt: Date = Date(),
        lastInferenceAt: Date = Date()
    ) -> MediaModelReadinessRecord {
        MediaModelReadinessRecord(
            fingerprint: fingerprint,
            modelBytesDigest: bytes,
            contractID: contractID,
            contractVersion: version,
            runtimeMarker: runtime,
            qualified: qualified,
            checkedAt: checkedAt,
            lastInferenceAt: lastInferenceAt,
            detail: "fixture mean(abs diff)=0.001 tolerance=0.030",
            metrics: [:]
        )
    }

    private func decide(_ record: MediaModelReadinessRecord?, bytes: String = "bytes",
                        fingerprint: String = "fp", runtime: String = "runtime",
                        now: Date = Date(), ttl: TimeInterval = 900) -> MediaModelReadinessCache.Decision {
        MediaModelReadinessCache.decide(
            record: record,
            fingerprint: fingerprint,
            modelBytesDigest: bytes,
            contractID: "floe/model-x",
            contractVersion: "1.0.0",
            runtimeMarker: runtime,
            now: now,
            negativeRetryInterval: ttl
        )
    }

    @Test func matchingPositiveRecordIsReusedWithoutInference() {
        #expect(decide(record()) == .reuseQualified)
    }

    @Test func byteChangeForcesAFreshInference() {
        #expect(decide(record(), bytes: "bytes-changed") == .runInference(reason: "model bytes or contract changed"))
    }

    @Test func contractOrVersionChangeForcesAFreshInference() {
        #expect(decide(record(), fingerprint: "fp2") == .runInference(reason: "model bytes or contract changed"))
        let otherVersion = MediaModelReadinessRecord(
            fingerprint: "fp", modelBytesDigest: "bytes", contractID: "floe/model-x",
            contractVersion: "2.0.0", runtimeMarker: "runtime", qualified: true,
            checkedAt: Date(), lastInferenceAt: Date(), detail: "d", metrics: [:]
        )
        #expect(decide(otherVersion) == .runInference(reason: "model version changed"))
    }

    @Test func runtimeChangeForcesAFreshInference() {
        #expect(decide(record(), runtime: "runtime2") == .runInference(reason: "runtime changed"))
    }

    @Test func negativeRecordIsReusedOnlyInsideItsRetryWindow() {
        let now = Date()
        #expect(decide(record(qualified: false, checkedAt: now), now: now) == .reuseNegative)
        let stale = now.addingTimeInterval(-1000)
        #expect(decide(record(qualified: false, checkedAt: stale), now: now) == .runInference(reason: "cached negative result expired"))
    }

    @Test func missingOrSchemaChangedRecordsForceInference() {
        #expect(decide(nil) == .runInference(reason: "no cached readiness record"))
        var old = record()
        old.schema = 1
        #expect(decide(old) == .runInference(reason: "readiness record schema changed"))
    }

    @Test func runtimeMarkerIncludesTheOSAndComputeUnits() {
        let marker = MediaModelReadiness.currentRuntimeMarker()
        #expect(marker.contains("compute=all"))
        #expect(marker.contains("os="))
        #expect(marker.contains("coreml"))
    }
}

@Suite("Model contract and readiness layout")
struct MediaModelContractTests {
    @Test func contractDecodesTheConversionOutput() throws {
        let json = """
        {
          "id": "floe/model-rife-v4", "version": "4.25.0-lite", "kind": "coreml",
          "capability": "video.interpolate", "tileSize": 256, "phase": 0.5,
          "inputs": [
            {"name": "frame0", "type": "image", "shape": [1,3,256,256], "colorLayout": "RGB", "scale": 0.0039},
            {"name": "frame1", "type": "image", "shape": [1,3,256,256], "colorLayout": "RGB", "scale": 0.0039},
            {"name": "timestep", "type": "tensor", "shape": [1,1], "range": [0,1]}
          ],
          "outputs": [{"name": "frame", "type": "image", "colorLayout": "RGB", "scale": 1.0}],
          "license": "MIT"
        }
        """
        let contract = try JSONDecoder().decode(MediaModelContract.self, from: Data(json.utf8))
        #expect(contract.id == "floe/model-rife-v4")
        #expect(contract.isInterpolation)
        #expect(!contract.isSuperResolution)
        #expect(contract.tileSize == 256)
        #expect(contract.inputs.count == 3)
        #expect(contract.outputs.first?.name == "frame")
    }

    @Test func srContractExposesScaleAndOutputName() throws {
        let json = """
        {
          "id": "floe/model-realesrgan-x4plus", "version": "1.0.0", "kind": "coreml",
          "capability": "video.superResolution", "scaleFactor": 4, "tileSize": 256,
          "inputs": [{"name": "image", "type": "image", "shape": [1,3,256,256]}],
          "outputs": [{"name": "image_out", "type": "image"}]
        }
        """
        let contract = try JSONDecoder().decode(MediaModelContract.self, from: Data(json.utf8))
        #expect(contract.isSuperResolution)
        #expect(contract.scaleFactor == 4)
        #expect(contract.outputs.first?.name == "image_out")
    }

    @Test func resultDigestCarriesMeasuredCounters() {
        let result = MediaEnhancementResult(
            outputPath: "/tmp/out.mp4", engine: "videotoolbox.frameRateConversion", mode: "quality",
            inputKind: "video", sourceWidth: 320, sourceHeight: 180, outputWidth: 320, outputHeight: 180,
            sourceFPS: 30, outputFPS: 60, sourceDurationSeconds: 2, outputDurationSeconds: 2,
            sourceFrameCount: 60, outputFrameCount: 119, interpolatedFrameCount: 59,
            audioCopied: true, hadRotation: false, outputBytes: 1234, outputSHA256: "abc", warnings: []
        )
        let digest = result.digest
        #expect(digest.contains("engine=videotoolbox.frameRateConversion"))
        #expect(digest.contains("frames=119"))
        #expect(digest.contains("interpolatedFrames=59"))
        #expect(digest.contains("audioCopied=true"))
        #expect(digest.contains("sha256=abc"))
    }
}

@Suite("Rational enhancement output clock")
struct MediaOutputFrameClockTests {
    @Test func nonIntegerRateUsesActualPairPhases() throws {
        let clock = try MediaOutputFrameClock(fps: 60)
        #expect(abs(try clock.phase(at: 1, sourcePTS: 0, nextPTS: 1.0 / 24) - 0.4) < 1e-9)
        #expect(abs(try clock.phase(at: 2, sourcePTS: 0, nextPTS: 1.0 / 24) - 0.8) < 1e-9)
        #expect(abs(try clock.phase(at: 3, sourcePTS: 1.0 / 24, nextPTS: 2.0 / 24) - 0.2) < 1e-9)
        #expect(abs(try clock.phase(at: 4, sourcePTS: 1.0 / 24, nextPTS: 2.0 / 24) - 0.6) < 1e-9)
        #expect(try clock.ticks(at: 5) == 5)
    }

    @Test func ntscClockDoesNotAccumulatePerFrameRounding() throws {
        let clock = try MediaOutputFrameClock(fps: 60_000.0 / 1001)
        #expect(clock.numerator == 60_000)
        #expect(clock.denominator == 1001)
        #expect(try clock.ticks(at: 200_000) == 200_200_000)
        #expect(abs(try clock.seconds(at: 200_000) - 200_200_000.0 / 60_000) < 1e-10)
    }

    @Test func variableInputTimestampChangesThePhase() throws {
        let clock = try MediaOutputFrameClock(fps: 60)
        #expect(abs(try clock.phase(at: 3, sourcePTS: 0.04, nextPTS: 0.10) - 1.0 / 6) < 1e-9)
        #expect(try clock.phase(at: 6, sourcePTS: 0.04, nextPTS: 0.10) == 1)
        #expect(throws: (any Error).self) { try clock.phase(at: 1, sourcePTS: 1, nextPTS: 1) }
        #expect(throws: (any Error).self) { try clock.phase(at: 1, sourcePTS: .nan, nextPTS: 1) }
        #expect(throws: (any Error).self) { try clock.phase(at: 1, sourcePTS: 1, nextPTS: 0) }
    }

    @Test func invalidAndOverflowingClocksAreRefused() throws {
        for fps in [0.0, -1, .nan, .infinity, 241] {
            #expect(throws: (any Error).self) { try MediaOutputFrameClock(fps: fps) }
        }
        let clock = try MediaOutputFrameClock(fps: 60_000.0 / 1001)
        #expect(throws: (any Error).self) { try clock.ticks(at: -1) }
        #expect(throws: (any Error).self) { try clock.ticks(at: Int.max) }
    }
}

#if canImport(AVFoundation)
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

@Suite("Enhancement precision and alpha contracts")
struct MediaEnhancementPixelContractTests {
    private func source(hdr: Bool = false, alpha: Bool = false, image: Bool = false) -> MediaSourceDescriptor {
        MediaSourceDescriptor(url: URL(fileURLWithPath: "/input.mov"), isImage: image,
            width: 64, height: 64, displayWidth: 64, displayHeight: 64, naturalFPS: 24,
            durationSeconds: 1, hasAudio: false, hadRotation: false,
            colorPrimary: hdr ? kCVImageBufferColorPrimaries_ITU_R_2020 as String : nil,
            transferFunction: hdr ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String : nil,
            isHDR: hdr, hasAlpha: alpha, codec: nil)
    }

    @Test func hdrNegotiatesPrecisionAndRefusesRGB8Engines() throws {
        let input = source(hdr: true)
        let native = try MediaEnhancementFormat(source: input, mode: .quality, output: URL(fileURLWithPath: "/output.mov"))
        #expect(native.workingPixelFormat == kCVPixelFormatType_64RGBAHalf)
        #expect(native.readerPixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        #expect(native.codec == .hevc)
        #expect(native.videoColorProperties[AVVideoTransferFunctionKey] as? String == input.transferFunction)
        for engine in [MediaEnhancementMode.coreml, .lowLatency, .metalFX] {
            #expect(throws: (any Error).self) { try MediaEnhancementFormat(source: input, mode: engine, output: URL(fileURLWithPath: "/out.mov")) }
        }
        #expect(throws: (any Error).self) { try MediaEnhancementFormat(source: source(hdr: true, alpha: true), mode: .quality, output: URL(fileURLWithPath: "/out.mov")) }
    }

    @Test func encodedHEVCDepthComesFromTheConfigurationRecord() {
        var record = Data(repeating: 0, count: 23)
        record[0] = 1; record[17] = 0xFA
        #expect(MediaSourceInspector.hevcBitDepth(record) == 10)
        record[17] = 0xF8
        #expect(MediaSourceInspector.hevcBitDepth(record) == 8)
        #expect(MediaSourceInspector.hevcBitDepth(Data([1, 2, 3])) == nil)
    }

    @Test func alphaRequiresAnActualAlphaContainer() throws {
        #expect(throws: (any Error).self) { try MediaEnhancementFormat(source: source(alpha: true), mode: .quality, output: URL(fileURLWithPath: "/out.mp4")) }
        #expect(throws: (any Error).self) { try MediaEnhancementFormat(source: source(alpha: true, image: true), mode: .coreml, output: URL(fileURLWithPath: "/out.jpg")) }
        let video = try MediaEnhancementFormat(source: source(alpha: true), mode: .coreml, output: URL(fileURLWithPath: "/out.mov"))
        #expect(video.codec == .hevcWithAlpha)
        let image = try MediaEnhancementFormat(source: source(alpha: true, image: true), mode: .coreml, output: URL(fileURLWithPath: "/out.png"))
        #expect(image.alpha)
        #expect(image.workingPixelFormat == kCVPixelFormatType_32BGRA)
    }

    @Test func halfFloatBridgeRetainsHighlightsAndRGB8ClippingIsDetected() throws {
        let format = try MediaEnhancementFormat(source: source(hdr: true), mode: .quality, output: URL(fileURLWithPath: "/out.mov"))
        let bridge = MediaImageBridge(colorSpace: format.workingSpace)
        let store = MediaPixelBufferStore()
        let half = try store.makeBuffer(format: format.workingPixelFormat, width: 64, height: 64)
        let light = CIImage(color: CIColor(red: 4, green: 2, blue: 1, alpha: 1)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        try bridge.render(image: light, destination: half)
        let original = try MediaPixelEvidence.capture(half, bridge: bridge)
        #expect(original.maximumLinearRGB > 3.5)
        let second = try bridge.bgraToHalfRGBA(half, store: store)
        let retained = try MediaPixelEvidence.capture(second, bridge: bridge)
        try MediaPixelEvidence.requireRange(source: original, output: retained)
        let clipped = try store.makeBuffer(format: MediaImageBridge.bgra, width: 64, height: 64)
        try bridge.render(source: half, destination: clipped)
        #expect(throws: (any Error).self) { try MediaPixelEvidence.requireRange(source: original, output: MediaPixelEvidence.capture(clipped, bridge: bridge)) }
        // A second SDR request cannot mutate the first request's working space.
        let sdr = MediaImageBridge()
        #expect(bridge.colorSpace.name != sdr.colorSpace.name)
        #expect(try MediaPixelEvidence.capture(second, bridge: bridge).maximumLinearRGB > 3.5)
    }

    @Test func floatingTIFFReopensWithoutClippingHighlights() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-float-tiff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("out.tiff")
        let format = try MediaEnhancementFormat(source: source(hdr: true, image: true), mode: .quality, output: url)
        let bridge = MediaImageBridge(colorSpace: format.workingSpace)
        let image = CIImage(color: CIColor(red: 4, green: 2, blue: 1, alpha: 1)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let bytes = try #require(bridge.cicontext.tiffRepresentation(of: image, format: .RGBAh, colorSpace: format.workingSpace, options: [:]))
        try bytes.write(to: url)
        let evidence = try MediaPixelEvidence.capture(image, bridge: bridge)
        #expect(evidence.maximumLinearRGB > 1.1)
        _ = try MediaEnhancementValidator.validateImage(staged: url, expectedWidth: 64, expectedHeight: 64, format: format, evidence: evidence, bridge: bridge)
        // A dark interpolated output is valid; encoding must preserve that
        // output's own range rather than an unrelated bright source endpoint.
        let dark = MediaPixelEvidence(maximumLinearRGB: 0.2, minimumAlpha: 1, maximumAlpha: 1)
        try dark.verify(reopened: dark, format: format)
    }

    @Test func alphaUsesTheActualPhaseAndStraightColor() throws {
        let bridge = MediaImageBridge(), store = MediaPixelBufferStore()
        func buffer(_ alpha: CGFloat) throws -> CVPixelBuffer {
            let result = try store.makeBuffer(format: MediaImageBridge.bgra, width: 64, height: 64)
            try bridge.render(image: CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: alpha)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)), destination: result)
            return result
        }
        let first = try buffer(0.2), second = try buffer(0.8)
        let color = try bridge.opaqueColor(first, store: store)
        let straight = try MediaPixelEvidence.capture(color, bridge: bridge)
        #expect(straight.minimumAlpha > 0.99)
        #expect(straight.maximumLinearRGB > 0.95)
        let output = try store.makeBuffer(format: MediaImageBridge.bgra, width: 64, height: 64)
        try bridge.restoreAlpha(color: color, current: first, next: second, phase: 0.25, destination: output)
        let restored = try MediaPixelEvidence.capture(output, bridge: bridge)
        #expect(abs(restored.minimumAlpha - 0.35) < 0.02)
        #expect(abs(restored.maximumAlpha - 0.35) < 0.02)
        let format = try MediaEnhancementFormat(source: source(alpha: true), mode: .coreml, output: URL(fileURLWithPath: "/out.mov"))
        #expect(throws: (any Error).self) { try restored.verify(reopened: straight, format: format) }
    }

    @Test func reopenedPNGVerifiesTransparentPixelsAndRejectsFlattening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-alpha-reopen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = try MediaEnhancementFormat(source: source(alpha: true, image: true), mode: .coreml, output: root.appendingPathComponent("out.png"))
        let bridge = MediaImageBridge()
        let alpha = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 0.25)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let evidence = try MediaPixelEvidence.capture(alpha, bridge: bridge)
        func write(_ image: CIImage, name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            let cg = try #require(bridge.cicontext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: bridge.colorSpace))
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, cg, nil)
            #expect(CGImageDestinationFinalize(destination))
            return url
        }
        let preserved = try write(alpha, name: "alpha.png")
        _ = try MediaEnhancementValidator.validateImage(staged: preserved, expectedWidth: 64, expectedHeight: 64, format: format, evidence: evidence, bridge: bridge)
        let flattened = try write(alpha.settingAlphaOne(in: alpha.extent), name: "opaque.png")
        #expect(throws: (any Error).self) { try MediaEnhancementValidator.validateImage(staged: flattened, expectedWidth: 64, expectedHeight: 64, format: format, evidence: evidence, bridge: bridge) }
    }
}
#endif

@Suite("Enhancement downloadable model layout")
struct MediaModelDownloadLayoutTests {
    private func fixture(version: String = "1.0.0") throws -> (ModelArtifact, [String: Data]) {
        let id = "floe/test-model", capability = "video.superResolution"
        let contract: [String: Any] = ["id": id, "version": version, "capability": capability, "kind": "coreml", "tileSize": 16,
                                       "inputs": [], "outputs": []]
        var bytes = ["contract.json": try JSONSerialization.data(withJSONObject: contract),
                     "LICENSE.txt": Data("MIT test fixture".utf8), "PROVENANCE.json": Data("{}".utf8),
                     "model.mlmodelc/weights/weight.bin": Data([1, 2, 3, 4])]
        let members: [[String: Any]] = bytes.sorted { $0.key < $1.key }.map {
            ["path": $0.key, "sha256": FloeDigest.sha256Hex($0.value), "sizeBytes": $0.value.count]
        }
        bytes["manifest.json"] = try JSONSerialization.data(withJSONObject: ["id": id, "version": version, "capability": capability, "license": "MIT", "files": members])
        let files = bytes.sorted { $0.key < $1.key }.map {
            ModelArtifact.File(path: $0.key, url: "https://example.invalid/" + $0.key.replacingOccurrences(of: "/", with: "--"),
                               sha256: FloeDigest.sha256Hex($0.value), sizeBytes: Int64($0.value.count))
        }
        return (ModelArtifact(id: id, version: "1.0.0", kind: "coreml", capability: capability, files: files, license: "MIT", status: "ready"), bytes)
    }

    @Test func exactDownloadInstallsButCorruptedBytesAndContractMismatchDoNot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-model-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (artifact, bytes) = try fixture()
        let downloads = Dictionary(uniqueKeysWithValues: artifact.files.map { ($0.url, bytes[$0.path]!) })
        let store = ModelArtifactStore(rootURL: root) { url, _ in try #require(downloads[url.absoluteString]) }
        let installed = try await store.install(artifact, scope: .shared, cancellation: nil)
        #expect(installed.version == artifact.version)
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: installed.rootPath).appendingPathComponent("manifest.json").path))
        let (mismatched, wrongBytes) = try fixture(version: "9.0.0")
        let wrongDownloads = Dictionary(uniqueKeysWithValues: mismatched.files.map { ($0.url, wrongBytes[$0.path]!) })
        let refused = ModelArtifactStore(rootURL: root.appendingPathComponent("mismatch")) { url, _ in try #require(wrongDownloads[url.absoluteString]) }
        await #expect(throws: (any Error).self) { try await refused.install(mismatched, scope: .shared, cancellation: nil) }
        #expect(await refused.installed().isEmpty)
        let corrupt = ModelArtifactStore(rootURL: root.appendingPathComponent("corrupt")) { _, _ in Data([0]) }
        await #expect(throws: (any Error).self) { try await corrupt.install(artifact, scope: .shared, cancellation: nil) }
        #expect(await corrupt.installed().isEmpty)
    }

    @Test func preparedCatalogBytesRemainUnavailable() throws {
        var artifact = try fixture().0
        artifact.status = "pending-qualification"
        #expect(!artifact.isInstallable)
        artifact.status = "ready"
        artifact.files = []
        #expect(!artifact.isInstallable)
    }
}
