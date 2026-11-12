// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeWorkspace
import FloeEnvironments
@testable import FloeApp

@Suite("Saved inline-content ownership and retrieval", .serialized)
@MainActor
struct ChatInlineContentContractTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InlineContent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func artifact(runID: UUID, bytes: Data) -> ToolArtifactReference {
        let id = UUID()
        return .init(id: id, relativePath: "PresentationArtifacts/\(runID.uuidString)/\(id.uuidString).chart.json",
            mimeType: "application/vnd.floe.chart+json", byteCount: bytes.count, sha256: FloeDigest.sha256Hex(bytes))
    }
    private func eventPayload(_ artifact: ToolArtifactReference, tool: String = "document.presentation.createInline",
                              status: String = "ok") throws -> String {
        // Field ordering is deliberately irrelevant: native event payloads
        // are decoded by key, never by searching for substrings in summaries.
        let fields = ["tool": tool, "artifactRefsJSON": String(decoding: try JSONEncoder().encode([artifact]), as: UTF8.self),
                      "id": "chart-call", "summary": "old chart created", "status": status]
        return String(decoding: try JSONSerialization.data(withJSONObject: fields, options: []), as: UTF8.self)
    }
    @Test func legacyArtifactResolvesAtTheSamePositionAfterStoreReopen() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("chat.sqlite")
        let database = try DatabaseManager(path: databaseURL); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database), runs = SQLiteRunStore(database: database)
        let task = UUID(), run = UUID()
        try await conversations.saveConversation(.init(id: task, title: "Synthetic inline test", createdAt: Date(), updatedAt: Date()))
        try await runs.saveRun(.init(id: run, conversationID: task, state: "completed", goal: "Chart", startedAt: Date(), endedAt: Date()))
        let bytes = Data("{\"type\":\"line\",\"series\":[{\"name\":\"A\",\"points\":[{\"label\":\"one\",\"value\":1}]}]}".utf8)
        let ref = artifact(runID: run, bytes: bytes)
        _ = try await runs.appendEvent(runID: run, kind: .toolResult, payloadJSON: eventPayload(ref))
        let file = root.appendingPathComponent(ref.relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        let uri = try #require(ChatContentReference(kind: .artifact, ownerID: run, contentID: ref.id.uuidString))
        let answer = "Before\n\n" + uri.markdown(title: "Chart") + "\n\nAfter"
        let message = UUID()
        try await conversations.appendMessage(.init(id: message, conversationID: task, role: "assistant", content: answer, createdAt: Date(), runID: run))
        // A different database manager and fresh services read durable bytes;
        // no view cache or process-global reference map participates.
        let reopened = try DatabaseManager(path: databaseURL)
        let restoredConversations = SQLiteConversationStore(database: reopened), restoredRuns = SQLiteRunStore(database: reopened)
        let resolved = try await ChatInlineContentResolver.resolve(uri, scope: .init(conversationID: task, isTemporary: false),
            conversations: restoredConversations, runs: restoredRuns)
        #expect(resolved == .artifact(ref, runID: run, tool: "document.presentation.createInline"))
        #expect(try VerifiedChatInlineArtifact.load(ref, runID: run, tool: "document.presentation.createInline", root: root).data == bytes)
        #expect(try await restoredConversations.messages(conversationID: task).first?.content == answer)
    }
    @Test func anotherTaskAndTemporaryChatCannotAdoptTheSameReceipt() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database), runs = SQLiteRunStore(database: database)
        let task = UUID(), other = UUID(), run = UUID()
        for id in [task, other] { try await conversations.saveConversation(.init(id: id, title: "Synthetic owner", createdAt: Date(), updatedAt: Date())) }
        try await runs.saveRun(.init(id: run, conversationID: task, state: "completed", goal: "Chart", startedAt: Date()))
        let ref = artifact(runID: run, bytes: Data("{}".utf8))
        _ = try await runs.appendEvent(runID: run, kind: .toolResult, payloadJSON: eventPayload(ref))
        let uri = try #require(ChatContentReference(kind: .artifact, ownerID: run, contentID: ref.id.uuidString))
        for scope in [ChatInlineContentScope(conversationID: other, isTemporary: false), .init(conversationID: task, isTemporary: true)] {
            await #expect(throws: ChatInlineContentResolutionError.wrongOwner) {
                try await ChatInlineContentResolver.resolve(uri, scope: scope, conversations: conversations, runs: runs)
            }
        }
    }
    @Test func missingFailedAndExternalReceiptsNeverResolve() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database), runs = SQLiteRunStore(database: database)
        let task = UUID(), run = UUID()
        try await conversations.saveConversation(.init(id: task, title: "Synthetic missing", createdAt: Date(), updatedAt: Date()))
        try await runs.saveRun(.init(id: run, conversationID: task, state: "completed", goal: "Chart", startedAt: Date()))
        for tool in ["mcp.untrusted.chart", "document.presentation.createInline"] {
            let ref = artifact(runID: run, bytes: Data("{}".utf8))
            _ = try await runs.appendEvent(runID: run, kind: .toolResult,
                payloadJSON: eventPayload(ref, tool: tool, status: tool.hasPrefix("mcp.") ? "ok" : "failed"))
            let uri = try #require(ChatContentReference(kind: .artifact, ownerID: run, contentID: ref.id.uuidString))
            await #expect(throws: ChatInlineContentResolutionError.unavailable) {
                try await ChatInlineContentResolver.resolve(uri, scope: .init(conversationID: task, isTemporary: false), conversations: conversations, runs: runs)
            }
        }
    }
    @Test func byteTamperingMissingFilesAndInRootSymlinksAreRejected() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let run = UUID(), bytes = Data("correct".utf8), ref = artifact(runID: run, bytes: bytes)
        let file = root.appendingPathComponent(ref.relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        #expect(try VerifiedChatInlineArtifact.load(ref, runID: run, tool: "document.presentation.createInline", root: root).data == bytes)
        try Data("changed".utf8).write(to: file)
        #expect(throws: (any Error).self) { try VerifiedChatInlineArtifact.load(ref, runID: run, tool: "document.presentation.createInline", root: root) }
        try FileManager.default.removeItem(at: file)
        #expect(throws: (any Error).self) { try VerifiedChatInlineArtifact.load(ref, runID: run, tool: "document.presentation.createInline", root: root) }
        let real = root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try bytes.write(to: real.appendingPathComponent(file.lastPathComponent))
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: file.deletingLastPathComponent(), withDestinationURL: real)
        #expect(throws: (any Error).self) { try VerifiedChatInlineArtifact.load(ref, runID: run, tool: "document.presentation.createInline", root: root) }
    }
    @Test func outputReceiptsKeepRealTaskCallAndIdentitySeals() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav"), bytes = Data("synthetic file output".utf8)
        try bytes.write(to: source)
        let run = UUID(), task = UUID(), context = ToolContext(runID: run, toolCallID: "audio-call", cancellation: CancellationToken(), conversationID: task)
        let receipt = try RunOutputSnapshotStore.publish(.init(producerTool: "studio.run", slot: "audio",
            commit: .init(sourceURL: source, sha256: FloeDigest.sha256Hex(bytes), byteCount: bytes.count,
                displayName: "output.wav", mimeType: "audio/wav")), using: context, artifactRoot: root.appendingPathComponent("store"))
        #expect(ChatInlineContentCatalog.accepts(receipt, runID: run, taskID: task, callID: "audio-call", tool: "studio.run"))
        #expect(!ChatInlineContentCatalog.accepts(receipt, runID: run, taskID: UUID(), callID: "audio-call", tool: "studio.run"))
        #expect(!ChatInlineContentCatalog.accepts(receipt, runID: run, taskID: task, callID: "other-call", tool: "studio.run"))
        var changed = receipt; changed.outputID = String(repeating: "a", count: 64)
        #expect(!ChatInlineContentCatalog.accepts(changed, runID: run, taskID: task, callID: "audio-call", tool: "studio.run"))
    }
    @Test func previewUnsupportedMissingAndCorruptStatesDoNotRewriteCompletedRun() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database), runs = SQLiteRunStore(database: database)
        let task = UUID(), run = UUID()
        try await conversations.saveConversation(.init(id: task, title: "Synthetic preview states", createdAt: Date(), updatedAt: Date()))
        try await runs.saveRun(.init(id: run, conversationID: task, state: "completed", goal: "File saved", startedAt: Date(), endedAt: Date()))
        let source = root.appendingPathComponent("source.bin"), data = Data([0, 1, 0, 2, 0, 3, 0, 4])
        try data.write(to: source)
        let receipt = try RunOutputSnapshotStore.publish(.init(producerTool: "files.write", slot: "text",
            commit: .init(sourceURL: source, sha256: FloeDigest.sha256Hex(data), byteCount: data.count,
                displayName: "result.bin", mimeType: "application/octet-stream")),
            using: .init(runID: run, toolCallID: "write", cancellation: CancellationToken(), conversationID: task), artifactRoot: root)
        let fields = ["tool": "files.write", "id": "write", "status": "ok",
            "outputFilesJSON": String(decoding: try JSONEncoder().encode([receipt]), as: UTF8.self)]
        _ = try await runs.appendEvent(runID: run, kind: .toolResult,
            payloadJSON: String(decoding: try JSONEncoder().encode(fields), as: UTF8.self))
        let reference = try #require(ChatContentReference(kind: .output, ownerID: run, contentID: receipt.outputID))
        _ = try await ChatInlineContentResolver.resolve(reference, scope: .init(conversationID: task, isTemporary: false),
            conversations: conversations, runs: runs)
        #expect(RunOutputPreviewRouting.route(for: receipt) == .quickLook)
        #expect(try await runs.run(id: run)?.state == "completed")
        let file = root.appendingPathComponent(receipt.relativePath)
        try Data(repeating: 65, count: data.count).write(to: file)
        guard case .changed = RunOutputSnapshotStore.verify(receipt, artifactRoot: root) else { Issue.record("corruption must stay a real file error"); return }
        #expect(try await runs.run(id: run)?.state == "completed")
        try FileManager.default.removeItem(at: file)
        guard case .missing = RunOutputSnapshotStore.verify(receipt, artifactRoot: root) else { Issue.record("missing file must stay missing"); return }
        #expect(try await runs.run(id: run)?.state == "completed")
        let missing = try #require(ChatContentReference(kind: .output, ownerID: run, contentID: String(repeating: "f", count: 64)))
        await #expect(throws: ChatInlineContentResolutionError.unavailable) {
            try await ChatInlineContentResolver.resolve(missing, scope: .init(conversationID: task, isTemporary: false), conversations: conversations, runs: runs)
        }
        #expect(try await runs.run(id: run)?.state == "completed")
    }

    @Test func savedFilePreviewUsesSQLiteNativeTaskRootAcrossSharedAndProjectBindings() async throws {
        let scratchRoot = try scratch(); defer { try? FileManager.default.removeItem(at: scratchRoot) }
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let conversations = environment.conversationStore, runs = environment.runStore
        let workspaces = SQLiteWorkspaceStore(database: environment.database)
        let center = WorkspaceCenter(environment: environment, publishesSharedState: false)
        let task = UUID(), now = Date()
        try await conversations.saveConversation(.init(id: task, title: "Native task root fixture", createdAt: now, updatedAt: now))
        let owner = try await workspaces.ensureWorkspace(conversationID: task, title: "Native task root fixture")
        // This is the actual native writer lease used by ConversationCenter.
        let nativeLease = try await center.acquireTaskRoot(owner, conversationID: task)
        defer { nativeLease.release(); try? FileManager.default.removeItem(at: nativeLease.url) }
        let text = String(repeating: "原生任务文件中文🙂", count: 10_001) + "NATIVE-EOF"
        let bytes = Data(text.utf8)
        try bytes.write(to: nativeLease.url.appendingPathComponent("answer.txt"))
        // A real isolated registry proves the alternate project root differs;
        // shared has no project-workspace mapping at all. Metadata only: no VM.
        let otherRoot = scratchRoot.appendingPathComponent("other-project", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let unrelated = Data("UNRELATED ENVIRONMENT FILE".utf8)
        try unrelated.write(to: otherRoot.appendingPathComponent("answer.txt"))
        let registry = EnvironmentRegistry(roots: EnvironmentRoots(rootURL: scratchRoot.appendingPathComponent("registry")), baseRevision: "preview-fixture")
        let canonicalOther = otherRoot.resolvingSymlinksInPath().standardizedFileURL
        let project = try await registry.ensureProjectContainer(workspaceID: FloeDigest.sha256Hex(Data(canonicalOther.path.utf8)), workspaceRootPath: canonicalOther.path)
        #expect(try await registry.workspaceRoot(for: project.id)?.resolvingSymlinksInPath().path == canonicalOther.path)
        #expect(try await registry.workspaceRoot(for: EnvironmentRegistry.sharedContainerID) == nil)
        #expect(canonicalOther.path != nativeLease.url.resolvingSymlinksInPath().path)
        #expect(center.currentRootURL == nil, "background preview must not rebind the visible workspace")
        for environmentID in [EnvironmentRegistry.sharedContainerID, project.id] {
            let runID = UUID()
            let binding = TaskExecutionBinding(conversationID: task,
                target: .init(environmentID: environmentID, backend: .linuxVM, operatingSystem: "linux", architecture: "arm64"))
            try await runs.saveRun(.init(id: runID, conversationID: task, state: "completed", goal: "Saved file",
                startedAt: now, endedAt: now, executionBinding: binding))
            let document = WorkspaceFileChangePreview(version: 1, path: "answer.txt", byteCount: bytes.count,
                sha256: FloeDigest.sha256Hex(bytes), text: String(text.prefix(24_000)), truncated: true, comparison: .comparisonTooLarge)
            let encoded = try JSONEncoder().encode(document), digest = FloeDigest.sha256Hex(encoded)
            let artifact = ToolArtifactReference(id: UUID(), relativePath: "ChangeArtifacts/\(runID.uuidString)/\(digest).preview.json",
                mimeType: "application/vnd.floe.file-preview+json", byteCount: encoded.count, sha256: digest)
            let file = scratchRoot.appendingPathComponent(artifact.relativePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoded.write(to: file)
            _ = try await runs.appendEvent(runID: runID, kind: .toolResult, payloadJSON: eventPayload(artifact, tool: "workspace.writeFile"))
            let opened = try await SavedFileTextPreviewPolicy.ownedBytes(document: document, artifact: artifact,
                scope: .init(conversationID: task, isTemporary: false), conversations: conversations, runs: runs,
                workspaces: workspaces, artifactRoot: scratchRoot,
                acquireRoot: { record in try await center.acquireMemorySourceRoot(record) })
            #expect(opened.source.byteLength == Int64(bytes.count))
            #expect(try opened.source.read(offset: Int64(bytes.count - 10), length: 10) == bytes.suffix(10))
            #expect(center.currentRootURL == nil)
            var missingBinding = try #require(try await runs.run(id: runID)); missingBinding.executionBinding = nil
            try await runs.saveRun(missingBinding)
            await #expect(throws: (any Error).self) {
                try await SavedFileTextPreviewPolicy.ownedBytes(document: document, artifact: artifact,
                    scope: .init(conversationID: task, isTemporary: false), conversations: conversations, runs: runs,
                    workspaces: workspaces, artifactRoot: scratchRoot,
                    acquireRoot: { record in try await center.acquireMemorySourceRoot(record) })
            }
        }
        #expect(try Data(contentsOf: nativeLease.url.appendingPathComponent("answer.txt")) == bytes)
        #expect(try Data(contentsOf: otherRoot.appendingPathComponent("answer.txt")) == unrelated)
    }

    @Test func attachmentsRequireTheActualMessagePartEvenForLegacyMetadata() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database), runs = SQLiteRunStore(database: database)
        let task = UUID(), owner = UUID(), otherMessage = UUID()
        try await conversations.saveConversation(.init(id: task, title: "Synthetic attachment", createdAt: Date(), updatedAt: Date()))
        for id in [owner, otherMessage] {
            try await conversations.appendMessage(.init(id: id, conversationID: task, role: "assistant", content: "Files", createdAt: Date()))
        }
        let attachment = AttachmentRef(conversationID: task, kind: .document, displayName: "result.pdf",
            uti: "com.adobe.pdf", byteCount: 3, sha256: FloeDigest.sha256Hex(Data("pdf".utf8)),
            // Stored dates have millisecond precision. Keep the fixture exact
            // so this full-record comparison tests ownership, not clock rounding.
            storage: .applicationSupport, relativePath: "synthetic.pdf", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await conversations.saveAttachment(attachment)
        try await conversations.appendMessage(.init(id: owner, conversationID: task, role: "assistant", content: "Files", createdAt: Date(),
            parts: [.init(messageID: owner, partIndex: 0, kind: .file, text: attachment.displayName, attachmentID: attachment.id)]))
        let valid = try #require(ChatContentReference(kind: .attachment, ownerID: owner, contentID: attachment.id.uuidString))
        #expect(try await ChatInlineContentResolver.resolve(valid, scope: .init(conversationID: task, isTemporary: false), conversations: conversations, runs: runs)
            == .attachment(attachment, messageID: owner))
        let wrong = try #require(ChatContentReference(kind: .attachment, ownerID: otherMessage, contentID: attachment.id.uuidString))
        await #expect(throws: ChatInlineContentResolutionError.unavailable) {
            try await ChatInlineContentResolver.resolve(wrong, scope: .init(conversationID: task, isTemporary: false), conversations: conversations, runs: runs)
        }
    }

    #if canImport(AlarmKit)
    // MARK: - Native timer binding receipts (forged producer / foreign owner / missing receipt / reopen)

    private func timerArtifact(runID: UUID) -> ToolArtifactReference {
        let id = UUID()
        let bytes = Data("{\"version\":1}".utf8)
        return .init(id: id,
            relativePath: "TimerArtifacts/\(runID.uuidString)/\(id.uuidString).timer.json",
            mimeType: "application/vnd.floe.native-timer+json",
            byteCount: bytes.count, sha256: FloeDigest.sha256Hex(bytes))
    }

    private func timerEventPayload(_ artifact: ToolArtifactReference, tool: String = "apple.alarm.schedule",
                                   status: String = "ok") throws -> String {
        let fields = ["tool": tool, "artifactRefsJSON": String(decoding: try JSONEncoder().encode([artifact]), as: UTF8.self),
                      "id": "timer-call", "summary": "timer scheduled", "status": status]
        return String(decoding: try JSONSerialization.data(withJSONObject: fields, options: []), as: UTF8.self)
    }

    @Test func timerBindingResolvesAndSurvivesStoreReopen() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("timer-chat.sqlite")
        let database = try DatabaseManager(path: databaseURL); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database), runs = SQLiteRunStore(database: database)
        let task = UUID(), run = UUID()
        try await conversations.saveConversation(.init(id: task, title: "Timer", createdAt: Date(), updatedAt: Date()))
        try await runs.saveRun(.init(id: run, conversationID: task, state: "completed", goal: "Tea", startedAt: Date(), endedAt: Date()))
        let ref = timerArtifact(runID: run)
        _ = try await runs.appendEvent(runID: run, kind: .toolResult, payloadJSON: timerEventPayload(ref))
        let file = root.appendingPathComponent(ref.relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"version\":1}".utf8).write(to: file)

        let uri = try #require(ChatContentReference(kind: .artifact, ownerID: run, contentID: ref.id.uuidString))
        let reopened = try DatabaseManager(path: databaseURL)
        let resolved = try await ChatInlineContentResolver.resolve(uri,
            scope: .init(conversationID: task, isTemporary: false),
            conversations: SQLiteConversationStore(database: reopened), runs: SQLiteRunStore(database: reopened))
        #expect(resolved == .artifact(ref, runID: run, tool: "apple.alarm.schedule"))
        let loaded = try VerifiedChatInlineArtifact.load(ref, runID: run, tool: "apple.alarm.schedule", root: root)
        #expect(loaded.data == Data("{\"version\":1}".utf8))
    }

    @Test func forgedTimerProducerNeverResolves() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database), runs = SQLiteRunStore(database: database)
        let task = UUID(), run = UUID()
        try await conversations.saveConversation(.init(id: task, title: "Forged", createdAt: Date(), updatedAt: Date()))
        try await runs.saveRun(.init(id: run, conversationID: task, state: "completed", goal: "T", startedAt: Date()))
        // Same path/mime bytes, but the receipt claims an untrusted producer.
        let ref = timerArtifact(runID: run)
        _ = try await runs.appendEvent(runID: run, kind: .toolResult, payloadJSON: timerEventPayload(ref, tool: "mcp.untrusted.timer"))
        let uri = try #require(ChatContentReference(kind: .artifact, ownerID: run, contentID: ref.id.uuidString))
        await #expect(throws: ChatInlineContentResolutionError.unavailable) {
            try await ChatInlineContentResolver.resolve(uri, scope: .init(conversationID: task, isTemporary: false), conversations: conversations, runs: runs)
        }
        // Wrong path shape (directory spoof) is rejected by the catalog itself.
        #expect(!ChatInlineContentCatalog.accepts(.init(id: ref.id,
            relativePath: "OtherArtifacts/\(run.uuidString)/\(ref.id.uuidString).timer.json",
            mimeType: ref.mimeType, byteCount: ref.byteCount, sha256: ref.sha256), runID: run, tool: "apple.alarm.schedule"))
        #expect(!ChatInlineContentCatalog.accepts(.init(id: ref.id,
            relativePath: "TimerArtifacts/\(run.uuidString)/\(ref.id.uuidString).timer.json",
            mimeType: "text/plain", byteCount: ref.byteCount, sha256: ref.sha256), runID: run, tool: "apple.alarm.schedule"))
    }

    @Test func foreignConversationCannotAdoptATimerReceipt() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database), runs = SQLiteRunStore(database: database)
        let task = UUID(), other = UUID(), run = UUID()
        for id in [task, other] { try await conversations.saveConversation(.init(id: id, title: "Owner", createdAt: Date(), updatedAt: Date())) }
        try await runs.saveRun(.init(id: run, conversationID: task, state: "completed", goal: "T", startedAt: Date()))
        let ref = timerArtifact(runID: run)
        _ = try await runs.appendEvent(runID: run, kind: .toolResult, payloadJSON: timerEventPayload(ref))
        let uri = try #require(ChatContentReference(kind: .artifact, ownerID: run, contentID: ref.id.uuidString))
        await #expect(throws: ChatInlineContentResolutionError.wrongOwner) {
            try await ChatInlineContentResolver.resolve(uri, scope: .init(conversationID: other, isTemporary: false), conversations: conversations, runs: runs)
        }
        await #expect(throws: ChatInlineContentResolutionError.wrongOwner) {
            try await ChatInlineContentResolver.resolve(uri, scope: .init(conversationID: task, isTemporary: true), conversations: conversations, runs: runs)
        }
    }

    @Test func missingOrFailedTimerReceiptNeverResolves() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database), runs = SQLiteRunStore(database: database)
        let task = UUID(), run = UUID()
        try await conversations.saveConversation(.init(id: task, title: "Missing", createdAt: Date(), updatedAt: Date()))
        try await runs.saveRun(.init(id: run, conversationID: task, state: "completed", goal: "T", startedAt: Date()))
        // Receipt exists on disk bytes shape but no toolResult event at all.
        let orphan = timerArtifact(runID: run)
        let orphanURI = try #require(ChatContentReference(kind: .artifact, ownerID: run, contentID: orphan.id.uuidString))
        await #expect(throws: ChatInlineContentResolutionError.unavailable) {
            try await ChatInlineContentResolver.resolve(orphanURI, scope: .init(conversationID: task, isTemporary: false), conversations: conversations, runs: runs)
        }
        // Failed schedule receipt is equally unusable.
        let failed = timerArtifact(runID: run)
        _ = try await runs.appendEvent(runID: run, kind: .toolResult, payloadJSON: timerEventPayload(failed, status: "failed"))
        let failedURI = try #require(ChatContentReference(kind: .artifact, ownerID: run, contentID: failed.id.uuidString))
        await #expect(throws: ChatInlineContentResolutionError.unavailable) {
            try await ChatInlineContentResolver.resolve(failedURI, scope: .init(conversationID: task, isTemporary: false), conversations: conversations, runs: runs)
        }
    }
    #endif
}
#endif
