import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloeSecurity
import FloeTestSupport
import FloeTools
@testable import FloeAgentRuntime

@Suite("Tool images at the actual provider dispatch boundary")
struct ToolVisualEvidenceDispatchTests {
    enum Route: Sendable { case direct, configuredHelper, textOnly }

    @Test(arguments: [Route.direct, .configuredHelper, .textOnly])
    func nativeAnimationFrameHasAnHonestVisualRoute(_ route: Route) async throws {
        let runID = UUID()
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("FloeAgent/CADAnimationFrames/\(runID.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try data.write(to: directory.appendingPathComponent("frame.png"))
        let artifact = ToolArtifactReference(id: UUID(),
            relativePath: "CADAnimationFrames/\(runID.uuidString)/frame.png", mimeType: "image/png",
            byteCount: data.count, sha256: FloeDigest.sha256Hex(data))
        let provider = TestFixtures.localhostProvider()
        var model = TestFixtures.testModel(providerID: provider.id)
        if route == .direct { model.capabilities.insert(.vision) }
        let call = try TestFixtures.toolCall(id: "native-frame")
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(call), .completed(.init(stopReason: .toolUse))],
            [.textDelta(.init(text: "Complete")), .completed(.init(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        executor.results = [.init(callID: call.id, status: .ok,
            outputSummary: "frame revision=7 change_count=12", outputDigest: "frame", artifacts: [artifact])]
        let helperCalls = AsyncLock(0)
        let resolver: (@Sendable ([ConversationImagePart], String) async -> [ConversationMessage])?
        if route == .configuredHelper || route == .direct {
            resolver = { images, _ in
                helperCalls.withLock { $0 += 1 }
                #expect(images.count == 1)
                #expect(Data(base64Encoded: images[0].base64) == data)
                return [.init(role: "system", content: "Configured auxiliary view: the native test frame is visible.")]
            }
        } else { resolver = nil }
        let runtime = FloeAgentRuntime(configuration: .init(provider: provider, model: model),
            adapter: adapter, policy: HumanApprovalPolicy(), executor: executor,
            toolVisualEvidenceResolver: resolver, runID: runID)
        try await runtime.start(goal: "Inspect the native animation frame")
        #expect(await runtime.state.name == "completed")
        #expect(adapter.requests.count == 2)
        let request = try #require(adapter.requests.last)
        let parts = request.contentMessages.flatMap(\.content)
        let images = parts.compactMap { part -> Data? in
            guard case .imageData(_, let base64) = part else { return nil }
            return Data(base64Encoded: base64)
        }
        let text = parts.compactMap { part -> String? in
            guard case .text(let text) = part else { return nil }
            return text
        }.joined(separator: "\n")
        #expect(text.contains(artifact.sha256))
#if canImport(ImageIO)
        #expect(text.contains("sourcePixels=1x1"))
        #expect(text.contains("attachedPixels=1x1"))
        #expect(text.contains("scaleX=1 scaleY=1"))
#endif
        switch route {
        case .direct:
            #expect(images == [data])
            #expect(helperCalls.withLock { $0 } == 0)
        case .configuredHelper:
            #expect(images.isEmpty)
            #expect(helperCalls.withLock { $0 } == 1)
            #expect(text.contains("Configured auxiliary view"))
            #expect(text.contains("not direct sight"))
        case .textOnly:
            #expect(images.isEmpty)
            #expect(helperCalls.withLock { $0 } == 0)
            #expect(text.contains("No visual analysis was delivered"))
        }
    }
}
