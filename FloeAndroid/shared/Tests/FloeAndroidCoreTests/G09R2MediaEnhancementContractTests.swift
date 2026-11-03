// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 media enhancement — focused source tests (NOT RUN in this lane).
//
// Pure contract/plan/parser/journal tests: no provider call, no Linux guest,
// no device. They pin the ENH-IN-OUT-CONTRACT refusals, the ffmpeg script
// shape, the probe/progress parsing, the journal round trip, and the fal
// backend origin validation that keeps the credential bound to its hosts.
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore

final class G09R2MediaEnhancementContractTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        try super.tearDownWithError()
    }

    private func tempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("enh-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func videoSource(width: Int = 1920, height: Int = 1080,
                             fps: Double = 30, duration: Double = 10,
                             isHDR: Bool = false) -> G09R2MediaProbeFacts {
        G09R2MediaProbeFacts(
            isImage: false, width: width, height: height,
            durationSeconds: duration, frameRate: fps,
            frameCount: Int((duration * fps).rounded()),
            hasAudio: true, codec: "h264", isHDR: isHDR,
            byteCount: 1_000_000, sha256: String(repeating: "a", count: 64))
    }

    // MARK: - ENH-IN-OUT-CONTRACT

    func testInterpolationRejectsNonMultipleTargetFPS() {
        let request = G09R2EnhancementRequestDTO(
            inputRelativePath: "Assets/clip.mp4",
            operation: .interpolation(targetFPS: 45), // 1.5x of 30
            outputFileName: "out.mp4")
        XCTAssertThrowsError(
            try G09R2EnhancementGuards.validate(
                source: videoSource(), request: request)) { error in
            guard let refusal = error as? G09R2EnhancementRefusal else {
                return XCTFail("expected a typed refusal, got \(error)")
            }
            XCTAssertEqual(refusal.code, G09R2EnhancementRefusal.targetFPSInvalid("").code)
        }
    }

    func testInterpolationAcceptsTwoToEightXMultiple() throws {
        let request = G09R2EnhancementRequestDTO(
            inputRelativePath: "Assets/clip.mp4",
            operation: .interpolation(targetFPS: 120), // 4x of 30
            outputFileName: "out.mp4")
        let result = try G09R2EnhancementGuards.validate(
            source: videoSource(), request: request)
        XCTAssertEqual(result.outputWidth, 1920)
        XCTAssertEqual(result.outputHeight, 1080)
        XCTAssertEqual(result.framesPerPair, 4)
    }

    func testInterpolationRejectsImagesExplicitly() {
        let image = G09R2MediaProbeFacts(
            isImage: true, width: 800, height: 600, durationSeconds: 0,
            frameRate: 0, frameCount: 0, hasAudio: false, codec: "png",
            byteCount: 10, sha256: "b")
        let request = G09R2EnhancementRequestDTO(
            inputRelativePath: "Assets/photo.png",
            operation: .interpolation(targetFPS: 60),
            outputFileName: "out.mp4")
        XCTAssertThrowsError(
            try G09R2EnhancementGuards.validate(source: image, request: request)) {
            error in
            guard let refusal = error as? G09R2EnhancementRefusal else {
                return XCTFail("expected a typed refusal, got \(error)")
            }
            XCTAssertEqual(
                refusal.code,
                G09R2EnhancementRefusal.unsupportedCombination("").code)
        }
    }

    func testSuperResolutionRejectsScaleOutsideTwoToFour() {
        for scale in [1, 5] {
            let request = G09R2EnhancementRequestDTO(
                inputRelativePath: "Assets/clip.mp4",
                operation: .superResolution(scaleFactor: scale),
                outputFileName: "out.mp4")
            XCTAssertThrowsError(
                try G09R2EnhancementGuards.validate(
                    source: videoSource(), request: request)) { error in
                guard let refusal = error as? G09R2EnhancementRefusal else {
                    return XCTFail("expected a typed refusal, got \(error)")
                }
                XCTAssertEqual(refusal.code, G09R2EnhancementRefusal.scaleInvalid("").code)
            }
        }
    }

    func testSuperResolutionRejectsImagesWithExplicitBoundary() {
        let image = G09R2MediaProbeFacts(
            isImage: true, width: 800, height: 600, durationSeconds: 0,
            frameRate: 0, frameCount: 0, hasAudio: false, codec: "png",
            byteCount: 10, sha256: "b")
        let request = G09R2EnhancementRequestDTO(
            inputRelativePath: "Assets/photo.png",
            operation: .superResolution(scaleFactor: 2),
            outputFileName: "out.mp4")
        XCTAssertThrowsError(
            try G09R2EnhancementGuards.validate(source: image, request: request)) {
            error in
            guard let refusal = error as? G09R2EnhancementRefusal else {
                return XCTFail("expected a typed refusal, got \(error)")
            }
            XCTAssertEqual(
                refusal.code,
                G09R2EnhancementRefusal.unsupportedCombination("").code)
            XCTAssertTrue(refusal.detail.contains("video inputs only"))
        }
    }

    func testSuperResolutionRejectsBeyondBackendFourK() {
        // 2160x1350 * 2x = 4320x2700 = 11.6M pixels > 4k bound.
        let source = videoSource(width: 2160, height: 1350)
        let request = G09R2EnhancementRequestDTO(
            inputRelativePath: "Assets/clip.mp4",
            operation: .superResolution(scaleFactor: 2),
            outputFileName: "out.mp4")
        XCTAssertThrowsError(
            try G09R2EnhancementGuards.validate(source: source, request: request)) {
            error in
            guard let refusal = error as? G09R2EnhancementRefusal else {
                return XCTFail("expected a typed refusal, got \(error)")
            }
            XCTAssertEqual(refusal.code, G09R2EnhancementRefusal.outputTooLarge("").code)
        }
    }

    func testHDRSourceRefusesEightBitOutput() {
        let source = videoSource(isHDR: true)
        let request = G09R2EnhancementRequestDTO(
            inputRelativePath: "Assets/clip.mp4",
            operation: .superResolution(scaleFactor: 2),
            outputFileName: "out.mp4",
            bitDepth: 8)
        XCTAssertThrowsError(
            try G09R2EnhancementGuards.validate(source: source, request: request)) {
            error in
            guard let refusal = error as? G09R2EnhancementRefusal else {
                return XCTFail("expected a typed refusal, got \(error)")
            }
            XCTAssertEqual(
                refusal.code,
                G09R2EnhancementRefusal.unsupportedCombination("").code)
            XCTAssertTrue(refusal.detail.contains("HDR"))
        }
    }

    func testHDRSourceAcceptsTenBit() throws {
        let source = videoSource(isHDR: true)
        let request = G09R2EnhancementRequestDTO(
            inputRelativePath: "Assets/clip.mp4",
            operation: .superResolution(scaleFactor: 2),
            outputFileName: "out.mp4",
            bitDepth: 10)
        let result = try G09R2EnhancementGuards.validate(source: source, request: request)
        XCTAssertEqual(result.outputWidth, 3840)
        XCTAssertEqual(result.outputHeight, 2160)
    }

    // MARK: - Output verification (no success strings)

    func testVerifyOutputRejectsWrongMeasuredFPS() {
        let source = videoSource()
        let measured = videoSource(fps: 24)
        let request = G09R2EnhancementRequestDTO(
            inputRelativePath: "Assets/clip.mp4",
            operation: .interpolation(targetFPS: 60),
            outputFileName: "out.mp4")
        XCTAssertThrowsError(
            try G09R2EnhancementGuards.verifyOutput(
                measured: measured, source: source, request: request))
    }

    func testVerifyOutputRejectsWrongScaledGeometry() {
        let source = videoSource()
        let measured = videoSource(width: 1920, height: 1080) // not scaled
        let request = G09R2EnhancementRequestDTO(
            inputRelativePath: "Assets/clip.mp4",
            operation: .superResolution(scaleFactor: 2),
            outputFileName: "out.mp4")
        XCTAssertThrowsError(
            try G09R2EnhancementGuards.verifyOutput(
                measured: measured, source: source, request: request)) { error in
            guard let refusal = error as? G09R2EnhancementRefusal else {
                return XCTFail("expected a typed refusal, got \(error)")
            }
            XCTAssertEqual(refusal.code, G09R2EnhancementRefusal.outputTooLarge("").code)
        }
    }

    // MARK: - ffmpeg plan

    func testInterpolationScriptUsesMinterpolateAndProgressFile() {
        let layout = G09R2EnhancementGuestLayout(
            jobID: "job-1", inputRelativePath: "Assets/clip.mp4",
            outputFileName: "out.mp4")
        let plan = G09R2EnhancementFFmpegPlan.interpolationScript(
            layout: layout, targetFPS: 120, sourceHasAudio: true)
        XCTAssertTrue(plan.script.contains("minterpolate=fps=120"))
        XCTAssertTrue(plan.script.contains("mi_mode=mci"))
        XCTAssertTrue(plan.script.contains("-progress"))
        XCTAssertTrue(plan.script.contains(G09R2EnhancementFFmpegPlan.probeOutPrefix))
        XCTAssertTrue(plan.script.contains("command -v ffprobe"))
    }

    func testShellQuotingEscapesSingleQuotes() {
        let quoted = G09R2EnhancementShellQuote.quoted("a'b.mp4")
        XCTAssertEqual(quoted, "'a'\\''b.mp4'")
    }

    func testGuestLayoutContainsJobStaging() {
        let layout = G09R2EnhancementGuestLayout(
            jobID: "JOB", inputRelativePath: "Assets/clip.mp4",
            outputFileName: "out.mp4")
        XCTAssertEqual(layout.stagingRelativeDir, ".floe-enhance/job")
        XCTAssertTrue(layout.outputRelativePath.hasSuffix(".part"))
        XCTAssertTrue(layout.progressRelativePath.contains("progress.txt"))
    }

    // MARK: - Probe/progress parsing

    func testProbeParserReadsRationalFPSAndHDR() throws {
        let json = """
        {"streams":[{"codec_name":"hevc","width":3840,"height":2160,\
        "avg_frame_rate":"24000/1001","nb_frames":240,"duration":"10.01",\
        "color_transfer":"smpte2084"}],"format":{"duration":"10.01"}}
        """
        let facts = try G09R2EnhancementProbeParser.parseVideoFacts(
            json, byteCount: 100, sha256: "c")
        XCTAssertEqual(facts.width, 3840)
        XCTAssertEqual(facts.height, 2160)
        XCTAssertEqual(facts.frameRate, 24000.0 / 1001.0, accuracy: 0.001)
        XCTAssertEqual(facts.frameCount, 240)
        XCTAssertTrue(facts.isHDR)
    }

    func testProgressParserReadsLatestFrame() {
        let text = "frame=  12\nfps=0.0\nframe=  34\n"
        XCTAssertEqual(
            G09R2EnhancementProbeParser.latestFrame(fromProgressText: text), 34)
        XCTAssertNil(G09R2EnhancementProbeParser.latestFrame(fromProgressText: "fps=1\n"))
    }

    func testJobOutputBlocksExtraction() {
        let output = """
        ENH_PROBE_IN:
        {"streams":[{"width":1,"height":1,"avg_frame_rate":"1/1","nb_frames":1,"duration":"1"}],"format":{"duration":"1"}}
        ENH_PROBE_OUT:
        {"streams":[{"width":2,"height":2,"avg_frame_rate":"2/1","nb_frames":2,"duration":"1"}],"format":{"duration":"1"}}
        """
        let blocks = G09R2EnhancementProbeParser.blocks(fromJobOutput: output)
        XCTAssertNotNil(blocks.input)
        XCTAssertNotNil(blocks.output)
        XCTAssertNil(blocks.error)
    }

    // MARK: - Journal round trip

    func testJournalRoundTripsRecord() async throws {
        let root = tempRoot()
        let journal = G09R2EnhancementJournal(root: root)
        let record = G09R2EnhancementRecord(
            jobID: "job-abc-123", projectID: UUID(),
            state: .running,
            request: G09R2EnhancementRequestDTO(
                inputRelativePath: "Assets/clip.mp4",
                operation: .interpolation(targetFPS: 60),
                outputFileName: "out.mp4"),
            sourceFacts: videoSource(),
            remoteRequestID: "remote-1",
            createdAt: Date(), updatedAt: Date())
        try await journal.write(record: record)
        let read = try await journal.read(jobID: "job-abc-123")
        XCTAssertEqual(read, record)
        let active = try await journal.activeRecords(projectID: record.projectID)
        XCTAssertEqual(active.count, 1)
    }

    // MARK: - fal backend origin validation

    func testFalBackendRejectsNonFalBaseURL() {
        XCTAssertThrowsError(
            try G09R2FalSuperResolutionBackend.authenticatedQueueBase(
                from: URL(string: "https://example.com")!)) { error in
            guard case .refused = error as? G09R2SuperResolutionBackendError else {
                return XCTFail("expected refused, got \(error)")
            }
        }
        XCTAssertNoThrow(
            try G09R2FalSuperResolutionBackend.authenticatedQueueBase(
                from: URL(string: "https://queue.fal.run")!))
    }

    func testFalBackendRejectsHttpBaseURL() {
        XCTAssertThrowsError(
            try G09R2FalSuperResolutionBackend.authenticatedQueueBase(
                from: URL(string: "http://queue.fal.run")!))
    }

    func testFalMediaHostValidation() {
        XCTAssertTrue(G09R2FalSuperResolutionBackend.isAllowedMediaHost(
            URL(string: "https://v3b.fal.media/files/b/x/y.mp4")!))
        XCTAssertTrue(G09R2FalSuperResolutionBackend.isAllowedMediaHost(
            URL(string: "https://storage.googleapis.com/falserverless/out.mp4")!))
        XCTAssertFalse(G09R2FalSuperResolutionBackend.isAllowedMediaHost(
            URL(string: "https://evil.example.com/out.mp4")!))
        XCTAssertFalse(G09R2FalSuperResolutionBackend.isAllowedMediaHost(
            URL(string: "http://v3b.fal.media/out.mp4")!))
    }

    func testFalSameOriginCheck() {
        let base = URL(string: "https://queue.fal.run/fal-ai/app")!
        XCTAssertTrue(G09R2FalSuperResolutionBackend.sameOrigin(
            URL(string: "https://queue.fal.run/fal-ai/app/requests/1")!, as: base))
        XCTAssertFalse(G09R2FalSuperResolutionBackend.sameOrigin(
            URL(string: "https://other.fal.run/requests/1")!, as: base))
    }

    // MARK: - Explicit muxer (job-418174da5d0c4a52)

    func testInterpolationScriptDeclaresExplicitMp4Muxer() {
        let layout = G09R2EnhancementGuestLayout(
            jobID: "job-1", inputRelativePath: "Assets/clip.mp4",
            outputFileName: "out.mp4")
        let plan = G09R2EnhancementFFmpegPlan.interpolationScript(
            layout: layout, targetFPS: 60, sourceHasAudio: false)
        // The staged name ends in `.part`, so ffmpeg cannot infer the
        // container: the muxer must be explicit or the guest job cannot
        // produce a real MP4.
        XCTAssertTrue(plan.script.contains("-f mp4"))
        XCTAssertTrue(plan.script.contains("-nostats"))
        XCTAssertTrue(plan.script.contains(".part"))
    }

    // MARK: - Canonical queue handle (official fal-js derivation)

    func testFalCanonicalHandleDropsSubpathForStatusResultCancel() {
        let queueBase = URL(string: "https://queue.fal.run")!
        let handle = G09R2FalSuperResolutionBackend.canonicalHandle(
            queueBase: queueBase,
            endpointID: "fal-ai/bytedance-upscaler/upscale/video",
            requestID: "req-123")
        XCTAssertEqual(handle.requestID, "req-123")
        // Official fal-js shape: owner/alias WITHOUT the submission subpath.
        XCTAssertEqual(
            handle.statusURL.absoluteString,
            "https://queue.fal.run/fal-ai/bytedance-upscaler/requests/req-123/status")
        XCTAssertEqual(
            handle.responseURL.absoluteString,
            "https://queue.fal.run/fal-ai/bytedance-upscaler/requests/req-123")
        XCTAssertEqual(
            handle.cancelURL.absoluteString,
            "https://queue.fal.run/fal-ai/bytedance-upscaler/requests/req-123/cancel")
        XCTAssertFalse(handle.statusURL.absoluteString.contains("upscale/video"))
    }

    func testFalCanonicalHandleSupportsNamespaces() {
        let queueBase = URL(string: "https://queue.fal.run")!
        let namespaced = G09R2FalSuperResolutionBackend.canonicalHandle(
            queueBase: queueBase,
            endpointID: "workflows/acme/flow/version/sub",
            requestID: "r9")
        XCTAssertEqual(
            namespaced.statusURL.absoluteString,
            "https://queue.fal.run/workflows/acme/flow/requests/r9/status")
        let plain = G09R2FalSuperResolutionBackend.canonicalHandle(
            queueBase: queueBase,
            endpointID: "fal-ai/fast-sdxl",
            requestID: "r2")
        XCTAssertEqual(
            plain.responseURL.absoluteString,
            "https://queue.fal.run/fal-ai/fast-sdxl/requests/r2")
    }

    func testFalParsedEndpointRejectsSingleSegment() {
        XCTAssertNil(G09R2FalSuperResolutionBackend.parsedEndpoint("fal-ai"))
        XCTAssertNotNil(G09R2FalSuperResolutionBackend.parsedEndpoint("fal-ai/app"))
    }

    func testFalRetainedHandleMustStayOnAuthenticatedOrigin() {
        let queueBase = URL(string: "https://queue.fal.run")!
        let handle = G09R2FalSuperResolutionBackend.canonicalHandle(
            queueBase: queueBase,
            endpointID: "fal-ai/bytedance-upscaler/upscale/video",
            requestID: "req-7")
        XCTAssertNoThrow(
            try G09R2FalSuperResolutionBackend.requireSameOriginAuthenticatedQueueBase(
                URL(string: "https://queue.fal.run")!, handle: handle))
        let foreign = G09R2SuperResolutionAcceptedHandle(
            requestID: "req-7",
            responseURL: URL(string: "https://evil.example.com/requests/req-7")!,
            statusURL: handle.statusURL,
            cancelURL: handle.cancelURL)
        XCTAssertThrowsError(
            try G09R2FalSuperResolutionBackend.requireSameOriginAuthenticatedQueueBase(
                URL(string: "https://queue.fal.run")!, handle: foreign))
    }

    // MARK: - Typed enhancer configuration

    func testEnhancerConfigurationDecodesDirectCredentialRow() throws {
        let json = """
        {"displayName":"My fal key","endpointID":"fal-ai/bytedance-upscaler/upscale/video",\
        "credentialAccount":"media.enhancement.superResolution","contractRevision":1}
        """
        let decoded = try JSONDecoder().decode(
            G09R2EnhancerBackendConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.displayName, "My fal key")
        XCTAssertEqual(
            decoded.endpointID,
            "fal-ai/bytedance-upscaler/upscale/video")
        XCTAssertEqual(
            decoded.credentialAccount,
            G09R2EnhancerBackendConfiguration.defaultCredentialAccount)
        XCTAssertNil(decoded.legacyProviderProfileID)
    }

    func testEnhancerConfigurationDecodesLegacyProviderProfileRow() throws {
        // Predecessor source-only rows referenced a ProviderProfile; they
        // must decode (not fail) and report the reconfigure state.
        let json = """
        {"providerProfileID":"7E84B39D-0000-4000-8000-000000000001",\
        "displayName":"old","contractRevision":1}
        """
        let decoded = try JSONDecoder().decode(
            G09R2EnhancerBackendConfiguration.self, from: Data(json.utf8))
        XCTAssertNotNil(decoded.legacyProviderProfileID)
        XCTAssertEqual(
            decoded.endpointID,
            G09R2EnhancerBackendConfiguration.defaultEndpointID)
    }

    func testJournalReadsLegacyISO8601Dates() async throws {
        let root = tempRoot()
        let record = G09R2EnhancementRecord(
            jobID: "job-legacy-date", projectID: UUID(), state: .running,
            request: .init(inputRelativePath: "Assets/clip.mp4",
                           operation: .superResolution(scaleFactor: 2), outputFileName: "out.mp4"),
            sourceFacts: videoSource(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001))
        let legacy = JSONEncoder()
        legacy.dateEncodingStrategy = .iso8601
        let directory = root.appendingPathComponent("Enhancements/.jobs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try legacy.encode(record).write(to: directory.appendingPathComponent("job-legacy-date.json"))
        let read = try await G09R2EnhancementJournal(root: root).read(jobID: record.jobID)
        XCTAssertEqual(read, record)
    }

    func testFailedJournalEncodingPreservesPriorRecord() async throws {
        let journal = G09R2EnhancementJournal(root: tempRoot())
        let record = G09R2EnhancementRecord(
            jobID: "job-invalid-encoding", projectID: UUID(), state: .running,
            request: .init(inputRelativePath: "Assets/clip.mp4",
                           operation: .interpolation(targetFPS: 60), outputFileName: "out.mp4"),
            sourceFacts: videoSource(), createdAt: Date(), updatedAt: Date())
        try await journal.write(record: record)
        var invalid = record
        invalid.request.operation = .interpolation(targetFPS: .nan)
        do {
            try await journal.write(record: invalid)
            XCTFail("Non-finite JSON must fail before replacing the prior journal")
        } catch is EncodingError { }
        let retained = try await journal.read(jobID: record.jobID)
        XCTAssertEqual(retained, record)
    }

    func testConcurrentJournalUpdatesPreserveAcceptedHandleAndProgress() async throws {
        let journal = G09R2EnhancementJournal(root: tempRoot())
        let jobID = "job-progress-handle"
        let handle = G09R2FalSuperResolutionBackend.canonicalHandle(
            queueBase: URL(string: "https://queue.fal.run")!,
            endpointID: "fal-ai/bytedance-upscaler/upscale/video", requestID: "req-concurrent")
        try await journal.write(record: .init(
            jobID: jobID, projectID: UUID(), state: .running,
            request: .init(inputRelativePath: "Assets/clip.mp4",
                           operation: .superResolution(scaleFactor: 2), outputFileName: "out.mp4"),
            sourceFacts: videoSource(), createdAt: Date(), updatedAt: Date()))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await journal.update(jobID: jobID) {
                    $0.remoteRequestID = handle.requestID
                    $0.remoteHandle = handle
                }
            }
            group.addTask {
                try await journal.update(jobID: jobID) {
                    $0.lastProgress = .init(phase: .processing, completedUnits: 2, totalUnits: 3)
                }
            }
            try await group.waitForAll()
        }
        let record = try await journal.read(jobID: jobID)
        XCTAssertEqual(record?.remoteHandle, handle)
        XCTAssertEqual(record?.remoteRequestID, handle.requestID)
        XCTAssertEqual(record?.lastProgress?.completedUnits, 2)
    }

    // MARK: - Journal round trip with handle + import identity

    func testJournalRoundTripsAcceptedHandleAndImportIdentity() async throws {
        let root = tempRoot()
        let journal = G09R2EnhancementJournal(root: root)
        let queueBase = URL(string: "https://queue.fal.run")!
        let handle = G09R2FalSuperResolutionBackend.canonicalHandle(
            queueBase: queueBase,
            endpointID: "fal-ai/bytedance-upscaler/upscale/video",
            requestID: "req-9")
        var record = G09R2EnhancementRecord(
            jobID: "job-handle-1", projectID: UUID(),
            state: .completed,
            request: G09R2EnhancementRequestDTO(
                inputRelativePath: "Assets/clip.mp4",
                operation: .superResolution(scaleFactor: 2),
                outputFileName: "out.mp4"),
            sourceFacts: videoSource(),
            remoteRequestID: handle.requestID,
            remoteHandle: handle,
            createdAt: Date(), updatedAt: Date())
        record.receipt = G09R2EnhancementReceipt(
            outputRelativePath: "Enhancements/out.mp4",
            engine: "fal", method: "superResolution", inputKind: "video",
            sourceWidth: 1920, sourceHeight: 1080,
            sourceFPS: 30, sourceDurationSeconds: 10, sourceFrameCount: 300,
            outputWidth: 3840, outputHeight: 2160,
            outputFPS: 30, outputDurationSeconds: 10, outputFrameCount: 300,
            outputBytes: 123, outputSHA256: String(repeating: "d", count: 64),
            remoteJobID: handle.requestID,
            importedAssetID: UUID(),
            importRevision: 42)
        try await journal.write(record: record)
        let read = try await journal.read(jobID: "job-handle-1")
        XCTAssertEqual(read, record)
        XCTAssertEqual(read?.remoteHandle, handle)
        XCTAssertEqual(read?.receipt?.importRevision, 42)
        XCTAssertNotNil(read?.receipt?.importedAssetID)
        XCTAssertNil(read?.receipt?.importErrorCode)
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
    func valueOrSelf() -> String { self }
}
