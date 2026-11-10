// SPDX-License-Identifier: MPL-2.0
// A saved synthetic chat, not a replacement renderer or a second scene.
#if DEBUG && targetEnvironment(simulator)
import Foundation
import FloeCore
import FloeImages
import FloeModels
import FloePersistence
import FloeTools

@MainActor
enum SVGChatUITestFixture {
    static let launchArgument = "--ui-test-svg-chat-fixture"
    static let title = "SVG chat page acceptance"
    static let conversationID = UUID(uuidString: "89551ED9-5C37-4975-BF86-1B59CD836101")!
    static let runID = UUID(uuidString: "89551ED9-5C37-4975-BF86-1B59CD836102")!
    private static let userMessageID = UUID(uuidString: "89551ED9-5C37-4975-BF86-1B59CD836103")!
    private static let assistantMessageID = UUID(uuidString: "89551ED9-5C37-4975-BF86-1B59CD836104")!
    private static let callID = "call-svg-chat-page-fixture-v1"
    private static let sourcePath = "svg-chat-fixture.svg"
    private static let leadingText = "SVG chat before the picture."
    private static let trailingText = "SVG chat after the picture."
    private static let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="240" height="120" viewBox="0 0 240 120">
      <rect x="20" y="20" width="80" height="60" fill="#ff0000"/>
    </svg>
    """

    static func prepareIfRequested(environment: AppEnvironment, router: AppRouter) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"), arguments.contains(launchArgument) else { return }
        do {
            try await prepare(environment: environment)
        } catch {
            // Failed real tool results stay in the owned run for diagnosis.
            // A partial fixture is never substituted with a ready image.
            FloeLogger(category: .app).error("svgChatFixtureFailed errorType=\(String(describing: type(of: error)))")
        }
        guard let saved = try? await environment.conversationStore.conversation(id: conversationID),
              saved.title == title else { return }
        await environment.conversationCenter.reload()
        router.openConversation(conversationID, runID: runID)
    }

    private static func body(for output: RunOutputFile) throws -> String {
        guard let reference = ChatContentReference(kind: .output, ownerID: runID, contentID: output.outputID) else {
            throw FloeError.validationFailed("SVG fixture output identity is invalid")
        }
        return leadingText + "\n\n```svg\n" + svg + "\n```\n\n" + trailingText
            + "\n\n" + reference.markdown(title: "SVG PNG export")
    }

    private static func prepare(environment: AppEnvironment) async throws {
        let conversations = SQLiteConversationStore(database: environment.database)
        let runs = SQLiteRunStore(database: environment.database)
        if let existing = try await conversations.conversation(id: conversationID) {
            guard existing.title == title else { throw FloeError.validationFailed("SVG fixture identity collision") }
            // Relaunch reads the same durable rows and verified snapshot.
            // Incomplete/stale fixtures fail honestly and remain inspectable.
            try await verifySavedFixture(conversations: conversations, runs: runs)
            return
        }
        guard try await runs.run(id: runID) == nil else {
            throw FloeError.validationFailed("SVG fixture run identity collision")
        }
        let now = Date()
        try await conversations.saveConversation(ConversationRecord(id: conversationID, title: title,
            createdAt: now, updatedAt: now))
        try await runs.saveRun(RunRecord(id: runID, conversationID: conversationID, state: "completed",
            goal: "Render the static SVG and export PNG locally", startedAt: now, endedAt: now))
        try await conversations.appendMessage(PersistedMessage(id: userMessageID, conversationID: conversationID,
            role: "user", content: "Show the SVG between paragraphs and export its PNG.", createdAt: now, runID: runID))

        let workspace = try await SQLiteWorkspaceStore(database: environment.database)
            .ensureWorkspace(conversationID: conversationID, title: title)
        guard workspace.kind == .privateTask else { throw FloeError.validationFailed("SVG fixture requires its own task root") }
        let lease = try await environment.workspaceCenter.acquireTaskRoot(workspace, conversationID: conversationID)
        defer { lease.release() }
        let sourceURL = lease.url.appendingPathComponent(sourcePath)
        // This is a new owned workspace. Do not overwrite even an unexpected
        // file inside it; neither fixture setup nor the producer adopts data.
        try Data(svg.utf8).write(to: sourceURL, options: .withoutOverwriting)
        let input = try json(["path": sourcePath, "format": "png"])
        try await runs.appendEvent(runID: runID, kind: .toolRequest,
            payloadJSON: try json(["tool": SVGRenderTool.name, "id": callID, "input": input, "status": "pending"]))
        let tool = SVGRenderTool(rootProvider: { lease.url })
        let arguments = SVGRenderTool.Arguments(path: sourcePath, format: "png")
        try tool.validate(arguments)
        let output = try await tool.execute(arguments, context: ToolContext(runID: runID, toolCallID: callID,
            workspaceRootURL: lease.url, cancellation: CancellationToken(), conversationID: conversationID))
        let receiptsJSON = String(decoding: try JSONEncoder().encode(output.outputFiles), as: UTF8.self)
        try await runs.appendEvent(runID: runID, kind: .toolResult, payloadJSON: try json([
            "tool": SVGRenderTool.name, "id": callID, "status": output.exitStatus == 0 ? "ok" : "error",
            "summary": output.summary, "outputFilesJSON": receiptsJSON
        ]))
        guard output.exitStatus == 0, output.outputFiles.count == 1, let receipt = output.outputFiles.first else {
            throw FloeError.validationFailed("The real SVG fixture producer did not publish one PNG")
        }
        let text = try body(for: receipt)
        try await runs.appendEvent(runID: runID, kind: .assistantText, payloadJSON: try json(["text": text]))
        try await conversations.appendMessage(PersistedMessage(id: assistantMessageID, conversationID: conversationID,
            role: "assistant", content: text, createdAt: Date(), runID: runID))
        try await runs.appendEvent(runID: runID, kind: .status, payloadJSON: try json(["state": "completed", "reason": "fixture"]))
        try await verifySavedFixture(conversations: conversations, runs: runs)
        await environment.workspaceCenter.reload()
    }

    private static func verifySavedFixture(conversations: SQLiteConversationStore, runs: SQLiteRunStore) async throws {
        guard let run = try await runs.run(id: runID), run.conversationID == conversationID, run.state == "completed" else {
            throw FloeError.validationFailed("SVG fixture run is incomplete")
        }
        let events = try await runs.events(runID: runID)
        guard let event = events.first(where: { $0.kind == .toolResult }),
              let payload = ChatInlineContentResolver.payload(event), payload["status"] == "ok",
              payload["id"] == callID, payload["tool"] == SVGRenderTool.name,
              let encoded = payload["outputFilesJSON"],
              let receipts = try? JSONDecoder().decode([RunOutputFile].self, from: Data(encoded.utf8)),
              receipts.count == 1, let receipt = receipts.first,
              receipt.mimeType == "image/png",
              RunOutputReceiptGate.accepts(receipt, in: .init(runID: runID, conversationID: conversationID,
                  callID: callID, toolName: SVGRenderTool.name)),
              case .verified = RunOutputSnapshotStore.verify(receipt) else {
            throw FloeError.validationFailed("SVG fixture PNG receipt did not verify")
        }
        let expected = try body(for: receipt)
        guard let message = try await conversations.message(id: assistantMessageID, conversationID: conversationID),
              message.role == "assistant", message.runID == runID, message.content == expected,
              events.contains(where: { $0.kind == .assistantText && ChatInlineContentResolver.payload($0)?["text"] == expected }),
              let reference = ChatContentReference(kind: .output, ownerID: runID, contentID: receipt.outputID),
              case .output(let resolved, _) = try await ChatInlineContentResolver.resolve(reference,
                  scope: .init(conversationID: conversationID, isTemporary: false), conversations: conversations, runs: runs),
              resolved == receipt else { throw FloeError.validationFailed("SVG fixture saved reply did not resolve its own PNG") }
    }

    private static func json(_ values: [String: String]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), as: UTF8.self)
    }
}
#endif
