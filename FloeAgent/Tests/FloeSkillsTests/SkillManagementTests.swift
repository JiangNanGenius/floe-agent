import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeSkills

private actor ManagedSkillFixture: SkillManaging {
    var mutations = 0
    func read(id: String?) async throws -> [ManagedSkill] {
        [.init(id: "example", name: "Example", version: "1.0.0", enabled: true, digest: String(repeating: "a", count: 64), markdown: id == nil ? nil : "body")]
    }
    func manage(_ request: SkillManageTool.Arguments) async throws -> String { mutations += 1; return "applied" }
}

private struct DiscoverySkillFixture: SkillManaging {
    let rows: [ManagedSkill]
    func read(id: String?) async throws -> [ManagedSkill] { rows }
    func manage(_ request: SkillManageTool.Arguments) async throws -> String {
        throw FloeError.validationFailed("Discovery cannot mutate")
    }
}

/// Records exactly what the exact-read resource overload receives, so the
/// production wrapper cannot silently drop the run binding through the
/// protocol's legacy default.
private actor ContextAwareSkillFixture: SkillManaging {
    struct Recorded: Sendable, Equatable {
        let environmentID: String?
        let workspaceRoot: String?
        let runID: UUID
    }

    private(set) var contextReads = 0
    private(set) var legacyRunReads = 0
    private(set) var lastContext: Recorded?
    let guestRoot = "/workspace/.floe/skills/example@" + String(repeating: "a", count: 64)
    let markdown: String

    init(markdown: String = "body") { self.markdown = markdown }

    func read(id: String?) async throws -> [ManagedSkill] {
        [.init(id: "example", name: "Example", version: "1.0.0", enabled: true,
               digest: String(repeating: "a", count: 64), markdown: id == nil ? nil : markdown)]
    }

    func read(id: String?, runID: UUID) async throws -> [ManagedSkill] {
        legacyRunReads += 1
        return try await read(id: id)
    }

    func read(id: String, runID: UUID, resourceContext: SkillResourceContext) async throws -> [ManagedSkill] {
        contextReads += 1
        lastContext = Recorded(
            environmentID: resourceContext.environmentID,
            workspaceRoot: resourceContext.workspaceRootURL?.path,
            runID: runID
        )
        var rows = try await read(id: id)
        rows[0].resources = SkillResourceAvailability(
            staged: true, guestRoot: guestRoot,
            pinnedSHA256: String(repeating: "a", count: 64),
            fileCount: 3, reason: nil
        )
        return rows
    }

    func manage(_ request: SkillManageTool.Arguments) async throws -> String { "applied" }
}

@Suite("Skill management contracts")
struct SkillManagementTests {
    @Test func thirdPartyDescriptionsMatchIndependentQueriesWithoutLeakingInstructions() async throws {
        let rows = [
            ManagedSkill(id: "custom-alpha", name: "Alpha", version: "1", enabled: false, digest: "a", markdown: "Private instructions", description: "Prepare invoices and reconcile receipts. 发票报销"),
            ManagedSkill(id: "custom-beta", name: "Beta", version: "1", enabled: true, digest: "b", description: "Café reservations"),
            ManagedSkill(id: "floe-office", name: "Office", version: "1", enabled: true, digest: "c")
        ]
        let tool = SkillSearchTool(manager: DiscoverySkillFixture(rows: rows))
        let result = try await tool.execute(.init(queries: ["发票报销", "CAFE", "PowerPoint"]), context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.summary.utf8)) as? [String: Any])
        let matches = try #require(object["matches"] as? [[String: Any]])
        let queries = try #require(object["queryMatches"] as? [[String: Any]])
        #expect(queries.compactMap { $0["skillIDs"] as? [String] } == [["custom-alpha"], ["custom-beta"], ["floe-office"]])
        #expect(matches.first?["enabled"] as? Bool == false)
        #expect(matches.first?["description"] as? String == rows[0].description)
        #expect(matches.allSatisfy { $0["markdown"] == nil })
        #expect(!result.summary.contains("Private instructions"))
        #expect(SkillSearchTool.matches(query: "private instructions", rows: rows).isEmpty)
    }

    @Test func largeMetadataPagesRemainValidAndEnumerateEveryID() async throws {
        // JSON escaping exceeds the response budget before reaching the count limit.
        let rows = (0..<100).map { index in
            ManagedSkill(id: String(format: "custom-%03d", index), name: "Custom", version: "1", enabled: index % 2 == 0, digest: "a", markdown: "Do not activate", description: String(repeating: "\u{0001}", count: 1_024))
        }
        let tool = SkillListTool(manager: DiscoverySkillFixture(rows: rows.reversed()))
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        var cursor: String?
        var ids: [String] = []
        var pages = 0
        repeat {
            let output = try await tool.execute(.init(afterID: cursor, limit: 100), context: context)
            let object = try #require(JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
            let page = try #require(object["skills"] as? [[String: Any]])
            #expect(!page.isEmpty)
            #expect(page.allSatisfy { $0["markdown"] == nil })
            #expect(object["total"] as? Int == 100)
            ids += page.compactMap { $0["id"] as? String }
            cursor = object["nextAfterID"] as? String
            pages += 1
            #expect(pages <= 100)
        } while cursor != nil && pages < 100
        #expect(pages > 1)
        #expect(ids == rows.map(\.id))
    }

    @Test func previousMetadataStillDecodesWithoutDescription() throws {
        let data = Data(#"{"id":"old","name":"Old","version":"1","enabled":true,"digest":"a"}"#.utf8)
        #expect(try JSONDecoder().decode(ManagedSkill.self, from: data).description == nil)
        // Previous invocations never carried resource availability; decoding
        // must stay compatible and default to nil.
        #expect(try JSONDecoder().decode(ManagedSkill.self, from: data).resources == nil)
    }

    @Test func exactReadCarriesRunBindingWhileListAndSearchNeverStage() async throws {
        let fixture = ContextAwareSkillFixture()
        let runID = UUID()
        let workspace = URL(fileURLWithPath: "/tmp/floe-skill-workspace", isDirectory: true)
        let tool = SkillReadTool(manager: fixture)
        let context = ToolContext(runID: runID, workspaceRootURL: workspace,
                                  cancellation: CancellationToken(), environmentID: "env-local-1")

        // List and search must keep the legacy, staging-free path.
        let list = try await tool.execute(.init(), context: context)
        let listRows = try JSONDecoder().decode([ManagedSkill].self, from: Data(list.summary.utf8))
        #expect(listRows.first?.resources == nil)
        _ = try await SkillSearchTool(manager: fixture).execute(.init(queries: ["example"]), context: context)
        #expect(await fixture.contextReads == 0)

        let detail = try await tool.execute(.init(id: "example"), context: context)
        #expect(await fixture.contextReads == 1)
        let recorded = try #require(await fixture.lastContext)
        #expect(recorded.environmentID == "env-local-1")
        #expect(recorded.workspaceRoot == workspace.path)
        #expect(recorded.runID == runID)
        let row = try #require(try JSONDecoder().decode([ManagedSkill].self, from: Data(detail.summary.utf8)).first)
        #expect(row.resources?.staged == true)
        #expect(row.resources?.guestRoot == fixture.guestRoot)
        #expect(row.resources?.fileCount == 3)
        #expect(row.resources?.reason == nil)
    }

    @Test func temporaryChatExactReadCarriesNoEnvironmentBinding() async throws {
        // Temporary chats are RAM-only: the exact read may not be bound to a
        // workspace, so the manager reports an honest unavailable status.
        let fixture = ContextAwareSkillFixture()
        let tool = SkillReadTool(manager: fixture)
        let context = ToolContext(runID: UUID(), workspaceRootURL: URL(fileURLWithPath: "/tmp/ws"),
                                  cancellation: CancellationToken(), environmentID: "env-local",
                                  temporaryReadOnly: true)
        _ = try await tool.execute(.init(id: "example"), context: context)
        let recorded = try #require(await fixture.lastContext)
        #expect(recorded.environmentID == nil)
        #expect(recorded.workspaceRoot == nil)
    }

    @Test func managersWithoutStagingKeepTheExactPreviousReadShape() async throws {
        // The protocol default delegates the context overload to the legacy
        // read, so a manager with no resource delivery keeps working and can
        // never fabricate a guest path.
        let tool = SkillReadTool(manager: ManagedSkillFixture())
        let context = ToolContext(runID: UUID(), workspaceRootURL: URL(fileURLWithPath: "/tmp/ws"),
                                  cancellation: CancellationToken(), environmentID: "env-local")
        let detail = try await tool.execute(.init(id: "example"), context: context)
        let row = try #require(try JSONDecoder().decode([ManagedSkill].self, from: Data(detail.summary.utf8)).first)
        #expect(row.markdown == "body")
        #expect(row.resources == nil)
    }

    @Test func resourceStatusStaysBoundedAndVisibleAcrossPagination() async throws {
        let fixture = ContextAwareSkillFixture(markdown: String(repeating: "x", count: 10_000))
        let tool = SkillReadTool(manager: fixture)
        let context = ToolContext(runID: UUID(), workspaceRootURL: URL(fileURLWithPath: "/tmp/ws"),
                                  cancellation: CancellationToken(), environmentID: "env-local")
        let first = try await tool.execute(.init(id: "example", offset: 0, limit: 100), context: context)
        let firstRow = try #require(try JSONDecoder().decode([ManagedSkill].self, from: Data(first.summary.utf8)).first)
        #expect(firstRow.markdown?.count == 100)
        #expect(firstRow.nextOffset == 100)
        // The portable root survives pagination outside the paginated Markdown.
        #expect(firstRow.resources?.guestRoot == fixture.guestRoot)
        let last = try await tool.execute(.init(id: "example", offset: 9_900, limit: 100), context: context)
        let lastRow = try #require(try JSONDecoder().decode([ManagedSkill].self, from: Data(last.summary.utf8)).first)
        #expect(lastRow.nextOffset == nil)
        #expect(lastRow.resources?.guestRoot == fixture.guestRoot)

        // Metadata stays compact: no per-file paths or hashes are duplicated
        // into every paginated read. `reason` is absent while staged because
        // the encoder omits nil optionals.
        let object = try #require(try JSONSerialization.jsonObject(with: Data(first.summary.utf8)) as? [[String: Any]])
        let resources = try #require(object.first?["resources"] as? [String: Any])
        #expect(Set(resources.keys) == ["staged", "guestRoot", "pinnedSHA256", "fileCount"])
        #expect(SkillReadTool.toolDescription.contains("guest root"))
        #expect(SkillReadTool.toolDescription.contains("$CODEX_HOME/skills/"))
        #expect(!SkillReadTool.isSideEffecting)
    }
    @Test func explicitListNeverReturnsInstructionsOrMutates() async throws {
        let manager = ManagedSkillFixture()
        let tool = SkillListTool(manager: manager)
        let output = try await tool.execute(.init(limit: 1), context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
        let rows = try #require(object["skills"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows.first?["markdown"] == nil)
        #expect(object["total"] as? Int == 1)
        #expect(await manager.mutations == 0)
        let empty = try await tool.execute(.init(afterID: "example"), context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        #expect(empty.summary.contains("\"skills\":[]"))
    }
    @Test func workflowSearchFindsCapabilitiesWithoutActivation() {
        let rows = ["floe-python", "floe-office", "floe-network", "floe-pdf"].map {
            ManagedSkill(id: $0, name: $0, version: "1.0.0", enabled: true, digest: "test")
        }
        #expect(SkillSearchTool.matches(query: "pandas 数据分析", rows: rows).first?.id == "floe-python")
        #expect(SkillSearchTool.matches(query: "PDF、网络、Python", rows: rows).count == 3)
        #expect(SkillSearchTool.matches(query: "nothing matches", rows: rows).isEmpty)
        #expect(!SkillSearchTool.isSideEffecting)
    }
    @Test func exactArgumentsAndNoTraversal() throws {
        let tool = SkillManageTool(manager: ManagedSkillFixture())
        let digest = String(repeating: "a", count: 64)
        try tool.validate(.init(action: .update, id: "example", expectedDigest: digest, instructions: "new body"))
        for id in ["../example", "/root", ".", "a/b"] {
            #expect(throws: FloeError.self) { try tool.validate(.init(action: .remove, id: id, expectedDigest: digest)) }
        }
        #expect(throws: FloeError.self) { try tool.validate(.init(action: .remove, id: "example", expectedDigest: digest, instructions: "ambiguous")) }
        #expect(throws: FloeError.self) { try tool.validate(.init(action: .setEnabled, id: "example", expectedDigest: digest)) }
        #expect(throws: FloeError.self) { try tool.validate(.init(action: .update, id: "example", expectedDigest: "stale", instructions: "body")) }
    }
    @Test func noGrantCannotMutate() async throws {
        let manager = ManagedSkillFixture()
        let tool = SkillManageTool(manager: manager)
        await #expect(throws: FloeError.self) {
            try await tool.execute(.init(action: .remove, id: "example", expectedDigest: String(repeating: "a", count: 64)), context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        }
        #expect(await manager.mutations == 0)
    }
    @Test func listAndDetailAreStructuredAndReadOnly() async throws {
        let tool = SkillReadTool(manager: ManagedSkillFixture())
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        let list = try await tool.execute(.init(), context: context)
        let detail = try await tool.execute(.init(id: "example"), context: context)
        #expect(try JSONDecoder().decode([ManagedSkill].self, from: Data(list.summary.utf8)).first?.markdown == nil)
        #expect(try JSONDecoder().decode([ManagedSkill].self, from: Data(detail.summary.utf8)).first?.markdown == "body")
        #expect(!SkillReadTool.isSideEffecting)
        #expect(SkillManageTool.isSideEffecting)
        let page = try await tool.execute(.init(id: "example", offset: 0, limit: 2), context: context)
        let decoded = try JSONDecoder().decode([ManagedSkill].self, from: Data(page.summary.utf8))[0]
        #expect(decoded.markdown == "bo")
        #expect(decoded.nextOffset == 2)
        let last = try await tool.execute(.init(id: "example", offset: 2, limit: 2), context: context)
        #expect(try JSONDecoder().decode([ManagedSkill].self, from: Data(last.summary.utf8))[0].markdown == "dy")
    }
}
