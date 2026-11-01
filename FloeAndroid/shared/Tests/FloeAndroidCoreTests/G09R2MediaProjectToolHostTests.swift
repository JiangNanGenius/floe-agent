// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 real media.project host tests (job-258c68e91e6840df).
//
// These are SOURCE-AUTHORED, focused deterministic tests. They use temporary
// explicit roots, an in-memory database and a private render-ticket mailbox.
// They do NOT execute the real Kotlin Media3/Bitmap renderer: export cases
// claim a real native ticket and settle it with a receipt whose output bytes
// are real files, so the native receipt/file/hash/ownership verification and
// the portable receipt mapping are exercised. Playability/codec/device proof
// remains Main's App/device gate and is not claimed here.
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeAndroidWorkbench

final class G09R2MediaProjectToolHostTests: XCTestCase {
    private var roots: [URL] = []
    private var database: DatabaseManager?
    private var mailbox: G09R2MediaRenderHostMailbox!
    private var service: G09CreativeDomainService!
    private var cluster: G09R2BoundCluster!
    private var proposals: G09R2MediaToolProposalStore!
    private var grants: G09R2MediaToolGrants!
    private var host: G09R2MediaProjectToolHost!
    private var conversationStore: SQLiteConversationStore!
    private var workspaceStore: SQLiteWorkspaceStore!
    private var conversationID: UUID!
    private var workspaceID: UUID!
    private var epoch: UInt64 = 0
    private var access: MediaProjectAccess!
    private var origin: G09CreativeOriginDTO!
    private let environmentID = "env-g09-mediatool"

    override func tearDown() async throws {
        if let mailbox, epoch > 0 {
            _ = mailbox.prepareRootStop(epoch: epoch)
        }
        G09R2SnapshotLeases.shared.retire(epoch: epoch)
        if let service, epoch > 0 {
            _ = await service.close(epoch: epoch)
        }
        G09R2MediaToolAvailability.shared.resetForTesting()
        if let database { try? await database.close() }
        database = nil
        mailbox = nil
        service = nil
        cluster = nil
        proposals = nil
        grants = nil
        host = nil
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        try await super.tearDown()
    }

    private func assertValidationFailure(
        _ error: Error, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let floe = error as? FloeError,
              case .validationFailed = floe else {
            XCTFail("expected a typed validation refusal, got \(error)",
                    file: file, line: line)
            return
        }
    }

    // MARK: - Fixture

    private func makeFixture(exportAwaitSeconds: TimeInterval = 660) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-mediatool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        database = manager
        workspaceStore = SQLiteWorkspaceStore(database: manager)
        conversationStore = SQLiteConversationStore(database: manager)
        let root = try XCTUnwrap(RuntimeStorageRoot(validatingAbsoluteDirectory: url.path))
        conversationID = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "Media Task",
            createdAt: Date(), updatedAt: Date()))
        workspaceID = UUID()
        try await workspaceStore.saveWorkspace(WorkspaceRecord(
            id: workspaceID, name: "Media Task", rootBookmark: Data(),
            kind: .privateTask,
            internalRelativePath: "PrivateTasks/\(workspaceID.uuidString)"))
        try await workspaceStore.assignConversation(
            workspaceID: workspaceID, conversationID: conversationID)

        mailbox = G09R2MediaRenderHostMailbox()
        service = G09CreativeDomainService()
        epoch = UInt64.random(in: 50_000...900_000)
        let context = G09CreativeStorageContext(
            root: root, database: manager, workspaceStore: workspaceStore,
            conversationStore: conversationStore)
        _ = try await service.bind(epoch: epoch, storage: context)
        let bound = await service.r2BoundCluster()
        cluster = try XCTUnwrap(bound)
        XCTAssertTrue(mailbox.bind(epoch: epoch))
        // A real epoch-exact consumer heartbeat proves the renderer is
        // running (bind alone is not proof).
        XCTAssertTrue(mailbox.consumerHeartbeat(epoch: epoch))
        origin = G09CreativeOriginDTO(
            kind: .chat, ownerID: conversationID, environmentID: environmentID)
        access = MediaProjectAccess(
            environmentID: environmentID, workspacePath: nil,
            ownerKind: "chat", ownerID: conversationID)
        proposals = G09R2MediaToolProposalStore()
        grants = G09R2MediaToolGrants(
            service: service, mailbox: mailbox, proposals: proposals)
        host = G09R2MediaProjectToolHost(
            service: service, mailbox: mailbox, proposals: proposals,
            grants: grants,
            config: G09R2MediaToolHostConfig(
                exportAwaitSeconds: exportAwaitSeconds,
                exportPollMillis: 250))
    }

    @discardableResult
    private func createProject(name: String = "Poster",
                               kind: MediaProjectKind = .image,
                               width: Int = 640, height: Int = 480,
                               frameRate: Double? = nil) async throws -> MediaProject {
        let created = try await cluster.media.create(
            name: name, kind: kind, width: width, height: height,
            frameRate: frameRate,
            storage: G09StorageLayerDTO(kind: .appOwned),
            origin: origin)
        return created.project
    }

    private func authorizeAndLoad(_ projectID: UUID) async throws -> MediaProject {
        try await host.authorizeAccess(projectID: projectID, access: access)
        let loaded = try await host.loadProject(id: projectID)
        return try XCTUnwrap(loaded)
    }

    private func addTextLayer(_ projectID: UUID, name: String = "Title") async throws {
        var text = ImageLayer(kind: .text, name: name)
        text.text = ImageTextContent(text: "Hello")
        _ = try await cluster.media.applyShared(
            projectID: projectID, expectedRevision: 0,
            sessionToken: "setup.session", storage: G09StorageLayerDTO(kind: .appOwned),
            origin: origin, opID: "setup-\(projectID.uuidString.lowercased())",
            commands: [.addImageLayer(text)])
    }

    private func readProjectFile(_ projectID: UUID) throws -> Data {
        let url = URL(fileURLWithPath: cluster.media.projectDirectoryPath,
                      isDirectory: true)
            .appendingPathComponent(MediaProjectStore.projectFileName(id: projectID))
        return try Data(contentsOf: url)
    }

    // MARK: - Access / task isolation

    func testAccessRequiresExactTaskOwnerEnvironmentAndRealStorageLayer() async throws {
        try await makeFixture()
        let project = try await createProject()
        // Without a preceding authorization the same host refuses a load.
        do {
            _ = try await host.loadProject(id: project.id)
            XCTFail("load without authorizeAccess must be refused")
        } catch let error as FloeError {
            XCTAssertEqual(error, .unauthorized)
        }
        let loaded = try await authorizeAndLoad(project.id)
        XCTAssertEqual(loaded.id, project.id)
        XCTAssertEqual(loaded.revision, 0)

        // A different conversation (or a nonexistent one) never reaches the
        // project.
        let otherConversation = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: otherConversation, title: "Other",
            createdAt: Date(), updatedAt: Date()))
        let otherAccess = MediaProjectAccess(
            environmentID: environmentID, workspacePath: nil,
            ownerKind: "chat", ownerID: otherConversation)
        do {
            try await host.authorizeAccess(projectID: project.id, access: otherAccess)
            XCTFail("another task must not authorize this media project")
        } catch let error as FloeError {
            XCTAssertEqual(error, .unauthorized)
        }

        // Another environment is refused even for the right conversation.
        let wrongEnvironment = MediaProjectAccess(
            environmentID: "env-other", workspacePath: nil,
            ownerKind: "chat", ownerID: conversationID)
        do {
            try await host.authorizeAccess(projectID: project.id, access: wrongEnvironment)
            XCTFail("a different environment must be refused")
        } catch let error as FloeError {
            XCTAssertEqual(error, .unauthorized)
        }

        // A caller-supplied workspace path that is not the task's real row is
        // refused (recorded provenance is never a root grant).
        let spoofed = MediaProjectAccess(
            environmentID: environmentID, workspacePath: "/tmp/not-this-task",
            ownerKind: "chat", ownerID: conversationID)
        do {
            try await host.authorizeAccess(projectID: project.id, access: spoofed)
            XCTFail("a foreign workspace path must be refused")
        } catch let error as FloeError {
            XCTAssertEqual(error, .unauthorized)
        }

    }

    func testTamperedRecordedStoragePathIsRefusedAndPreserved() async throws {
        try await makeFixture()
        let project = try await createProject()
        let url = URL(fileURLWithPath: cluster.media.projectDirectoryPath,
                      isDirectory: true)
            .appendingPathComponent(MediaProjectStore.projectFileName(id: project.id))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        object["taskWorkspacePath"] = "/tmp/forged-media-root"
        let forged = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys])
        try forged.write(to: url)

        do {
            try await host.authorizeAccess(projectID: project.id, access: access)
            XCTFail("a forged recorded path must not resolve to a storage root")
        } catch {
            assertValidationFailure(error)
        }
        XCTAssertEqual(try Data(contentsOf: url), forged)
    }

    // MARK: - Proposals / grants

    private func makeTextProposal(_ projectID: UUID, baseRevision: Int64,
                                  text: String = "Hello",
                                  id: UUID = UUID()) -> MediaProposal {
        var layer = ImageLayer(kind: .text, name: "Title")
        layer.text = ImageTextContent(text: text)
        return MediaProposal(
            id: id, projectID: projectID, baseRevision: baseRevision,
            summary: "Add \(text)", commands: [.addImageLayer(layer)])
    }

    func testProposalStoreIsBoundToTaskAndRejectsIdentityCollision() async throws {
        try await makeFixture()
        let project = try await createProject()
        _ = try await authorizeAndLoad(project.id)
        let proposal = makeTextProposal(project.id, baseRevision: 0)
        try await host.storeProposal(proposal)
        let loaded = try await host.loadProposal(id: proposal.id)
        XCTAssertEqual(loaded?.id, proposal.id)
        XCTAssertEqual(loaded?.commands.count, 1)

        // Same identity and same bytes is idempotent.
        try await host.storeProposal(proposal)
        let reloaded = try await host.loadProposal(id: proposal.id)
        XCTAssertEqual(reloaded?.summary, proposal.summary)

        // Same identity with different bytes is refused; the stored draft is
        // never silently replaced.
        let collision = makeTextProposal(
            project.id, baseRevision: 0, text: "Different", id: proposal.id)
        do {
            try await host.storeProposal(collision)
            XCTFail("a different proposal under the same identity must be refused")
        } catch {
            assertValidationFailure(error)
        }
        let stillStored = try await host.loadProposal(id: proposal.id)
        XCTAssertEqual(stillStored?.summary, proposal.summary)

        // A stale base is refused at storage time.
        let stale = makeTextProposal(project.id, baseRevision: 0, text: "Stale")
        _ = try await cluster.media.applyShared(
            projectID: project.id, expectedRevision: 0,
            sessionToken: "setup.session", storage: G09StorageLayerDTO(kind: .appOwned),
            origin: origin, opID: "advance-1",
            commands: [.setCanvas(width: 800, height: 600, frameRate: nil)])
        do {
            try await host.storeProposal(stale)
            XCTFail("a stale proposal must be refused")
        } catch {
            assertValidationFailure(error)
        }
    }

    func testGrantIsIssuedOnlyAfterRealAuthorizationAndConsumedOnce() async throws {
        try await makeFixture()
        let project = try await createProject()
        _ = try await authorizeAndLoad(project.id)
        let proposal = makeTextProposal(project.id, baseRevision: 0)
        try await host.storeProposal(proposal)

        let grantID = try await grants.issue(
            access: access, projectID: project.id,
            proposalID: proposal.id, revision: 0)
        XCTAssertFalse(grantID.isEmpty)
        let granted = await host.consumeGrant(
            grantID: grantID, proposalID: proposal.id,
            projectID: project.id, revision: 0)
        XCTAssertEqual(granted, .authorized)
        let replay = await host.consumeGrant(
            grantID: grantID, proposalID: proposal.id,
            projectID: project.id, revision: 0)
        XCTAssertEqual(replay, .alreadyConsumed)
        let unknown = await host.consumeGrant(
            grantID: "not-a-grant", proposalID: proposal.id,
            projectID: project.id, revision: 0)
        XCTAssertEqual(unknown, .unknownGrant)

        // A grant issued for revision 0 cannot commit a different revision;
        // the EXACT original single-use store reports the mismatch.
        let secondGrant = try await grants.issue(
            access: access, projectID: project.id,
            proposalID: proposal.id, revision: 0)
        let mismatch = await host.consumeGrant(
            grantID: secondGrant, proposalID: proposal.id,
            projectID: project.id, revision: 1)
        XCTAssertEqual(mismatch, .revisionMismatch(expected: 0, actual: 1))

        // Issuing against a foreign task is refused before any grant exists.
        let foreignAccess = MediaProjectAccess(
            environmentID: "env-other", workspacePath: nil,
            ownerKind: "chat", ownerID: conversationID)
        do {
            _ = try await grants.issue(
                access: foreignAccess, projectID: project.id,
                proposalID: proposal.id, revision: 0)
            XCTFail("a foreign environment cannot issue a grant")
        } catch let error as FloeError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    // MARK: - Durable apply / CAS replay

    func testPersistApplyUsesRealCASAndReplaysByProposalReceipt() async throws {
        try await makeFixture()
        let project = try await createProject()
        let base = try await authorizeAndLoad(project.id)
        let proposal = makeTextProposal(project.id, baseRevision: base.revision)
        try await host.storeProposal(proposal)
        _ = try await host.loadProposal(id: proposal.id)

        var live = base
        try MediaProposalGate.applyAuthorized(
            proposal, grant: .authorized, to: &live)
        try await host.persistProject(live, expectedRevision: base.revision)
        let reopenedValue = try await host.loadProject(id: project.id)
        let reopened = try XCTUnwrap(reopenedValue)
        XCTAssertEqual(reopened.revision, base.revision + 1)
        XCTAssertEqual(reopened.imageLayers.count, 1)
        XCTAssertEqual(reopened.imageLayers.first?.id,
                       live.imageLayers.first?.id)
        let receipt = try await cluster.media.readReceipt(
            "mt-\(proposal.id.uuidString.lowercased())")
        XCTAssertEqual(receipt.revision, reopened.revision)
        XCTAssertEqual(receipt.expectedRevision, base.revision)

        // A retried apply after the commit is reported idempotently from the
        // durable receipt; no second mutation is written.
        let before = try readProjectFile(project.id)
        try await host.persistProject(live, expectedRevision: base.revision)
        XCTAssertEqual(try readProjectFile(project.id), before)
        let reloadedValue = try await host.loadProject(id: project.id)
        let reloaded = try XCTUnwrap(reloadedValue)
        XCTAssertEqual(reloaded.revision, reopened.revision)

        // A base mismatch with a different target is a real stale apply.
        let staleValue = try await host.loadProject(id: project.id)
        var stale = try XCTUnwrap(staleValue)
        stale.name = "Stale rename"
        do {
            try await host.persistProject(stale, expectedRevision: base.revision)
            XCTFail("a stale base must be refused")
        } catch {
            assertValidationFailure(error)
        }
        XCTAssertEqual(try readProjectFile(project.id), before)

        // An externally fabricated mutation that matches no pending proposal
        // is never persisted.
        let externalValue = try await host.loadProject(id: project.id)
        var external = try XCTUnwrap(externalValue)
        external.name = "Not a proposal"
        do {
            try await host.persistProject(
                external, expectedRevision: reopened.revision)
            XCTFail("a mutation without a matching proposal must be refused")
        } catch {
            assertValidationFailure(error)
        }
        XCTAssertEqual(try readProjectFile(project.id), before)

        // The tool removes the draft after its apply; the host honours that
        // exactly once and a stale draft is not resurrected.
        try await host.removeProposal(id: proposal.id)
        let removed = try await host.loadProposal(id: proposal.id)
        XCTAssertNil(removed)
    }

    // MARK: - Export path

    private struct ClaimEnvelope: Decodable {
        let descriptor: G09R2RenderTicketDescriptorDTO
        let claimToken: String
    }

    private func waitForClaim(
        _ mailbox: G09R2MediaRenderHostMailbox,
        attempts: Int = 80
    ) async throws -> ClaimEnvelope {
        for _ in 0..<attempts {
            if let data = mailbox.claim(timeoutMillis: 100) {
                return try G09CreativeWire.decoder().decode(
                    ClaimEnvelope.self, from: data)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw FloeError.validationFailed("the export never submitted a ticket")
    }

    private func writeOutput(_ descriptor: G09R2RenderTicketDescriptorDTO,
                             bytes: Data = Data("verified-export-bytes".utf8))
        throws -> (url: URL, sha256: String, byteCount: Int64) {
        let root = URL(fileURLWithPath: descriptor.mediaRootPath,
                       isDirectory: true)
        let url = root.appendingPathComponent(descriptor.outputRelativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        let sha = try FloeDigest.sha256Hex(ofFileAt: url)
        return (url, sha, Int64(bytes.count))
    }

    private func complete(
        _ mailbox: G09R2MediaRenderHostMailbox,
        claim: ClaimEnvelope,
        receipt: G09R2MediaExportReceiptDTO
    ) throws -> Int32 {
        var reply = G09R2RenderTicketReplyDTO(
            ticketID: claim.descriptor.ticketID,
            status: .completed, receipt: receipt, errorCode: nil,
            completedAt: Date(), replyByteCount: 0)
        var data = try G09CreativeWire.encoder().encode(reply)
        reply.replyByteCount = data.count
        data = try G09CreativeWire.encoder().encode(reply)
        if reply.replyByteCount != data.count {
            reply.replyByteCount = data.count
            data = try G09CreativeWire.encoder().encode(reply)
        }
        return mailbox.complete(
            ticketID: claim.descriptor.ticketID,
            claimToken: claim.claimToken, replyData: data)
    }

    private func imageReceipt(
        _ descriptor: G09R2RenderTicketDescriptorDTO,
        output: (url: URL, sha256: String, byteCount: Int64),
        width: Int = 64, height: Int = 48
    ) -> G09R2MediaExportReceiptDTO {
        G09R2MediaExportReceiptDTO(
            binding: G09R2MediaExportReceiptBindingDTO(
                projectID: descriptor.projectID,
                mediaRootPath: descriptor.mediaRootPath,
                projectRevision: descriptor.projectRevision,
                timelineDigest: descriptor.timelineDigest,
                attemptID: descriptor.attemptID),
            kind: .image,
            outputRelativePath: descriptor.outputRelativePath,
            mimeType: "image/png",
            byteCount: output.byteCount,
            sha256: output.sha256,
            verification: G09R2ExportVerificationDTO(
                playable: true, decodedDurationSeconds: nil,
                width: width, height: height, audioTrackCount: 0,
                container: "png", codec: "png"),
            completedAt: Date())
    }

    func testImageExportUsesRealTicketAndVerifiedReceiptFacts() async throws {
        try await makeFixture()
        let project = try await createProject()
        try await addTextLayer(project.id)
        let loaded = try await authorizeAndLoad(project.id)
        let options = ImageExportOptions(
            format: .png, width: 64, height: 48, quality: 1,
            preserveTransparency: true, stripMetadata: true,
            fileName: "Poster")
        let host = try XCTUnwrap(self.host)
        let task = Task {
            try await host.exportImage(
                project: loaded, options: options,
                relativeOutput: "Workbench/Exports/Poster.png")
        }
        let claim = try await waitForClaim(mailbox)
        XCTAssertEqual(claim.descriptor.kind, .image)
        XCTAssertEqual(claim.descriptor.outputRelativePath,
                       "Workbench/Exports/Poster.png")
        XCTAssertEqual(claim.descriptor.imageSettings?.format, "png")
        XCTAssertEqual(claim.descriptor.imageSettings?.width, 64)
        XCTAssertEqual(claim.descriptor.projectRevision, loaded.revision)
        let output = try writeOutput(claim.descriptor)
        XCTAssertEqual(try complete(
            mailbox, claim: claim,
            receipt: imageReceipt(claim.descriptor, output: output)), 0)

        let receipt = try await task.value
        XCTAssertEqual(receipt.url.standardizedFileURL,
                       output.url.standardizedFileURL)
        XCTAssertEqual(receipt.width, 64)
        XCTAssertEqual(receipt.height, 48)
        XCTAssertEqual(receipt.format, "png")
        XCTAssertEqual(receipt.byteCount, output.byteCount)
        XCTAssertEqual(G09R2SnapshotLeases.shared.pinnedCount(epoch: epoch), 0)
        XCTAssertTrue(mailbox.drainStatus(epoch: epoch).drained)
    }

    func testVideoExportMapsOnlyVerifiedReceiptFacts() async throws {
        try await makeFixture()
        let project = try await createProject(
            name: "Movie", kind: .video, width: 640, height: 360,
            frameRate: 30)
        let loaded = try await authorizeAndLoad(project.id)
        let options = VideoExportOptions(
            codec: .h264, width: 640, height: 360,
            frameRate: 30, quality: 0.9, fileName: "Movie")
        let host = try XCTUnwrap(self.host)
        let task = Task {
            try await host.exportVideo(
                project: loaded, options: options,
                relativeOutput: "Workbench/Exports/Movie.mp4",
                cancellation: nil)
        }
        let claim = try await waitForClaim(mailbox)
        XCTAssertEqual(claim.descriptor.kind, .video)
        XCTAssertEqual(claim.descriptor.videoSettings?.codecMime, "video/avc")
        let output = try writeOutput(claim.descriptor)
        let receipt = G09R2MediaExportReceiptDTO(
            binding: G09R2MediaExportReceiptBindingDTO(
                projectID: claim.descriptor.projectID,
                mediaRootPath: claim.descriptor.mediaRootPath,
                projectRevision: claim.descriptor.projectRevision,
                timelineDigest: claim.descriptor.timelineDigest,
                attemptID: claim.descriptor.attemptID),
            kind: .video,
            outputRelativePath: claim.descriptor.outputRelativePath,
            mimeType: "video/mp4",
            byteCount: output.byteCount,
            sha256: output.sha256,
            verification: G09R2ExportVerificationDTO(
                playable: true, decodedDurationSeconds: 2.5,
                width: 640, height: 360, audioTrackCount: 1,
                container: "mp4", codec: "video/avc"),
            completedAt: Date())
        XCTAssertEqual(try complete(mailbox, claim: claim, receipt: receipt), 0)
        let mapped = try await task.value
        XCTAssertEqual(mapped.url.standardizedFileURL,
                       output.url.standardizedFileURL)
        XCTAssertEqual(mapped.durationSeconds, 2.5)
        XCTAssertEqual(mapped.width, 640)
        XCTAssertEqual(mapped.height, 360)
        XCTAssertEqual(mapped.frameRate, 30)
        XCTAssertEqual(mapped.codec, "h264")
        XCTAssertTrue(mapped.hasAudio)
        XCTAssertEqual(mapped.byteCount, output.byteCount)
    }

    func testUnverifiedReceiptFailureAndUnknownOutcomeAreTruthful() async throws {
        try await makeFixture(exportAwaitSeconds: 2)
        let project = try await createProject()
        try await addTextLayer(project.id)
        let loaded = try await authorizeAndLoad(project.id)
        let options = ImageExportOptions(
            format: .png, width: 32, height: 32, quality: 1,
            preserveTransparency: true, stripMetadata: true,
            fileName: "Fail")
        let host = try XCTUnwrap(self.host)
        let failing = Task {
            try await host.exportImage(
                project: loaded, options: options,
                relativeOutput: "Workbench/Exports/Fail.png")
        }
        let failedClaim = try await waitForClaim(mailbox)
        var failed = G09R2RenderTicketReplyDTO(
            ticketID: failedClaim.descriptor.ticketID,
            status: .failed, receipt: nil,
            errorCode: "unsupportedTransition", completedAt: Date(),
            replyByteCount: 0)
        var failedData = try G09CreativeWire.encoder().encode(failed)
        failed.replyByteCount = failedData.count
        failedData = try G09CreativeWire.encoder().encode(failed)
        if failed.replyByteCount != failedData.count {
            failed.replyByteCount = failedData.count
            failedData = try G09CreativeWire.encoder().encode(failed)
        }
        XCTAssertEqual(mailbox.complete(
            ticketID: failedClaim.descriptor.ticketID,
            claimToken: failedClaim.claimToken,
            replyData: failedData), 0)
        do {
            _ = try await failing.value
            XCTFail("a failed ticket must not produce a receipt")
        } catch {
            assertValidationFailure(error)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: failedClaim.descriptor.mediaRootPath)
                .appendingPathComponent(failedClaim.descriptor.outputRelativePath)
                .path))

        // Unknown: the consumer claims but never settles. The tool reports an
        // unknown outcome and must NOT submit a second export.
        let unknown = Task {
            try await host.exportImage(
                project: loaded, options: options,
                relativeOutput: "Workbench/Exports/Fail.png")
        }
        // The previous attempt left no file, so the same exact name can be
        // submitted again by a NEW call; only the unknown call itself must not
        // retry.
        let unknownClaim = try await waitForClaim(mailbox)
        do {
            _ = try await unknown.value
            XCTFail("an unsettled ticket must be reported as unknown")
        } catch {
            assertValidationFailure(error)
        }
        XCTAssertTrue(mailbox.isLive(ticketID: unknownClaim.descriptor.ticketID))
        // The unknown ticket still owns its snapshot pin; a later authenticated
        // close drains it and releases the snapshot.
        XCTAssertGreaterThan(
            G09R2SnapshotLeases.shared.pinnedCount(epoch: epoch), 0)
        XCTAssertEqual(mailbox.close(
            ticketID: unknownClaim.descriptor.ticketID,
            claimToken: unknownClaim.claimToken), 0)
        XCTAssertEqual(G09R2SnapshotLeases.shared.pinnedCount(epoch: epoch), 0)
    }

    func testCancellationStopsClaimedTicketAndRootStopDrains() async throws {
        try await makeFixture()
        let project = try await createProject(
            name: "Cancel", kind: .video, width: 320, height: 180,
            frameRate: 30)
        let loaded = try await authorizeAndLoad(project.id)
        let token = CancellationToken()
        let options = VideoExportOptions(
            codec: .h264, width: 320, height: 180,
            frameRate: 30, quality: 0.9, fileName: "Cancel")
        let host = try XCTUnwrap(self.host)
        let task = Task {
            try await host.exportVideo(
                project: loaded, options: options,
                relativeOutput: "Workbench/Exports/Cancel.mp4",
                cancellation: token)
        }
        let claim = try await waitForClaim(mailbox)
        token.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled export must not produce a receipt")
        } catch let error as FloeError {
            XCTAssertEqual(error, .cancelled)
        }
        // The real platform worker is told to stop and still settles once.
        XCTAssertTrue(mailbox.shouldStop(
            ticketID: claim.descriptor.ticketID,
            claimToken: claim.claimToken))
        XCTAssertEqual(mailbox.close(
            ticketID: claim.descriptor.ticketID,
            claimToken: claim.claimToken), 0)
        XCTAssertTrue(mailbox.drainStatus(epoch: epoch).drained)
        XCTAssertEqual(G09R2SnapshotLeases.shared.pinnedCount(epoch: epoch), 0)
    }

    func testRootStopWhileClaimedKeepsRootBoundUntilAcknowledged() async throws {
        try await makeFixture()
        let project = try await createProject()
        try await addTextLayer(project.id)
        let loaded = try await authorizeAndLoad(project.id)
        let options = ImageExportOptions(
            format: .png, width: 32, height: 32, quality: 1,
            preserveTransparency: true, stripMetadata: true,
            fileName: "RootStop")
        let host = try XCTUnwrap(self.host)
        let task = Task {
            try await host.exportImage(
                project: loaded, options: options,
                relativeOutput: "Workbench/Exports/RootStop.png")
        }
        let claim = try await waitForClaim(mailbox)
        // The service's aggregate drain uses the process-wide mailbox/pin
        // registries. This test's host mailbox is private for isolation, so
        // the aggregate must still report NOT drained because the claimed
        // ticket pins the shared snapshot lease. The private mailbox itself
        // is then stopped exactly as the App's root-stop order would.
        let firstDrain = await service.r2BeginRootStop(epoch: epoch)
        XCTAssertFalse(firstDrain)
        XCTAssertFalse(mailbox.prepareRootStop(epoch: epoch))
        XCTAssertEqual(mailbox.drainStatus(epoch: epoch).claimed, 1)
        do {
            _ = try await task.value
            XCTFail("a root-stopping export must not produce a receipt")
        } catch {
            assertValidationFailure(error)
        }
        XCTAssertTrue(mailbox.shouldStop(
            ticketID: claim.descriptor.ticketID,
            claimToken: claim.claimToken))
        XCTAssertEqual(mailbox.close(
            ticketID: claim.descriptor.ticketID,
            claimToken: claim.claimToken), 0)
        let secondDrain = await service.r2BeginRootStop(epoch: epoch)
        XCTAssertTrue(secondDrain)
        XCTAssertEqual(G09R2SnapshotLeases.shared.pinnedCount(epoch: epoch), 0)
    }

    // MARK: - Discovery

    func testDiscoveryIsHiddenUntilALiveConsumerAndHidesOnStop() async throws {
        try await makeFixture()
        let registry = ToolRunnerRegistry()
        let availability = G09R2MediaToolAvailability(mailbox: mailbox)
        XCTAssertTrue(G09R2MediaToolRegistration.install(
            service: service, registry: registry, availability: availability,
            mailbox: mailbox, proposals: proposals, grants: grants))
        func installed() -> Bool {
            registry.allDescriptors.contains { $0.name == MediaProjectTool.name }
        }
        XCTAssertFalse(installed(), "no accepted epoch is bound yet")
        XCTAssertNil(registry.runner(named: MediaProjectTool.name))
        let unbound = G09R2MediaToolRegistration.capability(availability: availability)
        XCTAssertFalse(unbound.mergeLayers)
        XCTAssertFalse(unbound.copySelection)
        XCTAssertFalse(unbound.fillSelection)
        XCTAssertFalse(unbound.cutSelection)
        XCTAssertEqual(unbound.enrichmentReasons["merge_layers"], "notBound")

        availability.markBound(epoch: epoch)
        XCTAssertTrue(installed())
        XCTAssertNotNil(registry.runner(named: MediaProjectTool.name))
        let ready = G09R2MediaToolRegistration.capability(availability: availability)
        XCTAssertTrue(ready.mergeLayers)
        XCTAssertTrue(ready.copySelection)
        XCTAssertTrue(ready.fillSelection)
        XCTAssertTrue(ready.cutSelection)
        XCTAssertTrue(ready.enrichmentReasons.isEmpty)

        availability.markStopping(epoch: epoch)
        XCTAssertFalse(installed(), "root stop must hide the tool")
        let stopping = G09R2MediaToolRegistration.capability(availability: availability)
        XCTAssertFalse(stopping.mergeLayers)
        XCTAssertFalse(stopping.copySelection)
        XCTAssertEqual(stopping.reason, "rootStopping")
        availability.markBound(epoch: epoch)
        availability.setEnabled(false)
        XCTAssertFalse(installed(), "an explicit disable must hide the tool")
        availability.setEnabled(true)
        XCTAssertTrue(installed())

        // Retiring the renderer (mailbox close) hides it even while the host
        // believes the epoch is bound. There is no claimed ticket here, so
        // the mailbox itself is drained (true); visibility still hides.
        XCTAssertTrue(mailbox.prepareRootStop(epoch: epoch))
        XCTAssertFalse(installed())

        // A new consumer generation is not advertised merely because the
        // mailbox accepted a higher bind: a real epoch-exact heartbeat is
        // required before media.project becomes visible again.
        let nextEpoch = epoch + 1
        XCTAssertTrue(mailbox.bind(epoch: nextEpoch))
        availability.markBound(epoch: nextEpoch)
        XCTAssertFalse(installed())
        XCTAssertTrue(mailbox.consumerHeartbeat(epoch: nextEpoch))
        XCTAssertTrue(installed())
        availability.markUnbound(epoch: nextEpoch)
        XCTAssertFalse(installed())
    }

    func testPersistAppliedProjectKeepsGeneratedCaptionIdentity() async throws {
        try await makeFixture()
        let project = try await createProject(
            name: "Captions", kind: .video, width: 640, height: 360,
            frameRate: 30)
        let base = try await authorizeAndLoad(project.id)
        let caption = CaptionSegment(
            id: UUID(), start: 0.5, end: 1.5, text: "Hello",
            source: .manual)
        let proposal = MediaProposal(
            id: UUID(), projectID: project.id, baseRevision: base.revision,
            summary: "Add caption",
            commands: [.addCaption(caption)])
        try await host.storeProposal(proposal)
        _ = try await host.loadProposal(id: proposal.id)
        var live = base
        try MediaProposalGate.applyAuthorized(
            proposal, grant: .authorized, to: &live)
        try await host.persistProject(live, expectedRevision: base.revision)
        let reopenedValue = try await host.loadProject(id: project.id)
        let reopened = try XCTUnwrap(reopenedValue)
        let stored = try XCTUnwrap(reopened.videoTimeline?.captions.first)
        XCTAssertEqual(reopened.revision, base.revision + 1)
        XCTAssertEqual(stored.id, caption.id)
        XCTAssertEqual(stored.text, "Hello")
        XCTAssertLessThan(
            abs(reopened.updatedAt.timeIntervalSince(live.updatedAt)), 1.0)
        // The exact authorized applied project is what the CAS reopened;
        // no command replay may substitute a different UUID/Date.
        XCTAssertEqual(
            try MediaProjectStore.canonicalContentData(reopened),
            try MediaProjectStore.canonicalContentData(live))
    }

    // MARK: - Enrichment

    func testMeasureLayersReadsRealAssetDimensionsAndRefusesUnsupported() async throws {
        try await makeFixture()
        let project = try await createProject(width: 200, height: 200)
        let assetID = UUID()
        let asset = MediaAssetReference(
            id: assetID, kind: .image,
            relativePath: "Workbench/Assets/photo.png",
            originalName: "photo.png", byteCount: 33,
            contentHash: nil, metadata: nil)
        var png = Data()
        png.append(contentsOf: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(contentsOf: [0, 0, 0, 13])
        png.append(contentsOf: Array("IHDR".utf8))
        png.append(contentsOf: [0, 0, 0, 100]) // width 100
        png.append(contentsOf: [0, 0, 0, 50])  // height 50
        png.append(contentsOf: [8, 6, 0, 0, 0])
        let loadedBase = try await cluster.media.load(
            id: project.id, requested: G09StorageLayerDTO(kind: .appOwned),
            origin: origin)
        let root = loadedBase.storage.rootURL
        let assetURL = root.appendingPathComponent(asset.relativePath)
        try FileManager.default.createDirectory(
            at: assetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: assetURL)
        var imageLayer = ImageLayer(
            kind: .image, name: "Photo", assetID: assetID)
        imageLayer.crop = nil
        var textLayer = ImageLayer(kind: .text, name: "Title")
        textLayer.text = ImageTextContent(text: "Hello")
        _ = try await cluster.media.applyShared(
            projectID: project.id, expectedRevision: 0,
            sessionToken: "setup.session", storage: G09StorageLayerDTO(kind: .appOwned),
            origin: origin, opID: "measure-setup",
            commands: [.addAsset(asset), .addImageLayer(imageLayer), .addImageLayer(textLayer)])
        let loaded = try await authorizeAndLoad(project.id)
        let sizes = try await host.measureLayers(
            project: loaded,
            layerIDs: [imageLayer.id, textLayer.id])
        XCTAssertEqual(sizes.count, 2)
        XCTAssertEqual(sizes[0].layerID, imageLayer.id)
        XCTAssertEqual(sizes[0].width, 200, accuracy: 0.001)
        XCTAssertEqual(sizes[0].height, 100, accuracy: 0.001)
        XCTAssertEqual(sizes[1].layerID, textLayer.id)
        XCTAssertEqual(sizes[1].width, 200, accuracy: 0.001)
        XCTAssertEqual(sizes[1].height, 200, accuracy: 0.001)

        // Unsupported container: a typed honest refusal, never a guessed size.
        let unsupportedID = UUID()
        let unsupported = MediaAssetReference(
            id: unsupportedID, kind: .image,
            relativePath: "Workbench/Assets/photo.heic",
            originalName: "photo.heic", byteCount: 8,
            contentHash: nil, metadata: nil)
        let heicURL = root.appendingPathComponent(unsupported.relativePath)
        try Data(repeating: 0, count: 8).write(to: heicURL)
        var heicLayer = ImageLayer(
            kind: .image, name: "HEIC", assetID: unsupportedID)
        heicLayer.crop = nil
        _ = try await cluster.media.applyShared(
            projectID: project.id, expectedRevision: 1,
            sessionToken: "setup.session", storage: G09StorageLayerDTO(kind: .appOwned),
            origin: origin, opID: "measure-setup-2",
            commands: [.addAsset(unsupported), .addImageLayer(heicLayer)])
        let extended = try await authorizeAndLoad(project.id)
        do {
            _ = try await host.measureLayers(
                project: extended, layerIDs: [heicLayer.id])
            XCTFail("an unsupported asset format must be refused")
        } catch {
            assertValidationFailure(error)
        }
    }

    func testInvalidMergeAndCopyInputsReturnTypedRefusalWithoutWriting() async throws {
        try await makeFixture()
        let project = try await createProject()
        let loaded = try await authorizeAndLoad(project.id)
        do {
            _ = try await host.renderMergeAsset(
                project: loaded, layerIDs: [UUID()], name: nil)
            XCTFail("a one-layer merge is invalid and must be refused before rendering")
        } catch {
            assertValidationFailure(error)
        }
        do {
            _ = try await host.renderCopySelectionAsset(
                project: loaded, sourceLayerID: UUID())
            XCTFail("a missing copy source must be refused before rendering")
        } catch {
            assertValidationFailure(error)
        }
    }
}
