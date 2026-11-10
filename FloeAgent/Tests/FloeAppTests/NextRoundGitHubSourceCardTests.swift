// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import UIKit
import Testing
import FloeCore
import FloeModels
import FloeGit
import FloePersistence
import FloeAgentRuntime
@testable import FloeApp

@Suite("GitHub saved-source ownership and routes", .serialized)
@MainActor struct NextRoundGitHubSourceCardTests {
    private func original(task: UUID, project: UUID? = nil, body: String = "Saved discussion",
                          url: String = "https://github.com/floe-fixture/source/issues/17#issuecomment-23") throws -> String {
        let link = try GitHubLinkParser.parse(url)
        let encoder = JSONEncoder()
        let encodedLink = try JSONSerialization.jsonObject(with: encoder.encode(link))
        var association = ["taskID": task.uuidString]
        if let project { association["projectID"] = project.uuidString }
        let repo: [String: Any] = ["owner": link.repository.owner, "name": link.repository.name]
        var source: [String: Any] = ["link": encodedLink, "association": association,
            "repository": ["id": 7, "identity": repo, "isPrivate": false, "url": "https://github.com/floe-fixture/source"],
            "source": ["originalURL": url, "resolvedURL": url, "repository": repo,
                       "readAt": "2026-11-09T01:02:03Z", "requests": []], "warnings": []]
        if link.kind == .issue {
            source["issue"] = ["number": 17, "title": "Fixture issue", "state": "open", "body": body, "labels": [], "isPullRequest": false]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["source": source], options: [.sortedKeys]), as: UTF8.self)
    }
    private func seed(task: UUID, run: UUID, text: String, database: DatabaseManager,
                      captures: ToolResultCaptureStore?, status: String = "ok", truncated: Bool = false) async throws -> GitHubSourceReference {
        let conversations = SQLiteConversationStore(database: database), runs = SQLiteRunStore(database: database)
        try await conversations.saveConversation(.init(id: task, title: "Synthetic source owner", createdAt: Date(), updatedAt: Date()))
        try await runs.saveRun(.init(id: run, conversationID: task, state: "completed", goal: "Read source", startedAt: Date()))
        let summary = captures == nil ? text : String(text.prefix(8_192))
        if let captures {
            await captures.capture(conversationID: task, runID: run, callID: "reused-call", toolName: GitHubReadLinkTool.name,
                status: status, text: text, temporary: false, executionReportedTruncation: truncated)
        }
        let fields = ["id": "reused-call", "tool": GitHubReadLinkTool.name, "status": status,
            "summary": summary, "outputDigest": FloeDigest.sha256Hex(Data(text.utf8))]
        let event = try await runs.appendEvent(runID: run, kind: .toolResult,
            payloadJSON: String(decoding: JSONSerialization.data(withJSONObject: fields), as: UTF8.self))
        return .init(conversationID: task, runID: run, eventID: event.id, sequence: event.sequence, callID: "reused-call")
    }
    private func resolve(_ ref: GitHubSourceReference, database: DatabaseManager, captures: ToolResultCaptureStore) async throws -> ResolvedGitHubSource {
        try await GitHubSourceResolver.resolve(ref, conversations: SQLiteConversationStore(database: database),
            runs: SQLiteRunStore(database: database), workspaces: SQLiteWorkspaceStore(database: database), captures: captures)
    }
    @Test func longCapturedReadRestoresExactOwnerRunAndAnchorFromRealStores() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitHubSource-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("db.sqlite")
        let database = try DatabaseManager(path: path); try await database.migrate()
        let task = UUID(), run = UUID(), text = try original(task: task, body: String(repeating: "source line\n", count: 5_000))
        let captures = ToolResultCaptureStore(durableRoot: root.appendingPathComponent("captures"), caps: .durableStandard)
        let ref = try await seed(task: task, run: run, text: text, database: database, captures: captures)
        // Reopen durable DB and capture storage; no source-card cache/map.
        let reopened = try DatabaseManager(path: path)
        let readback = ToolResultCaptureStore(durableRoot: root.appendingPathComponent("captures"), caps: .durableStandard)
        let result = try await resolve(ref, database: reopened, captures: readback)
        #expect(result.reference.runID == run && result.reference.conversationID == task)
        #expect(result.snapshot.link.anchor == .issueComment(23))
        #expect(result.snapshot.issue?.body == String(repeating: "source line\n", count: 5_000))
        #expect(result.opensCollaboration && result.workspaceID == nil)
    }
    @Test func repeatedCallIDCannotCrossTaskOrRunAndMissingRowsCannotBeAdopted() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let captures = ToolResultCaptureStore(durableRoot: nil), a = UUID(), b = UUID()
        let first = try await seed(task: a, run: UUID(), text: original(task: a, body: "A"), database: database, captures: captures)
        let second = try await seed(task: b, run: UUID(), text: original(task: b, body: "B"), database: database, captures: captures)
        #expect(try await resolve(first, database: database, captures: captures).snapshot.issue?.body == "A")
        #expect(try await resolve(second, database: database, captures: captures).snapshot.issue?.body == "B")
        let foreign = GitHubSourceReference(conversationID: b, runID: first.runID, eventID: first.eventID,
            sequence: first.sequence, callID: first.callID)
        await #expect(throws: GitHubSourceResolutionError.wrongOwner) { try await resolve(foreign, database: database, captures: captures) }
        let invented = GitHubSourceReference(conversationID: a, runID: first.runID, eventID: UUID(),
            sequence: first.sequence, callID: first.callID)
        await #expect(throws: GitHubSourceResolutionError.unavailable) { try await resolve(invented, database: database, captures: captures) }
    }
    @Test func legacyNeverAdoptsLaterProjectAndReassignmentRemovesExplicitPin() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let captures = ToolResultCaptureStore(durableRoot: nil), task = UUID()
        let store = SQLiteWorkspaceStore(database: database)
        let a = WorkspaceRecord(name: "A", rootBookmark: Data()), b = WorkspaceRecord(name: "B", rootBookmark: Data())
        try await store.saveWorkspace(a); try await store.saveWorkspace(b)
        let legacy = try await seed(task: task, run: UUID(), text: original(task: task), database: database, captures: captures)
        try await store.assignConversation(workspaceID: a.id, conversationID: task)
        #expect(try await resolve(legacy, database: database, captures: captures).workspaceID == nil)
        let pinned = try await seed(task: task, run: UUID(), text: original(task: task, project: a.id), database: database, captures: captures)
        #expect(try await resolve(pinned, database: database, captures: captures).workspaceID == a.id)
        try await store.assignConversation(workspaceID: b.id, conversationID: task)
        #expect(try await resolve(pinned, database: database, captures: captures).workspaceID == nil)
        #expect(try await resolve(legacy, database: database, captures: captures).workspaceID == nil)
    }
    @Test func truncatedFailedAndForeignProducerAssociationsRemainUnreadable() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let captures = ToolResultCaptureStore(durableRoot: nil), task = UUID()
        let truncated = try await seed(task: task, run: UUID(), text: original(task: task), database: database, captures: captures, truncated: true)
        await #expect(throws: GitHubSourceResolutionError.incomplete) { try await resolve(truncated, database: database, captures: captures) }
        let foreign = try await seed(task: task, run: UUID(), text: original(task: UUID()), database: database, captures: captures)
        await #expect(throws: GitHubSourceResolutionError.invalidSource) { try await resolve(foreign, database: database, captures: captures) }
        let failed = try await seed(task: task, run: UUID(), text: original(task: task), database: database, captures: captures, status: "failed")
        await #expect(throws: GitHubSourceResolutionError.unavailable) { try await resolve(failed, database: database, captures: captures) }
    }
    @Test func filesStayReadOnlyAndReturnActionUsesOnlyItsCapturedHost() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let captures = ToolResultCaptureStore(durableRoot: nil), task = UUID()
        let ref = try await seed(task: task, run: UUID(), text: original(task: task,
            url: "https://github.com/floe-fixture/source/blob/main/a.swift#L2-L4"), database: database, captures: nil)
        #expect(try await resolve(ref, database: database, captures: captures).opensCollaboration == false)
        var returned: UUID?
        let action = GitHubSourceReturnAction(conversationID: task) { returned = $0 }
        action(ref); #expect(returned == ref.runID)
        returned = nil
        action(.init(conversationID: UUID(), runID: ref.runID, eventID: ref.eventID, sequence: ref.sequence, callID: ref.callID))
        #expect(returned == nil)
        // The same production helper used for a fresh independent task must
        // create a private owner, never inherit the source/current project.
        let newTask = UUID(), workspaces = SQLiteWorkspaceStore(database: database)
        try await SQLiteConversationStore(database: database).saveConversation(.init(id: newTask, title: "Fresh", createdAt: Date(), updatedAt: Date()))
        let independent = try await WorkspaceCenter.ensureReviewConversationWorkspace(conversationID: newTask, workspaceID: nil, title: "Fresh", store: workspaces)
        #expect(try await workspaces.workspace(id: independent)?.kind == .privateTask)
        #expect(try await workspaces.workspaceID(conversationID: task) == nil)
    }
    @Test func persistedFileCaptureMountsActualSourceDetailsWithExactLinesAndOriginalReturn() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let captures = ToolResultCaptureStore(durableRoot: nil), task = UUID()
        let url = "https://github.com/floe-fixture/source/blob/main/a.swift#L2-L4"
        let base = try original(task: task, url: url)
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(base.utf8)) as? [String: Any])
        var source = try #require(envelope["source"] as? [String: Any])
        let lines = "first\nselected two\nselected three\nselected four\nlast\n"
        source["file"] = ["path": "a.swift", "blobSHA": String(repeating: "b", count: 40), "type": "file",
            "size": lines.utf8.count, "content": Data(lines.utf8).base64EncodedString(), "contentState": "loaded"]
        source["location"] = ["state": "resolved", "path": "a.swift", "startLine": 2, "endLine": 4,
            "selectedText": "selected two\nselected three\nselected four"]
        envelope["source"] = source
        let text = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        let ref = try await seed(task: task, run: UUID(), text: text, database: database, captures: captures)
        let resolved = try await resolve(ref, database: database, captures: captures)
        #expect(resolved.snapshot.file?.text == lines)
        #expect(resolved.snapshot.location?.startLine == 2 && resolved.snapshot.location?.endLine == 4)
        #expect(!resolved.opensCollaboration)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        let controller = UIHostingController(rootView: NavigationStack {
            GitHubSourceDetails(snapshot: resolved.snapshot, openCollaboration: nil, workInNewTask: nil)
        })
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        controller.view.layoutIfNeeded()
        #expect(controller.view.bounds.height > 300 && controller.view.bounds.width > 300)
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        Attachment.record(Array(try #require(image.pngData())), named: "github-source-real-file-lines.png")
        var originalRun: UUID?
        GitHubSourceReturnAction(conversationID: task) { originalRun = $0 }(resolved.reference)
        #expect(originalRun == ref.runID)
    }
}
#endif
