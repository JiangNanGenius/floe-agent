// FloeApp — DEBUG-only task-lifecycle inspector UI qualification fixture.
//
// SPDX-License-Identifier: MPL-2.0
//
// Seeds ONE clearly synthetic SAVED conversation with a completed run, a
// durable delegated child (with a 14-line result and a real tool pair), and a
// completed background job whose full output is spooled so the GUI acceptance
// can exercise the REAL delegate card → child transcript, the progress
// inspector and the retained-output viewer without any provider request.
// Every identity is a fixed synthetic UUID; nothing here touches user data.
//
// Gated on `-ui-testing` + `--ui-test-lifecycle-fixture`, simulator only.
#if DEBUG
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeExecution

@MainActor
enum TaskLifecycleUITestFixture {
    static let launchArgument = "--ui-test-lifecycle-fixture"
    static let conversationID = UUID(uuidString: "7A1E22C4-3B0F-4A5D-9E62-1C8F3D5B7B32")!
    static let title = "生命周期合成任务"
    static let runID = UUID(uuidString: "7A1E22C4-3B0F-4A5D-9E62-1C8F3D5B7C43")!
    static let childID = UUID(uuidString: "7A1E22C4-3B0F-4A5D-9E62-1C8F3D5B7D54")!
    static let jobID = UUID(uuidString: "7A1E22C4-3B0F-4A5D-9E62-1C8F3D5B7E65")!
    static let delegateCallID = "call-fixture-delegate"

    static func seedIfRequested(environment: AppEnvironment) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"), arguments.contains(launchArgument) else { return }
        #if targetEnvironment(simulator)
        let store = SQLiteConversationStore(database: environment.database)
        if (try? await store.conversation(id: conversationID)) == nil {
            try? await store.saveConversation(ConversationRecord(
                id: conversationID, title: title, createdAt: Date(), updatedAt: Date()
            ))
        }
        let existing = (try? await store.messages(conversationID: conversationID)) ?? []
        if existing.isEmpty {
            try? await store.appendMessage(PersistedMessage(
                id: UUID(), conversationID: conversationID, role: "user",
                content: "检查构建脚本并总结。", createdAt: Date(), runID: runID))
            try? await store.appendMessage(PersistedMessage(
                id: UUID(), conversationID: conversationID, role: "assistant",
                content: "已完成检查，子代理记录了完整发现。",
                createdAt: Date().addingTimeInterval(1), runID: runID))
        }

        let runStore = SQLiteRunStore(database: environment.database)
        if (try? await runStore.run(id: runID)) == nil {
            try? await runStore.saveRun(RunRecord(
                id: runID, conversationID: conversationID, state: "completed",
                goal: "检查构建脚本并总结。",
                startedAt: Date().addingTimeInterval(-120), endedAt: Date()))
            _ = try? await runStore.appendEvent(
                runID: runID, kind: .toolRequest,
                payloadJSON: #"{"tool":"delegate","id":"\#(delegateCallID)","input":"{\"task\":\"检查构建脚本并记录发现\",\"type\":\"explore\"}","status":"pending"}"#)
            _ = try? await runStore.appendEvent(
                runID: runID, kind: .toolResult,
                payloadJSON: #"{"tool":"delegate","id":"\#(delegateCallID)","status":"ok","summary":"status=ok iterationsUsed=3 findings=见子代理记录"}"#)
            _ = try? await runStore.appendEvent(
                runID: runID, kind: .status,
                payloadJSON: #"{"state":"completed","reason":"fixture"}"#)
        }

        let childStore = SQLiteChildRunStore(database: environment.database)
        if (try? await childStore.child(id: childID)) == nil {
            _ = try? await childStore.register(ChildRunRecord(
                id: childID, parentRunID: runID, rootRunID: runID,
                conversationID: conversationID, childIndex: 0, kind: "explore",
                taskSummary: "检查构建脚本并记录发现", state: .completed,
                iterationCount: 3, startedAt: Date().addingTimeInterval(-100),
                endedAt: Date(), resultSummary: "14 行发现",
                delegateCallID: delegateCallID))
            try? await childStore.appendEntry(
                id: childID, kind: .toolRequest,
                payloadJSON: #"{"tool":"workspace.readFile","callID":"c-fix-1","arguments":"{\"path\":\"scripts/gen_project.sh\"}"}"#)
            try? await childStore.appendEntry(
                id: childID, kind: .toolResult,
                payloadJSON: ##"{"tool":"workspace.readFile","callID":"c-fix-1","status":"ok","output":"#!/bin/bash"}"##)
            let findings = (1...14).map { "发现 \($0)：构建脚本第 \($0) 行已检查" }.joined(separator: "\n")
            try? await childStore.appendEntry(
                id: childID, kind: .result,
                payloadJSON: Self.json(["status": "completed", "iterationsUsed": "3", "findings": findings]))
        }

        let jobStore = BackgroundJobStore(database: environment.database)
        // Re-spool and refresh the row on EVERY launch: the stored artifact
        // path must point at THIS container (a reinstall/relaunch can move the
        // Application Support root, and a stale path is honestly reported as
        // unavailable by the viewer).
        let summary = (1...12).map { "任务结果第 \($0) 行" }.joined(separator: "\n")
        let fullText = "完整作业输出\n" + (1...2000).map { "第 \($0) 行输出内容" }.joined(separator: "\n")
        let spooled = BackgroundJobOutputSpool.write(
            jobID: jobID, text: fullText, root: BackgroundJobOutputSpool.defaultRoot())
        var job = (try? await jobStore.job(id: jobID)) ?? BackgroundJob(
            id: jobID, conversationID: conversationID, runID: runID,
            kind: .tool, targetTool: "exec.localPython",
            payloadJSON: Data("{}".utf8), state: .completed)
        job.conversationID = conversationID
        job.runID = runID
        job.state = .completed
        job.resultSummary = summary
        job.outputPath = spooled?.path
        job.outputBytes = spooled?.bytes
        job.completedAt = job.completedAt ?? Date()
        _ = try? await jobStore.save(job)

        _ = try? await SQLiteWorkspaceStore(database: environment.database)
            .ensureWorkspace(conversationID: conversationID, title: title)
        await environment.workspaceCenter.reload()
        await environment.conversationCenter.reload()
        #endif
    }

    private static func json(_ object: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
