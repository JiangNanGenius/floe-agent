// FloeWorkbench — Proposal confirmation, grant, and tool behavior tests.

import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeWorkbench

@Suite("Media proposals, grants and the media.project tool")
struct MediaProposalToolTests {
    // MARK: Test host

    actor Host: MediaProjectHost {
        var projects: [UUID: MediaProject]
        var proposals: [UUID: MediaProposal] = [:]
        let grants: MediaProposalGrantStore
        var exports: [String] = []
        var failExport = false
        /// Ownership this host will accept; other environments/tasks refuse.
        var permittedWorkspacePath: String? = "/tmp/workbench-task"
        var permittedEnvironmentID: String? = "task-env"

        init(project: MediaProject, grants: MediaProposalGrantStore) {
            self.projects = [project.id: project]
            self.grants = grants
        }

        func authorizeAccess(projectID: UUID, access: MediaProjectAccess) async throws {
            guard let target = projects[projectID] else { return }
            // A project that records ownership requires the matching context;
            // absent context is refused, not treated as a wildcard.
            if let recorded = target.taskWorkspacePath, !recorded.isEmpty {
                guard let requested = access.workspacePath, requested == recorded else {
                    throw FloeError.unauthorized
                }
            } else if let permitted = permittedWorkspacePath {
                guard let requested = access.workspacePath, requested == permitted else {
                    throw FloeError.unauthorized
                }
            }
            if let recorded = target.environmentID {
                guard access.environmentID == recorded else { throw FloeError.unauthorized }
            } else if let permitted = permittedEnvironmentID {
                guard access.environmentID == permitted else { throw FloeError.unauthorized }
            }
            if ["chat", "canvas"].contains(target.ownerKind) {
                guard access.ownerID == target.ownerID,
                      access.ownerKind == target.ownerKind else { throw FloeError.unauthorized }
            }
        }

        func loadProject(id: UUID) async throws -> MediaProject? { projects[id] }

        func persistProject(_ project: MediaProject, expectedRevision: Int64?) async throws {
            if let expectedRevision, let onDisk = projects[project.id], onDisk.revision != expectedRevision {
                throw FloeError.validationFailed("revision conflict")
            }
            projects[project.id] = project
        }

        func storeProposal(_ proposal: MediaProposal) async throws { proposals[proposal.id] = proposal }
        func loadProposal(id: UUID) async throws -> MediaProposal? { proposals[id] }
        func removeProposal(id: UUID) async throws { proposals.removeValue(forKey: id) }

        func consumeGrant(grantID: String, proposalID: UUID, projectID: UUID,
                          revision: Int64) async -> MediaGrantDecision {
            await grants.consume(grantID: grantID, projectID: projectID,
                                 proposalID: proposalID, revision: revision)
        }

        func exportVideo(project: MediaProject, options: VideoExportOptions,
                         relativeOutput: String, cancellation: CancellationToken?) async throws -> WorkbenchVideoExportReceipt {
            if failExport { throw FloeError.internalError("no enabled video provider") }
            exports.append(relativeOutput)
            return WorkbenchVideoExportReceipt(url: URL(fileURLWithPath: "/tmp/\(options.fileName).mp4"),
                                               durationSeconds: 1, width: options.width, height: options.height,
                                               frameRate: options.frameRate, codec: options.codec.rawValue,
                                               hasAudio: true, byteCount: 10)
        }

        func exportImage(project: MediaProject, options: ImageExportOptions,
                         relativeOutput: String) async throws -> WorkbenchImageExportReceipt {
            exports.append(relativeOutput)
            return WorkbenchImageExportReceipt(url: URL(fileURLWithPath: "/tmp/\(options.fileName).png"),
                                               width: options.width ?? 10, height: options.height ?? 10,
                                               format: options.format.rawValue, byteCount: 10)
        }
    }

    private func makeProject() -> MediaProject {
        let asset = MediaAssetReference(kind: .video, relativePath: "v.mp4", originalName: "v.mp4",
                                        metadata: MediaAssetMetadata(durationSeconds: 10, frameRate: 30))
        var project = MediaProject(kind: .video, name: "Tool", canvas: MediaCanvas(width: 640, height: 360, frameRate: 30),
                                   assets: [asset], sourceAssetID: asset.id)
        project.videoTimeline = VideoTimeline(clips: [VideoClip(assetID: asset.id, trimStart: 0, trimEnd: 4)])
        return project
    }

    private func context(workspacePath: String? = "/tmp/workbench-task",
                         environmentID: String? = "task-env") -> ToolContext {
        ToolContext(runID: UUID(),
                    workspaceRootURL: workspacePath.map { URL(fileURLWithPath: $0) },
                    cancellation: CancellationToken(),
                    environmentID: environmentID)
    }

    // MARK: Tests

    @Test func readReturnsRevisionSummary() async throws {
        let grants = MediaProposalGrantStore()
        let project = makeProject()
        let host = Host(project: project, grants: grants)
        let tool = MediaProjectTool(host: host)
        let output = try await tool.execute(
            MediaProjectArguments(action: .read, projectID: project.id, summary: nil, commands: nil,
                                  proposalID: nil, grantID: nil, export: nil),
            context: context())
        #expect(output.summary.contains("revision: 0"))
        #expect(output.summary.contains("clips: 1"))
    }

    @Test func proposeRequiresUserActionAndDoesNotMutate() async throws {
        let grants = MediaProposalGrantStore()
        let project = makeProject()
        let host = Host(project: project, grants: grants)
        let tool = MediaProjectTool(host: host)
        let commands: [[String: AnyCodableValue]] = [
            ["type": .string("update_clip"), "id": .string(project.videoTimeline!.clips[0].id.uuidString),
             "speed": .number(2)]
        ]
        let output = try await tool.execute(
            MediaProjectArguments(action: .propose, projectID: project.id, summary: "Speed up",
                                  commands: commands, proposalID: nil, grantID: nil, export: nil),
            context: context())
        #expect(output.requiresUserAction, "proposals must wait for explicit user acceptance")
        let live = try #require(await host.loadProject(id: project.id))
        #expect(live.revision == 0, "propose must not change the project")
        #expect(live.videoTimeline?.clips[0].speed == 1)
    }

    @Test func applyWithoutGrantIsRefused() async throws {
        let grants = MediaProposalGrantStore()
        let project = makeProject()
        let host = Host(project: project, grants: grants)
        let tool = MediaProjectTool(host: host)
        let commands: [[String: AnyCodableValue]] = [
            ["type": .string("update_clip"), "id": .string(project.videoTimeline!.clips[0].id.uuidString),
             "speed": .number(2)]
        ]
        _ = try await tool.execute(
            MediaProjectArguments(action: .propose, projectID: project.id, summary: "Speed up",
                                  commands: commands, proposalID: nil, grantID: nil, export: nil),
            context: context())
        // A fabricated grant id must be refused.
        let stored = await host.proposalList()
        let proposalID = try #require(stored.first?.id)
        await #expect(throws: (any Error).self) {
            try await tool.execute(
                MediaProjectArguments(action: .apply, projectID: project.id, summary: nil,
                                      commands: nil, proposalID: proposalID,
                                      grantID: "fabricated-token", export: nil),
                context: context())
        }
        let live = try #require(await host.loadProject(id: project.id))
        #expect(live.revision == 0)
    }

    @Test func applyWithTrustedGrantAppliesOneTransaction() async throws {
        let grants = MediaProposalGrantStore()
        let project = makeProject()
        let host = Host(project: project, grants: grants)
        let tool = MediaProjectTool(host: host)
        let commands: [[String: AnyCodableValue]] = [
            ["type": .string("update_clip"), "id": .string(project.videoTimeline!.clips[0].id.uuidString),
             "speed": .number(2)],
            ["type": .string("add_caption"),
             "start": .number(0), "end": .number(2), "text": .string("你好")]
        ]
        _ = try await tool.execute(
            MediaProjectArguments(action: .propose, projectID: project.id, summary: "Speed up and caption",
                                  commands: commands, proposalID: nil, grantID: nil, export: nil),
            context: context())
        let stored = await host.proposalList()
        let proposal = try #require(stored.first)
        // Only the UI may mint a grant; here we simulate the user tap.
        let grant = await grants.issueGrant(projectID: project.id, proposalID: proposal.id,
                                            revision: project.revision)
        let output = try await tool.execute(
            MediaProjectArguments(action: .apply, projectID: project.id, summary: nil, commands: nil,
                                  proposalID: proposal.id, grantID: grant.grantID, export: nil),
            context: context())
        #expect(output.summary.contains("revision 1"))
        let live = try #require(await host.loadProject(id: project.id))
        #expect(live.videoTimeline?.clips[0].speed == 2)
        #expect(live.videoTimeline?.captions.count == 1)
        #expect(live.undoHistory.count == 1, "proposal must be one undoable transaction")

        // Grant is single-use: a second apply fails.
        await #expect(throws: (any Error).self) {
            try await tool.execute(
                MediaProjectArguments(action: .apply, projectID: project.id, summary: nil, commands: nil,
                                      proposalID: proposal.id, grantID: grant.grantID, export: nil),
                context: context())
        }
    }

    @Test func manualChangeRejectsStaleProposal() async throws {
        let grants = MediaProposalGrantStore()
        let project = makeProject()
        let host = Host(project: project, grants: grants)
        let tool = MediaProjectTool(host: host)
        let clipID = project.videoTimeline!.clips[0].id
        let commands: [[String: AnyCodableValue]] = [
            ["type": .string("update_clip"), "id": .string(clipID.uuidString), "speed": .number(2)]
        ]
        _ = try await tool.execute(
            MediaProjectArguments(action: .propose, projectID: project.id, summary: "Speed",
                                  commands: commands, proposalID: nil, grantID: nil, export: nil),
            context: context())
        let proposal = try #require(await host.proposalList().first)
        let grant = await grants.issueGrant(projectID: project.id, proposalID: proposal.id,
                                            revision: project.revision)
        // A manual edit lands first (advancing the revision).
        var manual = project
        try MediaTransactions.apply(.updateClip(id: clipID, trimStart: nil, trimEnd: 3.0, speed: nil,
                                                volume: nil, isMuted: nil, rotationDegrees: nil,
                                                crop: .unchanged, leadingTransition: nil,
                                                transitionDuration: nil),
                                    to: &manual)
        try await host.persistProject(manual, expectedRevision: project.revision)

        await #expect(throws: (any Error).self) {
            try await tool.execute(
                MediaProjectArguments(action: .apply, projectID: project.id, summary: nil, commands: nil,
                                      proposalID: proposal.id, grantID: grant.grantID, export: nil),
                context: context())
        }
        let live = try #require(await host.loadProject(id: project.id))
        #expect(live.videoTimeline?.clips[0].speed == 1, "stale proposal must not change the project")
    }

    @Test func grantExpiryAndRevisionMismatchAreDistinguished() async throws {
        let store = MediaProposalGrantStore(timeToLive: 60)
        let projectID = UUID()
        let proposalID = UUID()
        let grant = await store.issueGrant(projectID: projectID, proposalID: proposalID, revision: 4)
        // Revision moved on: mismatch, not authorized.
        let mismatch = await store.consume(grantID: grant.grantID, projectID: projectID,
                                           proposalID: proposalID, revision: 5)
        #expect(mismatch == .revisionMismatch(expected: 4, actual: 5))
        // Correct revision after a failed attempt still works (consume only
        // marks consumed on success).
        let ok = await store.consume(grantID: grant.grantID, projectID: projectID,
                                     proposalID: proposalID, revision: 4)
        #expect(ok == .authorized)
        // Second use refused.
        let second = await store.consume(grantID: grant.grantID, projectID: projectID,
                                         proposalID: proposalID, revision: 4)
        #expect(second == .alreadyConsumed)
        // Unknown grant ids are refused.
        let unknown = await store.consume(grantID: "nope", projectID: projectID,
                                          proposalID: proposalID, revision: 4)
        #expect(unknown == .unknownGrant)

        let expiring = MediaProposalGrantStore(timeToLive: -1)
        let expiredGrant = await expiring.issueGrant(projectID: projectID, proposalID: proposalID, revision: 1)
        let expired = await expiring.consume(grantID: expiredGrant.grantID, projectID: projectID,
                                             proposalID: proposalID, revision: 1)
        #expect(expired == .unknownGrant, "expired grants are swept and treated as unknown")
    }

    @Test func unknownCommandsAreRejectedNotIgnored() async throws {
        let grants = MediaProposalGrantStore()
        let host = Host(project: makeProject(), grants: grants)
        let tool = MediaProjectTool(host: host)
        let commands: [[String: AnyCodableValue]] = [["type": .string("delete_everything")]]
        await #expect(throws: (any Error).self) {
            try await tool.execute(
                MediaProjectArguments(action: .propose, projectID: makeProject().id, summary: "nope",
                                      commands: commands, proposalID: nil, grantID: nil, export: nil),
                context: context())
        }
    }

    @Test func unavailableExportReportsFailureWithoutSideEffects() async throws {
        let grants = MediaProposalGrantStore()
        let project = makeProject()
        let host = Host(project: project, grants: grants)
        await host.setFailExport(true)
        let tool = MediaProjectTool(host: host)
        let export: MediaExportArguments = try JSONDecoder().decode(MediaExportArguments.self, from: Data("""
        {"kind":"video","file_name":"movie","codec":"h264","frame_rate":30,"width":640,"height":360}
        """.utf8))
        await #expect(throws: (any Error).self) {
            try await tool.execute(
                MediaProjectArguments(action: .export, projectID: project.id, summary: nil, commands: nil,
                                      proposalID: nil, grantID: nil, export: export),
                context: context())
        }
        let exports = await host.exportList()
        #expect(exports.isEmpty)
    }

    @Test func imageExportRequiresExplicitFormat() async throws {
        let grants = MediaProposalGrantStore()
        let project = makeProject()
        let host = Host(project: project, grants: grants)
        let tool = MediaProjectTool(host: host)
        let export: MediaExportArguments = try JSONDecoder().decode(MediaExportArguments.self, from: Data("""
        {"kind":"image","file_name":"still"}
        """.utf8))
        await #expect(throws: (any Error).self) {
            try await tool.execute(
                MediaProjectArguments(action: .export, projectID: project.id, summary: nil, commands: nil,
                                      proposalID: nil, grantID: nil, export: export),
                context: context())
        }
    }

    @Test func ownershipEnforcementRefusesOtherEnvironmentOrTask() async throws {
        let grants = MediaProposalGrantStore()
        var project = makeProject()
        project.taskWorkspacePath = "/tmp/workbench-task"
        project.environmentID = "task-env"
        let host = Host(project: project, grants: grants)
        let tool = MediaProjectTool(host: host)
        let read = MediaProjectArguments(action: .read, projectID: project.id, summary: nil,
                                         commands: nil, proposalID: nil, grantID: nil, export: nil)

        // Wrong task workspace: refused before any read.
        await #expect(throws: (any Error).self) {
            try await tool.execute(read, context: context(workspacePath: "/tmp/other-task"))
        }
        // Wrong environment: refused.
        await #expect(throws: (any Error).self) {
            try await tool.execute(read, context: context(environmentID: "other-env"))
        }
        // Absent workspace/environment context must not bypass the recorded
        // ownership of a scoped project.
        await #expect(throws: (any Error).self) {
            try await tool.execute(read, context: context(workspacePath: nil))
        }
        await #expect(throws: (any Error).self) {
            try await tool.execute(read, context: context(environmentID: nil))
        }
        // Matching environment + task: allowed.
        let output = try await tool.execute(read, context: context())
        #expect(output.summary.contains("revision: 0"))

        // Export is gated by the same check.
        let export: MediaExportArguments = try JSONDecoder().decode(MediaExportArguments.self, from: Data("""
        {"kind":"video","file_name":"movie","codec":"h264","frame_rate":30,"width":640,"height":360}
        """.utf8))
        await #expect(throws: (any Error).self) {
            try await tool.execute(
                MediaProjectArguments(action: .export, projectID: project.id, summary: nil, commands: nil,
                                      proposalID: nil, grantID: nil, export: export),
                context: context(workspacePath: "/tmp/other-task"))
        }
    }
}

extension MediaProposalToolTests.Host {
    func proposalList() -> [MediaProposal] { Array(proposals.values) }
    func exportList() -> [String] { exports }
    func setFailExport(_ value: Bool) { failExport = value }
}
