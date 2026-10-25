// FloeSkillsTests — the optional curated Hub boundary on the EXISTING skill
// tools (SkillHubToolContract). Every legacy behavior asserted here through
// the ORIGINAL constructors and defaults; the new assertions cover only the
// injected boundary: isolated catalog availability, bounded discovery, review-
// only hub reads with honest temp refusal, discriminated install validation,
// gate-before-IO ordering, and typed receipt integrity. Fakes supply verified
// metadata shapes only — the real native client is trusted by injection, not
// by these tests.

import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeSkills

// MARK: - Shared bounded fixtures

private let hubPinY = String(repeating: "b", count: 40)
private let hubSourceX = String(repeating: "a", count: 40)
private let hubCatalogDigest = String(repeating: "c", count: 64)
private let hubContentDigest = String(repeating: "d", count: 64)
private let hubPackageSHA = String(repeating: "e", count: 64)
private let hubReviewDigest = String(repeating: "f", count: 64)

private func makeProvenance(
    publicationCommit: String = hubPinY,
    sourceCommit: String? = hubSourceX
) throws -> SkillHubProvenance {
    try SkillHubProvenance(
        hubRepository: "github.com/jiangnangenius/floe-skill-hub",
        publisher: "JiangNanGenius",
        channel: .ios,
        feedStatus: .production,
        signatureKeyID: "official-2026-09",
        sourceCommit: sourceCommit,
        publicationCommit: publicationCommit,
        catalogDigest: hubCatalogDigest,
        contentDigest: hubContentDigest,
        packageSHA256: hubPackageSHA,
        reviewDigest: hubReviewDigest
    )
}

private func makeEntry(
    id: String,
    version: String = "1.0.0",
    nameEN: String = "Guide",
    nameZH: String = "指南",
    descriptionEN: String = "A reusable workflow",
    descriptionZH: String = "可复用工作流",
    category: String? = "productivity-organization",
    tags: [String] = ["writing", "报告"],
    offer: SkillHubInstallOffer = .qualified,
    containsScripts: Bool = false,
    provenance: SkillHubProvenance? = try? makeProvenance()
) throws -> SkillHubCatalogEntry {
    try SkillHubCatalogEntry(
        id: id,
        version: version,
        kind: .optional,
        name: .name(en: nameEN, zhHans: nameZH),
        description: .description(en: descriptionEN, zhHans: descriptionZH),
        category: category,
        tags: tags,
        containsScripts: containsScripts,
        installOffer: offer,
        reviewed: offer == .qualified,
        qualified: offer == .qualified,
        published: offer == .qualified,
        minimumAppVersion: "1.7.0",
        provenance: provenance
    )
}

private func makeDetail(
    reviewedTools: [String] = ["exec.shell"],
    id: String = "hub-candidate",
    instructions: String? = "# Review only\nApply the workflow carefully.\n",
    bundledFiles: [String] = ["SKILL.md", "references/guide.md"]
) throws -> SkillHubCatalogDetail {
    try SkillHubCatalogDetail(
        entry: makeEntry(id: id),
        instructions: instructions,
        bundledFiles: bundledFiles,
        fileCount: 2,
        totalBytes: 512,
        reviewedCapabilities: ["data.transform"],
        reviewedTools: reviewedTools
    )
}

private struct HubToolManager: SkillManaging {
    let rows: [ManagedSkill]
    func read(id: String?) async throws -> [ManagedSkill] {
        guard let id else {
            // Metadata lists never carry instruction bodies (production-shaped).
            return rows.map { row in var copy = row; copy.markdown = nil; return copy }
        }
        return rows.filter { $0.id == id }
    }
    func manage(_ request: SkillManageTool.Arguments) async throws -> String {
        throw FloeError.validationFailed("This fixture cannot mutate")
    }
}

private actor FakeCatalogProvider: SkillHubCatalogProviding {
    private(set) var entryCalls = 0
    private(set) var detailCalls = 0
    private(set) var detailRunIDs: [UUID] = []
    private(set) var detailOwnerIDs: [UUID?] = []
    private let entries: [SkillHubCatalogEntry]
    private let details: [String: SkillHubCatalogDetail]
    private let failure: (any Error)?

    init(
        entries: [SkillHubCatalogEntry] = [],
        details: [String: SkillHubCatalogDetail] = [:],
        failure: (any Error)? = nil
    ) {
        self.entries = entries
        self.details = details
        self.failure = failure
    }

    func verifiedCatalogEntries() async throws -> [SkillHubCatalogEntry] {
        entryCalls += 1
        if let failure { throw failure }
        return entries
    }

    func verifiedCatalogDetail(id: String) async throws -> SkillHubCatalogDetail? {
        detailCalls += 1
        if let failure { throw failure }
        return details[id]
    }
    func verifiedCatalogDetail(id: String, context: ToolContext) async throws -> SkillHubCatalogDetail? {
        detailRunIDs.append(context.runID)
        detailOwnerIDs.append(context.conversationID)
        return try await verifiedCatalogDetail(id: id)
    }
}

private actor RecordingWorkspaceInstaller: SkillWorkspaceInstalling {
    private(set) var plans: [SkillWorkspaceInstallPlan] = []
    func install(_ plan: SkillWorkspaceInstallPlan) async throws -> SkillWorkspaceInstallCommit {
        plans.append(plan)
        return SkillWorkspaceInstallCommit(
            skillID: plan.package.skillID,
            version: plan.package.version,
            canonicalSHA256: plan.package.canonicalSHA256,
            previousDigest: nil
        )
    }
    func planCount() -> Int { plans.count }
}

private actor FakeHubInstaller: SkillHubInstalling {
    private(set) var requests: [SkillHubInstallRequest] = []
    private(set) var contexts: [ToolContext] = []
    private let outcome: FakeHubOutcome

    init(_ outcome: FakeHubOutcome) { self.outcome = outcome }

    func install(_ request: SkillHubInstallRequest, context: ToolContext) async throws -> SkillHubInstallReceipt {
        requests.append(request)
        contexts.append(context)
        switch outcome {
        case .receipt(let receipt):
            return receipt
        case .cancelDuringCommit(let receipt, let token):
            // The bridge commits, THEN cancellation arrives: it must return
            // the receipt so the tool reports what actually landed.
            token.cancel()
            return receipt
        case .cancelBeforeCommit(let token):
            // Nothing durably committed: honor the live token and throw.
            token.cancel()
            try context.cancellation.throwIfCancelled()
            throw CancellationError()
        case .failure(let error):
            throw error
        }
    }
    func requestCount() -> Int { requests.count }
    func recordedContext() -> ToolContext? { contexts.first }
}

private enum FakeHubOutcome {
    case receipt(SkillHubInstallReceipt)
    case cancelDuringCommit(SkillHubInstallReceipt, CancellationToken)
    case cancelBeforeCommit(CancellationToken)
    case failure(any Error)
}

private func makeReceipt(
    reviewedTools: [String] = ["exec.shell"],
    skillID: String = "hub-candidate",
    publicationCommit: String = hubPinY,
    sourceCommit: String? = hubSourceX,
    contentDigest: String = hubContentDigest
) throws -> SkillHubInstallReceipt {
    try SkillHubInstallReceipt(
        status: .installed,
        skillID: skillID,
        version: "1.0.0",
        contentDigest: contentDigest,
        packageSHA256: hubPackageSHA,
        catalogDigest: hubCatalogDigest,
        reviewDigest: hubReviewDigest,
        sourceCommit: sourceCommit,
        publicationCommit: publicationCommit,
        containsScripts: false,
        fileCount: 3,
        totalBytes: 2_048,
        reviewedCapabilities: ["data.transform"],
        reviewedTools: reviewedTools
    )
}

private func hubContext(
    approved: Bool = true,
    temporary: Bool = false,
    workspace: URL? = nil,
    cancellation: CancellationToken = CancellationToken()
) -> ToolContext {
    ToolContext(
        runID: UUID(),
        approvalGrantID: approved ? UUID() : nil,
        workspaceRootURL: workspace,
        cancellation: cancellation,
        temporaryReadOnly: temporary
    )
}

// MARK: - Legacy behavior preserved

@Suite("SkillHubToolContract legacy compatibility")
struct SkillHubToolContractLegacyTests {

    @Test("Legacy constructors and the omitted-catalog search shape are unchanged")
    func legacyShapes() async throws {
        let rows = [ManagedSkill(id: "custom-alpha", name: "Alpha", version: "1", enabled: true, digest: "a", markdown: "Secret body", description: "Invoice help")]
        // The ORIGINAL single-argument constructor still exists and produces
        // the byte-identical legacy response keys.
        let tool = SkillSearchTool(manager: HubToolManager(rows: rows))
        let output = try await tool.execute(.init(query: "invoice"), context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["matches", "queryMatches", "nextAction"])
        #expect((object["matches"] as? [[String: Any]])?.first?["markdown"] == nil)
        #expect(!output.summary.contains("Secret body"))

        // skill.read without `source` keeps returning the [ManagedSkill] array.
        let reader = SkillReadTool(manager: HubToolManager(rows: rows))
        let list = try await reader.execute(.init(), context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        let decoded = try JSONDecoder().decode([ManagedSkill].self, from: Data(list.summary.utf8))
        #expect(decoded.first?.id == "custom-alpha")
        // Old argument JSON (no `source` key) still decodes as installed.
        let legacyArgs = try JSONDecoder().decode(SkillReadTool.Arguments.self, from: Data(#"{"id":"custom-alpha"}"#.utf8))
        #expect(legacyArgs.source == nil)
        // The workspace install tool keeps its legacy memberwise form and the
        // default directory flow through the legacy installer bridge.
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-hub-legacy-\(UUID().uuidString)", isDirectory: true)
        let packageRoot = workspace.appendingPathComponent("skills/legacy-flow-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        try Data("---\nname: legacy-flow-skill\ndescription: Reusable legacy flow\n---\n# legacy-flow-skill\nUse this workflow.\n".utf8)
            .write(to: packageRoot.appendingPathComponent("SKILL.md"), options: .atomic)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let installer = RecordingWorkspaceInstaller()
        let installTool = SkillWorkspaceInstallTool(installer: installer)
        let arguments = SkillWorkspaceInstallTool.Arguments(directory: "skills/legacy-flow-skill")
        let installed = try await installTool.execute(arguments, context: hubContext(workspace: workspace))
        #expect(installed.exitStatus == 0)
        #expect(installed.summary.contains("status=installed id=legacy-flow-skill"))
        #expect(installed.summary.contains("source=floe-folder://local/skills/legacy-flow-skill"))
        #expect(await installer.planCount() == 1)
    }

    @Test("Hub matches and availability are omitted entirely without a bridge")
    func bridgeAbsentOmitsNewFields() async throws {
        let rows = [ManagedSkill(id: "custom-alpha", name: "Alpha", version: "1", enabled: true, digest: "a", description: "help")]
        let searchOutput = try await SkillSearchTool(manager: HubToolManager(rows: rows))
            .execute(.init(query: "help"), context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        let object = try #require(JSONSerialization.jsonObject(with: Data(searchOutput.summary.utf8)) as? [String: Any])
        #expect(object["hubMatches"] == nil)
        #expect(object["hubQueryMatches"] == nil)
        #expect(object["catalogAvailability"] == nil)
        // hub read without a bridge fails honestly (no fallback to installed rows).
        await #expect(throws: FloeError.self) {
            try await SkillReadTool(manager: HubToolManager(rows: rows)).execute(
                .init(id: "custom-alpha", source: .hub),
                context: hubContext()
            )
        }
        // hub install without a bridge: honest notConfigured, never the
        // workspace branch or an interpreter fallback.
        let installer = RecordingWorkspaceInstaller()
        await #expect(throws: SkillHubInstallError.notConfigured) {
            try await SkillWorkspaceInstallTool(installer: installer).execute(
                .init(source: .hub, id: "hub-candidate"), context: hubContext()
            )
        }
        #expect(await installer.planCount() == 0)
    }
}

// MARK: - skill.search catalog boundary

@Suite("SkillHubToolContract discovery")
struct SkillHubToolSearchTests {

    @Test("Installed results survive an unavailable or invalid catalog; a real empty stays honest")
    func catalogFailureIsIsolated() async throws {
        let rows = [ManagedSkill(id: "custom-alpha", name: "Alpha", version: "1", enabled: true, digest: "a", description: "Invoice help")]
        for failure in [SkillHubCatalogError.unavailable("network offline"), SkillHubCatalogError.invalid("catalog signature mismatch")] {
            let provider = FakeCatalogProvider(entries: [], failure: failure)
            let tool = SkillSearchTool(manager: HubToolManager(rows: rows), catalog: provider)
            let output = try await tool.execute(.init(query: "invoice"), context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
            let object = try #require(JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
            let matches = try #require(object["matches"] as? [[String: Any]])
            #expect(matches.first?["id"] as? String == "custom-alpha")
            let availability = try #require(object["catalogAvailability"] as? [String: Any])
            if case .unavailable = failure {
                #expect(availability["state"] as? String == "unavailable")
            } else {
                #expect(availability["state"] as? String == "invalid")
            }
            #expect(availability["message"] as? String != nil)
            #expect((object["hubMatches"] as? [[String: Any]])?.isEmpty == true)
            // NOT a fake valid empty: the availability state distinguishes it.
            #expect((object["hubQueryMatches"] as? [[String: Any]])?.first?["skillIDs"] as? [String] == [])
        }
        // A verified catalog with genuinely no match stays state=available.
        let quiet = FakeCatalogProvider(entries: [try makeEntry(id: "unrelated-guide", descriptionEN: "Charts", descriptionZH: "图表")])
        let okOutput = try await SkillSearchTool(manager: HubToolManager(rows: rows), catalog: quiet)
            .execute(.init(query: "invoice"), context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        let okObject = try #require(JSONSerialization.jsonObject(with: Data(okOutput.summary.utf8)) as? [String: Any])
        #expect((okObject["catalogAvailability"] as? [String: Any])?["state"] as? String == "available")
    }

    @Test("Discovery never leaks instruction or resource bodies and marks rows uninstalled")
    func noInstructionLeak() async throws {
        let entry = try makeEntry(id: "hub-candidate", nameEN: "Report helper", nameZH: "报告助手")
        let provider = FakeCatalogProvider(
            entries: [entry],
            details: ["hub-candidate": try makeDetail(instructions: "PRIVATE-INSTRUCTION-BODY apply this")]
        )
        let tool = SkillSearchTool(manager: HubToolManager(rows: []), catalog: provider)
        let output = try await tool.execute(.init(query: "报告"), context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        #expect(!output.summary.contains("PRIVATE-INSTRUCTION-BODY"))
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
        let hub = try #require(object["hubMatches"] as? [[String: Any]])
        #expect(hub.first?["instructions"] == nil)
        #expect(hub.first?["bundledFiles"] == nil)
        #expect(hub.first?["enabled"] == nil)
        // zh metadata matches a zh query and English metadata matches English.
        #expect(hub.first?["id"] as? String == "hub-candidate")
        #expect((object["hubNextAction"] as? String)?.contains("uninstalled") == true)
        // Provenance stays plain fields with separate X and Y (X != Y normal).
        let provenance = try #require(hub.first?["provenance"] as? [String: Any])
        #expect(provenance["publicationCommit"] as? String == hubPinY)
        #expect(provenance["sourceCommit"] as? String == hubSourceX)
    }

    @Test("Hub matches are bounded per query and never merge over an installed identity")
    func perQueryBoundsAndInstalledChoiceWins() async throws {
        var entries: [SkillHubCatalogEntry] = []
        for index in 1...12 {
            entries.append(try makeEntry(id: String(format: "hub-report-%02d", index), nameEN: "Report \(index)", nameZH: "报告"))
        }
        // A misbehaving snapshot that duplicates one id cannot double-list it.
        entries.append(try makeEntry(id: "hub-report-03", version: "1.0.1", nameEN: "Report duplicate", nameZH: "报告"))
        let rows = [ManagedSkill(id: "hub-report-01", name: "User choice", version: "1", enabled: false, digest: "a", description: "报告 helper")]
        let provider = FakeCatalogProvider(entries: entries)
        let tool = SkillSearchTool(manager: HubToolManager(rows: rows), catalog: provider)
        let output = try await tool.execute(.init(query: "报告"), context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
        let hub = try #require(object["hubMatches"] as? [[String: Any]])
        #expect(hub.count == SkillHubSearch.maximumMatchesPerQuery)
        let ids = hub.compactMap { $0["id"] as? String }
        // The installed id (even disabled) is excluded, never merged over.
        #expect(!ids.contains("hub-report-01"))
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count)
        let installed = try #require(object["matches"] as? [[String: Any]])
        #expect(installed.first?["id"] as? String == "hub-report-01")
        #expect(installed.first?["enabled"] as? Bool == false)
    }
}

// MARK: - skill.read hub source

@Suite("SkillHubToolContract hub read")
struct SkillHubToolReadTests {

    @Test("Hub pagination forwards the same runtime run and owner to the native snapshot provider")
    func hubReadForwardsRuntimeSnapshotIdentity() async throws {
        let provider = FakeCatalogProvider(details: ["hub-candidate": try makeDetail()])
        let tool = SkillReadTool(manager: HubToolManager(rows: []), catalog: provider)
        let ctx = hubContext()
        _ = try await tool.execute(.init(id: "hub-candidate", offset: 0, limit: 1, source: .hub), context: ctx)
        _ = try await tool.execute(.init(id: "hub-candidate", offset: 1, limit: 1, source: .hub), context: ctx)
        #expect(await provider.detailRunIDs == [ctx.runID, ctx.runID])
        #expect(await provider.detailOwnerIDs == [ctx.conversationID, ctx.conversationID])
    }

    @Test("Hub read needs an exact id, refuses before any IO in a temporary chat, and paginates")
    func hubReadContract() async throws {
        let provider = FakeCatalogProvider(details: ["hub-candidate": try makeDetail(instructions: String(repeating: "x", count: 10_000))])
        let tool = SkillReadTool(manager: HubToolManager(rows: []), catalog: provider)

        await #expect(throws: SkillHubValidationError.hubIdRequired) {
            try await tool.execute(.init(source: .hub), context: hubContext())
        }
        // Temporary ceiling: refuse BEFORE any catalog IO.
        await #expect(throws: FloeError.self) {
            try await tool.execute(.init(id: "hub-candidate", source: .hub), context: hubContext(temporary: true))
        }
        #expect(await provider.detailCalls == 0)

        let first = try await tool.execute(.init(id: "hub-candidate", offset: 0, limit: 100, source: .hub), context: hubContext())
        let object = try #require(JSONSerialization.jsonObject(with: Data(first.summary.utf8)) as? [String: Any])
        #expect(object["source"] as? String == "hub")
        #expect((object["instructions"] as? String)?.count == 100)
        #expect(object["nextOffset"] as? Int == 100)
        #expect(object["totalCharacters"] as? Int == 10_000)
        #expect(object["currentDigest"] == nil)
        // Uninstalled catalog metadata is distinct from the installed pin.
        #expect(object["isInstalled"] as? Bool == false)
        #expect(object["installedDigest"] == nil)
        let last = try await tool.execute(.init(id: "hub-candidate", offset: 9_900, limit: 100, source: .hub), context: hubContext())
        let lastObject = try #require(JSONSerialization.jsonObject(with: Data(last.summary.utf8)) as? [String: Any])
        #expect(lastObject["nextOffset"] == nil)
        await #expect(throws: FloeError.self) {
            try await tool.execute(.init(id: "hub-candidate", offset: 20_000, source: .hub), context: hubContext())
        }
        // Missing entry: honest not-found, distinct from a fetch failure.
        await #expect(throws: FloeError.self) {
            try await tool.execute(.init(id: "no-such-entry", source: .hub), context: hubContext())
        }
        let failing = FakeCatalogProvider(details: [:], failure: SkillHubCatalogError.unavailable("publication fetch failed"))
        await #expect(throws: SkillHubCatalogError.self) {
            try await SkillReadTool(manager: HubToolManager(rows: []), catalog: failing)
                .execute(.init(id: "hub-candidate", source: .hub), context: hubContext())
        }
    }

    @Test("Hub read reports the installed workflow pin separately when the same id is installed")
    func hubReadDistinguishesInstalledPin() async throws {
        let installedDigest = String(repeating: "9", count: 64)
        let rows = [ManagedSkill(id: "hub-candidate", name: "Local copy", version: "0.9.0", enabled: false, digest: installedDigest, currentDigest: installedDigest, description: nil)]
        let provider = FakeCatalogProvider(details: ["hub-candidate": try makeDetail()])
        let tool = SkillReadTool(manager: HubToolManager(rows: rows), catalog: provider)
        let output = try await tool.execute(.init(id: "hub-candidate", source: .hub), context: hubContext())
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
        #expect(object["isInstalled"] as? Bool == true)
        #expect(object["installedDigest"] as? String == installedDigest)
        #expect(object["installedVersion"] as? String == "0.9.0")
        // The catalog entry keeps its OWN version/digest identity, and no
        // currentDigest leaks for the foreign catalog row itself.
        let entry = try #require(object["entry"] as? [String: Any])
        #expect(entry["version"] as? String == "1.0.0")
        #expect(object["currentDigest"] == nil)
        // Review text is carried but never claimed active.
        #expect((object["nextAction"] as? String)?.contains("NOT active") == true)
        // Bundled inventory stays package-relative (no host path, bounded).
        let files = try #require(object["bundledFiles"] as? [String])
        #expect(files == ["SKILL.md", "references/guide.md"])
    }

    @Test("Default installed reads keep manager/resourceContext behavior")
    func installedDefaultUnchanged() async throws {
        let rows = [ManagedSkill(id: "custom-alpha", name: "Alpha", version: "1", enabled: true, digest: "a", markdown: "body")]
        let provider = FakeCatalogProvider(entries: [], details: [:])
        let tool = SkillReadTool(manager: HubToolManager(rows: rows), catalog: provider)
        let context = hubContext()
        let list = try await tool.execute(.init(), context: context)
        #expect(try JSONDecoder().decode([ManagedSkill].self, from: Data(list.summary.utf8)).first?.markdown == nil)
        let detail = try await tool.execute(.init(id: "custom-alpha"), context: context)
        #expect(try JSONDecoder().decode([ManagedSkill].self, from: Data(detail.summary.utf8)).first?.markdown == "body")
        // The catalog bridge is never consulted for the installed source.
        #expect(await provider.detailCalls == 0)
        #expect(await provider.entryCalls == 0)
    }
}

// MARK: - skill.install hub branch

@Suite("SkillHubToolContract hub install")
struct SkillHubToolInstallTests {

    @Test("Arguments are strictly discriminated between the workspace and hub vocabularies")
    func discriminatedValidation() async throws {
        let tool = SkillWorkspaceInstallTool(installer: RecordingWorkspaceInstaller(), hub: FakeHubInstaller(.failure(SkillHubCatalogError.invalid("unused"))))
        // hub source refuses workspace parameters.
        #expect(throws: SkillHubValidationError.self) {
            try tool.validate(.init(source: .hub, directory: "skills/demo", id: "hub-candidate"))
        }
        #expect(throws: SkillHubValidationError.self) {
            try tool.validate(.init(source: .hub, mode: .replace, expectedDigest: hubContentDigest, id: "hub-candidate"))
        }
        #expect(throws: SkillHubValidationError.self) { try tool.validate(.init(source: .hub, expectedDigest: hubContentDigest, id: "hub-candidate")) }
        // hub source requires an id with the existing identifier grammar.
        #expect(throws: SkillHubValidationError.self) { try tool.validate(.init(source: .hub)) }
        #expect(throws: SkillValidationError.self) { try tool.validate(.init(source: .hub, id: "../escape")) }
        // an optional pin must be an exact 40-hex publication commit Y.
        #expect(throws: SkillHubValidationError.self) { try tool.validate(.init(source: .hub, id: "hub-candidate", publicationCommit: "deadbeef")) }
        try tool.validate(.init(source: .hub, id: "hub-candidate", publicationCommit: hubPinY))
        // workspace source refuses hub parameters.
        #expect(throws: SkillHubValidationError.self) {
            try tool.validate(.init(directory: "skills/demo", id: "hub-candidate"))
        }
        #expect(throws: SkillHubValidationError.self) {
            try tool.validate(.init(source: .workspace, directory: "skills/demo", publicationCommit: hubPinY))
        }
        // workspace source still requires the directory; legacy digest contract unchanged.
        #expect(throws: SkillWorkspaceInstallError.self) { try tool.validate(.init(source: .workspace)) }
        #expect(throws: SkillWorkspaceInstallError.self) { try tool.validate(.init(directory: "skills/demo", mode: .replace)) }
        try tool.validate(.init(directory: "skills/demo"))
        // JSON decoding: the hub vocabulary is accepted, unknown sources fail.
        let decoded = try JSONDecoder().decode(SkillWorkspaceInstallTool.Arguments.self, from: Data(#"{"source":"hub","id":"hub-candidate"}"#.utf8))
        #expect(decoded.source == .hub)
        #expect(decoded.directory == nil)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(SkillWorkspaceInstallTool.Arguments.self, from: Data(#"{"source":"host-interpreter"}"#.utf8))
        }
    }

    @Test("Approval, temporary and cancellation gates prevent any hub IO")
    func gatesPreventIO() async throws {
        let hub = FakeHubInstaller(.receipt(try makeReceipt()))
        let workspace = RecordingWorkspaceInstaller()
        let tool = SkillWorkspaceInstallTool(installer: workspace, hub: hub)
        let arguments = SkillWorkspaceInstallTool.Arguments(source: .hub, id: "hub-candidate", publicationCommit: hubPinY)

        await #expect(throws: FloeError.self) {
            try await tool.execute(arguments, context: hubContext(approved: false))
        }
        await #expect(throws: FloeError.self) {
            try await tool.execute(arguments, context: hubContext(temporary: true))
        }
        let cancelled = CancellationToken()
        cancelled.cancel()
        await #expect(throws: FloeError.cancelled) {
            try await tool.execute(arguments, context: hubContext(cancellation: cancelled))
        }
        // The hub branch needs NO workspaceRoot: a context without one is not
        // an error for hub (checked in the success test below), and no branch
        // ever touched the workspace installer here.
        #expect(await hub.requestCount() == 0)
        #expect(await workspace.planCount() == 0)
    }

    @Test("The bridge receives the actual runtime-issued context identity")
    func contextForwarding() async throws {
        let token = CancellationToken()
        let hub = FakeHubInstaller(.receipt(try makeReceipt()))
        let tool = SkillWorkspaceInstallTool(installer: RecordingWorkspaceInstaller(), hub: hub)
        let runID = UUID()
        let conversationID = UUID()
        let grantID = UUID()
        let context = ToolContext(
            runID: runID,
            toolCallID: "call-42",
            approvalGrantID: grantID,
            workspaceRootURL: nil,
            cancellation: token,
            conversationID: conversationID
        )
        _ = try await tool.execute(
            .init(source: .hub, id: "hub-candidate", publicationCommit: hubPinY),
            context: context
        )
        let forwarded = try #require(await hub.recordedContext())
        // Same-run refusal dedupe and durable staging must bind THIS identity:
        // the tool forwards the real context, not a re-derived stand-in.
        #expect(forwarded.runID == runID)
        #expect(forwarded.conversationID == conversationID)
        #expect(forwarded.approvalGrantID == grantID)
        #expect(forwarded.toolCallID == "call-42")
        #expect(forwarded.cancellation === token)
    }

    @Test("Cancellation before the real commit fails honestly as cancelled")
    func cancelBeforeCommit() async throws {
        let token = CancellationToken()
        let hub = FakeHubInstaller(.cancelBeforeCommit(token))
        let workspace = RecordingWorkspaceInstaller()
        let tool = SkillWorkspaceInstallTool(installer: workspace, hub: hub)
        await #expect(throws: FloeError.cancelled) {
            try await tool.execute(
                .init(source: .hub, id: "hub-candidate"),
                context: hubContext(cancellation: token)
            )
        }
        // Nothing is claimed as installed and no fallback to the workspace
        // directory branch happens.
        #expect(await workspace.planCount() == 0)
    }

    @Test("A pending permission delta returns an honest action state, never an installed receipt")
    func pendingReviewIsNotSuccess() async throws {
        let hub = FakeHubInstaller(.failure(SkillHubInstallError.reviewRequired))
        let workspace = RecordingWorkspaceInstaller()
        let tool = SkillWorkspaceInstallTool(installer: workspace, hub: hub)
        let output = try await tool.execute(
            .init(source: .hub, id: "hub-candidate", publicationCommit: hubPinY),
            context: hubContext()
        )
        // Action state: the user owes a decision in the EXISTING combined
        // approval flow; nothing is claimed as committed.
        #expect(output.exitStatus == nil)
        #expect(output.requiresUserAction == true)
        #expect(output.summary.contains("status=pending-review id=hub-candidate"))
        #expect(!output.summary.contains("status=installed"))
        #expect(!output.summary.contains("contentDigest="))
        #expect(!output.summary.contains("catalogDigest="))
        #expect(!output.summary.contains("publicationCommit="))
        // The id echo only carries the request's own id (no digests exist),
        // and there is no directory fallback: the workspace installer is
        // untouched even though the same tool instance owns both branches.
        #expect(await hub.requestCount() == 1)
        #expect(await workspace.planCount() == 0)
    }

    @Test("Declined review and user-choice blocks are terminal non-retryable messages")
    func terminalUserDecisions() async throws {
        let cases: [(SkillHubInstallError, String)] = [
            (.reviewDeclined, "status=review-declined"),
            (.userChoiceBlocked, "status=user-choice-blocked"),
        ]
        for (error, marker) in cases {
            let workspace = RecordingWorkspaceInstaller()
            let tool = SkillWorkspaceInstallTool(installer: workspace, hub: FakeHubInstaller(.failure(error)))
            let output = try await tool.execute(
                .init(source: .hub, id: "hub-candidate"), context: hubContext()
            )
            #expect(output.exitStatus == 1)
            #expect(output.requiresUserAction == false)
            #expect(output.summary.contains(marker))
            #expect(output.summary.contains("not retryable"))
            #expect(output.summary.contains("Do not attempt a workspace-directory install as a substitute"))
            #expect(!output.summary.contains("status=installed"))
            #expect(!output.summary.contains("status=pending-review"))
            #expect(await workspace.planCount() == 0)
        }
        // Fixed per-case vocabulary: the messages carry no associated values,
        // so a bridge can never route model-controlled text through them.
        #expect(SkillHubInstallError.reviewDeclined.errorDescription != SkillHubInstallError.userChoiceBlocked.errorDescription)
        // notConfigured remains a thrown wiring failure (covered by
        // bridgeAbsentOmitsNewFields), not one of these results.
        await #expect(throws: SkillHubInstallError.notConfigured) {
            try await SkillWorkspaceInstallTool(installer: RecordingWorkspaceInstaller())
                .execute(.init(source: .hub, id: "hub-candidate"), context: hubContext())
        }
    }

    @Test("A committed hub install verifies the typed receipt and keeps X/Y/digests separate")
    func typedReceiptSuccess() async throws {
        let hub = FakeHubInstaller(.receipt(try makeReceipt()))
        let tool = SkillWorkspaceInstallTool(installer: RecordingWorkspaceInstaller(), hub: hub)
        // No workspaceRoot in this context: the catalog install is global.
        let output = try await tool.execute(
            .init(source: .hub, id: "hub-candidate", publicationCommit: hubPinY),
            context: hubContext()
        )
        #expect(output.exitStatus == 0)
        let summary = output.summary
        #expect(summary.hasPrefix("status=installed id=hub-candidate version=1.0.0 contentDigest=\(hubContentDigest)"))
        #expect(summary.contains("catalogDigest=\(hubCatalogDigest) reviewDigest=\(hubReviewDigest)"))
        #expect(summary.contains("publicationCommit=\(hubPinY) sourceCommit=\(hubSourceX)"))
        #expect(summary.contains("reviewed capabilities=data.transform tools=exec.shell"))
        #expect(summary.contains("note=Installed through the curated Hub verified"))
        #expect(summary.count <= 4_096)
        let requests = await hub.requests
        #expect(requests.first?.id == "hub-candidate")
        #expect(requests.first?.publicationCommit == hubPinY)
        // Without an explicit pin the adapter resolves Y and the receipt
        // still records the ACTUAL pin.
        let unpinned = try await tool.execute(.init(source: .hub, id: "hub-candidate"), context: hubContext())
        #expect(unpinned.summary.contains("publicationCommit=\(hubPinY)"))
    }

    @Test("Wrong id, wrong pinned Y or malformed digests are refused integrity failures")
    func receiptIntegrity() async throws {
        let context = hubContext()
        await #expect(throws: SkillHubValidationError.receiptIdentityMismatch) {
            try await SkillWorkspaceInstallTool(
                installer: RecordingWorkspaceInstaller(),
                hub: FakeHubInstaller(.receipt(try makeReceipt(skillID: "different-skill")))
            ).execute(.init(source: .hub, id: "hub-candidate"), context: context)
        }
        await #expect(throws: SkillHubValidationError.receiptIdentityMismatch) {
            try await SkillWorkspaceInstallTool(
                installer: RecordingWorkspaceInstaller(),
                hub: FakeHubInstaller(.receipt(try makeReceipt(publicationCommit: String(repeating: "1", count: 40))))
            ).execute(.init(source: .hub, id: "hub-candidate", publicationCommit: hubPinY), context: context)
        }
        // Malformed receipt digests cannot even be constructed.
        #expect(throws: SkillHubValidationError.self) {
            try makeReceipt(contentDigest: "not-a-digest")
        }
        #expect(throws: SkillHubValidationError.self) {
            try SkillHubInstallReceipt(
                status: .installed, skillID: "hub-candidate", version: "1.0.0",
                contentDigest: hubContentDigest, packageSHA256: hubPackageSHA,
                catalogDigest: hubCatalogDigest, reviewDigest: hubReviewDigest,
                sourceCommit: hubSourceX, publicationCommit: "short", containsScripts: false,
                fileCount: 1, totalBytes: 1
            )
        }
        // Honest failed results for bridge failures (nothing committed):
        // the model sees the catalog state, not a fake success.
        let failed = try await SkillWorkspaceInstallTool(
            installer: RecordingWorkspaceInstaller(),
            hub: FakeHubInstaller(.failure(SkillHubCatalogError.invalid("review record does not join the package digest")))
        ).execute(.init(source: .hub, id: "hub-candidate"), context: context)
        #expect(failed.exitStatus == 1)
        #expect(failed.summary.hasPrefix("status=failed error="))
        #expect(failed.summary.contains("review record does not join"))
        #expect(!failed.summary.contains("status=installed"))
    }

    @Test("A cancellation that arrives after the real commit still reports the committed receipt")
    func lateCancellationReportsCommit() async throws {
        let token = CancellationToken()
        let hub = FakeHubInstaller(.cancelDuringCommit(try makeReceipt(), token))
        let tool = SkillWorkspaceInstallTool(installer: RecordingWorkspaceInstaller(), hub: hub)
        let output = try await tool.execute(
            .init(source: .hub, id: "hub-candidate", publicationCommit: hubPinY),
            context: hubContext(cancellation: token)
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("status=installed id=hub-candidate"))
        #expect(output.summary.contains("publicationCommit=\(hubPinY)"))
        #expect(!output.summary.contains("nothing installed"))
    }
}

// MARK: - Contract type bounds

@Suite("SkillHubToolContract types")
struct SkillHubToolContractTypeTests {

    @Test("Metadata is bounded and provenance keeps X separate from Y")
    func boundedMetadata() throws {
        let entry = try makeEntry(
            id: "hub-bounded",
            nameEN: String(repeating: "N", count: 400),
            descriptionEN: String(repeating: "D", count: 4_000)
        )
        #expect(entry.name.en.count <= SkillHubLocalizedText.maximumNameCharacters)
        #expect(entry.description.en.count <= SkillHubLocalizedText.maximumDescriptionCharacters)
        #expect(entry.tags.count <= SkillHubContractLimits.maximumTagCount)
        // X != Y is the normal shape; neither is defined via the other.
        let provenance = try #require(entry.provenance)
        #expect(provenance.sourceCommit == hubSourceX)
        #expect(provenance.publicationCommit == hubPinY)
        #expect(provenance.sourceCommit != provenance.publicationCommit)
        // Fixture feeds may lack X; malformed identity is refused.
        let fixture = try makeProvenance(publicationCommit: hubPinY, sourceCommit: nil)
        #expect(fixture.sourceCommit == nil)
        #expect(throws: SkillHubValidationError.self) { try makeProvenance(publicationCommit: "nope") }
        // A fixture feed can never be labeled through production install offers
        // here: the offer type is carried honestly.
        let simulated = try makeEntry(id: "hub-fixture", offer: .fixtureSimulated)
        #expect(simulated.installOffer == .fixtureSimulated)
        // Bundled inventory refuses host paths and traversal.
        #expect(throws: SkillHubValidationError.self) {
            try makeDetail(bundledFiles: ["/etc/passwd"])
        }
        #expect(throws: SkillHubValidationError.self) {
            try makeDetail(bundledFiles: ["../escape.md"])
        }
        // Instructions keep markdown structure but drop control bytes.
        let detail = try makeDetail(instructions: "line one\r\nline two\u{0}\tend")
        #expect(detail.instructions == "line one\nline two\tend")
    }

    @Test("Reviewed tool identities preserve exact CamelCase and distinct case")
    func reviewedToolIdentitiesAreExact() throws {
        let names = ["workspace.publishOutput", "workspace.listDirectory", "workspace.Example", "workspace.example"]
        let detail = try makeDetail(reviewedTools: names)
        let receipt = try makeReceipt(reviewedTools: names)
        #expect(detail.reviewedTools == names)
        #expect(receipt.reviewedTools == names)
        let roundTrip = try JSONDecoder().decode(SkillHubInstallReceipt.self, from: JSONEncoder().encode(receipt))
        #expect(roundTrip.reviewedTools == names)
    }

    @Test("Overlong, duplicate and malformed tool identities fail instead of being silently rewritten")
    func malformedReviewedIdentitiesFailClosed() throws {
        for names in [
            ["workspace." + String(repeating: "a", count: 129)],
            ["workspace.publishOutput", "workspace.publishOutput"],
            ["workspace.invalid name"]
        ] {
            #expect(throws: SkillHubValidationError.self) { try makeDetail(reviewedTools: names) }
            #expect(throws: SkillHubValidationError.self) { try makeReceipt(reviewedTools: names) }
        }
    }

    @Test("Search ranking is deterministic, zh-aware and id-grammar strict")
    func ranking() throws {
        let entries = try [
            makeEntry(id: "hub-exact", nameEN: "Zebra", nameZH: "斑马", descriptionEN: "anything"),
            makeEntry(id: "hub-other", nameEN: "Zebra helper", nameZH: "帮助", descriptionEN: "zebra things"),
        ]
        #expect(SkillHubSearch.matching(query: "hub-exact", entries: entries) == ["hub-exact", "hub-other"])
        #expect(SkillHubSearch.matching(query: "斑马", entries: entries).first == "hub-exact")
        #expect(SkillHubSearch.matching(query: "zebra", entries: entries, excluding: ["hub-exact"]) == ["hub-other"])
        // The shared catalog id grammar is the existing identifier contract.
        #expect(throws: SkillValidationError.self) { try SkillHubInstallRequest(id: "Bad_ID") }
        let request = try SkillHubInstallRequest(id: " hub-candidate ", publicationCommit: hubPinY.uppercased())
        #expect(request.id == "hub-candidate")
        #expect(request.publicationCommit == hubPinY)
    }
}
