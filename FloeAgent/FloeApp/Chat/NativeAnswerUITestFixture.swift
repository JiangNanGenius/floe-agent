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

@MainActor enum NativeAnswerUITestFixture {
    static let argument = "--ui-test-native-answer-fixture"
    static let conversationID = UUID(uuidString:"95B20771-2CC4-4B96-9FCA-9437BC412A10")!
    static let runID = UUID(uuidString:"95B20771-2CC4-4B96-9FCA-9437BC412A20")!
    static let title = "QA 原生正文与文件差异"

    static func prepareIfRequested(environment:AppEnvironment,router:AppRouter) async {
        #if targetEnvironment(simulator)
        let arguments=ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"),let index=arguments.firstIndex(of:argument),arguments.indices.contains(index+1) else { return }
        let mode=arguments[index+1]
        guard ["line","histogram","candlestick","treemap","sankey","gantt","small-diff","large-diff"].contains(mode) else { return }
        do {
            let conversations=SQLiteConversationStore(database:environment.database),runs=SQLiteRunStore(database:environment.database)
            let old=try await conversations.conversation(id:conversationID)
            if let old,old.title != title { throw FloeError.validationFailed("Fixture identity already occupied") }
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
            if let kind=ChartKind(rawValue:mode) {
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
    private static func json(_ values:[String:String]) throws -> String { String(decoding:try JSONSerialization.data(withJSONObject:values,options:[.sortedKeys]),as:UTF8.self) }
}
#endif
