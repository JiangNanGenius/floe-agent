// SPDX-License-Identifier: MPL-2.0
// DEBUG-only real saved chat + native producer acceptance; no model/provider requests.
#if DEBUG && canImport(UIKit)
import Foundation
import UIKit
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeExecution
import FloeWorkspace
import FloeNativeChartsCore
import FloeAgentRuntime

@MainActor enum NativeAnswerUITestFixture {
    static let argument = "--ui-test-native-answer-fixture"
    static let conversationID = UUID(uuidString:"95B20771-2CC4-4B96-9FCA-9437BC412A10")!
    static let runID = UUID(uuidString:"95B20771-2CC4-4B96-9FCA-9437BC412A20")!
    static let title = "QA 原生正文与文件差异"
    static let planConversationID = UUID(uuidString:"95B20771-2CC4-4B96-9FCA-9437BC412A40")!
    static let planID = UUID(uuidString:"95B20771-2CC4-4B96-9FCA-9437BC412A41")!
    static let planRequestID = UUID(uuidString:"95B20771-2CC4-4B96-9FCA-9437BC412A42")!
    static let planTitle = "QA 计划确认与历史"

    static func prepareIfRequested(environment:AppEnvironment,router:AppRouter) async {
        #if targetEnvironment(simulator)
        let arguments=ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"),let index=arguments.firstIndex(of:argument),arguments.indices.contains(index+1) else { return }
        let mode=arguments[index+1]
        guard ["line","histogram","candlestick","treemap","sankey","gantt","small-diff","large-diff","large-text","plan-ready","plan-accepted"].contains(mode) else { return }
        do {
            if mode == "plan-ready" || mode == "plan-accepted" {
                try await preparePlan(mode:mode,environment:environment,router:router)
                return
            }
            let conversations=SQLiteConversationStore(database:environment.database),runs=SQLiteRunStore(database:environment.database)
            let old=try await conversations.conversation(id:conversationID)
            if let old,old.title != title { throw FloeError.validationFailed("Fixture identity already occupied") }
            if mode == "large-text", let existingRun=try await runs.run(id:runID),
               existingRun.conversationID != conversationID || existingRun.goal != title {
                throw FloeError.validationFailed("Fixture run identity already occupied")
            }
            if old != nil { try await conversations.deleteConversation(id:conversationID) }
            let root=try FloeArtifactStore.root()
            // Only the two namespaces of this fixed, synthetic run are retired.
            for namespace in ["PresentationArtifacts","ChangeArtifacts"] {
                let folder=root.appendingPathComponent(namespace).appendingPathComponent(runID.uuidString)
                if FileManager.default.fileExists(atPath:folder.path) { try FileManager.default.removeItem(at:folder) }
            }
            try await conversations.saveConversation(.init(id:conversationID,title:title,createdAt:Date(),updatedAt:Date()))
            try await runs.saveRun(.init(id:runID,conversationID:conversationID,state:"completed",goal:title,startedAt:Date().addingTimeInterval(-20),endedAt:Date()))
            try await conversations.appendMessage(.init(id:UUID(),conversationID:conversationID,role:"user",content:"显示本地验收内容："+mode,createdAt:Date(),runID:runID))
            let context=ToolContext(runID:runID,cancellation:CancellationToken())
            let output:ToolExecutionOutput,tool:String
            if mode == "large-text" {
                output=try await largeTextOutput(environment:environment)
                tool=WorkspaceWriteFileTool.name
            } else if let kind=ChartKind(rawValue:mode) {
                let contract=try await PresentationChartContractTool().execute(.init(type:kind),context:context)
                guard let object=try JSONSerialization.jsonObject(with:Data((contract.capturedOutput ?? contract.summary).utf8)) as? [String:Any],var chart=object["chart"] as? [String:Any] else { throw FloeError.validationFailed("Fixture chart contract unavailable") }
                chart["title"]="QA "+mode
                let input=try JSONSerialization.data(withJSONObject:["kind":"chart","chart":chart])
                let args=try JSONDecoder().decode(PresentationArtifactTool.Arguments.self,from:input)
                output=try await PresentationArtifactTool().execute(args,context:context)
                tool=PresentationArtifactTool.name
            } else {
                let folder=root.appendingPathComponent("Qualification/NativeAnswerFixture",isDirectory:true)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                let before:String,after:String
                if mode == "small-diff" { before="kept\nold\nold2\n";after="kept\nnew\nnew2\nnew3\n" }
                else { before=(1...80).map{"old row \($0)"}.joined(separator:"\n")+"\n";after=(1...80).map{"new row \($0)"}.joined(separator:"\n")+"\n" }
                let file=folder.appendingPathComponent("answer-preview.txt")
                try Data(before.utf8).write(to:file,options:.atomic)
                output=try await WorkspaceWriteFileTool(environment:.init(rootProvider:{folder})).execute(.init(path:"answer-preview.txt",content:after,expectedSHA256:FloeDigest.sha256Hex(Data(before.utf8))),context:context)
                guard try String(contentsOf:file,encoding:.utf8)==after else { throw FloeError.validationFailed("Fixture write did not persist") }
                tool=WorkspaceWriteFileTool.name
            }
            guard let artifact=output.artifacts.first,ChatInlineContentCatalog.accepts(artifact,runID:runID,tool:tool),let reference=ChatContentReference(kind:.artifact,ownerID:runID,contentID:artifact.id.uuidString) else { throw FloeError.validationFailed("Fixture has no owned inline artifact") }
            _ = try VerifiedChatInlineArtifact.load(artifact,runID:runID,tool:tool,root:root)
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            let refs=String(decoding:try encoder.encode(output.artifacts),as:UTF8.self)
            try await runs.appendEvent(runID:runID,kind:.toolRequest,payloadJSON:try json(["tool":tool,"id":"call-native-answer-fixture","input":"{}","status":"pending"]))
            try await runs.appendEvent(runID:runID,kind:.toolResult,payloadJSON:try json(["tool":tool,"id":"call-native-answer-fixture","status":"ok","summary":output.summary,"durationMs":"1","artifactRefsJSON":refs]))
            let reply="正文前段：以下是已保存的本地内容。\n\n"+reference.markdown(title:"QA "+mode)+"\n\n正文后段：内容显示在这两段之间。"
            try await runs.appendEvent(runID:runID,kind:.assistantText,payloadJSON:try json(["text":reply]))
            try await conversations.appendMessage(.init(id:UUID(),conversationID:conversationID,role:"assistant",content:reply,createdAt:Date(),runID:runID))
            try await runs.appendEvent(runID:runID,kind:.status,payloadJSON:try json(["state":"completed","reason":"fixture"]))
            _ = try await SQLiteWorkspaceStore(database:environment.database).ensureWorkspace(conversationID:conversationID,title:title)
            await environment.workspaceCenter.reload();await environment.conversationCenter.reload()
            router.openConversation(conversationID,runID:runID)
        } catch {
            FloeLogger(category:.app).error("nativeAnswerFixtureFailed errorType=\(String(describing:type(of:error)))")
        }
        #endif
    }
    /// Both modes use the production plan store and message projection.
    /// Confirmation only: no run, provider request, guest or paid service.
    private static func preparePlan(mode:String,environment:AppEnvironment,router:AppRouter) async throws {
        let conversations=SQLiteConversationStore(database:environment.database)
        let plans=SQLiteIntelligenceStore(database:environment.database)
        let runs=SQLiteRunStore(database:environment.database)
        if let old=try await conversations.conversation(id:planConversationID) {
            let prior=try await plans.latestPlan(conversationID:planConversationID)
            let messages=try await conversations.messages(conversationID:planConversationID)
            guard old.title == planTitle,old.purpose == .ordinary,old.visibility == .normal,
                  old.editorOwnership == nil,prior == nil || prior?.id == planID,
                  try await runs.runs(conversationID:planConversationID).isEmpty,
                  messages.allSatisfy({ $0.id == planRequestID || PlanConfirmationSnapshot.from(message:$0)?.plan.id == planID }) else {
                throw FloeError.validationFailed("Plan fixture identity already occupied; saved work was preserved")
            }
            try await conversations.deleteConversation(id:planConversationID)
        }
        try await conversations.saveConversation(.init(id:planConversationID,title:planTitle,createdAt:Date(),updatedAt:Date()))
        try await conversations.appendMessage(.init(id:planRequestID,conversationID:planConversationID,role:"user",
            content:"请为本地报告安排可执行、可验收的步骤，先保留计划供我确认。",createdAt:Date()))
        let submission=PlanSubmission(title:"交付一份可核对的本地报告",summary:"只整理本任务资料，不发送文件，也不安装软件。",
            sections:[
                .init(title:"整理输入",body:"读取已授权资料并列出字段；产物为输入清单。核对清单与源资料一致；无前置依赖。"),
                .init(title:"编写报告",body:"按清单生成 report.csv 并记录结论；产物为报告文件。读回字段及行数；依赖输入清单。"),
                .init(title:"核对并交付",body:"核对报告及来源后提交简短说明；产物为验证记录。确认文件可打开且内容匹配；依赖报告文件。")],
            assumptions:["只使用当前任务中已授权的资料"],
            acceptanceCriteria:[.init(text:"报告与输入一致",verification:"独立读回报告并核对字段、行数和结论来源")])
        guard submission.validationErrors.isEmpty else { throw FloeError.validationFailed("Plan fixture submission is invalid") }
        var plan=submission.draft(conversationID:planConversationID)
        plan.id=planID;plan.sourceMessageIDs=[planRequestID]
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        plan.digest=FloeDigest.sha256Hex(try encoder.encode(submission))
        try await plans.savePlanRevision(plan)
        if mode == "plan-accepted" {
            _ = try await plans.confirmPlan(plan,conversationID:planConversationID,execution:.normal)
        }
        guard try await runs.runs(conversationID:planConversationID).isEmpty else {
            throw FloeError.validationFailed("Plan fixture must not dispatch a run")
        }
        _ = try await SQLiteWorkspaceStore(database:environment.database)
            .ensureWorkspace(conversationID:planConversationID,title:planTitle)
        await environment.workspaceCenter.reload();await environment.conversationCenter.reload()
        router.openConversation(planConversationID)
    }
    /// One bounded native-only UI sample. The old eight chart/diff modes
    /// keep their producer paths. This mode exercises the actual task root,
    /// a persisted execution pin, a truncated writer receipt, and the reader.
    private static func largeTextOutput(environment:AppEnvironment) async throws -> ToolExecutionOutput {
        let store=SQLiteWorkspaceStore(database:environment.database)
        let workspace=try await store.ensureWorkspace(conversationID:conversationID,title:title)
        guard workspace.kind == .privateTask,
              workspace.internalRelativePath == "PrivateTasks/\(conversationID.uuidString)" else {
            throw FloeError.validationFailed("Fixture task workspace is not privately owned")
        }
        let lease=try await environment.workspaceCenter.acquireTaskRoot(workspace,conversationID:conversationID)
        defer { lease.release() }
        let root=lease.url.resolvingSymlinksInPath().standardizedFileURL
        let project=try await environment.environmentRegistry.ensureProjectContainer(
            workspaceID:FloeDigest.sha256Hex(Data(root.path.utf8)),workspaceRootPath:root.path,executionBackend:.linuxVM)
        // target() maps the real registry record only. It does not validate,
        // prepare, download or boot a Linux guest.
        let binding=TaskExecutionBinding(conversationID:conversationID,
            target:try environment.taskExecutionEnvironments.target(project))
        try await TaskExecutionBindingStore(database:environment.database).pinRun(runID:runID,binding:binding)
        let context=ToolContext(runID:runID,toolCallID:"call-native-answer-fixture",workspaceRootURL:root,
            cancellation:CancellationToken(),environmentID:binding.target.environmentID,
            executionBindingGeneration:binding.generation,conversationID:conversationID)
        let path="answer-large-text.txt",file=root.appendingPathComponent("answer-large-text.txt")
        let before="FLOE-QA-LARGE-TEXT-BASELINE\n"+String(repeating:"旧行\n",count:20_001)
        let paragraphs=(1...128).map { index in
            "段落 \(String(format:"%03d",index))："+String(repeating:"中文🙂测试",count:48)+"。\n\n"
        }.joined()
        let after="FLOE-QA-LARGE-TEXT-BEGIN\n\n"+paragraphs+"FLOE-QA-LARGE-TEXT-EOF-95B20771\n"
        let beforeBytes=Data(before.utf8),afterBytes=Data(after.utf8)
        guard afterBytes.count > 64 * 1024,afterBytes.count < 256 * 1024 else {
            throw FloeError.validationFailed("Fixture text is outside its bounded size")
        }
        let writer=WorkspaceWriteFileTool(environment:.init(rootProvider:{root}))
        if FileManager.default.fileExists(atPath:file.path) {
            let info=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard info.isRegularFile == true,info.isSymbolicLink == false,
                  let size=info.fileSize,size <= max(beforeBytes.count,afterBytes.count) else {
                throw FloeError.validationFailed("Fixture file is already occupied")
            }
            let existing=try Data(contentsOf:file)
            guard existing == beforeBytes || existing == afterBytes else {
                throw FloeError.validationFailed("Fixture file is already occupied")
            }
            _ = try await writer.execute(.init(path:path,content:before,expectedSHA256:FloeDigest.sha256Hex(existing)),context:context)
        } else {
            _ = try await WorkspaceCreateFileTool(environment:.init(rootProvider:{root}))
                .execute(.init(path:path,content:before),context:context)
        }
        // >20k old lines force the production comparison-too-large receipt;
        // the final file itself is normal multi-paragraph UTF-8, not a diff.
        let output=try await writer.execute(.init(path:path,content:after,expectedSHA256:FloeDigest.sha256Hex(beforeBytes)),context:context)
        guard try Data(contentsOf:file) == afterBytes,
              let artifact=output.artifacts.first,artifact.mimeType == "application/vnd.floe.file-preview+json",
              let artifactRoot=try? FloeArtifactStore.root() else {
            throw FloeError.validationFailed("Fixture did not save the intended large text")
        }
        let verified=try VerifiedChatInlineArtifact.load(artifact,runID:runID,tool:WorkspaceWriteFileTool.name,root:artifactRoot)
        let document=try JSONDecoder().decode(WorkspaceFileChangePreview.self,from:verified.data)
        guard document.path == path,document.truncated,document.byteCount == afterBytes.count,
              document.sha256 == FloeDigest.sha256Hex(afterBytes) else {
            throw FloeError.validationFailed("Fixture has no matching truncated native receipt")
        }
        return output
    }
    private static func json(_ values:[String:String]) throws -> String { String(decoding:try JSONSerialization.data(withJSONObject:values,options:[.sortedKeys]),as:UTF8.self) }
}
#endif
