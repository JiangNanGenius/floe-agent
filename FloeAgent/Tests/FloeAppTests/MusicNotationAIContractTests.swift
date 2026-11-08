// SPDX-License-Identifier: MPL-2.0
// Real Music-owned Score service, opaque file and persistence contracts.
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
import FloePersistence
import FloeHeavyEditorSupport
import FloeHeavyEditorsHostAdapter
import FloeScoreKit
import FloeMusicCore
@testable import FloeApp

@Suite("Music-owned Score AI contract", .serialized)
@MainActor struct MusicNotationAIContractTests {
    @Test func companionReplayUsesTheParentAndCannotMintAccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("score-ai-reservation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = UUID(), stranger = UUID(), conversation = UUID()
        let access = try StudioDocumentAccess(root: directory)
        try await access.reserveCompanionCreation(operationKey: "score/run/call", digest: "exact-title", parentID: parent)
        let reopened = try StudioDocumentAccess(root: directory)
        try await reopened.reserveCompanionCreation(operationKey: "score/run/call", digest: "exact-title", parentID: parent)
        do {
            try await reopened.reserveCompanionCreation(operationKey: "score/run/call", digest: "changed-title", parentID: parent)
            Issue.record("Changed replay payload was accepted")
        } catch PersonalContentError.changedDocument {}
        do {
            try await reopened.reserveCompanionCreation(operationKey: "score/run/call", digest: "exact-title", parentID: stranger)
            Issue.record("A replay was rebound to a different parent")
        } catch PersonalContentError.changedDocument {}
        #expect(try await reopened.projectIDs(conversationID: conversation).isEmpty)
        #expect(try await !reopened.canAccess(conversationID: conversation, projectID: parent, editing: true))
    }
    private func context(environment: AppEnvironment, conversation: UUID, run: UUID, name: String?, call: String) throws -> ToolContext {
        var value = ToolContext(runID: run, toolCallID: call, allowedToolNames: MusicNotationAITools.names,
            serviceStorePaths: [TypedMutationContract.nativeStudioLibraryStoreKey: try PersonalContentLibrary.applicationRoot().path],
            cancellation: CancellationToken(), conversationID: conversation)
        value.executionToolName = name; value.frozenEffectiveCatalogNames = MusicNotationAITools.names
        return value
    }
    private func savedTask(_ body: @MainActor (AppEnvironment, UUID, UUID) async throws -> Void) async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let conversation = UUID(), run = UUID(), now = Date()
        try await environment.conversationStore.saveConversation(.init(id: conversation, title: "Score AI contract", createdAt: now, updatedAt: now))
        try await environment.conversationStore.setArchived(id: conversation, archived: true)
        try await environment.runStore.saveRun(.init(id: run, conversationID: conversation, state: "executing", goal: "Score AI contract", startedAt: now))
        do { try await body(environment, conversation, run) }
        catch { try? await environment.conversationStore.deleteConversation(id: conversation); throw error }
        try await environment.conversationStore.deleteConversation(id: conversation)
    }
    @Test func discoveryProvesTheSavedRunWithoutInventingAnExecutingName() async throws {
        try await savedTask { environment, conversation, run in
            var value = try context(environment: environment, conversation: conversation, run: run, name: nil, call: "discovery")
            #expect(try await environment.studioCoordinator.savedConversation(value) == conversation)
            do { _ = try await environment.studioCoordinator.conversation(value, allowedNames: MusicNotationAITools.names); Issue.record("Execution accepted a missing tool name") } catch {}
            value.temporaryReadOnly = true
            do { _ = try await environment.studioCoordinator.savedConversation(value); Issue.record("Temporary context discovered personal works") } catch {}
            value.temporaryReadOnly = false
            try await environment.runStore.updateRunState(id: run, state: "completed", endedAt: Date())
            do { _ = try await environment.studioCoordinator.savedConversation(value); Issue.record("Ended run retained document access") } catch {}
        }
    }
    @Test func opaqueAttachmentReadsTheOriginalAndRejectsPathsForeignOwnershipAndTampering() async throws {
        try await savedTask { environment, conversation, run in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("score-ai-source-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("original.musicxml"), bytes = Data("<score-partwise version=\"4.0\"/>".utf8)
            try bytes.write(to: url)
            let reference = AttachmentRef(conversationID: conversation, kind: .document, displayName: url.lastPathComponent,
                uti: "public.xml", byteCount: bytes.count, sha256: FloeDigest.sha256Hex(bytes), storage: .securityScopedBookmark,
                urlBookmark: try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
            try await environment.conversationStore.saveAttachment(reference)
            let value = try context(environment: environment, conversation: conversation, run: run, name: "score.import", call: "attachment")
            let validate: @MainActor @Sendable () async throws -> Void = { _ = try await environment.studioCoordinator.conversation(value, allowedNames: MusicNotationAITools.names) }
            let resolved = try await HeavyEditorTaskFileResolver.resolve("attachment:" + reference.id.uuidString,
                context: value, environment: environment, allowedExtensions: ["musicxml"], validate: validate)
            #expect(resolved.data == bytes)
            do { _ = try await HeavyEditorTaskFileResolver.resolve(url.path, context: value, environment: environment, allowedExtensions: ["musicxml"], validate: validate); Issue.record("A quoted host path became a source permission") } catch HeavyEditorError.invalidCommand {}
            try await savedTask { foreignEnvironment, foreignConversation, _ in
                var foreign = reference; foreign.id = UUID(); foreign.conversationID = foreignConversation
                try await foreignEnvironment.conversationStore.saveAttachment(foreign)
                do { _ = try await HeavyEditorTaskFileResolver.resolve("attachment:" + foreign.id.uuidString, context: value, environment: environment, allowedExtensions: ["musicxml"], validate: validate); Issue.record("A foreign attachment was read") } catch HeavyEditorError.wrongDocument {}
            }
            try Data("changed original".utf8).write(to: url)
            do { _ = try await HeavyEditorTaskFileResolver.resolve("attachment:" + reference.id.uuidString, context: value, environment: environment, allowedExtensions: ["musicxml"], validate: validate); Issue.record("Tampered bytes were accepted under an old digest") } catch PersonalContentPreviewError.sourceChanged {}
        }
    }
    private func invoke(_ name: String, args: EditorJSON, registry: ToolRunnerRegistry, template: ToolContext) async throws -> ToolExecutionOutput {
        var value = template
        value.executionToolName = name; value.toolCallID = "score-ai-" + UUID().uuidString
        value.runtimeAuthority = nil; value.approvalGrantID = nil
        let data = try args.data(), runner = try #require(registry.runner(named: name))
        if runner.descriptor.isSideEffecting {
            let approval = UUID(); value.approvalGrantID = approval
            var call = try ToolCall(id: value.toolCallID!, toolName: name, argumentsJSON: data, scope: value.scope)
            call.idempotencyKey = value.toolIdempotencyKey
            let binding = value.runtimeAuthorityBinding(toolName: name, operation: "apply",
                canonicalTarget: RuntimeAuthorityDigest.canonicalTarget(for: call, descriptor: runner.descriptor,
                    workspaceRootURL: value.workspaceRootURL, stagedDocument: value.canvasStagedDocument, serviceStorePaths: value.serviceStorePaths),
                baseRevision: RuntimeAuthorityDigest.baseRevision(in: data), payloadDigest: RuntimeAuthorityDigest.payloadDigest(data))
            // The trusted test host supplies the same issued binding used by
            // the runtime after its real approval result; never JSON authority.
            value.runtimeAuthority = await RuntimeAuthorityStore.shared.issue(.init(runID: binding.runID, taskID: binding.taskID,
                environmentBinding: binding.environmentBinding, canonicalTarget: binding.canonicalTarget, toolName: binding.toolName,
                operation: binding.operation, operationID: binding.operationID, idempotencyKey: binding.idempotencyKey,
                baseRevision: binding.baseRevision, payloadDigest: binding.payloadDigest, approvalGrantID: approval))
        }
        return try await runner.execute(argumentsJSON: data, context: value)
    }
    private func json(_ value: ToolExecutionOutput) throws -> EditorJSON { try EditorJSON.decode(Data((value.capturedOutput ?? value.summary).utf8)) }
    @Test func sixToolsRetainTheMusicOriginalAndReturnARealFileAttachment() async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let record = try await PersonalContentService.shared.create(kind: .music, title: "Score AI private contract " + String(UUID().uuidString.prefix(8)))
        let conversation = try await environment.studioCoordinator.assistant(for: record), run = UUID()
        try await environment.runStore.saveRun(.init(id: run, conversationID: conversation, state: "executing", goal: "Music-owned Score AI", startedAt: Date()))
        let location = try await PersonalContentService.shared.library().resolve(record.id)
        let musicRoot = location.url.appendingPathComponent("Music"), before = try MusicNotationPackage.capture(root: musicRoot, parentID: record.id)
        let registry = ToolRunnerRegistry(), host = MusicNotationAITools(environment: environment)
        try host.register(in: registry)
        let base = try context(environment: environment, conversation: conversation, run: run, name: nil, call: "initial")
        var childRevision: Double = 0
        func perform(_ tool: String, _ command: String, _ arguments: EditorJSON = .object([:])) async throws -> ToolExecutionOutput {
            let output = try await invoke(tool, args: .object(["projectID": .string(record.id.uuidString), "baseRevision": .number(childRevision), "command": .string(command), "arguments": arguments]), registry: registry, template: base)
            childRevision = try #require(try json(output)["baseRevision"].number)
            return output
        }
        do {
            // Reads must not construct missing notation.
            do { _ = try await invoke("score.describe", args: .object(["projectID": .string(record.id.uuidString)]), registry: registry, template: base); Issue.record("Describe created a missing score") } catch PersonalContentError.missingDocument {}
            #expect(try MusicNotationPackage.readOriginal(root: musicRoot, parentID: record.id) == nil)
            let created = try json(try await invoke("score.create", args: .object(["title": .string("Owned score")]), registry: registry, template: base))
            #expect(created["projectID"].string?.lowercased() == record.id.uuidString.lowercased())
            childRevision = try #require(created["baseRevision"].number)
            let description = try json(try await invoke("score.describe", args: .object(["projectID": .string(record.id.uuidString), "command": .string("score.edit.insert")]), registry: registry, template: base))
            #expect(description["revisionScope"] == .string("score"))
            #expect(description["form"]["fields"].array.contains(where: { $0["key"] == .string("part") }))
            _ = try await perform("score.invoke", "score.project.template", .object(["template": .string("piano"), "bars": .number(4)]))
            _ = try await perform("score.invoke", "score.edit.insert", .object(["pitch": .string("C4"), "type": .string("quarter"), "onset": .string("0"), "voice": .number(1), "staff": .number(1)]))
            _ = try await perform("score.invoke", "score.edit.chord", .object(["pitches": .string("E4,G4")]))
            _ = try await perform("score.invoke", "score.edit.select", .object(["from": .number(1), "to": .number(1), "voice": .string("1")]))
            _ = try await perform("score.invoke", "score.edit.transpose", .object(["semitones": .number(2)]))
            let timing = try json(try await perform("score.query", "score.playback.compile"))["result"]
            let part = try #require(timing["parts"].array.first?["id"].string)
            let pitches = timing["events"].array.filter { $0["part"].string == part && $0["measure"].number == 1 && $0["pass"].number == 1 && $0["staff"].number == 1 && $0["voice"].string == "1" && $0["startQuarter"].number == 0 }.compactMap { $0["pitch"].number }
            #expect(pitches == [62, 66, 69])
            let output = try await perform("score.export", "score.export", .object(["format": .string("midi")]))
            let receipt = try #require(output.outputFiles.first)
            #expect(output.outputFiles.count == 1 && receipt.producerTool == "score.export" && receipt.taskID == conversation)
            let exported = try json(output)["exports"].array
            #expect(exported.count == output.outputFiles.count)
            for (entry, file) in zip(exported, output.outputFiles) {
                #expect(entry["fileID"] == .string("output:\(file.runID.uuidString):\(file.outputID)"))
                #expect(entry["name"] == .string(file.displayName) && entry["sha256"] == .string(file.sha256))
                #expect(entry["byteCount"] == .number(Double(file.byteCount)))
                #expect(entry["managedFileID"].string?.hasPrefix("music:") == true)
            }
            guard case .verified(let snapshot) = RunOutputSnapshotStore.verify(receipt) else { Issue.record("No real output snapshot"); throw HeavyEditorError.invalidDocument }
            #expect(try Data(contentsOf: snapshot).prefix(4) == Data("MThd".utf8))
            // Import through an actual task attachment, not raw base64 or a path.
            let attachment = AttachmentRef(conversationID: conversation, kind: .document, displayName: receipt.displayName,
                uti: receipt.uti ?? "public.midi-audio", byteCount: receipt.byteCount, sha256: receipt.sha256, storage: .securityScopedBookmark,
                urlBookmark: try snapshot.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
            try await environment.conversationStore.saveAttachment(attachment)
            let imported = try json(try await invoke("score.import", args: .object(["projectID": .string(record.id.uuidString),
                "baseRevision": .number(childRevision), "fileID": .string("attachment:" + attachment.id.uuidString),
                "arguments": .object(["mode": .string("replace"), "quantization": .string("1/4")])]), registry: registry, template: base))
            #expect(imported["baseRevision"].number == childRevision + 1)
            let after = try MusicNotationPackage.capture(root: musicRoot, parentID: record.id)
            #expect(after.musicRevision == before.musicRevision && after.musicSHA256 == before.musicSHA256)
            #expect(after.scoreRevision != nil && after.scoreSHA256 != nil)
        } catch {
            try? await environment.runStore.updateRunState(id: run, state: "failed", endedAt: Date())
            throw error
        }
        try await environment.runStore.updateRunState(id: run, state: "completed", endedAt: Date())
        // The real owned fixture remains available for the coordinator's
        // App/UI readback; it never overwrites or deletes a user's project.
    }
}
#endif
