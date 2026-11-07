// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(AppIntents)
import Foundation
import AppIntents
import Testing
import GRDB
import FloeCore
import FloeTools
import FloeNotes
import FloeAgentRuntime
import FloePersistence
@testable import FloeApp

/// Uses the production native chat-source read guard with an isolated DB;
/// no AppEnvironment, user's library, provider or model is started.
private nonisolated struct SQLFixtureConversationProvider: GlobalSourceProvider {
    let id = "app.formal-native.v1"
    let database: DatabaseManager
    func inventory(cursor:String?,limit:Int) async throws -> GlobalSourcePage { .init(sources:[],nextCursor:nil) }
    func read(_ source:GlobalSourceDescriptor) async throws -> GlobalSourceSnapshot {
        guard source.providerID == id else { throw GlobalSourceJobError.unavailable }
        return try await NativeGlobalSourceProvider.conversationSnapshot(source,database:database)
    }
    func isAccessible(_ source:GlobalSourceDescriptor) async -> Bool { (try? await read(source)) != nil }
}

@Suite("Literal SQLite search integration", .serialized)
@MainActor
struct SQLLiteralSearchIntegrationTests {
    private let base = Date(timeIntervalSince1970:1_700_500_000)
    private var body:String { #"季度总结报告 English marker contains 50% and under_score and shelf\mesh."# }
    private var literals:[String] { ["总结","English","%","_",#"\"#,"50%",#"shelf\mesh"#] }

    private func fixture() async throws -> (DatabaseManager,SQLiteIntelligenceStore,GlobalSourceIndexStore,GlobalSourceMemoryService) {
        let db = try DatabaseManager.inMemory(); try await db.migrate()
        let memories = SQLiteIntelligenceStore(database:db), index = GlobalSourceIndexStore(database:db)
        try await index.prepare()
        let pipeline = MemoryCandidatePipeline(documents:SQLitePersonalizationStore(database:db),memories:memories)
        let service = GlobalSourceMemoryService(index:index,memories:memories,candidates:pipeline,
            providers:[SQLFixtureConversationProvider(database:db)],embedding:nil,summary:nil)
        return (db,memories,index,service)
    }
    private func add(_ db:DatabaseManager,title:String = "Fixture",body:String,
                     purpose:ConversationPurpose = .ordinary,searchable:Bool = true,
                     visibility:ConversationVisibility = .normal,offset:Double = 0) async throws -> (UUID,UUID) {
        let conversation = UUID(), message = UUID(), date = base.addingTimeInterval(offset)
        let store = SQLiteConversationStore(database:db)
        try await store.saveConversation(.init(id:conversation,title:title,createdAt:date,updatedAt:date,purpose:purpose,visibility:visibility))
        try await store.appendMessage(.init(id:message,conversationID:conversation,role:"user",content:body,createdAt:date))
        if !searchable {
            try await db.writer { sql in try sql.execute(sql:"UPDATE conversations SET is_searchable=0 WHERE id=?",arguments:[conversation.uuidString]) }
        }
        return (conversation,message)
    }
    private func index(_ index:GlobalSourceIndexStore,conversation:UUID,message:UUID,body:String) async throws -> GlobalSourceDescriptor {
        let source = GlobalSourceDescriptor(id:"message:"+message.uuidString,providerID:"app.formal-native.v1",kind:.conversationMessage,
            ownerID:conversation.uuidString,revision:MemoryContentDigest.make(body),title:"Fixture",locator:message.uuidString,
            conversationID:conversation,messageID:message,modifiedAt:base)
        let snapshot = GlobalSourceSnapshot(source:source,text:body)
        _ = try await index.touch(source,token:"fixture")
        try await index.replace(snapshot,chunks:GlobalSourceTextPolicy.chunks(snapshot),seenToken:"fixture",queueSummary:false)
        return source
    }
    private func runner(_ service:GlobalSourceMemoryService,conversation:UUID,run:UUID) throws -> AnyAgentTool {
        let registry = ToolRunnerRegistry()
        ToolCatalog.register(GlobalMemorySearchTool.self)
        registry.register(GlobalMemorySearchTool(service:service,authorize:{ context in
            context.runID == run && context.conversationID == conversation && context.executionToolName == "memory.search"
                && context.allowedToolNames?.contains("memory.search") != false
                && context.frozenEffectiveCatalogNames?.contains("memory.search") != false
        }))
        let registered = try #require(registry.runner(named:"memory.search"))
        return AnyAgentTool(descriptor:registered.descriptor,run:registered.run,
            validateArguments:registered.validateArguments,routing:ToolEnvironmentRouting())
    }
    private func sourceIDs(_ output:ToolExecutionOutput) throws -> Set<String> {
        let object = try #require(JSONSerialization.jsonObject(with:Data((output.capturedOutput ?? output.summary).utf8)) as? [String:Any])
        let hits = try #require(object["sources"] as? [[String:Any]])
        return Set(try hits.map { hit in
            let source = try #require(hit["source"] as? [String:Any]); return try #require(source["id"] as? String)
        })
    }

    @Test("The actual global LIKE fallback handles Chinese and literal punctuation")
    func globalIndexLiteralFallback() async throws {
        let (db,_,index,_) = try await fixture()
        let wanted = try await add(db,body:body), decoy = try await add(db,body:"plain decoy percent words and underXscore shelfXmesh")
        let source = try await self.index(index,conversation:wanted.0,message:wanted.1,body:body)
        _ = try await self.index(index,conversation:decoy.0,message:decoy.1,body:"plain decoy percent words and underXscore shelfXmesh")
        for query in literals {
            let rows = try await index.lexical(query)
            #expect(Set(rows.map { $0.0.id }) == [source.id],"Query: \(query)")
        }
        #expect(try await index.lexical("absent").isEmpty)
        try await index.exclude(source.id,excluded:true)
        #expect(try await index.lexical("总结").isEmpty)
    }

    @Test("Registered memory.search executes the real index and hybrid branches without leaking ineligible sources")
    func registeredMemorySearch() async throws {
        let (db,_,index,service) = try await fixture()
        let visible = try await add(db,body:body)
        let hidden = try await add(db,body:body,searchable:false)
        let noteAssistant = try await add(db,body:body,purpose:.notes)
        let source = try await self.index(index,conversation:visible.0,message:visible.1,body:body)
        for value in [hidden,noteAssistant] { _ = try await self.index(index,conversation:value.0,message:value.1,body:body) }
        let run = UUID(), runner = try runner(service,conversation:visible.0,run:run)
        #expect(runner.descriptor.name == "memory.search" && runner.descriptor.effect == .readOnly)
        for query in literals {
            let args = try JSONSerialization.data(withJSONObject:["query":query])
            let output = try await runner.execute(argumentsJSON:args,
                context:.init(runID:run,cancellation:.init(),conversationID:visible.0))
            #expect(try sourceIDs(output) == [source.id],"Query: \(query)")
        }
        var wrongOwner = source; wrongOwner.ownerID = UUID().uuidString
        await #expect(throws:GlobalSourceJobError.self) {
            _ = try await NativeGlobalSourceProvider.conversationSnapshot(wrongOwner,database:db)
        }
        var wrongRevision = source; wrongRevision.revision = "stale"
        await #expect(throws:GlobalSourceJobError.self) {
            _ = try await NativeGlobalSourceProvider.conversationSnapshot(wrongRevision,database:db)
        }
        // A stale index cannot restore access after the native owner disables search.
        try await db.writer { sql in try sql.execute(sql:"UPDATE conversations SET is_searchable=0 WHERE id=?",arguments:[visible.0.uuidString]) }
        let output = try await runner.execute(argumentsJSON:Data(#"{"query":"总结"}"#.utf8),
            context:.init(runID:run,cancellation:.init(),conversationID:visible.0))
        #expect(try sourceIDs(output).isEmpty)
    }

    @Test("Memory discovery does not expand task, temporary-chat or cancellation authority")
    func registeredMemoryAuthority() async throws {
        let (db,_,_,service) = try await fixture()
        let visible = try await add(db,body:body), run = UUID()
        let runner = try runner(service,conversation:visible.0,run:run)
        let arguments = Data(#"{"query":"English"}"#.utf8)
        await #expect(throws:FloeError.self) {
            _ = try await runner.execute(argumentsJSON:arguments,context:.init(runID:run,cancellation:.init(),conversationID:UUID()))
        }
        await #expect(throws:FloeError.self) {
            _ = try await runner.execute(argumentsJSON:arguments,context:.init(runID:run,allowedToolNames:[],cancellation:.init(),conversationID:visible.0))
        }
        await #expect(throws:FloeError.self) {
            _ = try await runner.execute(argumentsJSON:arguments,context:.init(runID:run,cancellation:.init(),conversationID:visible.0,temporaryReadOnly:true))
        }
        await #expect(throws:FloeError.self) {
            _ = try await runner.execute(argumentsJSON:arguments,context:.init(runID:run,publicWebOnly:true,cancellation:.init(),conversationID:visible.0))
        }
        let token = CancellationToken(); token.cancel()
        await #expect(throws:FloeError.self) {
            _ = try await runner.execute(argumentsJSON:arguments,context:.init(runID:run,cancellation:token,conversationID:visible.0))
        }
    }

    @Test("Actual hybrid recall stays distinct from source LIKE retrieval and memory.list")
    func hybridRecallAndList() async throws {
        let (db,store,_,_) = try await fixture()
        let normal = MemoryEntry(scope:.userProfile,status:.active,content:#"MemoryAnchor 记忆锚点 50%_\mesh"#,confidence:1,importance:0.8,sourceKind:.explicitUserRequest)
        let rejected = MemoryEntry(scope:.userProfile,status:.rejected,content:normal.content + " rejected-state-fixture",confidence:1,importance:0.8,sourceKind:.explicitUserRequest)
        let expired = MemoryEntry(scope:.userProfile,status:.active,content:normal.content + " expired-state-fixture",confidence:1,importance:0.8,sourceKind:.explicitUserRequest,expiresAt:Date(timeIntervalSince1970:1))
        for memory in [normal,rejected,expired] { try await store.saveMemory(memory,evidence:[]) }
        for query in ["MemoryAnchor","记忆锚点"] {
            #expect(try await store.hybridRecall(.init(query:query)).map(\.id) == [normal.id])
        }
        for query in ["%","_",#"\"#] { _ = try await store.hybridRecall(.init(query:query)) }
        let registry = ToolRunnerRegistry()
        registry.register(MemoryListTool(store:store))
        let registered = try #require(registry.runner(named:"memory.list"))
        let list = AnyAgentTool(descriptor:registered.descriptor,run:registered.run,
            validateArguments:registered.validateArguments,routing:ToolEnvironmentRouting())
        let output = try await list.execute(argumentsJSON:Data(#"{"scope":"user","status":"active"}"#.utf8),context:.init(runID:UUID(),cancellation:.init()))
        #expect((output.capturedOutput ?? output.summary).contains(normal.id.uuidString))
        // No user DB or App environment was involved in either branch.
        #expect(try await db.reader { sql in try Int.fetchOne(sql,sql:"SELECT COUNT(*) FROM conversations") } == 0)
    }

    @Test("Conversation library snippets keep literal characters and search eligibility")
    func historySnippetLiterals() async throws {
        let (db,store,_,_) = try await fixture()
        let visible = try await add(db,body:body)
        _ = try await add(db,body:"plain decoy underXscore shelfXmesh")
        _ = try await add(db,body:body,searchable:false)
        _ = try await add(db,body:body,purpose:.notes)
        for query in literals {
            #expect(Set(try await store.matchingConversationSnippets(query).keys) == [visible.0])
        }
    }

    @Test("Conversation substring/title fallback retains workspace and date fences")
    func historyFallbackScope() async throws {
        let (db,store,_,_) = try await fixture()
        let owned = try await add(db,title:#"OnlyTitle%_\marker"#,body:body)
        let other = try await add(db,title:#"OnlyTitle%_\marker"#,body:body,offset:1)
        let hidden = try await add(db,title:#"OnlyTitle%_\marker"#,body:body,searchable:false)
        let notes = try await add(db,title:#"OnlyTitle%_\marker"#,body:body,purpose:.notes)
        let workspace = UUID(), foreign = UUID(), workspaces = SQLiteWorkspaceStore(database:db)
        try await workspaces.saveWorkspace(.init(id:workspace,name:"Owned",rootBookmark:Data()))
        try await workspaces.saveWorkspace(.init(id:foreign,name:"Other",rootBookmark:Data()))
        try await db.writer { sql in
            for value in [owned,hidden,notes] {
                try sql.execute(sql:"INSERT INTO conversation_workspace_ownership(conversation_id,workspace_id,assigned_at) VALUES (?,?,?)",arguments:[value.0.uuidString,workspace.uuidString,"2023-01-01T00:00:00Z"])
            }
            try sql.execute(sql:"INSERT INTO conversation_workspace_ownership(conversation_id,workspace_id,assigned_at) VALUES (?,?,?)",arguments:[other.0.uuidString,foreign.uuidString,"2023-01-01T00:00:00Z"])
        }
        for query in ["总结",#"OnlyTitle%_\marker"#] {
            let hits = try await store.search(.init(query:query,workspaceID:workspace))
            #expect(Set(hits.map(\.conversationID)) == [owned.0])
            #expect(hits.allSatisfy { $0.workspaceID == workspace })
            #expect(try await store.search(.init(query:query,workspaceID:workspace,startDate:base.addingTimeInterval(60))).isEmpty)
        }
    }

    @Test("Notes authority searches literal body/title values and excludes trash")
    func notesStoreSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("literal-notes-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try NotesStore(root:root)
        var wanted = NoteDocument(title:#"Title%_\fixture"#); wanted.pages[0].elements = [NoteElement(text:body)]
        let saved = try await store.create(wanted)
        _ = try await store.create(NoteDocument(title:"Plain decoy underXscore shelfXmesh"))
        var trashSource = NoteDocument(title:wanted.title); trashSource.pages[0].elements = [NoteElement(text:body)]
        let trash = try await store.create(trashSource)
        _ = try await store.setTrashed(trash.id,expectedRevision:trash.revision,trashed:true)
        for query in literals + [#"Title%_\fixture"#] {
            #expect(try await store.search(query).map(\.id) == [saved.id])
        }
    }

    @Test("Authenticated shortcut title lookup keeps visible active ordinary-task rules")
    func shortcutRunTitleQuery() async throws {
        let (db,_,_,_) = try await fixture()
        let title = #"计划 English %_\fixture"#
        let visible = try await add(db,title:title,body:"visible")
        _ = try await add(db,title:"Plain decoy with underXscore",body:"plain")
        _ = try await add(db,title:title,body:"hidden",visibility:.skillAuthoring)
        _ = try await add(db,title:title,body:"notes",purpose:.notes)
        let archived = try await add(db,title:title,body:"archived")
        try await SQLiteConversationStore(database:db).setArchived(id:archived.0,archived:true)
        for query in ["计划","English","%","_",#"\"#,#"%_\fixture"#] {
            #expect(try await FindFloeRunsIntent.matchingConversationIDs(name:query,limit:20,database:db) == [visible.0.uuidString])
        }
        #expect(try await FindFloeRunsIntent.matchingConversationIDs(name:" ",limit:20,database:db).isEmpty)
        #expect(FindFloeRunsIntent.authenticationPolicy == .requiresLocalDeviceAuthentication)
    }
}
#endif
