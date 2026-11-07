// SPDX-License-Identifier: MPL-2.0
#if canImport(AVFoundation) && canImport(Darwin)
import Foundation
import AVFoundation
import Testing
import FloeCore
import FloeTools
@testable import FloeMedia

@Suite("Audio waveform observation", .serialized)
struct AudioWaveformInspectionTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-observation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    private func write(_ channels:[[Float]],to url:URL,rate:Double = 8000) throws {
        let frames = try #require(channels.first?.count)
        #expect(channels.allSatisfy { $0.count == frames })
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate:rate,channels:AVAudioChannelCount(channels.count)))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = try #require(buffer.floatChannelData)
        for channel in channels.indices { for frame in channels[channel].indices { samples[channel][frame] = channels[channel][frame] } }
        let writer = try AVAudioFile(forWriting:url,settings:format.settings,commonFormat:.pcmFormatFloat32,interleaved:false)
        try writer.write(from:buffer)
    }
    private func context(_ root:URL,allowed:[String] = [],token:CancellationToken = .init(),temporary:Bool = false) -> ToolContext {
        .init(runID:UUID(),workspaceRootURL:root,allowedWorkspacePaths:allowed,cancellation:token,
            environmentID:"audio-fixture",temporaryReadOnly:temporary)
    }
    private var left:[Float] { [0,0,0,0, 0.5,-0.5,0.5,-0.5, 1,-1,0,0, 0.25,-0.25,0.25,-0.25] }
    private var right:[Float] { [0.25,0.25,0.25,0.25, -0.25,-0.25,-0.25,-0.25, 1.25,-1.25,0.5,-0.5, 0,0,0,0] }

    @Test("Native PCM decode retains each channel and every selected sample")
    func actualDecodedBinsAndStatistics() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("source.caf")
        try write([left,right],to:file)
        let result = try await AudioWaveformInspector().inspect(path:"source.caf",bins:4,context:context(root))
        #expect(result.source.path == "source.caf")
        #expect(result.source.kind == "taskWorkspace")
        #expect(result.source.contentSHA256 == (try FloeDigest.sha256Hex(ofFileAt:file)))
        #expect(result.source.byteCount == Int64(try Data(contentsOf:file).count))
        #expect(result.source.resourceIdentity.count == 64)
        #expect(result.source.environmentID == "audio-fixture")
        #expect(result.source.sampleRate == 8000)
        #expect(result.source.channelCount == 2)
        #expect(result.source.frameCount == 16)
        #expect(result.window.coversEntireSource)
        #expect(result.window.analyzedFrameCount == 16)
        #expect(result.bins.map(\.startFrame) == [0,4,8,12])
        #expect(result.bins.map(\.endFrame) == [4,8,12,16])
        let a = result.channels[0], b = result.channels[1]
        #expect(a.binMin == [0,-0.5,-1,-0.25])
        #expect(a.binMax == [0,0.5,1,0.25])
        #expect(abs(a.binRMS[2] - sqrt(0.5)) < 1e-12)
        #expect(abs(a.rms - sqrt(3.25/16)) < 1e-12)
        #expect(a.peakAbsolute == 1 && a.fullScaleOrOverSampleCount == 2 && a.overFullScaleSampleCount == 0)
        #expect(a.silentSampleCount == 6 && a.longestSilentRunFrames == 4)
        #expect(a.meanDC == 0)
        #expect(b.binMin == [0.25,-0.25,-1.25,0])
        #expect(b.binMax == [0.25,-0.25,1.25,0])
        #expect(abs(b.rms - sqrt(4.125/16)) < 1e-12)
        #expect(b.peakAbsolute == 1.25 && b.fullScaleOrOverSampleCount == 2 && b.overFullScaleSampleCount == 2)
        #expect(b.silentSampleCount == 4 && b.longestSilentRunFrames == 4)
        #expect(b.peakDBFS! > 0)
    }

    @Test("Fractional time requests report the exact actual PCM frame window")
    func selectedTimeWindow() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        try write([left,right],to:root.appendingPathComponent("source.caf"))
        let start = 4.25/8000.0, end = 11.25/8000.0
        let result = try await AudioWaveformInspector().inspect(path:"source.caf",startSeconds:start,endSeconds:end,bins:2,context:context(root))
        #expect(result.window.requestedStartSeconds == start && result.window.requestedEndSeconds == end)
        #expect(result.window.startFrame == 4 && result.window.endFrame == 12)
        #expect(result.window.startSeconds == 4/8000.0 && result.window.endSeconds == 12/8000.0)
        #expect(result.window.analyzedFrameCount == 8 && !result.window.coversEntireSource)
        #expect(result.bins.map(\.frameCount) == [4,4])
        #expect(result.channels[0].binMin == [-0.5,-1])
        #expect(result.channels[0].binMax == [0.5,1])
        #expect(result.channels[1].peakAbsolute == 1.25)
    }

    @Test("Path-only defaults produce waveform data and bounded explicit coverage")
    func defaultWindowAndUnevenBins() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        try write([[Float](repeating:0,count:31*8000)],to:root.appendingPathComponent("long.caf"))
        let result = try await AudioWaveformInspector().inspect(path:"long.caf",context:context(root))
        #expect(result.source.durationSeconds == 31)
        #expect(result.window.startSeconds == 0 && result.window.endSeconds == 30)
        #expect(result.window.analyzedFrameCount == 30*8000 && !result.window.coversEntireSource)
        #expect(result.bins.count == 64 && result.channels[0].binRMS.count == 64)
        #expect(result.window.requestedBins == 64 && result.window.effectiveBins == 64)
        try write([[0,0.5,-0.5,1,-1,0.25,0.75]],to:root.appendingPathComponent("uneven.caf"))
        let uneven = try await AudioWaveformInspector().inspect(path:"uneven.caf",bins:3,context:context(root))
        #expect(uneven.bins.map(\.frameCount) == [2,2,3])
        #expect(uneven.bins.map(\.startFrame) == [0,2,4])
        #expect(uneven.bins.map(\.endFrame) == [2,4,7])
        #expect(uneven.channels[0].binMin == [0,-0.5,-1])
        #expect(uneven.channels[0].binMax == [0.5,1,0.75])
        #expect(abs(uneven.channels[0].binRMS[2] - sqrt((1+0.0625+0.5625)/3)) < 1e-12)
    }

    @Test("Digital silence produces valid JSON with explicit null dBFS")
    func silentResultIsFiniteJSON() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        try write([[0,0,0,0]],to:root.appendingPathComponent("silent.caf"))
        let result = try await AudioWaveformInspector().inspect(path:"silent.caf",bins:8,context:context(root))
        #expect(result.bins.count == 4)
        #expect(result.window.requestedBins == 8 && result.window.effectiveBins == 4)
        #expect(result.channels[0].exactDigitalSilence)
        #expect(result.channels[0].peakDBFS == nil && result.channels[0].rmsDBFS == nil)
        let bytes = try JSONEncoder().encode(result)
        let json = try #require(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        let channel = try #require((json["channels"] as? [[String:Any]])?.first)
        #expect(channel["peakDBFS"] is NSNull)
        #expect(channel["rmsDBFS"] is NSNull)
        #expect(channel["rms"] as? Double == 0)
        #expect(!String(decoding:bytes,as:UTF8.self).contains("estimatedLUFS"))
    }

    @Test("Real registration exposes the extended schema and invokes the decoder")
    func registeredRunnerAndFileScope() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        try write([left,right],to:root.appendingPathComponent("source.caf"))
        let registry = ToolRunnerRegistry()
        MediaToolRegistration.register(registry:registry,appBuild:"audio-observation-test")
        let descriptor = try #require(ToolCatalog.descriptor(named:"audio.inspect"))
        #expect(descriptor.riskLabels == [.readsFiles] && !descriptor.isSideEffecting && descriptor.effect == .readOnly)
        #expect(TemporaryChatToolPolicy.readOnlyDescriptor(descriptor) == nil)
        let schema = try #require(JSONSerialization.jsonObject(with:Data(descriptor.parametersJSON.utf8)) as? [String:Any])
        #expect(schema["required"] as? [String] == ["path"])
        let properties = try #require(schema["properties"] as? [String:Any])
        #expect(properties["startSeconds"] != nil && properties["endSeconds"] != nil && properties["bins"] != nil)
        let registered = try #require(registry.runner(named:"audio.inspect"))
        // Fixture routing is isolated from the running App's real registry;
        // descriptor/arguments/execute remain the registered production tool.
        let runner = AnyAgentTool(descriptor:registered.descriptor,run:registered.run,
            validateArguments:registered.validateArguments,routing:ToolEnvironmentRouting())
        let output = try await runner.execute(argumentsJSON:Data(#"{"path":"source.caf","bins":4}"#.utf8),context:context(root,allowed:["source.caf"]))
        let complete = try #require(output.capturedOutput)
        #expect(!output.capturedOutputTruncated)
        #expect(complete.utf8.count <= 65_536)
        #expect(output.fullOutputSHA256 == FloeDigest.sha256Hex(Data(complete.utf8)))
        let result = try JSONDecoder().decode(AudioWaveformInspection.self,from:Data(complete.utf8))
        #expect(result.channels[1].peakAbsolute == 1.25 && result.bins.count == 4)
        let legacy = try await runner.execute(argumentsJSON:Data(#"{"path":"source.caf"}"#.utf8),context:context(root))
        #expect(try JSONDecoder().decode(AudioWaveformInspection.self,from:Data((legacy.capturedOutput ?? legacy.summary).utf8)).bins.count == 16)
        await #expect(throws:(any Error).self) {
            _ = try await runner.execute(argumentsJSON:Data(#"{"path":"source.caf"}"#.utf8),context:context(root,allowed:["different.caf"]))
        }
    }

    @Test("Both declared path and resolved symlink target must be authorized")
    func canonicalPathCeilingAndTemporaryPolicy() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root.appendingPathComponent("allowed"),withIntermediateDirectories:true)
        try write([left],to:root.appendingPathComponent("private.caf"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("allowed/alias.caf"),withDestinationURL:root.appendingPathComponent("private.caf"))
        await #expect(throws:(any Error).self) {
            _ = try await AudioWaveformInspector().inspect(path:"allowed/alias.caf",context:context(root,allowed:["allowed"]))
        }
        await #expect(throws:(any Error).self) {
            _ = try await AudioWaveformInspector().inspect(path:"../private.caf",context:context(root))
        }
        await #expect(throws:(any Error).self) {
            _ = try await AudioWaveformInspector().inspect(path:"/etc/hosts",context:context(root))
        }
        await #expect(throws:(any Error).self) {
            _ = try await AudioWaveformInspector().inspect(path:"private.caf",context:context(root,temporary:true))
        }
    }

    @Test("Invalid windows, decoding failures, budgets and cancellation are explicit")
    func errorsAndCancellation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        try write([left],to:root.appendingPathComponent("source.caf"))
        try Data("not an audio file".utf8).write(to:root.appendingPathComponent("broken.caf"))
        let engine = AudioWaveformInspector()
        await #expect(throws:(any Error).self) { _ = try await engine.inspect(path:"broken.caf",context:context(root)) }
        await #expect(throws:AudioWaveformInspectionError.self) { _ = try await engine.inspect(path:"source.caf",startSeconds:1,context:context(root)) }
        await #expect(throws:AudioWaveformInspectionError.self) { _ = try await engine.inspect(path:"source.caf",endSeconds:121,context:context(root)) }
        await #expect(throws:AudioWaveformInspectionError.self) { _ = try await engine.inspect(path:"source.caf",startSeconds:.nan,context:context(root)) }
        await #expect(throws:AudioWaveformInspectionError.self) { _ = try await engine.inspect(path:"source.caf",bins:257,context:context(root)) }
        let token = CancellationToken(); token.cancel()
        await #expect(throws:FloeError.self) { _ = try await engine.inspect(path:"source.caf",context:context(root,token:token)) }
        let (events, start) = AsyncStream<Void>.makeStream()
        let task = Task {
            var iterator = events.makeAsyncIterator(); _ = await iterator.next()
            return try await engine.inspect(path:"source.caf",context:context(root))
        }
        task.cancel(); start.finish()
        await #expect(throws:CancellationError.self) { _ = try await task.value }
        let tooLarge = root.appendingPathComponent("too-large.caf")
        #expect(FileManager.default.createFile(atPath:tooLarge.path,contents:Data()))
        let handle = try FileHandle(forWritingTo:tooLarge)
        try handle.truncate(atOffset:UInt64(AudioWaveformInspector.maximumSourceBytes + 1)); try handle.close()
        await #expect(throws:AudioWaveformInspectionError.self) { _ = try await engine.inspect(path:"too-large.caf",context:context(root)) }
    }

    @Test("Changed source bytes never reuse a prior identity or UI waveform")
    func sourceByteGuard() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("source.caf")
        try write([left],to:file)
        let token = CancellationToken()
        let snapshot = try AudioWaveformSourceSnapshot.capture(url:file,cancellation:token)
        var data = try Data(contentsOf:file); data[data.count-1] ^= 1; try data.write(to:file)
        #expect(throws:AudioWaveformInspectionError.sourceChanged) { try snapshot.validate(url:file,cancellation:token) }
        // Even a current metadata stamp cannot substitute for the old SHA.
        let unchangedMetadataClaim = AudioWaveformSourceSnapshot(stamp:try .read(file),sha256:snapshot.sha256)
        #expect(throws:AudioWaveformInspectionError.sourceChanged) { try unchangedMetadataClaim.validate(url:file,cancellation:token) }
    }

    @Test("Native assets reuse the same decoder only after binding and SHA checks")
    func verifiedNativeSourceBridge() async throws {
        let root = try directory(), outside = try directory()
        defer { try? FileManager.default.removeItem(at:root); try? FileManager.default.removeItem(at:outside) }
        let file = outside.appendingPathComponent("native-asset.caf")
        try write([left,right],to:file)
        let expected = try FloeDigest.sha256Hex(ofFileAt:file), reference = "studio:verified-project:asset:actual-asset"
        let report = try await AudioWaveformInspector().inspectAuthorizedSource(at:file,sourceReference:reference,expectedSHA256:expected,bins:4,context:context(root)) { }
        #expect(report.source.kind == "authorizedNativeSource" && report.source.path == reference)
        #expect(!report.source.path.contains(outside.path))
        #expect(report.channels[1].peakAbsolute == 1.25 && report.source.contentSHA256 == expected)
        await #expect(throws:AudioWaveformInspectionError.sourceChanged) {
            _ = try await AudioWaveformInspector().inspectAuthorizedSource(at:file,sourceReference:reference,expectedSHA256:String(repeating:"0",count:64),context:context(root)) { }
        }
        await #expect(throws:FloeError.self) {
            _ = try await AudioWaveformInspector().inspectAuthorizedSource(at:file,sourceReference:reference,expectedSHA256:expected,context:context(root)) {
                throw FloeError.validationFailed("Fixture project binding is no longer owned by this task")
            }
        }
        await #expect(throws:FloeError.self) {
            _ = try await AudioWaveformInspector().inspectAuthorizedSource(at:file,sourceReference:reference,expectedSHA256:expected,context:context(root,temporary:true)) { }
        }
    }
}
#endif
