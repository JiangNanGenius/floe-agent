// SPDX-License-Identifier: MPL-2.0
#if canImport(AVFoundation) && canImport(Darwin)
import Foundation
import AVFoundation
import Testing
import FloeCore
import FloeTools
import FloeMedia
import FloeAgentRuntime
import FloeSecurity
import FloeTestSupport

/// Uses the real registered audio decoder, CatalogToolExecutor, capture store
/// and request selector. Only provider transport is scripted by MockAdapter.
@Suite("Audio waveform model visibility", .serialized)
struct AudioWaveformModelVisibilityTests {
    private func writePCM(to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate:8000,channels:2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:2048))
        buffer.frameLength = 2048
        let samples = try #require(buffer.floatChannelData)
        let a: [Float] = [0.125,-0.125,0.25,-0.25,0,0,0.5,-0.5]
        let b: [Float] = [0.03125,-0.03125,0.0625,-0.0625,0,0,0.125,-0.125]
        let tail: [Float] = [0.8125,-0.9375,0.125,-0.125,0,0,0.25,-0.25]
        for frame in 0..<2048 {
            samples[0][frame] = a[frame % 8]
            samples[1][frame] = frame >= 2040 ? tail[frame - 2040] : b[frame % 8]
        }
        let writer = try AVAudioFile(forWriting:url,settings:format.settings,commonFormat:.pcmFormatFloat32,interleaved:false)
        try writer.write(from:buffer)
    }

    @Test("Real PCM bins beyond the 4K UI preview reach the next provider request")
    func actualAudioResultReachesTheModelWithItsFinalBin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-model-visibility-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("source.caf")
        try writePCM(to:source)

        let productionRegistration = ToolRunnerRegistry()
        MediaToolRegistration.register(registry:productionRegistration,appBuild:"audio-model-visibility-test")
        let registered = try #require(productionRegistration.runner(named:AudioInspectTool.name))
        let observed = AsyncLock<ToolExecutionOutput?>(nil)
        let registry = ToolRunnerRegistry()
        registry.register(AnyAgentTool(descriptor:registered.descriptor,run:{ arguments,context in
            // Observe the real output; never substitute a synthesized result.
            let output = try await registered.run(arguments,context)
            observed.withLock { $0 = output }
            return output
        },validateArguments:registered.validateArguments,preflightSubmission:registered.preflightSubmission,
            routing:ToolEnvironmentRouting()))
        let call = try TestFixtures.toolCall(id:"actual-pcm-observation",toolName:AudioInspectTool.name,
            arguments:#"{"path":"source.caf","bins":256}"#)
        let provider = TestFixtures.localhostProvider(), adapter = MockAdapter(), checkpoints = MockCheckpointStore()
        adapter.script = [
            [.toolRequest(call),.completed(.init(stopReason:.toolUse))],
            [.textDelta(.init(text:"PCM result received.")),.completed(.init(stopReason:.endTurn))]
        ]
        let runtime = FloeAgentRuntime(configuration:.init(conversationID:UUID(),provider:provider,
            model:TestFixtures.testModel(providerID:provider.id),allowedToolNames:[AudioInspectTool.name],
            workspaceRootURL:root,allowedWorkspacePaths:["source.caf"],
            toolResultCaptureRoot:root.appendingPathComponent("Captures")),
            adapter:adapter,policy:HumanApprovalPolicy(),executor:CatalogToolExecutor(runners:registry),checkpointStore:checkpoints)
        try await runtime.start(goal:"Inspect the actual PCM waveform in the authorized source.caf, including its last bin.")
        #expect(await runtime.state.name == "completed")
        #expect(adapter.requests.count == 2)

        let output = try #require(observed.withLock { $0 }), complete = try #require(output.capturedOutput)
        #expect(output.summaryTruncated && !output.capturedOutputTruncated)
        #expect(complete.utf8.count > 4096 && complete.utf8.count <= 65_536)
        let tailMarker = #""startFrame":2040"#
        #expect(complete.contains(tailMarker) && !output.summary.contains(tailMarker))
        #expect(output.fullOutputSHA256 == FloeDigest.sha256Hex(Data(complete.utf8)))

        // This is the actual continuation delivered to ProviderAdapter.stream,
        // after Runtime capture, provenance and model-budget selection.
        let followup = try #require(adapter.requests.dropFirst().first)
        #expect(followup.pendingToolCalls.map(\.id) == [call.id])
        let wire = try #require(followup.toolResults.first { $0.callID == call.id }?.output)
        #expect(wire.contains("trustedSourceID"))
        #expect(wire.hasSuffix(complete),"The provider must receive the full real JSON, not the 4K display summary.")
        #expect(wire.contains(tailMarker))
        let range = try #require(wire.range(of:complete))
        let received = try JSONDecoder().decode(AudioWaveformInspection.self,from:Data(wire[range].utf8))
        #expect(received.source.contentSHA256 == (try FloeDigest.sha256Hex(ofFileAt:source)))
        #expect(received.source.frameCount == 2048 && received.source.channelCount == 2)
        #expect(received.window.effectiveBins == 256 && received.window.analyzedFrameCount == 2048)
        #expect(received.bins.last?.startFrame == 2040 && received.bins.last?.endFrame == 2048)
        #expect(received.channels[1].binMin.count == 256 && received.channels[1].binMax.count == 256)
        #expect(received.channels[1].binMin.last == -0.9375 && received.channels[1].binMax.last == 0.8125)
        let finalRMS = try #require(received.channels[1].binRMS.last)
        #expect(abs(finalRMS - sqrt(1.6953125 / 8)) < 1e-12)
        let settled = try #require(checkpoints.saved.flatMap(\.pendingToolResults).first { $0.callID == call.id })
        #expect(settled.status == .ok)
    }
}
#endif
