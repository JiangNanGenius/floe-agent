// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import Foundation
import Testing
import FloeCore
import FloePersistence
import FloeTools
import FloeWorkbench
import FloeMusicCore
import FloeMedia
@testable import FloeApp

@Suite("Registered native Music task-file import", .serialized)
@MainActor struct StudioMusicFileImportContractTests {
    private func invoke(_ name: String, _ args: [String: Any], _ context: ToolContext) async throws -> [String: Any] {
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: name))
        let output = try await runner.execute(argumentsJSON: JSONSerialization.data(withJSONObject: args), context: context)
        let bytes = Data((output.capturedOutput ?? output.summary).utf8)
        #expect(StudioToolOutput.hash(bytes) == output.fullOutputSHA256)
        return try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    private func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
    private func contexts(_ body: @MainActor (ToolContext, ToolContext) async throws -> Void) async throws {
        let environment = FloeAgentApp.liveEnvironment; try await environment.ensureDurableAutomationReady()
        var ids: [UUID] = [], contexts: [ToolContext] = [], leases: [WorkspaceCenter.TaskRootLease] = []
        func cleanup() async {
            for lease in leases { lease.release(); try? FileManager.default.removeItem(at: lease.url) }
            for id in ids { try? await environment.conversationStore.deleteConversation(id: id) }
        }
        do {
            for _ in 0..<2 {
                let id = UUID(), runID = UUID(), now = Date(); ids.append(id)
                try await environment.conversationStore.saveConversation(.init(id: id, title: "N13 audio contract", createdAt: now, updatedAt: now))
                try await environment.conversationStore.setArchived(id: id, archived: true)
                let workspace = try await SQLiteWorkspaceStore(database: environment.database).ensureWorkspace(conversationID: id, title: "N13 audio contract")
                let lease = try await environment.workspaceCenter.acquireTaskRoot(workspace, conversationID: id); leases.append(lease)
                try await environment.runStore.saveRun(.init(id: runID, conversationID: id, state: "executing", goal: "Observe native audio", startedAt: now))
                var context = ToolContext(runID: runID, toolCallID: "n13-fixture", allowedToolNames: StudioCoordinator.names,
                    workspaceRootURL: lease.url, cancellation: CancellationToken(), conversationID: id)
                context.frozenEffectiveCatalogNames = StudioCoordinator.names
                context.approvalGrantID = UUID() // Trusted fixture host only; never a model-minted grant.
                contexts.append(context)
            }
            try await body(contexts[0], contexts[1]); await cleanup()
        } catch { await cleanup(); throw error }
    }
    private func withOriginal(_ kind: String, context original: ToolContext,
                              body: @MainActor (UUID, URL, ToolContext) async throws -> Void) async throws {
        var context = original; context.toolCallID = "n13-create-" + UUID().uuidString
        let created = try await invoke("studio.create", ["kind": kind, "title": "N13 audio \(UUID().uuidString.prefix(8))"], context)
        let text = try #require((created["record"] as? [String: Any])?["id"] as? String), id = try #require(UUID(uuidString: text))
        let library = try await PersonalContentService.shared.library(), location = try await library.resolve(id)
        context.approvalGrantID = nil
        do {
            try await body(id, location.url, context)
            try await PersonalLibraryFileActions.delete(try await library.resolve(id).record, environment: FloeAgentApp.liveEnvironment)
        } catch {
            if let current = try? await library.resolve(id) { try? await PersonalLibraryFileActions.delete(current.record, environment: FloeAgentApp.liveEnvironment) }
            throw error
        }
    }
    private func wave(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_048)); buffer.frameLength = 2_048
        let samples = try #require(buffer.floatChannelData?[0])
        for i in 0..<2_048 { samples[i] = i % 2 == 0 ? 0.125 : -0.25 }
        let writer = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try writer.write(from: buffer)
    }

    private func importSource(_ id: UUID, revision: Int64, path: String, hash: String?, context original: ToolContext) async throws -> [String: Any] {
        var context = original; context.approvalGrantID = UUID(); context.toolCallID = "n13-music-import-" + UUID().uuidString
        var source: [String: Any] = ["workspacePath": path]; if let hash { source["expectedSHA256"] = hash }
        return try await invoke("studio.media", ["projectID": id.uuidString, "toolID": "music.import",
            "inputJSON": json(["expectedRevision": String(revision), "source": source])], context)
    }
    private func midi(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Real type-0 SMF: 480 PPQ, 120 BPM, C4 quarter note, end-of-track.
        try Data([0x4d,0x54,0x68,0x64,0,0,0,6,0,0,0,1,1,0xe0,
                  0x4d,0x54,0x72,0x6b,0,0,0,0x14,
                  0,0xff,0x51,3,7,0xa1,0x20,0,0x90,60,100,
                  0x83,0x60,0x80,60,0,0,0xff,0x2f,0]).write(to: url)
    }

    @Test func registeredMusicImportsActualTaskWAVAndSMFThenInspectsSavedAudio() async throws {
        try await contexts { context, _ in
            try await withOriginal("music", context: context) { id, root, context in
                let taskRoot = try #require(context.workspaceRootURL), file = taskRoot.appendingPathComponent("Attachments/source.wav")
                try wave(file); let bytes = try Data(contentsOf: file), digest = StudioToolOutput.hash(bytes)
                let state = try await invoke("studio.read", ["projectID": id.uuidString, "limit": 1], context)
                #expect((state["hostToolIDs"] as? [String])?.contains("music.import") == true)
                let revision = try #require((state["revision"] as? String).flatMap(Int64.init))
                let receipt = try await importSource(id, revision: revision, path: "Attachments/source.wav", hash: digest, context: context)
                #expect(receipt["sha256"] as? String == digest && receipt["byteCount"] as? Int == bytes.count)
                let session = try await MusicProjectSession.open(id: id, directory: root.appendingPathComponent("Music"), environment: FloeAgentApp.liveEnvironment)
                let asset = try #require(session.document.assets.first), payload = try #require(try await session.repository.assetPayload(assetID: asset.id))
                #expect(asset.contentHash == digest && payload.bytes == bytes && asset.sourceLocator.hasPrefix("task/" + context.conversationID!.uuidString.lowercased() + "/file/"))
                let provenance = try #require(JSONSerialization.jsonObject(with: Data(asset.provenance.utf8)) as? [String: Any])
                #expect((provenance["taskID"] as? String)?.lowercased() == context.conversationID?.uuidString.lowercased())
                #expect(provenance["workspacePath"] as? String == "Attachments/source.wav")
                let firstTrack = try #require(session.document.tracks.first)
                if case .audio(let clip) = try #require(firstTrack.clips.first).body { #expect(clip.assetID == asset.id) }
                else { Issue.record("WAV import did not create a real audio clip") }
                let measured = try await invoke("studio.run", ["projectID": id.uuidString, "action": "inspectAudio", "inputJSON": json(["assetID": asset.id.rawValue, "bins": 8])], context)
                let report = try JSONDecoder().decode(AudioWaveformInspection.self, from: JSONSerialization.data(withJSONObject: try #require(measured["audioObservation"] as? [String: Any])))
                #expect(report.source.contentSHA256 == digest && report.source.frameCount == 2_048 && report.channels.first?.binMin.count == 8)
                let smf = taskRoot.appendingPathComponent("Attachments/source.mid"); try midi(smf)
                let midiBytes = try Data(contentsOf: smf)
                _ = try await importSource(id, revision: session.document.revision, path: "Attachments/source.mid", hash: StudioToolOutput.hash(midiBytes), context: context)
                let midiAsset = try #require(session.document.assets.first(where: { $0.kind == .midiFile }))
                #expect(try await session.repository.assetPayload(assetID: midiAsset.id)?.bytes == midiBytes)
                let midiTrack = try #require(session.document.tracks.first(where: { $0.kind == .midi }))
                if case .midi(let notes) = try #require(midiTrack.clips.first).body { #expect(notes.notes.first?.pitch == 60 && notes.notes.count == 1) }
                else { Issue.record("SMF import did not parse actual note events") }
                #expect(try await session.repository.load(projectID: session.document.id) == session.document)
                #expect(try Data(contentsOf: file) == bytes)
            }
        }
    }

    @Test func registeredMusicImportRejectsStaleForeignAndLinkedSourcesBeforeStaging() async throws {
        try await contexts { context, other in
            try await withOriginal("music", context: context) { id, root, context in
                let taskRoot = try #require(context.workspaceRootURL), file = taskRoot.appendingPathComponent("Attachments/source.wav")
                try wave(file); let bytes = try Data(contentsOf: file), hash = StudioToolOutput.hash(bytes)
                let session = try await MusicProjectSession.open(id: id, directory: root.appendingPathComponent("Music"), environment: FloeAgentApp.liveEnvironment)
                let before = session.document
                _ = try await importSource(id, revision: before.revision, path: "Attachments/source.wav", hash: hash, context: context)
                let retained = session.document, metadata = session.root.appendingPathComponent("assets"), blobs = session.root.appendingPathComponent("blobs")
                let assetNames = try FileManager.default.contentsOfDirectory(atPath: metadata.path).sorted(), blobNames = try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted()
                let link = taskRoot.appendingPathComponent("Attachments/linked.wav")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
                let cases = [(before.revision, "Attachments/source.wav", context), (retained.revision, "Attachments/source.wav", other),
                             (retained.revision, "Attachments/linked.wav", context), (retained.revision, file.path, context)]
                for (revision, path, owner) in cases {
                    do { _ = try await importSource(id, revision: revision, path: path, hash: hash, context: owner); Issue.record("A stale/foreign/link/host-path import was accepted") } catch {}
                    #expect(session.document == retained)
                    #expect(try FileManager.default.contentsOfDirectory(atPath: metadata.path).sorted() == assetNames)
                    #expect(try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted() == blobNames)
                }
                #expect(try Data(contentsOf: file) == bytes)
            }
        }
    }

    @Test func actualImportSourceAndCancellationFencesClearTemporaryInspectionCopy() async throws {
        try await contexts { context, _ in
            try await withOriginal("music", context: context) { id, root, context in
                let taskRoot = try #require(context.workspaceRootURL), file = taskRoot.appendingPathComponent("Attachments/source.wav")
                try wave(file); let original = try Data(contentsOf: file)
                let session = try await MusicProjectSession.open(id: id, directory: root.appendingPathComponent("Music"), environment: FloeAgentApp.liveEnvironment), before = session.document
                for mode in ["source", "cancel"] {
                    let token = CancellationToken(); var validations = 0
                    do {
                        _ = try await session.importAuthorizedFile(file, sourceRoot: taskRoot, sourceReference: "trusted-fixture-source", provenance: "fixture",
                            expectedRevision: before.revision, expectedSHA256: StudioToolOutput.hash(original), cancellation: token,
                            validateSource: {
                                validations += 1
                                if validations == 2 {
                                    if mode == "source" { try Data("changed source".utf8).write(to: file) } else { token.cancel() }
                                }
                            })
                        Issue.record("A changed/cancelled native source committed")
                    } catch {}
                    #expect(validations == 2 && session.document == before)
                    #expect(try FileManager.default.contentsOfDirectory(atPath: session.root.path).allSatisfy { !$0.hasPrefix(".music-import-") })
                    #expect(try FileManager.default.contentsOfDirectory(atPath: session.root.appendingPathComponent("assets").path).isEmpty)
                    try original.write(to: file)
                }
            }
        }
    }
}
#endif
