// FloeWorkbenchTests — runtime-authorized automatic media.project apply.

import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeWorkbench

@Suite("media.project automatic apply authorization")
struct MediaAutomaticApplyTests {
    private func workspaceRoot() -> URL { URL(fileURLWithPath: "/tmp/workbench-task") }

    private func context(runID: UUID, conversationID: UUID, toolCallID: String = "call-1",
                         idempotencyKey: String = "key-1") -> ToolContext {
        ToolContext(runID: runID, toolCallID: toolCallID,
                    toolIdempotencyKey: idempotencyKey,
                    workspaceRootURL: workspaceRoot(),
                    cancellation: CancellationToken(),
                    environmentID: "task-env", conversationID: conversationID)
    }

    private func makeProject() -> MediaProject {
        let asset = MediaAssetReference(kind: .video, relativePath: "v.mp4", originalName: "v.mp4",
                                        contentHash: "asset-hash-1",
                                        metadata: MediaAssetMetadata(durationSeconds: 10, frameRate: 30))
        var project = MediaProject(kind: .video, name: "Auto",
                                   canvas: MediaCanvas(width: 640, height: 360, frameRate: 30),
                                   assets: [asset], sourceAssetID: asset.id)
        project.videoTimeline = VideoTimeline(clips: [VideoClip(assetID: asset.id, trimStart: 0, trimEnd: 4)])
        return project
    }

    private func speedUpCommands(_ project: MediaProject) -> [MediaEditCommand] {
        [.updateClip(id: project.videoTimeline!.clips[0].id, trimStart: nil, trimEnd: nil, speed: 2,
                     volume: nil, isMuted: nil, rotationDegrees: nil, crop: .unchanged,
                     leadingTransition: nil, transitionDuration: nil)]
    }

    private func propose(_ tool: MediaProjectTool, project: MediaProject,
                         host: MediaProposalToolTests.Host,
                         context: ToolContext) async throws -> MediaProposal {
        let clipID = project.videoTimeline!.clips[0].id
        let commands: [[String: AnyCodableValue]] = [
            ["type": .string("update_clip"), "id": .string(clipID.uuidString), "speed": .number(2)]
        ]
        _ = try await tool.execute(
            MediaProjectArguments(action: .propose, projectID: project.id, summary: "Speed up",
                                  commands: commands, proposalID: nil, grantID: nil, export: nil),
            context: context)
        let stored = try #require(await host.proposalList().first)
        return stored
    }

    private func mintToken(args: MediaProjectArguments, runID: UUID, taskID: UUID,
                           toolCallID: String, idempotencyKey: String,
                           context: ToolContext) async throws -> RuntimeTaskAuthority {
        let payload = try MediaProjectTool.canonicalApprovedPayload(args)
        let evidence = RuntimeAuthorityEvidence(
            runID: runID, taskID: taskID,
            environmentBinding: RuntimeAuthorityDigest.environmentBinding(
                workspaceRootURL: workspaceRoot(), conversationID: taskID),
            canonicalTarget: MediaProjectTool.canonicalTarget(context: context),
            toolName: MediaProjectTool.name, operation: "apply", operationID: toolCallID,
            idempotencyKey: idempotencyKey, baseRevision: nil,
            payloadDigest: RuntimeAuthorityDigest.payloadDigest(payload),
            approvalGrantID: UUID())
        return await RuntimeAuthorityStore.shared.issue(evidence)
    }

    @Test("an authorized automatic apply commits, reopens and reports the verified snapshot")
    func authorizedAutomaticApply() async throws {
        let grants = MediaProposalGrantStore()
        let project = makeProject()
        let host = MediaProposalToolTests.Host(project: project, grants: grants)
        let tool = MediaProjectTool(host: host)
        let runID = UUID(), taskID = UUID()
        let baseContext = context(runID: runID, conversationID: taskID)
        let proposal = try await propose(tool, project: project, host: host, context: baseContext)

        var args = MediaProjectArguments(action: .apply, projectID: project.id, summary: nil,
                                         commands: nil, proposalID: proposal.id, grantID: nil,
                                         export: nil)
        let token = try await mintToken(args: args, runID: runID, taskID: taskID,
                                        toolCallID: "call-1", idempotencyKey: "key-1",
                                        context: baseContext)
        let authorizedContext = ToolContext(runID: runID, toolCallID: "call-1",
                                            toolIdempotencyKey: "key-1",
                                            workspaceRootURL: workspaceRoot(),
                                            cancellation: CancellationToken(),
                                            environmentID: "task-env", conversationID: taskID,
                                            runtimeAuthority: token)
        let output = try await tool.execute(args, context: authorizedContext)
        #expect(output.summary.contains("mode=automatic"))
        #expect(output.summary.contains("revision=1"))
        #expect(output.summary.contains("sourceAssetsUnchanged=true"))
        #expect(output.summary.contains("projectDigest="))

        let live = try #require(await host.loadProject(id: project.id))
        #expect(live.revision == 1)
        #expect(live.videoTimeline?.clips[0].speed == 2)
        #expect(await host.proposalList().isEmpty)
        // Referenced assets are untouched.
        #expect(MediaAutomaticVerification.assetHashes(live) == MediaAutomaticVerification.assetHashes(project))
    }

    @Test("apply without a grant and without runtime authority is refused with no mutation")
    func missingAuthorityRefused() async throws {
        let grants = MediaProposalGrantStore()
        let project = makeProject()
        let host = MediaProposalToolTests.Host(project: project, grants: grants)
        let tool = MediaProjectTool(host: host)
        let runID = UUID(), taskID = UUID()
        let baseContext = context(runID: runID, conversationID: taskID)
        let proposal = try await propose(tool, project: project, host: host, context: baseContext)
        let args = MediaProjectArguments(action: .apply, projectID: project.id, summary: nil,
                                         commands: nil, proposalID: proposal.id, grantID: nil,
                                         export: nil)
        do {
            _ = try await tool.execute(args, context: baseContext)
            Issue.record("apply must be refused without authority")
        } catch {
            #expect(String(describing: error).contains("runtime-approved call authority")
                || String(describing: error).contains("authority"))
        }
        let live = try #require(await host.loadProject(id: project.id))
        #expect(live.revision == 0)
        #expect(live.videoTimeline?.clips[0].speed == 1)
    }

    @Test("a token minted for a different project never authorizes this apply")
    func payloadMismatchRefused() async throws {
        let grants = MediaProposalGrantStore()
        let project = makeProject()
        let host = MediaProposalToolTests.Host(project: project, grants: grants)
        let tool = MediaProjectTool(host: host)
        let runID = UUID(), taskID = UUID()
        let baseContext = context(runID: runID, conversationID: taskID)
        let proposal = try await propose(tool, project: project, host: host, context: baseContext)
        var args = MediaProjectArguments(action: .apply, projectID: project.id, summary: nil,
                                         commands: nil, proposalID: proposal.id, grantID: nil,
                                         export: nil)
        let otherArgs = MediaProjectArguments(action: .apply, projectID: UUID(), summary: nil,
                                              commands: nil, proposalID: proposal.id, grantID: nil,
                                              export: nil)
        let token = try await mintToken(args: otherArgs, runID: runID, taskID: taskID,
                                        toolCallID: "call-1", idempotencyKey: "key-1",
                                        context: baseContext)
        let authorizedContext = ToolContext(runID: runID, toolCallID: "call-1",
                                            toolIdempotencyKey: "key-1",
                                            workspaceRootURL: workspaceRoot(),
                                            cancellation: CancellationToken(),
                                            environmentID: "task-env", conversationID: taskID,
                                            runtimeAuthority: token)
        _ = try? await tool.execute(args, context: authorizedContext)
        let live = try #require(await host.loadProject(id: project.id))
        #expect(live.revision == 0)
    }

    @Test("the gate refuses a mismatched commands digest and a stale revision")
    func gateChecks() throws {
        let project = makeProject()
        let proposal = MediaProposal(projectID: project.id, baseRevision: project.revision,
                                     summary: "s", commands: speedUpCommands(project))
        let goodDigest = MediaProposalGate.commandsDigest(proposal.commands)
        var bad = project
        let wrongCommands = MediaAutomaticAuthorization(
            runID: UUID(), taskID: nil, operationID: "c", idempotencyKey: "k",
            approvalGrantID: nil, canonicalTarget: "workspace:/tmp/x",
            baseRevision: project.revision, payloadDigest: "d",
            commandsDigest: String(repeating: "0", count: 64), proposalID: proposal.id)
        #expect(throws: MediaProposalError.self) {
            try MediaProposalGate.applyAutomatic(proposal, authorization: wrongCommands, to: &bad)
        }
        #expect(bad.revision == project.revision)

        let stale = MediaAutomaticAuthorization(
            runID: UUID(), taskID: nil, operationID: "c", idempotencyKey: "k",
            approvalGrantID: nil, canonicalTarget: "workspace:/tmp/x",
            baseRevision: project.revision + 3, payloadDigest: "d",
            commandsDigest: goodDigest, proposalID: proposal.id)
        #expect(throws: MediaProposalError.self) {
            try MediaProposalGate.applyAutomatic(proposal, authorization: stale, to: &bad)
        }

        let good = MediaAutomaticAuthorization(
            runID: UUID(), taskID: nil, operationID: "c", idempotencyKey: "k",
            approvalGrantID: nil, canonicalTarget: "document:mediaproject:\(project.id.uuidString.lowercased())",
            baseRevision: project.revision, payloadDigest: "d",
            commandsDigest: goodDigest, proposalID: proposal.id)
        try MediaProposalGate.applyAutomatic(proposal, authorization: good, to: &bad)
        #expect(bad.revision == project.revision + 1)
        #expect(bad.videoTimeline?.clips[0].speed == 2)
    }

    @Test("an authorization for another tool or operation is refused")
    func wrongToolRefused() throws {
        let project = makeProject()
        let proposal = MediaProposal(projectID: project.id, baseRevision: project.revision,
                                     summary: "s", commands: speedUpCommands(project))
        var bad = project
        let foreign = MediaAutomaticAuthorization(
            runID: UUID(), taskID: nil, operationID: "c", idempotencyKey: "k",
            approvalGrantID: nil, canonicalTarget: "workspace:/tmp/x",
            baseRevision: project.revision, payloadDigest: "d",
            commandsDigest: MediaProposalGate.commandsDigest(proposal.commands),
            proposalID: proposal.id, toolName: "document.office.edit", operation: "apply")
        #expect(throws: MediaProposalError.self) {
            try MediaProposalGate.applyAutomatic(proposal, authorization: foreign, to: &bad)
        }
        #expect(bad.revision == project.revision)
    }
}
