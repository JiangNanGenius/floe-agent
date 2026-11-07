// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import CoreVideo
import Foundation
import Testing
import FloeCore
import FloePersistence
import FloeTools
import FloeWorkbench
import FloeMusicCore
import FloeMedia
@testable import FloeApp

@Suite("Registered native media import and audio observation", .serialized)
@MainActor struct StudioMediaImportAudioContractTests {
    private func invoke(_ name: String, _ args: [String: Any], _ context: ToolContext) async throws -> [String: Any] {
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: name))
        let result = try await runner.execute(argumentsJSON: JSONSerialization.data(withJSONObject: args), context: context)
        let bytes = Data((result.capturedOutput ?? result.summary).utf8)
        #expect(StudioToolOutput.hash(bytes) == result.fullOutputSHA256)
        return try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    private func withContexts(_ body: @MainActor (ToolContext, ToolContext) async throws -> Void) async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        var ids: [UUID] = [], contexts: [ToolContext] = [], leases: [WorkspaceCenter.TaskRootLease] = []
        func clean() async {
            for lease in leases { lease.release(); try? FileManager.default.removeItem(at: lease.url) }
            for id in ids { try? await environment.conversationStore.deleteConversation(id: id) }
        }
        do {
            for _ in 0..<2 {
                let id = UUID(), runID = UUID(), now = Date(); ids.append(id)
                try await environment.conversationStore.saveConversation(.init(id: id, title: "Media source contract", createdAt: now, updatedAt: now))
                try await environment.conversationStore.setArchived(id: id, archived: true)
                let record = try await SQLiteWorkspaceStore(database: environment.database).ensureWorkspace(conversationID: id, title: "Media source contract")
                try #require(record.kind == .privateTask)
                let lease = try await environment.workspaceCenter.acquireTaskRoot(record, conversationID: id); leases.append(lease)
                try await environment.runStore.saveRun(.init(id: runID, conversationID: id, state: "executing", goal: "Media source contract", startedAt: now))
                var context = ToolContext(runID: runID, toolCallID: "create-original", allowedToolNames: StudioCoordinator.names,
                    workspaceRootURL: lease.url, cancellation: CancellationToken(), conversationID: id)
                context.frozenEffectiveCatalogNames = StudioCoordinator.names; context.approvalGrantID = UUID()
                contexts.append(context)
            }
            try await body(contexts[0], contexts[1]); await clean()
        } catch { await clean(); throw error }
    }
    private func create(_ kind: String, _ context: ToolContext) async throws -> UUID {
        let value = try await invoke("studio.create", ["kind": kind, "title": "Contract media \(UUID().uuidString.prefix(8))"], context)
        let text = try #require((value["record"] as? [String: Any])?["id"] as? String)
        return try #require(UUID(uuidString:text))
    }
    private func readState(_ id:UUID,context:ToolContext,revision:String) async throws -> [String:Any] {
        var offset=0,content=""
        repeat {
            let page = try await invoke("studio.read",["projectID":id.uuidString,"offset":offset,"limit":12000],context)
            #expect(page["revision"] as? String == revision)
            content += try #require(page["contentJSON"] as? String)
            guard let next=page["nextOffset"] as? Int else { break }
            offset=next
        } while true
        return try #require(JSONSerialization.jsonObject(with:Data(content.utf8)) as? [String:Any])
    }
    private func encode(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
    private func movie(_ url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
        writer.add(input); try #require(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(10)
        for frame in 0..<4 {
            while !input.isReadyForMoreMediaData && Date() < deadline {
                try #require(writer.status == .writing); try await Task.sleep(for: .milliseconds(2))
            }
            try #require(input.isReadyForMoreMediaData)
            let pool = try #require(adaptor.pixelBufferPool); var pixel: CVPixelBuffer?
            try #require(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess)
            let buffer = try #require(pixel); CVPixelBufferLockBaseAddress(buffer, [])
            if let address = CVPixelBufferGetBaseAddress(buffer) { memset(address, Int32(frame * 32), CVPixelBufferGetDataSize(buffer)) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try #require(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 4)))
        }
        input.markAsFinished(); await writer.finishWriting(); try #require(writer.status == .completed)
    }
    @Test func registeredTaskMovieImportCommitsRealAssetAndRejectsStaleForeignAndBadSources() async throws {
        try await withContexts { initial, other in
            var context = initial
            let sourcePath = "Attachments/\(UUID().uuidString)/silent.mp4"
            let source = try #require(context.workspaceRootURL).appendingPathComponent(sourcePath)
            try await movie(source)
            let sourceBytes = try Data(contentsOf: source), hash = StudioToolOutput.hash(sourceBytes)
            let id = try await create("video", context), library = try await PersonalContentService.shared.library()
            let before = try await invoke("studio.read", ["projectID": id.uuidString, "limit": 12000], context)
            let revision = try #require(before["revision"] as? String)
            let state = try await readState(id, context:context, revision:revision)
            #expect((state["hostToolIDs"] as? [String])?.contains("media.import") == true)
            let guide = try #require(before["editFormat"] as? String)
            let importSection = try #require(guide.components(separatedBy: "Import inputJSON:\n").last)
            let example = try #require(importSection.components(separatedBy: "\nExample toolID:").first)
            #expect(try StudioMediaSourceContracts.decodeImport(example).expectedRevision == Int64(revision))
            context.toolCallID = "import-actual-task-movie"
            let input: [String: Any] = ["expectedRevision": revision, "source": ["workspacePath": sourcePath, "expectedSHA256": hash]]
            let receipt = try await invoke("studio.media", ["projectID": id.uuidString, "toolID": "media.import", "inputJSON": try encode(input)], context)
            #expect(receipt["sha256"] as? String == hash && receipt["byteCount"] as? Int == sourceBytes.count)
            let location = try await library.resolve(id), session = try await PersonalMediaFactory.session(id: id, directory: location.url)
            let asset = try #require(session.document.assets.first)
            #expect(asset.contentHash == hash && asset.metadata?.audioTracks == 0 && (asset.metadata?.durationSeconds ?? 0)>0)
            #expect(session.document.trackGraph.tracks.filter { $0.kind == .visual }.flatMap(\.clips).contains { $0.assetID == asset.id })
            let actual = try #require(session.resolvedAssets()[asset.id])
            #expect(try Data(contentsOf: actual) == sourceBytes)
            let disk = MediaProjectStore(directory: session.root.appendingPathComponent("Projects"))
            let saved = try #require(try await disk.loadProject(id: id))
            #expect(saved.prepared?.assets == session.document.assets)
            let projectBytes = try Data(contentsOf: disk.projectURL(id: id))
            let assetsBefore = try FileManager.default.contentsOfDirectory(atPath: session.root.appendingPathComponent("Assets").path).sorted()
            let rejected = [(context, input), (other, input), (context, ["expectedRevision": String(session.document.revision), "source": ["workspacePath": sourcePath, "expectedSHA256": String(repeating: "0", count: 64)]] as [String: Any]),
                            (context, ["expectedRevision": String(session.document.revision), "source": ["workspacePath": source.path]] as [String: Any])]
            for (index, pair) in rejected.enumerated() {
                let (owner, request) = pair
                do { _ = try await invoke("studio.media", ["projectID": id.uuidString, "toolID": "media.import", "inputJSON": try encode(request)], owner); Issue.record("A stale, foreign, changed or absolute source was accepted") }
                catch {
                    switch index {
                    case 0: #expect(error as? MediaPreparedCoreError == .documentChanged)
                    case 1: #expect(error.localizedDescription.contains("Open this work"))
                    case 2: #expect(error.localizedDescription.contains("SHA256"))
                    default: #expect(error.localizedDescription.contains("workspacePath"))
                    }
                }
                #expect(try Data(contentsOf: disk.projectURL(id: id)) == projectBytes)
                #expect(try FileManager.default.contentsOfDirectory(atPath: session.root.appendingPathComponent("Assets").path).sorted() == assetsBefore)
            }
            #expect(try Data(contentsOf: source) == sourceBytes)
        }
    }
    @Test func cancellationDuringBoundedCopyDeletesItsPartialAssetAndPreservesSource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("media-copy-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("Media"), source = folder.appendingPathComponent("source.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data(repeating: 0x6A, count: 2 * 1_048_576); try bytes.write(to: source)
        let token = CancellationToken()
        do {
            _ = try MediaV2StagedAsset.copy(source: source, destinationRoot: root, token: token, ephemeralSource: false,
                progress: { _ in token.cancel() })
            Issue.record("A cancellation after the first real copy chunk was ignored")
        } catch { #expect(token.isCancelled) }
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Assets").path).isEmpty)
    }
    @Test func sourceCancellationAndMovedParentFencesRemoveOnlyFreshAssets() async throws {
        for mode in ["source", "cancel", "parent"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("media-fence-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appendingPathComponent("Input/silent.mp4"), root = directory.appendingPathComponent("Media")
            try await movie(source); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = MediaProjectStore(directory: root.appendingPathComponent("Projects")), id = UUID()
            try await store.save(.init(id: id, kind: .video, name: "Fence", canvas: .init(width: 32, height: 32, frameRate: 4), videoTimeline: .init()))
            let session = try await MediaV2Session.open(projectID: id, root: root, store: store, upgrade: true)
            let token = CancellationToken(); var validations = 0
            do {
                _ = try await session.importAuthorizedFile(source, expectedRevision: session.document.revision, cancellation: token, validateSource: {
                    validations += 1
                    if validations == 2 {
                        switch mode {
                        case "source": try Data("changed".utf8).write(to: source)
                        case "cancel": token.cancel()
                        default: try FileManager.default.moveItem(at: root, to: directory.appendingPathComponent("Moved"))
                        }
                    }
                })
                Issue.record("A changed/cancelled/moved import committed")
            } catch { #expect(!error.localizedDescription.isEmpty) }
            #expect(validations == 2, "The actual copy/metadata stage must finish before the injected fence changes")
            let retained = mode == "parent" ? directory.appendingPathComponent("Moved") : root
            #expect(try FileManager.default.contentsOfDirectory(atPath: retained.appendingPathComponent("Assets").path).isEmpty)
            let saved = try #require(try await MediaProjectStore(directory: retained.appendingPathComponent("Projects")).loadProject(id: id))
            #expect(saved.prepared?.assets.isEmpty == true)
            if mode == "parent" { #expect(!FileManager.default.fileExists(atPath: root.path)) }
        }
    }
    private func wave(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12_000)); buffer.frameLength = 12_000
        let channels = try #require(buffer.floatChannelData)
        for index in 0..<12_000 { channels[0][index] = 0.25; channels[1][index] = -0.25 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer)
    }
    @Test func nativeMusicAssetInspectionIsReadOnlyAndRenderedMixCarriesItsActualObservation() async throws {
        try await withContexts { initial, other in
            var context = initial
            let id = try await create("music", context), library = try await PersonalContentService.shared.library()
            let location = try await library.resolve(id), session = try await MusicProjectSession.open(id: id, directory: location.url.appendingPathComponent("Music"), environment: FloeAgentApp.liveEnvironment)
            let source = try #require(context.workspaceRootURL).appendingPathComponent("Attachments/\(UUID().uuidString)/known.wav")
            try wave(source); await session.importFile(source)
            let asset = try #require(session.document.assets.first), revision = session.document.revision
            let before = session.document, modified = try await library.resolve(id).record.modifiedAt
            let input = try StudioTypedEditExamples.encode(StudioAudioInspectInput(assetID: asset.id, startSeconds: 0, endSeconds: 0.25, bins: 4))
            context.approvalGrantID = nil; context.toolCallID = "observe-native-audio-without-mutation-grant"
            let observed = try await invoke("studio.run", ["projectID": id.uuidString, "action": "inspectAudio", "inputJSON": input], context)
            #expect(observed["revision"] as? Int64 == revision)
            let report = try JSONDecoder().decode(AudioWaveformInspection.self, from: JSONSerialization.data(withJSONObject: try #require(observed["audioObservation"] as? [String: Any])))
            #expect(report.source.contentSHA256 == asset.contentHash && report.source.channelCount == 2)
            #expect(report.channels[0].binMin == [0.25,0.25,0.25,0.25] && report.channels[1].binMax == [-0.25,-0.25,-0.25,-0.25])
            #expect(!report.source.path.hasPrefix("/") && !report.source.path.contains("file://"))
            #expect(try await session.repository.load(projectID: before.id) == before)
            #expect(try await library.resolve(id).record.modifiedAt == modified)
            do { _ = try await invoke("studio.run", ["projectID": id.uuidString, "action": "inspectAudio", "inputJSON": input], other); Issue.record("Another task observed a native music asset") }
            catch { #expect(error.localizedDescription.contains("Open this work")) }
            context.approvalGrantID = UUID(); context.toolCallID = "render-with-real-mix-observation"
            let rendered = try await invoke("studio.run", ["projectID": id.uuidString, "action": "renderWAV"], context)
            let mix = try JSONDecoder().decode(AudioWaveformInspection.self, from: JSONSerialization.data(withJSONObject: try #require(rendered["audioObservation"] as? [String: Any])))
            let output = try #require(session.exportedFile), bytes = try Data(contentsOf: output)
            #expect(mix.source.contentSHA256 == StudioToolOutput.hash(bytes) && rendered["sha256"] as? String == mix.source.contentSHA256)
            #expect(rendered["sourceRevision"] as? Int64 == revision)
            #expect(mix.channels.contains { $0.rms > 0 } && !session.isPlaying)
        }
    }
}
#endif
