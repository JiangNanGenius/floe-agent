// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import CoreVideo
import Darwin
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
    @Test func guestFrameFileImportsAsRealVideoAndPreservesTaskBoundary() async throws {
        try await withContexts { initial, other in
            var context = initial
            let sourcePath = "frames/sequence.bgra"
            let source = try #require(context.workspaceRootURL).appendingPathComponent(sourcePath)
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            var bytes = Data()
            for frame in 0..<4 {
                let pixel: [UInt8] = frame.isMultiple(of: 2) ? [0, 0, 255, 255] : [255, 0, 0, 255]
                for _ in 0..<(32 * 32) { bytes.append(contentsOf: pixel) }
            }
            try bytes.write(to: source)
            let id = try await create("video", context)
            let read = try await invoke("studio.read", ["projectID": id.uuidString, "limit": 12000], context)
            let revision = try #require(read["revision"] as? String)
            let state = try await readState(id, context: context, revision: revision)
            #expect((state["hostToolIDs"] as? [String])?.contains("video.importFrames") == true)
            #expect((read["editFormat"] as? String)?.contains("video.importFrames") == true)
            let input: [String: Any] = ["expectedRevision": revision,
                "source": ["workspacePath": sourcePath, "expectedSHA256": StudioToolOutput.hash(bytes)],
                "width": 32, "height": 32, "frameRate": 4, "frameCount": 4]
            context.toolCallID = "import-guest-frames"
            let receipt = try await invoke("studio.media", ["projectID": id.uuidString, "toolID": "video.importFrames", "inputJSON": try encode(input)], context)
            #expect(receipt["sourceSHA256"] as? String == StudioToolOutput.hash(bytes))
            let library = try await PersonalContentService.shared.library()
            let location = try await library.resolve(id)
            let session = try await PersonalMediaFactory.session(id: id, directory: location.url)
            let asset = try #require(session.document.assets.first)
            #expect(asset.kind == .video && asset.metadata?.audioTracks == 0)
            #expect(session.document.trackGraph.tracks.flatMap(\.clips).contains { $0.assetID == asset.id })
            let movieURL = try #require(session.resolvedAssets()[asset.id])
            #expect(try Data(contentsOf: movieURL).count > 0)
            #expect(try Data(contentsOf: source) == bytes)
            let disk = MediaProjectStore(directory: session.root.appendingPathComponent("Projects"))
            let saved = try #require(try await disk.loadProject(id: id))
            #expect(saved.prepared?.assets.contains(where: { $0.id == asset.id }) == true)
            let replay = try await invoke("studio.media", ["projectID": id.uuidString, "toolID": "video.importFrames", "inputJSON": try encode(input)], context)
            #expect(replay["replayed"] as? Bool == true)
            #expect(replay["groupID"] as? String == receipt["groupID"] as? String)
            context.toolCallID = "new-stale-frame-import"
            for owner in [context, other] {
                do {
                    _ = try await invoke("studio.media", ["projectID": id.uuidString, "toolID": "video.importFrames", "inputJSON": try encode(input)], owner)
                    Issue.record("Stale or foreign frame import was accepted")
                } catch {}
                let after = try #require(try await disk.loadProject(id: id))
                #expect(after.prepared?.assets == saved.prepared?.assets)
            }
        }
    }
    @Test func importCommitSurvivesRefreshFailureAndReplaysDurableJournal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("media-frame-replay-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4"), root = directory.appendingPathComponent("Media")
        try await movie(source); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MediaProjectStore(directory: root.appendingPathComponent("Projects")), id = UUID()
        try await store.save(.init(id: id, kind: .video, name: "Replay", canvas: .init(width: 32, height: 32, frameRate: 4), videoTimeline: .init()))
        let session = try await MediaV2Session.open(projectID: id, root: root, store: store, upgrade: true)
        let base = session.document.revision
        let identity = MediaV2Session.ImportIdentity(groupID: UUID(), operationID: UUID())
        let imported = try await session.importAuthorizedFile(source, expectedRevision: base, actor: .model,
            identity: identity, refreshAfterCommit: { throw PersonalContentError.storageUnavailable })
        #expect(imported.refreshPending)
        let saved = try #require(try await store.loadProject(id: id))
        #expect(saved.prepared?.assets.count == 1)
        #expect(saved.preparedJournal?.entry(identity.groupID)?.committedRevision == imported.commit.revision)
        let replay = try #require(try await session.replayImport(identity, expectedRevision: base))
        #expect(replay.replayed && replay.commit.groupID == imported.commit.groupID && replay.asset.id == imported.asset.id)
        do {
            _ = try await session.importAuthorizedFile(source, expectedRevision: base, actor: .model,
                identity: .init(groupID: identity.groupID, operationID: UUID()))
            Issue.record("Changed input reused a committed request")
        } catch {}
        #expect(try await store.loadProject(id: id)?.prepared?.assets.count == 1)
        try await session.reload()
        _ = try await session.coordinator.undoGroup(identity.groupID, in: id)
        let undone = try #require(try await session.replayImport(identity, expectedRevision: base))
        #expect(undone.replayed && undone.journalStatus == .undone)
        do {
            _ = try await MediaV2Session.open(projectID: id, root: directory.appendingPathComponent("DifferentRoot"), store: store)
            Issue.record("A cached session was reused for a different root")
        } catch PersonalContentError.changedDocument {} catch { Issue.record("Unexpected root mismatch error: \(error)") }
        let pending = await StudioFrameImportFinalization.libraryRefreshPending { throw PersonalContentError.storageUnavailable }
        #expect(pending)
        let refreshed = await StudioFrameImportFinalization.libraryRefreshPending {}
        #expect(!refreshed)
    }
    @Test func competingCommitCannotBypassOriginalExpectedRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-frame-cas-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaProjectStore(directory: root.appendingPathComponent("Projects")), id = UUID()
        try await store.save(.init(id: id, kind: .video, name: "CAS", canvas: .init(width: 32, height: 32, frameRate: 4), videoTimeline: .init()))
        let coordinator = MediaPreparedCoordinator(store: store)
        let base = try await coordinator.upgradeDocument(id: id).revision
        let earlier = try await coordinator.beginInstruction(documentID: id, targets: [], actor: .model)
        let winner = MediaPreparedTrack(kind: .visual, name: "Winner")
        _ = try await coordinator.applyUserOperations([.init(action: .insertTrack(track: winner, index: nil))], to: id, expectedRevision: base)
        let rejected = MediaPreparedTrack(kind: .visual, name: "Stale")
        do {
            _ = try await coordinator.apply([.init(action: .insertTrack(track: rejected, index: nil))], instruction: earlier, expectedRevision: base)
            Issue.record("An operation admitted before a competing write overwrote the expected revision")
        } catch { #expect(error as? MediaPreparedCoreError == .documentChanged) }
        try await coordinator.stop(earlier)
        let saved = try #require(try await store.loadProject(id: id))
        #expect(saved.prepared?.trackGraph.tracks.contains(where: { $0.id == winner.id }) == true)
        #expect(saved.prepared?.trackGraph.tracks.contains(where: { $0.id == rejected.id }) == false)
        #expect(saved.revision == base + 1)
    }
    @Test func staleSessionCannotOverwriteAnotherStoreInstance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-session-cas-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Projects"), id = UUID()
        let firstStore = MediaProjectStore(directory: directory)
        try await firstStore.save(.init(id: id, kind: .video, name: "CAS", canvas: .init(width: 32, height: 32, frameRate: 4), videoTimeline: .init()))
        let session = try await MediaV2Session.open(projectID: id, root: root, store: firstStore, upgrade: true)
        let base = session.document.revision
        let competing = MediaPreparedCoordinator(store: MediaProjectStore(directory: directory))
        let winner = MediaPreparedTrack(kind: .visual, name: "Winner")
        _ = try await competing.applyUserOperations([.init(action: .insertTrack(track: winner, index: nil))], to: id, expectedRevision: base)
        let stale = MediaPreparedTrack(kind: .visual, name: "Stale")
        await #expect(throws: (any Error).self) {
            _ = try await session.apply([.init(action: .insertTrack(track: stale, index: nil))], expectedRevision: base, actor: .model)
        }
        let saved = try #require(try await firstStore.loadProject(id: id))
        #expect(saved.prepared?.trackGraph.tracks.contains(where: { $0.id == winner.id }) == true)
        #expect(saved.prepared?.trackGraph.tracks.contains(where: { $0.id == stale.id }) == false)
    }
    @Test func explicitImportPlacementIsNotChangedByConcurrentSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("media-import-placement-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4"), root = directory.appendingPathComponent("Media")
        try await movie(source)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MediaProjectStore(directory: root.appendingPathComponent("Projects")), id = UUID()
        try await store.save(.init(id: id, kind: .video, name: "Placement", canvas: .init(width: 32, height: 32, frameRate: 4), videoTimeline: .init()))
        let session = try await MediaV2Session.open(projectID: id, root: root, store: store, upgrade: true)
        let first = MediaPreparedTrack(kind: .visual, name: "First")
        let second = MediaPreparedTrack(kind: .visual, name: "Second")
        _ = try await session.coordinator.applyUserOperations([.init(action: .insertTrack(track: first, index: nil)),
            .init(action: .insertTrack(track: second, index: nil))], to: id, expectedRevision: session.document.revision)
        try await session.reload()
        let base = session.document.revision
        let imported = try await session.importAuthorizedFile(source, expectedRevision: base, actor: .model,
            validateSource: { session.selectedTrackID = second.id; session.playhead = 9 },
            identity: .init(groupID: UUID(), operationID: UUID()),
            placement: .init(trackID: first.id, startSeconds: 1))
        let saved = try #require(try await store.loadProject(id: id))
        let track = try #require(saved.prepared?.trackGraph.tracks.first(where: { $0.id == first.id }))
        let clip = try #require(track.clips.first(where: { $0.assetID == imported.asset.id }))
        #expect(abs(clip.timelineRange.start.seconds - 1) < 0.0001)
        #expect(saved.prepared?.trackGraph.tracks.first(where: { $0.id == second.id })?.clips.isEmpty == true)
    }
    @Test func workspaceVideoUsesBoundOriginalAndPreservesSource() async throws {
        try await withContexts { initial, other in
            let environment = FloeAgentApp.liveEnvironment
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-video-authority-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let authority = try StudioDocumentAccess(root: scratch)
            let coordinator = StudioCoordinator(environment: environment, authority: authority)
            #expect(ToolRunnerRegistry.shared.runner(named: "studio.workspaceVideo") != nil)
            #expect(ToolRunnerRegistry.shared.runner(named: "studio.workspaceVideoRead") != nil)
            let registry = ToolRunnerRegistry()
            registry.register(StudioWorkspaceVideoCreateTool(coordinator: coordinator))
            registry.register(StudioWorkspaceVideoReadTool(coordinator: coordinator))
            let writer = try #require(registry.runner(named: "studio.workspaceVideo"))
            let reader = try #require(registry.runner(named: "studio.workspaceVideoRead"))
            let workspaceStore = SQLiteWorkspaceStore(database: environment.database)
            let conversationID = try #require(initial.conversationID), otherConversationID = try #require(other.conversationID)
            let workspaceID = try #require(try await workspaceStore.workspaceID(conversationID: conversationID))
            let otherWorkspaceID = try #require(try await workspaceStore.workspaceID(conversationID: otherConversationID))
            let names: Set<String> = ["studio.workspaceVideo", "studio.workspaceVideoRead"]
            func prepared(_ original: ToolContext, workspace: UUID) throws -> ToolContext {
                var value = original
                value.allowedToolNames = names; value.frozenEffectiveCatalogNames = names
                value.executionToolName = "studio.workspaceVideo"
                value.serviceStorePaths[TypedMutationContract.workspaceStudioStoreKey] = try #require(value.workspaceRootURL)
                    .appendingPathComponent("Floe Studio " + String(workspace.uuidString.prefix(8))).path
                return value
            }
            var context = try prepared(initial, workspace: workspaceID)
            let workspaceRoot = try #require(context.workspaceRootURL).standardizedFileURL.resolvingSymlinksInPath()
            let source = workspaceRoot.appendingPathComponent("source.mp4")
            try await movie(source)
            let sourceBytes = try Data(contentsOf: source)
            // Resume the exact host-journaled staging inode after an
            // interruption before the root directory was published.
            func directoryIdentity(_ url: URL) throws -> String {
                let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw PersonalContentError.changedDocument }
                defer { close(fd) }
                var value = stat()
                guard fstat(fd, &value) == 0 else { throw PersonalContentError.changedDocument }
                return "\(value.st_dev):\(value.st_ino)"
            }
            let stagingName = ".floe-studio-" + UUID().uuidString
            let staging = workspaceRoot.appendingPathComponent(stagingName, isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            let intent = StudioWorkspaceVideoRootIntent(workspaceID: workspaceID,
                relativePath: "Floe Studio " + String(workspaceID.uuidString.prefix(8)),
                rootIdentity: try directoryIdentity(workspaceRoot), stagingName: stagingName,
                containerIdentity: try directoryIdentity(staging))
            try await authority.reserveWorkspaceVideoRoot(intent)
            let created = try await writer.execute(argumentsJSON: JSONSerialization.data(withJSONObject: ["action": "create", "title": "Workspace video"]), context: context)
            #expect(try await authority.workspaceVideoRootIntent(workspaceID: workspaceID) == nil)
            #expect(try directoryIdentity(workspaceRoot.appendingPathComponent(intent.relativePath)) == intent.containerIdentity)
            let createdJSON = try #require(JSONSerialization.jsonObject(with: Data(created.summary.utf8)) as? [String: Any])
            let id = try #require((createdJSON["projectID"] as? String).flatMap(UUID.init(uuidString:)))
            let retry = try await writer.execute(argumentsJSON: JSONSerialization.data(withJSONObject: ["action": "create", "title": "Workspace video"]), context: context)
            let retryJSON = try #require(JSONSerialization.jsonObject(with: Data(retry.summary.utf8)) as? [String: Any])
            #expect(retryJSON["projectID"] as? String == id.uuidString)
            #expect(retryJSON["replayed"] as? Bool == true)
            let binding = try #require(try await authority.workspaceVideoBinding(conversationID: conversationID, workspaceID: workspaceID, projectID: id))
            let directory = try #require(context.workspaceRootURL).appendingPathComponent(binding.relativePath)
#if DEBUG
            // Replace the selected staging pathname after its descriptor was
            // opened: initial package writes must never follow the symlink.
            do {
                var raced = context
                raced.toolCallID = "stage-symlink-replacement"
                let racedTitle = "Stage replacement"
                let key = raced.runID.uuidString + "/" + raced.toolCallID!
                let digest = StudioToolOutput.hash(try StudioToolOutput.data([workspaceID.uuidString, conversationID.uuidString, racedTitle]))
                let racedID = try await authority.reserveCreation(operationKey: key, digest: digest)
                let victim = workspaceRoot.appendingPathComponent("untouched-victim", isDirectory: true)
                let parked = workspaceRoot.appendingPathComponent("parked-stage", isDirectory: true)
                try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: false)
                StudioWorkspaceVideoService.afterProjectStageOpenForTesting = { stage in
                    try FileManager.default.moveItem(at: stage, to: parked)
                    try FileManager.default.createSymbolicLink(at: stage, withDestinationURL: victim)
                }
                defer { StudioWorkspaceVideoService.afterProjectStageOpenForTesting = nil }
                await #expect(throws: (any Error).self) {
                    _ = try await writer.execute(argumentsJSON: JSONSerialization.data(withJSONObject: ["action": "create", "title": racedTitle]), context: raced)
                }
                #expect(try FileManager.default.contentsOfDirectory(atPath: victim.path).isEmpty)
                #expect(try await authority.workspaceVideoBinding(conversationID: conversationID, workspaceID: workspaceID, projectID: racedID) == nil)
                #expect(try await authority.workspaceVideoProjectIntent(projectID: racedID) == nil)
            }
#endif
            // A crash after publication must not let a same-manifest replacement
            // acquire the original host-issued project authorization on retry.
            var interrupted = context
            interrupted.toolCallID = "interrupted-project-replacement"
            let operationKey = interrupted.runID.uuidString + "/" + interrupted.toolCallID!
            let replacementTitle = "Interrupted video"
            let digest = StudioToolOutput.hash(try StudioToolOutput.data([workspaceID.uuidString, conversationID.uuidString, replacementTitle]))
            let pendingID = try await authority.reserveCreation(operationKey: operationKey, digest: digest)
            let container = workspaceRoot.appendingPathComponent(intent.relativePath, isDirectory: true)
            let finalName = replacementTitle + " " + String(pendingID.uuidString.prefix(8)) + ".floeproject"
            let published = container.appendingPathComponent(finalName, isDirectory: true)
            try FileManager.default.copyItem(at: directory, to: published)
            let pendingRecord = PersonalContentRecord(id: pendingID, kind: .video, title: replacementTitle,
                createdAt: Date(), modifiedAt: Date(), folders: [], relativePath: finalName)
            try JSONEncoder().encode(pendingRecord).write(to: published.appendingPathComponent("FloeProject.json"))
            let pending = StudioWorkspaceVideoProjectIntent(projectID: pendingID, conversationID: conversationID,
                workspaceID: workspaceID, operationKey: operationKey, digest: digest, rootIdentity: intent.rootIdentity,
                containerIdentity: intent.containerIdentity, stagingName: ".floe-project-" + UUID().uuidString,
                finalName: finalName, projectIdentity: try directoryIdentity(published),
                mediaIdentity: try directoryIdentity(published.appendingPathComponent("Media")),
                storeIdentity: try directoryIdentity(published.appendingPathComponent("Media/Projects")))
            try await authority.reserveWorkspaceVideoProject(pending)
            let original = workspaceRoot.appendingPathComponent("preserved-published-project", isDirectory: true)
            try FileManager.default.moveItem(at: published, to: original)
            try FileManager.default.copyItem(at: original, to: published)
            await #expect(throws: (any Error).self) {
                _ = try await writer.execute(argumentsJSON: JSONSerialization.data(withJSONObject: ["action": "create", "title": replacementTitle]), context: interrupted)
            }
            #expect(try await authority.workspaceVideoBinding(conversationID: conversationID, workspaceID: workspaceID, projectID: pendingID) == nil)
            #expect(try await authority.workspaceVideoProjectIntent(projectID: pendingID) == pending)
            #expect(try directoryIdentity(original) == pending.projectIdentity)
            let record = try await PersonalContentLibrary(root: directory.deletingLastPathComponent()).resolve(id).record
            let session = try await StudioWorkspaceVideoService.sessionForNativeUI(record: record, directory: directory,
                workspaceID: workspaceID, workspaceRoot: workspaceRoot, environment: environment, authority: authority)
            let track = try #require(session.document.trackGraph.tracks.first(where: { $0.kind == .visual }))
            context.toolCallID = "import-workspace-video"
            let input = try encode(["expectedRevision": session.document.revision,
                "source": ["workspacePath": "source.mp4"], "trackID": track.id.uuidString, "startSeconds": 1])
            _ = try await writer.execute(argumentsJSON: JSONSerialization.data(withJSONObject: ["action": "import", "projectID": id.uuidString, "inputJSON": input]), context: context)
            #expect(try Data(contentsOf: source) == sourceBytes)
            let reopened = try #require(try await MediaProjectStore(directory: directory.appendingPathComponent("Media/Projects")).loadProject(id: id))
            #expect(reopened.prepared?.trackGraph.tracks.first(where: { $0.id == track.id })?.clips.count == 1)
            try await session.reload()
            var caption = MediaV2ToolInput()
            caption.expectedRevision = session.document.revision
            caption.text = "Workspace export"
            caption.start = 1
            caption.duration = 2
            _ = try await session.performTool("video.caption", input: caption)
            let subtitles = try await session.exportCaptions(.vtt)
            let project = try await session.exportInterchange(.original)
            let exportRoot = workspaceRoot.appendingPathComponent("Exports").resolvingSymlinksInPath().path
            #expect(subtitles.deletingLastPathComponent().resolvingSymlinksInPath().path == exportRoot)
            #expect(project.deletingLastPathComponent().resolvingSymlinksInPath().path == exportRoot)
            #expect(try MediaV2SubtitleCodec.parse(String(contentsOf: subtitles, encoding: .utf8)).map(\.text) == ["Workspace export"])
            #expect(try Data(contentsOf: project, options: .mappedIfSafe).prefix(2) == Data([0x50, 0x4B]))
            let savedWithCaption = try #require(try await session.store.loadProject(id: id))
            #expect(savedWithCaption.prepared?.trackGraph.tracks.flatMap(\.clips).contains(where: { $0.captionText == "Workspace export" }) == true)
            var stranger = try prepared(other, workspace: otherWorkspaceID)
            stranger.executionToolName = "studio.workspaceVideoRead"
            await #expect(throws: (any Error).self) {
                _ = try await reader.execute(argumentsJSON: JSONSerialization.data(withJSONObject: ["projectID": id.uuidString]), context: stranger)
            }
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
