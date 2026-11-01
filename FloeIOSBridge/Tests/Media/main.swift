import AVFoundation
import BridgeCore
import BridgeHostMedia
import CoreMedia
import Foundation

@main
struct MediaTestMain {
    struct TestCase {
        let name: String
        let body: @Sendable () async throws -> Void
    }

    static func main() async {
        let filter = ProcessInfo.processInfo.environment["MEDIA_TEST_FILTER"]
        let tests = allTests().filter { test in
            guard let filter, !filter.isEmpty else { return true }
            return test.name.localizedCaseInsensitiveContains(filter)
        }
        var passes = 0
        var failures: [(String, String)] = []
        print("Bridge media test suite: \(tests.count) tests")
        for test in tests {
            do {
                try await test.body()
                passes += 1
                print("PASS \(test.name)")
            } catch {
                failures.append((test.name, String(describing: error)))
                print("FAIL \(test.name): \(error)")
            }
        }
        print("RESULT pass=\(passes) fail=\(failures.count) total=\(passes + failures.count)")
        if !failures.isEmpty {
            for failure in failures {
                print("FAILED \(failure.0): \(failure.1)")
            }
            exit(1)
        }
        exit(0)
    }

    static func allTests() -> [TestCase] {
        [
            TestCase(name: "muxerBuildsValidInitAndMonotonicFragments", body: testMuxer),
            TestCase(name: "initialStreamStartsWithInitAndKeyframe", body: testInitialStream),
            TestCase(name: "lateJoinStartsWithFreshInitAndKeyframe", body: testLateJoin),
            TestCase(name: "geometryChangeClosesAndReopensFresh", body: testGeometryChange),
            TestCase(name: "slowConsumerIsDisconnectedWithoutUnboundedBuffer", body: testSlowConsumer),
            TestCase(name: "lastSubscriberReleasesProducer", body: testLastSubscriberRelease),
            TestCase(name: "sourceUnavailableIsExplicitAndRecoverable", body: testSourceUnavailable),
            TestCase(name: "transientGateBusyDoesNotTearDownStream", body: testTransientGateBusy),
            TestCase(name: "stopRestartFencesStaleWork", body: testStopRestart),
            TestCase(name: "stopDuringCaptureDoesNotOverlapRestart", body: testStopDuringCapture),
            TestCase(name: "capturesAreSequential", body: testSequentialCapture),
            TestCase(name: "avFoundationDecodesProducedStream", body: testAVFoundationDecode),
        ]
    }

    // MARK: - Unit muxer

    static func testMuxer() async throws {
        let sps = Data([0x67, 0x42, 0xC0, 0x1F, 0xE5, 0x88, 0x68])
        let pps = Data([0x68, 0xCE, 0x3C, 0x80])
        guard let muxer = BridgeFMP4Muxer(width: 320, height: 240, sps: sps, pps: pps) else {
            throw MediaTestFailure("muxer rejected valid parameter sets")
        }
        try mediaExpectEqual(muxer.codecString, "avc1.42C01F", "codec string")
        let first = try muxer.fragment(nalus: [Data([0x65, 0x88, 0x84, 0x00])],
                                       durationTicks: 18_000,
                                       keyframe: true,
                                       presentationTicks: 0)
        let second = try muxer.fragment(nalus: [Data([0x41, 0x9A, 0x00])],
                                        durationTicks: 18_000,
                                        keyframe: false,
                                        presentationTicks: 36_000)
        let combined = muxer.initSegment() + first + second
        let initInfo = try MediaInspector.parseInit(combined)
        try mediaExpectEqual(initInfo.width, 320, "init width")
        try mediaExpectEqual(initInfo.height, 240, "init height")
        try mediaExpectEqual(initInfo.codec, "avc1.42C01F", "init codec")
        try mediaExpectEqual(Data(initInfo.sps.prefix(4)), Data(sps.prefix(4)),
                             "SPS profile bytes retained")
        try mediaExpect(initInfo.sps.count >= sps.count, "SPS rewritten with low-delay VUI")

        let fragments = try MediaInspector.parseFragments(combined, initLength: initInfo.initLength)
        try mediaExpectEqual(fragments.count, 2, "fragment count")
        try mediaExpect(fragments[0].keyframe, "first fragment keyframe")
        try mediaExpectEqual(fragments[0].baseDecodeTime, 0, "first tfdt")
        try mediaExpect(!fragments[1].keyframe, "second fragment non-key")
        try mediaExpectEqual(fragments[1].baseDecodeTime, 36_000, "second tfdt follows presentation")
        try mediaExpect(fragments[0].duration > 0, "positive duration")
        try mediaExpectEqual(fragments[0].sampleSize, UInt32(fragments[0].mdatSize - 8),
                             "sample size matches mdat payload")

        var emptyRejected = false
        do {
            _ = try muxer.fragment(nalus: [], durationTicks: 1, keyframe: true)
        } catch {
            emptyRejected = true
        }
        try mediaExpect(emptyRejected, "empty sample rejected")
        try mediaExpect(BridgeFMP4Muxer(width: 0, height: 240, sps: sps, pps: pps) == nil,
                        "zero dimension rejected")
        try mediaExpect(BridgeFMP4Muxer(width: 320, height: 240, sps: Data(), pps: pps) == nil,
                        "empty SPS rejected")
    }

    // MARK: - Integration tests

    static func testInitialStream() async throws {
        let provider = MockFrameProvider(frames: [
            MediaFixtures.makeScreenFrame(width: 640, height: 480, variant: 1),
        ])
        let registry = BridgeScreenFrameRegistry()
        try mediaExpect(registry.register(owner: "media-test", provider: provider),
                        "provider registration")
        let service = makeService(registry: registry)
        defer { service.stop() }

        let channel = BridgeRPCStreamChannel(bufferBytes: 2 * 1_024 * 1_024)
        let collector = StreamCollector(channel: channel)
        collector.start()
        defer { collector.stop() }

        let opened = await service.openStream(clientID: "client-a", channel: channel)
        try mediaExpect(opened, "openStream succeeds")
        try mediaExpectEqual(service.contentType, "video/mp4", "content type")
        try await mediaWaitUntil { [weak collector] in
            (try? MediaInspector.parseFragments(collector?.data ?? Data(),
                                                initLength: (try? MediaInspector.parseInit(
                                                    collector?.data ?? Data()).initLength) ?? 0).count) ?? 0 >= 2
        }
        let data = collector.data
        let initInfo = try MediaInspector.parseInit(data)
        try mediaExpectEqual(initInfo.width, 320, "scaled width")
        try mediaExpectEqual(initInfo.height, 240, "scaled height")
        try mediaExpect(initInfo.codec.hasPrefix("avc1."), "codec string")
        let fragments = try MediaInspector.parseFragments(data, initLength: initInfo.initLength)
        try mediaExpectGreaterThan(fragments.count, 1, "fragment count")
        try mediaExpect(fragments[0].keyframe, "first fragment is keyframe")
        try mediaExpectEqual(fragments[0].baseDecodeTime, 0, "first decode time")
        for index in 1..<fragments.count {
            try mediaExpect(fragments[index].baseDecodeTime >= fragments[index - 1].baseDecodeTime,
                            "decode times monotonic at \(index)")
            try mediaExpect(fragments[index].sampleSize > 0, "sample size at \(index)")
        }
        writeArtifact("stream-initial.mp4", data: data)

        let diagnostics = service.diagnostics()
        try mediaExpect(diagnostics.framesCaptured >= 2, "captured frames")
        try mediaExpect(diagnostics.framesEncoded >= 2, "encoded frames")
        try mediaExpect(diagnostics.keyFrames >= 1, "keyframes")
        try mediaExpect(diagnostics.fragmentsSent >= 2, "fragments")
        try mediaExpect(diagnostics.bytesSent > 0, "bytes sent")
        try mediaExpect(diagnostics.codec == initInfo.codec, "diagnostic codec")

        service.stop()
        try await collector.waitUntilFinished()
        try mediaExpect(!service.isRunning, "producer stopped")
        try mediaExpectEqual(service.subscriberCount, 0, "subscribers released")
    }

    static func testLateJoin() async throws {
        let provider = MockFrameProvider(frames: [
            MediaFixtures.makeScreenFrame(width: 640, height: 480, variant: 2, encoding: .jpeg),
            MediaFixtures.makeScreenFrame(width: 640, height: 480, variant: 3, encoding: .jpeg),
        ])
        let registry = BridgeScreenFrameRegistry()
        try mediaExpect(registry.register(owner: "media-test", provider: provider),
                        "provider registration")
        var configuration = BridgeVideoService.Configuration()
        configuration.maxDimension = 320
        configuration.targetFramesPerSecond = 10
        configuration.keyFrameIntervalSeconds = 1
        let service = BridgeVideoService(frames: registry, configuration: configuration)
        defer { service.stop() }

        let firstChannel = BridgeRPCStreamChannel(bufferBytes: 2 * 1_024 * 1_024)
        let firstCollector = StreamCollector(channel: firstChannel)
        firstCollector.start()
        defer { firstCollector.stop() }
        let opened = await service.openStream(clientID: "first", channel: firstChannel)
try mediaExpect(opened, "first open")
        try await mediaWaitUntil { [weak firstCollector] in
            (firstCollector?.byteCount ?? 0) > 5_000
        }

        let secondChannel = BridgeRPCStreamChannel(bufferBytes: 2 * 1_024 * 1_024)
        let secondCollector = StreamCollector(channel: secondChannel)
        secondCollector.start()
        defer { secondCollector.stop() }
        let lateOpened = await service.openStream(clientID: "second", channel: secondChannel)
        try mediaExpect(lateOpened, "late join open")
        try await mediaWaitUntil { [weak secondCollector] in
            (secondCollector?.byteCount ?? 0) > 2_000
        }

        let data = secondCollector.data
        let initInfo = try MediaInspector.parseInit(data)
        try mediaExpectEqual(initInfo.width, 320, "late join width")
        let fragments = try MediaInspector.parseFragments(data, initLength: initInfo.initLength)
        try mediaExpect(!fragments.isEmpty, "late join fragment")
        try mediaExpect(fragments[0].keyframe, "late join first fragment is keyframe")
        try mediaExpect(service.subscriberCount == 2, "two subscribers")

        service.stop()
        try await firstCollector.waitUntilFinished()
        try await secondCollector.waitUntilFinished()
    }

    static func testGeometryChange() async throws {
        let provider = MockFrameProvider(frames: [
            MediaFixtures.makeScreenFrame(width: 640, height: 480, variant: 4),
        ])
        let registry = BridgeScreenFrameRegistry()
        try mediaExpect(registry.register(owner: "media-test", provider: provider),
                        "provider registration")
        let service = makeService(registry: registry)
        defer { service.stop() }

        let firstChannel = BridgeRPCStreamChannel(bufferBytes: 2 * 1_024 * 1_024)
        let firstCollector = StreamCollector(channel: firstChannel)
        firstCollector.start()
        defer { firstCollector.stop() }
        let opened = await service.openStream(clientID: "rotate", channel: firstChannel)
try mediaExpect(opened, "portrait open")
        try await mediaWaitUntil { [weak firstCollector] in
            (firstCollector?.byteCount ?? 0) > 5_000
        }

        provider.setFrames([
            MediaFixtures.makeScreenFrame(width: 480, height: 640, variant: 5),
        ])
        try await mediaWaitUntil(timeout: 10) { [weak service] in
            service?.isRunning == false
        }
        try await firstCollector.waitUntilFinished()
        try mediaExpect(service.diagnostics().geometryFences >= 1,
                        "geometry fence recorded")

        let secondChannel = BridgeRPCStreamChannel(bufferBytes: 2 * 1_024 * 1_024)
        let secondCollector = StreamCollector(channel: secondChannel)
        secondCollector.start()
        defer { secondCollector.stop() }
        let rotatedOpened = await service.openStream(clientID: "rotate-2",
                                                    channel: secondChannel)
        try mediaExpect(rotatedOpened, "fresh open after rotation")
        try await mediaWaitUntil { [weak secondCollector] in
            (secondCollector?.byteCount ?? 0) > 2_000
        }
        let initInfo = try MediaInspector.parseInit(secondCollector.data)
        try mediaExpectEqual(initInfo.width, 240, "portrait width")
        try mediaExpectEqual(initInfo.height, 320, "portrait height")
        let portraitFragments = try MediaInspector.parseFragments(
            secondCollector.data, initLength: initInfo.initLength)
        var portrait = initInfo.initData
        for fragment in portraitFragments { portrait.append(fragment.raw) }
        writeArtifact("stream-portrait.mp4", data: portrait)
        service.stop()
        try await secondCollector.waitUntilFinished()
    }

    static func testSlowConsumer() async throws {
        let provider = MockFrameProvider(frames: [
            MediaFixtures.makeScreenFrame(width: 1_280, height: 720, variant: 9),
        ])
        let registry = BridgeScreenFrameRegistry()
        try mediaExpect(registry.register(owner: "media-test", provider: provider),
                        "provider registration")
        var configuration = BridgeVideoService.Configuration()
        configuration.maxDimension = 320
        configuration.targetFramesPerSecond = 30
        configuration.keyFrameIntervalSeconds = 0.5
        configuration.openTimeoutSeconds = 8
        let service = BridgeVideoService(frames: registry, configuration: configuration)
        defer { service.stop() }

        // No iterator is created for this channel: the bounded stream buffer is
        // the only place data can accumulate.
        let channel = BridgeRPCStreamChannel(bufferBytes: 128 * 1_024)
        let opened = await service.openStream(clientID: "slow", channel: channel)
        try mediaExpect(opened, "slow consumer must still get a valid keyframe start")
        try await mediaWaitUntil(timeout: 15) { [weak service] in
            service?.isRunning == false
        }
        try mediaExpectEqual(service.subscriberCount, 0, "slow subscriber removed")
        try mediaExpect(service.diagnostics().framesDropped >= 0, "diagnostics readable")
    }

    static func testLastSubscriberRelease() async throws {
        let provider = MockFrameProvider(frames: [
            MediaFixtures.makeScreenFrame(width: 640, height: 480, variant: 6),
        ])
        let registry = BridgeScreenFrameRegistry()
        try mediaExpect(registry.register(owner: "media-test", provider: provider),
                        "provider registration")
        let service = makeService(registry: registry)
        defer { service.stop() }

        let firstChannel = BridgeRPCStreamChannel(bufferBytes: 2 * 1_024 * 1_024)
        let firstCollector = StreamCollector(channel: firstChannel)
        firstCollector.start()
        defer { firstCollector.stop() }
        let opened = await service.openStream(clientID: "one", channel: firstChannel)
try mediaExpect(opened, "first open")

        let secondChannel = BridgeRPCStreamChannel(bufferBytes: 2 * 1_024 * 1_024)
        let secondCollector = StreamCollector(channel: secondChannel)
        secondCollector.start()
        defer { secondCollector.stop() }
        let secondOpened = await service.openStream(clientID: "two", channel: secondChannel)
        try mediaExpect(secondOpened, "second open")
        try mediaExpectEqual(service.subscriberCount, 2, "two subscribers")

        firstChannel.finish()
        try await mediaWaitUntil { [weak service] in
            service?.subscriberCount == 1
        }
        try mediaExpect(service.isRunning, "producer remains for second subscriber")

        secondChannel.finish()
        try await mediaWaitUntil { [weak service] in
            service?.isRunning == false
        }
        try mediaExpectEqual(service.subscriberCount, 0, "all subscribers released")
        try await firstCollector.waitUntilFinished()
        try await secondCollector.waitUntilFinished()
    }

    static func testSourceUnavailable() async throws {
        let emptyRegistry = BridgeScreenFrameRegistry()
        let emptyService = makeService(registry: emptyRegistry)
        let emptyChannel = BridgeRPCStreamChannel(bufferBytes: 64 * 1_024)
        let emptyOpened = await emptyService.openStream(clientID: "none", channel: emptyChannel)
        try mediaExpect(!emptyOpened, "no provider is unavailable")
        emptyService.stop()

        let provider = MockFrameProvider(frames: [
            MediaFixtures.makeScreenFrame(width: 640, height: 480, variant: 7),
        ])
        provider.setReady(false)
        let registry = BridgeScreenFrameRegistry()
        try mediaExpect(registry.register(owner: "media-test", provider: provider),
                        "provider registration")
        var configuration = BridgeVideoService.Configuration()
        configuration.maxDimension = 320
        configuration.openTimeoutSeconds = 2
        configuration.sourceStallTimeoutSeconds = 2
        let service = BridgeVideoService(frames: registry, configuration: configuration)
        defer { service.stop() }

        let notReadyChannel = BridgeRPCStreamChannel(bufferBytes: 64 * 1_024)
        let notReadyOpened = await service.openStream(clientID: "not-ready",
                                                      channel: notReadyChannel)
        try mediaExpect(!notReadyOpened, "not-ready provider is unavailable")
        try mediaExpect(!service.isRunning, "producer not started")

        provider.setReady(true)
        let channel = BridgeRPCStreamChannel(bufferBytes: 2 * 1_024 * 1_024)
        let collector = StreamCollector(channel: channel)
        collector.start()
        defer { collector.stop() }
        let opened = await service.openStream(clientID: "live", channel: channel)
try mediaExpect(opened, "live open")
        provider.setReady(false)
        try await mediaWaitUntil(timeout: 10) { [weak service] in
            service?.isRunning == false
        }
        try mediaExpect(service.diagnostics().sourceUnavailableCount >= 1,
                        "unavailable recorded")
        try await collector.waitUntilFinished()
    }

    static func testTransientGateBusy() async throws {
        let provider = MockFrameProvider(frames: [
            MediaFixtures.makeScreenFrame(width: 640, height: 480, variant: 12),
        ])
        provider.setReady(false)
        let registry = BridgeScreenFrameRegistry()
        try mediaExpect(registry.register(owner: "media-test", provider: provider),
                        "provider registration")
        var configuration = BridgeVideoService.Configuration()
        configuration.maxDimension = 320
        configuration.openTimeoutSeconds = 8
        configuration.sourceStallTimeoutSeconds = 30
        let service = BridgeVideoService(frames: registry, configuration: configuration)
        defer { service.stop() }

        let channel = BridgeRPCStreamChannel(bufferBytes: 2 * 1_024 * 1_024)
        let collector = StreamCollector(channel: channel)
        collector.start()
        defer { collector.stop() }
        let opening = Task { await service.openStream(clientID: "busy", channel: channel) }
        try await Task.sleep(nanoseconds: 400_000_000)
        try mediaExpect(!service.isRunning || service.subscriberCount == 1,
                        "busy gate leaves the open pending instead of failing")
        provider.setReady(true)
        let opened = await opening.value
        try mediaExpect(opened, "open succeeds after the gate is released")
        try await mediaWaitUntil { [weak collector] in
            (collector?.byteCount ?? 0) > 2_000
        }

        provider.setReady(false)
        try await Task.sleep(nanoseconds: 500_000_000)
        try mediaExpect(service.isRunning, "short gate busy does not tear down the stream")
        provider.setReady(true)
        let before = collector.byteCount
        try await mediaWaitUntil(timeout: 10) { [weak collector] in
            (collector?.byteCount ?? 0) > before
        }
        service.stop()
        try await collector.waitUntilFinished()
    }

    static func testStopRestart() async throws {
        let provider = MockFrameProvider(frames: [
            MediaFixtures.makeScreenFrame(width: 640, height: 480, variant: 8),
        ])
        let registry = BridgeScreenFrameRegistry()
        try mediaExpect(registry.register(owner: "media-test", provider: provider),
                        "provider registration")
        let service = makeService(registry: registry)
        defer { service.stop() }

        let channel = BridgeRPCStreamChannel(bufferBytes: 2 * 1_024 * 1_024)
        let collector = StreamCollector(channel: channel)
        collector.start()
        defer { collector.stop() }
        let opened = await service.openStream(clientID: "restart", channel: channel)
try mediaExpect(opened, "first open")
        try await mediaWaitUntil { [weak collector] in
            (collector?.byteCount ?? 0) > 2_000
        }
        let firstGeneration = service.diagnostics().generation
        service.stop()
        try await collector.waitUntilFinished()
        let fragmentsAfterStop = service.diagnostics().fragmentsSent
        try await Task.sleep(nanoseconds: 300_000_000)
        try mediaExpectEqual(service.diagnostics().fragmentsSent, fragmentsAfterStop,
                             "no stale fragment after stop")
        try mediaExpect(!service.isRunning, "stopped")

        let secondChannel = BridgeRPCStreamChannel(bufferBytes: 2 * 1_024 * 1_024)
        let secondCollector = StreamCollector(channel: secondChannel)
        secondCollector.start()
        defer { secondCollector.stop() }
        let restartedOpened = await service.openStream(clientID: "restart-2",
                                                       channel: secondChannel)
        try mediaExpect(restartedOpened, "restart open")
        try await mediaWaitUntil { [weak secondCollector] in
            (secondCollector?.byteCount ?? 0) > 2_000
        }
        try mediaExpect(service.diagnostics().generation > firstGeneration,
                        "new generation")
        service.stop()
        try await secondCollector.waitUntilFinished()
    }

    static func testStopDuringCapture() async throws {
        let provider = MockFrameProvider(frames: [
            MediaFixtures.makeScreenFrame(width: 640, height: 480, variant: 13),
        ])
        provider.setCaptureDelay(milliseconds: 500)
        let registry = BridgeScreenFrameRegistry()
        try mediaExpect(registry.register(owner: "media-test", provider: provider),
                        "provider registration")
        var configuration = BridgeVideoService.Configuration()
        configuration.maxDimension = 320
        configuration.targetFramesPerSecond = 10
        configuration.openTimeoutSeconds = 5
        let service = BridgeVideoService(frames: registry, configuration: configuration)
        defer { service.stop() }

        let firstChannel = BridgeRPCStreamChannel(bufferBytes: 2 * 1_024 * 1_024)
        let firstOpening = Task { await service.openStream(clientID: "interrupt",
                                                           channel: firstChannel) }
        try await mediaWaitUntil(timeout: 3) { [weak service] in
            service?.subscriberCount == 1
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        service.stop()
        let firstOpened = await firstOpening.value
        try mediaExpect(!firstOpened, "stop resolves the pending open as unavailable")

        provider.setCaptureDelay(milliseconds: 0)
        let secondChannel = BridgeRPCStreamChannel(bufferBytes: 2 * 1_024 * 1_024)
        let secondCollector = StreamCollector(channel: secondChannel)
        secondCollector.start()
        defer { secondCollector.stop() }
        let secondOpened = await service.openStream(clientID: "after-capture",
                                                    channel: secondChannel)
        try mediaExpect(secondOpened, "restart waits for the old capture and succeeds")
        try await mediaWaitUntil { [weak secondCollector] in
            (secondCollector?.byteCount ?? 0) > 2_000
        }
        try mediaExpectEqual(provider.metrics.maximumInFlight, 1,
                             "no overlapping capture across stop/restart")
        service.stop()
        try await secondCollector.waitUntilFinished()
    }

    static func testSequentialCapture() async throws {
        let provider = MockFrameProvider(frames: [
            MediaFixtures.makeScreenFrame(width: 640, height: 480, variant: 10),
        ])
        provider.setCaptureDelay(milliseconds: 120)
        let registry = BridgeScreenFrameRegistry()
        try mediaExpect(registry.register(owner: "media-test", provider: provider),
                        "provider registration")
        var configuration = BridgeVideoService.Configuration()
        configuration.maxDimension = 320
        configuration.targetFramesPerSecond = 20
        let service = BridgeVideoService(frames: registry, configuration: configuration)
        defer { service.stop() }
        let channel = BridgeRPCStreamChannel(bufferBytes: 2 * 1_024 * 1_024)
        let collector = StreamCollector(channel: channel)
        collector.start()
        defer { collector.stop() }
        let opened = await service.openStream(clientID: "serial", channel: channel)
try mediaExpect(opened, "open")
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let metrics = provider.metrics
        try mediaExpectEqual(metrics.maximumInFlight, 1, "at most one capture at a time")
        try mediaExpectGreaterThan(metrics.captures, 1, "multiple sequential captures")
        service.stop()
        try await collector.waitUntilFinished()
    }

    // MARK: - AVFoundation decode proof

    static func testAVFoundationDecode() async throws {
        let provider = MockFrameProvider(frames: [
            MediaFixtures.makeScreenFrame(width: 640, height: 480, variant: 11),
        ])
        let registry = BridgeScreenFrameRegistry()
        try mediaExpect(registry.register(owner: "media-test", provider: provider),
                        "provider registration")
        let service = makeService(registry: registry)
        defer { service.stop() }
        let channel = BridgeRPCStreamChannel(bufferBytes: 2 * 1_024 * 1_024)
        let collector = StreamCollector(channel: channel)
        collector.start()
        defer { collector.stop() }
        let opened = await service.openStream(clientID: "decode", channel: channel)
try mediaExpect(opened, "open")
        try await mediaWaitUntil { [weak collector] in
            (collector?.byteCount ?? 0) > 10_000
        }
        service.stop()
        try await collector.waitUntilFinished()

        let data = collector.data
        let initInfo = try MediaInspector.parseInit(data)
        let fragments = try MediaInspector.parseFragments(data, initLength: initInfo.initLength)
        try mediaExpectGreaterThan(fragments.count, 0, "decode fragments")
        let artifact = initInfo.initData + fragments.reduce(into: Data()) { $0.append($1.raw) }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-media-decode-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try artifact.write(to: url)

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        try mediaExpect(!tracks.isEmpty, "AVFoundation sees a video track")
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let (image, _) = try await generator.image(at: CMTime(seconds: 0.2,
                                                             preferredTimescale: 600))
        try mediaExpectEqual(image.width, initInfo.width, "decoded width")
        try mediaExpectEqual(image.height, initInfo.height, "decoded height")
        writeArtifact("stream-decode.mp4", data: artifact)
        print("AVF_DECODE width=\(image.width) height=\(image.height) fragments=\(fragments.count)")
    }

    // MARK: - Helpers

    static func makeService(registry: BridgeScreenFrameRegistry) -> BridgeVideoService {
        var configuration = BridgeVideoService.Configuration()
        configuration.maxDimension = 320
        configuration.targetFramesPerSecond = 10
        configuration.averageBitRate = 1_500_000
        configuration.openTimeoutSeconds = 8
        configuration.sourceStallTimeoutSeconds = 8
        return BridgeVideoService(frames: registry, configuration: configuration)
    }

    static func writeArtifact(_ name: String, data: Data) {
        guard let directory = mediaArtifactDirectory() else { return }
        try? data.write(to: directory.appendingPathComponent(name))
    }
}
