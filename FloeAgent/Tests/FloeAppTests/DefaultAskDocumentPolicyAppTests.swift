// FloeAppTests — App-level default-ask document policy regression.
//
// The user's default chat mode is `.ask`: `HumanApprovalPolicy` decides every
// side-effecting call. This fixture drives ONE real `FloeAgentRuntime` with a
// scripted (adaptive) provider and the PRODUCTION tool hosts registered exactly
// like the app registers them:
//
//   * the real `document.pdf.edit` / `document.pdf.export` tools (PDFKit +
//     the bundled PDFium bridge) on a real PDF fixture;
//   * the real `media.project` tool hosted by a `WorkbenchCenter` whose
//     `MediaProjectStore` lives in an injected custom store directory (the
//     service-owned root the runtime contract is fed from), with the project
//     created through the production `startImageProject` path.
//
// It proves the ordinary non-repository workflow — READ/query -> draft ->
// apply -> READBACK -> safe export — executes without a single
// `waitingApproval` card and with real files/revisions produced, and that a
// write INTO a repository still parks on the human card. No fixture injects a
// grant, an approval or a runtime authority: the runtime mints the automatic
// apply authority itself and the tool consumes it.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(UIKit)
import XCTest
import UIKit
import CoreGraphics
import FloeCore
import FloeTools
import FloeWorkbench
import FloeAgentRuntime
import FloeModels
import FloeProviders
import FloeSecurity
@testable import FloeApp

/// Minimal async-safe flag box (App-test target local; no production type is
/// involved, and NSLock is unavailable from async contexts on this SDK).
private final class TestFlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Behaves like a real model: each turn is built from the tool evidence the
/// runtime hands back (this turn's results plus the replayed settled pairs),
/// so a proposal id produced by one turn's `propose` is applied in the NEXT
/// turn of the SAME run — one runtime, no reset, no human turn, no injected
/// grant. File-scope on purpose: turn builders must not capture the test
/// instance.
private final class AdaptiveProviderAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIChatCompletions
    private let lock = NSLock()
    private var turnIndex = 0
    private let buildTurn: @Sendable (Int, [(callID: String, output: String)]) -> [AgentEvent]

    init(buildTurn: @escaping @Sendable (Int, [(callID: String, output: String)]) -> [AgentEvent]) {
        self.buildTurn = buildTurn
    }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let built: ([AgentEvent], Int) = lock.withLock {
            var evidence: [(callID: String, output: String)] = request.toolResults
            evidence.append(contentsOf: request.replayedToolPairs.map {
                (callID: $0.call.id, output: $0.result.outputSummary)
            })
            let index = turnIndex
            turnIndex += 1
            return (buildTurn(index, evidence), index)
        }
        return AsyncThrowingStream { continuation in
            for event in built.0 { continuation.yield(event) }
            continuation.yield(.completed(.init(stopReason: .endTurn)))
            continuation.finish()
        }
    }

    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] {
        []
    }
}

private func appCall(_ id: String, _ tool: String, _ arguments: String) throws -> ToolCall {
    try ToolCall(id: id, toolName: tool, argumentsJSON: Data(arguments.utf8), scope: .local)
}

/// The media proposal id EXACTLY as the tool printed it (the model echoes it;
/// the raw-spelling binding consumes the same bytes the runtime digested).
private func appProposalID(from evidence: [(callID: String, output: String)],
                           callID: String) -> String? {
    guard let output = evidence.last(where: { $0.callID == callID })?.output else { return nil }
    let marker = "Pending media proposal "
    guard let range = output.range(of: marker) else { return nil }
    let id = output[range.upperBound...].prefix(while: { $0.isHexDigit || $0 == "-" })
    return id.count == 36 ? String(id) : nil
}

private actor AppRunRecorder: AgentEventSink {
    private var results: [ToolResult] = []
    private var transitions: [String] = []

    func agentRuntime(_ runtime: FloeAgentRuntime, didTransitionTo state: AgentState) async {
        transitions.append(state.name)
    }

    func agentRuntime(_ runtime: FloeAgentRuntime, didEmit event: AgentEvent) async {
        if case .toolResult(let result) = event { results.append(result) }
    }

    func snapshot() -> (results: [ToolResult], transitions: [String]) { (results, transitions) }
}

private actor AppAuditRecorder: AuditSink {
    private var entries: [AuditEntry] = []
    func record(_ entry: AuditEntry) async throws { entries.append(entry) }
    func snapshot() -> [AuditEntry] { entries }
}

@MainActor
final class DefaultAskDocumentPolicyAppTests: XCTestCase {

    private var workspace: URL!
    private var storeRoot: URL!

    override func setUp() async throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("default-ask-ws-\(UUID().uuidString)", isDirectory: true)
        storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("default-ask-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        if let storeRoot { try? FileManager.default.removeItem(at: storeRoot) }
    }

    // MARK: - Fixtures and production registration

    private func writePDFFixture(at url: URL) throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 200)).pdfData { context in
            context.beginPage()
            ("FLOE DEFAULT ASK FIXTURE" as NSString).draw(
                at: CGPoint(x: 24, y: 100),
                withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        try data.write(to: url)
    }

    private func writePNGFixture(at url: URL) throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        let png = try XCTUnwrap(image.pngData())
        try png.write(to: url)
    }

    private func makeBridge() -> WorkbenchAIBridge {
        WorkbenchAIBridge(
            isAvailable: { false },
            imageModels: { [] },
            videoModels: { [] },
            generateImages: { _, _, _, _, _ in [] },
            submitVideo: { _, _, _, _, _ in UUID() },
            refreshJob: { jobID in
                WorkbenchAIJobInfo(id: jobID, state: "idle", progress: nil, message: nil,
                                   isActive: false, isWaitStopped: false, modelName: "")
            },
            cancelJob: { _ in },
            jobs: { _ in [] },
            deliverResult: { _ in throw FloeError.notFound("no result") },
            costNote: { _ in "" })
    }

    /// Registers exactly the production tools this fixture drives on the
    /// shared registry and returns a restore closure.
    private func registerProductionTools(center: WorkbenchCenter) -> () -> Void {
        let previousMedia = ToolRunnerRegistry.shared.runner(named: MediaProjectTool.name)
        let previousPDFEdit = ToolRunnerRegistry.shared.runner(named: PDFEditTool.name)
        let previousPDFExport = ToolRunnerRegistry.shared.runner(named: PDFExportTool.name)
        ToolCatalog.register(MediaProjectTool.self)
        ToolCatalog.register(PDFEditTool.self)
        ToolCatalog.register(PDFExportTool.self)
        registerWorkbenchTools(center: center)
        ToolRunnerRegistry.shared.register(PDFEditTool())
        ToolRunnerRegistry.shared.register(PDFExportTool())
        return {
            if let previousMedia { ToolRunnerRegistry.shared.register(previousMedia) }
            if let previousPDFEdit { ToolRunnerRegistry.shared.register(previousPDFEdit) }
            if let previousPDFExport { ToolRunnerRegistry.shared.register(previousPDFExport) }
        }
    }

    private func makeRuntime(
        conversationID: UUID,
        adapter: AdaptiveProviderAdapter,
        allowedToolNames: Set<String>,
        serviceStorePaths: [String: String],
        audit: AppAuditRecorder,
        sink: AppRunRecorder
    ) -> FloeAgentRuntime {
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://default-ask.example/v1")!,
            displayName: "Scripted Default-Ask Provider")
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "scripted-default-ask",
            displayName: "Scripted Default-Ask Model",
            limits: ModelLimits(contextTokens: 16_384, maxOutputTokens: 2_048),
            capabilities: [.tools])
        return FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID,
                provider: provider,
                model: model,
                allowedToolNames: allowedToolNames,
                workspaceRootURL: workspace,
                serviceStorePaths: serviceStorePaths),
            adapter: adapter,
            // The user's DEFAULT .ask policy: every side-effecting call goes
            // through the real human policy (and the deterministic carve-outs).
            policy: HumanApprovalPolicy(),
            executor: CatalogToolExecutor(),
            auditSink: audit,
            checkpointStore: nil,
            sink: sink,
            runID: UUID())
    }

    private func waitUntil(
        timeout: TimeInterval = 30,
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    // MARK: - Tests

    func testDefaultAskReadDraftApplyReadbackExportHasNoCards() async throws {
        // ── Production services: real PDF tools + a real workbench center
        //    whose MediaProjectStore uses an INJECTED custom root.
        let conversationID = UUID()
        let center = WorkbenchCenter(rootProvider: { [workspace] in workspace },
                                     bridge: makeBridge(),
                                     mediaProjectStoreDirectory: storeRoot)
        let restore = registerProductionTools(center: center)
        defer { restore() }

        let pngURL = workspace.appendingPathComponent("source.png")
        try writePNGFixture(at: pngURL)
        await center.startImageProject(
            sourceURL: pngURL,
            owner: WorkbenchCenter.Owner(kind: .chat, id: conversationID, environmentID: nil))
        let project = try XCTUnwrap(center.project, "the production image project must open")
        let layerID = try XCTUnwrap(project.imageLayers.first?.id)

        // The runtime contract is fed from the ACTUAL store instance (this is
        // exactly what ConversationCenter passes), and the identity is the
        // custom injected root — not a second default-path calculator.
        XCTAssertEqual(center.typedServiceStorePaths[TypedMutationContract.mediaProjectStoreKey],
                       center.mediaProjectStoreRootPath)
        XCTAssertEqual(center.mediaProjectStoreRootPath,
                       storeRoot.standardizedFileURL.resolvingSymlinksInPath().path)
        let recordURL = URL(fileURLWithPath: center.mediaProjectStoreRootPath)
            .appendingPathComponent(MediaProjectStore.projectFileName(id: project.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL.path),
                      "the production store must have persisted the project record at its own root")

        let pdfURL = workspace.appendingPathComponent("input.pdf")
        try writePDFFixture(at: pdfURL)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: pdfURL)
        let assetHashesBefore = MediaAutomaticVerification.assetHashes(project)

        // ── Script: one runtime, adaptive turns, ordinary workflow. All
        //    identifiers are sent exactly as the tool prints them.
        let projectID = project.id.uuidString
        let layerUUID = layerID.uuidString
        let adapter = AdaptiveProviderAdapter { turn, evidence in
            switch turn {
            case 0:
                return [.toolRequest(try! appCall(
                    "pdf-edit", "document.pdf.edit",
                    #"{"inputPath":"input.pdf","outputPath":"edited.pdf","watermark":"FLOE"}"#))]
            case 1:
                return [
                    .toolRequest(try! appCall(
                        "pdf-export", "document.pdf.export",
                        #"{"inputPath":"edited.pdf","outputPath":"edited.txt","format":"text"}"#)),
                    .toolRequest(try! appCall(
                        "media-capabilities", "media.project",
                        #"{"action":"capabilities","project_id":"\#(projectID)"}"#))
                ]
            case 2:
                return [.toolRequest(try! appCall(
                    "media-read", "media.project",
                    #"{"action":"read","project_id":"\#(projectID)"}"#))]
            case 3:
                return [.toolRequest(try! appCall(
                    "media-propose", "media.project",
                    #"{"action":"propose","project_id":"\#(projectID)","summary":"K3 ordinary flow","commands":[{"type":"update_layer","id":"\#(layerUUID)","opacity":0.5}]}"#))]
            case 4:
                guard let proposal = appProposalID(from: evidence, callID: "media-propose") else {
                    return []
                }
                return [.toolRequest(try! appCall(
                    "media-apply", "media.project",
                    #"{"action":"apply","project_id":"\#(projectID)","proposal_id":"\#(proposal)"}"#))]
            case 5:
                return [.toolRequest(try! appCall(
                    "media-readback", "media.project",
                    #"{"action":"read","project_id":"\#(projectID)"}"#))]
            case 6:
                return [.toolRequest(try! appCall(
                    "media-export", "media.project",
                    #"{"action":"export","project_id":"\#(projectID)","export":{"kind":"image","file_name":"k3-export","format":"png"}}"#))]
            default:
                return [.textDelta(.init(text: "ordinary flow complete"))]
            }
        }

        let sink = AppRunRecorder()
        let audit = AppAuditRecorder()
        let runtime = makeRuntime(
            conversationID: conversationID,
            adapter: adapter,
            allowedToolNames: ["document.pdf.edit", "document.pdf.export", "media.project"],
            serviceStorePaths: center.typedServiceStorePaths,
            audit: audit,
            sink: sink)
        try await runtime.start(goal: "编辑 PDF 并完成媒体项目草稿、应用、读回与导出")

        // ── The whole flow closed with ZERO approval cards.
        let (results, transitions) = await sink.snapshot()
        XCTAssertFalse(transitions.contains("waitingApproval"),
                       "no ordinary step may park on an approval card: \(transitions)")
        let executed = Dictionary(uniqueKeysWithValues: results.map { ($0.callID, $0) })
        for callID in ["pdf-edit", "pdf-export", "media-capabilities", "media-read",
                       "media-propose", "media-apply", "media-readback", "media-export"] {
            let result = try XCTUnwrap(executed[callID], "\(callID) must have executed")
            XCTAssertEqual(result.status, .ok, "\(callID): \(result.outputSummary)")
        }
        // The real human policy allowed every media step through the canonical
        // decision path (an escalation or deny would have parked/failed above).
        let audited = await audit.snapshot()
        let mediaDecisions = audited.filter { $0.toolName == "media.project" }
        XCTAssertFalse(mediaDecisions.isEmpty, "the real policy path must have decided the media calls")
        XCTAssertTrue(mediaDecisions.allSatisfy { $0.decision.hasPrefix("allow") },
                      "\(mediaDecisions.map(\.decision))")

        // ── Real effects: PDF copy + export, media record committed, source
        //    bytes untouched, export file present, draft consumed.
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("edited.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("edited.txt").path))
        let sourceSHAAfter = try FloeDigest.sha256Hex(ofFileAt: pdfURL)
        XCTAssertEqual(sourceSHAAfter, sourceSHA,
                       "the PDF source must be byte-identical after the flow")
        let reopened = try await MediaProjectStore(directory: storeRoot).loadProject(id: project.id)
        let committed = try XCTUnwrap(reopened, "the applied project record must reopen")
        // The fixture project is created through two real transactions
        // (addAsset + addImageLayer), so it opens at revision 2; the applied
        // proposal must commit EXACTLY ONE revision above the pre-run revision.
        XCTAssertEqual(committed.revision, project.revision + 1,
                       "the runtime-authorized apply must commit exactly one revision")
        XCTAssertEqual(committed.imageLayers.first?.opacity, 0.5)
        XCTAssertEqual(MediaAutomaticVerification.assetHashes(committed), assetHashesBefore,
                       "referenced source assets must be unchanged")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("Workbench/Exports/k3-export.png").path),
            "the verified export file must exist")
        let proposalFromRun = appProposalID(from: results.map { ($0.callID, $0.outputSummary) },
                                           callID: "media-propose")
        if let proposalFromRun, let proposalUUID = UUID(uuidString: proposalFromRun) {
            let pending = try await center.loadProposal(id: proposalUUID)
            XCTAssertNil(pending, "an applied proposal must not stay pending")
        }
    }

    func testRepositoryDestinationStillCardsUnderDefaultAsk() async throws {
        // A workspace that IS a repository: the write must keep the card.
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)
        let center = WorkbenchCenter(rootProvider: { [workspace] in workspace },
                                     bridge: makeBridge(),
                                     mediaProjectStoreDirectory: storeRoot)
        let restore = registerProductionTools(center: center)
        defer { restore() }

        let pdfURL = workspace.appendingPathComponent("input.pdf")
        try writePDFFixture(at: pdfURL)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: pdfURL)

        let adapter = AdaptiveProviderAdapter { turn, _ in
            switch turn {
            case 0:
                return [.toolRequest(try! appCall(
                    "repo-pdf-edit", "document.pdf.edit",
                    #"{"inputPath":"input.pdf","outputPath":"inside.pdf","watermark":"FLOE"}"#))]
            default:
                return [.textDelta(.init(text: "blocked"))]
            }
        }
        let sink = AppRunRecorder()
        let audit = AppAuditRecorder()
        let runtime = makeRuntime(
            conversationID: UUID(),
            adapter: adapter,
            allowedToolNames: ["document.pdf.edit"],
            serviceStorePaths: center.typedServiceStorePaths,
            audit: audit,
            sink: sink)

        let finished = TestFlagBox(false)
        let task = Task {
            defer { finished.set() }
            try? await runtime.start(goal: "把 PDF 输出写进仓库")
        }
        let parked = await waitUntil { await runtime.state.name == "waitingApproval" }
        XCTAssertTrue(parked, "a repository destination must park on the human card")
        let (_, transitions) = await sink.snapshot()
        XCTAssertTrue(transitions.contains("waitingApproval"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("inside.pdf").path),
            "nothing may be written before the human decision")
        let sourceSHAUnchanged = try FloeDigest.sha256Hex(ofFileAt: pdfURL)
        XCTAssertEqual(sourceSHAUnchanged, sourceSHA)
        await runtime.cancel()
        _ = await waitUntil { finished.get() }
        await task.value
    }
}
#endif
