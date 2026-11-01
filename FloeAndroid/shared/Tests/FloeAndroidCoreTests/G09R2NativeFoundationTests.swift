// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 native foundation tests (job-b72b2978320e484e).
//
// Focused, network-free regression coverage for the additive foundation:
// typed video CAS/undo/idempotent replay, immutable snapshot leases, bounded
// render-ticket claim/settlement/root drain, streamed large-import truth and
// the BridgeV6 closed vocabulary. These run against temporary explicit roots
// and in-memory stores; no device, provider or paid call is involved.
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloePersistence
import FloeAndroidWorkbench

final class G09R2NativeFoundationTests: XCTestCase {
    private var roots: [URL] = []
    private var database: DatabaseManager?
    private static let epochLock = NSLock()
    nonisolated(unsafe) private static var epochCounter: UInt64 = 5_000

    override func tearDown() async throws {
        if let database { try? await database.close() }
        database = nil
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        try await super.tearDown()
    }

    private static func nextEpoch() -> UInt64 {
        epochLock.lock(); defer { epochLock.unlock() }
        epochCounter += 1
        return epochCounter
    }

    private struct Fixture {
        let service: G09CreativeDomainService
        let cluster: G09R2BoundCluster
        let epoch: UInt64
    }

    private func makeFixture() async throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-r2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        database = manager
        let workspaceStore = SQLiteWorkspaceStore(database: manager)
        let conversationStore = SQLiteConversationStore(database: manager)
        let root = try XCTUnwrap(RuntimeStorageRoot(validatingAbsoluteDirectory: url.path))
        let service = G09CreativeDomainService()
        let epoch = Self.nextEpoch()
        let context = G09CreativeStorageContext(
            root: root, database: manager, workspaceStore: workspaceStore,
            conversationStore: conversationStore)
        _ = try await service.bind(epoch: epoch, storage: context)
        let bound = await service.r2BoundCluster()
        let cluster = try XCTUnwrap(bound)
        return Fixture(service: service, cluster: cluster, epoch: epoch)
    }

    private func context(_ projectID: UUID, token: String,
                         storage: G09StorageLayerDTO = .init(kind: .appOwned),
                         origin: G09CreativeOriginDTO? = nil)
        -> G09R2ProjectContextDTO {
        G09R2ProjectContextDTO(
            projectID: projectID, sessionToken: token,
            storage: storage, origin: origin)
    }

    // MARK: - Video CAS / undo / replay

    func testVideoApplyIsOneDurableCASWithUndoAndIdempotentReplay() async throws {
        let fixture = try await makeFixture()
        let created = try await fixture.cluster.media.create(
            name: "R2 Timeline", kind: .video, width: 640, height: 360,
            frameRate: 30, storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        let projectID = created.project.id
        let token = "session-r2-video"
        let load = try await G09R2MediaFoundation.shared.loadVideo(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2VideoLoadRequest(
                context: context(projectID, token: token)))
        XCTAssertEqual(load.envelope.project.revision, 0)
        XCTAssertTrue(load.envelope.writable)
        XCTAssertEqual(load.envelope.mediaRootPath, created.storage.rootURL.path)

        let request = G09R2VideoApplyRequest(
            context: context(projectID, token: token),
            expectedRevision: 0, opID: "video-apply-1",
            commands: [.setCanvas(width: 1280, height: 720, frameRate: 30)])
        let receipt = try await G09R2MediaFoundation.shared.applyVideo(
            service: fixture.service, epoch: fixture.epoch, request: request)
        XCTAssertEqual(receipt.revision, 1)
        XCTAssertFalse(receipt.idempotent)
        XCTAssertTrue(receipt.canUndo)

        // Same opID + same CAS input: replay, never a second mutation.
        let replay = try await G09R2MediaFoundation.shared.applyVideo(
            service: fixture.service, epoch: fixture.epoch, request: request)
        XCTAssertTrue(replay.idempotent)
        XCTAssertEqual(replay.revision, 1)

        let reloaded = try await fixture.cluster.media.load(
            id: projectID, requested: G09StorageLayerDTO(kind: .appOwned))
        XCTAssertEqual(reloaded.project.revision, 1)
        XCTAssertEqual(reloaded.project.canvas?.width, 1280)

        // Stale revision is refused; the durable document is untouched.
        do {
            _ = try await G09R2MediaFoundation.shared.applyVideo(
                service: fixture.service, epoch: fixture.epoch,
                request: G09R2VideoApplyRequest(
                    context: context(projectID, token: token),
                    expectedRevision: 0, opID: "video-apply-stale",
                    commands: [.setCover(time: 1.5)]))
            XCTFail("stale revision must be refused")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.code, "revisionConflict")
        }

        let undo = try await fixture.cluster.media.undo(G09MediaUndoRedoRequest(
            projectID: projectID, expectedRevision: 1, sessionToken: token,
            storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone), opID: "video-undo-1"))
        XCTAssertEqual(undo.project.revision, 2)
        XCTAssertEqual(undo.project.canvas?.width, 640)

        // A foreign session cannot write even with the right project/revision.
        do {
            _ = try await G09R2MediaFoundation.shared.applyVideo(
                service: fixture.service, epoch: fixture.epoch,
                request: G09R2VideoApplyRequest(
                    context: context(projectID, token: "session-foreign"),
                    expectedRevision: 2, opID: "video-apply-foreign",
                    commands: [.setCanvas(width: 800, height: 600, frameRate: 30)]))
            XCTFail("stale/foreign session must be refused")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.code, "staleSession")
        }
    }

    // MARK: - Snapshot lease

    func testSnapshotIsImmutableAndReleasePreservesProjectAndAssets() async throws {
        let fixture = try await makeFixture()
        let created = try await fixture.cluster.media.create(
            name: "Snapshot", kind: .video, width: 320, height: 240,
            frameRate: 30, storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        let projectID = created.project.id
        let token = "session-r2-snapshot"
        let loaded = try await G09R2MediaFoundation.shared.loadVideo(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2VideoLoadRequest(
                context: context(projectID, token: token)))

        let lease = try await G09R2MediaFoundation.shared.acquireSnapshot(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2RenderSnapshotRequestDTO(
                context: context(projectID, token: token),
                expectedRevision: 0,
                expectedTimelineDigest: loaded.timelineDigest))
        let snapshotURL = URL(fileURLWithPath: lease.mediaRootPath, isDirectory: true)
            .appendingPathComponent(lease.relativePath)
        let firstBytes = try Data(contentsOf: snapshotURL)
        XCTAssertEqual(Int64(firstBytes.count), lease.byteCount)
        XCTAssertEqual(FloeDigest.sha256Hex(firstBytes), lease.sha256)

        // Mutate the live project after acquisition: the captured lease must
        // still describe the exact old revision, not the latest document.
        _ = try await G09R2MediaFoundation.shared.applyVideo(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2VideoApplyRequest(
                context: context(projectID, token: token),
                expectedRevision: 0, opID: "snapshot-mutate-1",
                commands: [.setCanvas(width: 640, height: 480, frameRate: 30)]))
        XCTAssertEqual(try Data(contentsOf: snapshotURL), firstBytes)

        // Cross-owner acquire is refused (different session token).
        do {
            _ = try await G09R2MediaFoundation.shared.acquireSnapshot(
                service: fixture.service, epoch: fixture.epoch,
                request: G09R2RenderSnapshotRequestDTO(
                    context: context(projectID, token: "session-other"),
                    expectedRevision: 1,
                    expectedTimelineDigest: loaded.timelineDigest))
            XCTFail("a foreign session must not acquire a snapshot")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.code, "staleSession")
        }

        // A lease cannot be replayed against another project/revision/hash.
        do {
            _ = try G09R2SnapshotLeases.shared.verify(
                lease, epoch: fixture.epoch,
                projectID: projectID, revision: 99,
                timelineDigest: loaded.timelineDigest,
                storage: G09StorageLayerDTO(kind: .appOwned),
                sessionToken: token)
            XCTFail("cross-revision lease must be refused")
        } catch let error as G09R2Error {
            XCTAssertEqual(error.code, "renderTicketNotFound")
        }

        _ = try await G09R2MediaFoundation.shared.releaseSnapshot(
            service: fixture.service, epoch: fixture.epoch, lease: lease)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
        let projectFile = URL(fileURLWithPath: fixture.cluster.media.projectDirectoryPath,
                              isDirectory: true)
            .appendingPathComponent(MediaProjectStore.projectFileName(id: projectID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectFile.path),
                      "release must never delete the project document")
    }

    // MARK: - Render ticket mailbox

    func testRenderTicketClaimSettlementAndRootDrain() async throws {
        let fixture = try await makeFixture()
        let mailbox = G09R2MediaRenderHostMailbox.shared
        XCTAssertTrue(mailbox.bind(epoch: fixture.epoch))
        defer { _ = mailbox.prepareRootStop(epoch: fixture.epoch) }

        let created = try await fixture.cluster.media.create(
            name: "Render", kind: .video, width: 320, height: 240,
            frameRate: 30, storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        let projectID = created.project.id
        let token = "session-r2-render"
        let loaded = try await G09R2MediaFoundation.shared.loadVideo(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2VideoLoadRequest(
                context: context(projectID, token: token)))
        let lease = try await G09R2MediaFoundation.shared.acquireSnapshot(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2RenderSnapshotRequestDTO(
                context: context(projectID, token: token),
                expectedRevision: 0,
                expectedTimelineDigest: loaded.timelineDigest))
        let attemptID = "attempt-\(UUID().uuidString.lowercased())"
        let descriptor = try await G09R2MediaFoundation.shared.submitRenderTicket(
            service: fixture.service, epoch: fixture.epoch,
            context: context(projectID, token: token),
            projectRevision: 0, timelineDigest: loaded.timelineDigest,
            attemptID: attemptID, kind: .video, lease: lease,
            videoSettings: G09R2VideoExportSettingsDTO(
                codecMime: "video/avc", width: 320, height: 240,
                frameRate: 30, quality: 0.8, fileName: "out.mp4"))
        XCTAssertLessThanOrEqual(descriptor.descriptorByteCount, 65_536)
        XCTAssertEqual(descriptor.outputRelativePath,
                       "Workbench/Exports/\(attemptID).mp4")

        // Buffer-too-small is refused, never truncated.
        var small = [CChar](repeating: 0, count: 8)
        let smallStatus = descriptor.ticketID.withCString { ticket in
            floeMediaRenderDescribe(ticket, &small, Int32(small.count))
        }
        XCTAssertEqual(smallStatus, G09R2MediaRenderHostMailbox.bufferTooSmall)

        let claimed = try XCTUnwrap(mailbox.claim(timeoutMillis: 1_000))
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: claimed) as? [String: Any])
        let claimToken = try XCTUnwrap(envelope["claimToken"] as? String)
        let claimedDescriptor = try XCTUnwrap(envelope["descriptor"] as? [String: Any])
        XCTAssertEqual(claimedDescriptor["ticketID"] as? String, descriptor.ticketID)
        XCTAssertTrue(mailbox.shouldStop(ticketID: descriptor.ticketID,
                                         claimToken: "wrong-token"))
        XCTAssertTrue(mailbox.heartbeat(ticketID: descriptor.ticketID,
                                        claimToken: claimToken))

        // The platform writes the real output; the native side verifies it.
        let outputURL = URL(fileURLWithPath: descriptor.mediaRootPath,
                            isDirectory: true)
            .appendingPathComponent(descriptor.outputRelativePath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let outputBytes = Data(repeating: 0x42, count: 4_096)
        try outputBytes.write(to: outputURL)
        let receipt = G09R2MediaExportReceiptDTO(
            binding: G09R2MediaExportReceiptBindingDTO(
                projectID: projectID, mediaRootPath: descriptor.mediaRootPath,
                projectRevision: 0, timelineDigest: loaded.timelineDigest,
                attemptID: attemptID),
            kind: .video, outputRelativePath: descriptor.outputRelativePath,
            mimeType: "video/mp4", byteCount: Int64(outputBytes.count),
            sha256: FloeDigest.sha256Hex(outputBytes),
            verification: G09R2ExportVerificationDTO(
                playable: true, decodedDurationSeconds: 1.0,
                width: 320, height: 240, audioTrackCount: 0,
                container: "mp4", codec: "avc1"),
            completedAt: Date())
        let replyData = try Self.encodeReply(
            ticketID: descriptor.ticketID, status: .completed, receipt: receipt)
        XCTAssertEqual(mailbox.complete(ticketID: descriptor.ticketID,
                                        claimToken: claimToken,
                                        replyData: replyData), 0)
        // Duplicate settlement with the same token is refused.
        XCTAssertEqual(mailbox.complete(ticketID: descriptor.ticketID,
                                        claimToken: claimToken,
                                        replyData: replyData),
                       G09R2MediaRenderHostMailbox.claimMismatch)
        let settled = try await mailbox.awaitReply(
            ticketID: descriptor.ticketID, timeoutMillis: 100)
        XCTAssertEqual(settled?.status, .completed)
        XCTAssertEqual(settled?.receipt?.sha256, receipt.sha256)
        XCTAssertEqual(mailbox.stats().completed, 1)

        // Root stop with an owned claim is pending until the host acks.
        let second = try await G09R2MediaFoundation.shared.submitRenderTicket(
            service: fixture.service, epoch: fixture.epoch,
            context: context(projectID, token: token),
            projectRevision: 0, timelineDigest: loaded.timelineDigest,
            attemptID: "attempt-\(UUID().uuidString.lowercased())",
            kind: .video, lease: lease,
            videoSettings: G09R2VideoExportSettingsDTO(
                codecMime: "video/avc", width: 320, height: 240,
                frameRate: 30, quality: 0.8, fileName: "out.mp4"))
        let secondClaim = try XCTUnwrap(mailbox.claim(timeoutMillis: 1_000))
        let secondEnvelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: secondClaim) as? [String: Any])
        let secondToken = try XCTUnwrap(secondEnvelope["claimToken"] as? String)
        XCTAssertFalse(mailbox.canBind(epoch: fixture.epoch + 100),
                       "a live claim must block a newer generation bind")
        XCTAssertFalse(mailbox.prepareRootStop(epoch: fixture.epoch),
                       "a claimed ticket must keep the generation draining")
        XCTAssertEqual(mailbox.drainStatus(epoch: fixture.epoch).claimed, 1)
        XCTAssertEqual(mailbox.close(ticketID: second.ticketID,
                                     claimToken: secondToken), 0)
        XCTAssertTrue(mailbox.prepareRootStop(epoch: fixture.epoch))
        XCTAssertEqual(mailbox.drainStatus(epoch: fixture.epoch).claimed, 0)
    }

    func testRenderTicketRejectsUnverifiedOutput() async throws {
        let fixture = try await makeFixture()
        let mailbox = G09R2MediaRenderHostMailbox.shared
        XCTAssertTrue(mailbox.bind(epoch: fixture.epoch))
        defer { _ = mailbox.prepareRootStop(epoch: fixture.epoch) }

        let created = try await fixture.cluster.media.create(
            name: "Render2", kind: .image, width: 200, height: 200,
            frameRate: nil, storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        let projectID = created.project.id
        let token = "session-r2-render2"
        let loaded = try await G09R2MediaFoundation.shared.loadVideo(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2VideoLoadRequest(
                context: context(projectID, token: token)))
        let lease = try await G09R2MediaFoundation.shared.acquireSnapshot(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2RenderSnapshotRequestDTO(
                context: context(projectID, token: token),
                expectedRevision: 0,
                expectedTimelineDigest: loaded.timelineDigest))
        let descriptor = try await G09R2MediaFoundation.shared.submitRenderTicket(
            service: fixture.service, epoch: fixture.epoch,
            context: context(projectID, token: token),
            projectRevision: 0, timelineDigest: loaded.timelineDigest,
            attemptID: "attempt-\(UUID().uuidString.lowercased())",
            kind: .preview, lease: lease)
        let claimed = try XCTUnwrap(mailbox.claim(timeoutMillis: 1_000))
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: claimed) as? [String: Any])
        let claimToken = try XCTUnwrap(envelope["claimToken"] as? String)
        // A fabricated receipt (no bytes on disk) must be refused; the claim
        // stays owned so the host can settle a truthful failure.
        let fake = G09R2MediaExportReceiptDTO(
            binding: G09R2MediaExportReceiptBindingDTO(
                projectID: projectID, mediaRootPath: descriptor.mediaRootPath,
                projectRevision: 0, timelineDigest: loaded.timelineDigest,
                attemptID: descriptor.attemptID),
            kind: .preview, outputRelativePath: descriptor.outputRelativePath,
            mimeType: "image/png", byteCount: 4_096,
            sha256: String(repeating: "a", count: 64),
            verification: G09R2ExportVerificationDTO(
                playable: true, decodedDurationSeconds: nil,
                width: 200, height: 200, audioTrackCount: 0,
                container: "png", codec: "png"),
            completedAt: Date())
        let replyData = try Self.encodeReply(
            ticketID: descriptor.ticketID, status: .completed, receipt: fake)
        XCTAssertEqual(mailbox.complete(ticketID: descriptor.ticketID,
                                        claimToken: claimToken,
                                        replyData: replyData),
                       G09R2MediaRenderHostMailbox.outputUnverified)
        XCTAssertTrue(mailbox.isLive(ticketID: descriptor.ticketID))
        XCTAssertEqual(mailbox.close(ticketID: descriptor.ticketID,
                                     claimToken: claimToken), 0)
    }

    // MARK: - Large import

    func testLargeImportPolicyAndCaps() {
        XCTAssertTrue(G09R2LargeImportPolicy.accepts(.image, byteCount: 128 << 20))
        XCTAssertFalse(G09R2LargeImportPolicy.accepts(.image, byteCount: (128 << 20) + 1))
        XCTAssertTrue(G09R2LargeImportPolicy.accepts(.video, byteCount: 1 << 30))
        XCTAssertFalse(G09R2LargeImportPolicy.accepts(.video, byteCount: 0))
        XCTAssertEqual(G09R2LargeImportPolicy.requiredFreeBytes(sourceBytes: 1 << 20),
                       (1 << 21) + (512 << 20))
        XCTAssertEqual(G09R2LargeImportPolicy.requiredFreeBytes(sourceBytes: .max),
                       .max)
        XCTAssertEqual(G09CreativeLimits.assetBytes, 64 << 20,
                       "the generic Canvas/R1 asset ceiling stays unchanged")
    }

    func testLargeImportCreatesOneProjectAndRecoversFromPostCommitFault()
        async throws {
        let fixture = try await makeFixture()
        let token = "session-r2-import"
        let opID = "import-op-\(UUID().uuidString.lowercased())"
        let bytes = Data("floe-r2-import-image".utf8)
        let stagingDirectory = URL(
            fileURLWithPath: fixture.cluster.assets.incomingDirectoryPath,
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingDirectory, withIntermediateDirectories: true)
        let stagingToken = "\(token).\(UUID().uuidString.lowercased())"
        let stagingURL = stagingDirectory.appendingPathComponent(stagingToken)
        try bytes.write(to: stagingURL)
        let metadata = G09R2LargeImportMetadata(
            token: stagingToken, kind: .image,
            fileName: "poster.png", mimeType: "image/png",
            byteCount: Int64(bytes.count),
            sha256: FloeDigest.sha256Hex(bytes),
            mediaMetadata: MediaAssetMetadata(width: 800, height: 600))
        let request = G09R2LargeImportRequest.newProject(
            storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone),
            name: "Imported", kind: .image, sessionToken: token,
            opID: opID, metadata: metadata, preparedIntentToken: nil)

        struct Crash: Error {}
        await fixture.cluster.media.setFaultAfterCommit { throw Crash() }
        let handle = try await G09R2LargeImportService.shared.submit(
            service: fixture.service, epoch: fixture.epoch, request: request)
        let first = try await G09R2LargeImportService.shared.waitForCompletion(
            jobID: handle.jobID, timeoutMillis: 10_000)
        XCTAssertNotNil(first)
        XCTAssertNotEqual(first?.state, .completed)
        XCTAssertNil(first?.createdProjectID)
        await fixture.cluster.media.setFaultAfterCommit(nil)

        // The same stable opID replays the committed intent instead of
        // creating a second project.
        let retry = try await G09R2LargeImportService.shared.submit(
            service: fixture.service, epoch: fixture.epoch, request: request)
        let retryStatus = await G09R2LargeImportService.shared.waitForCompletion(
            jobID: retry.jobID, timeoutMillis: 15_000)
        let completed = try XCTUnwrap(retryStatus)
        XCTAssertEqual(completed.state, .completed)
        let createdProjectID = try XCTUnwrap(completed.createdProjectID)
        XCTAssertEqual(createdProjectID,
                       G09SourceCreateIdentity.projectID(domain: "media", opID: opID))
        let loaded = try await fixture.cluster.media.load(
            id: createdProjectID, requested: G09StorageLayerDTO(kind: .appOwned))
        XCTAssertEqual(loaded.project.assets.count, 1)
        XCTAssertEqual(loaded.project.imageLayers.count, 1)
        XCTAssertEqual(loaded.project.revision, 2)

        let library = try await fixture.cluster.media.library()
        XCTAssertEqual(library.filter { $0.id == createdProjectID }.count, 1)
    }

    func testLargeImportDigestFailurePublishesNoProject() async throws {
        let fixture = try await makeFixture()
        let token = "session-r2-bad-import"
        let bytes = Data("not-the-declared-digest".utf8)
        let stagingDirectory = URL(
            fileURLWithPath: fixture.cluster.assets.incomingDirectoryPath,
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingDirectory, withIntermediateDirectories: true)
        let stagingToken = "\(token).\(UUID().uuidString.lowercased())"
        let stagingURL = stagingDirectory.appendingPathComponent(stagingToken)
        try bytes.write(to: stagingURL)
        let metadata = G09R2LargeImportMetadata(
            token: stagingToken, kind: .image,
            fileName: "bad.png", mimeType: "image/png",
            byteCount: Int64(bytes.count),
            sha256: String(repeating: "0", count: 64),
            mediaMetadata: MediaAssetMetadata(width: 100, height: 100))
        let before = try await fixture.cluster.media.library().count
        let handle = try await G09R2LargeImportService.shared.submit(
            service: fixture.service, epoch: fixture.epoch,
            request: .newProject(
                storage: G09StorageLayerDTO(kind: .appOwned),
                origin: G09CreativeOriginDTO(kind: .standalone),
                name: "Bad", kind: .image, sessionToken: token,
                opID: "bad-import-\(UUID().uuidString.lowercased())",
                metadata: metadata, preparedIntentToken: nil))
        let finished = await G09R2LargeImportService.shared.waitForCompletion(
            jobID: handle.jobID, timeoutMillis: 10_000)
        let status = try XCTUnwrap(finished)
        XCTAssertEqual(status.state, .failed)
        XCTAssertNil(status.createdProjectID)
        let after = try await fixture.cluster.media.library().count
        XCTAssertEqual(after, before, "a failed import publishes no empty project")
    }

    // MARK: - BridgeV6

    func testBridgeV6HandshakeAndEnabledCapabilities() async throws {
        let fixture = try await makeFixture()
        let handshakeData = try JSONSerialization.data(withJSONObject: [
            "version": 6, "operation": "handshake", "requestID": "h1",
        ])
        let handshake = BridgeV6Handler.handle(
            requestData: handshakeData, fallbackRequestID: "h1")
        XCTAssertEqual(handshake["ok"] as? Bool, true)
        XCTAssertEqual(handshake["schema"] as? String, "floe.creative/6")
        let actions = try XCTUnwrap(handshake["actions"] as? [String])
        XCTAssertTrue(actions.contains("media.video.load"))
        XCTAssertTrue(actions.contains("design.owner.preview"))
        let available = try XCTUnwrap(handshake["availableActions"] as? [String])
        XCTAssertEqual(Set(available), Set(BridgeV6.actions))
        XCTAssertEqual(available.count, BridgeV6.actions.count)
        let largeImport = try XCTUnwrap(
            handshake["largeImport"] as? [String: Any])
        XCTAssertEqual(largeImport["available"] as? Bool, true)
        let unavailable = try XCTUnwrap(
            handshake["unavailableActions"] as? [String: String])
        XCTAssertTrue(unavailable.isEmpty)

        let created = try await fixture.cluster.media.create(
            name: "Bridge", kind: .image, width: 100, height: 100,
            frameRate: nil, storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        let projectID = created.project.id
        let token = "session-r2-bridge"
        _ = try await G09R2MediaFoundation.shared.loadVideo(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2VideoLoadRequest(
                context: context(projectID, token: token)))

        let generation = try JSONSerialization.data(withJSONObject: [
            "version": 6, "operation": "command", "requestID": "g1",
            "epoch": fixture.epoch, "action": "generation.image.submit",
            "payload": [:],
        ])
        let refused = BridgeV6Handler.handle(
            requestData: generation, fallbackRequestID: "g1",
            service: fixture.service)
        XCTAssertEqual(refused["ok"] as? Bool, false)
        // Generation is installed; an empty payload is a typed payload error,
        // never the old "module not installed" refusal or a fake success.
        XCTAssertEqual(refused["error"] as? String, "invalidPayload")

        let load = try JSONSerialization.data(withJSONObject: [
            "version": 6, "operation": "command", "requestID": "l1",
            "epoch": fixture.epoch, "action": "media.video.load",
            "payload": ["context": [
                "projectID": projectID.uuidString,
                "sessionToken": token,
                "storage": ["kind": "appOwned"],
            ]],
        ])
        let loaded = BridgeV6Handler.handle(
            requestData: load, fallbackRequestID: "l1",
            service: fixture.service)
        XCTAssertEqual(loaded["ok"] as? Bool, true)
        XCTAssertNotNil(loaded["timelineDigest"] as? String)
        XCTAssertEqual((loaded["projectRevision"] as? NSNumber)?.int64Value, 0)
    }


    // MARK: - Contract-freeze V2 large-import wire

    private func stageFile(_ fixture: Fixture, token: String,
                           bytes: Data) throws -> String {
        let directory = URL(
            fileURLWithPath: fixture.cluster.assets.incomingDirectoryPath,
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let stagingToken = "\(token).\(UUID().uuidString.lowercased())"
        try bytes.write(to: directory.appendingPathComponent(stagingToken))
        return stagingToken
    }

    private func newProjectPayload(
        token: String, opID: String, metadata: G09R2LargeImportMetadata
    ) -> [String: Any] {
        var metadataObject: [String: Any] = [
            "token": metadata.token, "kind": metadata.kind.rawValue,
            "fileName": metadata.fileName, "byteCount": metadata.byteCount,
            "sha256": metadata.sha256,
        ]
        if let mime = metadata.mimeType { metadataObject["mimeType"] = mime }
        if let media = metadata.mediaMetadata {
            metadataObject["mediaMetadata"] = [
                "width": media.width ?? 0, "height": media.height ?? 0,
                "durationSeconds": media.durationSeconds ?? 0,
            ]
        }
        return [
            "opID": opID,
            "storage": ["kind": "appOwned"],
            "origin": ["kind": "standalone"],
            "name": "Wire Import",
            "kind": metadata.kind.rawValue,
            "sessionToken": token,
            "metadata": metadataObject,
        ]
    }

    func testBridgeV6LargeImportSubmitStatusAndCancelAreReal() async throws {
        let fixture = try await makeFixture()
        let token = "session-large-wire"
        let opID = "wire-import-\(UUID().uuidString.lowercased())"
        let bytes = Data("floe-r2-wire-large-import".utf8)
        let staged = try stageFile(fixture, token: token, bytes: bytes)
        let metadata = G09R2LargeImportMetadata(
            token: staged, kind: .image, fileName: "wire.png",
            mimeType: "image/png", byteCount: Int64(bytes.count),
            sha256: FloeDigest.sha256Hex(bytes),
            mediaMetadata: MediaAssetMetadata(width: 32, height: 32))
        let submit = try JSONSerialization.data(withJSONObject: [
            "version": 6, "operation": "command", "requestID": "li-submit",
            "epoch": fixture.epoch, "action": "media.largeImport.submit",
            "payload": newProjectPayload(token: token, opID: opID,
                                         metadata: metadata),
        ])
        let handle = BridgeV6Handler.handle(
            requestData: submit, fallbackRequestID: "li-submit",
            service: fixture.service)
        XCTAssertEqual(handle["ok"] as? Bool, true)
        let jobID = try XCTUnwrap(handle["jobID"] as? String)
        XCTAssertEqual(handle["state"] as? String, "queued")

        let finished = await G09R2LargeImportService.shared.waitForCompletion(
            jobID: jobID, timeoutMillis: 15_000)
        XCTAssertEqual(finished?.state, .completed)

        let statusRequest = try JSONSerialization.data(withJSONObject: [
            "version": 6, "operation": "command", "requestID": "li-status",
            "epoch": fixture.epoch, "action": "media.largeImport.status",
            "payload": ["jobID": jobID, "sessionToken": token],
        ])
        let status = BridgeV6Handler.handle(
            requestData: statusRequest, fallbackRequestID: "li-status",
            service: fixture.service)
        XCTAssertEqual(status["ok"] as? Bool, true)
        XCTAssertEqual(status["state"] as? String, "completed")
        XCTAssertEqual(
            (status["createdProjectID"] as? String)?.lowercased(),
            G09SourceCreateIdentity.projectID(
                domain: "media", opID: opID).uuidString.lowercased())

        // A foreign session never reads the job, and a second cancel is
        // idempotent and never rewrites the completed truth.
        let foreign = try JSONSerialization.data(withJSONObject: [
            "version": 6, "operation": "command", "requestID": "li-foreign",
            "epoch": fixture.epoch, "action": "media.largeImport.status",
            "payload": ["jobID": jobID, "sessionToken": "foreign-session"],
        ])
        let foreignStatus = BridgeV6Handler.handle(
            requestData: foreign, fallbackRequestID: "li-foreign",
            service: fixture.service)
        XCTAssertEqual(foreignStatus["ok"] as? Bool, true)
        XCTAssertEqual(foreignStatus["errorCode"] as? String, "staleSession")
        XCTAssertNil(foreignStatus["createdProjectID"])

        let cancel = try JSONSerialization.data(withJSONObject: [
            "version": 6, "operation": "command", "requestID": "li-cancel",
            "epoch": fixture.epoch, "action": "media.largeImport.cancel",
            "payload": ["jobID": jobID, "sessionToken": token, "opID": opID],
        ])
        let cancelled = BridgeV6Handler.handle(
            requestData: cancel, fallbackRequestID: "li-cancel",
            service: fixture.service)
        XCTAssertEqual(cancelled["ok"] as? Bool, true)
        XCTAssertEqual(cancelled["state"] as? String, "completed")
    }

    private actor TestGate {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var waiterCount: Int { waiters.count }

        func wait() async {
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            released = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    private func awaitGate(_ gate: TestGate, timeoutMillis: Int = 5_000)
        async throws {
        let deadline = Date().addingTimeInterval(
            Double(timeoutMillis) / 1000)
        while Date() < deadline {
            if await gate.waiterCount > 0 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("commit gate was never reached")
    }

    private func newImportRequest(
        token: String, opID: String, metadata: G09R2LargeImportMetadata
    ) -> G09R2LargeImportRequest {
        .newProject(
            storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone),
            name: "Root Drain Import", kind: .image,
            sessionToken: token, opID: opID, metadata: metadata,
            preparedIntentToken: nil)
    }

    func testRootStopWaitsForRealImportWorkerAndPublishesNothing() async throws {
        let fixture = try await makeFixture()
        let token = "session-root-drain"
        let opID = "root-drain-\(UUID().uuidString.lowercased())"
        let bytes = Data("floe-r2-root-drain".utf8)
        let staged = try stageFile(fixture, token: token, bytes: bytes)
        let metadata = G09R2LargeImportMetadata(
            token: staged, kind: .image, fileName: "drain.png",
            mimeType: "image/png", byteCount: Int64(bytes.count),
            sha256: FloeDigest.sha256Hex(bytes),
            mediaMetadata: MediaAssetMetadata(width: 16, height: 16))
        let gate = TestGate()
        G09R2LargeImportService.shared.testingBeforeCommit = { _ in
            await gate.wait()
        }
        defer { G09R2LargeImportService.shared.testingBeforeCommit = nil }

        let handle = try await G09R2LargeImportService.shared.submit(
            service: fixture.service, epoch: fixture.epoch,
            request: newImportRequest(token: token, opID: opID,
                                      metadata: metadata))
        try await awaitGate(gate)
        // The worker is real (digest verified, stalled before commit).
        XCTAssertEqual(G09R2LargeImportService.shared.pendingCount(
            epoch: fixture.epoch), 1)
        let notClosed = await fixture.service.close(epoch: fixture.epoch)
        XCTAssertFalse(notClosed, "an active import worker must keep Root bound")
        let bound = await fixture.service.r2BoundCluster()
        XCTAssertEqual(bound?.epoch, fixture.epoch)
        let projectID = G09SourceCreateIdentity.projectID(
            domain: "media", opID: opID)

        await gate.release()
        let finished = await G09R2LargeImportService.shared.waitForCompletion(
            jobID: handle.jobID, timeoutMillis: 15_000)
        XCTAssertEqual(finished?.state, .cancelled)
        XCTAssertNil(finished?.createdProjectID)
        let library = try await fixture.cluster.media.library()
        XCTAssertFalse(library.contains { $0.id == projectID },
                       "a pre-commit Root stop publishes no project")
        let closed = await fixture.service.close(epoch: fixture.epoch)
        XCTAssertTrue(closed)
        let unbound = await fixture.service.r2BoundCluster()
        XCTAssertNil(unbound)
    }


    func testExistingProjectLargeImportLosesNegativeRevisionCAS() async throws {
        let fixture = try await makeFixture()
        let created = try await fixture.cluster.media.create(
            name: "CAS Import", kind: .video, width: 64, height: 64,
            frameRate: 30, storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        let token = "session-cas-import"
        let projectID = created.project.id
        _ = try await G09R2MediaFoundation.shared.loadVideo(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2VideoLoadRequest(
                context: context(projectID, token: token)))
        let bytes = Data("floe-r2-cas-import".utf8)
        let staged = try stageFile(fixture, token: token, bytes: bytes)
        let metadata = G09R2LargeImportMetadata(
            token: staged, kind: .image, fileName: "cas.png",
            mimeType: "image/png", byteCount: Int64(bytes.count),
            sha256: FloeDigest.sha256Hex(bytes))
        let gate = TestGate()
        G09R2LargeImportService.shared.testingBeforeCommit = { _ in
            await gate.wait()
        }
        defer { G09R2LargeImportService.shared.testingBeforeCommit = nil }
        let handle = try await G09R2LargeImportService.shared.submit(
            service: fixture.service, epoch: fixture.epoch,
            request: .existingProject(
                context: context(projectID, token: token),
                expectedRevision: 0, opID: "cas-import-op",
                metadata: metadata))
        try await awaitGate(gate)
        // A real concurrent edit advances the revision before the import
        // commit fence; the existing-project import must lose the CAS.
        _ = try await G09R2MediaFoundation.shared.applyVideo(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2VideoApplyRequest(
                context: context(projectID, token: token),
                expectedRevision: 0, opID: "cas-import-edit",
                commands: [.setCanvas(width: 96, height: 64, frameRate: 30)]))
        await gate.release()
        let finished = await G09R2LargeImportService.shared.waitForCompletion(
            jobID: handle.jobID, timeoutMillis: 15_000)
        XCTAssertEqual(finished?.state, .failed)
        XCTAssertEqual(finished?.errorCode, "revisionConflict")
        let reloaded = try await fixture.cluster.media.load(
            id: projectID, requested: G09StorageLayerDTO(kind: .appOwned))
        XCTAssertEqual(reloaded.project.revision, 1)
        XCTAssertEqual(reloaded.project.assets.count, 0)
        let closed = await fixture.service.close(epoch: fixture.epoch)
        XCTAssertTrue(closed)
    }

    func testCancelBeforeCommitSettlesOnceWithoutPublishing() async throws {
        let fixture = try await makeFixture()
        let token = "session-cancel-import"
        let opID = "cancel-import-\(UUID().uuidString.lowercased())"
        let bytes = Data("floe-r2-cancel-import".utf8)
        let staged = try stageFile(fixture, token: token, bytes: bytes)
        let metadata = G09R2LargeImportMetadata(
            token: staged, kind: .image, fileName: "cancel.png",
            mimeType: "image/png", byteCount: Int64(bytes.count),
            sha256: FloeDigest.sha256Hex(bytes),
            mediaMetadata: MediaAssetMetadata(width: 16, height: 16))
        let gate = TestGate()
        G09R2LargeImportService.shared.testingBeforeCommit = { _ in
            await gate.wait()
        }
        defer { G09R2LargeImportService.shared.testingBeforeCommit = nil }
        let handle = try await G09R2LargeImportService.shared.submit(
            service: fixture.service, epoch: fixture.epoch,
            request: newImportRequest(token: token, opID: opID,
                                      metadata: metadata))
        try await awaitGate(gate)
        let cancelled = try await G09R2LargeImportService.shared.cancel(
            G09R2LargeImportCancelRequest(
                jobID: handle.jobID, sessionToken: token, opID: opID),
            service: fixture.service, epoch: fixture.epoch)
        XCTAssertFalse(
            [.completed, .failed].contains(cancelled.state),
            "cancel is a request, not a fabricated terminal state")
        await gate.release()
        let finished = await G09R2LargeImportService.shared.waitForCompletion(
            jobID: handle.jobID, timeoutMillis: 15_000)
        XCTAssertEqual(finished?.state, .cancelled)
        XCTAssertNil(finished?.createdProjectID)
        let closed = await fixture.service.close(epoch: fixture.epoch)
        XCTAssertTrue(closed)
    }

    // MARK: - Snapshot pins / prepared binding / authority

    func testSnapshotReleaseIsDeferredWhileATicketClaimIsLive() async throws {
        let fixture = try await makeFixture()
        let mailbox = G09R2MediaRenderHostMailbox.shared
        XCTAssertTrue(mailbox.bind(epoch: fixture.epoch))
        defer { _ = mailbox.prepareRootStop(epoch: fixture.epoch) }
        let created = try await fixture.cluster.media.create(
            name: "Pinned", kind: .image, width: 64, height: 64,
            frameRate: nil, storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        let token = "session-pinned"
        let projectID = created.project.id
        let loaded = try await G09R2MediaFoundation.shared.loadVideo(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2VideoLoadRequest(
                context: context(projectID, token: token)))
        let binding = try await G09R2MediaFoundation.shared.prepareRenderBinding(
            service: fixture.service, epoch: fixture.epoch,
            context: context(projectID, token: token),
            expectedRevision: 0, attemptID: "attempt-pinned")
        XCTAssertEqual(binding.timelineDigest, loaded.timelineDigest)
        let snapshotURL = URL(
            fileURLWithPath: binding.snapshot.mediaRootPath, isDirectory: true)
            .appendingPathComponent(binding.snapshot.relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))

        _ = try await G09R2MediaFoundation.shared.submitRenderTicket(
            service: fixture.service, epoch: fixture.epoch,
            context: context(projectID, token: token),
            projectRevision: 0, timelineDigest: binding.timelineDigest,
            attemptID: "attempt-pinned", kind: .preview,
            lease: binding.snapshot)
        let claimed = try XCTUnwrap(mailbox.claim(timeoutMillis: 1_000))
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: claimed) as? [String: Any])
        let claimToken = try XCTUnwrap(envelope["claimToken"] as? String)

        do {
            try await G09R2MediaFoundation.shared.releaseSnapshot(
                service: fixture.service, epoch: fixture.epoch,
                lease: binding.snapshot)
            XCTFail("release under a live claim must be refused")
        } catch let error as G09R2Error {
            XCTAssertEqual(error.code, "renderTicketExpired")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path),
                      "the claimed ticket still needs the snapshot")

        let ticketID = try XCTUnwrap(
            (envelope["descriptor"] as? [String: Any])?["ticketID"] as? String)
        XCTAssertEqual(mailbox.close(ticketID: ticketID,
                                     claimToken: claimToken), 0)
        // The deferred release is honoured exactly at settlement: the exact
        // owned snapshot is deleted once the last pin is gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
        try await G09R2MediaFoundation.shared.releaseSnapshot(
            service: fixture.service, epoch: fixture.epoch,
            lease: binding.snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    func testPrepareRenderBindingWorksForImageAndVideoAndPinBlocksRootStop()
        async throws {
        for (kind, width, height) in [
            (MediaProjectKind.image, 64, 64), (.video, 64, 64),
        ] {
            let fixture = try await makeFixture()
            let created = try await fixture.cluster.media.create(
                name: "Prepare \(kind.rawValue)", kind: kind,
                width: width, height: height,
                frameRate: kind == .video ? 30 : nil,
                storage: G09StorageLayerDTO(kind: .appOwned),
                origin: G09CreativeOriginDTO(kind: .standalone))
            let token = "session-prepare-\(kind.rawValue)"
            let projectID = created.project.id
            let loaded = try await G09R2MediaFoundation.shared.loadVideo(
                service: fixture.service, epoch: fixture.epoch,
                request: G09R2VideoLoadRequest(
                    context: context(projectID, token: token)))
            let binding = try await G09R2MediaFoundation.shared
                .prepareRenderBinding(
                    service: fixture.service, epoch: fixture.epoch,
                    context: context(projectID, token: token),
                    expectedRevision: 0,
                    attemptID: "attempt-prepare-\(kind.rawValue)")
            XCTAssertEqual(binding.mediaRootPath, created.storage.rootURL.path)
            XCTAssertEqual(binding.timelineDigest, loaded.timelineDigest)
            XCTAssertEqual(binding.projectRevision, 0)

            let pin = try await G09R2RenderBindingPins.shared.retain(
                service: fixture.service, epoch: fixture.epoch,
                request: G09R2RetainRenderBindingRequest(
                    binding: binding, ownerOperationID: "export-\(kind.rawValue)"))
            XCTAssertEqual(pin.mediaRootPath, created.storage.rootURL.path)
            // Platform lifecycle pin: same native-prepared attempt/lease,
            // no lease by value in the request.
            let lifecycle = try await G09R2RenderBindingPins.shared
                .pinLifecycle(
                    service: fixture.service, epoch: fixture.epoch,
                    request: G09R2LifecyclePinRequest(
                        context: context(projectID, token: token),
                        kind: "export", epoch: fixture.epoch,
                        mediaRootPath: binding.mediaRootPath,
                        attemptID: binding.attemptID, jobID: "job-1"))
            XCTAssertEqual(lifecycle.kind, "export")
            XCTAssertEqual(lifecycle.attemptID, binding.attemptID)
            XCTAssertEqual(lifecycle.leaseID, binding.snapshot.leaseID)
            let pinnedClose = await fixture.service.close(epoch: fixture.epoch)
            XCTAssertFalse(pinnedClose,
                           "a retained/lifecycle pin keeps Root bound")
            XCTAssertTrue(G09R2RenderBindingPins.shared.release(
                epoch: fixture.epoch, handle: pin.pinHandle))
            // Idempotent release after settlement.
            XCTAssertTrue(G09R2RenderBindingPins.shared.release(
                epoch: fixture.epoch, handle: pin.pinHandle))
            XCTAssertTrue(G09R2RenderBindingPins.shared.release(
                epoch: fixture.epoch, handle: lifecycle.pinHandle))

            let closed = await fixture.service.close(epoch: fixture.epoch)
            XCTAssertTrue(closed)
        }
    }


    func testExpiredAuthorityNeverReleasesAPinWithoutWorkerAck() async throws {
        let fixture = try await makeFixture()
        let created = try await fixture.cluster.media.create(
            name: "Overdue Pin", kind: .image, width: 48, height: 48,
            frameRate: nil, storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        let token = "session-overdue-pin"
        let projectID = created.project.id
        _ = try await G09R2MediaFoundation.shared.loadVideo(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2VideoLoadRequest(
                context: context(projectID, token: token)))
        let binding = try await G09R2MediaFoundation.shared.prepareRenderBinding(
            service: fixture.service, epoch: fixture.epoch,
            context: context(projectID, token: token),
            expectedRevision: 0, attemptID: "attempt-overdue")
        let snapshotURL = URL(
            fileURLWithPath: binding.snapshot.mediaRootPath, isDirectory: true)
            .appendingPathComponent(binding.snapshot.relativePath)
        let pin = try await G09R2RenderBindingPins.shared.retain(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2RetainRenderBindingRequest(
                binding: binding, ownerOperationID: "export-overdue"))
        XCTAssertEqual(G09R2SnapshotLeases.shared.pinnedCount(
            epoch: fixture.epoch), 1)

        // Advance the AUTHORITY deadline far past expiry. This must fence new
        // work, not pretend the worker stopped.
        G09R2RenderBindingPins.shared.purgeExpired(
            epoch: fixture.epoch,
            now: Date().addingTimeInterval(
                G09R2RenderBindingPins.authorityValiditySeconds + 120))
        XCTAssertEqual(G09R2RenderBindingPins.shared.overdueCount(
            epoch: fixture.epoch), 1)
        XCTAssertEqual(G09R2RenderBindingPins.shared.count(
            epoch: fixture.epoch), 1, "overdue is not released")
        XCTAssertEqual(G09R2SnapshotLeases.shared.pinnedCount(
            epoch: fixture.epoch), 1, "the lease/Root pin stays owned")
        XCTAssertGreaterThanOrEqual(
            floeMediaFoundationDrainPending(fixture.epoch), 1,
            "drain must stay pending without an ack")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))

        // An overdue authority refuses NEW work/extension on the same lease;
        // it does not release or extend the existing owner.
        do {
            _ = try await G09R2RenderBindingPins.shared.retain(
                service: fixture.service, epoch: fixture.epoch,
                request: G09R2RetainRenderBindingRequest(
                    binding: binding, ownerOperationID: "export-overdue-2"))
            XCTFail("overdue authority must not accept a new pin")
        } catch let error as G09R2Error {
            XCTAssertEqual(error.code, "renderTicketExpired")
        }
        XCTAssertEqual(G09R2RenderBindingPins.shared.count(
            epoch: fixture.epoch), 1)

        let notClosed = await fixture.service.close(epoch: fixture.epoch)
        XCTAssertFalse(notClosed, "the overdue pin still keeps Root bound")

        // A caller release while the pin is live is deferred; it cannot delete
        // the snapshot under the still-owned worker.
        do {
            try await G09R2MediaFoundation.shared.releaseSnapshot(
                service: fixture.service, epoch: fixture.epoch,
                lease: binding.snapshot)
            XCTFail("release under a pinned (even overdue) pin must be refused")
        } catch let error as G09R2Error {
            XCTAssertEqual(error.code, "renderTicketExpired")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))

        // Authenticated worker ack is the only release; the deferred caller
        // deletion then removes exactly the owned snapshot.
        XCTAssertTrue(G09R2RenderBindingPins.shared.release(
            epoch: fixture.epoch, handle: pin.pinHandle))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
        XCTAssertEqual(G09R2SnapshotLeases.shared.pinnedCount(
            epoch: fixture.epoch), 0)
        XCTAssertEqual(floeMediaFoundationDrainPending(fixture.epoch), 0)
        let closed = await fixture.service.close(epoch: fixture.epoch)
        XCTAssertTrue(closed)
    }

    func testResolveProjectMediaRootReturnsStableAuthorizedProof() async throws {
        let fixture = try await makeFixture()
        let created = try await fixture.cluster.media.create(
            name: "Recovery Root", kind: .image, width: 32, height: 32,
            frameRate: nil, storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        let token = "session-recovery"
        let projectID = created.project.id
        _ = try await G09R2MediaFoundation.shared.loadVideo(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2VideoLoadRequest(
                context: context(projectID, token: token)))
        let request = G09R2ProjectContextDTO(
            projectID: projectID, sessionToken: token,
            storage: G09StorageLayerDTO(kind: .appOwned),
            origin: nil)
        let first = try await G09R2HostAuthority.resolveProjectMediaRoot(
            service: fixture.service, epoch: fixture.epoch, context: request)
        let second = try await G09R2HostAuthority.resolveProjectMediaRoot(
            service: fixture.service, epoch: fixture.epoch, context: request)
        XCTAssertEqual(first.mediaRootPath, created.storage.rootURL.path)
        XCTAssertEqual(first.projectID, projectID.uuidString.lowercased())
        XCTAssertEqual(first.ownerProof, second.ownerProof)
        XCTAssertEqual(first.ownerProof.count, 64)
        XCTAssertEqual(first.storageKey, "appOwned")
        XCTAssertNil(first.originKey)
        XCTAssertFalse(first.mediaRootPath.hasPrefix("/tmp/"), "no base guess")
        do {
            _ = try await G09R2HostAuthority.resolveProjectMediaRoot(
                service: fixture.service, epoch: fixture.epoch,
                context: G09R2ProjectContextDTO(
                    projectID: projectID, sessionToken: "foreign-session",
                    storage: G09StorageLayerDTO(kind: .appOwned),
                    origin: nil))
            XCTFail("a foreign session must not resolve the project root")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.code, "staleSession")
        }
        let closed = await fixture.service.close(epoch: fixture.epoch)
        XCTAssertTrue(closed)
    }

    func testAuthorityTicketVerificationUsesNativeClaim() async throws {
        let fixture = try await makeFixture()
        let mailbox = G09R2MediaRenderHostMailbox.shared
        XCTAssertTrue(mailbox.bind(epoch: fixture.epoch))
        defer { _ = mailbox.prepareRootStop(epoch: fixture.epoch) }
        let created = try await fixture.cluster.media.create(
            name: "Authority Ticket", kind: .image, width: 32, height: 32,
            frameRate: nil, storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        let token = "session-authority-ticket"
        let projectID = created.project.id
        let loaded = try await G09R2MediaFoundation.shared.loadVideo(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2VideoLoadRequest(
                context: context(projectID, token: token)))
        let lease = try await G09R2MediaFoundation.shared.acquireSnapshot(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2RenderSnapshotRequestDTO(
                context: context(projectID, token: token),
                expectedRevision: 0,
                expectedTimelineDigest: loaded.timelineDigest))
        let descriptor = try await G09R2MediaFoundation.shared.submitRenderTicket(
            service: fixture.service, epoch: fixture.epoch,
            context: context(projectID, token: token),
            projectRevision: 0, timelineDigest: loaded.timelineDigest,
            attemptID: "attempt-authority-ticket", kind: .preview,
            lease: lease)
        let claimed = try XCTUnwrap(mailbox.claim(timeoutMillis: 1_000))
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: claimed) as? [String: Any])
        let claimToken = try XCTUnwrap(envelope["claimToken"] as? String)
        let grant = try await G09R2HostAuthority.verifyTicket(
            service: fixture.service, epoch: fixture.epoch,
            proof: G09R2TicketProof(
                descriptor: descriptor, claimToken: claimToken))
        XCTAssertEqual(grant.mediaRootPath, descriptor.mediaRootPath)
        XCTAssertEqual(grant.revision, 0)
        do {
            _ = try await G09R2HostAuthority.verifyTicket(
                service: fixture.service, epoch: fixture.epoch,
                proof: G09R2TicketProof(
                    descriptor: descriptor, claimToken: "wrong-token"))
            XCTFail("a client token must never prove a native claim")
        } catch let error as G09R2Error {
            XCTAssertEqual(error.code, "renderTicketNotFound")
        }
        XCTAssertEqual(mailbox.close(ticketID: descriptor.ticketID,
                                     claimToken: claimToken), 0)
    }

    // MARK: - Helpers

    private static func encodeReply(
        ticketID: String, status: G09R2RenderTicketReplyStatus,
        receipt: G09R2MediaExportReceiptDTO?
    ) throws -> Data {
        var reply = G09R2RenderTicketReplyDTO(
            ticketID: ticketID, status: status, receipt: receipt,
            errorCode: status == .completed ? nil : "renderFailed",
            completedAt: Date(), replyByteCount: 0)
        let encoder = G09CreativeWire.encoder()
        var data = try encoder.encode(reply)
        reply.replyByteCount = data.count
        data = try encoder.encode(reply)
        if data.count != reply.replyByteCount {
            reply.replyByteCount = data.count
            data = try encoder.encode(reply)
        }
        return data
    }
}
